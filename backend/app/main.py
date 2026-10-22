"""KikiTalk Apple account, profile and legal-consent API.

Production voice authorization is exchanged with the independent LiveKit service.
Legacy room metadata and Tencent credentials remain available only when the
production voice bridge is explicitly disabled, including isolated QA fixtures.
"""

import asyncio
from collections import defaultdict, deque
from contextlib import asynccontextmanager, contextmanager, suppress
from dataclasses import dataclass
from datetime import date
import hashlib
import hmac
import ipaddress
from io import BytesIO
import json
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

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, field_validator
from starlette.exceptions import HTTPException as StarletteHTTPException

from .usersig import generate_user_sig
from .apple_auth import (AppleAuth, AppleGrantRevoked, CHALLENGE_SECONDS, VALIDATION_SECONDS,
                         NOTIFICATION_SECONDS, REVOCATION_SECONDS)
from . import gifts, voice_bridge, voice_incidents, admin, ops_auth, activity, social, push
from .community_content import PublicTextPolicy

LOGGER = logging.getLogger("kikitalk")
SESSION_SECONDS = 30 * 86400
SDK_SECONDS = 86400
CONSENT_WITHDRAWAL_RECEIPT_SECONDS = 86400
MAX_BODY = 16 * 1024
MAX_AVATAR_BODY = 2 * 1024 * 1024
AVATAR_NAME = re.compile(r"^[a-f0-9]{64}\.jpg$")
LEGAL_DOCUMENTS_PATH = Path(__file__).with_name("legal_documents.json")


