"""Confirmed voice-room starts, delivered durably to the account notification service.

The SFU and current signaling authorization must both confirm the owner before
an event is recorded. Retries carry the same opaque event; no device token,
nickname, room title or follower list crosses this bridge.
"""
import asyncio
import hashlib
import hmac
import json
import logging
import secrets
import time
import uuid

import aiohttp
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from .account_bridge import verify_request

LOGGER = logging.getLogger("kiki.livekit.room_started")
ACCOUNT_URL = "https://kiki.group"
EVENT_PATH = "/internal/v1/voice/room-started"
STATUS_PATH = "/internal/v1/account/room-started-status"
TTL = 300
RECEIPT_TTL = 7 * 86400


def initialize_database(db):
    existing = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='room_start_markers'").fetchone()
    db.executescript("""
    CREATE TABLE IF NOT EXISTS room_start_markers(
      room_id TEXT PRIMARY KEY REFERENCES rooms(id) ON DELETE CASCADE,
      started_at_ns INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS room_start_outbox(
      event_id TEXT PRIMARY KEY,room_id TEXT NOT NULL UNIQUE REFERENCES rooms(id) ON DELETE CASCADE,
      host_id TEXT NOT NULL REFERENCES users(id),host_consent_epoch INTEGER NOT NULL,
      started_at_ns INTEGER NOT NULL,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,next_attempt_at INTEGER NOT NULL,
      delivered_at INTEGER,state TEXT NOT NULL DEFAULT 'pending');
    """)
    if not existing:
        # Installing the feature must not announce rooms that were already open.
        # The marker belongs to the existing room metadata, without an account ID.
        db.execute("INSERT OR IGNORE INTO room_start_markers SELECT id,0 FROM rooms")


def erase(db, user_id):
    db.execute("DELETE FROM room_start_outbox WHERE host_id=?", (user_id,))


def purge(db, now=None):
    now = int(time.time()) if now is None else now
    db.execute("UPDATE room_start_outbox SET state='cancelled' WHERE state='pending' AND expires_at<=?", (now,))
    db.execute("DELETE FROM room_start_outbox WHERE created_at<=?", (now-RECEIPT_TTL,))


def signed_headers(secret, body, *, timestamp=None, nonce=None):
    timestamp = str(int(time.time()) if timestamp is None else timestamp)
    nonce = nonce or secrets.token_hex(16)
    message = "\n".join(("voice-account-room-started-v1", "POST", EVENT_PATH, timestamp, nonce,
                          hashlib.sha256(body).hexdigest())).encode()
    return {"Content-Type":"application/json", "Accept-Encoding":"identity",
            "X-Kiki-Timestamp":timestamp,"X-Kiki-Nonce":nonce,
            "X-Kiki-Signature":hmac.new(secret.encode(),message,hashlib.sha256).hexdigest()}


