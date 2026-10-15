import base64
import hashlib
import hmac
from io import BytesIO
import json
from pathlib import Path
import sqlite3
import stat
from urllib.parse import urlsplit
import zlib

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import SCHEMA, Settings, create_app, hash_device_secret
from app.usersig import generate_user_sig

TEST_KEY = "a" * 64


@pytest.fixture
def client(tmp_path):
    settings = Settings(str(tmp_path / "test.sqlite3"), 1234567890, TEST_KEY, False)
    with TestClient(create_app(settings)) as test_client:
        test_client.settings = settings
        yield test_client


def login(client, name="alice", secret="1" * 64, complete_nickname=True):
    response = client.post("/v1/auth/id", json={"userID": name, "deviceSecret": secret})
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


def test_claim_bound_to_device_and_new_login_stable(client):
    first = login(client)
    again = login(client)
    assert first["user"]["sdkUserID"] == again["user"]["sdkUserID"]
    assert first["token"] != again["token"]
    denied = client.post("/v1/auth/id", json={"userID": "alice", "deviceSecret": "2" * 64})
    assert denied.status_code == 403
    assert "其他设备" in denied.json()["detail"]
    with sqlite3.connect(client.settings.db_path) as db:
        serialized = " ".join(str(row) for row in db.execute("SELECT * FROM identities"))
        assert "1" * 64 not in serialized
        stored = " ".join(str(row) for row in db.execute("SELECT * FROM sessions"))
        assert first["token"] not in stored


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


@pytest.mark.parametrize("payload", [
    {"userID": "ab", "deviceSecret": "1" * 64},
    {"userID": "中文ID", "deviceSecret": "1" * 64},
    {"userID": "alice", "deviceSecret": "short"},
    {"userID": "alice", "deviceSecret": "1" * 64, "admin": True},
])
def test_login_validation(client, payload):
    response = client.post("/v1/auth/id", json=payload)
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)


def test_profile_and_room_validation(client):
    headers = authorization(login(client))
    for body in ({"avatarIndex": 12}, {"name": "   "}, {"notificationsEnabled": "yes"}, {"name": "bad\nname"}):
        assert client.patch("/v1/me", headers=headers, json=body).status_code == 422
    assert client.post("/v1/rooms", headers=headers,
                       json={"title": "", "category": "随心聊", "isLive": False, "theme": 0}).status_code == 422
    assert client.post("/v1/auth/id", content=b"x" * 20000).status_code == 413
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


def test_auth_rate_limit(tmp_path):
    settings = Settings(str(tmp_path / "limit.sqlite3"), 123, TEST_KEY, True)
    with TestClient(create_app(settings)) as client:
        for _ in range(12):
            assert client.post("/v1/auth/id", json={"userID": "alice", "deviceSecret": "1" * 64}).status_code == 200
        assert client.post("/v1/auth/id", json={"userID": "alice", "deviceSecret": "1" * 64}).status_code == 429


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
    assert user["avatarURL"].startswith("https://43.138.219.160/v1/avatars/")
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


def test_upgrade_preserves_custom_nicknames_and_requires_old_default_names(tmp_path):
    settings = Settings(str(tmp_path / "old.sqlite3"), 123, TEST_KEY, False)
    old_schema = SCHEMA.replace("  avatar_filename TEXT,\n", "").replace("  needs_nickname INTEGER NOT NULL DEFAULT 1,\n", "")
    old_schema = old_schema.replace("  host_avatar_filename TEXT,\n", "")
    cases = (("alice", "alice", True), ("long_account_id_123456789", "long_account_id_", True),
             ("named_account", "已有昵称", False))
    with sqlite3.connect(settings.db_path) as db:
        db.executescript(old_schema)
        for login_id, name, _ in cases:
            db.execute("INSERT INTO accounts(account_id,login_id,sdk_user_id,name,created_at) VALUES(?,?,?,?,?)",
                       (login_id, login_id, "sdk_" + login_id, name, 1))
            salt = "a" * 32
            db.execute("INSERT INTO identities VALUES('device_id',?,?,?,?)",
                       (login_id, login_id, salt, hash_device_secret("1" * 64, salt)))
    with TestClient(create_app(settings)) as migrated:
        for login_id, name, needs_nickname in cases:
            result = login(migrated, login_id, complete_nickname=False)
            assert result["user"]["name"] == name
            assert result["user"]["needsNickname"] is needs_nickname
            assert result["user"]["avatarURL"] is None
        alice = login(migrated, complete_nickname=False)
        assert migrated.patch("/v1/me", headers=authorization(alice), json={"name": "alice"}).json()["needsNickname"] is False
    # Migration runs once; a nickname deliberately equal to ID remains accepted.
    with TestClient(create_app(settings)) as restarted:
        assert login(restarted, complete_nickname=False)["user"]["needsNickname"] is False
