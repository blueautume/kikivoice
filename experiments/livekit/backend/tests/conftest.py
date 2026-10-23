from dataclasses import replace
import hashlib
import json
from types import SimpleNamespace

from fastapi.testclient import TestClient
import pytest

from app.main import Settings, create_app
from app.rtc import LiveKitGateway


@pytest.fixture(autouse=True)
def offline_room_notification_delivery(monkeypatch):
    from app.room_started import RoomStarted

    async def delivered(sender, payload):
        if not hasattr(sender, "synthetic_deliveries"):
            sender.synthetic_deliveries = []
        sender.synthetic_deliveries.append(dict(payload))

    monkeypatch.setattr(RoomStarted, "post", delivered)


class FakeLiveKit:
    def __init__(self, settings):
        self.settings = settings
        self.rooms = {}
        self.create_failure = False
        self.delete_failure = False
        self.unavailable = False
        self.closed = False
        self.remove_failure = False
        self.permission_failure = False
        self.mute_failure = False
        self.permissions = {}
        self.removed = []
        self.muted = []
        self.chat_hints = []
        self.broadcast_failure = False

    async def close(self):
        self.closed = True

    async def list_rooms(self):
        if self.unavailable:
            raise ConnectionError()
        return {name: len(people) for name, people in self.rooms.items()}

    async def create_room(self, room_id):
        self.rooms[room_id] = set()
        if self.create_failure:
            raise TimeoutError()

    async def delete_room(self, room_id):
        if self.delete_failure:
            raise ConnectionError()
        self.rooms.pop(room_id, None)

    async def participants(self, room_id):
        return self.rooms.get(room_id, set())

    async def get_participants(self, room_id):
        return {identity: SimpleNamespace(identity=identity, tracks=[]) for identity in self.rooms.get(room_id, set())}

    async def remove_participant(self, room_id, user_id):
        if self.remove_failure:
            raise ConnectionError()
        self.rooms.get(room_id, set()).discard(user_id)
        self.removed.append((room_id, user_id))

    async def update_permissions(self, room_id, user_id, *, audio, data, metadata):
        if self.permission_failure:
            raise ConnectionError()
        self.permissions[(room_id, user_id)] = {"audio": audio, "data": data, "metadata": metadata}

    async def mute_audio_tracks(self, room_id, user_id):
        if self.mute_failure:
            raise ConnectionError()
        self.muted.append((room_id, user_id))

    async def broadcast_chat_sync(self, room_id, hint):
        if self.broadcast_failure:
            raise ConnectionError()
        self.chat_hints.append((room_id, hint))

    participant_token = LiveKitGateway.participant_token


@pytest.fixture
def lab(tmp_path):
    manifest = {"schemaVersion": 1, "minimumAge": 18, "privacyVersion": "2026-10-18-lab1",
                "termsVersion": "2026-10-18-lab1", "documents": [
                    {"id": name, "title": name, "version": "2026-10-18-lab1",
                     "sections": [{"title": "Test", "paragraphs": ["Laboratory notice"]}]}
                    for name in ("privacy", "terms", "sdk", "permissions")]}
    manifest["documentHash"] = hashlib.sha256(json.dumps(manifest, ensure_ascii=False,
        sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    legal_path = tmp_path / "legal.json"
    legal_path.write_text(json.dumps(manifest))
    settings = Settings(db_path=str(tmp_path / "lab.sqlite3"), legal_path=str(legal_path),
                        api_key="independent-lab-key", api_secret="a" * 48,
                        access_code="local-test-access-code", rate_limit_enabled=False)
    rtc = FakeLiveKit(settings)
    app = create_app(settings, rtc)
    consent = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    consent.update(accepted=True, adultConfirmed=True)
    with TestClient(app) as client:
        yield SimpleNamespace(client=client, app=app, rtc=rtc, settings=settings,
                              consent=consent, legal_path=legal_path)


def login(lab, name="实验者", **changes):
    response = lab.client.post("/v1/auth/lab", json={"name": name,
        "accessCode": lab.settings.access_code, "legalConsent": lab.consent, **changes})
    assert response.status_code == 200, response.text
    return response.json()


def headers(account):
    return {"Authorization": "Bearer " + account["token"]}


def create_room(lab, account, **changes):
    response = lab.client.post("/v1/rooms", headers=headers(account), json={
        "title": "LiveKit实验房", "category": "闲聊", "theme": 0, "isLive": False, **changes})
    assert response.status_code == 200, response.text
    return response.json()
