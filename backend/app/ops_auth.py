"""Passkey identities and individually granted operations capabilities.

These accounts, challenges, credentials and sessions have no relationship to
ordinary Apple business accounts or the former shared management passphrase.
"""
import argparse
import asyncio
from collections import defaultdict, deque
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
import unicodedata
import uuid
from typing import Literal

from fastapi import APIRouter, HTTPException, Request
import httpx
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from webauthn import (generate_authentication_options, generate_registration_options,
                      options_to_json, verify_authentication_response, verify_registration_response)
from webauthn.helpers.cose import COSEAlgorithmIdentifier
from webauthn.helpers.structs import (AuthenticatorAttachment, AuthenticatorSelectionCriteria,
                                      ResidentKeyRequirement, UserVerificationRequirement)

RP_ID = "kiki.group"
ORIGIN = "https://kiki.group"
VOICE_URL = "https://furby.top/internal/admin/v2/dashboard"
VOICE_PATH = "/internal/admin/v2/dashboard"
VOICE_MODERATION_PATHS = {kind: "/internal/admin/v2/moderation/" + kind for kind in ("query", "action")}
VOICE_INCIDENT_QUERY_PATH = "/internal/admin/v2/incidents/query"
SCOPES = ("account", "voice", "community")
CHALLENGE_SECONDS = 120
SESSION_SECONDS = 8 * 3600
MAX_BODY = 32768
MAX_DASHBOARD_BYTES = 2 * 1024 * 1024
VOICE_DEADLINE_SECONDS = 3.0
SCHEMA = """
CREATE TABLE IF NOT EXISTS ops_accounts(
 account_id TEXT PRIMARY KEY, user_handle BLOB NOT NULL UNIQUE,
 name TEXT, created_at INTEGER NOT NULL, disabled_at INTEGER);
CREATE TABLE IF NOT EXISTS ops_credentials(
 credential_id BLOB PRIMARY KEY, account_id TEXT NOT NULL REFERENCES ops_accounts(account_id) ON DELETE CASCADE,
 public_key BLOB NOT NULL, sign_count INTEGER NOT NULL, device_type TEXT NOT NULL,
 backed_up INTEGER NOT NULL, created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS ops_challenges(
 transaction_id TEXT PRIMARY KEY, kind TEXT NOT NULL, challenge BLOB NOT NULL,
 account_id TEXT, user_handle BLOB, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS ops_challenge_expiry ON ops_challenges(expires_at);
CREATE TABLE IF NOT EXISTS ops_sessions(
 token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES ops_accounts(account_id) ON DELETE CASCADE,
 created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS ops_session_account ON ops_sessions(account_id);
CREATE TABLE IF NOT EXISTS ops_grants(
 account_id TEXT NOT NULL REFERENCES ops_accounts(account_id) ON DELETE CASCADE,
 service TEXT NOT NULL CHECK(service IN ('account','voice','community')), granted_at INTEGER NOT NULL,
 PRIMARY KEY(account_id,service));
CREATE TABLE IF NOT EXISTS ops_audit(
 event_id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL,
 actor TEXT NOT NULL, action TEXT NOT NULL, account_id TEXT NOT NULL,
 name TEXT, service TEXT);
"""


def initialize_database(db):
    db.executescript(SCHEMA)
    # Existing installations have a restrictive CHECK constraint. Rebuild only
    # this independent ACL table atomically; existing viewers gain no new grant.
    sql = db.execute("SELECT sql FROM sqlite_master WHERE name='ops_grants'").fetchone()[0]
    if "'community'" not in sql or "'gifts'" in sql:
        db.execute("SAVEPOINT ops_acl_upgrade")
        try:
            db.execute("ALTER TABLE ops_grants RENAME TO ops_grants_previous")
            db.execute("""CREATE TABLE ops_grants(
                account_id TEXT NOT NULL REFERENCES ops_accounts(account_id) ON DELETE CASCADE,
                service TEXT NOT NULL CHECK(service IN ('account','voice','community')),
                granted_at INTEGER NOT NULL, PRIMARY KEY(account_id,service))""")
            db.execute("INSERT INTO ops_grants SELECT * FROM ops_grants_previous WHERE service IN ('account','voice','community')")
            db.execute("DROP TABLE ops_grants_previous")
            db.execute("RELEASE ops_acl_upgrade")
        except Exception:
            db.execute("ROLLBACK TO ops_acl_upgrade")
            db.execute("RELEASE ops_acl_upgrade")
            raise
    purge_expired(db)


