"""Single-worker, loopback-only backend for the independent LiveKit experiment."""
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from contextlib import suppress
from dataclasses import dataclass
import asyncio
import hashlib
import hmac
import ipaddress
import json
import logging
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
import uuid

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import account_bridge, ops_gateway, safety, incidents, social_policy, seating, room_catalog, room_started
from .rtc import LiveKitGateway
from .signal_gateway import SignalAuthorization, SignalGateway
from .chat import RoomChatStore, initialize_chat_database, validate_text
from .observability import LabObservability, QualityReport
from .admin import AdminService, build_admin_router, initialize_admin_database, validate_admin_settings

SESSION_SECONDS = 7 * 86400
DISCONNECT_GRACE_SECONDS = 60
OWNER_DISCONNECT_GRACE_SECONDS = 15
MAX_BODY = 16 * 1024
LOGGER = logging.getLogger("kiki.livekit.lab")


@dataclass(frozen=True)
class Settings:
    db_path: str
    legal_path: str
    livekit_url: str = "http://127.0.0.1:7880"
    public_url: str = "wss://furby.top"
    api_key: str = ""
    api_secret: str = ""
    access_code: str = ""
    rate_limit_enabled: bool = True
    max_active_rooms: int = 4
    max_room_participants: int = 32
    max_total_participants: int = 64
    authenticated_ip_limit: int = 18000
    auth_mode: str = "lab"
    account_bridge_secret: str = ""
    admin_auth_mode: str = "legacy"
    ops_bridge_secret: str = ""
    admin_passphrase_hash: str = ""
    admin_tls_cert_path: str = "/opt/kiki-livekit-lab/shared/server-certificate.pem"
    safety_terms_path: str = ""

    @classmethod
    def from_environment(cls):
        return cls(db_path=os.environ.get("LAB_DB_PATH", "/var/lib/kiki-livekit-lab/lab.sqlite3"),
                   legal_path=os.environ.get("LEGAL_DOCUMENTS_PATH", "../shared/legal_documents.json"),
                   livekit_url=os.environ.get("LIVEKIT_URL", "http://127.0.0.1:7880"),
                   public_url=os.environ.get("LIVEKIT_PUBLIC_URL", "wss://furby.top"),
                   api_key=os.environ.get("LIVEKIT_API_KEY", ""),
                   api_secret=os.environ.get("LIVEKIT_API_SECRET", ""),
                   access_code=os.environ.get("LAB_ACCESS_CODE", ""),
                   auth_mode=os.environ.get("VOICE_AUTH_MODE", "account"),
                   account_bridge_secret=os.environ.get("ACCOUNT_VOICE_BRIDGE_SECRET", ""),
                   max_active_rooms=int(os.environ.get("LAB_MAX_ACTIVE_ROOMS", "4")),
                   max_room_participants=int(os.environ.get("LAB_MAX_ROOM_PARTICIPANTS", "32")),
                   max_total_participants=int(os.environ.get("LAB_MAX_TOTAL_PARTICIPANTS", "64")),
                   authenticated_ip_limit=int(os.environ.get("LAB_HTTP_AUTHENTICATED_IP_LIMIT", "18000")),
                   admin_auth_mode=os.environ.get("ADMIN_AUTH_MODE", "legacy"),
                   ops_bridge_secret=os.environ.get("OPS_BRIDGE_SECRET", ""),
                   admin_passphrase_hash=os.environ.get("ADMIN_PASSPHRASE_HASH", ""),
                   safety_terms_path=os.environ.get("SAFETY_TERMS_PATH", ""),
                   admin_tls_cert_path=os.environ.get("ADMIN_TLS_CERT_PATH", "/opt/kiki-livekit-lab/shared/server-certificate.pem"))

    def validate(self):
        account_bridge.validate_settings(self)
        if (self.auth_mode == "lab" and len(self.access_code) < 16) or not self.api_key or len(self.api_secret) < 32:
            raise RuntimeError("Configure separate laboratory credentials before starting")
        if self.public_url != "wss://furby.top" or self.livekit_url != "http://127.0.0.1:7880":
            raise RuntimeError("Only the isolated laboratory LiveKit endpoints are permitted")
        if (not 1 <= self.max_active_rooms <= 20 or not 8 <= self.max_room_participants <= 100
                or not self.max_room_participants <= self.max_total_participants <= 1000):
            raise RuntimeError("Configure valid laboratory capacity limits")
        if not 6000 <= self.authenticated_ip_limit <= 60000:
            raise RuntimeError("Configure a bounded authenticated shared-network allowance")
        ops_gateway.validate_settings(self)
        validate_admin_settings(self)