def load_legal_manifest():
    """Load one verified text snapshot for both publication and consent checks."""
    try:
        manifest = json.loads(LEGAL_DOCUMENTS_PATH.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError("Invalid legal manifest")
        required = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
        for key in ("privacyVersion", "termsVersion"):
            if (not isinstance(required[key], str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}(?:-r[1-9][0-9]*)?", required[key])
                    or date.fromisoformat(required[key][:10]).isoformat() != required[key][:10]):
                raise ValueError("Invalid legal version")
        if not isinstance(required["documentHash"], str) or not re.fullmatch(r"[a-f0-9]{64}", required["documentHash"]):
            raise ValueError("Invalid legal document hash")
        if manifest.get("draft") is True or str(manifest.get("status", "")).lower() in {"draft", "草稿"}:
            raise ValueError("Legal documents are drafts")
        if manifest.get("schemaVersion") != 1 or manifest.get("minimumAge") != 18:
            raise ValueError("Invalid legal document schema or age policy")
        documents = manifest.get("documents")
        if (not isinstance(documents, list) or len(documents) != 4
                or not all(isinstance(item, dict) for item in documents)):
            raise ValueError("Missing legal documents")
        by_id = {item.get("id"): item for item in documents}
        if set(by_id) != {"privacy", "terms", "sdk", "permissions"}:
            raise ValueError("Incomplete legal documents")
        for document_id, document in by_id.items():
            version_key = "termsVersion" if document_id == "terms" else "privacyVersion"
            sections = document.get("sections")
            if (document.get("version") != required[version_key]
                    or not isinstance(document.get("title"), str) or not document["title"].strip()
                    or not isinstance(sections, list) or not sections):
                raise ValueError("Missing current legal document text")
            for section in sections:
                if (not isinstance(section, dict) or not isinstance(section.get("title"), str)
                        or not section["title"].strip() or not isinstance(section.get("paragraphs"), list)
                        or not section["paragraphs"] or any(not isinstance(p, str) or not p.strip()
                                                           for p in section["paragraphs"])):
                    raise ValueError("Invalid legal document paragraphs")
        canonical = json.dumps({key: value for key, value in manifest.items() if key != "documentHash"},
                               sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if not hmac.compare_digest(hashlib.sha256(canonical).hexdigest(), required["documentHash"]):
            raise ValueError("Legal document content hash mismatch")
        return manifest
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise RuntimeError("必须配置已发布的隐私政策和用户协议版本及内容哈希") from error


def load_legal_requirements():
    """Compatibility helper for tooling that only needs the current versions."""
    manifest = load_legal_manifest()
    return {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}


@dataclass(frozen=True)
class Settings:
    db_path: str
    sdk_app_id: int
    secret_key: str
    rate_limit_enabled: bool = True
    avatar_directory: str | None = None
    public_base_url: str = "https://kiki.group"
    apple_client_id: str = ""
    apple_team_id: str = ""
    apple_key_id: str = ""
    apple_private_key_path: str = ""
    apple_token_encryption_key: str = ""
    voice_bridge_enabled: bool = False
    voice_base_url: str = "https://furby.top"
    voice_bridge_secret: str = ""
    admin_auth_mode: str = "legacy"
    ops_bridge_secret: str = ""
    admin_passphrase_hash: str = ""
    admin_tls_cert_path: str = "/opt/kikitalk/shared/server-certificate.pem"
    admin_api_systemd_unit: str = "kikitalk.service"
    qa_gifts_enabled: bool = False
    qa_gifts_token: str = ""
    qa_gifts_expires_at: int = 0
    public_content_blocklist: str = ""
    apns_enabled: bool = False
    apns_team_id: str = ""
    apns_sandbox_key_id: str = ""
    apns_sandbox_private_key_path: str = ""
    apns_production_key_id: str = ""
    apns_production_private_key_path: str = ""

    @property
    def avatar_path(self):
        return Path(self.avatar_directory) if self.avatar_directory else Path(self.db_path).parent / "avatars"

    @classmethod
    def from_environment(cls):
        return cls(os.environ.get("DATABASE_PATH", "/var/lib/kikitalk/kikitalk.sqlite3"),
                   int(os.environ.get("SDKAPPID", "0")), os.environ.get("SECRETKEY", ""),
                   avatar_directory=os.environ.get("AVATAR_DIRECTORY"),
                   public_base_url=os.environ.get("PUBLIC_BASE_URL", "https://kiki.group"),
                   apple_client_id=os.environ.get("APPLE_CLIENT_ID", ""),
                   apple_team_id=os.environ.get("APPLE_TEAM_ID", ""),
                   apple_key_id=os.environ.get("APPLE_KEY_ID", ""),
                   apple_private_key_path=os.environ.get("APPLE_PRIVATE_KEY_PATH", ""),
                   apple_token_encryption_key=os.environ.get("APPLE_TOKEN_ENCRYPTION_KEY", ""),
                   voice_bridge_enabled=os.environ.get("VOICE_BRIDGE_ENABLED", "") == "1",
                   voice_base_url=os.environ.get("VOICE_BASE_URL", "https://furby.top"),
                   voice_bridge_secret=os.environ.get("ACCOUNT_VOICE_BRIDGE_SECRET", ""),
                   admin_auth_mode=os.environ.get("ADMIN_AUTH_MODE", "legacy"),
                   ops_bridge_secret=os.environ.get("OPS_BRIDGE_SECRET", ""),
                   admin_passphrase_hash=os.environ.get("ADMIN_PASSPHRASE_HASH", ""),
                   admin_tls_cert_path=os.environ.get("ADMIN_TLS_CERT_PATH", "/opt/kikitalk/shared/server-certificate.pem"),
                   admin_api_systemd_unit=os.environ.get("ADMIN_API_SYSTEMD_UNIT", "kikitalk.service"),
                   qa_gifts_enabled=os.environ.get("QA_GIFTS_ENABLED", "") == "1",
                   qa_gifts_token=os.environ.get("QA_GIFTS_TOKEN", ""),
                   qa_gifts_expires_at=int(os.environ.get("QA_GIFTS_EXPIRES_AT", "0")),
                   public_content_blocklist=os.environ.get("PUBLIC_CONTENT_BLOCKLIST", ""),
                   apns_enabled=os.environ.get("APNS_ENABLED", "") == "1",
                   apns_team_id=os.environ.get("APNS_TEAM_ID", ""),
                   apns_sandbox_key_id=os.environ.get("APNS_SANDBOX_KEY_ID", ""),
                   apns_sandbox_private_key_path=os.environ.get("APNS_SANDBOX_PRIVATE_KEY_PATH", ""),
                   apns_production_key_id=os.environ.get("APNS_PRODUCTION_KEY_ID", ""),
                   apns_production_private_key_path=os.environ.get("APNS_PRODUCTION_PRIVATE_KEY_PATH", ""))


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class LegalConsent(Model):
    privacyVersion: str | None = Field(default=None, min_length=1, max_length=32)
    termsVersion: str | None = Field(default=None, min_length=1, max_length=32)
    documentHash: str | None = Field(default=None, min_length=1, max_length=64)
    accepted: bool = Field(default=False, strict=True)
    adultConfirmed: bool = Field(default=False, strict=True)


class LegalConsentRequest(Model):
    legalConsent: LegalConsent | None = None


class AppleLogin(LegalConsentRequest):
    challengeID: str = Field(pattern=r"^[a-f0-9]{64}$")
    identityToken: str = Field(min_length=64, max_length=8192)
    authorizationCode: str = Field(min_length=1, max_length=2048)


class AppleNotification(Model):
    payload: str = Field(min_length=64, max_length=12000)


class QAGiftLogin(LegalConsentRequest):
    userID: str = Field(pattern=r"^[a-zA-Z0-9_]{3,32}$")
    name: str = Field(min_length=1, max_length=16)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value):
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("昵称不能包含控制字符")
        return value


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
-- Apple subject is never exposed as the public profile ID or Tencent SDK ID.
CREATE TABLE IF NOT EXISTS identities (
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  salt TEXT,
  secret_hash TEXT,
  PRIMARY KEY(provider, subject)
);
CREATE TABLE IF NOT EXISTS apple_challenges (
  challenge_id TEXT PRIMARY KEY,
  nonce_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS apple_challenge_expiry ON apple_challenges(expires_at);
CREATE TABLE IF NOT EXISTS apple_credentials (
  account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  refresh_token_encrypted TEXT NOT NULL,
  validated_at INTEGER NOT NULL,
  authenticated_at INTEGER NOT NULL,
  generation TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS apple_subject_events (
  subject_hash TEXT PRIMARY KEY,
  event_time INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS apple_notification_receipts (
  notification_id TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
-- No account ID or Apple subject is retained after deletion. This encrypted
-- credential remains personal data until successful revocation or its 7-day TTL.
CREATE TABLE IF NOT EXISTS apple_revocations (
  revocation_id TEXT PRIMARY KEY,
  refresh_token_encrypted TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS session_account ON sessions(account_id);
CREATE TABLE IF NOT EXISTS session_apple_grants (
  token_hash TEXT PRIMARY KEY REFERENCES sessions(token_hash) ON DELETE CASCADE,
  generation TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS legal_consent_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  privacy_version TEXT NOT NULL,
  terms_version TEXT NOT NULL,
  document_hash TEXT NOT NULL,
  accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
  adult_confirmed INTEGER NOT NULL CHECK(adult_confirmed IN (0,1)),
  recorded_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS legal_consent_account ON legal_consent_events(account_id,event_id DESC);
-- A withdrawal retry can only acknowledge its completed request. It can never
-- authenticate a business request or revoke sessions created after withdrawal.
CREATE TABLE IF NOT EXISTS legal_withdrawal_receipts (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS legal_withdrawal_expiry ON legal_withdrawal_receipts(expires_at);
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
    voice_bridge.validate_settings(settings)
    push.validate_settings(settings)
    admin.validate_admin_settings(settings)
    ops_auth.validate_settings(settings)
    if not settings.voice_bridge_enabled and (settings.sdk_app_id <= 0 or len(settings.secret_key) < 32):
        raise RuntimeError("请在服务端配置有效的 SDKAPPID 与 SECRETKEY")
    if settings.qa_gifts_enabled:
        # QA must never become an alternative production authentication path.
        # A separately named database and short lifetime are mandatory even when
        # this mode is accidentally enabled with the production environment.
        if not re.fullmatch(r"qa-gifts(?:-[A-Za-z0-9_-]+)?\.sqlite3", Path(settings.db_path).name):
            raise RuntimeError("礼物测试模式只能使用专用 qa-gifts*.sqlite3 数据库")
        if (not 43 <= len(settings.qa_gifts_token) <= 256 or len(set(settings.qa_gifts_token)) < 16
                or not int(time.time()) < settings.qa_gifts_expires_at <= int(time.time()) + 86400):
            raise RuntimeError("礼物测试模式需要高熵临时令牌和24小时内的到期时间")
    legal_manifest = load_legal_manifest()
    legal_requirements = {key: legal_manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    limits = RequestLimits()
    apple = AppleAuth(settings)
    refresh_locks = [threading.Lock() for _ in range(64)]
    revocation_lock = threading.Lock()
    bridge = voice_bridge.VoiceBridge(settings, database)
    incidents = voice_incidents.IncidentOutbox(settings, database, bridge)
    public_text = PublicTextPolicy(settings.public_content_blocklist)

    def qa_active():
        return settings.qa_gifts_enabled and int(time.time()) < settings.qa_gifts_expires_at

    def loopback_request(request):
        try:
            return request.client is not None and ipaddress.ip_address(request.client.host).is_loopback
        except ValueError:
            return False

    def purge_apple_metadata(db, now):
        db.execute("DELETE FROM apple_challenges WHERE expires_at<=?", (now,))
        db.execute("DELETE FROM apple_notification_receipts WHERE expires_at<=?", (now,))
        db.execute("DELETE FROM apple_subject_events WHERE expires_at<=?", (now,))

    def retry_apple_revocations(batch_limit=10):
        if not revocation_lock.acquire(blocking=False):
            return
        try:
            now = int(time.time())
            with database(settings) as db:
                expired = db.execute("SELECT COUNT(*) FROM apple_revocations WHERE created_at<=?",
                                     (now - REVOCATION_SECONDS,)).fetchone()[0]
                if expired:
                    LOGGER.error("Apple revocation retry retention expired: %s unresolved grants", expired)
                db.execute("DELETE FROM apple_revocations WHERE created_at<=?", (now - REVOCATION_SECONDS,))
                rows = db.execute("SELECT * FROM apple_revocations WHERE next_attempt_at<=? AND attempts<180 LIMIT ?",
                                  (now, batch_limit)).fetchall()
            for row in rows:
                try:
                    apple.revoke(row["refresh_token_encrypted"])
                except AppleGrantRevoked:
                    pass
                except Exception as error:
                    LOGGER.error("Apple authorization revocation pending: %s", type(error).__name__)
                    attempts = row["attempts"] + 1
                    with database(settings) as db:
                        db.execute("UPDATE apple_revocations SET attempts=?,next_attempt_at=? WHERE revocation_id=?",
                                   (attempts, now + min(3600, 60 * 2 ** min(attempts, 6)), row["revocation_id"]))
                    continue
                with database(settings) as db:
                    db.execute("DELETE FROM apple_revocations WHERE revocation_id=?", (row["revocation_id"],))
        finally:
            revocation_lock.release()

    def purge_withdrawal_receipts():
        with database(settings) as db:
            db.execute("DELETE FROM legal_withdrawal_receipts WHERE expires_at<=?", (int(time.time()),))
            purge_apple_metadata(db, int(time.time()))
            ops_auth.purge_expired(db)
            gifts.purge_gift_events(db, int(time.time()))
            activity.purge(db)
            social.purge(db)
            push.purge(db)
            if settings.voice_bridge_enabled:
                voice_incidents.purge(db)
        if hasattr(app.state,"social"):
            app.state.social.sweep_media()

    async def maintain_withdrawal_receipts():
        while True:
            await asyncio.sleep(60)
            try:
                await run_in_threadpool(purge_withdrawal_receipts)
                await run_in_threadpool(retry_apple_revocations)
            except Exception as error:
                LOGGER.error("Consent receipt cleanup failed: %s", type(error).__name__)

    async def maintain_voice_revocations():
        while True:
            await asyncio.sleep(5)
            try:
                await run_in_threadpool(bridge.retry_revocations)
                await run_in_threadpool(incidents.retry)
            except Exception as error:
                LOGGER.warning("Voice revocation maintenance pending: %s", type(error).__name__)

    async def maintain_push():
        while True:
            await asyncio.sleep(5)
            try:
                await run_in_threadpool(app.state.push.dispatch)
            except Exception as error:
                LOGGER.warning("APNs maintenance pending: %s", type(error).__name__)

    @asynccontextmanager
    async def lifespan(app):
        Path(settings.db_path).parent.mkdir(parents=True, exist_ok=True)
        settings.avatar_path.mkdir(mode=0o700, parents=True, exist_ok=True)
        with database(settings) as db:
            db.executescript(SCHEMA)
            db.executescript(gifts.SCHEMA)
            activity.initialize(db)
            social.initialize(db)
            push.initialize(db)
            admin.initialize_admin_database(db)
            ops_auth.initialize_database(db)
            if settings.admin_auth_mode == "passkey":
                db.execute("DELETE FROM account_admin_sessions")
            if settings.voice_bridge_enabled:
                voice_bridge.initialize_database(db)
                voice_incidents.initialize_database(db)
                voice_incidents.purge(db)
            if settings.qa_gifts_enabled and db.execute("""SELECT 1 FROM identities WHERE provider!='qa' LIMIT 1""").fetchone():
                raise RuntimeError("礼物测试数据库不能包含正式账号")
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
            db.execute("DELETE FROM legal_withdrawal_receipts WHERE expires_at<=?", (int(time.time()),))
            purge_apple_metadata(db, int(time.time()))
            gifts.migrate_wallets(db)
            gifts.purge_gift_events(db, int(time.time()))
        app.state.ops = ops_auth.OpsService(settings, database)
        app.state.social.ops = app.state.ops
        app.state.social.sweep_media()
        app.state.admin = admin.AdminService(settings, database)
        app.state.admin.start()
        receipt_cleanup = asyncio.create_task(maintain_withdrawal_receipts())
        voice_cleanup = asyncio.create_task(maintain_voice_revocations())
        push_cleanup = asyncio.create_task(maintain_push())
        try:
            yield
        finally:
            await app.state.ops.close()
            await app.state.admin.close()
            voice_cleanup.cancel()
            with suppress(asyncio.CancelledError):
                await voice_cleanup
            push_cleanup.cancel()
            with suppress(asyncio.CancelledError):
                await push_cleanup
            app.state.push.close()
            bridge.close()
            receipt_cleanup.cancel()
            with suppress(asyncio.CancelledError):
                await receipt_cleanup
            apple.close()

    app = FastAPI(title="KikiTalk API", version="1.0.0", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.voice_bridge = bridge
    app.state.voice_incidents = incidents
    app.state.apple_auth = apple
    app.state.retry_apple_revocations = retry_apple_revocations
    app.state.purge_privacy_metadata = purge_withdrawal_receipts

    @app.middleware("http")
    async def limit_request(request, call_next):
        if request.url.path in ("/v1/voice/session", "/v1/voice/incidents"):
            request.state.voice_request_id = str(uuid.uuid4())
        if settings.admin_auth_mode == "passkey" and request.url.path.startswith("/admin/v1"):
            return JSONResponse({"detail":"原口令管理入口已停用，请使用通行密钥登录"}, status_code=404,
                                headers={"Cache-Control":"no-store"})
        if request.url.path == "/v1/internal/qa/login" and not settings.qa_gifts_enabled:
            return JSONResponse({"detail": "接口不存在"}, status_code=404)
        if settings.qa_gifts_enabled and (not qa_active() or not loopback_request(request)):
            return JSONResponse({"detail": "接口不存在"}, status_code=404)
        if settings.voice_bridge_enabled and request.url.path.startswith(("/v1/rooms", "/v1/library", "/v1/favorites", "/v1/history")):
            return JSONResponse({"detail": "语聊房已迁移，请更新应用", "provider": "livekit"}, status_code=426, headers={"Cache-Control": "no-store"})
        maximum = (ops_auth.MAX_BODY if request.url.path.startswith("/admin/v2/") else
                   MAX_AVATAR_BODY if request.method == "POST" and request.url.path in ("/v1/me/avatar", "/v1/social/media") else MAX_BODY)
        content_length = request.headers.get("content-length")
        if content_length and (not content_length.isdigit() or int(content_length) > maximum):
            return JSONResponse({"detail": "请求内容过大"}, status_code=413, headers={"Cache-Control":"no-store"})
        # Reading through ASGI limits chunked bodies too; Request caches for call_next.
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > maximum:
                return JSONResponse({"detail": "请求内容过大"}, status_code=413, headers={"Cache-Control":"no-store"})
        request._body = bytes(body)
        try:
            if settings.rate_limit_enabled:
                ip = request.client.host if request.client else "unknown"
                # Shared Wi-Fi users need separate polling allowances. An
                # arbitrary bearer never qualifies, and authentication/control
                # endpoints retain their original anonymous/IP protection.
                session_key = None
                business_path = request.url.path.startswith("/v1/") and not request.url.path.startswith(("/v1/auth/", "/v1/internal/"))
                bearer = request.headers.get("authorization", "")
                if business_path and bearer.startswith("Bearer ") and re.fullmatch(r"[A-Za-z0-9_-]{43}", bearer[7:]):
                    token_hash = hashlib.sha256(bearer[7:].encode()).hexdigest()
                    provider = "qa" if settings.qa_gifts_enabled else "apple"
                    with database(settings) as db:
                        row = db.execute("""SELECT s.token_hash FROM sessions s JOIN accounts a ON a.account_id=s.account_id
                            WHERE s.token_hash=? AND s.expires_at>? AND EXISTS(SELECT 1 FROM identities i
                            WHERE i.account_id=a.account_id AND i.provider=?)""", (token_hash, int(time.time()), provider)).fetchone()
                    if row is not None:
                        session_key = row["token_hash"]
                if session_key is not None:
                    limits.check(("http-authenticated-ip", ip), 6000, 60)
                    limits.check(("http-session", session_key), 180, 60)
                else:
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
        if hasattr(request.state, "voice_request_id"):
            response.headers["X-Kiki-Request-ID"] = request.state.voice_request_id
        return response

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, _error):
        return JSONResponse({"detail": "参数不正确，请检查输入内容"}, status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_request, error):
        if error.status_code == 428 and isinstance(error.detail, dict):
            return JSONResponse(error.detail, status_code=428, headers=error.headers)
        return JSONResponse({"detail": error.detail}, status_code=error.status_code, headers=error.headers)

    def consent_required():
        raise HTTPException(428, {"detail": "请先阅读并同意当前版本的隐私政策和用户协议，并确认已满18周岁",
                                  "requiredVersions": legal_requirements})

    def validate_consent(payload):
        if payload is None or not payload.accepted or not payload.adultConfirmed:
            consent_required()
        if any(getattr(payload, key) != value for key, value in legal_requirements.items()):
            consent_required()

    def latest_consent(db, account_id):
        return db.execute("SELECT * FROM legal_consent_events WHERE account_id=? ORDER BY event_id DESC LIMIT 1",
                          (account_id,)).fetchone()

    def is_current_consent(row):
        return row is not None and row["accepted"] == 1 and row["adult_confirmed"] == 1 and all(
            row[column] == legal_requirements[key] for key, column in (
                ("privacyVersion", "privacy_version"), ("termsVersion", "terms_version"),
                ("documentHash", "document_hash")))

    def consent_status(db, account_id):
        row = latest_consent(db, account_id)
        record = None
        if row is not None:
            accepted_at = row["recorded_at"] if row["accepted"] else None
            if not row["accepted"]:
                previous = db.execute("""SELECT recorded_at FROM legal_consent_events
                    WHERE account_id=? AND event_id<? AND accepted=1 ORDER BY event_id DESC LIMIT 1""",
                    (account_id, row["event_id"])).fetchone()
                accepted_at = previous["recorded_at"] if previous else None
            record = {"privacyVersion": row["privacy_version"], "termsVersion": row["terms_version"],
                      "documentHash": row["document_hash"], "accepted": bool(row["accepted"]),
                      "adultConfirmed": bool(row["adult_confirmed"]), "acceptedAt": accepted_at,
                      "withdrawnAt": None if row["accepted"] else row["recorded_at"]}
        return {"requiredVersions": legal_requirements, "legalConsent": record,
                "requiresAcceptance": not is_current_consent(row)}

    def record_acceptance(db, account_id):
        if not is_current_consent(latest_consent(db, account_id)):
            db.execute("""INSERT INTO legal_consent_events
                (account_id,privacy_version,terms_version,document_hash,accepted,adult_confirmed,recorded_at)
                VALUES(?,?,?,?,1,1,?)""", (account_id, legal_requirements["privacyVersion"],
                legal_requirements["termsVersion"], legal_requirements["documentHash"], int(time.time())))

    def require_active_session(db, user, *, require_consent=True):
        if settings.qa_gifts_enabled and not qa_active():
            raise HTTPException(401, "测试会话已到期")
        session = db.execute("SELECT 1 FROM sessions WHERE token_hash=? AND account_id=? AND expires_at>?",
                             (user["token_hash"], user["account_id"], int(time.time()))).fetchone()
        if session is None:
            raise HTTPException(401, "登录已过期，请重新登录")
        if require_consent and not is_current_consent(latest_consent(db, user["account_id"])):
            consent_required()

    def request_token_hash(request):
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer ") or len(header) > 512:
            raise HTTPException(401, "请先登录")
        return hashlib.sha256(header[7:].encode()).hexdigest()

    def authenticated(request: Request):
        if settings.qa_gifts_enabled and not qa_active():
            raise HTTPException(401, "测试会话已到期")
        token_hash = request_token_hash(request)
        provider = "qa" if settings.qa_gifts_enabled else "apple"
        with database(settings) as db:
            row = db.execute("""SELECT a.*, s.token_hash FROM sessions s JOIN accounts a
                ON a.account_id=s.account_id WHERE s.token_hash=? AND s.expires_at>? AND EXISTS
                (SELECT 1 FROM identities i WHERE i.account_id=a.account_id AND i.provider=?)""",
                (token_hash, int(time.time()), provider)).fetchone()
        if row is None:
            raise HTTPException(401, "登录已过期，请重新登录")
        return dict(row)

    def require_current_consent(user):
        with database(settings) as db:
            require_active_session(db, user)

    def consented_user(user=Depends(authenticated)):
        require_current_consent(user)
        return user

    def sdk_credentials(user):
        # Keep this guard here as well as on business routes: future endpoints
        # must not accidentally issue Tencent credentials before legal acceptance.
        require_current_consent(user)
        if settings.voice_bridge_enabled:
            raise HTTPException(426, "请更新至支持自建语聊的版本")
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

    @app.get("/v1/legal/documents")
    def legal_documents():
        # Public text must remain readable before login or renewed consent.
        # Use the startup snapshot so it always matches consent validation.
        return JSONResponse(legal_manifest, headers={"Cache-Control": "no-store"})

    @app.post("/v1/auth/apple/challenge")
    def apple_challenge(request: Request):
        if settings.qa_gifts_enabled:
            raise HTTPException(404, "接口不存在")
        if settings.rate_limit_enabled:
            ip = request.client.host if request.client else "unknown"
            limits.check(("apple_challenge", ip), 20, 60)
        now = int(time.time())
        challenge_id, nonce = secrets.token_hex(32), secrets.token_urlsafe(32)
        with database(settings) as db:
            purge_apple_metadata(db, now)
            db.execute("INSERT INTO apple_challenges VALUES(?,?,?,?)",
                       (challenge_id, hashlib.sha256(nonce.encode()).hexdigest(), now, now + CHALLENGE_SECONDS))
        return {"challengeID": challenge_id, "nonce": nonce, "expiresAt": now + CHALLENGE_SECONDS}

    @app.post("/v1/auth/apple")
    def login(payload: AppleLogin, request: Request):
        if settings.qa_gifts_enabled:
            raise HTTPException(404, "接口不存在")
        if settings.rate_limit_enabled:
            ip = request.client.host if request.client else "unknown"
            limits.check(("auth_ip", ip), 20, 60)
        validate_consent(payload.legalConsent)
        now = int(time.time())
        # Commit consumption before network IO, including invalid authorization
        # attempts. Concurrent requests cannot both use one challenge.
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            challenge = db.execute("SELECT * FROM apple_challenges WHERE challenge_id=? AND expires_at>?",
                                   (payload.challengeID, now)).fetchone()
            db.execute("DELETE FROM apple_challenges WHERE challenge_id=?", (payload.challengeID,))
        if challenge is None:
            raise HTTPException(401, "登录验证已过期，请重新使用 Apple 登录")
        claims = apple.verify_identity(payload.identityToken, nonce=challenge["nonce_hash"],
                                       fresh_since=challenge["created_at"])
        if "c_hash" in claims:
            apple.verify_code_hash(payload.authorizationCode, claims["c_hash"])
        if settings.rate_limit_enabled:
            limits.check(("auth_subject", claims["sub"]), 12, 60)
        encrypted_refresh = apple.exchange_code(payload.authorizationCode, nonce=challenge["nonce_hash"],
                                                subject=claims["sub"], fresh_since=challenge["created_at"])
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            revoked = db.execute("SELECT event_time FROM apple_subject_events WHERE subject_hash=? AND expires_at>?",
                                 (hashlib.sha256(claims["sub"].encode()).hexdigest(), now)).fetchone()
            if revoked and claims["iat"] <= revoked["event_time"]:
                raise HTTPException(401, "Apple 授权已撤销，请重新登录")
            identity = db.execute("SELECT account_id FROM identities WHERE provider='apple' AND subject=?",
                                  (claims["sub"],)).fetchone()
            if identity:
                account_id = identity["account_id"]
            else:
                account_id = uuid.uuid4().hex
                public_id = "kiki_" + secrets.token_hex(8)
                sdk_user_id = "kiki_" + secrets.token_hex(13)
                db.execute("INSERT INTO accounts(account_id,login_id,sdk_user_id,name,created_at) VALUES(?,?,?,?,?)",
                           (account_id, public_id, sdk_user_id, "新朋友", now))
                db.execute("INSERT INTO identities(provider,subject,account_id) VALUES('apple',?,?)",
                           (claims["sub"], account_id))
            gifts.initialize_wallet(db, account_id, now)
            generation = uuid.uuid4().hex
            db.execute("""INSERT INTO apple_credentials VALUES(?,?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET
                refresh_token_encrypted=excluded.refresh_token_encrypted,validated_at=excluded.validated_at,
                authenticated_at=excluded.authenticated_at,generation=excluded.generation""",
                       (account_id, encrypted_refresh, now, claims["iat"], generation))
            record_acceptance(db, account_id)
            db.execute("DELETE FROM sessions WHERE expires_at<=?", (now,))
            db.execute("""DELETE FROM sessions WHERE account_id=? AND token_hash NOT IN
                (SELECT token_hash FROM sessions WHERE account_id=? ORDER BY created_at DESC LIMIT 4)""",
                       (account_id, account_id))
            token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            db.execute("INSERT INTO sessions VALUES(?,?,?,?)", (token_hash, account_id, now + SESSION_SECONDS, now))
            db.execute("INSERT INTO session_apple_grants VALUES(?,?)", (token_hash, generation))
            user = dict(db.execute("SELECT * FROM accounts WHERE account_id=?", (account_id,)).fetchone())
            user["token_hash"] = token_hash
        return {"token": token, "user": serialize_user(user, settings),
                **({} if settings.voice_bridge_enabled else {"sdk": sdk_credentials(user)})}

    @app.post("/v1/internal/qa/login")
    def qa_gift_login(payload: QAGiftLogin, request: Request):
        if not qa_active() or not loopback_request(request):
            raise HTTPException(404, "接口不存在")
        header = request.headers.get("authorization", "")
        if not hmac.compare_digest(header.encode(), ("Bearer " + settings.qa_gifts_token).encode()):
            raise HTTPException(404, "接口不存在")
        # Always rate-limit this bypass even if ordinary test traffic limits are
        # disabled. Each QA identity is confined to the dedicated QA database.
        limits.check(("qa_login", request.client.host), 20, 60)
        validate_consent(payload.legalConsent)
        now = int(time.time())
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            identity = db.execute("SELECT account_id FROM identities WHERE provider='qa' AND subject=?",
                                  (payload.userID,)).fetchone()
            if identity:
                account_id = identity["account_id"]
            else:
                account_id = uuid.uuid4().hex
                db.execute("""INSERT INTO accounts
                    (account_id,login_id,sdk_user_id,name,needs_nickname,created_at) VALUES(?,?,?,?,0,?)""",
                    (account_id, "qa_" + secrets.token_hex(8), "qa_" + secrets.token_hex(13), payload.name, now))
                db.execute("INSERT INTO identities(provider,subject,account_id) VALUES('qa',?,?)",
                           (payload.userID, account_id))
            gifts.initialize_wallet(db, account_id, now)
            record_acceptance(db, account_id)
            db.execute("DELETE FROM sessions WHERE account_id=?", (account_id,))
            token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            db.execute("INSERT INTO sessions VALUES(?,?,?,?)",
                       (token_hash, account_id, settings.qa_gifts_expires_at, now))
            user = dict(db.execute("SELECT * FROM accounts WHERE account_id=?", (account_id,)).fetchone())
            user["token_hash"] = token_hash
        return {"token": token, "user": serialize_user(user, settings),
                **({} if settings.voice_bridge_enabled else {"sdk": sdk_credentials(user)})}

    @app.post("/v1/auth/refresh")
    def refresh(user=Depends(consented_user)):
        if settings.qa_gifts_enabled:
            with database(settings) as db:
                require_active_session(db, user)
            return {"user": serialize_user(user, settings),
                **({} if settings.voice_bridge_enabled else {"sdk": sdk_credentials(user)})}
        # Serialize once-per-day Apple checks for this account, without holding a
        # SQLite transaction across any external request.
        lock_index = int(hashlib.sha256(user["account_id"].encode()).hexdigest()[:8], 16) % len(refresh_locks)
        with refresh_locks[lock_index]:
            with database(settings) as db:
                credential = db.execute("""SELECT c.*,i.subject FROM apple_credentials c JOIN identities i
                    ON c.account_id=i.account_id AND i.provider='apple' WHERE c.account_id=?""",
                    (user["account_id"],)).fetchone()
            if credential is None:
                raise HTTPException(401, "Apple 授权已失效，请重新登录")
            if credential["validated_at"] <= int(time.time()) - VALIDATION_SECONDS:
                try:
                    encrypted = apple.validate_refresh(credential["refresh_token_encrypted"], credential["subject"])
                except AppleGrantRevoked:
                    with database(settings) as db:
                        db.execute("BEGIN IMMEDIATE")
                        changed = db.execute("DELETE FROM apple_credentials WHERE account_id=? AND generation=?",
                                             (user["account_id"], credential["generation"])).rowcount
                        if changed:
                            db.execute("DELETE FROM account_activity_daily WHERE account_id=?", (user["account_id"],))
                            db.execute("DELETE FROM sessions WHERE account_id=?", (user["account_id"],))
                    if changed:
                        raise HTTPException(401, "Apple 授权已撤销，请重新登录")
                    # A fresh Apple authorization won while the old refresh was
                    # in flight. Its new credential and sessions remain valid.
                else:
                    with database(settings) as db:
                        db.execute("""UPDATE apple_credentials SET refresh_token_encrypted=?,validated_at=?
                            WHERE account_id=? AND generation=?""",
                            (encrypted, int(time.time()), user["account_id"], credential["generation"]))
            with database(settings) as db:
                db.execute("BEGIN IMMEDIATE")
                require_active_session(db, user)
                db.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?",
                           (int(time.time()) + SESSION_SECONDS, user["token_hash"]))
        return {"user": serialize_user(user, settings),
                **({} if settings.voice_bridge_enabled else {"sdk": sdk_credentials(user)})}

    def queue_voice_incident(user, event, *, source):
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            current = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
            consent_epoch = latest_consent(db, user["account_id"])["event_id"]
            withdrawal_epoch = db.execute("""SELECT COALESCE(MAX(event_id),0) FROM legal_consent_events
                WHERE account_id=? AND accepted=0""", (user["account_id"],)).fetchone()[0]
            return incidents.enqueue(db, current, event, consent_epoch=consent_epoch,
                                     last_withdrawal_epoch=withdrawal_epoch, source=source)

    @app.post("/v1/voice/incidents")
    def record_voice_incident(payload: voice_incidents.Incident, user=Depends(consented_user)):
        if not settings.voice_bridge_enabled:
            raise HTTPException(404, "接口不存在")
        if payload.platform not in ("ios", "ipados"):
            raise HTTPException(422, "客户端平台不正确")
        return {"ok": True, "queued": queue_voice_incident(user, payload, source="client")}

    @app.post("/v1/voice/session")
    def exchange_voice_session(request: Request, user=Depends(consented_user)):
        if not settings.voice_bridge_enabled:
            raise HTTPException(503, "语聊服务尚未启用")
        try:
            attempt_id = voice_incidents.canonical_uuid(request.headers.get("X-Kiki-Attempt-ID", str(uuid.uuid4())))
        except ValueError:
            raise HTTPException(422, "操作编号不正确") from None
        operation = request.headers.get("X-Kiki-Operation", "room_runtime")
        if operation not in ("create_room", "join_room", "room_runtime"):
            raise HTTPException(422, "操作类型不正确")
        started = time.monotonic()
        try:
            return perform_voice_exchange(user)
        except Exception as error:
            status = error.status_code if isinstance(error, HTTPException) else 500
            code = ({401: "http_unauthorized", 403: "http_forbidden", 404: "http_not_found",
                     409: "http_conflict", 428: "consent_required", 429: "http_rate_limited"}.get(status)
                    or ("http_server_error" if status >= 500 else "unknown_error"))
            # Only classify exception types. Never persist their text or HTTP
            # bodies, which may contain credentials or submitted user content.
            import httpx
            if isinstance(error.__cause__, httpx.TimeoutException):
                code = "request_timeout"
            elif isinstance(error.__cause__, httpx.NetworkError):
                code = "network_error"
            event = voice_incidents.Incident(eventID=str(uuid.uuid4()), attemptID=attempt_id,
                operation=operation, stage="account_authorization", severity="error" if status >= 500 else "warning",
                code=code, occurredAt=int(time.time()), elapsedMs=min(3600000, int((time.monotonic()-started)*1000)),
                requestID=request.state.voice_request_id, httpStatus=status,
                platform="server", appVersion="account-api", osVersion="server")
            try:
                queue_voice_incident(user, event, source="account")
            except HTTPException:
                # A concurrently withdrawn, revoked or deleted session cannot
                # create a new diagnostics record using its stale identity.
                pass
            except Exception as recording_error:
                LOGGER.warning("Voice incident journal unavailable: %s", type(recording_error).__name__)
            raise

    def perform_voice_exchange(user):
        # Reuse the established daily Apple grant validation even during a long
        # voice call whose client is otherwise only renewing its media lease.
        refresh(user)
        with database(settings) as db:
            require_active_session(db, user)
            session = db.execute("SELECT * FROM sessions WHERE token_hash=?", (user["token_hash"],)).fetchone()
            current = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
            profile = serialize_user(current, settings)
            consent_epoch = latest_consent(db, user["account_id"])["event_id"]
            last_withdrawal_epoch = db.execute("""SELECT COALESCE(MAX(event_id),0) FROM legal_consent_events
                WHERE account_id=? AND accepted=0""", (user["account_id"],)).fetchone()[0]
        result = bridge.exchange(user, session, legal_requirements, profile, consent_epoch, last_withdrawal_epoch)
        # Logout/deletion racing a slow exchange must not return new credentials.
        with database(settings) as db:
            require_active_session(db, user)
        return result

    @app.post("/v1/auth/logout")
    def logout(user=Depends(authenticated)):
        with database(settings) as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?", (user["token_hash"],))
        bridge.retry_revocations(1)
        return {"ok": True}

    @app.post("/v1/auth/apple/revoked")
    def apple_revoked(user=Depends(authenticated)):
        # Client state may sign out sessions but never delete an account. A
        # delayed retry from a prior Apple grant cannot invalidate fresh login.
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT generation FROM apple_credentials WHERE account_id=?",
                                 (user["account_id"],)).fetchone()
            session = db.execute("SELECT generation FROM session_apple_grants WHERE token_hash=?",
                                 (user["token_hash"],)).fetchone()
            if current and session and current["generation"] == session["generation"]:
                db.execute("DELETE FROM account_activity_daily WHERE account_id=?", (user["account_id"],))
                db.execute("DELETE FROM sessions WHERE account_id=?", (user["account_id"],))
            elif session:
                db.execute("""DELETE FROM sessions WHERE account_id=? AND token_hash IN
                    (SELECT token_hash FROM session_apple_grants WHERE generation=?)""",
                           (user["account_id"], session["generation"]))
        bridge.retry_revocations(1)
        return {"ok": True}

    @app.get("/v1/me/legal-consent")
    def get_legal_consent(user=Depends(authenticated)):
        with database(settings) as db:
            require_active_session(db, user, require_consent=False)
            return consent_status(db, user["account_id"])

    @app.post("/v1/me/legal-consent")
    def accept_legal_consent(payload: LegalConsentRequest, user=Depends(authenticated)):
        validate_consent(payload.legalConsent)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user, require_consent=False)
            record_acceptance(db, user["account_id"])
            return consent_status(db, user["account_id"])

    @app.delete("/v1/me/legal-consent")
    def withdraw_legal_consent(request: Request):
        token_hash = request_token_hash(request)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            db.execute("DELETE FROM legal_withdrawal_receipts WHERE expires_at<=?", (now,))
            if db.execute("SELECT 1 FROM legal_withdrawal_receipts WHERE token_hash=?", (token_hash,)).fetchone():
                return {"ok": True}
            user = db.execute("""SELECT a.* FROM sessions s JOIN accounts a ON a.account_id=s.account_id
                WHERE s.token_hash=? AND s.expires_at>? AND EXISTS
                (SELECT 1 FROM identities i WHERE i.account_id=a.account_id AND i.provider=?)""",
                (token_hash, now, "qa" if settings.qa_gifts_enabled else "apple")).fetchone()
            if user is None:
                # Return after committing expiry cleanup, even for an expired
                # retry token. A raised exception would roll that cleanup back.
                return JSONResponse({"detail": "登录已过期，请重新登录"}, status_code=401)
            previous = latest_consent(db, user["account_id"])
            withdrawal = db.execute("""INSERT INTO legal_consent_events
                (account_id,privacy_version,terms_version,document_hash,accepted,adult_confirmed,recorded_at)
                VALUES(?,?,?,?,0,?,?)""", (user["account_id"],
                previous["privacy_version"] if previous else legal_requirements["privacyVersion"],
                previous["terms_version"] if previous else legal_requirements["termsVersion"],
                previous["document_hash"] if previous else legal_requirements["documentHash"],
                previous["adult_confirmed"] if previous else 0, now))
            bridge.queue_authorization_withdrawal(db, user["account_id"], withdrawal.lastrowid, user["login_id"])
            if settings.voice_bridge_enabled:
                db.execute("DELETE FROM voice_incident_outbox WHERE account_id=?", (user["account_id"],))
            db.execute("DELETE FROM sessions WHERE account_id=?", (user["account_id"],))
            db.execute("DELETE FROM account_activity_daily WHERE account_id=?", (user["account_id"],))
            social.erase(db, user["account_id"])
            db.execute("INSERT INTO legal_withdrawal_receipts VALUES(?,?,?)",
                       (token_hash, user["account_id"], now + CONSENT_WITHDRAWAL_RECEIPT_SECONDS))
        bridge.retry_revocations(1)
        return {"ok": True}

    @app.get("/v1/me")
    def get_me(user=Depends(consented_user)):
        return serialize_user(user, settings)

    @app.post("/v1/me/activity")
    def record_activity(_payload: ops_auth.Empty, user=Depends(consented_user)):
        # Explicit foreground signal only. GET /me, login leases, health probes
        # and operations sessions never manufacture daily active accounts.
        if settings.rate_limit_enabled:
            limits.check(("foreground_activity", user["account_id"]), 120, 3600)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            return activity.record(db, user["account_id"])

    @app.patch("/v1/me")
    def update_me(payload: ProfileUpdate, user=Depends(consented_user)):
        fields = payload.model_dump(exclude_unset=True, exclude_none=True)
        public_text.check_profile(name=fields.get("name"), bio=fields.get("bio"))
        columns = {"name": "name", "bio": "bio", "avatarIndex": "avatar_index",
                   "notificationsEnabled": "notifications"}
        old_avatar = None
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            current = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
            if current is None:
                raise HTTPException(401, "登录已过期，请重新登录")
            for field, value in fields.items():
                db.execute(f"UPDATE accounts SET {columns[field]}=? WHERE account_id=?",
                           (value, user["account_id"]))
            if fields.get("notificationsEnabled") is False:
                db.execute("UPDATE push_outbox SET state='cancelled',completed_at=?,lease_id=NULL,lease_until=NULL WHERE recipient_id=? AND state IN ('pending','sending')",(int(time.time()),user["account_id"]))
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
                require_active_session(db, user)
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
    async def upload_avatar(request: Request, user=Depends(consented_user)):
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

    def erase_account(db, account_id, *, queue_revocation):
        current = db.execute("SELECT avatar_filename,login_id FROM accounts WHERE account_id=?", (account_id,)).fetchone()
        if current is None:
            return None
        bridge.queue_account_delete(db, current["login_id"])
        if queue_revocation:
            credential = db.execute("SELECT refresh_token_encrypted FROM apple_credentials WHERE account_id=?",
                                    (account_id,)).fetchone()
            if credential:
                now = int(time.time())
                db.execute("INSERT INTO apple_revocations VALUES(?,?,0,?,?)",
                           (uuid.uuid4().hex, credential["refresh_token_encrypted"], now, now))
        db.execute("""UPDATE rooms SET status='ended',host_id='anonymous',host_name='已注销用户',
            title='已结束的房间',category='其他',host_avatar_index=0,host_avatar_filename=NULL WHERE owner_id=?""",
                   (account_id,))
        social.erase(db, account_id)
        db.execute("DELETE FROM accounts WHERE account_id=?", (account_id,))
        return current["avatar_filename"]

    @app.delete("/v1/account")
    def delete_account(background_tasks: BackgroundTasks, user=Depends(authenticated)):
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user, require_consent=False)
            filename = erase_account(db, user["account_id"], queue_revocation=True)
        remove_avatar(filename, settings)
        # Local deletion has already committed and is never rolled back because
        # Apple's endpoint is unavailable. Its minimal encrypted receipt retries.
        bridge.retry_revocations(1)
        background_tasks.add_task(retry_apple_revocations, 1)
        return {"ok": True}

    @app.post("/v1/auth/apple/notifications")
    def apple_notification(payload: AppleNotification):
        if settings.qa_gifts_enabled:
            raise HTTPException(404, "接口不存在")
        notification_id, event = apple.verify_notification(payload.payload)
        filename = None
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            purge_apple_metadata(db, now)
            if db.execute("SELECT 1 FROM apple_notification_receipts WHERE notification_id=?", (notification_id,)).fetchone():
                return {"ok": True}
            db.execute("INSERT INTO apple_notification_receipts VALUES(?,?)", (notification_id, now + NOTIFICATION_SECONDS + 60))
            if event["type"] in ("consent-revoked", "account-deleted"):
                db.execute("""INSERT INTO apple_subject_events VALUES(?,?,?) ON CONFLICT(subject_hash) DO UPDATE SET
                    event_time=MAX(event_time,excluded.event_time),expires_at=excluded.expires_at""",
                    (hashlib.sha256(event["sub"].encode()).hexdigest(), event["event_time"], now + NOTIFICATION_SECONDS + 60))
            identity = db.execute("""SELECT i.account_id,c.authenticated_at FROM identities i LEFT JOIN apple_credentials c
                ON c.account_id=i.account_id WHERE i.provider='apple' AND i.subject=?""", (event["sub"],)).fetchone()
            # A delayed prior revocation must not delete a subsequently authorized
            # account. Notification token replay is separately recorded above.
            if identity and (identity["authenticated_at"] is None or event["event_time"] >= identity["authenticated_at"]):
                if event["type"] in ("consent-revoked", "account-deleted"):
                    filename = erase_account(db, identity["account_id"], queue_revocation=False)
        remove_avatar(filename, settings)
        bridge.retry_revocations(1)
        return {"ok": True}

    @app.get("/v1/rooms")
    def list_rooms(user=Depends(consented_user)):
        with database(settings) as db:
            rows = db.execute("SELECT * FROM rooms ORDER BY created_at DESC,id DESC LIMIT 500").fetchall()
        return {"rooms": [serialize_room(row, user["account_id"], settings) for row in rows]}

    @app.post("/v1/rooms/lookup")
    def lookup_rooms(payload: RoomLookup, user=Depends(consented_user)):
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
    def create_room(payload: RoomCreate, user=Depends(consented_user)):
        require_nickname(user)
        if settings.rate_limit_enabled:
            limits.check(("room_create", user["account_id"]), 20, 3600)
        prefix = ("qa_live_" if payload.isLive else "qa_voice_") if settings.qa_gifts_enabled else ("live_kiki_" if payload.isLive else "voice_kiki_")
        room_id = prefix + uuid.uuid4().hex[:24]
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            db.execute("""INSERT INTO rooms(id,owner_id,host_id,host_name,host_avatar_index,host_avatar_filename,title,category,is_live,theme,created_at)
                       VALUES(?,?,?,?,?,?,?,?,?,?,?)""", (room_id, user["account_id"], user["sdk_user_id"],
                       user["name"], user["avatar_index"], user["avatar_filename"], payload.title, payload.category, payload.isLive, payload.theme, int(time.time())))
            row = find_room(db, room_id)
        return serialize_room(row, user["account_id"], settings)

    @app.get("/v1/rooms/{room_id}")
    def get_room(room_id: str, user=Depends(consented_user)):
        with database(settings) as db:
            row = find_room(db, room_id)
        return serialize_room(row, user["account_id"], settings)

    @app.patch("/v1/rooms/{room_id}")
    def update_room(room_id: str, payload: RoomUpdate, user=Depends(consented_user)):
        if payload.status == "live":
            require_nickname(user)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            row = find_room(db, room_id)
            if row["owner_id"] != user["account_id"]:
                raise HTTPException(403, "只有房主可以修改房间状态")
            if row["status"] == "ended" and payload.status != "ended":
                raise HTTPException(409, "房间已经结束，请创建新房间")
            db.execute("UPDATE rooms SET status=? WHERE id=?", (payload.status, room_id))
            row = find_room(db, room_id)
        return serialize_room(row, user["account_id"], settings)

    @app.get("/v1/library")
    def library(user=Depends(consented_user)):
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
    def favorite(room_id: str, user=Depends(consented_user)):
        with database(settings) as db:
            # Serialize the capacity check and insertion; a retry of an existing
            # favorite succeeds even when the library is at capacity.
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
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
    def unfavorite(room_id: str, user=Depends(consented_user)):
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            db.execute("DELETE FROM favorites WHERE account_id=? AND room_id=?",
                       (user["account_id"], room_id))
        return {"ok": True}

    @app.post("/v1/history/{room_id}")
    def record_history(room_id: str, user=Depends(consented_user)):
        require_nickname(user)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            find_room(db, room_id)
            db.execute("""INSERT INTO history VALUES(?,?,?) ON CONFLICT(account_id,room_id)
                          DO UPDATE SET visited_at=excluded.visited_at""",
                       (user["account_id"], room_id, time.time_ns()))
            db.execute("""DELETE FROM history WHERE account_id=? AND room_id NOT IN
                (SELECT room_id FROM history WHERE account_id=? ORDER BY visited_at DESC LIMIT 20)""",
                (user["account_id"], user["account_id"]))
        return {"ok": True}

    gifts.install_routes(app, settings, database=database, consented_user=consented_user,
                         require_active_session=require_active_session, require_nickname=require_nickname,
                         avatar_url=avatar_url, find_room=find_room, limits=limits)
    app.state.social = social.SocialService(settings, database, bridge, legal_requirements, require_active_session, limits)
    app.state.social.ops = app.state.ops if hasattr(app.state,"ops") else None
    app.state.push = push.PushService(settings,database,app.state.social,limits)
    app.state.social.push = app.state.push
    app.include_router(push.build_router(app,consented_user=consented_user,authenticated=authenticated))
    app.include_router(social.build_router(app, consented_user=consented_user))
    app.include_router(admin.build_admin_router(app))
    app.include_router(ops_auth.build_router(app))
    return app
