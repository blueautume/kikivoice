import base64
import hashlib
import hmac
from io import BytesIO
import json
from pathlib import Path
import sqlite3
import stat
import time
from urllib.parse import urlsplit
import zlib

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import LEGAL_DOCUMENTS_PATH, SCHEMA, Settings, create_app, load_legal_requirements
from app.usersig import generate_user_sig
from conftest import apple_settings, apple_payload

TEST_KEY = "a" * 64


def current_legal_consent():
    return {**load_legal_requirements(), "accepted": True, "adultConfirmed": True}


@pytest.fixture
def client(tmp_path, fake_apple):
    settings = apple_settings(Settings(str(tmp_path / "test.sqlite3"), 1234567890, TEST_KEY, False))
    with TestClient(create_app(settings)) as test_client:
        test_client.settings = settings
        test_client.fake_apple = fake_apple
        yield test_client


def login(client, name="alice", secret="1" * 64, complete_nickname=True):
    response = client.post("/v1/auth/apple", json=apple_payload(client, name))
    assert response.status_code == 200
    result = response.json()
    if complete_nickname and result["user"]["needsNickname"]:
        updated = client.patch("/v1/me", headers=authorization(result), json={"name": name[:16]})
        assert updated.status_code == 200
        result["user"] = updated.json()
    return result


def authorization(result):
    return {"Authorization": "Bearer " + result["token"]}


def create_room(client, headers, suffix="", live=False):
    response = client.post("/v1/rooms", headers=headers,
                           json={"title": "真实测试房间" + suffix, "category": "随心聊", "isLive": live, "theme": 2})
    assert response.status_code == 200
    return response.json()


def jpeg_bytes(size=(320, 240), color="red", with_metadata=False):
    image = Image.new("RGB", size, color)
    result = BytesIO()
    exif = Image.Exif()
    if with_metadata:
        exif[315] = "private artist metadata"
        exif[270] = "private location metadata"
        exif[274] = 6
    image.save(result, "JPEG", exif=exif)
    return result.getvalue()


def upload_avatar(client, headers, content=None):
    return client.post("/v1/me/avatar", headers={**headers, "Content-Type": "image/jpeg"},
                       content=jpeg_bytes() if content is None else content)


def test_usersig_matches_protocol():
    signature = generate_user_sig(123, TEST_KEY, "test_user", 600, now=1700000000)
    raw = base64.b64decode(signature.translate(str.maketrans("*-_", "+/=")))
    payload = json.loads(zlib.decompress(raw))
    assert payload == {"TLS.ver": "2.0", "TLS.identifier": "test_user", "TLS.sdkappid": 123,
                       "TLS.expire": 600, "TLS.time": 1700000000,
                       "TLS.sig": base64.b64encode(hmac.new(TEST_KEY.encode(),
                           b"TLS.identifier:test_user\nTLS.sdkappid:123\nTLS.time:1700000000\nTLS.expire:600\n",
                           hashlib.sha256).digest()).decode()}


def test_apple_subject_stable_and_legacy_login_removed(client):
    first = login(client)
    again = login(client, secret="2" * 64)
    assert first["user"]["sdkUserID"] == again["user"]["sdkUserID"]
    assert first["token"] != again["token"]
    assert client.post("/v1/auth/id", json={"userID": "alice", "deviceSecret": "1" * 64}).status_code == 404
    assert first["user"]["id"] != "alice"
    with sqlite3.connect(client.settings.db_path) as db:
        stored = " ".join(str(row) for row in db.execute("SELECT * FROM sessions"))
        assert first["token"] not in stored
        credentials = " ".join(str(row) for row in db.execute("SELECT * FROM apple_credentials"))
        assert "refresh-" not in credentials and "not-stored" not in credentials


def test_removed_gift_and_currency_routes_are_absent_and_new_accounts_create_no_wallets(client):
    session = login(client)
    headers = authorization(session)
    room = create_room(client, headers)
    media_hash = "a" * 64
    for method, path in [
        ("GET", "/v1/gifts/catalog"), ("GET", "/v1/me/wallet"),
        ("GET", f"/v1/rooms/{room['id']}/gifts"),
        ("POST", f"/v1/rooms/{room['id']}/gifts"),
        ("POST", f"/v1/rooms/{room['id']}/gifts/batch"),
        ("GET", f"/v1/gift-media/{media_hash}.mov"),
        ("GET", f"/v1/gift-media/{media_hash}.png"),
        ("POST", "/v1/internal/qa/login"),
    ]:
        assert client.request(method, path, headers=headers).status_code == 404
    paths = client.app.openapi()["paths"]
    assert not any(term in path for path in paths for term in ("gift", "wallet", "diamond"))
    with sqlite3.connect(client.settings.db_path) as db:
        names = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type IN ('table','index')")}
        assert not any(term in name for name in names for term in ("gift", "wallet", "diamond"))
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 1


