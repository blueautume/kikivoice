from dataclasses import replace
import hashlib
import json
import time

from fastapi.testclient import TestClient
import jwt
import pytest

from app.main import Settings, create_app, load_legal
from conftest import FakeLiveKit, create_room, headers, login


def test_experimental_identity_and_hashed_sessions(lab):
    first = login(lab)
    second = login(lab)
    assert first["user"]["id"] != second["user"]["id"]
    assert first["token"] != second["token"]
    assert first["sdk"]["provider"] == "livekit"
    assert first["sdk"]["serverURL"] == "wss://furby.top"
    assert set(first["sdk"]) == {"provider", "serverURL", "userID", "expiresAt"}
    assert first["user"]["sdkUserID"] == first["user"]["id"]
    assert first["sdk"]["expiresAt"] - time.time() == pytest.approx(7 * 86400, abs=3)
    rows = lab.app.state.db.execute("SELECT token_hash FROM sessions").fetchall()
    assert all(row[0] != first["token"] for row in rows)
    assert hashlib.sha256(first["token"].encode()).hexdigest() in {row[0] for row in rows}
    refreshed = lab.client.post("/v1/auth/refresh", headers=headers(first))
    assert refreshed.json()["user"] == first["user"]


@pytest.mark.parametrize("changes,status", [
    ({"accessCode": "wrong-invitation"}, 403),
    ({"legalConsent": None}, 428),
    ({"userID": "admin"}, 422),
    ({"name": "\n"}, 422),
])
def test_login_validation(lab, changes, status):
    response = lab.client.post("/v1/auth/lab", json={"name": "Test", "accessCode": lab.settings.access_code,
        "legalConsent": lab.consent, **changes})
    assert response.status_code == status
    assert lab.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


@pytest.mark.parametrize("key,value", [("adultConfirmed", False), ("accepted", False),
    ("documentHash", "0" * 64), ("privacyVersion", "old"), ("termsVersion", "old")])
def test_legal_consent_must_match_published_document(lab, key, value):
    response = lab.client.post("/v1/auth/lab", json={"name": "Test", "accessCode": lab.settings.access_code,
        "legalConsent": {**lab.consent, key: value}})
    assert response.status_code == 428
    assert response.json()["requiredVersions"]["documentHash"] == lab.consent["documentHash"]