def purge_expired(db):
    now = int(time.time())
    db.execute("DELETE FROM ops_challenges WHERE expires_at<=?",(now,))
    db.execute("DELETE FROM ops_sessions WHERE expires_at<=?",(now,))


def validate_settings(settings):
    if settings.admin_auth_mode not in {"legacy", "passkey"}:
        raise RuntimeError("ADMIN_AUTH_MODE must be legacy or passkey")
    if settings.admin_auth_mode == "passkey":
        secret = settings.ops_bridge_secret
        if len(secret) < 43 or len(set(secret)) < 16:
            raise RuntimeError("Configure an independent high-entropy operations bridge secret")
        if secret in {settings.voice_bridge_secret, settings.secret_key, settings.apple_token_encryption_key}:
            raise RuntimeError("Operations bridge credentials must be independent")
        if settings.admin_passphrase_hash:
            from .admin import verify_passphrase
            if verify_passphrase(secret, settings.admin_passphrase_hash):
                raise RuntimeError("Operations bridge credentials must differ from the old management passphrase")


def encode(value):
    import base64
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def decode(value, *, maximum=16384):
    import base64
    if (not isinstance(value, str) or not 1 <= len(value) <= maximum
            or not re.fullmatch(r"[A-Za-z0-9_-]+", value)):
        raise ValueError("Invalid Base64URL")
    result = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    if encode(result) != value:
        raise ValueError("Noncanonical Base64URL")
    return result


def signed_ops_headers(secret, *, timestamp=None, nonce=None, path=VOICE_PATH, body=b"{}", method="POST"):
    timestamp = str(int(time.time()) if timestamp is None else timestamp)
    nonce = nonce or secrets.token_hex(16)
    message = "\n".join(("account-voice-ops-v2", method, path, timestamp, nonce,
                         hashlib.sha256(body).hexdigest())).encode()
    return {"Content-Type": "application/json", "X-Kiki-Ops-Timestamp": timestamp,
            "X-Kiki-Ops-Nonce": nonce,
            "X-Kiki-Ops-Signature": hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()}


class Empty(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Verification(Empty):
    transactionID: str = Field(pattern=r"^[a-f0-9]{64}$")
    credential: dict


class NameUpdate(Empty):
    name: str = Field(min_length=1, max_length=128, strict=True)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value):
        value = unicodedata.normalize("NFC", value).strip()
        if not 1 <= len(value) <= 32 or any(unicodedata.category(char) in {"Cc", "Cf", "Cs"} for char in value):
            raise ValueError("Invalid operations name")
        return value


class ModerationQuery(Empty):
    status: Literal["pending", "resolved", "all"] = "pending"
    limit: int = Field(default=30, strict=True, ge=1, le=50)


class IncidentQuery(Empty):
    severity: Literal["all", "warning", "error"] = "all"
    operation: Literal["all", "create_room", "join_room", "room_runtime"] = "all"
    userQuery: str | None = Field(default=None, strict=True, max_length=80)
    limit: int = Field(default=30, strict=True, ge=1, le=50)
    cursor: str | None = Field(default=None, strict=True,
        pattern=r"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$")

    @field_validator("userQuery")
    @classmethod
    def safe_query(cls, value):
        if value is not None and any(unicodedata.category(char) in {"Cc", "Cf", "Cs"} for char in value):
            raise ValueError("Invalid account query")
        return value.strip() if value is not None else None

    @field_validator("cursor")
    @classmethod
    def canonical_cursor(cls, value):
        return str(uuid.UUID(value)) if value is not None else None


