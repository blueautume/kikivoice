"""KikiTalk account and room metadata API.

Active media rooms, membership, seats and messages are managed by Tencent's SDK.
This service stores account-owned metadata and never fabricates online activity.
"""

from collections import defaultdict, deque
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
import hashlib
import hmac
from io import BytesIO
import logging
import os
from pathlib import Path
import re
import secrets
import sqlite3
import tempfile
import threading
import time
from typing import Literal
import uuid

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, field_validator
from starlette.exceptions import HTTPException as StarletteHTTPException

from .usersig import generate_user_sig

LOGGER = logging.getLogger("kikitalk")
SESSION_SECONDS = 30 * 86400
SDK_SECONDS = 86400
MAX_BODY = 16 * 1024
MAX_AVATAR_BODY = 2 * 1024 * 1024
AVATAR_NAME = re.compile(r"^[a-f0-9]{64}\.jpg$")


@dataclass(frozen=True)
class Settings:
    db_path: str
    sdk_app_id: int
    secret_key: str
    rate_limit_enabled: bool = True
    avatar_directory: str | None = None
    public_base_url: str = "https://43.138.219.160"

    @property
    def avatar_path(self):
        return Path(self.avatar_directory) if self.avatar_directory else Path(self.db_path).parent / "avatars"

    @classmethod
    def from_environment(cls):
        return cls(os.environ.get("DATABASE_PATH", "/var/lib/kikitalk/kikitalk.sqlite3"),
                   int(os.environ.get("SDKAPPID", "0")), os.environ.get("SECRETKEY", ""),
                   avatar_directory=os.environ.get("AVATAR_DIRECTORY"),
                   public_base_url=os.environ.get("PUBLIC_BASE_URL", "https://43.138.219.160"))


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class IDLogin(Model):
    userID: str = Field(pattern=r"^[A-Za-z0-9_-]{3,32}$")
    deviceSecret: str = Field(pattern=r"^[a-fA-F0-9]{64}$")


class ProfileUpdate(Model):
    name: str | None = Field(default=None, min_length=1, max_length=16)
    bio: str | None = Field(default=None, max_length=80)
    avatarIndex: int | None = Field(default=None, strict=True, ge=0, le=11)
    notificationsEnabled: bool | None = Field(default=None, strict=True)

    @field_validator("name")
    @classmethod
    def clean_text(cls, value):
        if value is not None and any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("文字不能包含控制字符")
        return value

    @field_validator("bio", mode="before")
    @classmethod
    def clean_bio(cls, value):
        if isinstance(value, str):
            value = value.replace("\r\n", "\n").replace("\r", "\n")
            if any((ord(c) < 32 and c != "\n") or ord(c) == 127 for c in value):
                raise ValueError("简介只能包含文字和换行")
        return value


class RoomCreate(Model):
    title: str = Field(min_length=1, max_length=40)
    category: str = Field(min_length=1, max_length=12)
    isLive: bool = Field(strict=True)
    theme: int = Field(strict=True, ge=0, le=5)

    @field_validator("title", "category")
    @classmethod
    def clean_text(cls, value):
        if any(ord(c) < 32 for c in value):
            raise ValueError("文字不能包含控制字符")
        return value

    @field_validator("title")
    @classmethod
    def title_byte_limit(cls, value):
        if len(value.encode("utf-8")) > 100:
            raise ValueError("房间标题过长，最多支持 100 字节（约 33 个汉字）")
        return value


class RoomUpdate(Model):
    status: Literal["draft", "live", "ended"]


class RoomLookup(Model):
    ids: list[str] = Field(max_length=100)


SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS accounts (
  account_id TEXT PRIMARY KEY,
  login_id TEXT NOT NULL UNIQUE,
  sdk_user_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  bio TEXT NOT NULL DEFAULT '',
  avatar_index INTEGER NOT NULL DEFAULT 0,
  avatar_filename TEXT,
  needs_nickname INTEGER NOT NULL DEFAULT 1,
  notifications INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);