class StatusQuery(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    eventID: str = Field(pattern=r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")
    roomID: str = Field(pattern=r"^lk_[a-f0-9]{32}$")
    hostID: str = Field(pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")
    hostConsentEpoch: int = Field(ge=1, le=9223372036854775807)


class RoomStarted:
    def __init__(self, app, settings, lock, valid_session):
        self.app, self.settings, self.lock, self.valid_session = app, settings, lock, valid_session
        self.clock = time.time
        self.time_ns = time.time_ns
        self.dispatch_lock = asyncio.Lock()

    def observe_locked(self, room, online, connections):
        if self.settings.auth_mode != "account" or room["status"] != "active" or room["owner_id"] not in online:
            return
        db, host = self.app.state.db, room["owner_id"]
        if db.execute("SELECT 1 FROM room_start_markers WHERE room_id=?", (room["id"],)).fetchone():
            return
        member = db.execute("SELECT * FROM room_members WHERE room_id=? AND user_id=? AND active=1", (room["id"],host)).fetchone()
        connection = connections.get((room["id"],host))
        if (member is None or connection is None or connection.revoked.is_set() or not connection.upstream_connected
                or connection.upstream_connected_at is None or member["signal_disconnected"]
                or connection.generation != member["generation"]
                or not hmac.compare_digest(connection.session_hash,member["session_hash"])
                or not self.valid_session(member["session_hash"])):
            return
        epoch = db.execute("""SELECT p.consent_epoch FROM account_authorizations a
            JOIN account_authorization_privacy p ON p.authorization_id=a.authorization_id
            WHERE a.user_id=? AND a.token_hash=?""", (host,member["session_hash"])).fetchone()
        if epoch is None or epoch[0] < 1:
            return
        started_ns = self.time_ns()
        started = started_ns // 1_000_000_000
        with db:
            db.execute("INSERT INTO room_start_markers VALUES(?,?)", (room["id"],started_ns))
            db.execute("""INSERT INTO room_start_outbox(event_id,room_id,host_id,host_consent_epoch,
                started_at_ns,created_at,expires_at,next_attempt_at) VALUES(?,?,?,?,?,?,?,?)""",
                (str(uuid.uuid4()),room["id"],host,epoch[0],started_ns,started,started+TTL,started))

    def active_locked(self, query):
        db = self.app.state.db
        event = db.execute("SELECT * FROM room_start_outbox WHERE event_id=? AND room_id=? AND host_id=? AND host_consent_epoch=?",
                           (query.eventID,query.roomID,query.hostID,query.hostConsentEpoch)).fetchone()
        if event is None:
            return False
        room = db.execute("SELECT * FROM rooms WHERE id=? AND owner_id=? AND status='active'", (query.roomID,query.hostID)).fetchone()
        member = db.execute("SELECT * FROM room_members WHERE room_id=? AND user_id=? AND active=1", (query.roomID,query.hostID)).fetchone()
        if room is None or member is None or not self.valid_session(member["session_hash"]):
            return False
        epoch = db.execute("""SELECT p.consent_epoch FROM account_authorizations a
            JOIN account_authorization_privacy p ON p.authorization_id=a.authorization_id
            WHERE a.user_id=? AND a.token_hash=?""", (query.hostID,member["session_hash"])).fetchone()
        # The established room stays live during the existing short reconnect
        # grace. Its authoritative close/revocation immediately invalidates it.
        return epoch is not None and epoch[0] == query.hostConsentEpoch

    async def post(self, payload):
        body = json.dumps(payload,sort_keys=True,ensure_ascii=False,separators=(",",":")).encode()
        timeout = aiohttp.ClientTimeout(total=3,connect=1)
        async with aiohttp.ClientSession(timeout=timeout,trust_env=False,auto_decompress=False) as session:
            async with session.post(ACCOUNT_URL+EVENT_PATH,data=body,
                    headers=signed_headers(self.settings.account_bridge_secret,body),allow_redirects=False) as response:
                if response.status != 200 or response.headers.get("Content-Encoding","identity").lower() != "identity":
                    raise ValueError("Account notification bridge unavailable")
                data = bytearray()
                while True:
                    chunk = await response.content.read(min(1024,4097-len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data)>4096:
                        raise ValueError("Invalid account notification receipt")
                value = json.loads(data)
                if not isinstance(value,dict) or set(value)!={"ok"} or value["ok"] is not True:
                    raise ValueError("Invalid account notification receipt")

    async def dispatch(self, limit=10):
        if self.settings.auth_mode != "account" or self.dispatch_lock.locked():
            return
        async with self.dispatch_lock:
            for _ in range(limit):
                async with self.lock:
                    db, now = self.app.state.db, int(self.clock())
                    with db:
                        purge(db,now)
                        row = db.execute("SELECT * FROM room_start_outbox WHERE state='pending' AND next_attempt_at<=? AND expires_at>? ORDER BY created_at,event_id LIMIT 1", (now,now)).fetchone()
                        if row is None:
                            return
                        query = StatusQuery(eventID=row["event_id"],roomID=row["room_id"],hostID=row["host_id"],hostConsentEpoch=row["host_consent_epoch"])
                        if not self.active_locked(query):
                            db.execute("UPDATE room_start_outbox SET state='cancelled' WHERE event_id=?", (row["event_id"],))
                            continue
                        payload = {"schemaVersion":1,**query.model_dump(),"startedAt":row["started_at_ns"]//1_000_000_000,
                                   "startedAtNs":row["started_at_ns"]}
                        attempts = row["attempts"]+1
                        db.execute("UPDATE room_start_outbox SET attempts=?,next_attempt_at=? WHERE event_id=?",
                                   (attempts,now+min(60,5*2**min(attempts-1,4)),row["event_id"]))
                try:
                    # Never hold the voice transaction/lock while the account
                    # receiver calls the signed active-room status endpoint.
                    await self.post(payload)
                except Exception as error:
                    LOGGER.warning("Room notification awaits retry: %s",type(error).__name__)
                    continue
                async with self.lock:
                    with self.app.state.db:
                        self.app.state.db.execute("UPDATE room_start_outbox SET state='delivered',delivered_at=? WHERE event_id=? AND state='pending'",
                                                  (int(self.clock()),row["event_id"]))

    async def maintain(self):
        while True:
            await asyncio.sleep(2)
            try:
                await self.dispatch()
            except Exception as error:
                LOGGER.warning("Room notification maintenance pending: %s",type(error).__name__)


def build_router(app, settings, lock):
    router = APIRouter()

    @router.post(STATUS_PATH)
    async def status(query: StatusQuery, request: Request):
        if request.url.query:
            raise HTTPException(404,"接口不存在")
        async with lock:
            verify_request(settings,app.state.db,request,await request.body())
            return {"schemaVersion":1,**query.model_dump(),"active":app.state.room_started.active_locked(query)}

    return router
