"""Native APNs with account/session scoped bindings and a durable bounded outbox.

Routing metadata contains only opaque references. Alert previews are resolved
from current authorized content and the recipient's latest privacy preference;
message text and APNs tokens are never stored in the outbox or emitted in logs.
APNs acceptance is not a read/delivery receipt; ambiguous retries may duplicate alerts.
"""
import hashlib
import hmac
import json
import logging
from pathlib import Path
import re
import secrets
import threading
import time
from typing import Literal
import uuid

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter, Depends, HTTPException
import httpx
import jwt
from pydantic import BaseModel, ConfigDict, Field

class TokenRedaction(logging.Filter):
    def filter(self, record):
        message = record.getMessage()
        if "push.apple.com" in message or "/3/device/" in message:
            record.msg = re.sub(r"(/3/device/)[a-fA-F0-9]+",r"\1<redacted>",message)
            record.args = ()
        return True


# httpx's INFO request log contains the device URL. HTTP/2 debug traces may
# contain compressed authorization headers, so retain only warning/error there.
logging.getLogger("httpx").addFilter(TokenRedaction())
for _logger in ("httpcore", "hpack", "h2"):
    logging.getLogger(_logger).setLevel(logging.WARNING)

TOPIC = "com.kikitalk.demo"
DAY = 86400
BINDING_TTL = 30 * DAY
PENDING_TTL = DAY
RECEIPT_TTL = 7 * DAY
HOSTS = {"sandbox":"https://api.sandbox.push.apple.com", "production":"https://api.push.apple.com"}
GENERIC_ALERT = {"title":"Kiki语聊","body":"你有新的消息，请打开应用查看。"}
MAX_ALERT_TITLE_BYTES = 160
MAX_ALERT_BODY_BYTES = 2048
MAX_PAYLOAD_BYTES = 4096
SCHEMA = """
CREATE TABLE IF NOT EXISTS push_installations (
 installation_hash TEXT PRIMARY KEY, revision INTEGER NOT NULL, request_hash TEXT NOT NULL,
 session_hash TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS push_devices (
 id TEXT PRIMARY KEY, installation_hash TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL,
 generation TEXT NOT NULL UNIQUE, account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
 environment TEXT NOT NULL, token_hash TEXT NOT NULL, token_encrypted TEXT NOT NULL,
 permission TEXT NOT NULL, created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL,
 UNIQUE(environment,token_hash));
CREATE INDEX IF NOT EXISTS push_devices_account ON push_devices(account_id);
CREATE TABLE IF NOT EXISTS push_outbox (
 id TEXT PRIMARY KEY, event_id TEXT NOT NULL, event_kind TEXT NOT NULL,
 recipient_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 actor_id TEXT REFERENCES accounts(account_id) ON DELETE CASCADE,
 binding_id TEXT NOT NULL, binding_generation TEXT NOT NULL, source_id TEXT NOT NULL,
 created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
 state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL,
 lease_id TEXT, lease_until INTEGER, completed_at INTEGER, error_code TEXT,
 UNIQUE(event_kind,event_id,binding_generation));
CREATE INDEX IF NOT EXISTS push_due ON push_outbox(state,next_attempt_at);
"""


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class DeviceRegistration(Model):
    token: str = Field(pattern=r"^[a-fA-F0-9]{2,512}$")
    environment: Literal["sandbox","production"]
    revision: int = Field(strict=True, ge=1, le=9223372036854775807)
    permission: Literal["authorized","provisional","denied"]


class DeviceRemoval(Model):
    revision: int = Field(strict=True, ge=1, le=9223372036854775807)


