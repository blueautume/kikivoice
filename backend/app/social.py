"""Small-community social data owned by the account service.

Voice remains the sole block authority. Every social request obtains an uncached,
bounded privacy-policy snapshot, then rechecks account/session/current consent.
No Apple subject, credential, raw network error or private token enters responses.
"""
import base64
import hashlib
import hmac
import json
import re
import time
import threading
import unicodedata
import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request
import httpx
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .voice_bridge import signed_headers
from .social_content import (ContentMethods, initialize_content, purge_content, erase_content, install_content_routes)
from .community_content import PublicTextPolicy

DAYS = 30 * 86400
POLICY_PATH = "/internal/v1/account/social-policy"
BLOCK_PATH = "/internal/v1/account/social-block"
MAX_POLICY_BYTES = 1024 * 1024
ID_PATTERN = r"^[A-Za-z0-9_]{3,80}$"
ROOM_PATTERN = r"^lk_[a-f0-9]{32}$"
UUID_PATTERN = r"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"
SCHEMA = """
CREATE TABLE IF NOT EXISTS social_follows(
 follower_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 followed_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 created_at INTEGER NOT NULL,PRIMARY KEY(follower_id,followed_id),CHECK(follower_id!=followed_id));
CREATE INDEX IF NOT EXISTS social_followed ON social_follows(followed_id,created_at DESC,follower_id);
CREATE TABLE IF NOT EXISTS social_notifications(
 id TEXT PRIMARY KEY,recipient_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 actor_id TEXT REFERENCES accounts(account_id) ON DELETE CASCADE,
 kind TEXT NOT NULL,text TEXT NOT NULL,created_at INTEGER NOT NULL,read_at INTEGER,
 dedupe_key TEXT UNIQUE,room_id TEXT,moment_id TEXT);
CREATE INDEX IF NOT EXISTS social_notification_recipient ON social_notifications(recipient_id,created_at DESC,id DESC);
CREATE TABLE IF NOT EXISTS social_notification_sequence(
 seq INTEGER PRIMARY KEY AUTOINCREMENT,
 notification_id TEXT NOT NULL UNIQUE REFERENCES social_notifications(id) ON DELETE CASCADE);
CREATE TRIGGER IF NOT EXISTS social_notification_sequence_insert AFTER INSERT ON social_notifications
 BEGIN INSERT INTO social_notification_sequence(notification_id) VALUES(NEW.id); END;
CREATE TABLE IF NOT EXISTS social_notification_state(
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 is_pinned INTEGER NOT NULL DEFAULT 0 CHECK(is_pinned IN (0,1)),
 cleared_through_seq INTEGER NOT NULL DEFAULT 0 CHECK(cleared_through_seq>=0));
CREATE TABLE IF NOT EXISTS social_receipts(
 actor_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,request_id TEXT NOT NULL,
 request_hash TEXT NOT NULL,created_at INTEGER NOT NULL,result_id TEXT,PRIMARY KEY(actor_id,request_id));
CREATE TABLE IF NOT EXISTS social_rate_events(
 id TEXT PRIMARY KEY,actor_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 kind TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS social_rate_actor ON social_rate_events(actor_id,kind,created_at);
CREATE TABLE IF NOT EXISTS social_block_requests(
 seq INTEGER PRIMARY KEY AUTOINCREMENT,actor_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 target_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,request_id TEXT NOT NULL,
 blocked INTEGER NOT NULL,created_at INTEGER NOT NULL,completed INTEGER NOT NULL DEFAULT 0,
 UNIQUE(actor_id,request_id));
CREATE TABLE IF NOT EXISTS social_restrictions(
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 muted_until INTEGER NOT NULL,source_report_id TEXT);
CREATE TABLE IF NOT EXISTS social_reports(
 id TEXT PRIMARY KEY,reporter_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 target_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 client_request_id TEXT NOT NULL,request_hash TEXT NOT NULL,target_type TEXT NOT NULL,
 content_id TEXT,reason TEXT NOT NULL,details TEXT NOT NULL,evidence TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending',created_at INTEGER NOT NULL,resolved_at INTEGER,
 last_action TEXT,UNIQUE(reporter_id,client_request_id));
CREATE INDEX IF NOT EXISTS social_report_status ON social_reports(status,created_at,id);
CREATE TABLE IF NOT EXISTS social_actions(
 request_id TEXT PRIMARY KEY,request_hash TEXT NOT NULL,report_id TEXT NOT NULL,
 actor_id TEXT NOT NULL,target_id TEXT,note TEXT,action TEXT NOT NULL,
 created_at INTEGER NOT NULL,result TEXT NOT NULL);
"""


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)


class Mutation(Model):
    requestID: str = Field(pattern=UUID_PATTERN)

    @field_validator("requestID")
    @classmethod
    def identifier(cls, value):
        return str(uuid.UUID(value))


class NotificationPin(Mutation):
    pinned:bool


class InboxMutation(Mutation):
    snapshot:str=Field(min_length=1,max_length=1024)


class NotificationClear(Mutation):
    throughNotificationID:str=Field(pattern=UUID_PATTERN)

    @field_validator("throughNotificationID")
    @classmethod
    def through_identifier(cls,value):
        return str(uuid.UUID(value))