def test_auth_refresh_logout_and_expiration(client):
    result = login(client)
    headers = authorization(result)
    assert client.get("/v1/me").status_code == 401
    assert client.get("/v1/me", headers={"Authorization": "Bearer fake"}).status_code == 401
    refreshed = client.post("/v1/auth/refresh", headers=headers)
    assert refreshed.status_code == 200
    assert refreshed.json()["sdk"]["userID"] == result["user"]["sdkUserID"]
    assert client.get("/v1/me", headers=headers).status_code == 200
    assert client.post("/v1/auth/logout", headers=headers).status_code == 200
    assert client.get("/v1/me", headers=headers).status_code == 401
    latest = login(client)
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE sessions SET expires_at=1")
    assert client.get("/v1/me", headers=authorization(latest)).status_code == 401


def test_profile_owned_rooms_and_other_account_isolation(client):
    alice = login(client)
    bob = login(client, "bob", "2" * 64)
    a, b = authorization(alice), authorization(bob)
    room = create_room(client, a)
    assert room["id"].startswith("voice_kiki_")
    assert room["status"] == "draft" and room["audience"] == 0
    assert room["hostID"] == alice["user"]["sdkUserID"]
    updated = client.patch("/v1/me", headers=a, json={"name": "新昵称", "bio": "新简介", "avatarIndex": 11,
                                                     "notificationsEnabled": False})
    assert updated.json()["name"] == "新昵称"
    assert client.get("/v1/me", headers=b).json()["name"] == "bob"
    shared_room = client.get("/v1/rooms/" + room["id"], headers=b).json()
    assert shared_room["host"] == "新昵称" and not shared_room["isCreatedByMe"]
    assert shared_room["hostAvatarIndex"] == 11
    assert client.patch("/v1/rooms/" + room["id"], headers=b, json={"status": "live"}).status_code == 403
    assert client.patch("/v1/rooms/" + room["id"], headers=a, json={"status": "live"}).json()["status"] == "live"
    assert client.patch("/v1/rooms/" + room["id"], headers=a, json={"status": "ended"}).status_code == 200
    assert client.patch("/v1/rooms/" + room["id"], headers=a, json={"status": "live"}).status_code == 409
    assert client.get("/v1/library", headers=b).json() == {"favorites": [], "recents": [], "created": []}


def test_library_history_deduplicated_latest_twenty(client):
    a = authorization(login(client))
    b = authorization(login(client, "bob", "2" * 64))
    rooms = [create_room(client, a, str(index)) for index in range(22)]
    for room in rooms:
        assert client.post("/v1/history/" + room["id"], headers=b).status_code == 200
    assert client.post("/v1/history/" + rooms[-2]["id"], headers=b).status_code == 200
    assert client.put("/v1/favorites/" + rooms[0]["id"], headers=b).status_code == 200
    assert client.put("/v1/favorites/" + rooms[0]["id"], headers=b).status_code == 200
    library = client.get("/v1/library", headers=b).json()
    assert len(library["recents"]) == 20
    assert library["recents"][0]["id"] == rooms[-2]["id"]
    assert len({r["id"] for r in library["recents"]}) == 20
    assert len(library["favorites"]) == 1
    assert client.delete("/v1/favorites/" + rooms[0]["id"], headers=b).status_code == 200
    assert not client.get("/v1/library", headers=b).json()["favorites"]
    assert client.put("/v1/favorites/missing", headers=b).status_code == 404
    assert client.post("/v1/history/missing", headers=b).status_code == 404


def test_delete_account_revokes_every_session_and_identity(client):
    first = login(client)
    other_session = login(client)
    a = authorization(first)
    room = create_room(client, a, live=True)
    assert room["id"].startswith("live_kiki_")
    assert client.delete("/v1/account", headers=a).status_code == 200
    assert client.get("/v1/me", headers=authorization(other_session)).status_code == 401
    recreated = login(client, secret="3" * 64)
    assert recreated["user"]["sdkUserID"] != first["user"]["sdkUserID"]
    old = client.get("/v1/rooms/" + room["id"], headers=authorization(recreated)).json()
    assert old["status"] == "ended" and not old["isCreatedByMe"]
    assert old["host"] == "已注销用户"
    assert old["hostID"] == "anonymous" and old["title"] == "已结束的房间" and old["category"] == "其他"


@pytest.mark.parametrize("changes", [
    {"challengeID": "bad"}, {"identityToken": "short"}, {"authorizationCode": ""}, {"admin": True},
])
def test_login_validation(client, changes):
    payload = {**apple_payload(client), **changes}
    response = client.post("/v1/auth/apple", json=payload)
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)


def test_profile_and_room_validation(client):
    headers = authorization(login(client))
    for body in ({"avatarIndex": 12}, {"name": "   "}, {"notificationsEnabled": "yes"}, {"name": "bad\nname"}):
        assert client.patch("/v1/me", headers=headers, json=body).status_code == 422
    assert client.post("/v1/rooms", headers=headers,
                       json={"title": "", "category": "随心聊", "isLive": False, "theme": 0}).status_code == 422
    assert client.post("/v1/auth/apple", content=b"x" * 20000).status_code == 413
    response = client.get("/health")
    assert response.json() == {"status": "ok", "rtcConfigured": True}
    assert response.headers["Cache-Control"] == "no-store"