def load_legal_manifest(path):
    try:
        manifest = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError("Invalid manifest")
        required = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
        if (manifest.get("schemaVersion") != 1 or manifest.get("minimumAge") != 18
                or manifest.get("draft") is True or manifest.get("status") == "draft"
                or not all(isinstance(value, str) and value for value in required.values())
                or not re.fullmatch("[a-f0-9]{64}", required["documentHash"])):
            raise ValueError("Invalid manifest")
        entries = manifest["documents"]
        if (not isinstance(entries, list) or len(entries) != 4
                or not all(isinstance(entry, dict) for entry in entries)):
            raise ValueError("Incomplete documents")
        documents = {entry["id"]: entry for entry in entries}
        if set(documents) != {"privacy", "terms", "sdk", "permissions"}:
            raise ValueError("Incomplete documents")
        for document_id, doc in documents.items():
            version_key = "termsVersion" if document_id == "terms" else "privacyVersion"
            if doc["version"] != required[version_key]:
                raise ValueError("Mismatched document versions")
            sections = doc.get("sections")
            if (not isinstance(doc.get("title"), str) or not doc["title"].strip()
                    or not isinstance(sections, list) or not sections):
                raise ValueError("Missing document text")
            for section in sections:
                if (not isinstance(section, dict) or not isinstance(section.get("title"), str)
                        or not section["title"].strip() or not isinstance(section.get("paragraphs"), list)
                        or not section["paragraphs"] or any(not isinstance(p, str) or not p.strip()
                                                           for p in section["paragraphs"])):
                    raise ValueError("Invalid document paragraphs")
        canonical = json.dumps({key: value for key, value in manifest.items() if key != "documentHash"},
                               sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if not hmac.compare_digest(hashlib.sha256(canonical).hexdigest(), required["documentHash"]):
            raise ValueError("Invalid document digest")
        return manifest
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise RuntimeError("A valid published laboratory legal document manifest is required") from error


def load_legal(path):
    """Compatibility helper for tooling that only needs the current versions."""
    manifest = load_legal_manifest(path)
    return {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Acceptance(Model):
    privacyVersion: str = Field(max_length=64)
    termsVersion: str = Field(max_length=64)
    documentHash: str = Field(max_length=64)
    accepted: bool = Field(strict=True)
    adultConfirmed: bool = Field(strict=True)


class ConsentRequest(Model):
    legalConsent: Acceptance | None = None


class LabLogin(ConsentRequest):
    name: str = Field(min_length=1, max_length=16)
    accessCode: str = Field(min_length=1, max_length=128)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value):
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid name")
        return value


class ProfileUpdate(Model):
    name: str | None = Field(default=None, min_length=1, max_length=16)
    bio: str | None = Field(default=None, max_length=80)
    avatarIndex: int | None = Field(default=None, strict=True, ge=0, le=11)
    notificationsEnabled: bool | None = Field(default=None, strict=True)

    @field_validator("name", "bio")
    @classmethod
    def clean_text(cls, value):
        if value is not None and any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid text")
        return value


def default_room_title(name):
    suffix = "的房间"
    prefix = ""
    for char in str(name or "我").strip():
        if ord(char) < 32 or ord(char) == 127:
            continue
        candidate = prefix + char + suffix
        if len(candidate) > 36 or len(candidate.encode("utf-8")) > 100:
            break
        prefix += char
    return (prefix or "我") + suffix


def clean_room_title(value):
    # Preserve the existing 40-codepoint backend boundary for older clients;
    # current clients additionally cap visible graphemes at 36.
    if any(ord(char) < 32 or ord(char) == 127 for char in value) or len(value.encode("utf-8")) > 100:
        raise ValueError("Invalid room title")
    return value


class RoomCreate(Model):
    title: str = Field(default="", max_length=40)
    category: str = Field(min_length=1, max_length=12)
    isLive: bool = Field(strict=True)
    theme: int = Field(strict=True, ge=0, le=4)

    @field_validator("title")
    @classmethod
    def clean_title(cls, value):
        return clean_room_title(value)

    @field_validator("category")
    @classmethod
    def clean_text(cls, value):
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid text")
        return value


class RoomUpdate(Model):
    status: str | None = Field(default=None, pattern="^(live|active|closed|ended)$")
    title: str | None = Field(default=None, max_length=40)
    theme: int | None = Field(default=None, strict=True, ge=0, le=4)

    @field_validator("title")
    @classmethod
    def clean_title(cls, value):
        return clean_room_title(value) if value is not None else value

    @model_validator(mode="after")
    def one_operation(self):
        edits = self.title is not None or self.theme is not None
        if (self.status is None) == (not edits):
            raise ValueError("Supply status alone, or title/theme edits")
        return self


class RoomLookup(Model):
    ids: list[str] = Field(max_length=100)


class RoomAction(Model):
    action: str = Field(pattern="^(request_seat|cancel_request|approve_request|reject_request|invite_seat|accept_invite|decline_invite|leave_seat|move_seat|remove_seat|lock_seat|lock_audio|mute_audio|mute_chat|set_admin|kick|unban)$")
    targetUserID: str | None = Field(default=None, min_length=1, max_length=64)
    seatIndex: int | None = Field(default=None, strict=True, ge=1, le=8)
    enabled: bool | None = Field(default=None, strict=True)


class ChatSend(Model):
    clientMessageID: str = Field(min_length=36, max_length=36)
    text: str = Field(max_length=2000)

    @field_validator("clientMessageID")
    @classmethod
    def clean_id(cls, value):
        return str(uuid.UUID(value))

    @field_validator("text")
    @classmethod
    def clean_text(cls, value):
        return validate_text(value)


class AnnouncementUpdate(Model):
    text: str = Field(max_length=2000)

    @field_validator("text")
    @classmethod
    def clean_text(cls, value):
        return validate_text(value, empty=True)


class Limiter:
    def __init__(self):
        self.events = defaultdict(deque)

    def check(self, key, limit, period):
        now = time.monotonic()
        events = self.events[key]
        while events and events[0] < now - period:
            events.popleft()
        if len(events) >= limit:
            raise HTTPException(429, "请求过于频繁，请稍后重试", headers={"Retry-After": str(period)})
        events.append(now)
        if len(self.events) > 10000:
            for old_key in list(self.events):
                if not self.events[old_key] or self.events[old_key][-1] < now - 3600:
                    del self.events[old_key]


def initialize_database(path):
    directory = Path(path).parent
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = sqlite3.connect(path, check_same_thread=False)
    os.chmod(path, 0o600)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA secure_delete=ON")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, bio TEXT NOT NULL DEFAULT '',
        avatar_index INTEGER NOT NULL DEFAULT 0, notifications INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
        expires_at INTEGER NOT NULL, revoked_at INTEGER, revoked_reason TEXT);
    CREATE TABLE IF NOT EXISTS consents (
        user_id TEXT PRIMARY KEY REFERENCES users(id), privacy_version TEXT NOT NULL,
        terms_version TEXT NOT NULL, document_hash TEXT NOT NULL,
        accepted_at INTEGER NOT NULL, withdrawn_at INTEGER);
    CREATE TABLE IF NOT EXISTS rooms (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES users(id), title TEXT NOT NULL,
        category TEXT NOT NULL, theme INTEGER NOT NULL, status TEXT NOT NULL,
        created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS memberships (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        issued_at INTEGER NOT NULL, PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS favorites (
        user_id TEXT NOT NULL REFERENCES users(id), room_id TEXT NOT NULL REFERENCES rooms(id),
        created_at INTEGER NOT NULL, PRIMARY KEY(user_id,room_id));
    CREATE TABLE IF NOT EXISTS history (
        user_id TEXT NOT NULL REFERENCES users(id), room_id TEXT NOT NULL REFERENCES rooms(id),
        created_at INTEGER NOT NULL, PRIMARY KEY(user_id,room_id));
    CREATE TABLE IF NOT EXISTS deletion_requests (
        user_id TEXT PRIMARY KEY REFERENCES users(id), requested_at INTEGER NOT NULL,
        completed_at INTEGER);
    CREATE TABLE IF NOT EXISTS room_revisions (
        room_id TEXT PRIMARY KEY REFERENCES rooms(id), revision INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS room_members (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        session_hash TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 0,
        role TEXT NOT NULL DEFAULT 'member', active INTEGER NOT NULL DEFAULT 1,
        audio_muted INTEGER NOT NULL DEFAULT 0, chat_muted INTEGER NOT NULL DEFAULT 0,
        joined_at INTEGER NOT NULL, PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS room_seats (
        room_id TEXT NOT NULL REFERENCES rooms(id), seat_index INTEGER NOT NULL CHECK(seat_index BETWEEN 1 AND 8),
        user_id TEXT REFERENCES users(id), locked INTEGER NOT NULL DEFAULT 0,
        audio_locked INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(room_id,seat_index), UNIQUE(room_id,user_id));
    CREATE TABLE IF NOT EXISTS seat_requests (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        requested_at INTEGER NOT NULL, PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS seat_invitations (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        seat_index INTEGER NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS room_bans (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        banned_at INTEGER NOT NULL, PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS media_cleanup (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        kind TEXT NOT NULL, PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS room_presence (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        offline_since INTEGER, PRIMARY KEY(room_id,user_id));
    """)
    account_bridge.initialize_database(db)
    initialize_chat_database(db)
    initialize_admin_database(db)
    ops_gateway.initialize_database(db)
    safety.initialize_database(db)
    incidents.initialize_database(db)
    social_policy.initialize_database(db)
    seating.initialize_database(db)
    room_catalog.initialize_database(db)
    room_started.initialize_database(db)
    if "signal_disconnected" not in {row["name"] for row in db.execute("PRAGMA table_info(room_members)")}:
        db.execute("ALTER TABLE room_members ADD COLUMN signal_disconnected INTEGER NOT NULL DEFAULT 0")
        db.execute("""UPDATE room_members SET signal_disconnected=1 WHERE active=1 AND EXISTS(
            SELECT 1 FROM room_presence p WHERE p.room_id=room_members.room_id
            AND p.user_id=room_members.user_id AND p.offline_since IS NOT NULL)""")
    # Recover deletion requests made by the earlier laboratory build before this durable
    # intent table existed. Do not depend on the client retaining its revoked bearer.
    db.execute("""INSERT OR IGNORE INTO deletion_requests(user_id,requested_at)
        SELECT user_id,MIN(revoked_at) FROM sessions
        WHERE revoked_reason='deleted' AND revoked_at IS NOT NULL GROUP BY user_id""")
    db.commit()
    return db


def create_app(settings=None, gateway=None):
    settings = settings or Settings.from_environment()
    lock = asyncio.Lock()
    limiter = Limiter()
    connections = {}
    disconnect_deadlines = {}
    known_presence = {}
    known_online_members = {}
    presence_epochs = defaultdict(int)
    observability = LabObservability()

    @asynccontextmanager
    async def lifespan(app):
        settings.validate()
        app.state.legal_manifest = load_legal_manifest(settings.legal_path)
        app.state.legal = {key: app.state.legal_manifest[key]
                           for key in ("privacyVersion", "termsVersion", "documentHash")}
        app.state.db = initialize_database(settings.db_path)
        app.state.room_catalog = room_catalog.RoomCatalog(app.state.db, lock)
        if settings.admin_auth_mode == "passkey":
            with app.state.db:
                app.state.db.execute("DELETE FROM admin_sessions")
        if settings.auth_mode == "account":
            with app.state.db:
                app.state.db.execute("UPDATE sessions SET revoked_at=COALESCE(revoked_at,?),revoked_reason='mode-switch' WHERE token_hash NOT IN (SELECT token_hash FROM account_authorizations)", (int(time.time()),))
        app.state.chat = RoomChatStore(app.state.db, Limiter())
        app.state.seating = seating.OrderedSeats(app.state.db)
        app.state.safety = safety.SafetyStore.configured(app.state.db, Limiter(), settings.safety_terms_path)
        app.state.incidents = incidents.IncidentStore(app.state.db)
        app.state.rtc = gateway or LiveKitGateway(settings)
        app.state.room_started = room_started.RoomStarted(app, settings, lock, valid_session)
        app.state.admin = AdminService(settings, app.state.db, app.state.rtc, observability,
                                       capacity, lock, Limiter(), client_ip)
        app.state.admin.safety = app.state.safety
        app.state.admin.incidents = app.state.incidents
        maintenance = None
        diagnostics_maintenance = None
        catalog_monitor = None
        notification_maintenance = None
        try:
            # A crash between database registration and CreateRoom must not leave joinable ghosts.
            async with lock:
                with app.state.db:
                    app.state.chat.prune()
                    app.state.safety.prune()
                    app.state.incidents.prune()
                    social_policy.prune(app.state.db)
                try:
                    await expire_members()
                except HTTPException:
                    # Durable rights and cleanup intent remain accessible even if
                    # the separate SFU is down when this API process restarts.
                    LOGGER.warning("Laboratory media cleanup awaits SFU recovery")
                await cleanup_pending(app.state.db, app.state.rtc)
            maintenance = asyncio.create_task(maintain_rooms())
            diagnostics_maintenance = asyncio.create_task(maintain_observability())
            catalog_monitor = asyncio.create_task(app.state.room_catalog.monitor())
            notification_maintenance = asyncio.create_task(app.state.room_started.maintain())
            app.state.admin.start()
            yield
        finally:
            await app.state.admin.close()
            for task in (maintenance, diagnostics_maintenance, catalog_monitor, notification_maintenance):
                if task:
                    task.cancel()
            for task in (maintenance, diagnostics_maintenance, catalog_monitor, notification_maintenance):
                if task:
                    with suppress(asyncio.CancelledError):
                        await task
            await app.state.signal.close()
            app.state.db.close()
            await app.state.rtc.close()

    app = FastAPI(title="kiki Voice API", docs_url=None, redoc_url=None,
                  openapi_url=None, lifespan=lifespan)

    def client_ip(request):
        peer = request.client.host if request.client else "unknown"
        # Uvicorn must use --no-proxy-headers; nginx replaces X-Real-IP itself.
        if peer in {"127.0.0.1", "::1"}:
            value = request.headers.get("x-real-ip", "")
            try:
                return str(ipaddress.ip_address(value))
            except ValueError:
                pass
        return peer

    @app.middleware("http")
    async def protect_request(request, call_next):
        request.state.request_id = str(uuid.uuid4())
        started = time.monotonic()
        try:
            if settings.admin_auth_mode == "passkey" and (request.url.path == "/admin/v1" or request.url.path.startswith("/admin/v1/")):
                raise HTTPException(404, "接口不存在")
            if request.url.path.startswith("/internal/admin/v2/") and request.url.path not in ops_gateway.ALLOWED_PATHS:
                # Do not let the framework redirect a trailing slash or expose
                # future control paths outside the single signed aggregate route.
                raise HTTPException(404, "接口不存在")
            if request.url.path.startswith("/internal/v1/account/incident") and request.url.path!="/internal/v1/account/incident":
                raise HTTPException(404,"接口不存在")
            if request.url.path.startswith("/internal/v1/account/social-") and request.url.path not in social_policy.PATHS:
                raise HTTPException(404,"接口不存在")
            if request.url.path.startswith(room_started.STATUS_PATH) and request.url.path != room_started.STATUS_PATH:
                raise HTTPException(404,"接口不存在")
            length = request.headers.get("content-length")
            if length and (not length.isdigit() or int(length) > MAX_BODY):
                raise HTTPException(413, "请求内容过大")
            content = bytearray()
            async for chunk in request.stream():
                content.extend(chunk)
                if len(content) > MAX_BODY:
                    raise HTTPException(413, "请求内容过大")
            request._body = bytes(content)
            if settings.rate_limit_enabled:
                peer = client_ip(request)
                # Separate valid sessions on the same Wi-Fi. Merely presenting an
                # arbitrary bearer must not bypass the anonymous/IP allowance.
                session_key = None
                admin_key = None
                bearer = request.headers.get("authorization", "")
                if bearer.startswith("Bearer ") and re.fullmatch(r"[A-Za-z0-9_-]{43}", bearer[7:]):
                    digest = hashlib.sha256(bearer[7:].encode()).hexdigest()
                    row = app.state.db.execute("SELECT s.token_hash FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>? AND u.deleted=0", (digest, int(time.time()))).fetchone()
                    if row:
                        session_key = row[0]
                    elif request.url.path.startswith("/admin/v1/") and app.state.admin.legacy_enabled:
                        row = app.state.db.execute("SELECT token_hash FROM admin_sessions WHERE token_hash=? AND revoked_at IS NULL AND expires_at>? AND credential_fingerprint=?", (digest, int(time.time()), app.state.admin.credential_fingerprint)).fetchone()
                        if row:
                            admin_key = row[0]
                if session_key:
                    limiter.check(("http-authenticated-ip", peer), settings.authenticated_ip_limit, 60)
                    limiter.check(("http-session", session_key), 180, 60)
                elif admin_key:
                    limiter.check(("http-authenticated-ip", peer), settings.authenticated_ip_limit, 60)
                    limiter.check(("http-admin-session", admin_key), 60, 60)
                else:
                    limiter.check(("http-total", peer), 6000, 60)
                    limiter.check(("http-anonymous", peer), 240, 60)
                if request.url.path == "/v1/auth/lab":
                    limiter.check(("login", peer), 10, 60)
            response = await call_next(request)
        except HTTPException as error:
            response = JSONResponse({"detail": error.detail}, status_code=error.status_code,
                                    headers=error.headers)
        except Exception as error:
            LOGGER.error("Laboratory API failure: %s", type(error).__name__)
            response = JSONResponse({"detail": "实验服务暂时不可用，请稍后重试"}, status_code=503)
        if request.method not in {"GET", "HEAD", "OPTIONS"}:
            # A trigger owns the durable revision. HTTP code merely wakes local
            # waiters after committed writes, including account/admin cleanup.
            try:
                async with lock:
                    app.state.room_catalog.publish_locked()
            except Exception as error:
                LOGGER.warning("Room catalog publication pending: %s", type(error).__name__)
        # Correlate API evidence with a client attempt without trusting caller
        # identity or persisting request/error text. Telemetry failure itself must
        # never turn a room response into a second failure.
        if response.status_code >= 400:
            path = request.url.path
            operation = "create_room" if request.method == "POST" and path == "/v1/rooms" else None
            matched = re.fullmatch(r"/v1/rooms/(lk_[a-f0-9]{32})/(token|state)", path)
            if matched:
                operation = "join_room" if matched[2] == "token" else "room_runtime"
            user = getattr(request.state, "incident_user", None)
            if operation and user is not None:
                try:
                    async with lock:
                        if not consent_status(user["id"])["requiresAcceptance"] and not app.state.db.execute("SELECT deleted FROM users WHERE id=?",(user["id"],)).fetchone()[0]:
                            status = response.status_code
                            code = getattr(request.state,"incident_code",None) or {401:"http_unauthorized",403:"http_forbidden",404:"http_not_found",409:"http_conflict",428:"consent_required",429:"http_rate_limited"}.get(status,"http_server_error" if status>=500 else "http_invalid_response")
                            attempt = request.headers.get("x-kiki-attempt-id","").lower()
                            if not re.fullmatch(r"[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}",attempt):
                                attempt = request.state.request_id
                            event = incidents.Incident(eventID=str(uuid.uuid4()),attemptID=attempt,
                                operation=operation,stage="room_api" if operation=="create_room" else "token_api" if operation=="join_room" else "state_sync",
                                severity="error" if status>=500 else "warning",code=code,occurredAt=int(time.time()),
                                elapsedMs=min(3600000,int((time.monotonic()-started)*1000)),
                                roomID=matched[1] if matched else getattr(request.state,"incident_room_id",None),
                                requestID=request.state.request_id,httpStatus=status,platform="server",appVersion="voice-api",osVersion="server")
                            privacy=app.state.db.execute("SELECT consent_epoch FROM account_privacy_state WHERE user_id=?",(user["id"],)).fetchone()
                            with app.state.db:
                                app.state.incidents.record(user["id"],user["name"],event,source="server",consent_epoch=privacy[0] if privacy else 0)
                            LOGGER.warning("Room incident request_id=%s operation=%s code=%s status=%s",request.state.request_id,operation,code,status)
                except Exception as error:
                    LOGGER.warning("Room incident persistence unavailable: %s",type(error).__name__)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Kiki-Request-ID"] = request.state.request_id
        return response

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_request, _error):
        return JSONResponse({"detail": "参数不正确，请检查输入内容"}, status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_request, error):
        if isinstance(error.detail,dict) and error.detail.get("code") in incidents.CODES:
            _request.state.incident_code=error.detail["code"]
        body = error.detail if isinstance(error.detail, dict) else {"detail": error.detail}
        return JSONResponse(body, status_code=error.status_code, headers=error.headers)

    def require_consent():
        raise HTTPException(428, {"detail": "请同意当前实验协议并确认已满18周岁",
                                  "requiredVersions": app.state.legal})

    def validate_consent(consent):
        if (consent is None or not consent.accepted or not consent.adultConfirmed
                or any(getattr(consent, key) != value for key, value in app.state.legal.items())):
            require_consent()

    def consent_status(user_id):
        row = app.state.db.execute("SELECT * FROM consents WHERE user_id=?", (user_id,)).fetchone()
        record = None if row is None else {
            "privacyVersion": row["privacy_version"], "termsVersion": row["terms_version"],
            "documentHash": row["document_hash"], "acceptedAt": row["accepted_at"],
            "withdrawnAt": row["withdrawn_at"]}
        current = (row is not None and row["withdrawn_at"] is None and all(
            record[key] == value for key, value in app.state.legal.items()))
        return {"requiredVersions": app.state.legal, "requiresAcceptance": not current,
                "legalConsent": record}

    def authenticate(request, *, consent=True, termination=False):
        value = request.headers.get("authorization", "")
        if not value.startswith("Bearer ") or not re.fullmatch(r"[A-Za-z0-9_-]{43}", value[7:]):
            raise HTTPException(401, "登录已过期，请重新登录")
        token_hash = hashlib.sha256(value[7:].encode()).hexdigest()
        session = app.state.db.execute("SELECT * FROM sessions WHERE token_hash=?", (token_hash,)).fetchone()
        if (session is None or (session["expires_at"] <= int(time.time()) and not termination)
                or (session["revoked_at"] is not None and not termination)):
            raise HTTPException(401, "登录已过期，请重新登录")
        if settings.auth_mode == "account" and not app.state.db.execute(
                "SELECT 1 FROM account_authorizations WHERE token_hash=?", (token_hash,)).fetchone():
            raise HTTPException(401, "请通过 Apple 账号重新登录")
        user = app.state.db.execute("SELECT * FROM users WHERE id=?", (session["user_id"],)).fetchone()
        if user is None or (user["deleted"] and not termination):
            raise HTTPException(401, "账号不可用")
        if consent and consent_status(user["id"])["requiresAcceptance"]:
            require_consent()
        if consent:
            request.state.incident_user=user
        if not termination:
            if request.url.path.startswith(("/v1/rooms", "/v1/room-catalog", "/v1/library", "/v1/favorites", "/v1/history")):
                app.state.safety.enforce(user["id"])
            if consent:
                with app.state.db:
                    app.state.safety.activity(user["id"])
        return user, session

    async def active_user(request: Request):
        return authenticate(request)[0]

    def user_json(user):
        return {"id": user["id"], "sdkUserID": user["id"], "displayID": user["display_id"], "name": user["name"],
                "bio": user["bio"], "avatarIndex": user["avatar_index"],
                "notificationsEnabled": bool(user["notifications"]), "avatarURL": user["avatar_url"],
                "needsNickname": bool(user["needs_nickname"])}

    def sdk_json(user, session):
        return {"provider": "livekit", "serverURL": settings.public_url, "userID": user["id"],
                "expiresAt": session["expires_at"]}

    def get_room(room_id):
        room = app.state.db.execute("SELECT * FROM rooms WHERE id=?", (room_id,)).fetchone()
        if room is None:
            raise HTTPException(404, "房间不存在")
        return room

    def capacity():
        db = app.state.db
        active_ids = [row[0] for row in db.execute("SELECT id FROM rooms WHERE status='active'")]
        fresh = all(identifier in known_presence and known_presence[identifier][0] >= time.monotonic()-10 for identifier in active_ids)
        return {"activeRooms": db.execute("SELECT COUNT(*) FROM rooms WHERE status IN ('creating','active','closing')").fetchone()[0],
            "activeParticipants": sum(known_presence[identifier][1] for identifier in active_ids) if fresh else None,
            "admittedParticipants": db.execute("SELECT COUNT(*) FROM room_members m JOIN rooms r ON r.id=m.room_id WHERE m.active=1 AND r.status='active'").fetchone()[0],
            "maxRooms": settings.max_active_rooms, "maxParticipantsPerRoom": settings.max_room_participants,
            "maxParticipantsTotal": settings.max_total_participants}

    def check_admission_capacity(room_id, user_id, *, creating=False):
        snapshot = capacity()
        if creating and snapshot["activeRooms"] >= settings.max_active_rooms:
            raise HTTPException(429, "实验服务器同时开放的房间已达上限，请稍后重试", headers={"Retry-After": "30"})
        existing = None if creating else app.state.db.execute("SELECT active FROM room_members WHERE room_id=? AND user_id=?", (room_id, user_id)).fetchone()
        increment = 0 if existing and existing["active"] else 1
        if not creating:
            count = app.state.db.execute("SELECT COUNT(*) FROM room_members WHERE room_id=? AND active=1", (room_id,)).fetchone()[0]
            if count+increment > settings.max_room_participants:
                raise HTTPException(409, f"房间入场人数已达实验上限{settings.max_room_participants}人，请稍后重试")
        if snapshot["admittedParticipants"]+increment > settings.max_total_participants:
            raise HTTPException(429, "实验服务器入场人数已达总上限，请稍后重试", headers={"Retry-After": "30"})

    def room_json(room, user_id, audience=0):
        owner = app.state.db.execute("SELECT * FROM users WHERE id=?", (room["owner_id"],)).fetchone()
        online = known_online_members.get(room["id"], set()) if room["status"] == "active" else set()
        blocked = {row[0] for row in app.state.db.execute("""SELECT blocked_user_id FROM safety_blocks WHERE user_id=?
            UNION SELECT user_id FROM safety_blocks WHERE blocked_user_id=?""", (user_id, user_id))}
        preview = [{"userID": row["id"], "displayID": row["display_id"], "name": row["name"], "avatarIndex": row["avatar_index"], "avatarURL": row["avatar_url"]}
                   for row in app.state.db.execute("""SELECT u.* FROM room_members m JOIN users u ON u.id=m.user_id
                       WHERE m.room_id=? AND m.active=1 AND u.deleted=0 ORDER BY m.joined_at,m.user_id""", (room["id"],))
                   if row["id"] in online and row["id"] != owner["id"] and row["id"] not in blocked][:5]
        return {"id": room["id"], "title": room["title"], "host": owner["name"],
                "hostID": owner["id"], "hostDisplayID": owner["display_id"], "category": room["category"], "audience": audience,
                "isLive": False, "theme": room["theme"] if room["theme"] in range(5) else 0, "isCreatedByMe": owner["id"] == user_id,
                "status": "live" if room["status"] == "active" else "ended",
                "createdAt": room["created_at"], "hostAvatarIndex": owner["avatar_index"],
                "hostAvatarURL": owner["avatar_url"], "memberPreview": preview}

    def bump(room_id):
        app.state.db.execute("INSERT INTO room_revisions(room_id,revision) VALUES(?,1) ON CONFLICT(room_id) DO UPDATE SET revision=revision+1", (room_id,))

    def forget_room_presence(room_id):
        known_presence.pop(room_id, None)
        known_online_members.pop(room_id, None)
        for key in tuple(disconnect_deadlines):
            if key[0] == room_id:
                disconnect_deadlines.pop(key, None)

    def ensure_room_model(room):
        """Additive migration preserves old accounts, rooms and library records."""
        db = app.state.db
        room_id = room["id"]
        # Read the model's completeness before attempting additive migration writes.
        # Check on every call, so a partially migrated/corrupt seat set is repaired.
        complete = db.execute("""SELECT
            EXISTS(SELECT 1 FROM room_revisions WHERE room_id=?)
            AND (SELECT COUNT(*) FROM room_seats WHERE room_id=?)=8
            AND EXISTS(SELECT 1 FROM room_members WHERE room_id=? AND user_id=?)
            AND NOT EXISTS(SELECT 1 FROM memberships old
                WHERE old.room_id=? AND NOT EXISTS(SELECT 1 FROM room_members current
                    WHERE current.room_id=old.room_id AND current.user_id=old.user_id))""",
            (room_id, room_id, room_id, room["owner_id"], room_id)).fetchone()[0]
        if complete:
            return
        db.execute("INSERT OR IGNORE INTO room_revisions VALUES(?,0)", (room_id,))
        for index in range(1, 9):
            db.execute("INSERT OR IGNORE INTO room_seats(room_id,seat_index) VALUES(?,?)", (room_id, index))
        # Legacy room memberships become listeners. Only a still-valid business session
        # may be migrated; old JWTs without server bindings intentionally cannot rejoin.
        candidates = {row[0] for row in db.execute("SELECT user_id FROM memberships WHERE room_id=?", (room_id,))}
        candidates.add(room["owner_id"])
        for user_id in candidates:
            session = db.execute("SELECT token_hash FROM sessions WHERE user_id=? ORDER BY (revoked_at IS NULL AND expires_at>?) DESC,expires_at DESC LIMIT 1", (user_id, int(time.time()))).fetchone()
            if session:
                cursor = db.execute("INSERT OR IGNORE INTO room_members(room_id,user_id,session_hash,role,joined_at) VALUES(?,?,?,?,?)",
                    (room_id, user_id, session[0], "owner" if user_id == room["owner_id"] else "member", int(time.time())))
                if cursor.rowcount and user_id == room["owner_id"]:
                    db.execute("UPDATE room_seats SET user_id=? WHERE room_id=? AND seat_index=1 AND user_id IS NULL", (user_id, room_id))
                    app.state.safety.activity(user_id, mic=True)
        db.commit()

    def member_row(room_id, user_id, required=True):
        row = app.state.db.execute("SELECT * FROM room_members WHERE room_id=? AND user_id=? AND active=1", (room_id, user_id)).fetchone()
        if row is None and required:
            raise HTTPException(403, "请先进入房间")
        return row

    def valid_session(token_hash):
        row = app.state.db.execute("SELECT s.*,u.deleted FROM sessions s JOIN users u ON u.id=s.user_id WHERE token_hash=?", (token_hash,)).fetchone()
        if settings.auth_mode == "account" and not app.state.db.execute(
                "SELECT 1 FROM account_authorizations WHERE token_hash=?", (token_hash,)).fetchone():
            return False
        return (row is not None and not row["deleted"] and row["revoked_at"] is None
                and row["expires_at"] > int(time.time()) and not consent_status(row["user_id"])["requiresAcceptance"]
                and not app.state.safety.restrictions(row["user_id"])["bannedUntil"])

    def permissions_for_seat(member, seat):
        if "chat_muted_until" in member.keys():
            now = int(time.time())
            restrictions = {"chatMutedUntil":member["chat_muted_until"] and member["chat_muted_until"] > now,
                "voiceMutedUntil":member["voice_muted_until"] and member["voice_muted_until"] > now,
                "bannedUntil":member["banned_until"] and member["banned_until"] > now}
        else:
            restrictions = app.state.safety.restrictions(member["user_id"])
        return {"role": member["role"], "seatIndex": seat["seat_index"] if seat else None,
            "canPublishAudio": bool(member["active"] and seat and not seat["audio_locked"] and not member["audio_muted"] and not restrictions["voiceMutedUntil"] and not restrictions["bannedUntil"]),
            "canPublishData": bool(member["active"] and not member["chat_muted"] and not restrictions["chatMutedUntil"] and not restrictions["bannedUntil"]),
            "sessionHash": member["session_hash"], "generation": member["generation"]}

    def member_permissions(member):
        seat = app.state.db.execute("SELECT * FROM room_seats WHERE room_id=? AND user_id=?", (member["room_id"], member["user_id"])).fetchone()
        return permissions_for_seat(member, seat)

    def reconcile_ordered_seats(room, online):
        """Caller owns the transaction; media changes are applied after commit."""
        db, room_id = app.state.db, room["id"]
        eligible = set()
        for member in db.execute("""SELECT m.* FROM room_members m JOIN seat_requests q
            ON q.room_id=m.room_id AND q.user_id=m.user_id JOIN seat_request_states a
            ON a.room_id=m.room_id AND a.user_id=m.user_id AND a.status='approved'
            WHERE m.room_id=? AND m.active=1""", (room_id,)):
            if member["user_id"] not in online or not valid_session(member["session_hash"]):
                continue
            restrictions = app.state.safety.restrictions(member["user_id"])
            if not restrictions["voiceMutedUntil"] and not restrictions["bannedUntil"]:
                eligible.add(member["user_id"])
        affected = app.state.seating.compact(room_id, room["owner_id"])
        promoted = app.state.seating.fill(room_id, eligible, int(time.time()))
        for person_id in promoted:
            app.state.safety.activity(person_id, mic=True)
        affected.update(promoted)
        for person_id in affected:
            schedule_media(room_id, person_id, "permissions")
        return affected

    async def participant_ids(room_id, presence=None):
        try:
            result = set(await app.state.rtc.participants(room_id))
            # Registration alone is not a reconnect. Retain the durable flag
            # across process/session changes until a current upstream handshake
            # succeeded within the original grace and the SFU confirms presence.
            db = app.state.db
            disconnected = db.execute("""SELECT m.*,p.offline_since FROM room_members m
                LEFT JOIN room_presence p ON p.room_id=m.room_id AND p.user_id=m.user_id
                WHERE m.room_id=? AND m.active=1 AND m.signal_disconnected=1""", (room_id,)).fetchall()
            owner_id = get_room(room_id)["owner_id"] if disconnected else None
            with db:
                for member in disconnected:
                    key = (room_id, member["user_id"])
                    connection = connections.get(key)
                    grace = OWNER_DISCONNECT_GRACE_SECONDS if member["user_id"] == owner_id else DISCONNECT_GRACE_SECONDS
                    recovered = (member["user_id"] in result and connection is not None
                        and not connection.revoked.is_set() and connection.upstream_connected
                        and connection.upstream_connected_at is not None
                        and connection.generation == member["generation"]
                        and hmac.compare_digest(connection.session_hash, member["session_hash"])
                        and member["offline_since"] is not None
                        and connection.upstream_connected_at < member["offline_since"] + grace)
                    if recovered:
                        db.execute("UPDATE room_members SET signal_disconnected=0 WHERE room_id=? AND user_id=?", key)
                        db.execute("UPDATE room_presence SET offline_since=NULL WHERE room_id=? AND user_id=?", key)
                        disconnect_deadlines.pop(key, None)
                        bump(room_id)
                    else:
                        result.discard(member["user_id"])
            known_online_members[room_id] = result
            known_presence[room_id] = (time.monotonic(), len(result))
            with app.state.db:
                app.state.safety.observe(room_id, result)
            try:
                app.state.room_started.observe_locked(get_room(room_id), result, connections)
            except Exception as error:
                # Reminder persistence must not break the room's media/state
                # path. Its atomic insert can be retried on the next sample.
                LOGGER.warning("Room start notification awaits persistence: %s",type(error).__name__)
            if presence is not None:
                presence[room_id] = (result, presence_epochs[room_id])
            return result
        except Exception:
            raise HTTPException(503, "无法确认房间在线状态，请稍后重试") from None

    def current_member(room_id, user, session):
        app.state.safety.enforce(user["id"])
        if app.state.db.execute("SELECT 1 FROM room_bans WHERE room_id=? AND user_id=?", (room_id, user["id"])).fetchone():
            raise HTTPException(403, "你已被移出房间，需管理员解除禁入")
        member = member_row(room_id, user["id"])
        if member["session_hash"] != session["token_hash"]:
            raise HTTPException(403, "入场会话已变化，请重新进入")
        return member

    async def room_state(room_id, user, session, presence=None):
        room = get_room(room_id)
        if room["status"] != "active":
            raise HTTPException(409, "房间已结束")
        me = current_member(room_id, user, session)
        cached = presence.get(room_id) if presence is not None else None
        online = cached[0] if cached is not None and cached[1] == presence_epochs[room_id] else await participant_ids(room_id)
        db = app.state.db
        now = int(time.time())
        if db.execute("SELECT 1 FROM seat_invitations WHERE room_id=? AND expires_at<=? LIMIT 1", (room_id, now)).fetchone():
            with db:
                db.execute("DELETE FROM seat_invitations WHERE room_id=? AND expires_at<=?", (room_id, now))
                bump(room_id)
        rows = db.execute("SELECT m.*,u.name,u.avatar_index,u.avatar_url,u.display_id,s.chat_muted_until,s.voice_muted_until,s.banned_until,p.offline_since,a.status request_status,q.user_id requested_user FROM room_members m JOIN users u ON u.id=m.user_id LEFT JOIN safety_restrictions s ON s.user_id=m.user_id LEFT JOIN room_presence p ON p.room_id=m.room_id AND p.user_id=m.user_id LEFT JOIN seat_request_states a ON a.room_id=m.room_id AND a.user_id=m.user_id LEFT JOIN seat_requests q ON q.room_id=m.room_id AND q.user_id=m.user_id WHERE m.room_id=? AND m.active=1 ORDER BY m.joined_at,m.user_id", (room_id,)).fetchall()
        seats = db.execute("SELECT * FROM room_seats WHERE room_id=? ORDER BY seat_index", (room_id,)).fetchall()
        seats_by_user = {seat["user_id"]: seat for seat in seats if seat["user_id"] is not None}
        members = []
        for member in rows:
            permissions = permissions_for_seat(member, seats_by_user.get(member["user_id"]))
            offline_since = member["offline_since"] if member["user_id"] not in online else None
            grace = OWNER_DISCONNECT_GRACE_SECONDS if member["user_id"] == room["owner_id"] else DISCONNECT_GRACE_SECONDS
            members.append({"userID": member["user_id"], "displayID": member["display_id"], "name": member["name"],
                "avatarIndex": member["avatar_index"], "avatarURL": member["avatar_url"], "role": member["role"],
                "seatIndex": permissions["seatIndex"], "audioMuted": bool(member["audio_muted"] or member["voice_muted_until"] and member["voice_muted_until"] > now),
                "chatMuted": bool(member["chat_muted"] or member["chat_muted_until"] and member["chat_muted_until"] > now), "online": member["user_id"] in online,
                "offlineSince": offline_since, "reconnectDeadline": offline_since + grace if offline_since is not None else None,
                "seatRequestStatus": "seated" if permissions["seatIndex"] is not None else
                    member["request_status"] if member["request_status"] in {"pending", "approved", "rejected"} else
                    "pending" if member["requested_user"] else "none",
                "canPublishAudio": permissions["canPublishAudio"], "canPublishData": permissions["canPublishData"]})
        moderator = me["role"] in {"owner", "admin"}
        invitations = db.execute("SELECT i.*,u.name,u.display_id FROM seat_invitations i JOIN users u ON u.id=i.user_id WHERE i.room_id=? ORDER BY i.expires_at,i.user_id", (room_id,)).fetchall()
        queue = db.execute("SELECT q.*,u.name,u.display_id,COALESCE(a.status,'pending') request_status,a.approval_order FROM seat_requests q JOIN users u ON u.id=q.user_id LEFT JOIN seat_request_states a ON a.room_id=q.room_id AND a.user_id=q.user_id WHERE q.room_id=? ORDER BY CASE WHEN a.status='approved' THEN 0 ELSE 1 END,a.approval_order,q.requested_at,q.rowid", (room_id,)).fetchall()
        bans = db.execute("SELECT b.*,u.name,u.display_id FROM room_bans b JOIN users u ON u.id=b.user_id WHERE b.room_id=? ORDER BY b.banned_at,b.user_id", (room_id,)).fetchall() if moderator else []
        return {"room": room_json(room, user["id"], len(online)),
            "seatMode": "ordered", "disconnectGraceSeconds": DISCONNECT_GRACE_SECONDS,
            "ownerDisconnectGraceSeconds": OWNER_DISCONNECT_GRACE_SECONDS,
            "revision": db.execute("SELECT revision FROM room_revisions WHERE room_id=?", (room_id,)).fetchone()[0],
            "me": next(member for member in members if member["userID"] == user["id"]), "members": members,
            "seats": [{"index": seat["seat_index"], "userID": seat["user_id"], "locked": bool(seat["locked"]), "audioLocked": bool(seat["audio_locked"])} for seat in seats],
            "queue": [{"userID": q["user_id"], "displayID": q["display_id"], "name": q["name"], "requestedAt": q["requested_at"], "position": index+1,
                       "status": q["request_status"], "online": q["user_id"] in online} for index,q in enumerate(queue)],
            "invitations": [{"userID": i["user_id"], "displayID": i["display_id"], "name": i["name"], "seatIndex": i["seat_index"], "expiresAt": i["expires_at"]} for i in invitations if moderator or i["user_id"] == user["id"]],
            "bans": [{"userID": b["user_id"], "displayID": b["display_id"], "name": b["name"], "bannedAt": b["banned_at"]} for b in bans]}

    def schedule_media(room_id, user_id, kind):
        app.state.db.execute("INSERT INTO media_cleanup VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET kind=excluded.kind", (room_id, user_id, kind))

    async def apply_media(room_id, user_id):
        """Persisted intent stays pending until the SFU confirms permissions/removal."""
        db = app.state.db
        task = db.execute("SELECT kind FROM media_cleanup WHERE room_id=? AND user_id=?", (room_id, user_id)).fetchone()
        if task is None:
            return True
        # A request-local online snapshot must not survive an intervening media
        # mutation, including fail-closed fallback removal after permission errors.
        presence_epochs[room_id] += 1
        try:
            if task["kind"] == "permissions":
                member = member_row(room_id, user_id, required=False)
                if member:
                    await app.state.signal.close_pending_identity(room_id, user_id)
                    user = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                    grants = member_permissions(member)
                    await app.state.rtc.update_permissions(room_id, user_id, audio=grants["canPublishAudio"],
                        data=grants["canPublishData"], metadata=LiveKitGateway.metadata(user_json(user), grants))
                    if not grants["canPublishAudio"]:
                        await app.state.rtc.mute_audio_tracks(room_id, user_id)
                else:
                    await app.state.signal.close_identity(room_id, user_id)
                    await app.state.rtc.remove_participant(room_id, user_id)
            else:
                await app.state.signal.close_identity(room_id, user_id)
                await app.state.rtc.remove_participant(room_id, user_id)
        except Exception:
            # Fail closed when a permission update cannot be confirmed. Retain the
            # durable permission intent, so reconnect is always authorized from DB.
            try:
                await app.state.signal.close_identity(room_id, user_id)
                await app.state.rtc.remove_participant(room_id, user_id)
            except Exception:
                return False
        db.execute("DELETE FROM media_cleanup WHERE room_id=? AND user_id=?", (room_id, user_id))
        db.commit()
        return True

    async def cleanup_pending(db, rtc):
        for task in db.execute("SELECT room_id,user_id FROM media_cleanup").fetchall():
            await apply_media(task["room_id"], task["user_id"])
        pending = db.execute("SELECT id FROM rooms WHERE status IN ('creating','closing')").fetchall()
        for row in pending:
            try:
                await app.state.signal.close_room(row["id"])
                await rtc.delete_room(row["id"])
            except Exception:
                continue
            with db:
                db.execute("UPDATE rooms SET status='closed' WHERE id=?", (row["id"],))
                app.state.safety.forget_room(row["id"])
                db.execute("UPDATE room_members SET active=0,generation=generation+1,signal_disconnected=0 WHERE room_id=? AND active=1", (row["id"],))
                db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=?", (row["id"],))
                app.state.seating.clear(row["id"])
                db.execute("DELETE FROM seat_invitations WHERE room_id=?", (row["id"],))
                db.execute("DELETE FROM room_presence WHERE room_id=?", (row["id"],))
                db.execute("DELETE FROM media_cleanup WHERE room_id=?", (row["id"],))
                app.state.chat.clear_room(row["id"])
            forget_room_presence(row["id"])
        complete_deletions(db)

    async def expire_safety_restrictions():
        """Restore only platform mutes at expiry; room-admin mutes stay intact."""
        db, now = app.state.db, int(time.time())
        rows = db.execute("""SELECT * FROM safety_restrictions WHERE
            (chat_muted_until IS NOT NULL AND chat_muted_until<=?) OR
            (voice_muted_until IS NOT NULL AND voice_muted_until<=?) OR
            (banned_until IS NOT NULL AND banned_until<=?)""", (now,now,now)).fetchall()
        for row in rows:
            with db:
                db.execute("""UPDATE safety_restrictions SET
                    chat_muted_until=CASE WHEN chat_muted_until<=? THEN NULL ELSE chat_muted_until END,
                    voice_muted_until=CASE WHEN voice_muted_until<=? THEN NULL ELSE voice_muted_until END,
                    banned_until=CASE WHEN banned_until<=? THEN NULL ELSE banned_until END WHERE user_id=?""", (now,now,now,row["user_id"]))
                members = db.execute("SELECT room_id FROM room_members WHERE user_id=? AND active=1", (row["user_id"],)).fetchall()
                for member in members:
                    schedule_media(member["room_id"],row["user_id"],"permissions")
                    bump(member["room_id"])
                db.execute("DELETE FROM safety_restrictions WHERE user_id=? AND chat_muted_until IS NULL AND voice_muted_until IS NULL AND banned_until IS NULL", (row["user_id"],))
            for member in members:
                await apply_media(member["room_id"],row["user_id"])

    @app.get("/v1/safety")
    async def safety_state(request: Request):
        async with lock:
            user, _ = authenticate(request)
            return app.state.safety.snapshot(user["id"])

    @app.put("/v1/safety/blocks/{target_id}")
    async def safety_block(target_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            if await request.body() not in (b"",b"{}"):
                raise HTTPException(422,"拉黑操作不接受其他参数")
            with app.state.db:
                return app.state.safety.block(user["id"],target_id,True)

    @app.delete("/v1/safety/blocks/{target_id}")
    async def safety_unblock(target_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            with app.state.db:
                return app.state.safety.block(user["id"],target_id,False)

    @app.post("/v1/safety/reports")
    async def safety_report(payload: safety.ReportRequest, request: Request):
        async with lock:
            user, _ = authenticate(request)
            room = app.state.db.execute("SELECT status FROM rooms WHERE id=?", (payload.roomID,)).fetchone()
            # Opportunistically verify real SFU participation; a previously
            # observed participant can report after leaving or during an outage.
            if room and room["status"] == "active":
                with suppress(HTTPException):
                    observed = await participant_ids(payload.roomID)
                    with app.state.db:
                        app.state.safety.observe(payload.roomID,observed,force=True)
            with app.state.db:
                return app.state.safety.create_report(user["id"],payload)

    @app.get("/v1/safety/reports/mine")
    async def safety_reports_mine(request: Request):
        async with lock:
            user, _ = authenticate(request)
            return app.state.safety.mine(user["id"])

    @app.post(ops_gateway.MODERATION_QUERY_PATH)
    async def moderation_query(payload: safety.ModerationQuery, request: Request):
        async with lock:
            ops_gateway.verify_request(settings,app.state.db,request,await request.body(),path=ops_gateway.MODERATION_QUERY_PATH)
            return app.state.safety.query(payload)

    @app.post(ops_gateway.MODERATION_ACTION_PATH)
    async def moderation_action(payload: safety.ModerationAction, request: Request):
        async with lock:
            db, now = app.state.db, int(time.time())
            ops_gateway.verify_request(settings,db,request,await request.body(),path=ops_gateway.MODERATION_ACTION_PATH)
            timed = payload.action in {"mute_chat","mute_audio","ban_user"}
            if timed != (payload.durationSeconds is not None):
                raise HTTPException(422,"禁言、禁麦和语聊封禁需要有效时长，其他操作不能指定时长")
            digest = safety.canonical_hash(payload.model_dump())
            existing = db.execute("SELECT * FROM safety_actions WHERE request_id=?", (payload.requestID,)).fetchone()
            if existing:
                if existing["request_hash"] != digest:
                    raise HTTPException(409,"管理操作重试标识已用于其他内容")
                await cleanup_pending(db,app.state.rtc)
                response = json.loads(existing["response_json"])
                response["mediaCleanupPending"] = bool(db.execute("SELECT 1 FROM media_cleanup WHERE user_id=?", (existing["target_user_id"],)).fetchone()
                    or db.execute("SELECT 1 FROM rooms r JOIN safety_reports s ON s.room_id=r.id WHERE s.id=? AND r.status='closing'",(payload.reportID,)).fetchone())
                return response
            report = db.execute("SELECT * FROM safety_reports WHERE id=? AND evidence_expires_at>?", (payload.reportID,now)).fetchone()
            if report is None and payload.action == "restore_user":
                # Evidence expires independently of a still-active later sanction.
                # Keep only its opaque source report ID, never extend evidence.
                restriction = db.execute("""SELECT user_id FROM safety_restrictions WHERE source_report_id=?
                    AND (chat_muted_until>? OR voice_muted_until>? OR banned_until>?)""", (payload.reportID,now,now,now)).fetchone()
                if restriction:
                    report = {"id":payload.reportID,"target_user_id":restriction["user_id"],"room_id":None,"message_id":None}
            if report is None:
                raise HTTPException(404,"举报不存在或证据已到保留期限")
            target_id = report["target_user_id"]
            target = db.execute("SELECT * FROM users WHERE id=? AND deleted=0", (target_id,)).fetchone()
            if payload.action not in {"dismiss","close_room"} and target is None:
                raise HTTPException(409,"该用户已注销，不能继续处置")
            response = {"ok":True,"requestID":payload.requestID,"reportID":payload.reportID,
                "action":payload.action,"status":"dismissed" if payload.action=="dismiss" else "resolved",
                "mediaCleanupPending":False}
            affected = []
            with db:
                if timed:
                    column = {"mute_chat":"chat_muted_until","mute_audio":"voice_muted_until","ban_user":"banned_until"}[payload.action]
                    db.execute("INSERT OR IGNORE INTO safety_restrictions(user_id) VALUES(?)", (target_id,))
                    db.execute(f"UPDATE safety_restrictions SET {column}=MAX(COALESCE({column},0),?),reason=?,source_report_id=? WHERE user_id=?", (now+payload.durationSeconds,payload.note,payload.reportID,target_id))
                elif payload.action == "restore_user":
                    db.execute("DELETE FROM safety_restrictions WHERE user_id=?", (target_id,))
                if payload.action not in {"close_room","dismiss"}:
                    labels = {"warn":"社区提醒","mute_chat":"临时文字禁言","mute_audio":"临时禁麦","ban_user":"暂停语聊权限","restore_user":"语聊限制已解除"}
                    db.execute("INSERT INTO safety_notices VALUES(?,?,?,?,?,?)", ("notice_"+uuid.uuid4().hex,target_id,
                        labels[payload.action]+"："+payload.note,payload.action,now,now+safety.REPORT_SECONDS))
                if report["message_id"] and payload.action not in {"dismiss","restore_user"}:
                    if db.execute("DELETE FROM room_messages WHERE room_id=? AND id=?",(report["room_id"],report["message_id"])).rowcount:
                        app.state.chat.bump_history(report["room_id"])
                if payload.action in {"mute_chat","mute_audio","restore_user"}:
                    affected = db.execute("SELECT room_id FROM room_members WHERE user_id=? AND active=1", (target_id,)).fetchall()
                    for member in affected:
                        schedule_media(member["room_id"],target_id,"permissions")
                        bump(member["room_id"])
                db.execute("UPDATE safety_reports SET status=?,resolved_at=?,last_action=? WHERE id=?", (response["status"],now,payload.action,report["id"]))
                db.execute("INSERT INTO safety_actions VALUES(?,?,?,?,?,?,?,?,?)", (payload.requestID,digest,payload.reportID,
                    payload.opsActorID,target_id,payload.action,payload.note,now,json.dumps(response)))
            if payload.action == "close_room":
                with suppress(HTTPException):
                    await close_room(report["room_id"])
            elif payload.action == "ban_user":
                # Commit the global ban before touching SFU connections. New
                # sessions/old grants can no longer enter while removal retries.
                owned = db.execute("SELECT id FROM rooms WHERE owner_id=? AND status IN ('active','creating','closing')", (target_id,)).fetchall()
                for room in owned:
                    with suppress(HTTPException):
                        await close_room(room["id"])
                members = db.execute("SELECT room_id FROM room_members WHERE user_id=? AND active=1", (target_id,)).fetchall()
                for member in members:
                    with suppress(HTTPException):
                        await leave_member(member["room_id"],target_id)
            else:
                for member in affected:
                    await apply_media(member["room_id"],target_id)
            response["mediaCleanupPending"] = bool(db.execute("SELECT 1 FROM media_cleanup WHERE user_id=?",(target_id,)).fetchone()
                or db.execute("SELECT 1 FROM rooms WHERE id=? AND status='closing'", (report["room_id"],)).fetchone())
            with db:
                db.execute("UPDATE safety_actions SET response_json=? WHERE request_id=?", (json.dumps(response),payload.requestID))
            return response

    def complete_deletions(db):
        pending = db.execute("SELECT user_id FROM deletion_requests WHERE completed_at IS NULL").fetchall()
        for request in pending:
            user_id = request["user_id"]
            associated = db.execute("""SELECT 1 FROM rooms r LEFT JOIN room_members m ON m.room_id=r.id AND m.active=1
                WHERE r.status!='closed' AND (r.owner_id=? OR m.user_id=?) LIMIT 1""", (user_id, user_id)).fetchone()
            media = db.execute("SELECT 1 FROM media_cleanup WHERE user_id=? LIMIT 1", (user_id,)).fetchone()
            if associated or media:
                continue
            with db:
                db.execute("UPDATE users SET name='已注销',bio='',avatar_index=0,notifications=0,avatar_url=NULL,display_id=NULL,deleted=1 WHERE id=?", (user_id,))
                room_started.erase(db,user_id)
                app.state.safety.clear_user(user_id)
                db.execute("DELETE FROM safety_restrictions WHERE user_id=?", (user_id,))
                db.execute("DELETE FROM favorites WHERE user_id=?", (user_id,))
                db.execute("DELETE FROM history WHERE user_id=?", (user_id,))
                db.execute("UPDATE deletion_requests SET completed_at=? WHERE user_id=?", (int(time.time()), user_id))

    async def close_room(room_id):
        db = app.state.db
        presence_epochs[room_id] += 1
        forget_room_presence(room_id)
        with db:
            app.state.safety.forget_room(room_id)
            db.execute("UPDATE rooms SET status='closing' WHERE id=? AND status!='closed'", (room_id,))
            db.execute("UPDATE room_members SET active=0,generation=generation+1,signal_disconnected=0 WHERE room_id=? AND active=1", (room_id,))
            db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=?", (room_id,))
            app.state.seating.clear(room_id)
            db.execute("DELETE FROM seat_invitations WHERE room_id=?", (room_id,))
            db.execute("DELETE FROM room_presence WHERE room_id=?", (room_id,))
            app.state.chat.clear_room(room_id)
            bump(room_id)
        app.state.room_catalog.publish_locked()
        try:
            await app.state.signal.close_room(room_id)
            await app.state.rtc.delete_room(room_id)
        except Exception:
            raise HTTPException(503, "房间正在关闭，请稍后重试以确认所有成员已退出") from None
        with db:
            db.execute("UPDATE rooms SET status='closed' WHERE id=?", (room_id,))
            db.execute("DELETE FROM media_cleanup WHERE room_id=?", (room_id,))

    async def leave_member(room_id, user_id, *, online=None):
        db = app.state.db
        member = member_row(room_id, user_id, required=False)
        room = get_room(room_id)
        if room["owner_id"] == user_id and room["status"] != "closed":
            # The host owns this room's lifecycle. Explicit leave, revocation and
            # confirmed disconnect expiry close it instead of transferring it.
            await close_room(room_id)
            return True
        if member is None:
            return await apply_media(room_id, user_id)
        if online is None:
            try:
                online = await participant_ids(room_id) if room["status"] == "active" else set()
            except HTTPException:
                # Revocation/leave still commits while the SFU is unavailable.
                # Promotion waits for an authoritative presence observation.
                online = set()
        with db:
            db.execute("UPDATE room_members SET active=0,generation=generation+1,signal_disconnected=0,role=CASE role WHEN 'owner' THEN 'member' ELSE role END WHERE room_id=? AND user_id=?", (room_id, user_id))
            db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=? AND user_id=?", (room_id, user_id))
            app.state.seating.clear(room_id, user_id)
            db.execute("DELETE FROM seat_invitations WHERE room_id=? AND user_id=?", (room_id, user_id))
            db.execute("DELETE FROM room_presence WHERE room_id=? AND user_id=?", (room_id, user_id))
            schedule_media(room_id, user_id, "remove")
            app.state.safety.samples.pop((room_id,user_id),None)
            affected = reconcile_ordered_seats(room, online - {user_id}) if room["status"] == "active" else set()
            bump(room_id)
        success = await apply_media(room_id, user_id)
        for person_id in affected:
            success = await apply_media(room_id, person_id) and success
        return success

    async def expire_members(presence=None, *, room_id=None):
        db = app.state.db
        await expire_safety_restrictions()
        for room in db.execute("SELECT * FROM rooms WHERE status='active'").fetchall():
            ensure_room_model(room)
            if member_row(room["id"], room["owner_id"], required=False) is None:
                # Recover a crash after committing owner departure but before its
                # asynchronous room deletion. Never leave an ownerless room.
                try:
                    await leave_member(room["id"], room["owner_id"])
                except HTTPException:
                    continue
        # Check every member against current durable session/consent state in one
        # query. This is not a cached authorization decision: revocation and expiry
        # are visible on the very next request, including after direct DB changes.
        expired = db.execute("""SELECT m.* FROM room_members m
            JOIN rooms r ON r.id=m.room_id
            LEFT JOIN sessions s ON s.token_hash=m.session_hash
            LEFT JOIN users u ON u.id=s.user_id
            LEFT JOIN consents c ON c.user_id=s.user_id
            LEFT JOIN safety_restrictions sr ON sr.user_id=m.user_id
            WHERE m.active=1 AND r.status='active' AND
                (s.token_hash IS NULL OR s.user_id!=m.user_id OR u.id IS NULL OR u.deleted!=0
                OR s.revoked_at IS NOT NULL OR s.expires_at<=?
                OR c.user_id IS NULL OR c.withdrawn_at IS NOT NULL
                OR sr.banned_until>CAST(strftime('%s','now') AS INTEGER)
                OR c.privacy_version!=? OR c.terms_version!=? OR c.document_hash!=?)""",
            (int(time.time()), app.state.legal["privacyVersion"], app.state.legal["termsVersion"],
             app.state.legal["documentHash"])).fetchall()
        for member in expired:
            try:
                await leave_member(member["room_id"], member["user_id"])
            except HTTPException:
                # The durable account/session remains revoked. Retry cleanup and
                # room deletion when the separate SFU recovers.
                continue
        # Persist the disconnect grace so a backend restart cannot retain dead
        # seats/requests forever. Pending admissions receive the same recovery window.
        now = int(time.time())
        if room_id is None:
            presence_rooms = db.execute("SELECT * FROM rooms WHERE status='active'").fetchall()
        else:
            # A state poll needs a fresh participant snapshot only for its room.
            # Due disconnect timers elsewhere remain immediate: refresh those rooms
            # too before expiring anybody, since they may already have reconnected.
            presence_rooms = db.execute("""SELECT * FROM rooms r WHERE r.status='active'
                AND (r.id=? OR EXISTS(SELECT 1 FROM room_presence p
                    JOIN room_members m ON m.room_id=p.room_id AND m.user_id=p.user_id
                    WHERE p.room_id=r.id AND m.active=1 AND p.offline_since IS NOT NULL
                    AND p.offline_since<=? - CASE WHEN m.user_id=r.owner_id THEN ? ELSE ? END))""",
                    (room_id, now, OWNER_DISCONNECT_GRACE_SECONDS, DISCONNECT_GRACE_SECONDS)).fetchall()
        for room in presence_rooms:
            online = await participant_ids(room["id"], presence)
            members = db.execute("SELECT * FROM room_members WHERE room_id=? AND active=1", (room["id"],)).fetchall()
            persisted = {row["user_id"]: row["offline_since"] for row in db.execute(
                "SELECT user_id,offline_since FROM room_presence WHERE room_id=?", (room["id"],))}
            changed = False
            expired_offline = []
            for member in members:
                key = (room["id"], member["user_id"])
                if member["user_id"] in online:
                    if member["user_id"] not in persisted:
                        db.execute("INSERT INTO room_presence VALUES(?,?,NULL)", key)
                        changed = True
                    elif persisted[member["user_id"]] is not None:
                        db.execute("UPDATE room_presence SET offline_since=NULL WHERE room_id=? AND user_id=?", key)
                        changed = True
                    disconnect_deadlines.pop(key, None)
                    continue
                since = persisted.get(member["user_id"])
                if since is None:
                    db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=COALESCE(offline_since,excluded.offline_since)", (*key, now))
                    since = now
                    changed = True
                grace = OWNER_DISCONNECT_GRACE_SECONDS if member["user_id"] == room["owner_id"] else DISCONNECT_GRACE_SECONDS
                if since <= now - grace:
                    expired_offline.append(key)
            if changed:
                bump(room["id"])
                db.commit()
            # Persist newly discovered disconnections together before awaiting any
            # media removal. Existing timers are still tested on every request.
            for key in expired_offline:
                if get_room(room["id"])["status"] != "active":
                    break
                await leave_member(*key, online=online)
                disconnect_deadlines.pop(key, None)
            if get_room(room["id"])["status"] == "active":
                with db:
                    affected = reconcile_ordered_seats(room, online)
                    if affected:
                        bump(room["id"])
                for person_id in affected:
                    await apply_media(room["id"], person_id)

    async def maintain_rooms():
        while True:
            await asyncio.sleep(5)
            try:
                async with lock:
                    with app.state.db:
                        app.state.chat.prune()
                        app.state.safety.prune()
                        app.state.incidents.prune()
                        social_policy.prune(app.state.db)
                    await expire_members()
                    await cleanup_pending(app.state.db, app.state.rtc)
            except Exception as error:
                LOGGER.error("Room cleanup pending: %s", type(error).__name__)
            finally:
                async with lock:
                    app.state.room_catalog.publish_locked()

    async def maintain_observability():
        # Keep the retention clock independent from slow SFU calls and the room
        # transaction lock. No client traffic is needed for idle samples to expire.
        while True:
            await asyncio.sleep(1)
            observability.prune()

    async def synchronize(presence=None, *, room_id=None):
        await expire_members(presence, room_id=room_id)
        await cleanup_pending(app.state.db, app.state.rtc)
        try:
            live = await app.state.rtc.list_rooms()
        except Exception:
            raise HTTPException(503, "LiveKit 暂时无法连接，请稍后重试") from None
        now = time.monotonic()
        for identifier, count in live.items():
            known_presence[identifier] = (now, count)
        rows = app.state.db.execute("SELECT * FROM rooms WHERE status='active'").fetchall()
        for room in rows:
            if room["id"] not in live:
                with app.state.db:
                    app.state.db.execute("UPDATE rooms SET status='closed' WHERE id=?", (room["id"],))
                    app.state.safety.forget_room(room["id"])
                    app.state.db.execute("UPDATE room_members SET active=0,generation=generation+1,signal_disconnected=0 WHERE room_id=? AND active=1", (room["id"],))
                    app.state.db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=?", (room["id"],))
                    app.state.seating.clear(room["id"])
                    app.state.db.execute("DELETE FROM seat_invitations WHERE room_id=?", (room["id"],))
                    app.state.db.execute("DELETE FROM room_presence WHERE room_id=?", (room["id"],))
                    app.state.chat.clear_room(room["id"])
                forget_room_presence(room["id"])
                await app.state.signal.close_room(room["id"])
        return live

    async def revoke_session(request, reason):
        user, session = authenticate(request, consent=False, termination=True)
        if session["revoked_at"] is not None and session["revoked_reason"] != reason:
            raise HTTPException(401, "登录已退出，该凭据只能重试原退出操作")
        db = app.state.db
        now = int(time.time())
        with db:
            db.execute("UPDATE sessions SET revoked_at=COALESCE(revoked_at,?), revoked_reason=? WHERE token_hash=?", (now, reason, session["token_hash"]))
            if reason == "withdrawal":
                db.execute("UPDATE consents SET withdrawn_at=COALESCE(withdrawn_at,?) WHERE user_id=?", (now, user["id"]))
            if reason == "deleted":
                db.execute("INSERT OR IGNORE INTO deletion_requests(user_id,requested_at) VALUES(?,?)", (user["id"], now))
            if reason in {"withdrawal", "deleted"}:
                app.state.chat.clear_sender(user["id"])
                app.state.safety.clear_user(user["id"])
                app.state.incidents.clear_user(user["id"])
        await app.state.signal.close_session(session["token_hash"])
        errors = False
        affected = db.execute("SELECT room_id FROM room_members WHERE user_id=? AND (active=1 OR room_id IN (SELECT room_id FROM media_cleanup WHERE user_id=?))", (user["id"], user["id"])).fetchall()
        for room in affected:
            try:
                if not await leave_member(room["room_id"], user["id"]):
                    errors = True
            except HTTPException:
                errors = True
        await cleanup_pending(db, app.state.rtc)
        if db.execute("SELECT 1 FROM media_cleanup WHERE user_id=?", (user["id"],)).fetchone():
            errors = True
        if db.execute("SELECT 1 FROM rooms WHERE owner_id=? AND status='closing'", (user["id"],)).fetchone():
            errors = True
        if errors:
            raise HTTPException(503, "登录已停止，但音频退出尚未确认，请重试")
        complete_deletions(db)
        return {"ok": True}

    async def revoke_account_authorizations(rows, *, deleted, withdrawn=False, withdrawal_epoch=None):
        # Only the named source sessions lose membership. A delayed old-session
        # logout must never eject a fresh account login from the same room.
        db, now = app.state.db, int(time.time())
        for row in rows:
            erase_withdrawal = False
            if withdrawn:
                privacy = db.execute("SELECT * FROM account_privacy_state WHERE user_id=?",(row["user_id"],)).fetchone()
                if withdrawal_epoch is not None:
                    erase_withdrawal = (not privacy or privacy["consent_epoch"]<=withdrawal_epoch) and (not privacy or privacy["withdrawal_epoch"]<withdrawal_epoch)
                elif not privacy or privacy["consent_epoch"] == 0:
                    # Compatibility with pre-epoch senders: never let a delayed
                    # old-source withdrawal tear down a fresh active source.
                    erase_withdrawal = not db.execute("""SELECT 1 FROM sessions s JOIN account_authorizations a ON a.token_hash=s.token_hash
                        WHERE a.user_id=? AND s.token_hash!=? AND s.revoked_at IS NULL AND s.expires_at>? LIMIT 1""",(row["user_id"],row["token_hash"],now)).fetchone()
            with db:
                db.execute("UPDATE sessions SET revoked_at=COALESCE(revoked_at,?),revoked_reason=? WHERE token_hash=?",
                           (now, "deleted" if deleted else "account-revoked", row["token_hash"]))
                if erase_withdrawal:
                    db.execute("UPDATE consents SET withdrawn_at=COALESCE(withdrawn_at,?) WHERE user_id=?", (now,row["user_id"]))
                if deleted:
                    db.execute("INSERT OR IGNORE INTO deletion_requests(user_id,requested_at) VALUES(?,?)", (row["user_id"], now))
                if deleted or erase_withdrawal:
                    room_started.erase(db,row["user_id"])
                    app.state.chat.clear_sender(row["user_id"])
                    social = db.execute("SELECT consent_epoch FROM account_social_privacy WHERE user_id=?",(row["user_id"],)).fetchone()
                    preserve_blocks = (not deleted and withdrawal_epoch is not None
                                       and social is not None and social[0] > withdrawal_epoch)
                    app.state.safety.clear_user(row["user_id"],preserve_blocks=preserve_blocks)
                    app.state.incidents.clear_user(row["user_id"],withdrawal_epoch=withdrawal_epoch if erase_withdrawal else None)
                if withdrawn and withdrawal_epoch is not None:
                    db.execute("""INSERT INTO account_privacy_state(user_id,withdrawal_epoch) VALUES(?,?)
                        ON CONFLICT(user_id) DO UPDATE SET withdrawal_epoch=MAX(withdrawal_epoch,excluded.withdrawal_epoch)""",(row["user_id"],withdrawal_epoch))
            await app.state.signal.close_session(row["token_hash"])
            members = db.execute("SELECT room_id FROM room_members WHERE user_id=? AND session_hash=? AND active=1",
                                 (row["user_id"], row["token_hash"])).fetchall()
            for member in members:
                with suppress(HTTPException):
                    await leave_member(member["room_id"], row["user_id"])
        await cleanup_pending(db, app.state.rtc)
        complete_deletions(db)
        # Rights are durable before media cleanup. Maintenance retries the latter.

    @app.get("/health")
    async def health():
        try:
            await app.state.rtc.list_rooms()
            return {"ok": True, "service": "kiki-livekit-lab", "provider": "livekit", "rtcConfigured": True}
        except Exception:
            return JSONResponse({"ok": False, "service": "kiki-livekit-lab", "provider": "livekit",
                                 "rtcConfigured": False}, status_code=503)

    @app.get("/v1/legal/documents")
    async def legal_documents():
        # Anonymous publication is available before login or renewed consent.
        # Text and acceptance requirements share the verified startup snapshot.
        return JSONResponse(app.state.legal_manifest, headers={"Cache-Control": "no-store"})

    @app.get("/v1/diagnostics")
    async def diagnostics(request: Request):
        async with lock:
            authenticate(request)
            return observability.snapshot(capacity())

    @app.post("/v1/rooms/{room_id}/quality", status_code=202)
    async def report_quality(room_id: str, payload: QualityReport, request: Request):
        async with lock:
            _user, member = chat_member(room_id, request)
            accepted = observability.record_quality(member["session_hash"], payload.quality,
                rtt_ms=payload.rtt_ms, jitter_ms=payload.jitter_ms,
                packet_loss_percent=payload.packet_loss_percent)
            return {"accepted": accepted}

    @app.post("/v1/auth/lab")
    async def login(payload: LabLogin):
        if settings.auth_mode != "lab":
            raise HTTPException(404, "接口不存在")
        if not hmac.compare_digest(hashlib.sha256(payload.accessCode.encode()).digest(),
                                   hashlib.sha256(settings.access_code.encode()).digest()):
            raise HTTPException(403, "实验邀请码不正确")
        validate_consent(payload.legalConsent)
        async with lock:
            now = int(time.time())
            user_id = "lab_" + uuid.uuid4().hex
            token = secrets.token_urlsafe(32)
            db = app.state.db
            with db:
                db.execute("INSERT INTO users(id,name,created_at) VALUES(?,?,?)", (user_id, payload.name, now))
                db.execute("INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)",
                           (hashlib.sha256(token.encode()).hexdigest(), user_id, now + SESSION_SECONDS))
                db.execute("INSERT INTO consents VALUES(?,?,?,?,?,NULL)", (user_id,
                    app.state.legal["privacyVersion"], app.state.legal["termsVersion"],
                    app.state.legal["documentHash"], now))
            user = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            return {"token": token, "user": user_json(user),
                    "sdk": sdk_json(user, {"expires_at": now + SESSION_SECONDS})}

    @app.post("/v1/auth/refresh")
    async def refresh(request: Request):
        user, session = authenticate(request)
        return {"user": user_json(user), "sdk": sdk_json(user, session)}

    @app.post("/v1/auth/logout")
    async def logout(request: Request):
        async with lock:
            return await revoke_session(request, "logout")

    @app.delete("/v1/account")
    async def delete_account(request: Request):
        if settings.auth_mode == "account":
            raise HTTPException(409, "请通过账号服务管理账号资料及授权")
        async with lock:
            return await revoke_session(request, "deleted")

    @app.get("/v1/me/legal-consent")
    async def legal_status(request: Request):
        user, _ = authenticate(request, consent=False)
        return consent_status(user["id"])

    @app.post("/v1/me/legal-consent")
    async def legal_acceptance(payload: ConsentRequest, request: Request):
        if settings.auth_mode == "account":
            raise HTTPException(409, "请通过账号服务管理账号资料及授权")
        async with lock:
            user, _ = authenticate(request, consent=False)
            validate_consent(payload.legalConsent)
            if consent_status(user["id"])["requiresAcceptance"]:
                with app.state.db:
                    app.state.db.execute("INSERT OR REPLACE INTO consents VALUES(?,?,?,?,?,NULL)",
                        (user["id"], app.state.legal["privacyVersion"], app.state.legal["termsVersion"],
                         app.state.legal["documentHash"], int(time.time())))
            return consent_status(user["id"])

    @app.delete("/v1/me/legal-consent")
    async def legal_withdrawal(request: Request):
        if settings.auth_mode == "account":
            raise HTTPException(409, "请通过账号服务管理账号资料及授权")
        async with lock:
            return await revoke_session(request, "withdrawal")

    @app.get("/v1/me")
    async def me(user=Depends(active_user)):
        return user_json(user)

    @app.patch("/v1/me")
    async def update_me(payload: ProfileUpdate, request: Request):
        if settings.auth_mode == "account":
            raise HTTPException(409, "请通过账号服务管理账号资料及授权")
        async with lock:
            user, _ = authenticate(request)
            mapping = {"name": "name", "bio": "bio", "avatarIndex": "avatar_index",
                       "notificationsEnabled": "notifications"}
            with app.state.db:
                for key, value in payload.model_dump(exclude_unset=True).items():
                    if value is not None:
                        app.state.db.execute(f"UPDATE users SET {mapping[key]}=? WHERE id=?", (value, user["id"]))
            return user_json(app.state.db.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone())

    @app.get("/v1/room-catalog/changes")
    async def room_catalog_changes(request: Request,
                                   after: int | None = Query(default=None, ge=0, le=9223372036854775807),
                                   waitSeconds: int = Query(default=15, ge=0, le=20)):
        async with lock:
            authenticate(request)
            revision, event = app.state.room_catalog.snapshot_locked()
            if after is None or revision != after:
                return {"revision": revision, "changed": True}
        await app.state.room_catalog.wait(event, waitSeconds)
        async with lock:
            # A session/consent/restriction can change while this request waits.
            authenticate(request)
            revision, _ = app.state.room_catalog.snapshot_locked()
            return {"revision": revision, "changed": revision != after}

    @app.get("/v1/rooms")
    async def rooms(request: Request):
        async with lock:
            user, _ = authenticate(request)
            live = await synchronize()
            rows = app.state.db.execute("SELECT * FROM rooms WHERE status='active' ORDER BY created_at DESC").fetchall()
            return {"rooms": [room_json(room, user["id"], live[room["id"]]) for room in rows if room["id"] in live]}

    @app.post("/v1/rooms")
    async def create_room(payload: RoomCreate, request: Request):
        if payload.isLive:
            raise HTTPException(422, "本次实验只支持语聊房，视频直播尚未接入")
        async with lock:
            user, session = authenticate(request)
            title = payload.title or default_room_title(user["name"])
            app.state.safety.enforce(user["id"], "chat")
            app.state.safety.check_text(title)
            app.state.safety.check_text(payload.category)
            if user["needs_nickname"]:
                raise HTTPException(409, "请先设置昵称")
            db = app.state.db
            # One room per host prevents accidentally exhausting the experimental SFU.
            await synchronize()
            if db.execute("SELECT id FROM rooms WHERE owner_id=? AND status IN ('creating','active','closing')", (user["id"],)).fetchone():
                raise HTTPException(409, "请先结束你已创建的房间")
            check_admission_capacity(None, user["id"], creating=True)
            room_id = "lk_" + uuid.uuid4().hex
            request.state.incident_room_id=room_id
            with db:
                db.execute("INSERT INTO rooms VALUES(?,?,?,?,?,'creating',?)", (room_id, user["id"],
                    title, payload.category, payload.theme, int(time.time())))
            try:
                await app.state.rtc.create_room(room_id)
                with db:
                    db.execute("UPDATE rooms SET status='active' WHERE id=?", (room_id,))
            except Exception as error:
                request.state.incident_code="request_timeout" if isinstance(error,TimeoutError) else "http_server_error"
                # A timed-out CreateRoom may still have succeeded remotely. Keep closing state
                # until deletion is confirmed; synchronize/startup both retry this compensation.
                try:
                    await close_room(room_id)
                except HTTPException:
                    pass
                raise HTTPException(503, "LiveKit 房间创建未完成，请稍后重试") from None
            ensure_room_model(get_room(room_id))
            return room_json(get_room(room_id), user["id"])

    @app.post("/v1/rooms/lookup")
    async def lookup_rooms(payload: RoomLookup, request: Request):
        async with lock:
            user, _ = authenticate(request)
            live = await synchronize()
            result = []
            for room_id in dict.fromkeys(payload.ids):
                room = app.state.db.execute("SELECT * FROM rooms WHERE id=? AND status='active'", (room_id,)).fetchone()
                if room and room_id in live:
                    result.append(room_json(room, user["id"], live[room_id]))
            return {"rooms": result}

    @app.get("/v1/rooms/{room_id}")
    async def room_details(room_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            live = await synchronize()
            return room_json(get_room(room_id), user["id"], live.get(room_id, 0))

    @app.patch("/v1/rooms/{room_id}")
    async def update_room(room_id: str, payload: RoomUpdate, request: Request):
        async with lock:
            user, session = authenticate(request)
            room = get_room(room_id)
            if room["owner_id"] != user["id"]:
                raise HTTPException(403, "只有房主可以修改或结束房间")
            if payload.title is not None or payload.theme is not None:
                if payload.title is not None:
                    app.state.safety.enforce(user["id"], "chat")
                    title = payload.title or default_room_title(user["name"])
                    app.state.safety.check_text(title)
                else:
                    title = room["title"]
                theme = payload.theme if payload.theme is not None else room["theme"]
                presence = {}
                await synchronize(presence, room_id=room_id)
                room = get_room(room_id)
                # Confirm live-room authorization before committing either field.
                state = await room_state(room_id, user, session, presence)
                if payload.title is not None and state["me"]["chatMuted"]:
                    raise HTTPException(403, "你已被禁言，暂时无法修改房间名称")
                if room["title"] != title or room["theme"] != theme:
                    with app.state.db:
                        app.state.db.execute("UPDATE rooms SET title=?,theme=? WHERE id=?", (title, theme, room_id))
                        bump(room_id)
                state["room"] = room_json(get_room(room_id), user["id"], state["room"]["audience"])
                state["revision"] = app.state.db.execute("SELECT revision FROM room_revisions WHERE room_id=?", (room_id,)).fetchone()[0]
                return state
            if payload.status in {"live", "active"}:
                if room["status"] != "active":
                    raise HTTPException(409, "房间已结束，请创建新房间")
            else:
                await close_room(room_id)
            return room_json(get_room(room_id), user["id"])

    @app.post("/v1/rooms/{room_id}/token")
    async def room_token(room_id: str, request: Request):
        async with lock:
            user, session = authenticate(request)
            if user["needs_nickname"]:
                raise HTTPException(409, "请先设置昵称")
            if (await request.body()) not in (b"", b"{}"):
                raise HTTPException(422, "入场身份和权限由服务器确定")
            live = await synchronize()
            room = get_room(room_id)
            if room["status"] != "active" or room_id not in live:
                raise HTTPException(409, "房间已结束")
            db = app.state.db
            if db.execute("SELECT 1 FROM room_bans WHERE room_id=? AND user_id=?", (room_id, user["id"])).fetchone():
                raise HTTPException(403, "你已被移出房间，需管理员解除禁入")
            participants = await participant_ids(room_id)
            check_admission_capacity(room_id, user["id"])
            if len(participants) >= settings.max_room_participants and user["id"] not in participants:
                raise HTTPException(409, f"房间已满，实验上限{settings.max_room_participants}人")
            existing = db.execute("SELECT * FROM room_members WHERE room_id=? AND user_id=?", (room_id, user["id"])).fetchone()
            if existing is None:
                with db:
                    db.execute("INSERT INTO room_members(room_id,user_id,session_hash,role,joined_at) VALUES(?,?,?,?,?)", (room_id, user["id"], session["token_hash"], "owner" if room["owner_id"] == user["id"] else "member", int(time.time())))
                    if room["owner_id"] == user["id"]:
                        db.execute("UPDATE room_seats SET user_id=? WHERE room_id=? AND seat_index=1 AND user_id IS NULL", (user["id"], room_id))
                    bump(room_id)
            elif not existing["active"] or existing["session_hash"] != session["token_hash"]:
                if not await apply_media(room_id, user["id"]):
                    raise HTTPException(503, "上次退出尚未确认，请稍后重试")
                with db:
                    db.execute("UPDATE room_members SET active=1,session_hash=?,generation=generation+1,joined_at=?,signal_disconnected=CASE WHEN active=1 THEN signal_disconnected ELSE 0 END WHERE room_id=? AND user_id=?", (session["token_hash"], int(time.time()), room_id, user["id"]))
                    bump(room_id)
                    if existing["active"]:
                        db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=COALESCE(offline_since,excluded.offline_since)", (room_id, user["id"], int(time.time())))
                    else:
                        db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=excluded.offline_since", (room_id, user["id"], int(time.time())))
            member = current_member(room_id, user, session)
            grants = member_permissions(member)
            token = app.state.rtc.participant_token(room_id, user_json(user), grants)
            with db:
                db.execute("INSERT OR REPLACE INTO memberships VALUES(?,?,?)", (room_id, user["id"], int(time.time())))
            return {"serverURL": settings.public_url, "participantToken": token,
                    "room": room_json(room, user["id"], len(participants))}

    @app.get("/v1/rooms/{room_id}/state")
    async def get_room_state(room_id: str, request: Request):
        async with lock:
            user, session = authenticate(request)
            presence = {}
            await synchronize(presence, room_id=room_id)
            return await room_state(room_id, user, session, presence)

    def chat_member(room_id, request):
        user, session = authenticate(request)
        room = get_room(room_id)
        if room["status"] != "active":
            raise HTTPException(409, "房间已结束")
        return user, current_member(room_id, user, session)

    async def broadcast_chat_sync(room_id, hint):
        # Content is already committed. A lost hint is repaired by incremental
        # HTTP polling and must never turn successful persistence into a failure.
        try:
            await asyncio.wait_for(app.state.rtc.broadcast_chat_sync(room_id, hint), timeout=1)
        except Exception:
            pass

    @app.get("/v1/rooms/{room_id}/messages")
    async def room_messages(room_id: str, request: Request,
                            afterSeq: int = Query(default=0, ge=0, le=9223372036854775807),
                            limit: int = Query(default=200, ge=1, le=200)):
        async with lock:
            user, _ = chat_member(room_id, request)
            with app.state.db:
                return app.state.safety.filter_chat(user["id"], app.state.chat.read(room_id, afterSeq, limit))

    @app.post("/v1/rooms/{room_id}/messages")
    async def send_room_message(room_id: str, payload: ChatSend, request: Request):
        async with lock:
            user, member = chat_member(room_id, request)
            app.state.safety.enforce(user["id"], "chat")
            app.state.safety.check_text(payload.text)
            if member["chat_muted"]:
                raise HTTPException(403, "你已被禁言，暂时无法发送文字")
            with app.state.db:
                message, created = app.state.chat.send(room_id, user, payload.clientMessageID, payload.text)
                hint = app.state.chat.notification(room_id)
        if created:
            await broadcast_chat_sync(room_id, hint)
        return message

    @app.put("/v1/rooms/{room_id}/announcement")
    async def update_room_announcement(room_id: str, payload: AnnouncementUpdate, request: Request):
        async with lock:
            user, member = chat_member(room_id, request)
            app.state.safety.enforce(user["id"], "chat")
            app.state.safety.check_text(payload.text)
            if member["role"] not in {"owner", "admin"}:
                raise HTTPException(403, "只有房主或管理员可以修改公告")
            if member["chat_muted"]:
                raise HTTPException(403, "你已被禁言，暂时无法修改文字")
            with app.state.db:
                announcement = app.state.chat.put_announcement(room_id, user["id"], payload.text)
                hint = app.state.chat.notification(room_id)
        await broadcast_chat_sync(room_id, hint)
        return announcement

    @app.post("/v1/rooms/{room_id}/leave")
    async def leave_room(room_id: str, request: Request):
        async with lock:
            user, session = authenticate(request)
            member = member_row(room_id, user["id"], required=False)
            if member:
                current_member(room_id, user, session)
            if not await leave_member(room_id, user["id"]):
                raise HTTPException(503, "退出尚未确认，请稍后重试")
            return {"ok": True}

    @app.post("/v1/rooms/{room_id}/actions")
    async def room_action(room_id: str, payload: RoomAction, request: Request):
        async with lock:
            user, session = authenticate(request)
            await synchronize()
            room = get_room(room_id)
            if room["status"] != "active":
                raise HTTPException(409, "房间已结束")
            actor = current_member(room_id, user, session)
            db = app.state.db
            action, target_id, index, enabled = payload.action, payload.targetUserID, payload.seatIndex, payload.enabled
            if action in {"request_seat", "accept_invite", "move_seat"}:
                app.state.safety.enforce(user["id"], "voice")
            # A narrow shape per action prevents identity/role fields being silently
            # ignored and makes all role checks server-side and auditable.
            shapes = {
                "request_seat": set(), "cancel_request": set(), "approve_request": {"targetUserID", "seatIndex"},
                "reject_request": {"targetUserID"}, "invite_seat": {"targetUserID", "seatIndex"},
                "accept_invite": set(), "decline_invite": set(), "leave_seat": set(), "move_seat": {"seatIndex"},
                "remove_seat": {"targetUserID"}, "lock_seat": {"seatIndex", "enabled"}, "lock_audio": {"seatIndex", "enabled"},
                "mute_audio": {"targetUserID", "enabled"}, "mute_chat": {"targetUserID", "enabled"},
                "set_admin": {"targetUserID", "enabled"}, "kick": {"targetUserID"}, "unban": {"targetUserID"}}
            supplied = {key for key, value in payload.model_dump().items() if key != "action" and value is not None}
            if not supplied <= shapes[action]:
                raise HTTPException(422, "操作参数不正确")
            requires_target = {"approve_request", "reject_request", "invite_seat", "remove_seat", "mute_audio", "mute_chat", "set_admin", "kick", "unban"}
            requires_index = {"move_seat", "lock_seat", "lock_audio"}
            requires_enabled = {"lock_seat", "lock_audio", "mute_audio", "mute_chat", "set_admin"}
            if ((action in requires_target and target_id is None) or (action in requires_index and index is None)
                    or (action in requires_enabled and enabled is None)):
                raise HTTPException(422, "缺少操作参数")
            moderation = {"approve_request", "reject_request", "invite_seat", "remove_seat", "lock_seat", "lock_audio", "mute_audio", "mute_chat", "set_admin", "kick", "unban"}
            if action in moderation and actor["role"] not in {"owner", "admin"}:
                raise HTTPException(403, "只有房主或管理员可以执行此操作")
            if action == "set_admin" and actor["role"] != "owner":
                raise HTTPException(403, "只有房主可以任免管理员")
            target = None
            if action in requires_target and action != "unban":
                target = member_row(room_id, target_id)
                if target_id == user["id"]:
                    raise HTTPException(403, "请使用自己的上麦或下麦操作")
                restrictive = action in {"remove_seat", "mute_audio", "mute_chat", "set_admin", "kick"}
                if restrictive and (target["role"] == "owner" or (actor["role"] == "admin" and target["role"] == "admin")):
                    raise HTTPException(403, "不能管理房主或同级管理员")
            affected = set()
            now = int(time.time())
            seat = db.execute("SELECT * FROM room_seats WHERE room_id=? AND user_id=?", (room_id, user["id"])).fetchone()

            online = await participant_ids(room_id)
            with db:
                db.execute("DELETE FROM seat_invitations WHERE room_id=? AND expires_at<=?", (room_id, now))
                if action == "request_seat":
                    if seat:
                        raise HTTPException(409, "你已在麦上")
                    app.state.seating.request(room_id, user["id"], now)
                elif action == "cancel_request":
                    app.state.seating.clear(room_id, user["id"])
                elif action == "approve_request":
                    if not db.execute("SELECT 1 FROM seat_requests WHERE room_id=? AND user_id=?", (room_id, target_id)).fetchone():
                        raise HTTPException(409, "该申请已取消或已处理")
                    if db.execute("SELECT 1 FROM room_seats WHERE room_id=? AND user_id=?", (room_id, target_id)).fetchone():
                        raise HTTPException(409, "对方已在麦上")
                    app.state.safety.enforce(target_id, "voice")
                    app.state.seating.approve(room_id, target_id, now)
                elif action == "reject_request":
                    if not db.execute("SELECT 1 FROM seat_requests WHERE room_id=? AND user_id=?", (room_id, target_id)).fetchone():
                        raise HTTPException(409, "该申请已取消或已处理")
                    app.state.seating.reject(room_id, target_id, now)
                elif action == "invite_seat":
                    if db.execute("SELECT 1 FROM room_seats WHERE room_id=? AND user_id=?", (room_id, target_id)).fetchone():
                        raise HTTPException(409, "对方已在麦上")
                    # Retain the legacy invitation DTO without a selectable seat.
                    next_slot = db.execute("SELECT seat_index FROM room_seats WHERE room_id=? AND seat_index>1 AND locked=0 AND user_id IS NULL ORDER BY seat_index LIMIT 1", (room_id,)).fetchone()
                    db.execute("INSERT OR REPLACE INTO seat_invitations VALUES(?,?,?,?)", (room_id, target_id, next_slot[0] if next_slot else 2, now+120))
                elif action == "accept_invite":
                    invitation = db.execute("SELECT * FROM seat_invitations WHERE room_id=? AND user_id=? AND expires_at>?", (room_id, user["id"], now)).fetchone()
                    if invitation is None:
                        raise HTTPException(409, "邀请已过期或已取消")
                    if seat:
                        raise HTTPException(409, "你已在麦上")
                    app.state.seating.request(room_id, user["id"], now)
                    app.state.seating.approve(room_id, user["id"], now)
                    db.execute("DELETE FROM seat_invitations WHERE room_id=? AND user_id=?", (room_id, user["id"]))
                elif action == "decline_invite":
                    db.execute("DELETE FROM seat_invitations WHERE room_id=? AND user_id=?", (room_id, user["id"]))
                elif action == "leave_seat":
                    if room["owner_id"] == user["id"]:
                        raise HTTPException(409, "房主固定在1号麦，可关闭麦克风或结束房间")
                    db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=? AND user_id=?", (room_id, user["id"]))
                    app.state.seating.clear(room_id, user["id"])
                    affected.add(user["id"])
                elif action == "move_seat":
                    raise HTTPException(409, "麦位按审批顺序安排，不能手动选择麦位")
                elif action == "remove_seat":
                    db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=? AND user_id=?", (room_id, target_id))
                    app.state.seating.clear(room_id, target_id)
                    affected.add(target_id)
                elif action in {"lock_seat", "lock_audio"}:
                    if action == "lock_seat" and index == 1 and enabled:
                        raise HTTPException(409, "1号麦为房主固定麦位")
                    locked = db.execute("SELECT * FROM room_seats WHERE room_id=? AND seat_index=?", (room_id, index)).fetchone()
                    occupant = member_row(room_id, locked["user_id"], required=False) if locked["user_id"] else None
                    if occupant and occupant["user_id"] != user["id"] and (occupant["role"] == "owner" or (actor["role"] == "admin" and occupant["role"] == "admin")):
                        raise HTTPException(403, "不能锁定房主或同级管理员的麦位")
                    column = "locked" if action == "lock_seat" else "audio_locked"
                    db.execute(f"UPDATE room_seats SET {column}=? WHERE room_id=? AND seat_index=?", (enabled, room_id, index))
                    if occupant:
                        if action == "lock_seat" and enabled:
                            db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=? AND seat_index=?", (room_id, index))
                            app.state.seating.clear(room_id, occupant["user_id"])
                        affected.add(occupant["user_id"])
                    if action == "lock_seat" and enabled:
                        db.execute("DELETE FROM seat_invitations WHERE room_id=? AND seat_index=?", (room_id, index))
                elif action in {"mute_audio", "mute_chat", "set_admin"}:
                    if action == "set_admin":
                        db.execute("UPDATE room_members SET role=? WHERE room_id=? AND user_id=?", ("admin" if enabled else "member", room_id, target_id))
                    else:
                        column = "audio_muted" if action == "mute_audio" else "chat_muted"
                        db.execute(f"UPDATE room_members SET {column}=? WHERE room_id=? AND user_id=?", (enabled, room_id, target_id))
                    affected.add(target_id)
                elif action == "kick":
                    db.execute("INSERT OR REPLACE INTO room_bans VALUES(?,?,?)", (room_id, target_id, now))
                    db.execute("UPDATE room_members SET active=0,generation=generation+1,signal_disconnected=0,role='member' WHERE room_id=? AND user_id=?", (room_id, target_id))
                    db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=? AND user_id=?", (room_id, target_id))
                    app.state.seating.clear(room_id, target_id)
                    db.execute("DELETE FROM seat_invitations WHERE room_id=? AND user_id=?", (room_id, target_id))
                    db.execute("DELETE FROM room_presence WHERE room_id=? AND user_id=?", (room_id, target_id))
                    schedule_media(room_id, target_id, "remove")
                    affected.add(target_id)
                elif action == "unban":
                    db.execute("DELETE FROM room_bans WHERE room_id=? AND user_id=?", (room_id, target_id))
                affected.update(reconcile_ordered_seats(room, online - ({target_id} if action == "kick" else set())))
                for person_id in affected:
                    if action != "kick" or person_id != target_id:
                        schedule_media(room_id, person_id, "permissions")
                bump(room_id)
            success = True
            for person_id in affected:
                success = await apply_media(room_id, person_id) and success
            if not success:
                raise HTTPException(503, "权限已停止，但媒体服务尚未确认，请稍后重试")
            return await room_state(room_id, user, session)

    @app.get("/v1/library")
    async def library(request: Request):
        async with lock:
            user, _ = authenticate(request)
            live = await synchronize()
            db = app.state.db
            result = {}
            for key, sql in (("favorites", "SELECT r.* FROM favorites f JOIN rooms r ON r.id=f.room_id WHERE f.user_id=? ORDER BY f.created_at DESC,r.id DESC"),
                             ("recents", "SELECT r.* FROM history h JOIN rooms r ON r.id=h.room_id WHERE h.user_id=? ORDER BY h.created_at DESC,h.rowid DESC LIMIT 20"),
                             ("created", "SELECT * FROM rooms WHERE owner_id=? ORDER BY created_at DESC,id DESC")):
                rows = db.execute(sql, (user["id"],)).fetchall()
                # Synchronization closes missing SFU rooms. Historical cards
                # remain useful but retain status=ended and a zero audience.
                result[key] = [room_json(row, user["id"], live.get(row["id"],0) if row["status"] == "active" else 0)
                               for row in rows if row["status"] in {"active","closed","closing"}]
            return result

    @app.put("/v1/favorites/{room_id}")
    async def favorite(room_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            room = get_room(room_id)
            if room["status"] != "active":
                raise HTTPException(409, "房间已结束")
            with app.state.db:
                app.state.db.execute("INSERT OR IGNORE INTO favorites VALUES(?,?,?)", (user["id"], room_id, int(time.time())))
            return {"ok": True}

    @app.delete("/v1/favorites/{room_id}")
    async def unfavorite(room_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            with app.state.db:
                app.state.db.execute("DELETE FROM favorites WHERE user_id=? AND room_id=?", (user["id"], room_id))
            return {"ok": True}

    @app.post("/v1/history/{room_id}")
    async def visit(room_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            get_room(room_id)
            with app.state.db:
                app.state.db.execute("INSERT OR REPLACE INTO history VALUES(?,?,?)", (user["id"], room_id, int(time.time())))
                app.state.db.execute("""DELETE FROM history WHERE user_id=? AND room_id NOT IN
                    (SELECT room_id FROM history WHERE user_id=? ORDER BY created_at DESC,rowid DESC LIMIT 20)""",(user["id"],user["id"]))
            return {"ok": True}

    @app.delete("/v1/history/{room_id}")
    async def forget_visit(room_id: str, request: Request):
        async with lock:
            user, _ = authenticate(request)
            with app.state.db:
                app.state.db.execute("DELETE FROM history WHERE user_id=? AND room_id=?",(user["id"],room_id))
            return {"ok": True}

    @app.delete("/v1/history")
    async def clear_visits(request: Request):
        async with lock:
            user, _ = authenticate(request)
            with app.state.db:
                app.state.db.execute("DELETE FROM history WHERE user_id=?",(user["id"],))
            return {"ok": True}

    async def authorize_signal(claims, register):
        async with lock:
            room = get_room(claims.room)
            if room["status"] != "active":
                raise HTTPException(403, "房间已结束")
            member = member_row(claims.room, claims.user_id)
            app.state.safety.enforce(claims.user_id)
            if (not hmac.compare_digest(member["session_hash"], claims.session_hash)
                    or member["generation"] != claims.generation
                    or not valid_session(claims.session_hash)
                    or app.state.db.execute("SELECT 1 FROM room_bans WHERE room_id=? AND user_id=?", (claims.room, claims.user_id)).fetchone()):
                raise HTTPException(403, "入场权限已失效")
            if member["signal_disconnected"]:
                # Preserve a timely verified recovery before replacing its
                # connection again; authorization/validation alone cannot reset
                # the clock of an unconfirmed attempt.
                await participant_ids(claims.room)
            presence = app.state.db.execute("SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?",
                                            (claims.room, claims.user_id)).fetchone()
            grace = OWNER_DISCONNECT_GRACE_SECONDS if claims.user_id == room["owner_id"] else DISCONNECT_GRACE_SECONDS
            if presence is not None and presence[0] is not None and presence[0] <= time.time() - grace:
                # A timely successful current handshake may not yet have been
                # observed by the maintenance tick. Confirm it before denying a
                # healthy replacement; pending/failed registrations cannot help.
                await participant_ids(claims.room)
                presence = app.state.db.execute("SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?",
                                                (claims.room, claims.user_id)).fetchone()
                if presence is not None and presence[0] is not None and presence[0] <= time.time() - grace:
                    await leave_member(claims.room, claims.user_id)
                    raise HTTPException(403, "重连宽限已结束，请重新进入房间")
            check_admission_capacity(claims.room, claims.user_id)
            user = app.state.db.execute("SELECT * FROM users WHERE id=?", (claims.user_id,)).fetchone()
            token = app.state.rtc.participant_token(claims.room, user_json(user), member_permissions(member))
            authorization = SignalAuthorization(claims.room, claims.user_id, claims.session_hash, claims.generation, token)
            connection = register(authorization)
            if not connection.is_validation:
                connections[(claims.room, claims.user_id)] = connection
                with app.state.db:
                    app.state.db.execute("UPDATE room_members SET signal_disconnected=1 WHERE room_id=? AND user_id=?", (claims.room, claims.user_id))
                    app.state.db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=COALESCE(offline_since,excluded.offline_since)", (claims.room, claims.user_id, int(time.time())))
                    bump(claims.room)
            return connection

    async def signal_disconnected(connection):
        if connection.is_validation:
            return
        async with lock:
            key = (connection.room, connection.user_id)
            if connections.get(key) is not connection:
                return
            connections.pop(key, None)
            member = member_row(connection.room, connection.user_id, required=False)
            if member and member["generation"] == connection.generation:
                room = get_room(connection.room)
                grace = OWNER_DISCONNECT_GRACE_SECONDS if room["owner_id"] == connection.user_id else DISCONNECT_GRACE_SECONDS
                disconnect_deadlines[key] = time.monotonic() + grace
                with app.state.db:
                    previous = app.state.db.execute("SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?", key).fetchone()
                    timely_success = (member["signal_disconnected"] and previous is not None and previous[0] is not None
                        and connection.upstream_connected and connection.upstream_connected_at is not None
                        and connection.upstream_connected_at < previous[0] + grace)
                    app.state.db.execute("UPDATE room_members SET signal_disconnected=1 WHERE room_id=? AND user_id=?", key)
                    if timely_success:
                        app.state.db.execute("UPDATE room_presence SET offline_since=? WHERE room_id=? AND user_id=?", (int(time.time()), *key))
                    else:
                        app.state.db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=COALESCE(offline_since,excluded.offline_since)", (*key, int(time.time())))
                    bump(connection.room)

    app.state.signal = SignalGateway(settings.api_key, settings.api_secret, authorize_signal, signal_disconnected,
                                    observer=observability.record_signal)
    app.include_router(app.state.signal.router)
    app.include_router(build_admin_router(app, lock))
    app.include_router(ops_gateway.build_router(app, settings, lock))
    app.include_router(account_bridge.build_router(app, settings, lock, user_json, sdk_json, revoke_account_authorizations))
    app.include_router(social_policy.build_router(app, settings, lock, valid_session))
    app.include_router(room_started.build_router(app, settings, lock))
    app.include_router(incidents.build_router(app, settings, lock, authenticate))
    # Exposed for focused lifecycle/authorization tests without a real WebRTC client.
    app.state.authorize_signal = authorize_signal
    app.state.signal_disconnected = signal_disconnected

    @app.api_route("/v1/{path:path}", methods=["GET", "POST", "PATCH", "PUT", "DELETE"])
    async def unsupported(path: str, user=Depends(active_user)):
        if path.startswith(("me/avatar", "auth/apple")):
            raise HTTPException(501, "LiveKit 基础实验暂未接入此功能")
        raise HTTPException(404, "接口不存在")

    return app


app = create_app()
