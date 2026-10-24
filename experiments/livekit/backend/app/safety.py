"""Small-community safety: server-authored evidence, scoped sanctions and bounded data.

Evidence/reports and user notices expire after 30 days. Minimal operator action
audit and idempotency receipts expire after 90 days. Neither audio nor video is
recorded. Withdrawing consent/deletion removes blocks, evidence and identifiable
activity; opaque action receipts survive only for their bounded audit period.
"""
from dataclasses import dataclass, field
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import time
import unicodedata
import uuid
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator
from typing import Literal

REPORT_SECONDS = 30 * 86400
AUDIT_SECONDS = 90 * 86400
MAX_BLOCKS = 500
DEFAULT_WORDS = ("加微信刷单", "代开赌博", "出售身份证", "未成年裸聊")


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class ReportRequest(Model):
    clientRequestID: str = Field(min_length=36, max_length=36)
    targetType: Literal["room", "user", "message"]
    roomID: str = Field(min_length=1, max_length=80)
    targetUserID: str | None = Field(default=None, min_length=1, max_length=80)
    messageID: str | None = Field(default=None, min_length=1, max_length=80)
    reason: Literal["harassment", "spam", "sexual", "fraud", "other"]
    details: str = Field(default="", max_length=500)

    @field_validator("clientRequestID")
    @classmethod
    def identifier(cls, value):
        return str(uuid.UUID(value))

    @field_validator("details")
    @classmethod
    def text(cls, value):
        if any(ord(c) < 32 and c not in "\n\t" or ord(c) == 127 for c in value):
            raise ValueError("Invalid details")
        return value


class ModerationQuery(Model):
    status: Literal["pending", "resolved", "all"] = "pending"
    limit: int = Field(default=50, strict=True, ge=1, le=50)
    opsActorID: str = Field(pattern=r"^ops_[a-f0-9]{32}$")


