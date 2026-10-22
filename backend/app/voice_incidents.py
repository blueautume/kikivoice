"""Bounded, consent-aware account → voice incident delivery.

Only allowlisted technical fields enter this journal. Tokens, request bodies,
URLs and arbitrary exception text never enter an incident or its retry state.
"""
import hashlib
import json
import re
import threading
import time
import uuid
from typing import Literal

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator

RETENTION_SECONDS = 7 * 86400
HOURLY_LIMIT = 60
DAILY_LIMIT = 300
PENDING_LIMIT = 1000
MAX_TOTAL_ROWS = 20000
PATH = "/internal/v1/account/incident"
UUID_PATTERN = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SCHEMA = """
CREATE TABLE IF NOT EXISTS voice_incident_outbox (
  event_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  source TEXT NOT NULL CHECK(source IN ('client','account')),
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  delivered_at INTEGER,
  payload_hash TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS voice_incident_expiry ON voice_incident_outbox(expires_at);
CREATE INDEX IF NOT EXISTS voice_incident_delivery ON voice_incident_outbox(delivered_at,next_attempt_at);
CREATE INDEX IF NOT EXISTS voice_incident_account ON voice_incident_outbox(account_id,created_at);
"""


def canonical_uuid(value):
    if not isinstance(value, str) or not UUID_PATTERN.fullmatch(value):
        raise ValueError("Expected a standard UUID")
    return str(uuid.UUID(value))


class Incident(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    eventID: str
    attemptID: str
    operation: Literal["create_room", "join_room", "room_runtime"]
    stage: Literal["account_authorization", "room_api", "token_api", "media_connect", "state_sync", "media_runtime", "reconnect",
                   "safety_sync", "chat_sync", "audio_policy", "room_action", "room_leave"]
    severity: Literal["warning", "error"]
    code: Literal[
        "request_timeout", "network_unavailable", "network_connection_lost", "network_tls_failed", "network_error",
        "http_unauthorized", "http_forbidden", "http_not_found", "http_conflict", "http_rate_limited",
        "http_server_error", "http_invalid_response", "consent_required", "capacity_reached", "room_ended",
        "voice_banned", "chat_muted", "voice_muted", "content_filtered", "media_connect_timeout",
        "media_connect_failed", "media_disconnected", "reconnect_failed", "state_sync_failed",
        "audio_publish_failed", "audio_permission_denied", "quality_poor", "quality_lost", "unknown_error"]
    occurredAt: int
    elapsedMs: int | None = Field(default=None, ge=0, le=3600000)
    roomID: str | None = Field(default=None, pattern=r"^lk_[a-f0-9]{32}$")
    requestID: str | None = None
    httpStatus: int | None = Field(default=None, ge=400, le=599)
    platform: Literal["ios", "ipados", "server"]
    appVersion: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9 .()_-]+$")
    osVersion: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9 .()_-]+$")

    @field_validator("eventID", "attemptID", "requestID", mode="before")
    @classmethod
    def identifiers(cls, value):
        return None if value is None else canonical_uuid(value)

    @field_validator("occurredAt")
    @classmethod
    def occurrence(cls, value):
        now = int(time.time())
        if not now - RETENTION_SECONDS < value <= now + 300:
            raise ValueError("Incident timestamp outside retention")
        return value


def initialize_database(db):
    db.executescript(SCHEMA)
    if "payload_hash" not in {row["name"] for row in db.execute("PRAGMA table_info(voice_incident_outbox)")}:
        db.execute("ALTER TABLE voice_incident_outbox ADD COLUMN payload_hash TEXT NOT NULL DEFAULT ''")
    # Pending legacy envelopes can recover a canonical hash without storing any
    # additional metadata. Delivered legacy receipts intentionally cannot: their
    # payload was already erased, so reusing them is rejected rather than silently
    # accepting changed content under an unverifiable UUID.
    for row in db.execute("SELECT event_id,source,payload FROM voice_incident_outbox WHERE payload_hash='' AND payload!='{}'").fetchall():
        try:
            payload=json.loads(row["payload"])
            value=Incident.model_construct(**payload["event"])
            digest=event_hash(value,row["source"])
        except (ValueError,TypeError,KeyError):
            continue
        db.execute("UPDATE voice_incident_outbox SET payload_hash=? WHERE event_id=?",(digest,row["event_id"]))


def event_hash(event,source):
    canonical=json.dumps(event.model_dump(mode="json"),ensure_ascii=False,sort_keys=True,separators=(",",":"))
    return hashlib.sha256((source+":"+canonical).encode()).hexdigest()


