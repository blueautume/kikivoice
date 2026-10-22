"""Bounded, durable room failure evidence. Never stores free-form error text."""
import hashlib
import json
import time
import uuid
from typing import Literal

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

RETENTION_DAYS = 7
RETENTION_SECONDS = RETENTION_DAYS * 86400
MAX_EVENTS = 10000
CODES = {
    "request_timeout": "请求超时，未及时取得响应", "network_unavailable": "设备网络不可用",
    "network_connection_lost": "网络连接中断", "network_tls_failed": "安全连接建立失败",
    "network_error": "网络请求失败", "http_unauthorized": "业务登录授权不可用",
    "http_forbidden": "操作权限被拒绝", "http_not_found": "请求的房间或资源不存在",
    "http_conflict": "房间状态或操作发生冲突", "http_rate_limited": "请求受到频率限制",
    "http_server_error": "服务端处理失败", "http_invalid_response": "服务响应格式不正确",
    "consent_required": "需要确认当前隐私协议", "capacity_reached": "房间或服务准入达到上限",
    "room_ended": "目标房间已经结束", "voice_banned": "账号受到语聊限制",
    "chat_muted": "账号受到文字禁言限制", "voice_muted": "账号受到上麦限制",
    "content_filtered": "内容未通过过滤", "media_connect_timeout": "媒体连接建立超时",
    "media_connect_failed": "媒体连接建立失败", "media_disconnected": "媒体连接意外断开",
    "reconnect_failed": "媒体重连失败", "state_sync_failed": "房间状态同步失败",
    "audio_publish_failed": "麦克风音轨发布失败", "audio_permission_denied": "麦克风权限不可用",
    "quality_poor": "音频连接质量较差", "quality_lost": "音频连接质量丢失",
    "unknown_error": "未分类的房间错误",
}


class Incident(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    eventID: str = Field(min_length=36, max_length=36)
    attemptID: str = Field(min_length=36, max_length=36)
    operation: Literal["create_room", "join_room", "room_runtime"]
    stage: Literal["account_authorization", "room_api", "token_api", "media_connect", "state_sync", "media_runtime", "reconnect", "safety_sync", "chat_sync", "audio_policy", "room_action", "room_leave"]
    severity: Literal["warning", "error"]
    code: str = Field(max_length=40,json_schema_extra={"enum":list(CODES)})
    occurredAt: int = Field(strict=True, ge=1)
    elapsedMs: int | None = Field(default=None, strict=True, ge=0, le=3600000)
    roomID: str | None = Field(default=None, pattern=r"^lk_[a-f0-9]{32}$")
    requestID: str | None = Field(default=None, min_length=36, max_length=36)
    httpStatus: int | None = Field(default=None, strict=True, ge=400, le=599)
    platform: Literal["ios", "ipados", "server"]
    appVersion: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9 .()_-]+$")
    osVersion: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9 .()_-]+$")

    @field_validator("eventID", "attemptID", "requestID")
    @classmethod
    def valid_uuid(cls, value):
        if value is None:
            return value
        parsed = str(uuid.UUID(value))
        if parsed != value.lower():
            raise ValueError("Use a canonical UUID")
        return parsed

    @field_validator("code")
    @classmethod
    def known_code(cls, value):
        if value not in CODES:
            raise ValueError("Unknown diagnostic code")
        return value