def test_multiline_bio_normalizes_newlines_and_rejects_other_controls(client):
    headers = authorization(login(client))
    updated = client.patch("/v1/me", headers=headers,
                           json={"bio": "第一行中文\r\n第二行中文\r第三行中文\n第四行中文"})
    assert updated.status_code == 200
    expected = "第一行中文\n第二行中文\n第三行中文\n第四行中文"
    assert updated.json()["bio"] == expected
    assert client.get("/v1/me", headers=headers).json()["bio"] == expected
    for forbidden in ("\t", "\x00", "\x1f", "\x7f"):
        assert client.patch("/v1/me", headers=headers,
                            json={"bio": "中文" + forbidden + "简介"}).status_code == 422
    assert client.patch("/v1/me", headers=headers, json={"name": "中文\n昵称"}).status_code == 422
    assert client.post("/v1/rooms", headers=headers,
                       json={"title": "中文\n房间", "category": "随心聊", "isLive": False, "theme": 0}).status_code == 422


def test_room_title_sdk_utf8_byte_limit(client):
    headers = authorization(login(client))
    payload = {"title": "中" * 36, "category": "随心聊", "isLive": False, "theme": 0}
    assert client.post("/v1/rooms", headers=headers, json=payload).status_code == 422
    payload["title"] = "中" * 30
    response = client.post("/v1/rooms", headers=headers, json=payload)
    assert response.status_code == 200
    assert response.json()["title"] == "中" * 30


def test_repeat_favorite_at_capacity_succeeds_and_new_favorite_is_rejected(client):
    headers = authorization(login(client))
    room = create_room(client, headers)
    with sqlite3.connect(client.settings.db_path) as db:
        account_id = db.execute("SELECT account_id FROM accounts").fetchone()[0]
        db.execute("INSERT INTO favorites VALUES(?,?,?)", (account_id, room["id"], 0))
        for index in range(1, 500):
            extra_id = "capacity_" + str(index)
            db.execute("""INSERT INTO rooms(id,owner_id,host_id,host_name,host_avatar_index,
                          title,category,is_live,theme,status,created_at)
                          SELECT ?,owner_id,host_id,host_name,host_avatar_index,title,
                          category,is_live,theme,status,created_at FROM rooms WHERE id=?""",
                       (extra_id, room["id"]))
            db.execute("INSERT INTO favorites VALUES(?,?,?)", (account_id, extra_id, index))
    assert client.put("/v1/favorites/" + room["id"], headers=headers).status_code == 200
    next_room = create_room(client, headers, "第501个收藏")
    assert client.put("/v1/favorites/" + next_room["id"], headers=headers).status_code == 409
    assert len(client.get("/v1/library", headers=headers).json()["favorites"]) == 500


def test_lookup_finds_old_live_metadata_after_recent_registry_limit(client):
    owner = authorization(login(client))
    viewer = authorization(login(client, "viewer", "2" * 64))
    old_room = create_room(client, owner, "仍然在线")
    client.patch("/v1/rooms/" + old_room["id"], headers=owner, json={"status": "live"})
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE rooms SET created_at=1 WHERE id=?", (old_room["id"],))
        for index in range(500):
            db.execute("""INSERT INTO rooms(id,owner_id,host_id,host_name,host_avatar_index,
                          title,category,is_live,theme,status,created_at)
                          SELECT ?,owner_id,host_id,host_name,host_avatar_index,title,
                          category,is_live,theme,?,? FROM rooms WHERE id=?""",
                       ("archived_" + str(index), "ended" if index % 2 else "draft", index + 2, old_room["id"]))
    recent = client.get("/v1/rooms", headers=viewer).json()["rooms"]
    assert len(recent) == 500 and old_room["id"] not in {room["id"] for room in recent}
    requested = [old_room["id"], "archived_42", old_room["id"], "missing", "' OR 1=1 --"]
    response = client.post("/v1/rooms/lookup", headers=viewer, json={"ids": requested})
    assert response.status_code == 200
    rooms = response.json()["rooms"]
    assert [room["id"] for room in rooms] == [old_room["id"], "archived_42"]
    assert rooms[0]["title"] == old_room["title"] and rooms[0]["status"] == "live"
    assert all(not room["isCreatedByMe"] for room in rooms)
    own = client.post("/v1/rooms/lookup", headers=owner, json={"ids": [old_room["id"]]}).json()["rooms"]
    assert own[0]["isCreatedByMe"]
    hundred = ["archived_" + str(index) for index in range(100)]
    assert len(client.post("/v1/rooms/lookup", headers=viewer, json={"ids": hundred}).json()["rooms"]) == 100


