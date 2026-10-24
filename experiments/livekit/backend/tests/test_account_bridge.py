from dataclasses import replace
import hashlib
import hmac
import json
import secrets
import time

from fastapi.testclient import TestClient
import pytest

from app.main import create_app
from conftest import FakeLiveKit, headers, create_room, login

SECRET = "bridge-test-" + "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


@pytest.fixture
def account_service(lab, tmp_path):
    settings = replace(lab.settings, db_path=str(tmp_path / "account-voice.sqlite3"),
                       auth_mode="account", account_bridge_secret=SECRET, access_code="")
    rtc = FakeLiveKit(settings)
    app = create_app(settings, rtc)
    with TestClient(app) as client:
        yield type("Service", (), {"client": client, "app": app, "rtc": rtc,
            "settings": settings, "consent": lab.consent})()


def profile(name="用户", account_id="kiki_0123456789abcdef"):
    return {"id": account_id, "sdkUserID": account_id, "name": name, "bio": "简介\n第二行",
            "avatarIndex": 1, "avatarURL": None, "needsNickname": False, "notificationsEnabled": True}


def payload(service, auth=None, user=None):
    return {"authorizationID": auth or hashlib.sha256(b"source-session-1").hexdigest(),
            "sourceExpiresAt": int(time.time()) + 86400, "user": user or profile(),
            "legalConsent": {key: service.consent[key] for key in ("privacyVersion", "termsVersion", "documentHash")}}


def signed(service, action, data, *, nonce=None, timestamp=None, secret=SECRET):
    path = "/internal/v1/account/" + action
    body = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    stamp, nonce = str(int(time.time()) if timestamp is None else timestamp), nonce or secrets.token_hex(16)
    message = "\n".join(("account-voice-v1", "POST", path, stamp, nonce, hashlib.sha256(body).hexdigest())).encode()
    signature = hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()
    return service.client.post(path, content=body, headers={"Content-Type": "application/json",
        "X-Kiki-Timestamp": stamp, "X-Kiki-Nonce": nonce, "X-Kiki-Signature": signature})


def exchange(service, **changes):
    return signed(service, "session", payload(service, **changes))


def test_signed_exchange_and_stable_short_lease(account_service):
    service = account_service
    first = exchange(service)
    assert first.status_code == 200, first.text
    value = first.json()
    assert value["sdk"]["provider"] == "livekit" and value["sdk"]["serverURL"] == "wss://furby.top"
    assert value["user"]["id"] == value["sdk"]["userID"] == "kiki_0123456789abcdef"
    assert 890 <= value["expiresAt"] - int(time.time()) <= 900
    updated = exchange(service, user=profile("新昵称")).json()
    assert updated["token"] == value["token"] and updated["user"]["name"] == "新昵称"
    assert service.client.get("/v1/me", headers=headers(value)).status_code == 200
    assert service.client.patch("/v1/me", headers=headers(value), json={"name": "伪造"}).status_code == 409
    assert service.client.post("/v1/auth/lab", json={"name": "访客", "accessCode": "x"}).status_code == 404


def test_wrong_signature_replay_stale_and_legal_mismatch(account_service):
    s = account_service; data = payload(s); nonce = secrets.token_hex(16)
    assert signed(s, "session", data, secret="wrong").status_code == 401
    assert signed(s, "session", data, timestamp=int(time.time()) - 31).status_code == 401
    assert signed(s, "session", data, nonce=nonce).status_code == 200
    assert signed(s, "session", data, nonce=nonce).status_code == 401
    data["legalConsent"]["documentHash"] = "0" * 64
    assert signed(s, "session", data).status_code == 428


@pytest.mark.parametrize("url", ["http://kiki.group/v1/avatars/" + "a"*64 + ".jpg",
    "https://evil.test/1.jpg", "https://kiki.group.evil.test/1.jpg",
    "https://kiki.group/v1/avatars/" + "a"*64 + ".jpg?token=x"])
def test_avatar_urls_are_fixed_public_account_images(account_service, url):
    user = profile(); user["avatarURL"] = url
    assert exchange(account_service, user=user).status_code == 422


def test_revocation_tombstone_wins_against_late_exchange(account_service):
    s=account_service; data=payload(s)
    assert signed(s,"revoke", {"authorizationID": data["authorizationID"]}).status_code == 200
    assert signed(s,"session",data).status_code == 401


