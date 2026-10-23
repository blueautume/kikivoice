"""Voice-authoritative room starts, with bounded signed delivery and receipts.

The account service owns followers and APNs bindings. Voice sends no audience,
profile, room title or alert text. Remote checks never hold a SQLite transaction.
"""
import hashlib
import hmac
import json
import re
import time
import uuid

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from starlette.concurrency import run_in_threadpool

PATH = "/internal/v1/voice/room-started"
STATUS_PATH = "/internal/v1/account/room-started-status"
DOMAIN = "voice-account-room-started-v1"
TTL = 300
RECEIPT_TTL = 7 * 86400
TEXT = "开始语聊了，点击进入房间"
SCHEMA = """
CREATE TABLE IF NOT EXISTS voice_room_started_nonces(
 nonce TEXT PRIMARY KEY,expires_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS social_room_started_events(
 event_id TEXT PRIMARY KEY,payload_hash TEXT NOT NULL,
 room_id TEXT NOT NULL,host_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 started_at INTEGER NOT NULL,started_at_ns INTEGER NOT NULL,host_consent_epoch INTEGER NOT NULL,created_at INTEGER NOT NULL,
 UNIQUE(room_id,host_id));
CREATE INDEX IF NOT EXISTS social_room_started_expiry ON social_room_started_events(created_at);
"""