class ReadNotifications(Model):
    ids: list[str] | None = Field(default=None, min_length=1, max_length=100)
    all: bool = False

    @field_validator("ids")
    @classmethod
    def identifiers(cls, value):
        if value is None:
            return None
        if any(not re.fullmatch(UUID_PATTERN, item) for item in value):
            raise ValueError("Invalid notification ID")
        return list(dict.fromkeys(str(uuid.UUID(item)) for item in value))

    @model_validator(mode="after")
    def exclusive(self):
        if self.all == (self.ids is not None):
            raise ValueError("Choose IDs or all")
        return self


class PolicyRoom(Model):
    userID: str = Field(pattern=ID_PATTERN)
    roomID: str = Field(pattern=ROOM_PATTERN)


class Policy(Model):
    schemaVersion: Literal[1]
    accountID: str = Field(pattern=ID_PATTERN)
    blockedUserIDs: list[str] = Field(max_length=10000)
    currentRooms: list[PolicyRoom] = Field(max_length=50)
    roomsStale: bool

    @field_validator("schemaVersion",mode="before")
    @classmethod
    def version(cls,value):
        if type(value) is not int or value!=1:
            raise ValueError("Invalid policy schema")
        return value

    @field_validator("blockedUserIDs")
    @classmethod
    def identifiers(cls, value):
        if any(not re.fullmatch(ID_PATTERN, item) for item in value) or len(set(value)) != len(value):
            raise ValueError("Invalid policy IDs")
        return value


def initialize(db):
    db.executescript(SCHEMA)
    if "moment_id" not in {row["name"] for row in db.execute("PRAGMA table_info(social_notifications)")}:
        db.execute("ALTER TABLE social_notifications ADD COLUMN moment_id TEXT")
    db.execute("INSERT INTO social_notification_sequence(notification_id) SELECT n.id FROM social_notifications n WHERE NOT EXISTS(SELECT 1 FROM social_notification_sequence s WHERE s.notification_id=n.id) ORDER BY n.created_at,n.id")
    initialize_content(db)
    purge(db)


def purge(db, now=None):
    now = int(time.time()) if now is None else now
    db.execute("DELETE FROM social_notifications WHERE created_at<=?", (now-DAYS,))
    db.execute("DELETE FROM social_receipts WHERE created_at<=?", (now-DAYS,))
    db.execute("DELETE FROM social_rate_events WHERE created_at<=?", (now-86400,))
    db.execute("DELETE FROM social_block_requests WHERE created_at<=?", (now-DAYS,))
    db.execute("DELETE FROM social_reports WHERE created_at<=?", (now-DAYS,))
    db.execute("DELETE FROM social_actions WHERE created_at<=?", (now-90*86400,))
    db.execute("DELETE FROM social_restrictions WHERE muted_until<=?", (now,))
    purge_content(db,now)


def erase(db, account_id):
    """Withdrawal clears social data even though the Apple account survives."""
    from . import push
    push.erase(db,account_id)
    for table, where in (("social_follows", "follower_id=? OR followed_id=?"),
                         ("social_notifications", "recipient_id=? OR actor_id=?"),
                         ("social_reports", "reporter_id=? OR target_id=?")):
        db.execute(f"DELETE FROM {table} WHERE {where}", (account_id, account_id))
    for table in ("social_receipts", "social_rate_events"):
        db.execute(f"DELETE FROM {table} WHERE actor_id=?", (account_id,))
    db.execute("UPDATE social_actions SET target_id=NULL,note=NULL WHERE target_id=?", (account_id,))
    db.execute("DELETE FROM social_block_requests WHERE actor_id=? OR target_id=?", (account_id,account_id))
    db.execute("DELETE FROM social_notification_state WHERE account_id=?",(account_id,))
    erase_content(db,account_id)
    # Active restrictions outlive withdrawal, preventing a consent-toggle bypass.
    # Account deletion cascades them; temporary restrictions expire within30days.


def clean_text(value, maximum, *, multiline=False):
    value = unicodedata.normalize("NFC", value).strip()
    if not 0 < len(value) <= maximum or any(unicodedata.category(c) in {"Cc", "Cf", "Cs"}
            and not (multiline and c == "\n") for c in value):
        raise HTTPException(422, "文字格式不正确")
    return value


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(",", ":")).encode()).hexdigest()