class ModerationAction(Empty):
    requestID: str = Field(pattern=r"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$", strict=True)
    reportID: str = Field(pattern=r"^[A-Za-z0-9_-]{1,100}$", strict=True)
    action: Literal["warn", "mute_chat", "mute_audio", "ban_user", "close_room", "dismiss", "restore_user"]
    durationSeconds: int | None = Field(default=None, strict=True, ge=60, le=2592000)
    note: str = Field(min_length=1, max_length=500, strict=True)

    @field_validator("requestID")
    @classmethod
    def canonical_request_id(cls, value):
        return str(uuid.UUID(value))

    @field_validator("note")
    @classmethod
    def safe_note(cls, value):
        value = value.strip()
        if not value:
            raise ValueError("A moderation reason is required")
        if any(unicodedata.category(char) in {"Cc", "Cf", "Cs"} and char != "\n" for char in value):
            raise ValueError("Invalid moderation note")
        return value

    @model_validator(mode="after")
    def valid_duration(self):
        timed = self.action in {"mute_chat", "mute_audio", "ban_user"}
        if timed != (self.durationSeconds is not None):
            raise ValueError("Duration is required only for temporary restrictions")
        return self


class RequestLimits:
    def __init__(self):
        self.events = defaultdict(deque)
        self.lock = threading.Lock()

    def check(self, key, limit, seconds):
        now = time.monotonic()
        with self.lock:
            if len(self.events) > 4096:
                self.events = defaultdict(deque, {k:q for k,q in self.events.items() if q and now-q[-1] < 600})
            queue = self.events[key]
            while queue and queue[0] <= now-seconds:
                queue.popleft()
            if len(queue) >= limit:
                raise HTTPException(429, "操作过于频繁，请稍后重试", headers={"Retry-After":str(seconds)})
            queue.append(now)


