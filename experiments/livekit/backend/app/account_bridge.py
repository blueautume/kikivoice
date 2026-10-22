"""Signed account-service requests; independent of media and administrator keys."""
import base64
import hashlib
import hmac
import re
import secrets
import time
from typing import Literal

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

LEASE_SECONDS = 15 * 60
TOMBSTONE_SECONDS = 32 * 86400


def validate_settings(settings):
    if settings.auth_mode not in {"lab", "account"}:
        raise RuntimeError("VOICE_AUTH_MODE must be explicitly lab or account")
    if settings.auth_mode == "account":
        if len(settings.account_bridge_secret) < 43 or len(set(settings.account_bridge_secret)) < 16:
            raise RuntimeError("Configure an independent high-entropy account bridge secret")
        if settings.account_bridge_secret in {settings.api_secret, settings.access_code, settings.api_key}:
            raise RuntimeError("Account bridge credentials must be independent of media credentials")


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS account_bridge_nonces(nonce TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS account_authorizations(
      authorization_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
      token_hash TEXT NOT NULL REFERENCES sessions(token_hash));
    CREATE TABLE IF NOT EXISTS account_revocations(authorization_id TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS account_deletions(subject_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS account_privacy_state(
      user_id TEXT PRIMARY KEY REFERENCES users(id),consent_epoch INTEGER NOT NULL DEFAULT 0,
      withdrawal_epoch INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS account_authorization_privacy(
      authorization_id TEXT PRIMARY KEY REFERENCES account_authorizations(authorization_id),
      consent_epoch INTEGER NOT NULL DEFAULT 0);
    """)
    columns = {row["name"] for row in db.execute("PRAGMA table_info(users)")}
    if "avatar_url" not in columns:
        db.execute("ALTER TABLE users ADD COLUMN avatar_url TEXT")
    if "needs_nickname" not in columns:
        db.execute("ALTER TABLE users ADD COLUMN needs_nickname INTEGER NOT NULL DEFAULT 0")


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Profile(Model):
    id: str = Field(pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")
    sdkUserID: str = Field(max_length=80)
    name: str = Field(min_length=1, max_length=16)
    bio: str = Field(max_length=80)
    avatarIndex: int = Field(strict=True, ge=0, le=11)
    avatarURL: str | None = Field(default=None, max_length=160)
    needsNickname: bool = Field(strict=True)
    notificationsEnabled: bool = Field(strict=True)

    @field_validator("name", "bio")
    @classmethod
    def text(cls, value, info):
        if any((ord(char) < 32 and not (info.field_name == "bio" and char == "\n")) or ord(char) == 127 for char in value):
            raise ValueError("Invalid profile")
        return value

    @field_validator("avatarURL")
    @classmethod
    def avatar(cls, value):
        if value is not None and not re.fullmatch(r"https://kiki\.group/v1/avatars/[a-f0-9]{64}\.jpg", value):
            raise ValueError("Only account-service avatar URLs are accepted")
        return value


class Exchange(Model):
    authorizationID: str = Field(pattern=r"^[a-f0-9]{64}$")
    sourceExpiresAt: int = Field(strict=True)
    user: Profile
    legalConsent: dict[str, str]
    consentEpoch: int | None = Field(default=None, strict=True, ge=1, le=9223372036854775807)
    lastWithdrawalEpoch: int | None = Field(default=None, strict=True, ge=0, le=9223372036854775807)


class Revocation(Model):
    authorizationID: str = Field(pattern=r"^[a-f0-9]{64}$")
    reason: Literal["logout", "withdrawal"] = "logout"
    consentEpoch: int | None = Field(default=None, strict=True, ge=1, le=9223372036854775807)
    accountID: str | None = Field(default=None, pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")


class Deletion(Model):
    accountID: str = Field(pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")


def verify_request(settings, db, request, body):
    if settings.auth_mode != "account":
        raise HTTPException(404, "接口不存在")
    timestamp = request.headers.get("x-kiki-timestamp", "")
    nonce = request.headers.get("x-kiki-nonce", "")
    signature = request.headers.get("x-kiki-signature", "")
    now = int(time.time())
    if (not re.fullmatch(r"[0-9]{10,12}", timestamp) or abs(now - int(timestamp)) > 30
            or not re.fullmatch(r"[a-f0-9]{32}", nonce) or not re.fullmatch(r"[a-f0-9]{64}", signature)):
        raise HTTPException(401, "无效的服务授权")
    message = "\n".join(("account-voice-v1", "POST", request.url.path, timestamp, nonce,
                         hashlib.sha256(body).hexdigest())).encode()
    expected = hmac.new(settings.account_bridge_secret.encode(), message, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(401, "无效的服务授权")
    with db:
        db.execute("DELETE FROM account_bridge_nonces WHERE expires_at<=?", (now,))
        db.execute("DELETE FROM account_revocations WHERE expires_at<=?", (now,))
        db.execute("DELETE FROM account_deletions WHERE expires_at<=?", (now,))
        if db.execute("SELECT 1 FROM account_bridge_nonces WHERE nonce=?", (nonce,)).fetchone():
            raise HTTPException(401, "服务请求已使用")
        db.execute("INSERT INTO account_bridge_nonces VALUES(?,?)", (nonce, now + 61))


def session_token(secret, authorization_id):
    digest = hmac.new(secret.encode(), ("voice-session-v1:" + authorization_id).encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def build_router(app, settings, lock, user_json, sdk_json, revoke):
    router = APIRouter()

    async def verified(request):
        verify_request(settings, app.state.db, request, await request.body())

    @router.post("/internal/v1/account/session")
    async def exchange(payload: Exchange, request: Request):
        async with lock:
            await verified(request)
            now, db = int(time.time()), app.state.db
            if payload.legalConsent != app.state.legal:
                raise HTTPException(428, "请先同意当前协议")
            profile = payload.user
            if profile.sdkUserID != profile.id or not now < payload.sourceExpiresAt <= now + 31 * 86400:
                raise HTTPException(401, "无效的账号授权")
            privacy = db.execute("SELECT * FROM account_privacy_state WHERE user_id=?",(profile.id,)).fetchone()
            social = db.execute("SELECT * FROM account_social_privacy WHERE user_id=?",(profile.id,)).fetchone()
            incident = db.execute("SELECT withdrawal_epoch FROM room_incident_privacy WHERE user_id=?",(profile.id,)).fetchone()
            current_epoch = max(privacy["consent_epoch"] if privacy else 0,social["consent_epoch"] if social else 0)
            withdrawal_epoch = max(privacy["withdrawal_epoch"] if privacy else 0,
                                   social["withdrawal_epoch"] if social else 0,incident[0] if incident else 0)
            if (payload.lastWithdrawalEpoch is not None and (payload.consentEpoch is None
                    or payload.lastWithdrawalEpoch >= payload.consentEpoch)):
                raise HTTPException(422,"同意记录版本不正确")
            if (payload.consentEpoch is None and (current_epoch>0 or withdrawal_epoch>0)
                    or payload.consentEpoch is not None and (payload.consentEpoch<current_epoch
                        or payload.consentEpoch<=withdrawal_epoch)):
                raise HTTPException(409,"同意记录已更新，请重新获取账号授权")
            subject_hash = hashlib.sha256(profile.id.encode()).hexdigest()
            if (db.execute("SELECT 1 FROM account_revocations WHERE authorization_id=?", (payload.authorizationID,)).fetchone()
                    or db.execute("SELECT 1 FROM account_deletions WHERE subject_hash=?", (subject_hash,)).fetchone()):
                raise HTTPException(401, "账号授权已撤回")
            token = session_token(settings.account_bridge_secret, payload.authorizationID)
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            existing = db.execute("SELECT * FROM account_authorizations WHERE authorization_id=?", (payload.authorizationID,)).fetchone()
            if existing and (existing["user_id"] != profile.id or existing["token_hash"] != token_hash):
                raise HTTPException(409, "账号授权不能变更用户")
            old_session = db.execute("SELECT revoked_at FROM sessions WHERE token_hash=?", (token_hash,)).fetchone()
            if old_session and old_session["revoked_at"] is not None:
                raise HTTPException(401, "账号授权已退出")
            if payload.lastWithdrawalEpoch and (not privacy or payload.lastWithdrawalEpoch>privacy["withdrawal_epoch"]):
                # Re-consent can beat the queued withdrawal delivery. Remove old
                # personal data before accepting a new epoch, so a delayed event
                # never erases newly-created blocks, reports or activity.
                previous = db.execute("""SELECT a.user_id,a.token_hash FROM account_authorizations a
                    LEFT JOIN account_authorization_privacy p ON p.authorization_id=a.authorization_id
                    WHERE a.user_id=? AND COALESCE(p.consent_epoch,0)<=?""",(profile.id,payload.lastWithdrawalEpoch)).fetchall()
                await revoke(previous,deleted=False,withdrawn=True,withdrawal_epoch=payload.lastWithdrawalEpoch)
                from .social_policy import clear_account
                with db:
                    clear_account(app,profile.id,withdrawal_epoch=payload.lastWithdrawalEpoch)
            expires = min(payload.sourceExpiresAt, now + LEASE_SECONDS)
            with db:
                db.execute("""INSERT INTO users(id,name,bio,avatar_index,notifications,created_at,avatar_url,needs_nickname)
                    VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,bio=excluded.bio,
                    avatar_index=excluded.avatar_index,notifications=excluded.notifications,
                    avatar_url=excluded.avatar_url,needs_nickname=excluded.needs_nickname""",
                    (profile.id, profile.name, profile.bio, profile.avatarIndex, profile.notificationsEnabled, now,
                     profile.avatarURL, profile.needsNickname))
                db.execute("INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?) ON CONFLICT(token_hash) DO UPDATE SET expires_at=excluded.expires_at",
                           (token_hash, profile.id, expires))
                db.execute("INSERT OR IGNORE INTO account_authorizations VALUES(?,?,?)", (payload.authorizationID, profile.id, token_hash))
                db.execute("""INSERT INTO account_authorization_privacy VALUES(?,?)
                    ON CONFLICT(authorization_id) DO UPDATE SET consent_epoch=MAX(consent_epoch,excluded.consent_epoch)""",(payload.authorizationID,payload.consentEpoch or 0))
                db.execute("""INSERT INTO account_privacy_state(user_id,consent_epoch,withdrawal_epoch) VALUES(?,?,?)
                    ON CONFLICT(user_id) DO UPDATE SET consent_epoch=MAX(consent_epoch,excluded.consent_epoch),
                    withdrawal_epoch=MAX(withdrawal_epoch,excluded.withdrawal_epoch)""",(profile.id,payload.consentEpoch or 0,payload.lastWithdrawalEpoch or 0))
                db.execute("INSERT OR REPLACE INTO consents VALUES(?,?,?,?,?,NULL)", (profile.id,
                    app.state.legal["privacyVersion"], app.state.legal["termsVersion"], app.state.legal["documentHash"], now))
                user = db.execute("SELECT * FROM users WHERE id=?", (profile.id,)).fetchone()
            return {"token": token, "expiresAt": expires, "user": user_json(user), "sdk": sdk_json(user, {"expires_at": expires})}

    @router.post("/internal/v1/account/revoke")
    async def revoke_authorization(payload: Revocation, request: Request):
        async with lock:
            await verified(request)
            now, db = int(time.time()), app.state.db
            with db:
                db.execute("INSERT OR REPLACE INTO account_revocations VALUES(?,?)", (payload.authorizationID, now + TOMBSTONE_SECONDS))
            rows = db.execute("SELECT user_id,token_hash FROM account_authorizations WHERE authorization_id=?", (payload.authorizationID,)).fetchall()
            if payload.reason == "withdrawal" and payload.consentEpoch is not None and rows:
                rows = db.execute("""SELECT a.user_id,a.token_hash FROM account_authorizations a
                    LEFT JOIN account_authorization_privacy p ON p.authorization_id=a.authorization_id
                    WHERE a.user_id=? AND COALESCE(p.consent_epoch,0)<=?""",(rows[0]["user_id"],payload.consentEpoch)).fetchall()
            await revoke(rows, deleted=False, withdrawn=payload.reason == "withdrawal",withdrawal_epoch=payload.consentEpoch)
            if payload.reason=="withdrawal" and payload.accountID and payload.consentEpoch is not None:
                with db:
                    app.state.incidents.clear_user(payload.accountID,withdrawal_epoch=payload.consentEpoch)
                    from .social_policy import clear_account
                    clear_account(app,payload.accountID,withdrawal_epoch=payload.consentEpoch)
            return {"ok": True}

    @router.post("/internal/v1/account/delete")
    async def delete_account(payload: Deletion, request: Request):
        async with lock:
            await verified(request)
            now, db = int(time.time()), app.state.db
            with db:
                db.execute("INSERT OR REPLACE INTO account_deletions VALUES(?,?)", (hashlib.sha256(payload.accountID.encode()).hexdigest(), now + TOMBSTONE_SECONDS))
            rows = db.execute("SELECT user_id,token_hash FROM account_authorizations WHERE user_id=?", (payload.accountID,)).fetchall()
            await revoke(rows, deleted=True)
            with db:
                # Deletion can arrive after every voice lease expired. Erase
                # experience state even when there are no sessions to revoke.
                app.state.experience.clear_user(payload.accountID, deleted=True)
                app.state.incidents.clear_user(payload.accountID)
                from .social_policy import clear_account
                clear_account(app,payload.accountID)
            return {"ok": True}

    return router