def identifier(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(422,"通知标识格式不正确") from None


def preview_text(value, maximum):
    encoded=value.encode("utf-8")
    if len(encoded)<=maximum:return value
    return encoded[:max(0,maximum-3)].decode("utf-8",errors="ignore")+"…"


def validate_settings(settings):
    if not settings.apns_enabled:
        return
    if not re.fullmatch(r"[A-Z0-9]{10}",settings.apns_team_id):
        raise RuntimeError("APNs team configuration is incomplete")
    for env in HOSTS:
        kid = getattr(settings,f"apns_{env}_key_id")
        path = getattr(settings,f"apns_{env}_private_key_path")
        if not re.fullmatch(r"[A-Z0-9]{10}",kid) or not Path(path).is_absolute():
            raise RuntimeError("APNs environment configuration is incomplete")
        if kid == settings.apple_key_id or Path(path) == Path(settings.apple_private_key_path):
            raise RuntimeError("APNs must use an independent notification key")
    try:
        Fernet(settings.apple_token_encryption_key.encode())
    except Exception:
        raise RuntimeError("APNs token encryption is not configured") from None


def initialize(db):
    db.executescript(SCHEMA)
    purge(db)


def purge(db, now=None):
    now = int(time.time()) if now is None else now
    db.execute("DELETE FROM push_devices WHERE last_seen<=? OR NOT EXISTS(SELECT 1 FROM sessions s WHERE s.token_hash=push_devices.session_hash AND s.expires_at>?)",(now-BINDING_TTL,now))
    db.execute("UPDATE push_outbox SET state='cancelled',completed_at=?,lease_id=NULL,lease_until=NULL WHERE state IN ('pending','sending') AND NOT EXISTS(SELECT 1 FROM push_devices d WHERE d.id=push_outbox.binding_id AND d.generation=push_outbox.binding_generation)",(now,))
    db.execute("UPDATE push_outbox SET state='failed',completed_at=?,error_code='expired',lease_id=NULL,lease_until=NULL WHERE state IN ('pending','sending') AND expires_at<=?",(now,now))
    db.execute("DELETE FROM push_outbox WHERE created_at<=?",(now-RECEIPT_TTL,))
    db.execute("DELETE FROM push_installations WHERE updated_at<=?",(now-BINDING_TTL,))


def erase(db, account_id):
    db.execute("DELETE FROM push_outbox WHERE recipient_id=? OR actor_id=?",(account_id,account_id))
    # Keep only the anonymous installation revision watermark, so a delayed
    # registration cannot resurrect a withdrawn account's old binding.
    db.execute("DELETE FROM push_devices WHERE account_id=?",(account_id,))


def metrics(db, settings, now):
    valid = """a.needs_nickname=0 AND EXISTS(SELECT 1 FROM legal_consent_events l WHERE l.account_id=a.account_id
     AND l.event_id=(SELECT MAX(event_id) FROM legal_consent_events WHERE account_id=a.account_id)
     AND l.accepted=1 AND l.adult_confirmed=1 AND l.privacy_version=? AND l.terms_version=? AND l.document_hash=?)"""
    # Imported lazily to avoid the account app's dependency cycle.
    from .main import load_legal_requirements
    legal = load_legal_requirements()
    args = tuple(legal[k] for k in ("privacyVersion","termsVersion","documentHash"))
    active = db.execute("SELECT COUNT(*) FROM push_devices d JOIN sessions s ON s.token_hash=d.session_hash JOIN accounts a ON a.account_id=d.account_id WHERE d.last_seen>? AND s.expires_at>? AND d.permission IN ('authorized','provisional') AND "+valid,(int(now)-BINDING_TTL,int(now),*args)).fetchone()[0]
    counts = {row["state"]:row["n"] for row in db.execute("SELECT state,COUNT(*) n FROM push_outbox WHERE (state IN ('pending','sending') AND expires_at>?) OR completed_at>? GROUP BY state",(now,now-DAY))}
    failures = [{"code":row["error_code"] or "unknown","occurredAt":row["completed_at"]} for row in db.execute("SELECT error_code,completed_at FROM push_outbox WHERE state='failed' AND completed_at>? ORDER BY completed_at DESC LIMIT 10",(now-DAY,))]
    configured = bool(settings.apns_team_id and all(getattr(settings,f"apns_{env}_key_id") and getattr(settings,f"apns_{env}_private_key_path") for env in HOSTS))
    return {"schemaVersion":1,"configured":configured,"enabled":settings.apns_enabled,"activeDevices":active,"pending":counts.get("pending",0)+counts.get("sending",0),"accepted":counts.get("accepted",0),"failed":counts.get("failed",0),"recentFailures":failures}


class PushService:
    def __init__(self, settings, database, social, limits):
        self.settings,self.database,self.social,self.limits = settings,database,social,limits
        self.has_storage_key = bool(settings.apple_token_encryption_key)
        material = settings.apple_token_encryption_key.encode() if self.has_storage_key else Fernet.generate_key()
        self.cipher = Fernet(material)
        self.key = hmac.new(material,b"kiki-apns-index-v1",hashlib.sha256).digest()
        self.http = None
        self.provider_tokens = {}
        self.token_lock = threading.Lock()
        self.worker_lock = threading.Lock()
        self.clock = time.time

    def close(self):
        if self.http is not None:
            self.http.close()
        self.provider_tokens.clear()

    def hashed(self, value):
        return hmac.new(self.key,value.encode(),hashlib.sha256).hexdigest()

    def account_tag(self, account_id):
        return self.hashed("account:"+account_id)

    def register(self,user,installation,payload):
        if not self.has_storage_key:
            raise HTTPException(503,"系统通知尚未配置")
        installation = self.hashed("installation:"+identifier(installation))
        now = int(self.clock())
        token = payload.token.lower()
        if len(token)%2:
            raise HTTPException(422,"通知凭证格式不正确")
        request_hash = self.hashed(json.dumps([user["account_id"],user["token_hash"],token,payload.environment,payload.permission],separators=(",",":")))
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.social.check(db,user)
            purge(db,now)
            old = db.execute("SELECT * FROM push_installations WHERE installation_hash=?",(installation,)).fetchone()
            if old and (payload.revision<old["revision"] or payload.revision==old["revision"] and not hmac.compare_digest(request_hash,old["request_hash"])):
                raise HTTPException(409,"通知设备状态已更新，请重新同步")
            if old and payload.revision==old["revision"]:
                exists=db.execute("SELECT 1 FROM push_devices WHERE installation_hash=? AND session_hash=? AND revision=?",(installation,user["token_hash"],payload.revision)).fetchone()
                return {"ok":True,"accountTag":self.account_tag(user["account_id"]),"registered":bool(exists)}
            self.limits.check(("push-register",user["token_hash"]),30,60)
            db.execute("INSERT INTO push_installations VALUES(?,?,?,?,?) ON CONFLICT(installation_hash) DO UPDATE SET revision=excluded.revision,request_hash=excluded.request_hash,session_hash=excluded.session_hash,updated_at=excluded.updated_at",(installation,payload.revision,request_hash,user["token_hash"],now))
            db.execute("DELETE FROM push_devices WHERE installation_hash=? OR (environment=? AND token_hash=?)",(installation,payload.environment,self.hashed(token)))
            if payload.permission!="denied":
                count=db.execute("SELECT COUNT(*) FROM push_devices WHERE account_id=?",(user["account_id"],)).fetchone()[0]
                if count>=10:
                    raise HTTPException(409,"通知设备已达到10台，请先退出其他设备")
                db.execute("INSERT INTO push_devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",(str(uuid.uuid4()),installation,payload.revision,str(uuid.uuid4()),user["account_id"],user["token_hash"],payload.environment,self.hashed(token),self.cipher.encrypt(token.encode()).decode(),payload.permission,now,now))
            purge(db,now)
        return {"ok":True,"accountTag":self.account_tag(user["account_id"]),"registered":payload.permission!="denied"}

    def unregister(self,user,installation,payload):
        installation=self.hashed("installation:"+identifier(installation))
        now=int(self.clock())
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.social.require_active_session(db,user,require_consent=False)
            old=db.execute("SELECT * FROM push_installations WHERE installation_hash=?",(installation,)).fetchone()
            # A stale logout must not erase a new session's binding or revision.
            if old and old["session_hash"]!=user["token_hash"]:
                return {"ok":True}
            if old and payload.revision<old["revision"]:
                return {"ok":True}
            digest=self.hashed("removed:"+user["token_hash"])
            db.execute("INSERT INTO push_installations VALUES(?,?,?,?,?) ON CONFLICT(installation_hash) DO UPDATE SET revision=excluded.revision,request_hash=excluded.request_hash,session_hash=excluded.session_hash,updated_at=excluded.updated_at",(installation,payload.revision,digest,user["token_hash"],now))
            db.execute("DELETE FROM push_devices WHERE installation_hash=? AND session_hash=?",(installation,user["token_hash"]))
            purge(db,now)
        return {"ok":True}

    def cancel_pair(self,db,first,second,dm_only=False):
        db.execute("UPDATE push_outbox SET state='cancelled',completed_at=?,lease_id=NULL,lease_until=NULL WHERE state IN ('pending','sending') AND ((recipient_id=? AND actor_id=?) OR (recipient_id=? AND actor_id=?))"+(" AND event_kind='direct_message'" if dm_only else ""),(int(self.clock()),first,second,second,first))

    def enqueue(self,db,recipient,kind,source_id,actor=None):
        if not self.settings.apns_enabled:
            return
        now=int(self.clock())
        target=db.execute("SELECT notifications FROM accounts WHERE account_id=?",(recipient,)).fetchone()
        if target is None or not target[0]:return
        for binding in db.execute("SELECT d.* FROM push_devices d JOIN sessions s ON s.token_hash=d.session_hash WHERE d.account_id=? AND d.last_seen>? AND s.expires_at>? AND d.permission IN ('authorized','provisional')",(recipient,now-BINDING_TTL,now)).fetchall():
            db.execute("INSERT OR IGNORE INTO push_outbox(id,event_id,event_kind,recipient_id,actor_id,binding_id,binding_generation,source_id,created_at,expires_at,state,next_attempt_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",(str(uuid.uuid4()),source_id,kind,recipient,actor,binding["id"],binding["generation"],source_id,now,now+PENDING_TTL,"pending",now))

    def binding(self,db,row):
        return db.execute("SELECT d.*,a.*,s.expires_at,s.token_hash AS source_session_hash FROM push_devices d JOIN sessions s ON s.token_hash=d.session_hash JOIN accounts a ON a.account_id=d.account_id WHERE d.id=? AND d.generation=? AND d.account_id=? AND d.last_seen>? AND s.expires_at>? AND a.notifications=1 AND d.permission IN ('authorized','provisional') AND "+self.social.valid_account_sql(),(row["binding_id"],row["binding_generation"],row["recipient_id"],int(self.clock())-BINDING_TTL,int(self.clock()),*self.social.legal_args)).fetchone()

    def destination(self,db,user,row,policy,*,must_unread=True):
        if row["recipient_id"]!=user["account_id"]:return None
        actor=None
        if row["actor_id"]:
            actor=db.execute("SELECT a.* FROM accounts a WHERE account_id=? AND "+self.social.valid_account_sql(),(row["actor_id"],*self.social.legal_args)).fetchone()
            if actor is None or actor["login_id"] in policy.blockedUserIDs:return None
        if row["event_kind"]=="direct_message":
            message=db.execute("SELECT * FROM social_messages WHERE id=? AND recipient_id=? AND created_at>?",(row["source_id"],user["account_id"],int(self.clock())-30*DAY)).fetchone()
            if message is None or actor is None or message["sender_id"]!=actor["account_id"]:return None
            if message["seq"]<=self.social.conversation_state(db,user,message["conversation_id"])["cleared_through_seq"]:return None
            if must_unread:
                read=db.execute("SELECT through_seq FROM social_reads WHERE conversation_id=? AND account_id=?",(message["conversation_id"],user["account_id"])).fetchone()
                if read and read[0]>=message["seq"]:return None
            return {"type":"direct_message","personID":actor["login_id"]}
        notice=db.execute("SELECT * FROM social_notifications WHERE id=? AND recipient_id=? AND created_at>?",(row["source_id"],user["account_id"],int(self.clock())-30*DAY)).fetchone()
        if notice is None or must_unread and notice["read_at"] is not None:return None
        sequence=db.execute("SELECT seq FROM social_notification_sequence WHERE notification_id=?",(notice["id"],)).fetchone()
        if sequence is None or sequence["seq"]<=self.social.notification_state(db,user)["cleared_through_seq"]:return None
        result={"type":"notification","notificationID":notice["id"]}
        if notice["moment_id"]:
            moment=db.execute("SELECT p.*,a.login_id FROM social_moments p JOIN accounts a ON a.account_id=p.author_id WHERE p.id=? AND "+self.social.valid_account_sql(),(notice["moment_id"],*self.social.legal_args)).fetchone()
            if moment is None or moment["login_id"] in policy.blockedUserIDs:return None
            if notice["dedupe_key"] and notice["dedupe_key"].startswith("comment:"):
                if not db.execute("SELECT 1 FROM social_comments WHERE id=? AND moment_id=?",(notice["dedupe_key"][8:],moment["id"])).fetchone():return None
            if notice["dedupe_key"] and notice["dedupe_key"].startswith("like:"):
                if actor is None or not db.execute("SELECT 1 FROM social_likes WHERE moment_id=? AND actor_id=?",(moment["id"],actor["account_id"])).fetchone():return None
            result["momentID"]=notice["moment_id"]
        elif actor:
            if notice["kind"]=="follow" and not db.execute("SELECT 1 FROM social_follows WHERE follower_id=? AND followed_id=?",(actor["account_id"],user["account_id"])).fetchone():return None
            result["personID"]=actor["login_id"]
        return result

    def badge(self,db,user,policy):
        count=0
        for notice in db.execute("SELECT n.id,n.actor_id,a.login_id FROM social_notifications n JOIN social_notification_sequence s ON s.notification_id=n.id LEFT JOIN accounts a ON a.account_id=n.actor_id WHERE recipient_id=? AND read_at IS NULL AND n.created_at>? AND s.seq>COALESCE((SELECT cleared_through_seq FROM social_notification_state WHERE account_id=?),0)",(user["account_id"],int(self.clock())-30*DAY,user["account_id"])):
            if notice["actor_id"] and (notice["login_id"] in policy.blockedUserIDs or not db.execute("SELECT 1 FROM accounts a WHERE a.account_id=? AND "+self.social.valid_account_sql(),(notice["actor_id"],*self.social.legal_args)).fetchone()):continue
            count+=1
        for item in db.execute("SELECT m.sender_id,a.login_id,COUNT(*) n FROM social_messages m JOIN accounts a ON a.account_id=m.sender_id LEFT JOIN social_reads r ON r.conversation_id=m.conversation_id AND r.account_id=m.recipient_id LEFT JOIN social_conversation_state s ON s.conversation_id=m.conversation_id AND s.account_id=m.recipient_id WHERE m.recipient_id=? AND m.created_at>? AND m.seq>MAX(COALESCE(r.through_seq,0),COALESCE(s.cleared_through_seq,0)) AND "+self.social.valid_account_sql()+" GROUP BY m.sender_id,a.login_id",(user["account_id"],int(self.clock())-30*DAY,*self.social.legal_args)):
            if item["login_id"] not in policy.blockedUserIDs:count+=item["n"]
        return min(9999,count)

    def notification_payload(self,db,user,row,badge):
        # Called only after destination authorization, in the same DB snapshot.
        # No preview is cached with the queued delivery or its retry receipt.
        alert=dict(GENERIC_ALERT)
        if not user["hide_notification_content"]:
            actor=db.execute("SELECT name FROM accounts WHERE account_id=?",(row["actor_id"],)).fetchone() if row["actor_id"] else None
            if actor:alert["title"]=actor["name"]
            if row["event_kind"]=="direct_message":
                source=db.execute("SELECT text FROM social_messages WHERE id=? AND recipient_id=?",(row["source_id"],user["account_id"])).fetchone()
                if source:alert["body"]=source["text"]
            else:
                notice=db.execute("SELECT * FROM social_notifications WHERE id=? AND recipient_id=?",(row["source_id"],user["account_id"])).fetchone()
                if notice:
                    alert["body"]=notice["text"]
                    if notice["dedupe_key"] and notice["dedupe_key"].startswith("comment:"):
                        comment=db.execute("SELECT text FROM social_comments WHERE id=? AND moment_id=? AND author_id=?",(notice["dedupe_key"][8:],notice["moment_id"],row["actor_id"])).fetchone()
                        if comment:alert["body"]+="："+comment["text"]
        alert={"title":preview_text(alert["title"],MAX_ALERT_TITLE_BYTES),"body":preview_text(alert["body"],MAX_ALERT_BODY_BYTES)}
        payload={"aps":{"alert":alert,"sound":"default","badge":badge},"deliveryID":row["id"],"accountTag":self.account_tag(row["recipient_id"])}
        # JSON escaping also consumes APNs' byte budget (quotes, newlines, etc.).
        while len(json.dumps(payload,ensure_ascii=False,separators=(",",":"),allow_nan=False).encode("utf-8"))>MAX_PAYLOAD_BYTES:
            alert["body"]=preview_text(alert["body"],max(3,len(alert["body"].encode("utf-8"))-128))
        return payload

    def status(self,user):
        policy=self.social.policy(user)
        with self.database(self.settings) as db:
            current=self.social.check(db,user)
            registered=db.execute("SELECT 1 FROM push_devices WHERE session_hash=? AND last_seen>? AND permission IN ('authorized','provisional')",(user["token_hash"],int(self.clock())-BINDING_TTL)).fetchone()
            return {"enabled":bool(current["notifications"]),"registered":bool(registered),"badgeCount":self.badge(db,user,policy),"accountTag":self.account_tag(user["account_id"]),"hideNotificationContent":bool(current["hide_notification_content"])}

    def resolve(self,user,delivery_id):
        delivery_id=identifier(delivery_id)
        policy=self.social.policy(user)
        with self.database(self.settings) as db:
            self.social.check(db,user)
            row=db.execute("SELECT * FROM push_outbox WHERE id=? AND recipient_id=? AND created_at>? AND state IN ('sending','accepted','pending')",(delivery_id,user["account_id"],int(self.clock())-RECEIPT_TTL)).fetchone()
            result=self.destination(db,user,row,policy) if row else None
            if not result:raise HTTPException(404,"通知已失效或暂不可见")
            return result

    def provider_token(self,environment):
        now=int(self.clock())
        with self.token_lock:
            cached=self.provider_tokens.get(environment)
            if cached and 0<=now-cached[0]<3000:return cached[1]
            path=getattr(self.settings,f"apns_{environment}_private_key_path")
            key=serialization.load_pem_private_key(Path(path).read_bytes(),password=None)
            if not isinstance(key,ec.EllipticCurvePrivateKey) or not isinstance(key.curve,ec.SECP256R1):
                raise ValueError("Invalid APNs provider key")
            value=jwt.encode({"iss":self.settings.apns_team_id,"iat":now},key,algorithm="ES256",headers={"kid":getattr(self.settings,f"apns_{environment}_key_id")})
            self.provider_tokens[environment]=(now,value)
            return value

    def claim(self):
        now=int(self.clock())
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            purge(db,now)
            row=db.execute("SELECT * FROM push_outbox WHERE expires_at>? AND next_attempt_at<=? AND (state='pending' OR (state='sending' AND lease_until<=?)) ORDER BY created_at,id LIMIT 1",(now,now,now)).fetchone()
            if row is None:return None
            lease=secrets.token_hex(16)
            db.execute("UPDATE push_outbox SET state='sending',lease_id=?,lease_until=?,attempts=attempts+1 WHERE id=?",(lease,now+120,row["id"]))
            return dict(db.execute("SELECT * FROM push_outbox WHERE id=?",(row["id"],)).fetchone())

    def finish(self,row,state,code=None,retry_after=None,invalid=False,invalid_at=None):
        now=int(self.clock())
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            if not db.execute("SELECT 1 FROM push_outbox WHERE id=? AND lease_id=? AND state='sending'",(row["id"],row["lease_id"])).fetchone():return
            if state=="pending" and (row["expires_at"]<=now or row["attempts"]>=24):state,code="failed","expired"
            delay=min(3600,max(15,30*2**min(row["attempts"]-1,7)))
            if retry_after is not None:delay=min(3600,max(delay,retry_after))
            db.execute("UPDATE push_outbox SET state=?,error_code=?,next_attempt_at=?,completed_at=?,lease_id=NULL,lease_until=NULL WHERE id=? AND lease_id=?",(state,code,now+delay,now if state!="pending" else None,row["id"],row["lease_id"]))
            if invalid:
                db.execute("DELETE FROM push_devices WHERE id=? AND generation=?"+(" AND created_at<=?" if invalid_at is not None else ""),(row["binding_id"],row["binding_generation"],*((invalid_at,) if invalid_at is not None else ())))

    def send_one(self,row):
        with self.database(self.settings) as db:
            binding=self.binding(db,row)
            user=dict(binding) if binding else None
            if user is not None:user["token_hash"]=user["source_session_hash"]
        if user is None:
            self.finish(row,"cancelled");return
        try:
            policy=self.social.policy(user)
        except Exception:
            self.finish(row,"pending","privacy_unavailable");return
        try:
            environment=user["environment"]
            provider=self.provider_token(environment)
            token=self.cipher.decrypt(user["token_encrypted"].encode()).decode()
            if self.http is None:self.http=httpx.Client(http2=True,timeout=httpx.Timeout(8,connect=3),trust_env=False,follow_redirects=False)
        except (OSError,ValueError,TypeError):
            self.finish(row,"pending","provider_auth");return
        except Exception:
            self.finish(row,"pending","transport_error");return
        with self.database(self.settings) as db:
            now=int(self.clock())
            purge(db,now)
            binding=self.binding(db,row)
            active = db.execute("SELECT 1 FROM push_outbox WHERE id=? AND state='sending' AND lease_id=? AND expires_at>? AND lease_until>?",(row["id"],row["lease_id"],now,now)).fetchone()
            valid = binding is not None and active is not None and self.destination(db,user,row,policy) is not None
            if valid:
                badge=self.badge(db,user,policy)
                payload=self.notification_payload(db,binding,row,badge)
        if not valid:
            if row["expires_at"]<=int(self.clock()):self.finish(row,"failed","expired")
            elif row["lease_until"]>int(self.clock()):self.finish(row,"cancelled")
            return
        # No SQLite transaction or lock spans policy/APNs network operations.
        collapse=self.hashed("collapse:"+row["recipient_id"]+":"+str(row["actor_id"]) if row["event_kind"]=="direct_message" else "event:"+row["event_id"])
        try:
            response=self.http.post(HOSTS[environment]+"/3/device/"+token,headers={"authorization":"bearer "+provider,"apns-topic":TOPIC,"apns-push-type":"alert","apns-priority":"10","apns-id":row["id"],"apns-expiration":str(row["expires_at"]),"apns-collapse-id":collapse},json=payload)
        except (OSError,ValueError,TypeError):
            self.finish(row,"pending","provider_auth");return
        except Exception:
            self.finish(row,"pending","transport_error");return
        if response.status_code==200:
            self.finish(row,"accepted");return
        try:details=response.json() if len(response.content)<=2048 else {}
        except Exception:details={}
        reason=details.get("reason") if isinstance(details,dict) else None
        code={"BadDeviceToken":"bad_device_token","DeviceTokenNotForTopic":"wrong_topic","Unregistered":"unregistered","ExpiredProviderToken":"provider_auth","InvalidProviderToken":"provider_auth","Forbidden":"provider_auth","PayloadTooLarge":"payload_invalid","TooManyRequests":"rate_limited"}.get(reason,"provider_unavailable" if response.status_code>=500 else "unknown")
        if response.status_code==429 or response.status_code>=500:
            header=response.headers.get("retry-after","")
            self.finish(row,"pending",code,int(header) if header.isdigit() else None)
        else:
            stamp=details.get("timestamp") if isinstance(details,dict) else None
            timestamp=int(stamp/1000) if type(stamp) is int and stamp>0 else None
            self.finish(row,"failed",code,invalid=response.status_code==410 or reason in {"BadDeviceToken","DeviceTokenNotForTopic"},invalid_at=timestamp if response.status_code==410 else None)

    def dispatch(self,limit=20):
        if not self.settings.apns_enabled or not self.worker_lock.acquire(blocking=False):return
        try:
            for _ in range(limit):
                row=self.claim()
                if row is None:break
                self.send_one(row)
        finally:self.worker_lock.release()


def build_router(app,*,consented_user,authenticated):
    router=APIRouter(prefix="/v1/push")
    @router.put("/devices/{installation}")
    def register(installation:str,payload:DeviceRegistration,user=Depends(consented_user)):
        return app.state.push.register(user,installation,payload)
    @router.delete("/devices/{installation}")
    def unregister(installation:str,payload:DeviceRemoval,user=Depends(authenticated)):
        return app.state.push.unregister(user,installation,payload)
    @router.get("/status")
    def status(user=Depends(consented_user)):
        return app.state.push.status(user)
    @router.get("/destinations/{delivery_id}")
    def resolve(delivery_id:str,user=Depends(consented_user)):
        return app.state.push.resolve(user,delivery_id)
    return router