class OpsService:
    def __init__(self, settings, database):
        self.settings, self.database = settings, database
        self.limiter = RequestLimits()
        self.http = httpx.AsyncClient(timeout=httpx.Timeout(3.0, connect=1.0),
                                     follow_redirects=False, trust_env=False)

    async def close(self):
        await self.http.aclose()

    def check_request(self, request):
        if self.settings.admin_auth_mode != "passkey":
            raise HTTPException(404, "接口不存在")
        if (request.headers.get("origin") not in (None, ORIGIN)
                or request.headers.get("sec-fetch-site", "") not in {"", "same-origin", "none"}):
            raise HTTPException(403, "管理请求来源不正确")
        if request.url.query:
            raise HTTPException(422, "管理接口不接受查询参数")

    def limited(self, request, kind, maximum, seconds):
        self.check_request(request)
        peer = request.client.host if request.client else "unknown"
        self.limiter.check((kind,"ip",peer), maximum, seconds)
        self.limiter.check((kind,"global"), maximum*10, seconds)

    def options(self, request, kind):
        self.limited(request, kind+"-options", 10 if kind == "registration" else 30, 300)
        transaction, challenge = secrets.token_hex(32), secrets.token_bytes(32)
        now = int(time.time())
        account_id = "ops_"+uuid.uuid4().hex if kind == "registration" else None
        user_handle = secrets.token_bytes(32) if kind == "registration" else None
        with self.database(self.settings) as db:
            db.execute("DELETE FROM ops_challenges WHERE expires_at<=?", (now,))
            if db.execute("SELECT COUNT(*) FROM ops_challenges").fetchone()[0] >= 1000:
                raise HTTPException(429, "登录请求繁忙，请稍后重试", headers={"Retry-After":"120"})
            db.execute("INSERT INTO ops_challenges VALUES(?,?,?,?,?,?,?)",
                       (transaction,kind,challenge,account_id,user_handle,now,now+CHALLENGE_SECONDS))
        if kind == "registration":
            options = generate_registration_options(rp_id=RP_ID, rp_name="kiki 运维", user_name=account_id,
                user_id=user_handle, user_display_name="kiki 运维新账号", challenge=challenge,
                timeout=CHALLENGE_SECONDS*1000, supported_pub_key_algs=[COSEAlgorithmIdentifier.ECDSA_SHA_256],
                authenticator_selection=AuthenticatorSelectionCriteria(authenticator_attachment=AuthenticatorAttachment.PLATFORM,
                    resident_key=ResidentKeyRequirement.REQUIRED,require_resident_key=True,
                    user_verification=UserVerificationRequirement.REQUIRED))
        else:
            options = generate_authentication_options(rp_id=RP_ID,challenge=challenge,
                timeout=CHALLENGE_SECONDS*1000,user_verification=UserVerificationRequirement.REQUIRED)
        return {"transactionID":transaction,"publicKey":json.loads(options_to_json(options))}

    def consume(self, transaction_id, kind):
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM ops_challenges WHERE transaction_id=?",(transaction_id,)).fetchone()
            db.execute("DELETE FROM ops_challenges WHERE transaction_id=?",(transaction_id,))
        if row is None or row["kind"] != kind or row["expires_at"] <= int(time.time()):
            raise HTTPException(409, "登录挑战已过期或已使用，请重新开始")
        return row

    def client_data(self, credential):
        if (credential.get("type") != "public-key" or credential.get("id") != credential.get("rawId")
                or len(decode(credential.get("rawId"),maximum=2048)) > 1024):
            raise ValueError("Invalid credential ID")
        response = credential.get("response")
        if not isinstance(response,dict):
            raise ValueError("Invalid credential response")
        value = json.loads(decode(response.get("clientDataJSON"),maximum=8192))
        if (not isinstance(value,dict) or value.get("crossOrigin",False) is not False
                or value.get("origin") != ORIGIN or "topOrigin" in value):
            raise ValueError("Invalid client origin")
        return response

    def issue_session(self, db, account_id):
        now = int(time.time())
        db.execute("DELETE FROM ops_sessions WHERE expires_at<=?",(now,))
        db.execute("""DELETE FROM ops_sessions WHERE account_id=? AND token_hash NOT IN
            (SELECT token_hash FROM ops_sessions WHERE account_id=? ORDER BY created_at DESC LIMIT 7)""",(account_id,account_id))
        token = secrets.token_urlsafe(32)
        db.execute("INSERT INTO ops_sessions VALUES(?,?,?,?)",(hashlib.sha256(token.encode()).hexdigest(),account_id,now,now+SESSION_SECONDS))
        return {"token":token,"expiresAt":now+SESSION_SECONDS,"serviceID":"ops-identity","role":"member",
                "account":self.account_json(db,account_id)}

    def registration(self, payload, request):
        self.limited(request,"registration-verify",20,300)
        challenge = self.consume(payload.transactionID,"registration")
        try:
            self.client_data(payload.credential)
            result = verify_registration_response(credential=payload.credential,
                expected_challenge=challenge["challenge"],expected_rp_id=RP_ID,expected_origin=ORIGIN,
                require_user_presence=True,require_user_verification=True,
                supported_pub_key_algs=[COSEAlgorithmIdentifier.ECDSA_SHA_256])
        except Exception:
            raise HTTPException(401,"通行密钥验证失败，请重新开始") from None
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM ops_credentials WHERE credential_id=?",(result.credential_id,)).fetchone():
                raise HTTPException(409,"该通行密钥已注册，请使用登录")
            now = int(time.time())
            db.execute("INSERT INTO ops_accounts VALUES(?,?,NULL,?,NULL)",(challenge["account_id"],challenge["user_handle"],now))
            db.execute("INSERT INTO ops_credentials VALUES(?,?,?,?,?,?,?,?)",(result.credential_id,challenge["account_id"],
                result.credential_public_key,result.sign_count,result.credential_device_type.value,
                result.credential_backed_up,now,now))
            db.execute("INSERT INTO ops_audit(recorded_at,actor,action,account_id) VALUES(?,?,?,?)",
                       (now,"passkey","register",challenge["account_id"]))
            return self.issue_session(db,challenge["account_id"])

    def authentication(self, payload, request):
        self.limited(request,"authentication-verify",30,300)
        challenge = self.consume(payload.transactionID,"authentication")
        try:
            response = self.client_data(payload.credential)
            credential_id = decode(payload.credential["rawId"],maximum=2048)
            user_handle = decode(response.get("userHandle"),maximum=128)
            with self.database(self.settings) as db:
                credential = db.execute("""SELECT c.*,a.user_handle,a.disabled_at FROM ops_credentials c
                    JOIN ops_accounts a ON a.account_id=c.account_id WHERE credential_id=?""",(credential_id,)).fetchone()
            if (credential is None or credential["disabled_at"] is not None
                    or not hmac.compare_digest(user_handle,credential["user_handle"])):
                raise ValueError("Unknown credential")
            result = verify_authentication_response(credential=payload.credential,
                expected_challenge=challenge["challenge"],expected_rp_id=RP_ID,expected_origin=ORIGIN,
                credential_public_key=credential["public_key"],credential_current_sign_count=credential["sign_count"],
                require_user_verification=True)
        except Exception:
            raise HTTPException(401,"通行密钥验证失败，请重新开始") from None
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            updated = db.execute("""UPDATE ops_credentials SET sign_count=?,backed_up=?,device_type=?,last_used_at=?
                WHERE credential_id=? AND sign_count=? AND account_id IN
                (SELECT account_id FROM ops_accounts WHERE disabled_at IS NULL)""",
                (result.new_sign_count,result.credential_backed_up,result.credential_device_type.value,int(time.time()),
                 credential_id,credential["sign_count"])).rowcount
            if not updated:
                raise HTTPException(401,"通行密钥状态已变化，请重新登录")
            return self.issue_session(db,credential["account_id"])

    def authenticate(self, request, db):
        self.check_request(request)
        value = request.headers.get("authorization","")
        if not re.fullmatch(r"Bearer [A-Za-z0-9_-]{43}",value):
            raise HTTPException(401,"运维登录已过期，请重新登录")
        digest = hashlib.sha256(value[7:].encode()).hexdigest()
        row = db.execute("""SELECT a.*,s.token_hash FROM ops_sessions s JOIN ops_accounts a ON a.account_id=s.account_id
            WHERE s.token_hash=? AND s.expires_at>? AND a.disabled_at IS NULL""",(digest,int(time.time()))).fetchone()
        if row is None:
            raise HTTPException(401,"运维登录已过期，请重新登录")
        return row

    def account_json(self, db, account_id):
        row = db.execute("SELECT * FROM ops_accounts WHERE account_id=?",(account_id,)).fetchone()
        grants = {r[0] for r in db.execute("SELECT service FROM ops_grants WHERE account_id=?",(account_id,))}
        return {"id":account_id,"name":row["name"],"needsName":row["name"] is None,
                "permissions":{scope:scope in grants for scope in SCOPES}}

    def scope(self, request, db, service):
        user = self.authenticate(request,db)
        if not user["name"] or not db.execute("SELECT 1 FROM ops_grants WHERE account_id=? AND service=?",(user["account_id"],service)).fetchone():
            raise HTTPException(403,"尚未获准使用该功能，请联系运营者授权")
        self.limiter.check((service,user["account_id"]),60,60)
        return user

    async def voice_moderation(self, request, payload, kind):
        with self.database(self.settings) as db:
            actor = self.scope(request, db, "community")
            actor_id = actor["account_id"]
        if kind == "action":
            self.limiter.check(("community-action", actor_id), 20, 60)
        path = VOICE_MODERATION_PATHS[kind]
        # The public payload cannot supply an actor, URL, path, HTTP method or
        # credential. The exact bytes containing the authenticated stable ID
        # are signed, including for reads, and are never logged here.
        forwarded = {**payload.model_dump(exclude_none=True), "opsActorID": actor_id}
        content = json.dumps(forwarded, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
        headers = signed_ops_headers(self.settings.ops_bridge_secret, path=path, body=content)
        headers["Accept-Encoding"] = "identity"
        upstream_status = None
        try:
            async with asyncio.timeout(VOICE_DEADLINE_SECONDS):
                async with self.http.stream("POST", "https://furby.top" + path,
                                            content=content, headers=headers) as response:
                    upstream_status = response.status_code
                    if (upstream_status not in {200, 404, 409, 422}
                            or response.headers.get("content-encoding", "identity").lower() != "identity"):
                        raise ValueError("Moderation service unavailable")
                    body = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=8192):
                        if len(body) + len(chunk) > MAX_DASHBOARD_BYTES:
                            raise ValueError("Moderation response too large")
                        body.extend(chunk)
                result = json.loads(body)
            if not isinstance(result, dict):
                raise ValueError("Invalid moderation response")
            if upstream_status == 200:
                if kind == "query":
                    reports = result.get("reports")
                    if (type(result.get("schemaVersion")) is not int or result["schemaVersion"] != 1
                            or not isinstance(reports, list) or len(reports) > payload.limit
                            or any(not isinstance(item, dict) for item in reports)):
                        raise ValueError("Invalid moderation query response")
                elif (result.get("ok") is not True or result.get("requestID") != payload.requestID
                      or result.get("reportID") != payload.reportID or result.get("action") != payload.action):
                    raise ValueError("Invalid moderation action response")
        except (httpx.HTTPError, ValueError, TypeError, TimeoutError):
            # Actions carry requestID and are idempotent remotely. Do not retry
            # blindly here: a timeout can occur after the remote commit.
            raise HTTPException(503, "社区管理暂时不可用，请刷新状态后重试") from None
        with self.database(self.settings) as db:
            self.scope(request, db, "community")
        if upstream_status != 200:
            messages = {404: "举报记录不存在或证据已过期", 409: "处理状态已变化，请刷新后重试", 422: "该举报不支持所选处理方式"}
            raise HTTPException(upstream_status, messages[upstream_status])
        return result

    async def voice_dashboard(self, request):
        with self.database(self.settings) as db:
            self.scope(request,db,"voice")
        try:
            headers = signed_ops_headers(self.settings.ops_bridge_secret)
            # A compressed response could expand inside an HTTP decoder before
            # our byte limit is observed. The aggregate endpoint uses plain JSON.
            headers["Accept-Encoding"] = "identity"
            async with asyncio.timeout(VOICE_DEADLINE_SECONDS):
                async with self.http.stream("POST",VOICE_URL,content=b"{}",headers=headers) as response:
                    if (response.status_code != 200
                            or response.headers.get("content-encoding", "identity").lower() != "identity"):
                        raise ValueError("Voice dashboard unavailable")
                    body = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=8192):
                        if len(body) + len(chunk) > MAX_DASHBOARD_BYTES:
                            raise ValueError("Voice dashboard response too large")
                        body.extend(chunk)
                result = json.loads(body)
            if not isinstance(result,dict):
                raise ValueError("Invalid voice dashboard")
            service, account_service = result.get("service"), result.get("accountService")
            if (type(result.get("schemaVersion")) is not int or result["schemaVersion"] != 1
                    or not isinstance(service,dict) or service.get("id") != "voice-lab"
                    or service.get("host") != "furby.top" or service.get("readOnly") is not True
                    or not isinstance(account_service,dict) or account_service.get("connected") is not False):
                raise ValueError("Invalid voice dashboard")
        except (httpx.HTTPError,ValueError,TypeError,TimeoutError):
            raise HTTPException(503,"语聊服务运维数据暂时不可用") from None
        with self.database(self.settings) as db:
            self.scope(request,db,"voice")
        return result

    async def voice_incidents(self, request, payload):
        with self.database(self.settings) as db:
            self.scope(request, db, "voice")
        content = json.dumps(payload.model_dump(exclude_none=True), ensure_ascii=False,
                             separators=(",", ":"), sort_keys=True).encode()
        headers = signed_ops_headers(self.settings.ops_bridge_secret, path=VOICE_INCIDENT_QUERY_PATH, body=content)
        headers["Accept-Encoding"] = "identity"
        try:
            async with asyncio.timeout(VOICE_DEADLINE_SECONDS):
                async with self.http.stream("POST", "https://furby.top" + VOICE_INCIDENT_QUERY_PATH,
                                            content=content, headers=headers) as response:
                    if (response.status_code != 200
                            or response.headers.get("content-encoding", "identity").lower() != "identity"):
                        raise ValueError("Voice incident query unavailable")
                    body = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=8192):
                        if len(body) + len(chunk) > MAX_DASHBOARD_BYTES:
                            raise ValueError("Voice incident response too large")
                        body.extend(chunk)
                result = json.loads(body)
            if (not isinstance(result, dict) or type(result.get("schemaVersion")) is not int
                    or result["schemaVersion"] != 1 or type(result.get("retentionDays")) is not int
                    or result["retentionDays"] != 7 or not isinstance(result.get("events"), list)
                    or len(result["events"]) > payload.limit
                    or any(not isinstance(event, dict) for event in result["events"])):
                raise ValueError("Invalid incident query response")
            cursor = result.get("nextCursor")
            if cursor is not None and (not isinstance(cursor, str) or str(uuid.UUID(cursor)) != cursor.lower()):
                raise ValueError("Invalid incident cursor")
        except (httpx.HTTPError, ValueError, TypeError, TimeoutError):
            raise HTTPException(503, "语聊问题记录暂时不可用，请稍后重试") from None
        with self.database(self.settings) as db:
            self.scope(request, db, "voice")
        return result