class SocialService(ContentMethods):
    def __init__(self, settings, database, bridge, requirements, require_active_session, limits):
        self.settings, self.database, self.bridge = settings, database, bridge
        self.requirements, self.require_active_session, self.limits = requirements, require_active_session, limits
        self.text_policy = PublicTextPolicy(settings.public_content_blocklist)
        self.block_locks = [threading.Lock() for _ in range(64)]
        seed = settings.voice_bridge_secret if settings.voice_bridge_enabled else settings.apple_token_encryption_key
        if len(seed)<32:
            raise RuntimeError("Social cursor signing requires configured account cryptographic material")
        self.cursor_key = hmac.new(seed.encode(),b"account-social-cursor-v1",hashlib.sha256).digest()

    def valid_account_sql(self, alias="a"):
        return f"""{alias}.needs_nickname=0 AND EXISTS(SELECT 1 FROM legal_consent_events lc
          WHERE lc.account_id={alias}.account_id AND lc.event_id=(SELECT MAX(event_id)
          FROM legal_consent_events WHERE account_id={alias}.account_id)
          AND lc.accepted=1 AND lc.adult_confirmed=1 AND lc.privacy_version=?
          AND lc.terms_version=? AND lc.document_hash=?)"""

    @property
    def legal_args(self):
        return tuple(self.requirements[k] for k in ("privacyVersion", "termsVersion", "documentHash"))

    def check(self, db, user, *, publishing=False):
        self.require_active_session(db, user)
        current = db.execute("SELECT * FROM accounts WHERE account_id=?", (user["account_id"],)).fetchone()
        if current is None:
            raise HTTPException(401, "登录已过期，请重新登录")
        if current["needs_nickname"]:
            raise HTTPException(409, "请先设置昵称")
        if publishing:
            row = db.execute("SELECT muted_until FROM social_restrictions WHERE account_id=?", (user["account_id"],)).fetchone()
            if row and row[0] > int(time.time()):
                raise HTTPException(403, "暂时无法发布社交内容，请查看社区通知")
        return current

    def privacy_post(self, path, payload):
        if not self.settings.voice_bridge_enabled:
            raise HTTPException(503, "隐私设置暂时无法同步，请稍后重试")
        content = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
        headers = signed_headers(self.settings.voice_bridge_secret, path, content)
        headers["Accept-Encoding"] = "identity"
        try:
            with self.bridge.http.stream("POST", self.settings.voice_base_url+path, content=content, headers=headers) as response:
                if response.status_code == 409:
                    raise HTTPException(409, "隐私设置已变化，请刷新后重试")
                if response.status_code == 422:
                    raise HTTPException(422, "无法更新该用户的隐私设置")
                if response.status_code != 200 or response.headers.get("content-encoding", "identity").lower() != "identity":
                    raise ValueError("Unavailable policy")
                body = bytearray()
                for chunk in response.iter_bytes(chunk_size=8192):
                    if len(body)+len(chunk) > MAX_POLICY_BYTES:
                        raise ValueError("Oversized policy")
                    body.extend(chunk)
            result = json.loads(body)
            if not isinstance(result, dict):
                raise ValueError("Invalid policy")
            return result
        except HTTPException:
            raise
        except (httpx.HTTPError, ValueError, TypeError):
            raise HTTPException(503, "隐私设置暂时无法同步，请稍后重试") from None

    def policy(self, user, target_ids=()):
        ids = list(dict.fromkeys(target_ids))
        if len(ids) > 50:
            raise RuntimeError("Policy target batch exceeds50")
        try:
            policy = Policy.model_validate(self.privacy_post(POLICY_PATH, {"accountID":user["login_id"], "targetIDs":ids}))
            if policy.accountID != user["login_id"] or any(room.userID not in ids for room in policy.currentRooms):
                raise ValueError("Policy identity mismatch")
            if len({r.userID for r in policy.currentRooms}) != len(policy.currentRooms):
                raise ValueError("Duplicate room owner")
            if policy.roomsStale and policy.currentRooms:
                raise ValueError("Stale rooms must be absent")
            return policy
        except (ValueError, TypeError):
            raise HTTPException(503, "隐私设置暂时无法同步，请稍后重试") from None

    def cursor(self, user, scope, key=None, value=None):
        if key is not None:
            payload = {"v":1,"u":user["account_id"],"s":scope,"k":key,"exp":int(time.time())+86400}
            raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
            signature = hmac.new(self.cursor_key, b"social-cursor-v1:"+raw, hashlib.sha256).digest()
            return base64.urlsafe_b64encode(raw+signature).rstrip(b"=").decode()
        if value is None:
            return None
        try:
            if len(value) > 1024 or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
                raise ValueError("Invalid cursor")
            packed = base64.urlsafe_b64decode(value+"="*(-len(value)%4))
            raw, signature = packed[:-32], packed[-32:]
            expected = hmac.new(self.cursor_key, b"social-cursor-v1:"+raw, hashlib.sha256).digest()
            obj = json.loads(raw)
            if not isinstance(obj,dict): raise ValueError("Invalid cursor object")
            position = obj.get("k")
            valid_position = (isinstance(position,list) and len(position)==2
                              and type(position[0]) is int and isinstance(position[1],str))
            if scope in {"conversations-v2","inbox-v1"}:
                valid_position = (isinstance(position,list) and len(position)==3
                                  and type(position[0]) is int and position[0] in (0,1)
                                  and type(position[1]) is int and isinstance(position[2],str))
            if (not hmac.compare_digest(expected, signature) or obj.get("v") != 1 or obj.get("u") != user["account_id"]
                    or obj.get("s") != scope or type(obj.get("exp")) is not int or obj["exp"] < int(time.time())
                    or not valid_position):
                raise ValueError("Cursor mismatch")
            return obj["k"]
        except (ValueError, TypeError, KeyError, UnicodeError):
            raise HTTPException(422, "列表位置已失效，请刷新") from None

    def account(self, db, user_id):
        if not re.fullmatch(ID_PATTERN, user_id):
            raise HTTPException(404, "用户不存在或暂不可见")
        row = db.execute(f"SELECT a.* FROM accounts a WHERE a.login_id=? AND {self.valid_account_sql()}",
                         (user_id, *self.legal_args)).fetchone()
        if row is None:
            raise HTTPException(404, "用户不存在或暂不可见")
        return row

    def person(self, db, user, row, policy):
        target, actor = row["account_id"], user["account_id"]
        blocked = set(policy.blockedUserIDs)
        if row["login_id"] in blocked:
            raise HTTPException(404, "用户不存在或暂不可见")
        following = bool(db.execute("SELECT 1 FROM social_follows WHERE follower_id=? AND followed_id=?", (actor,target)).fetchone())
        follows_you = bool(db.execute("SELECT 1 FROM social_follows WHERE follower_id=? AND followed_id=?", (target,actor)).fetchone())
        def count(direction):
            other, owner = ("followed_id", "follower_id") if direction == "following" else ("follower_id", "followed_id")
            rows = db.execute(f"SELECT a.login_id FROM social_follows f JOIN accounts a ON a.account_id=f.{other} WHERE f.{owner}=? AND {self.valid_account_sql()}",
                              (target, *self.legal_args)).fetchall()
            return sum(item[0] not in blocked for item in rows)
        room = next((item.roomID for item in policy.currentRooms if item.userID == row["login_id"]), None)
        return {"id":row["login_id"],"name":row["name"],"bio":row["bio"],"avatarIndex":row["avatar_index"],
                "avatarURL":self.settings.public_base_url.rstrip("/")+"/v1/avatars/"+row["avatar_filename"] if row["avatar_filename"] else None,
                "following":following,"followsYou":follows_you,"mutual":following and follows_you,
                "followingCount":count("following"),"followerCount":count("followers"),"currentRoomID":room}

    def list_people(self, user, query="", kind=None, limit=20, cursor=None):
        if any(unicodedata.category(c) in {"Cc", "Cf", "Cs"} for c in query):
            raise HTTPException(422, "搜索内容格式不正确")
        query = query.strip()
        scope = "people:"+digest({"q":query,"kind":kind})
        key = self.cursor(user, scope, value=cursor)
        with self.database(self.settings) as db:
            self.check(db, user)
            args, join, conditions = [], "", ["a.account_id!=?", self.valid_account_sql()]
            args.extend((user["account_id"], *self.legal_args))
            if kind:
                join = "JOIN social_follows f ON "+("f.followed_id=a.account_id" if kind in {"following","mutual"} else "f.follower_id=a.account_id")
                conditions.append("f.follower_id=?" if kind in {"following","mutual"} else "f.followed_id=?")
                args.append(user["account_id"])
                order = "f.created_at"
                if kind == "mutual":
                    conditions.append("EXISTS(SELECT 1 FROM social_follows back WHERE back.follower_id=a.account_id AND back.followed_id=?)")
                    args.append(user["account_id"])
            else:
                order = "a.created_at"
            if query:
                literal = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                conditions.append("(a.name LIKE ? ESCAPE '\\' OR a.login_id LIKE ? ESCAPE '\\')")
                args.extend(("%"+literal+"%", "%"+literal+"%"))
            if key:
                conditions.append(f"({order}<? OR ({order}=? AND a.login_id<?))")
                args.extend((key[0],key[0],key[1]))
            rows = db.execute(f"SELECT a.*, {order} AS sort_value FROM accounts a {join} WHERE "+" AND ".join(conditions)+
                              f" ORDER BY {order} DESC,a.login_id DESC LIMIT ?", (*args, limit+1)).fetchall()
            candidates = rows[:limit]
        policy = self.policy(user, [row["login_id"] for row in candidates])
        with self.database(self.settings) as db:
            self.check(db, user)
            people = []
            for previous in candidates:
                row = db.execute(f"SELECT a.* FROM accounts a WHERE a.account_id=? AND {self.valid_account_sql()}",
                                 (previous["account_id"],*self.legal_args)).fetchone()
                if row is not None and row["login_id"] not in policy.blockedUserIDs:
                    people.append(self.person(db,user,row,policy))
        next_cursor = self.cursor(user,scope,key=[candidates[-1]["sort_value"],candidates[-1]["login_id"]]) if len(rows)>limit and candidates else None
        return {"people":people,"nextCursor":next_cursor}

    def get_person(self, user, target_id):
        policy = self.policy(user, [target_id] if re.fullmatch(ID_PATTERN,target_id) else [])
        with self.database(self.settings) as db:
            self.check(db,user)
            return {"person":self.person(db,user,self.account(db,target_id),policy)}

    def relation_ids(self, user):
        policy = self.policy(user)
        with self.database(self.settings) as db:
            self.check(db,user)
            me = self.account(db,user["login_id"])
            person = self.person(db,user,me,policy)
            rows = db.execute(f"SELECT a.login_id FROM social_follows f JOIN accounts a ON a.account_id=f.followed_id WHERE f.follower_id=? AND {self.valid_account_sql()} ORDER BY f.created_at DESC,a.login_id DESC",
                              (user["account_id"],*self.legal_args)).fetchall()
            ids = [row[0] for row in rows if row[0] not in policy.blockedUserIDs]
            return {"followingIDs":ids,"followingCount":person["followingCount"],"followerCount":person["followerCount"]}

    def receipt(self, db, user, request_id, content):
        hashed = digest(content)
        row = db.execute("SELECT * FROM social_receipts WHERE actor_id=? AND request_id=?", (user["account_id"],request_id)).fetchone()
        if row and not hmac.compare_digest(row["request_hash"],hashed):
            raise HTTPException(409, "操作编号已用于其他内容，请刷新后重试")
        return row,hashed

    def rate(self, db, user, kind, hourly, daily):
        now = int(time.time())
        hour,day = db.execute("SELECT COALESCE(SUM(created_at>?),0),COUNT(*) FROM social_rate_events WHERE actor_id=? AND kind=? AND created_at>?",
                              (now-3600,user["account_id"],kind,now-86400)).fetchone()
        if hour >= hourly or day >= daily:
            raise HTTPException(429, "操作较多，请稍后再试", headers={"Retry-After":"3600"})
        db.execute("INSERT INTO social_rate_events VALUES(?,?,?,?)", (str(uuid.uuid4()),user["account_id"],kind,now))

    def notice(self, db, recipient, kind, text, actor=None, dedupe=None,moment_id=None):
        now = int(time.time())
        notice_id = str(uuid.uuid4())
        inserted = db.execute("INSERT OR IGNORE INTO social_notifications(id,recipient_id,actor_id,kind,text,created_at,dedupe_key,moment_id) VALUES(?,?,?,?,?,?,?,?)",
                   (notice_id,recipient,actor,kind,text,now,dedupe,moment_id))
        if inserted.rowcount and hasattr(self,"push"):
            self.push.enqueue(db,recipient,"notification",notice_id,actor)

    def follow(self, user, target_id, mutation, enabled):
        policy = self.policy(user,[target_id] if re.fullmatch(ID_PATTERN,target_id) else [])
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            current = self.check(db,user,publishing=enabled)
            purge(db)
            target = self.account(db,target_id)
            if target["account_id"] == user["account_id"]:
                raise HTTPException(422, "不能关注自己")
            if target_id in policy.blockedUserIDs:
                raise HTTPException(404, "用户不存在或暂不可见")
            previous,hashed = self.receipt(db,user,mutation.requestID,{"kind":"follow","target":target_id,"enabled":enabled})
            if not previous:
                self.rate(db,user,"follow",40,100)
                exists = db.execute("SELECT 1 FROM social_follows WHERE follower_id=? AND followed_id=?", (user["account_id"],target["account_id"])).fetchone()
                if enabled and not exists:
                    if db.execute("SELECT COUNT(*) FROM social_follows WHERE follower_id=?", (user["account_id"],)).fetchone()[0]>=1000:
                        raise HTTPException(409, "关注人数已达到1000人")
                    db.execute("INSERT INTO social_follows VALUES(?,?,?)", (user["account_id"],target["account_id"],time.time_ns()))
                    self.notice(db,target["account_id"],"follow","关注了你",user["account_id"],f"follow:{user['account_id']}:{target['account_id']}")
                elif not enabled:
                    db.execute("DELETE FROM social_follows WHERE follower_id=? AND followed_id=?", (user["account_id"],target["account_id"]))
                db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)", (user["account_id"],mutation.requestID,hashed,int(time.time())))
            return {"person":self.person(db,user,target,policy)}

    def block(self, user, target_id, enabled, mutation):
        if not re.fullmatch(ID_PATTERN,target_id) or target_id == user["login_id"]:
            raise HTTPException(422,"不能设置该用户")
        # Fixed stripes bound memory and serialize in-flight privacy writes from
        # one actor without holding a SQLite write transaction over the network.
        stripe = int(hashlib.sha256(user["account_id"].encode()).hexdigest()[:8],16)%len(self.block_locks)
        with self.block_locks[stripe]:
            with self.database(self.settings) as db:
                db.execute("BEGIN IMMEDIATE")
                self.check(db,user)
                purge(db)
                target = self.account(db,target_id)
                old,hashed=self.receipt(db,user,mutation.requestID,{"kind":"block","target":target_id,"enabled":enabled})
                if old is None:
                    self.rate(db,user,"block",40,100)
                    db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",(user["account_id"],mutation.requestID,hashed,int(time.time())))
                    db.execute("INSERT INTO social_block_requests(actor_id,target_id,request_id,blocked,created_at) VALUES(?,?,?,?,?)",(user["account_id"],target["account_id"],mutation.requestID,int(enabled),int(time.time())))
                row=db.execute("SELECT * FROM social_block_requests WHERE actor_id=? AND request_id=?",(user["account_id"],mutation.requestID)).fetchone()
                latest=db.execute("SELECT * FROM social_block_requests WHERE actor_id=? AND target_id=? ORDER BY seq DESC LIMIT 1",(user["account_id"],target["account_id"])).fetchone()
                if row is None:
                    raise HTTPException(409,"隐私操作已过期，请重新操作")
                if row["seq"]<latest["seq"]:
                    if not latest["completed"]:
                        raise HTTPException(409,"有新的隐私设置尚待确认，请重试最新操作")
                    return {"ok":True,"blocked":bool(latest["blocked"])}
                if row["completed"]:
                    return {"ok":True,"blocked":bool(row["blocked"])}
                epoch = db.execute("SELECT MAX(event_id) FROM legal_consent_events WHERE account_id=? AND accepted=1", (user["account_id"],)).fetchone()[0]
                withdrawn = db.execute("SELECT COALESCE(MAX(event_id),0) FROM legal_consent_events WHERE account_id=? AND accepted=0", (user["account_id"],)).fetchone()[0]
            result = self.privacy_post(BLOCK_PATH,{"accountID":user["login_id"],"targetID":target_id,"blocked":enabled,
                                                  "consentEpoch":epoch,"lastWithdrawalEpoch":withdrawn})
            if (set(result)!={"schemaVersion","accountID","targetID","blocked"} or type(result.get("schemaVersion")) is not int or result["schemaVersion"]!=1
                    or result.get("accountID")!=user["login_id"] or result.get("targetID")!=target_id
                    or result.get("blocked") is not enabled):
                raise HTTPException(503,"隐私设置暂时无法同步，请稍后重试")
            with self.database(self.settings) as db:
                db.execute("BEGIN IMMEDIATE")
                self.check(db,user)
                db.execute("UPDATE social_block_requests SET completed=1 WHERE actor_id=? AND request_id=?",(user["account_id"],mutation.requestID))
                if enabled:
                    if hasattr(self,"push"):
                        self.push.cancel_pair(db,user["account_id"],target["account_id"])
                    db.execute("DELETE FROM social_follows WHERE (follower_id=? AND followed_id=?) OR (follower_id=? AND followed_id=?)",
                               (user["account_id"],target["account_id"],target["account_id"],user["account_id"]))
                return {"ok":True,"blocked":enabled}

    def notifications(self, user, limit=20, cursor=None):
        key = self.cursor(user,"notifications",value=cursor)
        with self.database(self.settings) as db:
            self.check(db,user)
            rows = db.execute("SELECT n.*,a.login_id AS actor_public,s.seq FROM social_notifications n JOIN social_notification_sequence s ON s.notification_id=n.id LEFT JOIN accounts a ON a.account_id=n.actor_id WHERE n.recipient_id=? AND n.created_at>? AND s.seq>COALESCE((SELECT cleared_through_seq FROM social_notification_state WHERE account_id=?),0)"+
                              (" AND (n.created_at<? OR (n.created_at=? AND n.id<?))" if key else "")+
                              " ORDER BY n.created_at DESC,n.id DESC LIMIT ?",
                              (user["account_id"],int(time.time())-DAYS,user["account_id"],*((key[0],key[0],key[1]) if key else ()),limit+1)).fetchall()
        candidates = rows[:limit]
        policy = self.policy(user,[row["actor_public"] for row in candidates if row["actor_public"]])
        with self.database(self.settings) as db:
            db.execute("BEGIN")
            self.check(db,user)
            notices=[]
            for row in candidates:
                fresh=db.execute("SELECT 1 FROM social_notifications n JOIN social_notification_sequence s ON s.notification_id=n.id WHERE n.id=? AND n.recipient_id=? AND s.seq>COALESCE((SELECT cleared_through_seq FROM social_notification_state WHERE account_id=?),0)",(row["id"],user["account_id"],user["account_id"])).fetchone()
                if not fresh or row["actor_public"] in policy.blockedUserIDs:
                    continue
                actor = None
                if row["actor_id"]:
                    account = db.execute(f"SELECT a.* FROM accounts a WHERE a.account_id=? AND {self.valid_account_sql()}", (row["actor_id"],*self.legal_args)).fetchone()
                    if account is None:
                        continue
                    actor = self.person(db,user,account,policy)
                notices.append({"id":row["id"],"seq":row["seq"],"kind":row["kind"],"actor":actor,"text":row["text"],"createdAt":row["created_at"],
                                "readAt":row["read_at"],"roomID":None,"momentID":row["moment_id"]})
            unread=self.unread(db,user,policy)
            state=self.notification_inbox_state(db,user,policy)
        return {"notifications":notices,"unreadCount":unread,"nextCursor":self.cursor(user,"notifications",key=[candidates[-1]["created_at"],candidates[-1]["id"]]) if len(rows)>limit and candidates else None,"retentionDays":30,"inboxState":state}

    def notification_state(self,db,user):
        row=db.execute("SELECT is_pinned,cleared_through_seq FROM social_notification_state WHERE account_id=?",(user["account_id"],)).fetchone()
        return row if row is not None else {"is_pinned":0,"cleared_through_seq":0}

    def notification_visible(self,db,row,policy):
        if row["actor_public"] in policy.blockedUserIDs: return False
        return not row["actor_id"] or db.execute("SELECT 1 FROM accounts a WHERE a.account_id=? AND "+self.valid_account_sql(),(row["actor_id"],*self.legal_args)).fetchone() is not None

    def notification_inbox_state(self,db,user,policy):
        state=self.notification_state(db,user)
        rows=db.execute("SELECT n.id,n.actor_id,a.login_id AS actor_public FROM social_notifications n JOIN social_notification_sequence s ON s.notification_id=n.id LEFT JOIN accounts a ON a.account_id=n.actor_id WHERE n.recipient_id=? AND n.created_at>? AND s.seq>? ORDER BY s.seq DESC",(user["account_id"],int(time.time())-DAYS,state["cleared_through_seq"]))
        latest=next((row["id"] for row in rows if self.notification_visible(db,row,policy)),None)
        return {"isPinned":bool(state["is_pinned"]),"isHidden":state["cleared_through_seq"]>0 and latest is None,"throughNotificationID":latest,"clearedThroughSeq":state["cleared_through_seq"]}

    def unread(self, db, user, policy, *, cutoff=None):
        if cutoff is None: cutoff=int(time.time())-DAYS
        rows=db.execute("SELECT n.actor_id,a.login_id AS actor_public FROM social_notifications n JOIN social_notification_sequence s ON s.notification_id=n.id LEFT JOIN accounts a ON a.account_id=n.actor_id WHERE n.recipient_id=? AND n.read_at IS NULL AND n.created_at>? AND s.seq>COALESCE((SELECT cleared_through_seq FROM social_notification_state WHERE account_id=?),0)",(user["account_id"],cutoff,user["account_id"])).fetchall()
        return sum(self.notification_visible(db,row,policy) for row in rows)

    def pin_notifications(self,user,payload):
        self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"notifications-pin","pinned":payload.pinned})
            if old: return {"ok":True}
            self.rate(db,user,"inbox",300,1000)
            db.execute("INSERT INTO social_notification_state(account_id,is_pinned) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET is_pinned=excluded.is_pinned",(user["account_id"],int(payload.pinned)))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",(user["account_id"],payload.requestID,hashed,int(time.time())))
            return {"ok":True}

    def clear_notifications(self,user,payload):
        policy=self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"notifications-clear","throughNotificationID":payload.throughNotificationID})
            if old: return {"ok":True}
            row=db.execute("SELECT s.seq,n.actor_id,a.login_id AS actor_public FROM social_notifications n JOIN social_notification_sequence s ON s.notification_id=n.id LEFT JOIN accounts a ON a.account_id=n.actor_id WHERE n.id=? AND n.recipient_id=? AND n.created_at>?",(payload.throughNotificationID,user["account_id"],int(time.time())-DAYS)).fetchone()
            if row is None or not self.notification_visible(db,row,policy): raise HTTPException(404,"通知不存在或已过期")
            self.rate(db,user,"inbox",300,1000)
            db.execute("INSERT INTO social_notification_state(account_id,is_pinned,cleared_through_seq) VALUES(?,0,?) ON CONFLICT(account_id) DO UPDATE SET is_pinned=0,cleared_through_seq=MAX(cleared_through_seq,excluded.cleared_through_seq)",(user["account_id"],row["seq"]))
            db.execute("UPDATE social_notifications SET read_at=? WHERE recipient_id=? AND read_at IS NULL AND id IN (SELECT notification_id FROM social_notification_sequence WHERE seq<=?)",(int(time.time()),user["account_id"],row["seq"]))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",(user["account_id"],payload.requestID,hashed,int(time.time())))
            return {"ok":True}

    def delete_notification(self,user,notification_id,payload):
        content={"kind":"notification-delete","notificationID":notification_id}
        # The source row is gone after success. Check the authenticated receipt
        # first so an ambiguous retry cannot fail or touch a newer notification.
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            old,_=self.receipt(db,user,payload.requestID,content)
            if old: return {"ok":True}
        policy=self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            old,hashed=self.receipt(db,user,payload.requestID,content)
            if old: return {"ok":True}
            row=db.execute("SELECT n.actor_id,a.login_id AS actor_public FROM social_notifications n LEFT JOIN accounts a ON a.account_id=n.actor_id WHERE n.id=? AND n.recipient_id=? AND n.created_at>?",(notification_id,user["account_id"],int(time.time())-DAYS)).fetchone()
            if row is None or not self.notification_visible(db,row,policy):
                raise HTTPException(404,"通知不存在或暂不可见")
            self.rate(db,user,"inbox",300,1000)
            # Outbox sources intentionally have no FK: retain accepted delivery
            # receipts, but revoke pending/leased sends in this same transaction.
            if hasattr(self,"push"):
                db.execute("UPDATE push_outbox SET state='cancelled',completed_at=?,lease_id=NULL,lease_until=NULL WHERE recipient_id=? AND event_kind='notification' AND source_id=? AND state IN ('pending','sending')",(int(time.time()),user["account_id"],notification_id))
            db.execute("DELETE FROM social_notifications WHERE id=? AND recipient_id=?",(notification_id,user["account_id"]))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",(user["account_id"],payload.requestID,hashed,int(time.time())))
            return {"ok":True}

    def read_notifications(self,user,payload):
        policy=self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            if payload.all:
                db.execute("UPDATE social_notifications SET read_at=? WHERE recipient_id=? AND read_at IS NULL",(int(time.time()),user["account_id"]))
            else:
                marks=",".join("?" for _ in payload.ids)
                db.execute(f"UPDATE social_notifications SET read_at=? WHERE recipient_id=? AND id IN ({marks}) AND read_at IS NULL",(int(time.time()),user["account_id"],*payload.ids))
            return {"unreadCount":self.unread(db,user,policy)}

    def inbox_consent_epoch(self,db,user):
        return db.execute("SELECT MAX(event_id) FROM legal_consent_events WHERE account_id=?",
                          (user["account_id"],)).fetchone()[0]

    def inbox_snapshot(self,user):
        self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN")
            self.check(db,user)
            payload={"v":1,"u":user["account_id"],"e":self.inbox_consent_epoch(db,user),
                     "n":db.execute("SELECT COALESCE(MAX(seq),0) FROM social_notification_sequence").fetchone()[0],
                     "m":db.execute("SELECT COALESCE(MAX(seq),0) FROM social_messages").fetchone()[0],
                     "exp":int(time.time())+600}
        raw=json.dumps(payload,sort_keys=True,separators=(",",":")).encode()
        signature=hmac.new(self.cursor_key,b"inbox-snapshot-v1:"+raw,hashlib.sha256).digest()
        return {"snapshot":base64.urlsafe_b64encode(raw+signature).rstrip(b"=").decode()}

    def read_inbox_snapshot(self,db,user,value):
        try:
            if len(value)>1024 or not re.fullmatch(r"[A-Za-z0-9_-]+",value): raise ValueError("Invalid snapshot")
            packed=base64.urlsafe_b64decode(value+"="*(-len(value)%4))
            raw,signature=packed[:-32],packed[-32:]
            expected=hmac.new(self.cursor_key,b"inbox-snapshot-v1:"+raw,hashlib.sha256).digest()
            obj=json.loads(raw)
            if (not hmac.compare_digest(expected,signature) or not isinstance(obj,dict)
                    or set(obj)!={"v","u","e","n","m","exp"} or type(obj["v"]) is not int or obj["v"]!=1
                    or obj["u"]!=user["account_id"] or type(obj["e"]) is not int
                    or obj["e"]!=self.inbox_consent_epoch(db,user)
                    or any(type(obj[key]) is not int or obj[key]<0 for key in ("n","m","exp"))
                    or obj["exp"]<int(time.time())):
                raise ValueError("Snapshot mismatch")
            return obj
        except (ValueError,TypeError,KeyError,UnicodeError):
            raise HTTPException(422,"消息快照已失效，请刷新后重试") from None

    def mutate_inbox(self,user,payload,*,clear):
        content={"kind":"inbox-clear" if clear else "inbox-read","snapshot":payload.snapshot}
        # Completed retries do not reapply a watermark, or fail merely because
        # the confirmation token has since expired. Auth/current consent still
        # precede receipt lookup; withdrawal also erases these receipts.
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            old,_=self.receipt(db,user,payload.requestID,content)
            if old: return {"ok":True}
        self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            old,hashed=self.receipt(db,user,payload.requestID,content)
            if old: return {"ok":True}
            snapshot=self.read_inbox_snapshot(db,user,payload.snapshot)
            self.rate(db,user,"inbox",300,1000)
            self.mutate_inbox_history(db,user,snapshot,clear=clear)
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",
                       (user["account_id"],payload.requestID,hashed,int(time.time())))
            return {"ok":True}