def test_public_legal_documents_are_complete_anonymous_and_match_consent(lab):
    response = lab.client.get("/v1/legal/documents")
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert "set-cookie" not in response.headers and not lab.client.cookies
    manifest = response.json()
    assert manifest == json.loads(lab.legal_path.read_text())
    assert {doc["id"] for doc in manifest["documents"]} == {"privacy", "terms", "sdk", "permissions"}
    canonical = json.dumps({key: value for key, value in manifest.items() if key != "documentHash"},
                           sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    assert hashlib.sha256(canonical).hexdigest() == manifest["documentHash"]
    assert lab.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    assert lab.app.state.db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
    assert lab.app.state.db.execute("SELECT COUNT(*) FROM consents").fetchone()[0] == 0
    required = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    rejected = lab.client.post("/v1/auth/lab", json={"name": "动态协议测试", "accessCode": lab.settings.access_code})
    assert rejected.status_code == 428 and rejected.json()["requiredVersions"] == required
    accepted = lab.client.post("/v1/auth/lab", json={"name": "动态协议测试", "accessCode": lab.settings.access_code,
        "legalConsent": {**required, "accepted": True, "adultConfirmed": True}})
    assert accepted.status_code == 200
    assert lab.client.get("/v1/me/legal-consent", headers=headers(accepted.json())).json()["requiresAcceptance"] is False


def test_downloaded_legal_documents_allow_an_existing_user_to_accept_current_text(lab):
    member = login(lab)
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE consents SET privacy_version='old',document_hash=?", ("0" * 64,))
    rejected = lab.client.post("/v1/auth/refresh", headers=headers(member))
    assert rejected.status_code == 428
    manifest = lab.client.get("/v1/legal/documents").json()
    required = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    assert rejected.json()["requiredVersions"] == required
    accepted = lab.client.post("/v1/me/legal-consent", headers=headers(member),
        json={"legalConsent": {**required, "accepted": True, "adultConfirmed": True}})
    assert accepted.status_code == 200 and accepted.json()["requiresAcceptance"] is False
    assert lab.client.post("/v1/auth/refresh", headers=headers(member)).status_code == 200


def test_public_legal_documents_and_required_versions_share_a_startup_snapshot(lab):
    member = login(lab)
    manifest = lab.client.get("/v1/legal/documents").json()
    lab.legal_path.write_text("{}")
    assert lab.client.get("/v1/legal/documents").json() == manifest
    status = lab.client.get("/v1/me/legal-consent", headers=headers(member)).json()
    assert status["requiredVersions"] == {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    assert status["requiresAcceptance"] is False


def test_account_isolation_and_authentication(lab):
    alice, bob = login(lab, "Alice"), login(lab, "Bob")
    assert lab.client.get("/v1/me").status_code == 401
    assert lab.client.get("/v1/me", headers={"Authorization": "Bearer " + "x" * 43}).status_code == 401
    response = lab.client.patch("/v1/me", headers=headers(alice), json={"name": "Alice2", "bio": "Hi", "avatarIndex": 5})
    assert response.json()["name"] == "Alice2"
    assert lab.client.get("/v1/me", headers=headers(bob)).json()["name"] == "Bob"
    assert lab.client.patch("/v1/me", headers=headers(alice), json={"id": bob["user"]["id"]}).status_code == 422
    lab.app.state.db.execute("UPDATE sessions SET expires_at=0 WHERE user_id=?", (alice["user"]["id"],))
    lab.app.state.db.commit()
    assert lab.client.post("/v1/auth/refresh", headers=headers(alice)).status_code == 401


def test_real_room_lifecycle_no_ghosts_and_host_permissions(lab):
    owner, member = login(lab, "Owner"), login(lab, "Member")
    assert lab.client.get("/v1/rooms", headers=headers(owner)).json() == {"rooms": []}
    room = create_room(lab, owner)
    room_id = room["id"]
    assert room_id in lab.rtc.rooms
    assert room["hostID"] == owner["user"]["sdkUserID"]
    assert room["status"] == "live" and room["isCreatedByMe"]
    lab.rtc.rooms[room_id] = {owner["user"]["id"], member["user"]["id"]}
    listed = lab.client.get("/v1/rooms", headers=headers(member)).json()["rooms"]
    assert listed[0]["audience"] == 2 and not listed[0]["isCreatedByMe"]
    assert lab.client.patch("/v1/rooms/" + room_id, headers=headers(member), json={"status": "closed"}).status_code == 403
    response = lab.client.patch("/v1/rooms/" + room_id, headers=headers(owner), json={"status": "closed"})
    assert response.status_code == 200 and response.json()["status"] == "ended"
    assert room_id not in lab.rtc.rooms
    assert lab.client.get("/v1/rooms", headers=headers(member)).json()["rooms"] == []
    assert lab.client.post(f"/v1/rooms/{room_id}/token", headers=headers(member)).status_code == 409
    assert lab.client.patch("/v1/rooms/" + room_id, headers=headers(owner), json={"status": "active"}).status_code == 409


def test_disappeared_livekit_room_is_never_advertised_or_recreated(lab):
    account = login(lab)
    room = create_room(lab, account)
    lab.rtc.rooms.pop(room["id"])
    assert lab.client.get("/v1/rooms", headers=headers(account)).json()["rooms"] == []
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(account)).status_code == 409
    assert not lab.rtc.rooms


def test_mic_only_tokens_are_identity_and_room_scoped(lab):
    owner, member = login(lab, "Owner"), login(lab, "Member")
    room = create_room(lab, owner)
    response = lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(member))
    assert response.status_code == 200, response.text
    claims = jwt.decode(response.json()["participantToken"], lab.settings.api_secret, algorithms=["HS256"])
    assert claims["sub"] == member["user"]["id"]
    assert claims["iss"] == lab.settings.api_key
    assert claims["exp"] - claims["nbf"] == 300
    grant = claims["video"]
    assert grant["room"] == room["id"] and grant["roomJoin"]
    assert grant["canPublishSources"] == ["microphone"]
    assert grant["canPublishData"] and grant["canSubscribe"] and not grant["canPublish"]
    assert not grant.get("roomAdmin") and not grant.get("roomCreate")
    assert grant["canUpdateOwnMetadata"] is False
    assert json.loads(claims["metadata"])["host"] is False
    host_response = lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(owner))
    host_claims = jwt.decode(host_response.json()["participantToken"], lab.settings.api_secret, algorithms=["HS256"])
    assert json.loads(host_claims["metadata"])["host"] is True
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(member), json={"identity": owner["user"]["id"]}).status_code == 422
    assert lab.client.post('/v1/rooms/arbitrary/token', headers=headers(member)).status_code == 404
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token').status_code == 401