def test_lookup_empty_input_authentication_and_limit(client):
    headers = authorization(login(client))
    assert client.post("/v1/rooms/lookup", json={"ids": []}).status_code == 401
    assert client.post("/v1/rooms/lookup", headers=headers, json={"ids": []}).json() == {"rooms": []}
    assert client.post("/v1/rooms/lookup", headers=headers, json={"ids": ["missing"] * 100}).json() == {"rooms": []}
    assert client.post("/v1/rooms/lookup", headers=headers, json={"ids": ["missing"] * 101}).status_code == 422
    assert client.post("/v1/rooms/lookup", headers=headers, json={"ids": "invalid"}).status_code == 422


def test_auth_rate_limit(tmp_path, fake_apple):
    settings = apple_settings(Settings(str(tmp_path / "limit.sqlite3"), 123, TEST_KEY, True))
    with TestClient(create_app(settings)) as client:
        client.fake_apple = fake_apple
        for _ in range(12):
            assert client.post("/v1/auth/apple", json=apple_payload(client)).status_code == 200
        assert client.post("/v1/auth/apple", json=apple_payload(client)).status_code == 429


def test_first_login_requires_explicit_valid_nickname_before_room_use(client):
    result = login(client, complete_nickname=False)
    headers = authorization(result)
    assert result["user"]["needsNickname"] is True
    assert result["user"]["avatarURL"] is None
    assert client.post("/v1/auth/refresh", headers=headers).json()["user"]["needsNickname"] is True
    payload = {"title": "尚未设置昵称", "category": "随心聊", "isLive": False, "theme": 0}
    assert client.post("/v1/rooms", headers=headers, json=payload).status_code == 409
    assert client.post("/v1/history/missing", headers=headers).status_code == 409
    # Other profile edits and malformed nicknames cannot bypass onboarding.
    assert client.patch("/v1/me", headers=headers, json={"bio": "只有简介", "avatarIndex": 2}).json()["needsNickname"] is True
    for nickname in ("", "   ", "不合法\n昵称", "中" * 17):
        assert client.patch("/v1/me", headers=headers, json={"name": nickname}).status_code == 422
    accepted = client.patch("/v1/me", headers=headers, json={"name": "  小柒  "})
    assert accepted.status_code == 200
    assert accepted.json()["name"] == "小柒" and accepted.json()["needsNickname"] is False
    room = create_room(client, headers)
    assert room["host"] == "小柒"
    assert client.post("/v1/history/" + room["id"], headers=headers).status_code == 200
    assert login(client, complete_nickname=False)["user"]["needsNickname"] is False


def test_avatar_upload_sanitizes_metadata_serves_publicly_and_syncs_rooms(client):
    owner = authorization(login(client))
    other = authorization(login(client, "viewer", "2" * 64))
    room = create_room(client, owner)
    uploaded = upload_avatar(client, owner, jpeg_bytes(with_metadata=True))
    assert uploaded.status_code == 200
    user = uploaded.json()
    assert user["avatarURL"].startswith("https://kiki.group/v1/avatars/")
    public_path = urlsplit(user["avatarURL"]).path
    stored_path = client.settings.avatar_path / Path(public_path).name
    assert stat.S_IMODE(stored_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(client.settings.avatar_path.stat().st_mode) == 0o700
    public_image = client.get(public_path)
    assert public_image.status_code == 200
    assert public_image.headers["Content-Type"] == "image/jpeg"
    assert public_image.headers["X-Content-Type-Options"] == "nosniff"
    with Image.open(BytesIO(public_image.content)) as decoded:
        assert decoded.format == "JPEG" and decoded.size == (512, 512)
        assert not decoded.getexif()
        assert "exif" not in decoded.info and "icc_profile" not in decoded.info
    assert b"private" not in public_image.content
    assert client.get("/v1/me", headers=owner).json()["avatarURL"] == user["avatarURL"]
    assert client.get("/v1/me", headers=other).json()["avatarURL"] is None
    shared = client.get("/v1/rooms/" + room["id"], headers=other).json()
    assert shared["hostAvatarURL"] == user["avatarURL"]
    assert create_room(client, owner)["hostAvatarURL"] == user["avatarURL"]
    assert client.post("/v1/auth/refresh", headers=owner).json()["user"]["avatarURL"] == user["avatarURL"]


def test_configured_public_origin_ignores_request_host_and_proxy_headers(tmp_path, monkeypatch, fake_apple):
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "origin.sqlite3"))
    monkeypatch.setenv("AVATAR_DIRECTORY", str(tmp_path / "avatars"))
    monkeypatch.setenv("SDKAPPID", "1234567890")
    monkeypatch.setenv("SECRETKEY", TEST_KEY)
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://media.example.test/")
    settings = apple_settings(Settings.from_environment())
    with TestClient(create_app(settings), base_url="https://untrusted.example.test") as configured:
        configured.fake_apple = fake_apple
        headers = {**authorization(login(configured)), "Host": "spoofed.example.test",
                   "X-Forwarded-Host": "forwarded.example.test", "X-Forwarded-Proto": "http"}
        uploaded = upload_avatar(configured, headers)
        assert uploaded.status_code == 200
        avatar = uploaded.json()["avatarURL"]
        assert avatar.startswith("https://media.example.test/v1/avatars/")
        assert configured.get("/v1/me", headers=headers).json()["avatarURL"] == avatar
        assert create_room(configured, headers)["hostAvatarURL"] == avatar
        assert configured.get(urlsplit(avatar).path).status_code == 200