def build_router(app):
    router = APIRouter(prefix="/admin/v2")

    @router.post("/auth/registration/options")
    def registration_options(_payload: Empty,request:Request):
        return app.state.ops.options(request,"registration")

    @router.post("/auth/authentication/options")
    def authentication_options(_payload: Empty,request:Request):
        return app.state.ops.options(request,"authentication")

    @router.post("/auth/registration/verify")
    def registration_verify(payload:Verification,request:Request):
        return app.state.ops.registration(payload,request)

    @router.post("/auth/authentication/verify")
    def authentication_verify(payload:Verification,request:Request):
        return app.state.ops.authentication(payload,request)

    @router.get("/me")
    def me(request:Request):
        service=app.state.ops
        with service.database(service.settings) as db:
            user=service.authenticate(request,db)
            return {"schemaVersion":1,"account":service.account_json(db,user["account_id"])}

    @router.patch("/me")
    def name(payload:NameUpdate,request:Request):
        service=app.state.ops
        with service.database(service.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            user=service.authenticate(request,db)
            if user["name"] != payload.name:
                db.execute("UPDATE ops_accounts SET name=? WHERE account_id=?",(payload.name,user["account_id"]))
                db.execute("INSERT INTO ops_audit(recorded_at,actor,action,account_id,name) VALUES(?,?,?,?,?)",
                           (int(time.time()),"self","name",user["account_id"],payload.name))
            return {"schemaVersion":1,"account":service.account_json(db,user["account_id"])}

    @router.delete("/auth/session")
    def logout(request:Request):
        service=app.state.ops
        with service.database(service.settings) as db:
            user=service.authenticate(request,db)
            db.execute("DELETE FROM ops_sessions WHERE token_hash=?",(user["token_hash"],))
        return {"revoked":True}

    @router.get("/services/account/dashboard")
    def account_dashboard(request:Request):
        service=app.state.ops
        with service.database(service.settings) as db:
            service.scope(request,db,"account")
            result=app.state.admin.dashboard(db)
            service.scope(request,db,"account")
        return result

    @router.get("/services/voice/dashboard")
    async def voice_dashboard(request:Request):
        return await app.state.ops.voice_dashboard(request)

    @router.post("/services/voice/moderation/query")
    async def moderation_query(payload: ModerationQuery, request: Request):
        return await app.state.ops.voice_moderation(request, payload, "query")

    @router.post("/services/voice/incidents/query")
    async def incident_query(payload: IncidentQuery, request: Request):
        return await app.state.ops.voice_incidents(request, payload)

    @router.post("/services/voice/moderation/action")
    async def moderation_action(payload: ModerationAction, request: Request):
        return await app.state.ops.voice_moderation(request, payload, "action")

    return router


def change_grant(settings,database,*,account_id,name,service,action,actor):
    if action not in {"grant","revoke","delete"} or (action != "delete" and service not in SCOPES):
        raise ValueError("Invalid grant action")
    with database(settings) as db:
        db.execute("BEGIN IMMEDIATE")
        row=db.execute("SELECT * FROM ops_accounts WHERE account_id=?",(account_id,)).fetchone()
        if row is None or row["name"] is None or row["name"] != name or row["disabled_at"] is not None:
            raise ValueError("Exact active operations account ID and current name are required")
        now=int(time.time())
        if action == "grant":
            db.execute("INSERT OR REPLACE INTO ops_grants VALUES(?,?,?)",(account_id,service,now))
        elif action == "revoke":
            db.execute("DELETE FROM ops_grants WHERE account_id=? AND service=?",(account_id,service))
        else:
            db.execute("DELETE FROM ops_accounts WHERE account_id=?",(account_id,))
        db.execute("INSERT INTO ops_audit(recorded_at,actor,action,account_id,name,service) VALUES(?,?,?,?,?,?)",
                   (now,actor,action,account_id,name,service))


def cli():
    parser=argparse.ArgumentParser(description="Local server-only operations access control")
    sub=parser.add_subparsers(dest="action",required=True)
    sub.add_parser("list")
    for action in ("grant","revoke","delete"):
        command=sub.add_parser(action)
        command.add_argument("--account-id",required=True)
        command.add_argument("--name",required=True)
        if action != "delete":
            command.add_argument("--service",choices=SCOPES,required=True)
    args=parser.parse_args()
    from .main import Settings,database
    settings=Settings.from_environment()
    if not Path(settings.db_path).is_file():
        raise SystemExit("Existing service database is required")
    if args.action == "list":
        with database(settings) as db:
            rows=db.execute("SELECT account_id,name,created_at,disabled_at FROM ops_accounts ORDER BY created_at,account_id").fetchall()
            result=[{"id":r["account_id"],"name":r["name"],"createdAt":r["created_at"],"disabled":r["disabled_at"] is not None,
                     "permissions":{service:bool(db.execute("SELECT 1 FROM ops_grants WHERE account_id=? AND service=?",(r["account_id"],service)).fetchone()) for service in SCOPES}} for r in rows]
        print(json.dumps(result,ensure_ascii=False))
    else:
        try:
            change_grant(settings,database,account_id=args.account_id,name=args.name,
                         service=getattr(args,"service",None),action=args.action,actor="local:"+getpass.getuser())
        except ValueError as error:
            raise SystemExit(str(error)) from None
        print(json.dumps({"action":args.action,"accountID":args.account_id,"name":args.name,"service":getattr(args,"service",None),"ok":True},ensure_ascii=False))


if __name__ == "__main__":
    cli()