-- Provider identity stays separate so a future verified Apple sub can link an
-- existing account without changing room ownership or SDK identity.
CREATE TABLE IF NOT EXISTS identities (
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  salt TEXT,
  secret_hash TEXT,
  PRIMARY KEY(provider, subject)
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS session_account ON sessions(account_id);
CREATE TABLE IF NOT EXISTS rooms (
  id TEXT PRIMARY KEY,
  owner_id TEXT REFERENCES accounts(account_id) ON DELETE SET NULL,
  host_id TEXT NOT NULL,
  host_name TEXT NOT NULL,
  host_avatar_index INTEGER NOT NULL DEFAULT 0,
  host_avatar_filename TEXT,
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  is_live INTEGER NOT NULL,
  theme INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS room_owner ON rooms(owner_id);
CREATE TABLE IF NOT EXISTS favorites (
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(account_id,room_id)
);
CREATE TABLE IF NOT EXISTS history (
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  visited_at INTEGER NOT NULL,
  PRIMARY KEY(account_id,room_id)
);
"""


@contextmanager
def database(settings):
    connection = sqlite3.connect(settings.db_path, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def avatar_url(filename, settings):
    return settings.public_base_url.rstrip("/") + "/v1/avatars/" + filename if filename else None


def serialize_user(row, settings):
    return {"id": row["login_id"], "sdkUserID": row["sdk_user_id"],
            "name": row["name"], "bio": row["bio"], "avatarIndex": row["avatar_index"],
            "avatarURL": avatar_url(row["avatar_filename"], settings),
            "needsNickname": bool(row["needs_nickname"]),
            "notificationsEnabled": bool(row["notifications"])}


def serialize_room(row, account_id, settings):
    return {"id": row["id"], "title": row["title"], "host": row["host_name"],
            "hostID": row["host_id"], "hostAvatarIndex": row["host_avatar_index"],
            "hostAvatarURL": avatar_url(row["host_avatar_filename"], settings),
            "audience": 0, "isLive": bool(row["is_live"]),
            "theme": row["theme"], "category": row["category"],
            "isCreatedByMe": row["owner_id"] == account_id, "status": row["status"],
            "createdAt": row["created_at"]}


def remove_avatar(filename, settings):
    # Only filenames generated by this service can ever reach filesystem access.
    if filename and AVATAR_NAME.fullmatch(filename):
        (settings.avatar_path / filename).unlink(missing_ok=True)


def normalize_avatar(payload):
    """Decode genuine JPEG pixels and produce a fresh metadata-free square."""
    try:
        with Image.open(BytesIO(payload)) as source:
            if source.format != "JPEG":
                raise HTTPException(415, "请选择 JPEG 格式的头像")
            width, height = source.size
            if min(width, height) < 64 or max(width, height) > 8192 or width * height > 20_000_000:
                raise HTTPException(422, "头像尺寸需至少 64×64，单边不超过 8192，且不超过 2000 万像素")
            source.verify()
        with Image.open(BytesIO(payload)) as source:
            source.load()
            oriented = ImageOps.exif_transpose(source)
            cropped = ImageOps.fit(oriented.convert("RGB"), (512, 512), Image.Resampling.LANCZOS)
            clean = Image.new("RGB", cropped.size)
            clean.paste(cropped)
            result = BytesIO()
            clean.save(result, format="JPEG", quality=88, optimize=True)
            return result.getvalue()
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as error:
        raise HTTPException(422, "头像文件损坏，请重新从相册选择") from error


def hash_device_secret(secret, salt):
    return hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), 120000).hex()


class RequestLimits:
    def __init__(self):
        self.lock = threading.Lock()
        self.events = defaultdict(deque)

    def check(self, key, maximum, seconds):
        now = time.monotonic()
        with self.lock:
            # Expire idle keys to bound memory under a scan of many source IPs.
            if len(self.events) > 4096:
                self.events = defaultdict(deque, {
                    k: q for k, q in self.events.items() if q and now - q[-1] < 3600})
            queue = self.events[key]
            while queue and queue[0] <= now - seconds:
                queue.popleft()
            if len(queue) >= maximum:
                raise HTTPException(429, "操作过于频繁，请稍后再试", headers={"Retry-After": str(seconds)})
            queue.append(now)


def create_app(settings: Settings | None = None):
    settings = settings or Settings.from_environment()
    if settings.sdk_app_id <= 0 or len(settings.secret_key) < 32:
        raise RuntimeError("请在服务端配置有效的 SDKAPPID 与 SECRETKEY")
    limits = RequestLimits()

    @asynccontextmanager
    async def lifespan(app):
        Path(settings.db_path).parent.mkdir(parents=True, exist_ok=True)
        settings.avatar_path.mkdir(mode=0o700, parents=True, exist_ok=True)
        with database(settings) as db:
            db.executescript(SCHEMA)
            account_columns = {row["name"] for row in db.execute("PRAGMA table_info(accounts)")}
            if "avatar_filename" not in account_columns:
                db.execute("ALTER TABLE accounts ADD COLUMN avatar_filename TEXT")
            if "needs_nickname" not in account_columns:
                db.execute("ALTER TABLE accounts ADD COLUMN needs_nickname INTEGER NOT NULL DEFAULT 1")
                # The previous app truncated ID-based placeholder names to 16
                # characters. Preserve deliberate custom nicknames during upgrade.
                db.execute("""UPDATE accounts SET needs_nickname=CASE
                    WHEN name=login_id OR name=substr(login_id,1,16) THEN 1 ELSE 0 END""")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(rooms)")}
            if "host_avatar_index" not in columns:
                db.execute("ALTER TABLE rooms ADD COLUMN host_avatar_index INTEGER NOT NULL DEFAULT 0")
                db.execute("""UPDATE rooms SET host_avatar_index=COALESCE(
                    (SELECT avatar_index FROM accounts WHERE account_id=rooms.owner_id),0)""")
            if "host_avatar_filename" not in columns:
                db.execute("ALTER TABLE rooms ADD COLUMN host_avatar_filename TEXT")
            db.execute("DELETE FROM sessions WHERE expires_at<=?", (int(time.time()),))
        yield

    app = FastAPI(title="KikiTalk API", version="1.0.0", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def limit_request(request, call_next):
        maximum = MAX_AVATAR_BODY if request.method == "POST" and request.url.path == "/v1/me/avatar" else MAX_BODY
        content_length = request.headers.get("content-length")
        if content_length and (not content_length.isdigit() or int(content_length) > maximum):
            return JSONResponse({"detail": "请求内容过大"}, status_code=413)
        # Reading through ASGI limits chunked bodies too; Request caches for call_next.
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > maximum:
                return JSONResponse({"detail": "请求内容过大"}, status_code=413)
        request._body = bytes(body)
        try:
            if settings.rate_limit_enabled:
                ip = request.client.host if request.client else "unknown"
                limits.check(("http", ip), 240, 60)
            response = await call_next(request)
        except HTTPException as error:
            response = JSONResponse({"detail": error.detail}, status_code=error.status_code,
                                    headers=error.headers)
        except Exception as error:
            # Exception class only: SQL, tokens and submitted content never enter logs.
            LOGGER.error("Unhandled API failure: %s", type(error).__name__)
            response = JSONResponse({"detail": "服务暂时不可用，请稍后重试"}, status_code=500)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Strict-Transport-Security"] = "max-age=31536000"
        return response

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, _error):
        return JSONResponse({"detail": "参数不正确，请检查输入内容（ID 需为 3–32 位字母、数字、下划线或短横线）"}, status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_request, error):
        return JSONResponse({"detail": error.detail}, status_code=error.status_code, headers=error.headers)

    def authenticated(request: Request):
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer ") or len(header) > 512:
            raise HTTPException(401, "请先登录")
        token_hash = hashlib.sha256(header[7:].encode()).hexdigest()
        with database(settings) as db:
            row = db.execute("""SELECT a.*, s.token_hash FROM sessions s JOIN accounts a
                ON a.account_id=s.account_id WHERE s.token_hash=? AND s.expires_at>?""",
                (token_hash, int(time.time()))).fetchone()
        if row is None:
            raise HTTPException(401, "登录已过期，请重新登录")
        return dict(row)

    def sdk_credentials(user):
        now = int(time.time())
        return {"sdkAppID": settings.sdk_app_id, "userID": user["sdk_user_id"],
                "userSig": generate_user_sig(settings.sdk_app_id, settings.secret_key,
                                             user["sdk_user_id"], SDK_SECONDS, now=now),
                "expiresAt": now + SDK_SECONDS}

    def require_nickname(user):
        if user["needs_nickname"]:
            raise HTTPException(409, "请先设置昵称，再进入或创建房间")

    def find_room(db, room_id):
        row = db.execute("SELECT * FROM rooms WHERE id=?", (room_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "房间不存在或已被移除")
        return row

    @app.get("/health")
    def health():
        with database(settings) as db:
            db.execute("SELECT 1")
        return {"status": "ok", "rtcConfigured": True}

    @app.post("/v1/auth/id")
    def login(payload: IDLogin, request: Request):
        if settings.rate_limit_enabled:
            ip = request.client.host if request.client else "unknown"
            limits.check(("auth_ip", ip), 20, 60)
            limits.check(("auth_id", payload.userID), 12, 60)
        now = int(time.time())
        # IMMEDIATE serializes first claim so competing installations cannot win
        # the same account ID or replace an existing device credential.
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            identity = db.execute("SELECT * FROM identities WHERE provider='device_id' AND subject=?",
                                  (payload.userID,)).fetchone()
            if identity:
                candidate = hash_device_secret(payload.deviceSecret, identity["salt"])
                if not hmac.compare_digest(candidate, identity["secret_hash"]):
                    raise HTTPException(403, "该 ID 已绑定其他设备，请使用其他 ID 或原设备登录")
                account_id = identity["account_id"]
            else:
                account_id = uuid.uuid4().hex
                sdk_user_id = "kiki_" + secrets.token_hex(13)
                salt = secrets.token_hex(16)
                db.execute("""INSERT INTO accounts(account_id,login_id,sdk_user_id,name,created_at)
                              VALUES(?,?,?,?,?)""", (account_id, payload.userID, sdk_user_id,
                                                     payload.userID[:16], now))
                db.execute("INSERT INTO identities VALUES('device_id',?,?,?,?)",
                           (payload.userID, account_id, salt, hash_device_secret(payload.deviceSecret, salt)))
            db.execute("DELETE FROM sessions WHERE expires_at<=?", (now,))
            # Bound active sessions for repeated login on the same installation.
            db.execute("""DELETE FROM sessions WHERE account_id=? AND token_hash NOT IN
                       (SELECT token_hash FROM sessions WHERE account_id=? ORDER BY created_at DESC LIMIT 4)""",
                       (account_id, account_id))
            token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (token_hash, account_id, now + SESSION_SECONDS, now))
            user = db.execute("SELECT * FROM accounts WHERE account_id=?", (account_id,)).fetchone()
        return {"token": token, "user": serialize_user(user, settings), "sdk": sdk_credentials(user)}

    @app.post("/v1/auth/refresh")
    def refresh(user=Depends(authenticated)):
        with database(settings) as db:
            db.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?",
                       (int(time.time()) + SESSION_SECONDS, user["token_hash"]))
        return {"user": serialize_user(user, settings), "sdk": sdk_credentials(user)}

    @app.post("/v1/auth/logout")
    def logout(user=Depends(authenticated)):
        with database(settings) as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?", (user["token_hash"],))
        return {"ok": True}

    @app.get("/v1/me")
    def get_me(user=Depends(authenticated)):
        return serialize_user(user, settings)

    @app.patch("/v1/me")
    def update_me(payload: ProfileUpdate, user=Depends(authenticated)):
        fields = payload.model_dump(exclude_unset=True, exclude_none=True)
        columns = {"name": "name", "bio": "bio", "avatarIndex": "avatar_index",
                   "notificationsEnabled": "notifications"}
        old_avatar = None
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
            if current is None:
                raise HTTPException(401, "登录已过期，请重新登录")
            for field, value in fields.items():
                db.execute(f"UPDATE accounts SET {columns[field]}=? WHERE account_id=?",
                           (value, user["account_id"]))
            if "name" in fields:
                db.execute("UPDATE accounts SET needs_nickname=0 WHERE account_id=?", (user["account_id"],))
                db.execute("UPDATE rooms SET host_name=? WHERE owner_id=?",
                           (fields["name"], user["account_id"]))
            if "avatarIndex" in fields:
                old_avatar = current["avatar_filename"]
                db.execute("UPDATE accounts SET avatar_filename=NULL WHERE account_id=?", (user["account_id"],))
                db.execute("UPDATE rooms SET host_avatar_index=?,host_avatar_filename=NULL WHERE owner_id=?",
                           (fields["avatarIndex"], user["account_id"]))
            updated = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
        remove_avatar(old_avatar, settings)
        return serialize_user(updated, settings)

    def store_avatar(payload, user):
        encoded = normalize_avatar(payload)
        filename = secrets.token_hex(32) + ".jpg"
        destination = settings.avatar_path / filename
        temporary_path = None
        try:
            with database(settings) as db:
                db.execute("BEGIN IMMEDIATE")
                current = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
                if current is None:
                    raise HTTPException(401, "登录已过期，请重新登录")
                old_avatar = current["avatar_filename"]
                with tempfile.NamedTemporaryFile(dir=settings.avatar_path, prefix=".upload-", delete=False) as temporary:
                    temporary_path = Path(temporary.name)
                    temporary.write(encoded)
                    temporary.flush()
                    os.fsync(temporary.fileno())
                os.replace(temporary_path, destination)
                db.execute("UPDATE accounts SET avatar_filename=? WHERE account_id=?", (filename, user["account_id"]))
                db.execute("UPDATE rooms SET host_avatar_filename=? WHERE owner_id=?", (filename, user["account_id"]))
                updated = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
        except Exception:
            destination.unlink(missing_ok=True)
            raise
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
        remove_avatar(old_avatar, settings)
        return serialize_user(updated, settings)

    @app.post("/v1/me/avatar")
    async def upload_avatar(request: Request, user=Depends(authenticated)):
        if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "image/jpeg":
            raise HTTPException(415, "请以 image/jpeg 上传头像")
        if settings.rate_limit_enabled:
            limits.check(("avatar_upload", user["account_id"]), 20, 3600)
        return await run_in_threadpool(store_avatar, await request.body(), user)

    @app.get("/v1/avatars/{filename}")
    def get_avatar(filename: str):
        if not AVATAR_NAME.fullmatch(filename):
            raise HTTPException(404, "头像不存在")
        path = settings.avatar_path / filename
        if not path.is_file():
            raise HTTPException(404, "头像不存在")
        return FileResponse(path, media_type="image/jpeg")

    @app.delete("/v1/account")
    def delete_account(user=Depends(authenticated)):
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT avatar_filename FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
            # Keep room IDs as ended records so others' saved history is honest;
            # remove identifying profile information and ownership permanently.
            db.execute("UPDATE rooms SET status='ended',host_name='已注销用户',host_avatar_index=0,host_avatar_filename=NULL WHERE owner_id=?",
                       (user["account_id"],))
            db.execute("DELETE FROM accounts WHERE account_id=?", (user["account_id"],))
        if current is not None:
            remove_avatar(current["avatar_filename"], settings)
        return {"ok": True}

    @app.get("/v1/rooms")
    def list_rooms(user=Depends(authenticated)):
        with database(settings) as db:
            rows = db.execute("SELECT * FROM rooms ORDER BY created_at DESC,id DESC LIMIT 500").fetchall()
        return {"rooms": [serialize_room(row, user["account_id"], settings) for row in rows]}

    @app.post("/v1/rooms/lookup")
    def lookup_rooms(payload: RoomLookup, user=Depends(authenticated)):
        room_ids = list(dict.fromkeys(payload.ids))
        if not room_ids:
            return {"rooms": []}
        placeholders = ",".join("?" for _ in room_ids)
        with database(settings) as db:
            rows = db.execute(f"SELECT * FROM rooms WHERE id IN ({placeholders})", room_ids).fetchall()
        by_id = {row["id"]: row for row in rows}
        return {"rooms": [serialize_room(by_id[room_id], user["account_id"], settings)
                          for room_id in room_ids if room_id in by_id]}

    @app.post("/v1/rooms")
    def create_room(payload: RoomCreate, user=Depends(authenticated)):
        require_nickname(user)
        if settings.rate_limit_enabled:
            limits.check(("room_create", user["account_id"]), 20, 3600)
        room_id = ("live_kiki_" if payload.isLive else "voice_kiki_") + uuid.uuid4().hex[:24]
        with database(settings) as db:
            db.execute("""INSERT INTO rooms(id,owner_id,host_id,host_name,host_avatar_index,host_avatar_filename,title,category,is_live,theme,created_at)
                       VALUES(?,?,?,?,?,?,?,?,?,?,?)""", (room_id, user["account_id"], user["sdk_user_id"],
                       user["name"], user["avatar_index"], user["avatar_filename"], payload.title, payload.category, payload.isLive, payload.theme, int(time.time())))
            row = find_room(db, room_id)
        return serialize_room(row, user["account_id"], settings)

    @app.get("/v1/rooms/{room_id}")
    def get_room(room_id: str, user=Depends(authenticated)):
        with database(settings) as db:
            row = find_room(db, room_id)
        return serialize_room(row, user["account_id"], settings)

    @app.patch("/v1/rooms/{room_id}")
    def update_room(room_id: str, payload: RoomUpdate, user=Depends(authenticated)):
        if payload.status == "live":
            require_nickname(user)
        with database(settings) as db:
            row = find_room(db, room_id)
            if row["owner_id"] != user["account_id"]:
                raise HTTPException(403, "只有房主可以修改房间状态")
            if row["status"] == "ended" and payload.status != "ended":
                raise HTTPException(409, "房间已经结束，请创建新房间")
            db.execute("UPDATE rooms SET status=? WHERE id=?", (payload.status, room_id))
            row = find_room(db, room_id)
        return serialize_room(row, user["account_id"], settings)

    @app.get("/v1/library")
    def library(user=Depends(authenticated)):
        account_id = user["account_id"]
        with database(settings) as db:
            favorites = db.execute("""SELECT r.* FROM favorites f JOIN rooms r ON r.id=f.room_id
                WHERE f.account_id=? ORDER BY f.created_at DESC,r.id DESC""", (account_id,)).fetchall()
            recents = db.execute("""SELECT r.* FROM history h JOIN rooms r ON r.id=h.room_id
                WHERE h.account_id=? ORDER BY h.visited_at DESC,r.id DESC LIMIT 20""", (account_id,)).fetchall()
            created = db.execute("SELECT * FROM rooms WHERE owner_id=? ORDER BY created_at DESC,id DESC LIMIT 500",
                                 (account_id,)).fetchall()
        return {"favorites": [serialize_room(row, account_id, settings) for row in favorites],
                "recents": [serialize_room(row, account_id, settings) for row in recents],
                "created": [serialize_room(row, account_id, settings) for row in created]}

    @app.put("/v1/favorites/{room_id}")
    def favorite(room_id: str, user=Depends(authenticated)):
        with database(settings) as db:
            # Serialize the capacity check and insertion; a retry of an existing
            # favorite succeeds even when the library is at capacity.
            db.execute("BEGIN IMMEDIATE")
            find_room(db, room_id)
            existing = db.execute("SELECT 1 FROM favorites WHERE account_id=? AND room_id=?",
                                  (user["account_id"], room_id)).fetchone()
            if existing:
                return {"ok": True}
            count = db.execute("SELECT COUNT(*) FROM favorites WHERE account_id=?", (user["account_id"],)).fetchone()[0]
            if count >= 500:
                raise HTTPException(409, "收藏数量已达上限，请先取消部分收藏")
            db.execute("INSERT OR IGNORE INTO favorites VALUES(?,?,?)",
                       (user["account_id"], room_id, time.time_ns()))
        return {"ok": True}

    @app.delete("/v1/favorites/{room_id}")
    def unfavorite(room_id: str, user=Depends(authenticated)):
        with database(settings) as db:
            db.execute("DELETE FROM favorites WHERE account_id=? AND room_id=?",
                       (user["account_id"], room_id))
        return {"ok": True}

    @app.post("/v1/history/{room_id}")
    def record_history(room_id: str, user=Depends(authenticated)):
        require_nickname(user)
        with database(settings) as db:
            find_room(db, room_id)
            db.execute("""INSERT INTO history VALUES(?,?,?) ON CONFLICT(account_id,room_id)
                          DO UPDATE SET visited_at=excluded.visited_at""",
                       (user["account_id"], room_id, time.time_ns()))
            db.execute("""DELETE FROM history WHERE account_id=? AND room_id NOT IN
                (SELECT room_id FROM history WHERE account_id=? ORDER BY visited_at DESC LIMIT 20)""",
                (user["account_id"], user["account_id"]))
        return {"ok": True}

    return app