def test_room_capacity_and_video_rejection(lab):
    owner, outsider = login(lab), login(lab)
    assert lab.client.post("/v1/rooms", headers=headers(owner), json={"title": "Video", "category": "闲聊", "theme": 0, "isLive": True}).status_code == 422
    room = create_room(lab, owner)
    lab.rtc.rooms[room["id"]] = {owner["user"]["id"], *[f"member{i}" for i in range(99)]}
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(outsider)).status_code == 409
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(owner)).status_code == 200


def test_create_failure_compensates_even_if_remote_creation_succeeded(lab):
    account = login(lab)
    lab.rtc.create_failure = True
    response = lab.client.post("/v1/rooms", headers=headers(account), json={"title": "Test", "category": "闲聊", "theme": 0, "isLive": False})
    assert response.status_code == 503
    assert not lab.rtc.rooms
    assert lab.app.state.db.execute("SELECT status FROM rooms").fetchone()[0] == "closed"


def test_failed_compensation_is_retried_and_never_listed(lab):
    account = login(lab)
    lab.rtc.create_failure = lab.rtc.delete_failure = True
    response = lab.client.post("/v1/rooms", headers=headers(account), json={"title": "Test", "category": "闲聊", "theme": 0, "isLive": False})
    assert response.status_code == 503
    room_id = next(iter(lab.rtc.rooms))
    assert lab.app.state.db.execute("SELECT status FROM rooms").fetchone()[0] == "closing"
    assert lab.client.get("/v1/rooms", headers=headers(account)).json()["rooms"] == []
    assert lab.client.post(f"/v1/rooms/{room_id}/token", headers=headers(account)).status_code == 409
    lab.rtc.delete_failure = False
    assert lab.client.get("/v1/rooms", headers=headers(account)).json()["rooms"] == []
    assert not lab.rtc.rooms


def test_failed_close_denies_tokens_and_can_be_retried(lab):
    account = login(lab)
    room = create_room(lab, account)
    lab.rtc.delete_failure = True
    path = f'/v1/rooms/{room["id"]}'
    assert lab.client.patch(path, headers=headers(account), json={"status": "closed"}).status_code == 503
    assert lab.client.post(path + "/token", headers=headers(account)).status_code == 409
    lab.rtc.delete_failure = False
    assert lab.client.patch(path, headers=headers(account), json={"status": "closed"}).status_code == 200
    assert not lab.rtc.rooms