class ModerationAction(Model):
    requestID: str = Field(min_length=36, max_length=36)
    reportID: str = Field(min_length=1, max_length=80)
    action: Literal["warn", "mute_chat", "mute_audio", "ban_user", "close_room", "dismiss", "restore_user"]
    durationSeconds: int | None = Field(default=None, strict=True, ge=60, le=30 * 86400)
    note: str = Field(min_length=1, max_length=500)
    opsActorID: str = Field(pattern=r"^ops_[a-f0-9]{32}$")

    @field_validator("requestID")
    @classmethod
    def identifier(cls, value):
        return str(uuid.UUID(value))

    @field_validator("note")
    @classmethod
    def text(cls, value):
        if any(ord(c) < 32 and c not in "\n\t" or ord(c) == 127 for c in value):
            raise ValueError("Invalid note")
        return value


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS safety_blocks(
      user_id TEXT NOT NULL REFERENCES users(id), blocked_user_id TEXT NOT NULL REFERENCES users(id),
      created_at INTEGER NOT NULL, PRIMARY KEY(user_id,blocked_user_id));
    CREATE TABLE IF NOT EXISTS safety_restrictions(
      user_id TEXT PRIMARY KEY REFERENCES users(id), chat_muted_until INTEGER,
      voice_muted_until INTEGER, banned_until INTEGER, reason TEXT NOT NULL DEFAULT '',source_report_id TEXT);
    CREATE TABLE IF NOT EXISTS safety_notices(
      id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),message TEXT NOT NULL,
      action TEXT NOT NULL,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS safety_notice_user ON safety_notices(user_id,created_at);
    CREATE TABLE IF NOT EXISTS safety_reports(
      id TEXT PRIMARY KEY,reporter_id TEXT NOT NULL,client_request_id TEXT NOT NULL,
      request_hash TEXT NOT NULL,target_type TEXT NOT NULL,room_id TEXT NOT NULL,
      room_title TEXT NOT NULL,target_user_id TEXT NOT NULL,message_id TEXT,
      reason TEXT NOT NULL,details TEXT NOT NULL,evidence_json TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',created_at INTEGER NOT NULL,
      resolved_at INTEGER,last_action TEXT,evidence_expires_at INTEGER NOT NULL,
      UNIQUE(reporter_id,client_request_id));
    CREATE INDEX IF NOT EXISTS safety_report_status ON safety_reports(status,created_at);
    CREATE TABLE IF NOT EXISTS safety_actions(
      request_id TEXT PRIMARY KEY,request_hash TEXT NOT NULL,report_id TEXT NOT NULL,
      actor_id TEXT NOT NULL,target_user_id TEXT NOT NULL,action TEXT NOT NULL,
      note TEXT NOT NULL,created_at INTEGER NOT NULL,response_json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS safety_observed_members(
      room_id TEXT NOT NULL,user_id TEXT NOT NULL,last_seen INTEGER NOT NULL,
      PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS safety_activity_daily(
      day TEXT NOT NULL,user_id TEXT NOT NULL,first_seen INTEGER NOT NULL,
      room_seconds INTEGER NOT NULL DEFAULT 0,mic_joins INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(day,user_id));
    CREATE TABLE IF NOT EXISTS safety_metadata(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
    INSERT OR IGNORE INTO safety_metadata VALUES('tracking_since',CAST(strftime('%s','now') AS INTEGER));
    """)
    columns = {row["name"] for row in db.execute("PRAGMA table_info(safety_restrictions)")}
    if "source_report_id" not in columns:
        db.execute("ALTER TABLE safety_restrictions ADD COLUMN source_report_id TEXT")
    # Account-only users can block each other before ever entering voice. Keep
    # this one authoritative relation without manufacturing media users just to
    # satisfy the laboratory-era foreign keys. Erasure is explicit below.
    if db.execute("PRAGMA foreign_key_list(safety_blocks)").fetchall():
        db.executescript("""
        CREATE TABLE safety_blocks_account_ids(
          user_id TEXT NOT NULL,blocked_user_id TEXT NOT NULL,created_at INTEGER NOT NULL,
          PRIMARY KEY(user_id,blocked_user_id));
        INSERT INTO safety_blocks_account_ids SELECT user_id,blocked_user_id,created_at FROM safety_blocks;
        DROP TABLE safety_blocks;
        ALTER TABLE safety_blocks_account_ids RENAME TO safety_blocks;
        """)
    db.execute("CREATE INDEX IF NOT EXISTS safety_blocks_target ON safety_blocks(blocked_user_id,user_id)")


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(",", ":")).encode()).hexdigest()


@dataclass
class SafetyStore:
    db: object
    limiter: object
    words: tuple = DEFAULT_WORDS
    samples: dict = field(default_factory=dict)
    activity_seen: set = field(default_factory=set)

    @classmethod
    def configured(cls, db, limiter, path=""):
        words = DEFAULT_WORDS
        if path:
            raw = json.loads(Path(path).read_text(encoding="utf-8"))
            if (not isinstance(raw, dict) or set(raw) != {"blockedTerms"}
                    or not isinstance(raw["blockedTerms"], list) or len(raw["blockedTerms"]) > 2000
                    or any(not isinstance(term, str) or not 2 <= len(term.strip()) <= 80 for term in raw["blockedTerms"])):
                raise RuntimeError("Invalid safety terms file")
            words = tuple(raw["blockedTerms"])
        return cls(db, limiter, words)

    def check_text(self, text):
        # NFKC and removing separators stop trivial full-width/zero-width spacing
        # evasions. This intentionally remains a basic configurable phrase filter.
        compact = lambda value: "".join(c for c in unicodedata.normalize("NFKC", value).casefold()
                                        if not c.isspace() and unicodedata.category(c) != "Cf")
        normal = compact(text)
        if any(compact(word) in normal for word in self.words):
            raise HTTPException(422, {"detail":"内容包含暂不允许发布的词语，请修改后重试", "code":"content_filtered"})

    def restrictions(self, user_id, now=None):
        now = int(time.time()) if now is None else now
        row = self.db.execute("SELECT * FROM safety_restrictions WHERE user_id=?", (user_id,)).fetchone()
        keys = {"chatMutedUntil":"chat_muted_until", "voiceMutedUntil":"voice_muted_until", "bannedUntil":"banned_until"}
        return {key: row[column] if row and row[column] and row[column] > now else None
                for key,column in keys.items()}

    def enforce(self, user_id, kind="ban"):
        key, code, text = {"ban":("bannedUntil", "voice_banned", "你的语聊权限暂时已被暂停"),
            "chat":("chatMutedUntil", "chat_muted", "你暂时无法发送文字"),
            "voice":("voiceMutedUntil", "voice_muted", "你暂时无法上麦")}[kind]
        until = self.restrictions(user_id)[key]
        if until:
            row = self.db.execute("SELECT reason FROM safety_restrictions WHERE user_id=?", (user_id,)).fetchone()
            raise HTTPException(403, {"detail":text, "code":code,"until":until,"reason":row[0]})

    def snapshot(self, user_id):
        now = int(time.time())
        rows = self.db.execute("""SELECT b.blocked_user_id,COALESCE(u.name,'用户'),b.created_at,u.display_id FROM safety_blocks b
            LEFT JOIN users u ON u.id=b.blocked_user_id WHERE b.user_id=? AND COALESCE(u.deleted,0)=0
            ORDER BY b.created_at DESC,b.blocked_user_id""", (user_id,)).fetchall()
        notices = self.db.execute("SELECT * FROM safety_notices WHERE user_id=? AND expires_at>? ORDER BY created_at DESC,id DESC LIMIT 50", (user_id,now)).fetchall()
        return {"schemaVersion":1, "blockedUsers":[{"userID":r[0],"name":r[1],"createdAt":r[2],"displayID":r[3]} for r in rows],
            "notices":[{"id":r["id"],"message":r["message"],"action":r["action"],"createdAt":r["created_at"],"expiresAt":r["expires_at"]} for r in notices],
            "restrictions":self.restrictions(user_id)}

    def block(self, user_id, target_id, enabled, *, account_verified=False):
        if user_id == target_id:
            raise HTTPException(422,"不能拉黑自己")
        if enabled:
            if not account_verified and not self.db.execute("SELECT 1 FROM users WHERE id=? AND deleted=0", (target_id,)).fetchone():
                raise HTTPException(404,"用户不存在")
            exists = self.db.execute("SELECT 1 FROM safety_blocks WHERE user_id=? AND blocked_user_id=?", (user_id,target_id)).fetchone()
            if not exists and self.db.execute("SELECT COUNT(*) FROM safety_blocks WHERE user_id=?", (user_id,)).fetchone()[0] >= MAX_BLOCKS:
                raise HTTPException(409,"拉黑人数已达上限，请先移除不再需要的记录")
            self.db.execute("INSERT OR IGNORE INTO safety_blocks VALUES(?,?,?)", (user_id,target_id,int(time.time())))
        else:
            self.db.execute("DELETE FROM safety_blocks WHERE user_id=? AND blocked_user_id=?", (user_id,target_id))
        return self.snapshot(user_id)

    def filter_chat(self, user_id, result):
        blocked = {row[0] for row in self.db.execute("SELECT blocked_user_id FROM safety_blocks WHERE user_id=?", (user_id,))}
        result["messages"] = [m for m in result["messages"] if m["senderUserID"] not in blocked]
        if result["announcement"]["updatedByUserID"] in blocked:
            result["announcement"] = {**result["announcement"], "text":"", "updatedByUserID":None}
        # Preserve the unfiltered server cursor, so hidden messages never cause
        # an endless catch-up loop. The client clears its own cache on block changes.
        return result

    def display_id(self, user_id):
        # Public numbers can be reused after erasure. Moderation always acts on
        # the immutable target user ID, never on this presentation-only value.
        person = self.db.execute("SELECT display_id FROM users WHERE id=? AND deleted=0", (user_id,)).fetchone()
        return person[0] if person else None

    def report_json(self, row, *, operator=False):
        result = {"id":row["id"], "status":row["status"], "targetType":row["target_type"],
            "roomID":row["room_id"],"targetUserID":row["target_user_id"],"messageID":row["message_id"],
            "reason":row["reason"],"details":row["details"],"createdAt":row["created_at"],"resolvedAt":row["resolved_at"]}
        if operator:
            def name(identifier):
                person = self.db.execute("SELECT name FROM users WHERE id=? AND deleted=0", (identifier,)).fetchone()
                return person[0] if person else "已移除用户"
            evidence = json.loads(row["evidence_json"])
            result.update(roomTitle=row["room_title"], reporterID=row["reporter_id"], reporterName=name(row["reporter_id"]),
                targetName=name(row["target_user_id"]), reporterDisplayID=self.display_id(row["reporter_id"]),
                targetDisplayID=self.display_id(row["target_user_id"]), messageExcerpt=evidence.get("message",{}).get("text"),
                lastAction=row["last_action"],evidenceExpiresAt=row["evidence_expires_at"])
        return result

    def create_report(self, user_id, payload):
        now = int(time.time())
        digest = canonical_hash(payload.model_dump())
        existing = self.db.execute("SELECT * FROM safety_reports WHERE reporter_id=? AND client_request_id=?", (user_id,payload.clientRequestID)).fetchone()
        if existing and existing["evidence_expires_at"] <= now:
            self.db.execute("DELETE FROM safety_reports WHERE id=?",(existing["id"],))
            existing = None
        if existing:
            if digest != existing["request_hash"]:
                raise HTTPException(409,"举报重试标识已用于其他内容")
            return self.report_json(existing)
        room = self.db.execute("SELECT * FROM rooms WHERE id=?", (payload.roomID,)).fetchone()
        observed = self.db.execute("SELECT 1 FROM safety_observed_members WHERE room_id=? AND user_id=? AND last_seen>?", (payload.roomID,user_id,now-REPORT_SECONDS)).fetchone()
        if not room or not observed:
            raise HTTPException(403,"只能举报你实际参与过的房间及其中内容")
        evidence = {"room":{"id":room["id"],"title":room["title"],"ownerID":room["owner_id"]}}
        target_id = room["owner_id"]
        if payload.targetType == "room":
            if payload.messageID or payload.targetUserID:
                raise HTTPException(422,"房间举报不接受用户或消息标识")
        elif payload.targetType == "user":
            if not payload.targetUserID or payload.messageID:
                raise HTTPException(422,"用户举报需要用户标识")
            target_id = payload.targetUserID
            if not self.db.execute("SELECT 1 FROM room_members WHERE room_id=? AND user_id=?", (payload.roomID,target_id)).fetchone():
                raise HTTPException(403,"举报对象不属于该房间")
        else:
            if not payload.messageID:
                raise HTTPException(422,"消息举报需要消息标识")
            message = self.db.execute("SELECT * FROM room_messages WHERE room_id=? AND id=? AND created_at>?", (payload.roomID,payload.messageID,now-7200)).fetchone()
            if not message:
                raise HTTPException(409,"消息证据已过期或不存在，请改为举报用户并描述情况")
            target_id = message["sender_user_id"]
            if payload.targetUserID and payload.targetUserID != target_id:
                raise HTTPException(422,"举报对象与消息作者不一致")
            evidence["message"] = {"id":message["id"],"senderUserID":target_id,"text":message["text"],"createdAt":message["created_at"]}
        if target_id == user_id:
            raise HTTPException(422,"不能举报自己")
        self.limiter.check(("report-short",user_id), 3, 60)
        self.limiter.check(("report-day",user_id), 20, 86400)
        # Persistent daily limit survives process restart, unlike burst limits.
        if self.db.execute("SELECT COUNT(*) FROM safety_reports WHERE reporter_id=? AND created_at>?", (user_id,now-86400)).fetchone()[0] >= 20:
            raise HTTPException(429,"今天提交的举报较多，请等待处理",headers={"Retry-After":"3600"})
        identifier = "report_" + uuid.uuid4().hex
        self.db.execute("""INSERT INTO safety_reports(id,reporter_id,client_request_id,request_hash,target_type,
            room_id,room_title,target_user_id,message_id,reason,details,evidence_json,created_at,evidence_expires_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (identifier,user_id,payload.clientRequestID,digest,payload.targetType,
            payload.roomID,room["title"],target_id,payload.messageID,payload.reason,payload.details,
            json.dumps(evidence,ensure_ascii=False),now,now+REPORT_SECONDS))
        return self.report_json(self.db.execute("SELECT * FROM safety_reports WHERE id=?", (identifier,)).fetchone())

    def mine(self, user_id):
        rows = self.db.execute("SELECT * FROM safety_reports WHERE reporter_id=? AND evidence_expires_at>? ORDER BY created_at DESC,id DESC LIMIT 100", (user_id,int(time.time()))).fetchall()
        return {"reports":[self.report_json(r) for r in rows],"retentionDays":30}

    def query(self, payload):
        now = int(time.time())
        clause = "" if payload.status == "all" else "AND status='pending'" if payload.status == "pending" else "AND status IN ('resolved','dismissed')"
        ordering = "ASC" if payload.status == "pending" else "DESC"
        rows = self.db.execute("SELECT * FROM safety_reports WHERE evidence_expires_at>? " + clause + f" ORDER BY created_at {ordering},id {ordering} LIMIT ?", (now,payload.limit)).fetchall()
        active = self.db.execute("""SELECT * FROM safety_restrictions WHERE source_report_id IS NOT NULL
            AND (chat_muted_until>? OR voice_muted_until>? OR banned_until>?)
            ORDER BY user_id LIMIT 5001""", (now,now,now)).fetchall()
        return {"schemaVersion":1,"reports":[self.report_json(r,operator=True) for r in rows],"retentionDays":30,
            "activeRestrictions":[{"reportID":r["source_report_id"],"targetUserID":r["user_id"],
                "targetDisplayID":self.display_id(r["user_id"]),
                "chatMutedUntil":r["chat_muted_until"] if r["chat_muted_until"] and r["chat_muted_until"]>now else None,
                "voiceMutedUntil":r["voice_muted_until"] if r["voice_muted_until"] and r["voice_muted_until"]>now else None,
                "bannedUntil":r["banned_until"] if r["banned_until"] and r["banned_until"]>now else None} for r in active[:5000]],
            "activeRestrictionsTruncated":len(active)>5000,"activeRestrictionsLimit":5000}

    def prune(self, now=None):
        now = int(time.time()) if now is None else now
        self.db.execute("DELETE FROM safety_reports WHERE evidence_expires_at<=?", (now,))
        self.db.execute("DELETE FROM safety_notices WHERE expires_at<=?", (now,))
        self.db.execute("DELETE FROM safety_actions WHERE created_at<=?", (now-AUDIT_SECONDS,))
        self.db.execute("DELETE FROM safety_observed_members WHERE last_seen<=?", (now-REPORT_SECONDS,))
        cutoff = (datetime.fromtimestamp(now,ZoneInfo("Asia/Shanghai")).date()-timedelta(days=34)).isoformat()
        self.db.execute("DELETE FROM safety_activity_daily WHERE day<?", (cutoff,))
        self.activity_seen = {key for key in self.activity_seen if key[0] >= cutoff}

    def clear_user(self, user_id, *, preserve_blocks=False):
        if not preserve_blocks:
            self.db.execute("DELETE FROM safety_blocks WHERE user_id=? OR blocked_user_id=?", (user_id,user_id))
        self.db.execute("DELETE FROM safety_notices WHERE user_id=?", (user_id,))
        self.db.execute("UPDATE safety_restrictions SET reason='社区语聊限制仍有效' WHERE user_id=?", (user_id,))
        # Audit contains no media/text evidence. Clear free-form notes and target
        # identity on erasure; the opaque request/report IDs remain for 90 days.
        self.db.execute("UPDATE safety_actions SET target_user_id='',note='' WHERE target_user_id=?", (user_id,))
        self.db.execute("DELETE FROM safety_reports WHERE reporter_id=? OR target_user_id=?", (user_id,user_id))
        self.db.execute("DELETE FROM safety_observed_members WHERE user_id=?", (user_id,))
        self.db.execute("DELETE FROM safety_activity_daily WHERE user_id=?", (user_id,))
        self.activity_seen = {key for key in self.activity_seen if key[1] != user_id}
        for key in list(self.samples):
            if key[1] == user_id:
                del self.samples[key]

    def activity(self, user_id, *, mic=False, seconds=0, now=None):
        now = int(time.time()) if now is None else now
        day = datetime.fromtimestamp(now,ZoneInfo("Asia/Shanghai")).date().isoformat()
        key = (day,user_id)
        if key in self.activity_seen and not mic and not seconds:
            return
        self.db.execute("""INSERT INTO safety_activity_daily(day,user_id,first_seen,room_seconds,mic_joins)
            VALUES(?,?,?,?,?) ON CONFLICT(day,user_id) DO UPDATE SET
            room_seconds=room_seconds+excluded.room_seconds,mic_joins=mic_joins+excluded.mic_joins""", (day,user_id,now,seconds,int(mic)))
        self.activity_seen.add(key)

    def forget_room(self, room_id):
        for key in list(self.samples):
            if key[0] == room_id:
                del self.samples[key]

    def observe(self, room_id, online, *, now=None, force=False):
        now = int(time.time()) if now is None else now
        members = {r[0] for r in self.db.execute("SELECT user_id FROM room_members WHERE room_id=? AND active=1", (room_id,))}
        online = set(online) & members
        # At most one durable sample per 5 seconds per room; state polling stays
        # read-only between samples. No duration is extrapolated across outages.
        previous_room = self.samples.get((room_id,""))
        if not force and previous_room is not None and now-previous_room < 5:
            return
        self.samples[(room_id,"")] = now
        for key in list(self.samples):
            if key[0] == room_id and key[1] and key[1] not in online:
                del self.samples[key]
        for user_id in online:
            key = (room_id,user_id)
            previous = self.samples.get(key)
            elapsed = now-previous if previous is not None and 0 < now-previous <= 15 else 0
            self.samples[key] = now
            self.db.execute("INSERT INTO safety_observed_members VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET last_seen=excluded.last_seen", (room_id,user_id,now))
            self.activity(user_id,seconds=elapsed,now=now)

    def metrics(self, now=None):
        now = int(time.time()) if now is None else int(now)
        day = datetime.fromtimestamp(now,ZoneInfo("Asia/Shanghai")).date().isoformat()
        since = self.db.execute("SELECT value FROM safety_metadata WHERE key='tracking_since'").fetchone()[0]
        start = int(datetime.fromisoformat(day).replace(tzinfo=ZoneInfo("Asia/Shanghai")).timestamp())
        scalar = lambda query,args=(): self.db.execute(query,args).fetchone()[0]
        active = scalar("SELECT COUNT(*) FROM safety_activity_daily WHERE day=?",(day,))
        returning = scalar("SELECT COUNT(*) FROM safety_activity_daily d WHERE day=? AND EXISTS(SELECT 1 FROM safety_activity_daily p WHERE p.user_id=d.user_id AND p.day<d.day)",(day,))
        active_rooms = [row[0] for row in self.db.execute("SELECT id FROM rooms WHERE status='active'")]
        room_samples = [self.samples.get((room_id,"")) for room_id in active_rooms]
        fresh = all(at is not None and 0 <= now-at <= 10 for at in room_samples)
        online = {user_id for (room_id,user_id),at in self.samples.items()
                  if user_id and room_id in active_rooms and 0 <= now-at <= 10}
        return {"trackingSince":since,"day":day,"timeZone":"Asia/Shanghai", "activeUsersToday":active,
            "returningUsersToday":returning, "onlineUsersNow":len(online) if fresh else None,
            "onlineSampledAt":min(room_samples) if fresh and room_samples else now if fresh else None,
            "roomStaySecondsToday":scalar("SELECT COALESCE(SUM(room_seconds),0) FROM safety_activity_daily WHERE day=?",(day,)),
            "micSeatJoinsToday":scalar("SELECT COALESCE(SUM(mic_joins),0) FROM safety_activity_daily WHERE day=?",(day,)),
            "reportsToday":scalar("SELECT COUNT(*) FROM safety_reports WHERE created_at>=?",(start,)),
            "pendingReports":scalar("SELECT COUNT(*) FROM safety_reports WHERE status='pending' AND evidence_expires_at>?",(now,)),
            "note":"语聊活跃按成功认证的账号ID去重，回访指近35天曾活跃；停留按SFU在线采样估计，中断不补算，上麦统计授权麦位进入次数。仅从trackingSince开始记录，非历史全量。"}