def test_avatar_replacement_preset_and_account_deletion_remove_old_files(client):
    headers = authorization(login(client))
    room = create_room(client, headers)
    first = upload_avatar(client, headers).json()["avatarURL"]
    second = upload_avatar(client, headers, jpeg_bytes(color="blue")).json()["avatarURL"]
    assert first != second
    assert client.get(urlsplit(first).path).status_code == 404
    assert client.get(urlsplit(second).path).status_code == 200
    assert len(list(client.settings.avatar_path.iterdir())) == 1
    changed = client.patch("/v1/me", headers=headers, json={"avatarIndex": 7}).json()
    assert changed["avatarIndex"] == 7 and changed["avatarURL"] is None
    assert client.get(urlsplit(second).path).status_code == 404
    assert not list(client.settings.avatar_path.iterdir())
    assert client.get("/v1/rooms/" + room["id"], headers=headers).json()["hostAvatarURL"] is None
    third = upload_avatar(client, headers).json()["avatarURL"]
    assert client.delete("/v1/account", headers=headers).status_code == 200
    assert client.get(urlsplit(third).path).status_code == 404
    assert not list(client.settings.avatar_path.iterdir())
    another = authorization(login(client, "viewer", "2" * 64))
    old = client.get("/v1/rooms/" + room["id"], headers=another).json()
    assert old["hostAvatarURL"] is None and old["host"] == "已注销用户"


def test_avatar_validation_authentication_size_and_path_boundaries(client):
    headers = authorization(login(client))
    assert upload_avatar(client, {}).status_code == 401
    assert upload_avatar(client, {"Authorization": "Bearer expired"}).status_code == 401
    assert client.post("/v1/me/avatar", headers=headers, content=jpeg_bytes()).status_code == 415
    assert upload_avatar(client, headers, b"not actually a JPEG").status_code == 422
    png = BytesIO()
    Image.new("RGB", (128, 128)).save(png, "PNG")
    assert upload_avatar(client, headers, png.getvalue()).status_code == 415
    assert upload_avatar(client, headers, jpeg_bytes((32, 128))).status_code == 422
    assert upload_avatar(client, headers, jpeg_bytes((8200, 64))).status_code == 422
    assert upload_avatar(client, headers, jpeg_bytes((5000, 5000))).status_code == 422
    assert upload_avatar(client, headers, jpeg_bytes()[:100]).status_code == 422
    assert upload_avatar(client, headers, b"x" * (2 * 1024 * 1024 + 1)).status_code == 413
    chunked = (b"x" * 8192 for _ in range(257))
    assert upload_avatar(client, headers, chunked).status_code == 413
    # The larger allowance is scoped to precisely the binary upload endpoint.
    assert client.patch("/v1/me", headers=headers, content=b"x" * 20000).status_code == 413
    assert client.post("/v1/avatars/arbitrary", headers=headers, content=b"x" * 20000).status_code == 413
    for filename in ("server.env", "test.sqlite3", "a.jpg", "a" * 64 + ".png", "../test.sqlite3", "%2e%2e%2ftest.sqlite3"):
        assert client.get("/v1/avatars/" + filename).status_code == 404
    assert not list(client.settings.avatar_path.iterdir())


def test_legacy_device_identity_cannot_authenticate_or_merge(client):
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("INSERT INTO accounts(account_id,login_id,sdk_user_id,name,created_at) VALUES('legacy','alice','old_sdk','旧昵称',1)")
        db.execute("INSERT INTO identities(provider,subject,account_id) VALUES('device_id','alice','legacy')")
        db.execute("INSERT INTO sessions VALUES(?,?,?,1)", (hashlib.sha256(b"old-token").hexdigest(), "legacy", int(time.time())+300))
    assert client.get("/v1/me", headers={"Authorization": "Bearer old-token"}).status_code == 401
    result = login(client, complete_nickname=False)
    assert result["user"]["needsNickname"] is True
    assert result["user"]["name"] != "旧昵称"
    assert result["user"]["sdkUserID"] != "old_sdk"


@pytest.mark.parametrize("changes", [
    None,
    {"accepted": False},
    {"adultConfirmed": False},
    {"adultConfirmed": None},
    {"documentHash": None},
    {"documentHash": "0" * 64},
    {"privacyVersion": "2026-10-16"},
    {"termsVersion": "2026-10-16"},
])
def test_login_requires_explicit_current_adult_legal_acceptance(client, changes):
    payload = apple_payload(client, "unaccepted", consent=False)
    if changes is not None:
        consent = current_legal_consent()
        for key, value in changes.items():
            if value is None:
                consent.pop(key)
            else:
                consent[key] = value
        payload["legalConsent"] = consent
    response = client.post("/v1/auth/apple", json=payload)
    assert response.status_code == 428
    assert response.json()["requiredVersions"] == load_legal_requirements()
    assert isinstance(response.json()["detail"], str)
    assert "token" not in response.json() and "sdk" not in response.json()
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM legal_consent_events").fetchone()[0] == 0