def test_library_is_per_user_and_retains_ended_rooms_without_live_status(lab):
    owner, member = login(lab), login(lab)
    room = create_room(lab, owner)
    room_id = room["id"]
    assert lab.client.put(f"/v1/favorites/{room_id}", headers=headers(member)).status_code == 200
    assert lab.client.post(f"/v1/history/{room_id}", headers=headers(member)).status_code == 200
    library = lab.client.get("/v1/library", headers=headers(member)).json()
    assert len(library["favorites"]) == len(library["recents"]) == 1 and library["created"] == []
    owner_library = lab.client.get("/v1/library", headers=headers(owner)).json()
    assert not owner_library["favorites"] and len(owner_library["created"]) == 1
    assert lab.client.post("/v1/rooms/lookup", headers=headers(member), json={"ids": [room_id, "missing"]}).json()["rooms"][0]["id"] == room_id
    lab.rtc.rooms.pop(room_id)
    historical = lab.client.get("/v1/library", headers=headers(member)).json()
    assert historical["created"] == []
    assert historical["favorites"][0]["id"] == historical["recents"][0]["id"] == room_id
    assert historical["favorites"][0]["status"] == historical["recents"][0]["status"] == "ended"
    assert historical["recents"][0]["audience"] == 0
    assert lab.client.get("/v1/library",headers=headers(owner)).json()["created"][0]["status"] == "ended"
    assert lab.client.put(f"/v1/favorites/{room_id}",headers=headers(member)).status_code == 409
    assert lab.client.delete(f"/v1/favorites/{room_id}", headers=headers(member)).status_code == 200


def test_withdrawal_revokes_only_own_membership(lab):
    owner, member = login(lab), login(lab)
    room = create_room(lab, owner)
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(member)).status_code == 200
    status = lab.client.get("/v1/me/legal-consent", headers=headers(member)).json()
    assert not status["requiresAcceptance"] and status["legalConsent"]["acceptedAt"]
    response = lab.client.delete("/v1/me/legal-consent", headers=headers(member))
    assert response.status_code == 200
    assert room["id"] in lab.rtc.rooms
    assert lab.client.post("/v1/auth/refresh", headers=headers(member)).status_code == 401
    assert lab.client.post("/v1/me/legal-consent", headers=headers(member), json={"legalConsent": lab.consent}).status_code == 401
    assert lab.client.delete("/v1/me/legal-consent", headers=headers(member)).status_code == 200
    assert lab.app.state.db.execute("SELECT withdrawn_at FROM consents WHERE user_id=?", (member["user"]["id"],)).fetchone()[0]


@pytest.mark.parametrize("route,method", [("/v1/auth/logout", "post"), ("/v1/account", "delete"), ("/v1/me/legal-consent", "delete")])
def test_session_end_failure_revokes_first_and_allows_safe_retry(lab, route, method):
    account = login(lab)
    room = create_room(lab, account)
    lab.rtc.delete_failure = True
    assert getattr(lab.client, method)(route, headers=headers(account)).status_code == 503
    assert lab.client.get("/v1/me", headers=headers(account)).status_code == 401
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(account)).status_code == 401
    lab.rtc.delete_failure = False
    assert getattr(lab.client, method)(route, headers=headers(account)).status_code == 200
    assert not lab.rtc.rooms


def test_legal_manifest_rejects_tampering(lab):
    manifest = json.loads(lab.legal_path.read_text())
    manifest["documents"][0]["title"] = "Tampered"
    lab.legal_path.write_text(json.dumps(manifest))
    with pytest.raises(RuntimeError, match="manifest"):
        load_legal(lab.legal_path)