class Event(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    schemaVersion: int = Field(ge=1, le=1)
    eventID: str = Field(pattern=r"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$")
    roomID: str = Field(pattern=r"^lk_[a-f0-9]{32}$")
    hostID: str = Field(pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")
    startedAt: int = Field(ge=1, le=9223372036854775807)
    startedAtNs: int = Field(ge=1, le=9223372036854775807)
    hostConsentEpoch: int = Field(ge=1, le=9223372036854775807)

    @field_validator("eventID")
    @classmethod
    def canonical_id(cls, value):
        return str(uuid.UUID(value))

    @model_validator(mode="after")
    def same_clock(self):
        if self.startedAtNs//1_000_000_000 != self.startedAt:
            raise ValueError("Start timestamps must represent the same second")
        return self


def initialize(db):
    db.executescript(SCHEMA)
    purge(db)


def purge(db, now=None):
    now = int(time.time()) if now is None else now
    db.execute("DELETE FROM voice_room_started_nonces WHERE expires_at<=?", (now,))
    db.execute("DELETE FROM social_room_started_events WHERE created_at<=?", (now-RECEIPT_TTL,))


def erase(db, account_id):
    # A recipient withdrawing must not erase the shared event receipt and allow
    # a sender retry to recreate notifications that other recipients deleted.
    db.execute("DELETE FROM social_room_started_events WHERE host_id=?", (account_id,))


def delivery_event(db, row):
    if row["event_kind"]!="notification":return None
    event = db.execute("""SELECT e.*,a.login_id AS host_public FROM social_notifications n
        JOIN social_room_started_events e ON e.room_id=n.room_id AND e.host_id=n.actor_id
        JOIN accounts a ON a.account_id=e.host_id
        WHERE n.id=? AND n.recipient_id=? AND n.kind='room_started' AND n.actor_id=?""",
        (row["source_id"],row["recipient_id"],row["actor_id"])).fetchone()
    return dict(event) if event else None


def status_payload(event):
    return {"eventID":event["event_id"],"roomID":event["room_id"],
            "hostID":event["host_public"],"hostConsentEpoch":event["host_consent_epoch"]}


def still_following(db, recipient_id, event):
    # The committed notice already proves membership in the original audience.
    # Delivery/click still requires the recipient's current follow relation.
    follow = db.execute("SELECT 1 FROM social_follows WHERE follower_id=? AND followed_id=?",
                        (recipient_id,event["host_id"])).fetchone()
    epoch = db.execute("SELECT MAX(event_id) FROM legal_consent_events WHERE account_id=?",
                       (event["host_id"],)).fetchone()[0]
    return bool(follow) and epoch == event["host_consent_epoch"]


class RoomStartedService:
    def __init__(self, settings, database, social):
        self.settings,self.database,self.social = settings,database,social
        self.clock = time.time

    def verify(self, request, body):
        if not self.settings.voice_bridge_enabled:
            raise HTTPException(404,"接口不存在")
        if request.url.path != PATH or request.url.query:
            raise HTTPException(404,"接口不存在")
        if len(body)>1024:
            raise HTTPException(413,"请求内容过大")
        timestamp,nonce,signature = (request.headers.get(key,"") for key in
                                    ("x-kiki-timestamp","x-kiki-nonce","x-kiki-signature"))
        now=int(self.clock())
        if (not re.fullmatch(r"[0-9]{10,12}",timestamp) or abs(now-int(timestamp))>30
                or not re.fullmatch(r"[a-f0-9]{32}",nonce) or not re.fullmatch(r"[a-f0-9]{64}",signature)):
            raise HTTPException(401,"无效的服务授权")
        message="\n".join((DOMAIN,"POST",PATH,timestamp,nonce,hashlib.sha256(body).hexdigest())).encode()
        expected=hmac.new(self.settings.voice_bridge_secret.encode(),message,hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature,expected):
            raise HTTPException(401,"无效的服务授权")
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM voice_room_started_nonces WHERE expires_at<=?",(now,))
            if db.execute("SELECT 1 FROM voice_room_started_nonces WHERE nonce=?",(nonce,)).fetchone():
                raise HTTPException(401,"服务请求已使用")
            db.execute("INSERT INTO voice_room_started_nonces VALUES(?,?)",(nonce,now+61))

    def prior(self, db, payload, hashed):
        old=db.execute("SELECT payload_hash FROM social_room_started_events WHERE event_id=?",(payload.eventID,)).fetchone()
        if old:
            if not hmac.compare_digest(old[0],hashed):
                raise HTTPException(409,"开播事件编号已用于其他内容")
            return True
        if db.execute("SELECT 1 FROM social_room_started_events e JOIN accounts a ON a.account_id=e.host_id WHERE e.room_id=? AND a.login_id=?",
                      (payload.roomID,payload.hostID)).fetchone():
            raise HTTPException(409,"该房间的开播事件已记录")
        return False

    def receive(self, payload, request, body):
        self.verify(request,body)
        content=payload.model_dump()
        hashed=hashlib.sha256(json.dumps(content,sort_keys=True,separators=(",",":")).encode()).hexdigest()
        now=int(self.clock())
        with self.database(self.settings) as db:
            if self.prior(db,payload,hashed): return {"ok":True}
        if not now-TTL < payload.startedAt <= now+30:
            raise HTTPException(422,"开播事件已过期或时间不正确")
        # All network operations precede the atomic receipt/notice/outbox write.
        active=self.social.room_started_status({key:content[key] for key in
            ("eventID","roomID","hostID","hostConsentEpoch")})
        policy=self.social.policy({"login_id":payload.hostID}) if active else None
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            if self.prior(db,payload,hashed): return {"ok":True}
            host=db.execute("SELECT a.* FROM accounts a WHERE a.login_id=? AND "+self.social.valid_account_sql(),
                            (payload.hostID,*self.social.legal_args)).fetchone()
            if host is None: return {"ok":True}
            epoch=db.execute("SELECT MAX(event_id) FROM legal_consent_events WHERE account_id=?",(host["account_id"],)).fetchone()[0]
            if epoch != payload.hostConsentEpoch: return {"ok":True}
            db.execute("INSERT INTO social_room_started_events VALUES(?,?,?,?,?,?,?,?)",
                       (payload.eventID,hashed,payload.roomID,host["account_id"],payload.startedAt,payload.startedAtNs,payload.hostConsentEpoch,now))
            if not active or int(self.clock())>=payload.startedAt+TTL: return {"ok":True}
            recipients=db.execute("SELECT a.* FROM social_follows f JOIN accounts a ON a.account_id=f.follower_id WHERE f.followed_id=? AND f.created_at<=? AND "+self.social.valid_account_sql(),
                                  (host["account_id"],payload.startedAtNs,*self.social.legal_args)).fetchall()
            blocked=set(policy.blockedUserIDs)
            for recipient in recipients:
                if recipient["login_id"] not in blocked:
                    self.social.notice(db,recipient["account_id"],"room_started",TEXT,host["account_id"],
                        f"room-started:{payload.eventID}:{recipient['account_id']}",room_id=payload.roomID,
                        push_expires_at=payload.startedAt+TTL)
        return {"ok":True}


def build_router(app):
    router=APIRouter()
    @router.post(PATH)
    async def receive(payload:Event,request:Request):
        return await run_in_threadpool(app.state.room_started.receive,payload,request,await request.body())
    return router