def build_router(app, *, consented_user):
    router=APIRouter(prefix="/v1/social")

    def social_user(user=Depends(consented_user)):
        if app.state.settings.rate_limit_enabled:
            app.state.social.limits.check(("social-read",user["account_id"]),120,60)
        return user

    @router.get("/people")
    def people(query:str=Query(default="",max_length=80),limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.list_people(user,query=query,limit=limit,cursor=cursor)

    @router.get("/people/{target_id}")
    def person(target_id:str,user=Depends(social_user)):
        return app.state.social.get_person(user,target_id)

    @router.get("/relationships/ids")
    def ids(user=Depends(social_user)):
        return app.state.social.relation_ids(user)

    @router.get("/relationships")
    def relationships(kind:Literal["following","followers","mutual"]="following",limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.list_people(user,kind=kind,limit=limit,cursor=cursor)

    @router.put("/follows/{target_id}")
    def follow(target_id:str,payload:Mutation,user=Depends(social_user)):
        return app.state.social.follow(user,target_id,payload,True)

    @router.delete("/follows/{target_id}")
    def unfollow(target_id:str,payload:Mutation,user=Depends(social_user)):
        return app.state.social.follow(user,target_id,payload,False)

    @router.put("/blocks/{target_id}")
    def block(target_id:str,payload:Mutation,user=Depends(social_user)):
        return app.state.social.block(user,target_id,True,payload)

    @router.delete("/blocks/{target_id}")
    def unblock(target_id:str,payload:Mutation,user=Depends(social_user)):
        return app.state.social.block(user,target_id,False,payload)

    @router.get("/notifications")
    def notifications(limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.notifications(user,limit,cursor)

    @router.get("/inbox")
    def inbox(limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.inbox(user,limit,cursor)

    @router.get("/inbox/snapshot")
    def inbox_snapshot(user=Depends(social_user)):
        return app.state.social.inbox_snapshot(user)

    @router.post("/inbox/read")
    def read_inbox(payload:InboxMutation,user=Depends(social_user)):
        return app.state.social.mutate_inbox(user,payload,clear=False)

    @router.post("/inbox/clear")
    def clear_inbox(payload:InboxMutation,user=Depends(social_user)):
        return app.state.social.mutate_inbox(user,payload,clear=True)

    @router.post("/notifications/read")
    def read_notifications(payload:ReadNotifications,user=Depends(social_user)):
        return app.state.social.read_notifications(user,payload)

    @router.put("/notifications/pin")
    def pin_notifications(payload:NotificationPin,user=Depends(social_user)):
        return app.state.social.pin_notifications(user,payload)

    @router.post("/notifications/clear")
    def clear_notifications(payload:NotificationClear,user=Depends(social_user)):
        return app.state.social.clear_notifications(user,payload)

    @router.delete("/notifications/{notification_id}")
    def delete_notification(notification_id:uuid.UUID,payload:Mutation,user=Depends(social_user)):
        return app.state.social.delete_notification(user,str(notification_id),payload)

    install_content_routes(router,app,social_user)
    return router


def metrics(db,now=None):
    """Aggregate product counts only; ordinary account viewers never receive cases."""
    now=int(time.time()) if now is None else now
    scalar=lambda sql,args=():db.execute(sql,args).fetchone()[0]
    return {"follows":scalar("SELECT COUNT(*) FROM social_follows"),
            "mutualPairs":scalar("SELECT COUNT(*) FROM social_follows f WHERE f.follower_id<f.followed_id AND EXISTS(SELECT 1 FROM social_follows b WHERE b.follower_id=f.followed_id AND b.followed_id=f.follower_id)"),
            "moments":scalar("SELECT COUNT(*) FROM social_moments"),
            "comments":scalar("SELECT COUNT(*) FROM social_comments"),
            "privateMedia":scalar("SELECT COUNT(*) FROM social_media"),
            "messagesLast30Days":scalar("SELECT COUNT(*) FROM social_messages WHERE created_at>?",(now-DAYS,)),
            "pendingReports":scalar("SELECT COUNT(*) FROM social_reports WHERE status='pending' AND created_at>?",(now-DAYS,)),
            "activePostingRestrictions":scalar("SELECT COUNT(*) FROM social_restrictions WHERE muted_until>?",(now,)),
            "note":"账号服务社交汇总；动态/关系为当前保留总量，私聊为滚动30天。举报证据需独立社区管理权限；以上不包含语聊在线人数或外部推送投递。"}