@pytest.mark.parametrize("damage", ["invalid-json", "tampered", "missing-document", "duplicate-document", "empty-paragraph"])
def test_server_refuses_damaged_legal_documents_at_startup(lab, tmp_path, damage):
    manifest = json.loads(lab.legal_path.read_text())
    if damage == "tampered":
        manifest["documents"][0]["title"] += "篡改"
    elif damage == "missing-document":
        manifest["documents"].pop()
    elif damage == "duplicate-document":
        manifest["documents"][-1] = manifest["documents"][0]
    elif damage == "empty-paragraph":
        manifest["documents"][0]["sections"][0]["paragraphs"] = ["  "]
    if damage not in {"invalid-json", "tampered"}:
        manifest["documentHash"] = hashlib.sha256(json.dumps(
            {key: value for key, value in manifest.items() if key != "documentHash"},
            sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
    path = tmp_path / "damaged-legal.json"
    path.write_text("not-json" if damage == "invalid-json" else json.dumps(manifest, ensure_ascii=False))
    settings = replace(lab.settings, db_path=str(tmp_path / "damaged.sqlite3"), legal_path=str(path))
    with pytest.raises(RuntimeError, match="manifest"):
        with TestClient(create_app(settings, FakeLiveKit(settings))):
            pass


def test_expired_backend_session_removes_only_own_membership(lab):
    owner, member = login(lab), login(lab)
    room = create_room(lab, owner)
    lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(member))
    lab.app.state.db.execute("UPDATE sessions SET expires_at=0 WHERE user_id=?", (member["user"]["id"],))
    lab.app.state.db.commit()
    assert len(lab.client.get("/v1/rooms", headers=headers(owner)).json()["rooms"]) == 1
    assert room["id"] in lab.rtc.rooms
    assert (room["id"], member["user"]["id"]) in lab.rtc.removed


def test_revoked_bearer_only_retries_original_operation(lab):
    account = login(lab)
    assert lab.client.post("/v1/auth/logout", headers=headers(account)).status_code == 200
    assert lab.client.post("/v1/auth/logout", headers=headers(account)).status_code == 200
    assert lab.client.delete("/v1/account", headers=headers(account)).status_code == 401


@pytest.mark.parametrize("route,method", [("/v1/auth/logout", "post"), ("/v1/account", "delete"),
                                         ("/v1/me/legal-consent", "delete")])
def test_expired_verifiable_bearer_can_only_terminate_and_retry(lab, route, method):
    account = login(lab)
    # Even a very late rights request remains possible; no session renewal or ordinary
    # access is allowed. Each laboratory login has a different immutable account ID.
    lab.app.state.db.execute("UPDATE sessions SET expires_at=? WHERE user_id=?",
                            (int(time.time()) - 366 * 86400, account["user"]["id"]))
    lab.app.state.db.commit()
    assert lab.client.post("/v1/auth/refresh", headers=headers(account)).status_code == 401
    assert lab.client.get("/v1/me", headers=headers(account)).status_code == 401
    assert lab.client.post("/v1/me/legal-consent", headers=headers(account),
                           json={"legalConsent": lab.consent}).status_code == 401
    assert getattr(lab.client, method)(route, headers=headers(account)).status_code == 200
    assert getattr(lab.client, method)(route, headers=headers(account)).status_code == 200
    assert lab.client.post("/v1/auth/refresh", headers=headers(account)).status_code == 401
    assert getattr(lab.client, method)(route, headers={"Authorization": "Bearer " + "z" * 43}).status_code == 401


def test_pending_deletion_completes_after_bearer_is_discarded(lab):
    account, observer = login(lab, "Delete me"), login(lab)
    room = create_room(lab, account)
    lab.client.put(f'/v1/favorites/{room["id"]}', headers=headers(account))
    lab.client.post(f'/v1/history/{room["id"]}', headers=headers(account))
    lab.rtc.delete_failure = True
    assert lab.client.delete("/v1/account", headers=headers(account)).status_code == 503
    db, user_id = lab.app.state.db, account["user"]["id"]
    assert db.execute("SELECT completed_at FROM deletion_requests WHERE user_id=?", (user_id,)).fetchone()[0] is None
    assert db.execute("SELECT deleted FROM users WHERE id=?", (user_id,)).fetchone()[0] == 0
    # The client loses its credential on 401. Independent maintenance/synchronization
    # must finish the durable request without any more request from this account.
    assert lab.client.post("/v1/auth/refresh", headers=headers(account)).status_code == 401
    del account["token"]
    lab.rtc.delete_failure = False
    assert lab.client.get("/v1/rooms", headers=headers(observer)).status_code == 200
    assert not lab.rtc.rooms
    user = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    assert user["deleted"] == 1 and user["name"] == "已注销" and user["bio"] == ""
    assert db.execute("SELECT completed_at FROM deletion_requests WHERE user_id=?", (user_id,)).fetchone()[0]
    assert db.execute("SELECT COUNT(*) FROM favorites WHERE user_id=?", (user_id,)).fetchone()[0] == 0
    assert db.execute("SELECT COUNT(*) FROM history WHERE user_id=?", (user_id,)).fetchone()[0] == 0


def test_restart_finishes_durable_and_legacy_pending_deletion(lab):
    current, legacy = login(lab, "Current"), login(lab, "Legacy")
    current_room = create_room(lab, current)
    legacy_room = create_room(lab, legacy)
    lab.rtc.delete_failure = True
    assert lab.client.delete("/v1/account", headers=headers(current)).status_code == 503
    # Simulate the earlier build: revoked session recorded before DeleteRoom failed,
    # without a deletion_requests row and with the RTC room still marked active.
    lab.app.state.db.execute("UPDATE sessions SET revoked_at=?,revoked_reason='deleted' WHERE user_id=?",
                            (int(time.time()), legacy["user"]["id"]))
    lab.app.state.db.commit()
    lab.rtc.delete_failure = False
    restarted_app = create_app(lab.settings, lab.rtc)
    with TestClient(restarted_app):
        assert current_room["id"] not in lab.rtc.rooms and legacy_room["id"] not in lab.rtc.rooms
        for account in (current, legacy):
            user_id = account["user"]["id"]
            assert restarted_app.state.db.execute("SELECT deleted FROM users WHERE id=?", (user_id,)).fetchone()[0] == 1
            assert restarted_app.state.db.execute("SELECT completed_at FROM deletion_requests WHERE user_id=?", (user_id,)).fetchone()[0]


def test_startup_recovers_interrupted_room_creation(lab):
    owner = login(lab)
    room_id = "lk_interrupted"
    lab.app.state.db.execute("INSERT INTO rooms VALUES(?,?,?,?,?,'creating',?)", (
        room_id, owner["user"]["id"], "Interrupted", "闲聊", 0, int(time.time())))
    lab.app.state.db.commit()
    lab.rtc.rooms[room_id] = set()
    with TestClient(create_app(lab.settings, lab.rtc)) as restarted:
        assert room_id not in lab.rtc.rooms
        assert restarted.get("/v1/rooms", headers=headers(owner)).json()["rooms"] == []


def test_health_uses_real_connectivity_and_never_exposes_config(lab):
    assert lab.client.get("/health").json()["rtcConfigured"]
    lab.rtc.unavailable = True
    response = lab.client.get("/health")
    assert response.status_code == 503 and response.json()["rtcConfigured"] is False
    assert lab.settings.api_secret not in response.text


def test_unsupported_features_body_limit_and_rate_limiting(lab):
    account = login(lab)
    assert lab.client.get("/v1/gifts/catalog", headers=headers(account)).status_code == 200
    assert lab.client.post("/v1/me/avatar", headers=headers(account), content=b"image").status_code == 501
    assert lab.client.post("/v1/auth/lab", content=b"x" * 16385).status_code == 413
    assert lab.client.post("/v1/auth/lab", content=b"{}", headers={"content-length": "20000"}).status_code == 413
    settings = replace(lab.settings, rate_limit_enabled=True)
    with TestClient(create_app(settings, FakeLiveKit(settings))) as client:
        for i in range(10):
            response = client.post("/v1/auth/lab", json={"name": "Test", "accessCode": "wrong"})
            assert response.status_code == 403
        assert client.post("/v1/auth/lab", json={"name": "Test", "accessCode": "wrong"}).status_code == 429
        # The untrusted peer cannot change its limiting bucket with spoofed proxy headers.
        assert client.post("/v1/auth/lab", headers={"X-Real-IP": "1.2.3.4"}, json={"name": "Test", "accessCode": "wrong"}).status_code == 429