class AccountIncident(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    accountID: str = Field(pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")
    name: str = Field(min_length=1, max_length=16)
    consentEpoch: int = Field(strict=True, ge=1, le=9223372036854775807)
    lastWithdrawalEpoch: int = Field(strict=True, ge=0, le=9223372036854775807)
    source: Literal["client", "account"]
    event: Incident

    @field_validator("name")
    @classmethod
    def clean_name(cls, value):
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("Invalid name")
        return value


class IncidentQuery(BaseModel):
    model_config = ConfigDict(extra="forbid",str_strip_whitespace=True)
    severity: Literal["all","warning","error"] = "all"
    operation: Literal["all","create_room","join_room","room_runtime"] = "all"
    userQuery: str | None = Field(default=None,max_length=80)
    limit: int = Field(default=50,strict=True,ge=1,le=50)
    cursor: str | None = Field(default=None,min_length=36,max_length=36)

    @field_validator("userQuery")
    @classmethod
    def clean_query(cls,value):
        if value is not None and any(ord(c)<32 or ord(c)==127 for c in value):
            raise ValueError("Invalid search")
        return value

    @field_validator("cursor")
    @classmethod
    def cursor_uuid(cls,value):
        return Incident.valid_uuid(value)


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS room_incident_metadata(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS room_incident_privacy(user_id TEXT PRIMARY KEY,withdrawal_epoch INTEGER NOT NULL DEFAULT 0,expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS room_incidents(
      seq INTEGER PRIMARY KEY AUTOINCREMENT,user_id TEXT NOT NULL,user_name TEXT NOT NULL,event_id TEXT NOT NULL,
      attempt_id TEXT NOT NULL,operation TEXT NOT NULL,severity TEXT NOT NULL,code TEXT NOT NULL,
      occurred_at INTEGER NOT NULL,received_at INTEGER NOT NULL,source TEXT NOT NULL,
      consent_epoch INTEGER NOT NULL DEFAULT 0,payload TEXT NOT NULL,payload_hash TEXT NOT NULL,
      UNIQUE(user_id,event_id));
    CREATE UNIQUE INDEX IF NOT EXISTS room_incidents_event_uuid ON room_incidents(event_id);
    CREATE INDEX IF NOT EXISTS room_incidents_received ON room_incidents(received_at);
    CREATE INDEX IF NOT EXISTS room_incidents_occurred ON room_incidents(occurred_at);
    CREATE INDEX IF NOT EXISTS room_incidents_user_received ON room_incidents(user_id,received_at);
    """)
    db.execute("INSERT OR IGNORE INTO room_incident_metadata VALUES('tracking_since',?)", (int(time.time()),))
    # Additive migration for a process that briefly ran the first incident build.
    if "expires_at" not in {row["name"] for row in db.execute("PRAGMA table_info(room_incident_privacy)")}:
        db.execute("ALTER TABLE room_incident_privacy ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0")
        db.execute("UPDATE room_incident_privacy SET expires_at=?",(int(time.time())+32*86400,))


class IncidentStore:
    def __init__(self, db):
        self.db = db

    def prune(self, now=None):
        at = int(time.time()) if now is None else int(now)
        self.db.execute("DELETE FROM room_incidents WHERE occurred_at<=?", (at-RETENTION_SECONDS,))
        self.db.execute("DELETE FROM room_incident_privacy WHERE expires_at<=?",(at,))
        self.db.execute("DELETE FROM room_incidents WHERE seq IN (SELECT seq FROM room_incidents ORDER BY seq DESC LIMIT -1 OFFSET ?)", (MAX_EVENTS,))

    def clear_user(self, user_id, *, withdrawal_epoch=None):
        if withdrawal_epoch is None:
            self.db.execute("DELETE FROM room_incidents WHERE user_id=?", (user_id,))
            self.db.execute("DELETE FROM room_incident_privacy WHERE user_id=?",(user_id,))
        else:
            self.db.execute("DELETE FROM room_incidents WHERE user_id=? AND consent_epoch<=?", (user_id,withdrawal_epoch))
            self.db.execute("""INSERT INTO room_incident_privacy VALUES(?,?,?) ON CONFLICT(user_id)
                DO UPDATE SET withdrawal_epoch=MAX(withdrawal_epoch,excluded.withdrawal_epoch),expires_at=MAX(expires_at,excluded.expires_at)""", (user_id,withdrawal_epoch,int(time.time())+32*86400))

    def record(self, user_id, name, event, *, source="client", consent_epoch=0, now=None):
        at = int(time.time()) if now is None else int(now)
        self.prune(at)
        body = event.model_dump()
        encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        digest = hashlib.sha256((source+":"+encoded).encode()).hexdigest()
        previous = self.db.execute("SELECT payload_hash,user_id FROM room_incidents WHERE event_id=?", (event.eventID,)).fetchone()
        if previous:
            if previous[0] != digest or previous[1] != user_id:
                raise HTTPException(409, "问题事件编号不能复用")
            return {"accepted":True,"eventID":event.eventID,"duplicate":True}
        if event.occurredAt <= at-RETENTION_SECONDS or event.occurredAt > at+300:
            raise HTTPException(422, "问题事件时间超出记录窗口")
        # Durable limits cover retries/restarts and both submission paths. Server
        # request evidence has a separate small allowance, so client spam cannot
        # hide a real API failure. No request body or free-form message is saved.
        lane = "server" if source in {"server","account"} else "submitted"
        clause = "source IN ('server','account')" if lane == "server" else "source='client'"
        recent = self.db.execute(f"SELECT COUNT(*) FROM room_incidents WHERE user_id=? AND {clause} AND received_at>?", (user_id,at-60)).fetchone()[0]
        day = self.db.execute(f"SELECT COUNT(*) FROM room_incidents WHERE user_id=? AND {clause} AND received_at>?", (user_id,at-86400)).fetchone()[0]
        if recent >= (30 if lane == "server" else 20) or day >= (300 if lane == "server" else 100):
            raise HTTPException(429, "问题记录过于频繁，请稍后重试", headers={"Retry-After":"60"})
        if event.code in {"quality_poor", "quality_lost"}:
            duplicate = self.db.execute("SELECT event_id FROM room_incidents WHERE user_id=? AND attempt_id=? AND code=? AND received_at>?", (user_id,event.attemptID,event.code,at-60)).fetchone()
            if duplicate:
                return {"accepted":True,"eventID":event.eventID,"duplicate":True}
        self.db.execute("""INSERT INTO room_incidents(user_id,user_name,event_id,attempt_id,operation,severity,code,
            occurred_at,received_at,source,consent_epoch,payload,payload_hash) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (user_id,name,event.eventID,event.attemptID,event.operation,event.severity,event.code,event.occurredAt,at,source,consent_epoch,encoded,digest))
        self.prune(at)
        return {"accepted":True,"eventID":event.eventID,"duplicate":False}

    def internal(self, payload):
        if (payload.source=="client" and payload.event.platform=="server"
                or payload.source=="account" and (payload.event.platform!="server"
                    or payload.event.appVersion!="account-api" or payload.event.osVersion!="server")):
            raise HTTPException(422,"问题事件来源不正确")
        uid, epoch, previous_withdrawal = payload.accountID,payload.consentEpoch,payload.lastWithdrawalEpoch
        if previous_withdrawal >= epoch:
            raise HTTPException(422,"问题记录的同意版本不正确")
        privacy = self.db.execute("SELECT * FROM account_privacy_state WHERE user_id=?", (uid,)).fetchone()
        local = self.db.execute("SELECT withdrawal_epoch FROM room_incident_privacy WHERE user_id=?", (uid,)).fetchone()
        watermark = max(privacy["withdrawal_epoch"] if privacy else 0,local[0] if local else 0)
        if epoch <= watermark or (privacy and epoch < privacy["consent_epoch"]):
            raise HTTPException(409,"问题记录授权已撤回或更新")
        if self.db.execute("SELECT 1 FROM account_deletions WHERE subject_hash=? AND expires_at>?", (hashlib.sha256(uid.encode()).hexdigest(),int(time.time()))).fetchone():
            raise HTTPException(401,"账号授权已撤回")
        if previous_withdrawal > watermark:
            self.clear_user(uid,withdrawal_epoch=previous_withdrawal)
        return self.record(uid,payload.name,payload.event,source=payload.source,consent_epoch=epoch)

    def dashboard(self, now=None):
        at = int(time.time()) if now is None else int(now)
        with self.db:
            self.prune(at)
        counts = dict(self.db.execute("SELECT severity,COUNT(*) FROM room_incidents WHERE occurred_at>? GROUP BY severity", (at-86400,)).fetchall())
        attempts = self.db.execute("SELECT COUNT(*) FROM (SELECT user_id,attempt_id FROM room_incidents WHERE occurred_at>? AND operation IN ('create_room','join_room') GROUP BY user_id,attempt_id)", (at-86400,)).fetchone()[0]
        events=self.query(IncidentQuery())["events"]
        return {"schemaVersion":1,"retentionDays":RETENTION_DAYS,
            "trackingSince":self.db.execute("SELECT value FROM room_incident_metadata WHERE key='tracking_since'").fetchone()[0],
            "totalEvents":self.db.execute("SELECT COUNT(*) FROM room_incidents").fetchone()[0],
            "errorsLast24Hours":counts.get("error",0),"warningsLast24Hours":counts.get("warning",0),
            "failedAttemptsLast24Hours":attempts,"events":events}

    @staticmethod
    def event_json(row):
        event=json.loads(row["payload"])
        event.update(userID=row["user_id"],userName=row["user_name"],source=row["source"],receivedAt=row["received_at"],message=CODES[row["code"]])
        return event

    def query(self,payload):
        with self.db:
            self.prune()
        clauses,values=[],[]
        for column,value in (("severity",payload.severity),("operation",payload.operation)):
            if value!="all":
                clauses.append(column+"=?")
                values.append(value)
        if payload.userQuery:
            escaped=payload.userQuery.replace("\\","\\\\").replace("%","\\%").replace("_","\\_")
            clauses.append("(user_id LIKE ? ESCAPE '\\' OR user_name LIKE ? ESCAPE '\\')")
            values.extend(["%"+escaped+"%"]*2)
        if payload.cursor:
            previous=self.db.execute("SELECT received_at,event_id FROM room_incidents WHERE event_id=?",(payload.cursor,)).fetchone()
            if previous is None:
                raise HTTPException(422,"问题记录游标已过期，请刷新")
            clauses.append("(received_at<? OR (received_at=? AND event_id<?))")
            values.extend([previous[0],previous[0],previous[1]])
        where=" WHERE "+" AND ".join(clauses) if clauses else ""
        rows=self.db.execute("SELECT * FROM room_incidents"+where+" ORDER BY received_at DESC,event_id DESC LIMIT ?",(*values,payload.limit+1)).fetchall()
        return {"schemaVersion":1,"retentionDays":RETENTION_DAYS,
            "events":[self.event_json(r) for r in rows[:payload.limit]],
            "nextCursor":rows[payload.limit-1]["event_id"] if len(rows)>payload.limit else None}


def build_router(app, settings, lock, authenticate):
    from . import account_bridge
    router=APIRouter()

    @router.post("/v1/telemetry/incidents",status_code=202)
    async def report(payload:Incident,request:Request):
        async with lock:
            user,_session=authenticate(request)
            if payload.platform=="server":
                raise HTTPException(422,"客户端平台不正确")
            privacy=app.state.db.execute("SELECT consent_epoch FROM account_privacy_state WHERE user_id=?",(user["id"],)).fetchone()
            with app.state.db:
                return app.state.incidents.record(user["id"],user["name"],payload,consent_epoch=privacy[0] if privacy else 0)

    @router.post("/internal/v1/account/incident",status_code=202)
    async def signed_report(payload:AccountIncident,request:Request):
        async with lock:
            path="/internal/v1/account/incident"
            if (request.method!="POST" or request.url.path!=path or request.url.query
                    or request.scope.get("raw_path",path.encode())!=path.encode()
                    or "authorization" in request.headers or request.headers.getlist("content-type")!=["application/json"]
                    or any(len(request.headers.getlist(name))!=1 for name in ("x-kiki-timestamp","x-kiki-nonce","x-kiki-signature"))):
                raise HTTPException(401,"无效的服务授权")
            account_bridge.verify_request(settings,app.state.db,request,await request.body())
            with app.state.db:
                return app.state.incidents.internal(payload)

    return router