def purge(db, now=None):
    db.execute("DELETE FROM voice_incident_outbox WHERE expires_at<=?", (int(time.time()) if now is None else now,))


class IncidentOutbox:
    def __init__(self, settings, database, bridge):
        self.settings, self.database, self.bridge = settings, database, bridge
        self.lock = threading.Lock()

    def enqueue(self, db, user, event, *, consent_epoch, last_withdrawal_epoch, source="client"):
        now = int(time.time())
        purge(db, now)
        digest=event_hash(event,source)
        prior = db.execute("SELECT account_id,delivered_at,payload_hash FROM voice_incident_outbox WHERE event_id=?",
                           (event.eventID,)).fetchone()
        if prior is not None:
            if prior["account_id"] != user["account_id"]:
                raise HTTPException(409, "事件编号已使用")
            if prior["payload_hash"] != digest:
                raise HTTPException(409,"问题事件编号不能复用")
            return prior["delivered_at"] is None
        # Persistent limits apply across API workers, restarts and all devices.
        counts = db.execute("""SELECT SUM(created_at>?),SUM(created_at>?),SUM(delivered_at IS NULL)
            FROM voice_incident_outbox WHERE account_id=? AND source=?""",
            (now - 3600, now - 86400, user["account_id"], source)).fetchone()
        if ((counts[0] or 0) >= HOURLY_LIMIT or (counts[1] or 0) >= DAILY_LIMIT
                or (counts[2] or 0) >= PENDING_LIMIT):
            raise HTTPException(429, "问题记录已达到频率上限，请稍后重试", headers={"Retry-After": "3600"})
        if db.execute("SELECT COUNT(*) FROM voice_incident_outbox").fetchone()[0] >= MAX_TOTAL_ROWS:
            raise HTTPException(503, "问题记录暂时繁忙，请稍后重试")
        payload = {"accountID": user["login_id"], "name": user["name"], "consentEpoch": consent_epoch,
                   "lastWithdrawalEpoch": last_withdrawal_epoch, "source": source,
                   "event": event.model_dump(mode="json", exclude_none=True)}
        db.execute("""INSERT INTO voice_incident_outbox
            (event_id,account_id,source,payload,created_at,expires_at,payload_hash) VALUES(?,?,?,?,?,?,?)""",
            (event.eventID, user["account_id"], source,
             json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")), now,
             min(now, event.occurredAt) + RETENTION_SECONDS,digest))
        return True

    def retry(self, batch_limit=10):
        if not self.settings.voice_bridge_enabled or not self.lock.acquire(blocking=False):
            return
        try:
            now = int(time.time())
            with self.database(self.settings) as db:
                purge(db, now)
                rows = db.execute("""SELECT * FROM voice_incident_outbox WHERE delivered_at IS NULL
                    AND next_attempt_at<=? ORDER BY created_at,event_id LIMIT ?""", (now, batch_limit)).fetchall()
            for row in rows:
                payload = json.loads(row["payload"])
                # Never hold SQLite's write lock across network I/O. Remote
                # withdrawal watermarks reject an in-flight old-epoch event.
                with self.database(self.settings) as db:
                    db.execute("BEGIN IMMEDIATE")
                    if not db.execute("SELECT 1 FROM voice_incident_outbox WHERE event_id=? AND delivered_at IS NULL",
                                      (row["event_id"],)).fetchone():
                        continue
                    latest = db.execute("""SELECT event_id,accepted,adult_confirmed FROM legal_consent_events
                        WHERE account_id=? ORDER BY event_id DESC LIMIT 1""", (row["account_id"],)).fetchone()
                    if (latest is None or not latest["accepted"] or not latest["adult_confirmed"]
                            or latest["event_id"] != payload["consentEpoch"]):
                        db.execute("DELETE FROM voice_incident_outbox WHERE event_id=?", (row["event_id"],))
                        continue
                try:
                    self.bridge.post(PATH, payload)
                except Exception:
                    with self.database(self.settings) as db:
                        attempts = row["attempts"] + 1
                        db.execute("UPDATE voice_incident_outbox SET attempts=?,next_attempt_at=? WHERE event_id=?",
                                   (attempts, now + min(300, 5 * 2 ** min(attempts, 6)), row["event_id"]))
                else:
                    with self.database(self.settings) as db:
                        # Retain only the opaque dedupe receipt after delivery.
                        db.execute("UPDATE voice_incident_outbox SET delivered_at=?,payload='{}' WHERE event_id=?",
                                   (now, row["event_id"]))
        finally:
            self.lock.release()