def test_revoking_old_source_preserves_new_session_membership(account_service):
    s=account_service; first=exchange(s).json()
    room=create_room(s,first); s.rtc.rooms[room["id"]].add(first["user"]["id"])
    other=hashlib.sha256(b"later-account-session").hexdigest()
    second=exchange(s,auth=other).json()
    assert s.client.post(f"/v1/rooms/{room['id']}/token",headers=headers(second)).status_code == 200
    assert signed(s,"revoke", {"authorizationID": payload(s)["authorizationID"]}).status_code == 200
    assert s.client.get("/v1/me",headers=headers(first)).status_code == 401
    assert s.client.get("/v1/me",headers=headers(second)).status_code == 200
    member=s.app.state.db.execute("SELECT * FROM room_members WHERE room_id=?",(room["id"],)).fetchone()
    assert member["active"] == 1 and member["session_hash"] == hashlib.sha256(second["token"].encode()).hexdigest()


def test_account_deletion_clears_profile_and_denies_all_old_sources(account_service):
    s=account_service; user=profile(); user["avatarURL"]="https://kiki.group/v1/avatars/"+"a"*64+".jpg"
    first=exchange(s,user=user).json()
    assert signed(s,"delete", {"accountID": user["id"]}).status_code == 200
    assert s.client.get("/v1/me",headers=headers(first)).status_code == 401
    row=s.app.state.db.execute("SELECT * FROM users WHERE id=?",(user["id"],)).fetchone()
    assert row["deleted"] == 1 and row["bio"] == "" and row["avatar_url"] is None
    assert exchange(s,auth=hashlib.sha256(b"late-source").hexdigest()).status_code == 401


def test_laboratory_mode_never_accepts_signed_account_exchange(lab):
    assert signed(lab,"session",payload(lab)).status_code == 404


def test_mode_switch_rejects_existing_lab_tokens(lab):
    old=login(lab)
    settings=replace(lab.settings,auth_mode="account",account_bridge_secret=SECRET)
    with TestClient(create_app(settings,FakeLiveKit(settings))) as client:
        assert client.get("/v1/me",headers=headers(old)).status_code == 401


def test_public_number_is_optional_and_never_replaces_voice_identity(account_service):
    s = account_service
    old = exchange(s).json()
    assert old["user"]["displayID"] is None
    user = profile(); user["displayID"] = "kiki_000001"
    current = exchange(s, user=user).json()
    assert current["token"] == old["token"]
    assert current["user"]["id"] == current["sdk"]["userID"] == user["id"]
    assert current["user"]["displayID"] == "kiki_000001"
    room = create_room(s, current)
    s.rtc.rooms[room["id"]].add(user["id"])
    state = s.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(current))
    assert state.status_code == 200, state.text
    value = state.json()
    assert value["room"]["hostID"] == value["me"]["userID"] == user["id"]
    assert value["room"]["hostDisplayID"] == value["me"]["displayID"] == "kiki_000001"
    assert s.app.state.db.execute("SELECT owner_id FROM rooms WHERE id=?", (room["id"],)).fetchone()[0] == user["id"]
    user["displayID"] = "kiki_000002"
    changed = exchange(s, user=user).json()
    assert changed["token"] == current["token"]
    assert changed["user"]["id"] == user["id"]
    assert changed["user"]["displayID"] == "kiki_000002"
    assert s.client.get("/v1/me", headers=headers(old)).json()["displayID"] == "kiki_000002"
    assert signed(s, "delete", {"accountID": user["id"]}).status_code == 200
    assert s.app.state.db.execute("SELECT display_id FROM users WHERE id=?", (user["id"],)).fetchone()[0] is None
    new_user = profile("新用户", "kiki_newstable00001"); new_user["displayID"] = "kiki_000002"
    new = exchange(s, auth=hashlib.sha256(b"new-number-owner").hexdigest(), user=new_user).json()
    assert new["user"]["displayID"] == changed["user"]["displayID"]
    assert new["user"]["id"] != current["user"]["id"]
    assert s.client.get("/v1/me", headers=headers(current)).status_code == 401


@pytest.mark.parametrize("number", ["kiki_000000", "kiki_12345", "kiki_1234567", "kiki_abcdef", "Kiki_000001"])
def test_public_number_bridge_rejects_malformed_display_only_values(account_service, number):
    user = profile(); user["displayID"] = number
    assert exchange(account_service, user=user).status_code == 422


def test_public_number_cannot_be_used_as_stable_account_identity(account_service):
    user = profile(account_id="kiki_000001"); user["displayID"] = "kiki_000001"
    assert exchange(account_service, user=user).status_code == 422


def test_deletion_clears_cached_public_number_without_any_voice_authorization(account_service):
    s = account_service
    user = profile(); user["displayID"] = "kiki_000001"
    assert exchange(s, user=user).status_code == 200
    with s.app.state.db:
        s.app.state.db.execute("DELETE FROM account_authorization_privacy")
        s.app.state.db.execute("DELETE FROM account_authorizations")
        s.app.state.db.execute("DELETE FROM sessions")
    assert signed(s, "delete", {"accountID": user["id"]}).status_code == 200
    assert s.app.state.db.execute("SELECT display_id FROM users WHERE id=?", (user["id"],)).fetchone()[0] is None
