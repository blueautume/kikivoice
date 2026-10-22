"""Server-only account → voice authorization; credentials never reach the iOS app."""
import hashlib
import hmac
import json
import logging
import secrets
import threading
import time

import httpx
from fastapi import HTTPException

LOGGER = logging.getLogger("kikitalk.voice_bridge")
VOICE_BASE_URL = "https://furby.top"
SCHEMA = """
CREATE TABLE IF NOT EXISTS voice_revocation_outbox (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL, subject TEXT NOT NULL,
  created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  reason TEXT NOT NULL DEFAULT 'logout',
  consent_epoch INTEGER,
  account_public_id TEXT,
  UNIQUE(kind,subject)
);
CREATE TRIGGER IF NOT EXISTS voice_session_deleted AFTER DELETE ON sessions BEGIN
  INSERT OR IGNORE INTO voice_revocation_outbox(kind,subject,created_at)
  VALUES('revoke',OLD.token_hash,unixepoch());
END;
"""


def initialize_database(db):
    db.executescript(SCHEMA)
    columns = {row["name"] for row in db.execute("PRAGMA table_info(voice_revocation_outbox)")}
    if "reason" not in columns:
        db.execute("ALTER TABLE voice_revocation_outbox ADD COLUMN reason TEXT NOT NULL DEFAULT 'logout'")
    if "consent_epoch" not in columns:
        db.execute("ALTER TABLE voice_revocation_outbox ADD COLUMN consent_epoch INTEGER")
    if "account_public_id" not in columns:
        db.execute("ALTER TABLE voice_revocation_outbox ADD COLUMN account_public_id TEXT")


def authorization_id(secret, source_hash):
    return hmac.new(secret.encode(), ("voice-authorization-v1:" + source_hash).encode(), hashlib.sha256).hexdigest()


def signed_headers(secret, path, body, *, timestamp=None, nonce=None):
    timestamp = str(int(time.time()) if timestamp is None else timestamp)
    nonce = nonce or secrets.token_hex(16)
    message = "\n".join(("account-voice-v1", "POST", path, timestamp, nonce,
                         hashlib.sha256(body).hexdigest())).encode()
    return {"Content-Type": "application/json", "X-Kiki-Timestamp": timestamp,
            "X-Kiki-Nonce": nonce, "X-Kiki-Signature": hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()}


def validate_settings(settings):
    if settings.voice_bridge_enabled:
        if settings.qa_gifts_enabled:
            raise RuntimeError("Isolated QA identities cannot authorize the production voice service")
        if (settings.voice_base_url != VOICE_BASE_URL or len(settings.voice_bridge_secret) < 43
                or len(set(settings.voice_bridge_secret)) < 16):
            raise RuntimeError("Configure the fixed HTTPS voice endpoint and an independent high-entropy bridge secret")
        if settings.voice_bridge_secret in {settings.secret_key, settings.qa_gifts_token,
                                           settings.apple_token_encryption_key}:
            raise RuntimeError("Voice bridge credentials must be independent")


class VoiceBridge:
    def __init__(self, settings, database):
        self.settings, self.database = settings, database
        self.lock = threading.Lock()
        self.http = httpx.Client(timeout=httpx.Timeout(2.5, connect=1.0), follow_redirects=False, trust_env=False)

    def close(self):
        self.http.close()

    def post(self, path, payload):
        body = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        try:
            response = self.http.post(self.settings.voice_base_url + path, content=body,
                headers=signed_headers(self.settings.voice_bridge_secret, path, body))
            if response.status_code in (401, 409, 428):
                raise HTTPException(response.status_code, "语聊授权已失效，请重新登录或确认协议")
            accepted = (200, 202) if path == "/internal/v1/account/incident" else (200,)
            if response.status_code not in accepted:
                raise ValueError("Voice service unavailable")
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError("Invalid voice response")
            return result
        except HTTPException:
            raise
        except (httpx.HTTPError, ValueError, TypeError) as error:
            LOGGER.warning("Voice bridge request pending: %s", type(error).__name__)
            raise HTTPException(503, "语聊服务暂时不可用，请稍后重试") from error

    def exchange(self, user, session, legal, profile, consent_epoch=None, last_withdrawal_epoch=0):
        return self.post("/internal/v1/account/session", {
            "authorizationID": authorization_id(self.settings.voice_bridge_secret, user["token_hash"]),
            "sourceExpiresAt": session["expires_at"], "user": {**profile, "sdkUserID": profile["id"]},
            "legalConsent": legal, "consentEpoch": consent_epoch, "lastWithdrawalEpoch": last_withdrawal_epoch})

    def queue_account_delete(self, db, public_id):
        if self.settings.voice_bridge_enabled:
            db.execute("INSERT OR IGNORE INTO voice_revocation_outbox(kind,subject,created_at) VALUES('delete',?,?)",
                       (public_id, int(time.time())))

    def queue_authorization_withdrawal(self, db, account_id, consent_epoch=None, account_public_id=None):
        if self.settings.voice_bridge_enabled:
            # Upgrade privacy intent before deletion. The existing UNIQUE key
            # makes its trigger an idempotent no-op, not a duplicate logout.
            db.execute("""INSERT INTO voice_revocation_outbox(kind,subject,created_at,reason,consent_epoch,account_public_id)
                SELECT 'revoke',token_hash,?,'withdrawal',?,? FROM sessions WHERE account_id=?
                ON CONFLICT(kind,subject) DO UPDATE SET reason='withdrawal',next_attempt_at=0,
                account_public_id=COALESCE(excluded.account_public_id,account_public_id),
                consent_epoch=CASE WHEN excluded.consent_epoch IS NULL THEN consent_epoch
                ELSE MAX(COALESCE(consent_epoch,0),excluded.consent_epoch) END""",
                (int(time.time()), consent_epoch, account_public_id, account_id))

    def retry_revocations(self, batch_limit=10):
        if not self.settings.voice_bridge_enabled or not self.lock.acquire(blocking=False):
            return
        try:
            now = int(time.time())
            with self.database(self.settings) as db:
                rows = db.execute("SELECT * FROM voice_revocation_outbox WHERE next_attempt_at<=? ORDER BY event_id LIMIT ?",
                                  (now, batch_limit)).fetchall()
            for row in rows:
                is_revoke = row["kind"] == "revoke"
                payload = ({"authorizationID": authorization_id(self.settings.voice_bridge_secret, row["subject"])}
                           if is_revoke else {"accountID": row["subject"]})
                if is_revoke and row["reason"] == "withdrawal":
                    payload["reason"] = "withdrawal"
                    if row["consent_epoch"] is not None:
                        payload["consentEpoch"] = row["consent_epoch"]
                    if row["account_public_id"] is not None:
                        payload["accountID"] = row["account_public_id"]
                path = "/internal/v1/account/" + ("revoke" if is_revoke else "delete")
                try:
                    self.post(path, payload)
                except Exception as error:
                    LOGGER.warning("Voice revocation queued: %s", type(error).__name__)
                    with self.database(self.settings) as db:
                        attempts = row["attempts"] + 1
                        db.execute("UPDATE voice_revocation_outbox SET attempts=?,next_attempt_at=? WHERE event_id=?",
                            (attempts, now + min(300, 5 * 2 ** min(attempts, 6)), row["event_id"]))
                    continue
                with self.database(self.settings) as db:
                    db.execute("DELETE FROM voice_revocation_outbox WHERE event_id=?", (row["event_id"],))
        finally:
            self.lock.release()
