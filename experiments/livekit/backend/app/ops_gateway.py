"""Central operations bridge; account service owns identity and per-request ACL.

The account service authorizes each operation before signing a fixed endpoint.
Community writes retain only its opaque operator ID in the bounded action audit.
This key and nonce namespace are independent of business-account/media bridges.
"""
import hashlib
import hmac
import re
import sqlite3
import time

from fastapi import APIRouter, HTTPException, Request

DASHBOARD_PATH = "/internal/admin/v2/dashboard"
MODERATION_QUERY_PATH = "/internal/admin/v2/moderation/query"
MODERATION_ACTION_PATH = "/internal/admin/v2/moderation/action"
INCIDENT_QUERY_PATH = "/internal/admin/v2/incidents/query"
ALLOWED_PATHS = {DASHBOARD_PATH, MODERATION_QUERY_PATH, MODERATION_ACTION_PATH, INCIDENT_QUERY_PATH}
SIGNING_DOMAIN = "account-voice-ops-v2"
CLOCK_TOLERANCE_SECONDS = 30
NONCE_RETENTION_SECONDS = 61
MAX_ACTIVE_NONCES = 4096


def validate_settings(settings):
    if settings.admin_auth_mode not in {"legacy", "passkey"}:
        raise RuntimeError("ADMIN_AUTH_MODE must be explicitly legacy or passkey")
    if settings.admin_auth_mode == "passkey":
        secret = settings.ops_bridge_secret
        if (not 43 <= len(secret) <= 256 or len(set(secret)) < 16
                or secret in {settings.account_bridge_secret, settings.api_secret,
                              settings.api_key, settings.access_code}):
            raise RuntimeError("Configure an independent high-entropy operations bridge secret")
        # The management passphrase must not double as an internal bridge key.
        if settings.admin_passphrase_hash:
            from .admin import verify_passphrase
            if verify_passphrase(secret, settings.admin_passphrase_hash):
                raise RuntimeError("Operations bridge credentials must differ from management credentials")


def initialize_database(db):
    db.execute("CREATE TABLE IF NOT EXISTS ops_bridge_nonces(nonce TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)")
    db.execute("CREATE INDEX IF NOT EXISTS ops_bridge_nonce_expiry ON ops_bridge_nonces(expires_at)")


def verify_request(settings, db, request, body, *, now=None, path=DASHBOARD_PATH):
    if settings.admin_auth_mode != "passkey":
        raise HTTPException(404, "接口不存在")
    # Fixed paths only. A dashboard remains the exact empty aggregate request;
    # community bodies have separate strict schemas with an injected audit ID.
    # Client Bearers and client-supplied ACL claims are never authorization here.
    if (path not in ALLOWED_PATHS or request.method != "POST" or request.url.path != path or request.url.query
            or request.scope.get("raw_path", path.encode("ascii")) != path.encode("ascii")
            or (path == DASHBOARD_PATH and body != b"{}") or "authorization" in request.headers
            or request.headers.getlist("content-type") != ["application/json"]):
        raise HTTPException(401, "无效的运维服务授权")
    values = []
    for name in ("x-kiki-ops-timestamp", "x-kiki-ops-nonce", "x-kiki-ops-signature"):
        supplied = request.headers.getlist(name)
        if len(supplied) != 1:
            raise HTTPException(401, "无效的运维服务授权")
        values.append(supplied[0])
    timestamp, nonce, signature = values
    at = int(time.time()) if now is None else int(now)
    if (not re.fullmatch(r"[0-9]{10,12}", timestamp) or abs(at - int(timestamp)) > CLOCK_TOLERANCE_SECONDS
            or not re.fullmatch(r"[a-f0-9]{32}", nonce) or not re.fullmatch(r"[a-f0-9]{64}", signature)):
        raise HTTPException(401, "无效的运维服务授权")
    canonical = "\n".join((SIGNING_DOMAIN, "POST", path, timestamp, nonce,
                           hashlib.sha256(body).hexdigest())).encode("ascii")
    expected = hmac.new(settings.ops_bridge_secret.encode(), canonical, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(401, "无效的运维服务授权")
    with db:
        db.execute("DELETE FROM ops_bridge_nonces WHERE expires_at<=?", (at,))
        if db.execute("SELECT 1 FROM ops_bridge_nonces WHERE nonce=?", (nonce,)).fetchone():
            raise HTTPException(401, "运维服务请求已使用")
        if db.execute("SELECT COUNT(*) FROM ops_bridge_nonces").fetchone()[0] >= MAX_ACTIVE_NONCES:
            raise HTTPException(429, "运维服务请求过于频繁", headers={"Retry-After":"60"})
        try:
            db.execute("INSERT INTO ops_bridge_nonces VALUES(?,?)", (nonce, at + NONCE_RETENTION_SECONDS))
        except sqlite3.IntegrityError:
            raise HTTPException(401, "运维服务请求已使用") from None


def build_router(app, settings, lock):
    router = APIRouter()

    @router.post(DASHBOARD_PATH)
    async def dashboard(request: Request):
        async with lock:
            verify_request(settings, app.state.db, request, await request.body())
            return app.state.admin.dashboard()

    from .incidents import IncidentQuery

    @router.post(INCIDENT_QUERY_PATH)
    async def incidents(payload:IncidentQuery,request:Request):
        async with lock:
            verify_request(settings,app.state.db,request,await request.body(),path=INCIDENT_QUERY_PATH)
            with app.state.db:
                return app.state.incidents.query(payload)

    return router