@pytest.mark.parametrize("changes", [
    {"accepted": "true"}, {"adultConfirmed": 1}, {"acceptedAt": 1}, {"ip": "127.0.0.1"},
])
def test_legal_acceptance_rejects_coercion_and_client_evidence(client, changes):
    response = client.post("/v1/auth/apple", json={**apple_payload(client, "invalid_consent"),
                                              "legalConsent": {**current_legal_consent(), **changes}})
    assert response.status_code == 422


def test_public_legal_documents_are_complete_anonymous_and_match_consent(client):
    response = client.get("/v1/legal/documents")
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert "set-cookie" not in response.headers and not client.cookies
    manifest = response.json()
    assert manifest == json.loads(LEGAL_DOCUMENTS_PATH.read_text(encoding="utf-8"))
    assert {document["id"] for document in manifest["documents"]} == {"privacy", "terms", "sdk", "permissions"}
    canonical = json.dumps({key: value for key, value in manifest.items() if key != "documentHash"},
                           sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    assert hashlib.sha256(canonical).hexdigest() == manifest["documentHash"]
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM legal_consent_events").fetchone()[0] == 0
    rejected = client.post("/v1/auth/apple", json=apple_payload(client, "dynamic_documents", consent=False))
    required = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    assert rejected.status_code == 428 and rejected.json()["requiredVersions"] == required
    payload = apple_payload(client, "dynamic_documents", consent=False)
    payload["legalConsent"] = {**required, "accepted": True, "adultConfirmed": True}
    accepted = client.post("/v1/auth/apple", json=payload)
    assert accepted.status_code == 200
    assert client.get("/v1/me/legal-consent", headers=authorization(accepted.json())).json()["requiresAcceptance"] is False


def test_downloaded_legal_documents_allow_an_existing_account_to_accept_current_text(client):
    account = login(client)
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE legal_consent_events SET privacy_version='old',document_hash=?", ("0" * 64,))
    rejected = client.post("/v1/auth/refresh", headers=authorization(account))
    assert rejected.status_code == 428
    manifest = client.get("/v1/legal/documents").json()
    required = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    assert rejected.json()["requiredVersions"] == required
    response = client.post("/v1/me/legal-consent", headers=authorization(account),
                           json={"legalConsent": {**required, "accepted": True, "adultConfirmed": True}})
    assert response.status_code == 200 and response.json()["requiresAcceptance"] is False
    assert client.post("/v1/auth/refresh", headers=authorization(account)).status_code == 200


def test_public_legal_documents_and_required_versions_share_a_startup_snapshot(client, tmp_path, monkeypatch):
    account = login(client)
    manifest = client.get("/v1/legal/documents").json()
    changed_path = tmp_path / "unpublished-replacement.json"
    changed_path.write_text("{}", encoding="utf-8")
    monkeypatch.setattr("app.main.LEGAL_DOCUMENTS_PATH", changed_path)
    assert client.get("/v1/legal/documents").json() == manifest
    status = client.get("/v1/me/legal-consent", headers=authorization(account)).json()
    assert status["requiredVersions"] == {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    assert status["requiresAcceptance"] is False


def test_legal_acceptance_uses_server_time_hash_and_idempotent_account_record(client):
    before = int(time.time())
    result = login(client)
    headers = authorization(result)
    current = client.get("/v1/me/legal-consent", headers=headers)
    assert current.status_code == 200
    status = current.json()
    assert status["requiredVersions"] == load_legal_requirements()
    assert status["requiresAcceptance"] is False
    assert status["legalConsent"] == {**current_legal_consent(),
                                     "acceptedAt": status["legalConsent"]["acceptedAt"], "withdrawnAt": None}
    assert before <= status["legalConsent"]["acceptedAt"] <= int(time.time())
    repeated = client.post("/v1/me/legal-consent", headers=headers,
                           json={"legalConsent": current_legal_consent()})
    assert repeated.json() == status
    login(client)
    with sqlite3.connect(client.settings.db_path) as db:
        rows = db.execute("""SELECT a.login_id,e.document_hash,e.adult_confirmed,e.accepted,e.recorded_at
            FROM legal_consent_events e JOIN accounts a ON a.account_id=e.account_id""").fetchall()
    assert rows == [(result["user"]["id"], load_legal_requirements()["documentHash"], 1, 1,
                     status["legalConsent"]["acceptedAt"])]


def test_existing_session_can_review_and_accept_before_business_or_sdk_use(client, monkeypatch):
    headers = authorization(login(client))
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("DELETE FROM legal_consent_events")
    calls = []

    def guarded_signer(*args, **kwargs):
        calls.append(args)
        return generate_user_sig(*args, **kwargs)

    monkeypatch.setattr("app.main.generate_user_sig", guarded_signer)
    assert client.get("/v1/me/legal-consent", headers=headers).json() == {
        "requiredVersions": load_legal_requirements(), "legalConsent": None, "requiresAcceptance": True}
    business_calls = [
        ("GET", "/v1/me", None), ("PATCH", "/v1/me", {"name": "不能修改"}),
        ("POST", "/v1/auth/refresh", None), ("GET", "/v1/rooms", None),
        ("POST", "/v1/rooms/lookup", {"ids": []}),
        ("POST", "/v1/rooms", {"title": "未同意", "category": "语聊", "isLive": False, "theme": 0}),
        ("GET", "/v1/rooms/missing", None), ("PATCH", "/v1/rooms/missing", {"status": "live"}),
        ("GET", "/v1/library", None), ("PUT", "/v1/favorites/missing", None),
        ("DELETE", "/v1/favorites/missing", None), ("POST", "/v1/history/missing", None),
    ]
    for method, path, body in business_calls:
        response = client.request(method, path, headers=headers, json=body)
        assert response.status_code == 428, (method, path, response.text)
        assert response.json()["requiredVersions"] == load_legal_requirements()
    assert upload_avatar(client, headers).status_code == 428
    assert not calls
    assert client.get("/health").status_code == 200
    assert client.post("/v1/me/legal-consent", headers=headers, json={}).status_code == 428
    accepted = client.post("/v1/me/legal-consent", headers=headers,
                           json={"legalConsent": current_legal_consent()})
    assert accepted.status_code == 200 and accepted.json()["requiresAcceptance"] is False
    assert client.get("/v1/me", headers=headers).status_code == 200
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 200
    assert len(calls) == 1


def test_outdated_consent_does_not_grandfather_sdk_or_business_access(client):
    headers = authorization(login(client))
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE legal_consent_events SET privacy_version='2026-10-16',document_hash=?", ("0" * 64,))
    status = client.get("/v1/me/legal-consent", headers=headers).json()
    assert status["legalConsent"]["privacyVersion"] == "2026-10-16"
    assert status["requiresAcceptance"] is True
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 428
    stale = {**current_legal_consent(), "documentHash": "0" * 64}
    assert client.post("/v1/me/legal-consent", headers=headers, json={"legalConsent": stale}).status_code == 428
    assert client.post("/v1/me/legal-consent", headers=headers,
                       json={"legalConsent": current_legal_consent()}).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM legal_consent_events").fetchone()[0] == 2
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 200


def test_withdrawal_records_event_and_revokes_all_account_sessions(client):
    first = login(client)
    second = login(client)
    other = authorization(login(client, "other", "2" * 64))
    headers = authorization(first)
    before = int(time.time())
    withdrawn = client.delete("/v1/me/legal-consent", headers=headers)
    assert withdrawn.status_code == 200 and withdrawn.json() == {"ok": True}
    for revoked in (headers, authorization(second)):
        assert client.get("/v1/me", headers=revoked).status_code == 401
        assert client.post("/v1/auth/refresh", headers=revoked).status_code == 401
        assert client.get("/v1/me/legal-consent", headers=revoked).status_code == 401
        assert client.post("/v1/me/legal-consent", headers=revoked,
                           json={"legalConsent": current_legal_consent()}).status_code == 401
    assert client.get("/v1/me", headers=other).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        account = db.execute("SELECT account_id FROM identities WHERE provider='apple' AND subject='alice'").fetchone()[0]
        events = db.execute("""SELECT accepted,adult_confirmed,document_hash,recorded_at
            FROM legal_consent_events WHERE account_id=? ORDER BY event_id""", (account,)).fetchall()
        assert db.execute("SELECT COUNT(*) FROM sessions WHERE account_id=?", (account,)).fetchone()[0] == 0
    assert [row[0] for row in events] == [1, 0]
    assert events[-1][1:3] == (1, load_legal_requirements()["documentHash"])
    assert before <= events[-1][3] <= int(time.time())
    # Withdrawing does not silently accept again on a legacy login request.
    assert client.post("/v1/auth/apple", json=apple_payload(client, consent=False)).status_code == 428
    renewed = login(client)
    assert renewed["user"]["sdkUserID"] == first["user"]["sdkUserID"]
    assert client.get("/v1/me/legal-consent", headers=authorization(renewed)).json()["requiresAcceptance"] is False
    with sqlite3.connect(client.settings.db_path) as db:
        assert [row[0] for row in db.execute("SELECT accepted FROM legal_consent_events WHERE account_id=? ORDER BY event_id",
                                           (account,))] == [1, 0, 1]


def test_withdrawal_response_loss_can_retry_without_revoking_new_sessions(client):
    original = login(client)
    unrelated_session = login(client)
    old_headers = authorization(original)
    # Treat the first successful response as lost to the caller.
    assert client.delete("/v1/me/legal-consent", headers=old_headers).status_code == 200
    assert client.delete("/v1/me/legal-consent", headers=old_headers).json() == {"ok": True}
    assert client.delete("/v1/me/legal-consent", headers=authorization(unrelated_session)).status_code == 401
    renewed_headers = authorization(login(client))
    assert client.delete("/v1/me/legal-consent", headers=old_headers).json() == {"ok": True}
    assert client.get("/v1/me", headers=renewed_headers).status_code == 200
    assert client.get("/v1/me/legal-consent", headers=old_headers).status_code == 401
    with sqlite3.connect(client.settings.db_path) as db:
        receipt = db.execute("SELECT token_hash,expires_at FROM legal_withdrawal_receipts").fetchone()
        assert receipt[0] == hashlib.sha256(original["token"].encode()).hexdigest()
        assert int(time.time()) + 86000 < receipt[1] <= int(time.time()) + 86400
        assert db.execute("SELECT COUNT(*) FROM legal_consent_events WHERE accepted=0").fetchone()[0] == 1
        db.execute("UPDATE legal_withdrawal_receipts SET expires_at=1")
    assert client.delete("/v1/me/legal-consent", headers=old_headers).status_code == 401
    assert client.get("/v1/me", headers=renewed_headers).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM legal_withdrawal_receipts").fetchone()[0] == 0


def test_account_deletion_removes_consent_and_withdrawal_receipts(client):
    old_headers = authorization(login(client))
    assert client.delete("/v1/me/legal-consent", headers=old_headers).status_code == 200
    current_headers = authorization(login(client))
    assert client.delete("/v1/account", headers=current_headers).status_code == 200
    assert client.delete("/v1/me/legal-consent", headers=old_headers).status_code == 401
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM legal_consent_events").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM legal_withdrawal_receipts").fetchone()[0] == 0


@pytest.mark.parametrize("action", ["logout", "delete"])
def test_unaccepted_legacy_sessions_can_logout_or_delete_account(client, action):
    headers = authorization(login(client))
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE legal_consent_events SET privacy_version='2026-10-16'")
    if action == "logout":
        assert client.post("/v1/auth/logout", headers=headers).status_code == 200
    else:
        assert client.delete("/v1/account", headers=headers).status_code == 200
        with sqlite3.connect(client.settings.db_path) as db:
            assert db.execute("SELECT COUNT(*) FROM legal_consent_events").fetchone()[0] == 0
    assert client.get("/v1/me/legal-consent", headers=headers).status_code == 401


@pytest.mark.parametrize("manifest", [None, {}, {"draft": True}, {"status": "draft"}, {"documentHash": "invalid"}])
def test_server_refuses_missing_invalid_or_draft_legal_documents(tmp_path, monkeypatch, manifest):
    path = tmp_path / "legal_documents.json"
    if manifest is not None:
        path.write_text(json.dumps({**load_legal_requirements(), **manifest}), encoding="utf-8")
        if manifest == {}:
            path.write_text("{}", encoding="utf-8")
    monkeypatch.setattr("app.main.LEGAL_DOCUMENTS_PATH", path)
    with pytest.raises(RuntimeError, match="隐私政策"):
        create_app(Settings(str(tmp_path / "invalid.sqlite3"), 123, TEST_KEY, False))


def test_server_refuses_legal_text_changed_without_new_content_hash(tmp_path, monkeypatch):
    manifest = json.loads(LEGAL_DOCUMENTS_PATH.read_text(encoding="utf-8"))
    manifest["documents"][0]["sections"][0]["paragraphs"][0] += "修改后的内容"
    path = tmp_path / "changed_documents.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr("app.main.LEGAL_DOCUMENTS_PATH", path)
    with pytest.raises(RuntimeError, match="隐私政策"):
        create_app(Settings(str(tmp_path / "changed.sqlite3"), 123, TEST_KEY, False))


@pytest.mark.parametrize("damage", ["missing-document", "duplicate-document", "empty-paragraph"])
def test_server_refuses_incomplete_legal_text_even_with_recomputed_hash(tmp_path, monkeypatch, damage):
    manifest = json.loads(LEGAL_DOCUMENTS_PATH.read_text(encoding="utf-8"))
    if damage == "missing-document":
        manifest["documents"].pop()
    elif damage == "duplicate-document":
        manifest["documents"][-1] = manifest["documents"][0]
    else:
        manifest["documents"][0]["sections"][0]["paragraphs"] = ["  "]
    manifest["documentHash"] = hashlib.sha256(json.dumps(
        {key: value for key, value in manifest.items() if key != "documentHash"},
        sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
    path = tmp_path / "incomplete_documents.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    monkeypatch.setattr("app.main.LEGAL_DOCUMENTS_PATH", path)
    with pytest.raises(RuntimeError, match="隐私政策"):
        create_app(Settings(str(tmp_path / "incomplete.sqlite3"), 123, TEST_KEY, False))
