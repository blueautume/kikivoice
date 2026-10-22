"""Account-owned reply-gated direct messages, static-image moments and moderation.

Uploads are private, authenticated on every read, metadata-free JPEGs. Case media
is only visible to community operators while an unexpired report refers to it.
"""
from io import BytesIO
import json
import os
from pathlib import Path
import re
import tempfile
import time
from typing import Literal
import uuid
import warnings

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

UUID_PATTERN = r"^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"
CONTENT_SCHEMA="""
CREATE TABLE IF NOT EXISTS social_media(
 id TEXT PRIMARY KEY,owner_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 width INTEGER NOT NULL,height INTEGER NOT NULL,created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS social_moments(
 id TEXT PRIMARY KEY,author_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 text TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS social_moment_order ON social_moments(created_at DESC,id DESC);
CREATE TABLE IF NOT EXISTS social_moment_media(
 moment_id TEXT NOT NULL REFERENCES social_moments(id) ON DELETE CASCADE,
 media_id TEXT NOT NULL UNIQUE REFERENCES social_media(id) ON DELETE CASCADE,position INTEGER NOT NULL,
 PRIMARY KEY(moment_id,media_id));
CREATE TABLE IF NOT EXISTS social_likes(
 moment_id TEXT NOT NULL REFERENCES social_moments(id) ON DELETE CASCADE,
 actor_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,created_at INTEGER NOT NULL,
 PRIMARY KEY(moment_id,actor_id));
CREATE TABLE IF NOT EXISTS social_comments(
 id TEXT PRIMARY KEY,moment_id TEXT NOT NULL REFERENCES social_moments(id) ON DELETE CASCADE,
 author_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 text TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS social_comment_order ON social_comments(moment_id,created_at DESC,id DESC);
CREATE TABLE IF NOT EXISTS social_conversations(
 id TEXT PRIMARY KEY,first_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 second_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,UNIQUE(first_id,second_id),CHECK(first_id<second_id));
CREATE TABLE IF NOT EXISTS social_messages(
 seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
 conversation_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
 sender_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 recipient_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 text TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS social_message_order ON social_messages(conversation_id,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS social_message_sequence ON social_messages(conversation_id,seq DESC);
CREATE TABLE IF NOT EXISTS social_reads(
 conversation_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 through_seq INTEGER NOT NULL DEFAULT0,PRIMARY KEY(conversation_id,account_id));
CREATE TABLE IF NOT EXISTS social_conversation_state(
 conversation_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 is_pinned INTEGER NOT NULL DEFAULT0 CHECK(is_pinned IN (0,1)),
 cleared_through_seq INTEGER NOT NULL DEFAULT0 CHECK(cleared_through_seq>=0),
 PRIMARY KEY(conversation_id,account_id));
CREATE TABLE IF NOT EXISTS social_dm_contact_state(
 first_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 second_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 first_sent_count INTEGER NOT NULL DEFAULT0 CHECK(first_sent_count>=0),
 second_sent_count INTEGER NOT NULL DEFAULT0 CHECK(second_sent_count>=0),
 PRIMARY KEY(first_id,second_id),CHECK(first_id<second_id));
""".replace("DEFAULT0", "DEFAULT 0")

INITIAL_MESSAGE_LIMIT=5


class ContentModel(BaseModel):
    model_config=ConfigDict(extra="forbid",strict=True,str_strip_whitespace=True)


class ContentMutation(ContentModel):
    requestID:str=Field(pattern=UUID_PATTERN)

    @field_validator("requestID")
    @classmethod
    def identifier(cls,value):
        return str(uuid.UUID(value))


class MessageCreate(ContentMutation):
    text:str=Field(min_length=1,max_length=1000)


class ConversationPin(ContentMutation):
    pinned:bool


class ConversationClear(ContentMutation):
    throughMessageID:str=Field(pattern=UUID_PATTERN)

    @field_validator("throughMessageID")
    @classmethod
    def through_identifier(cls,value):
        return str(uuid.UUID(value))


class MomentCreate(ContentMutation):
    text:str=Field(default="",max_length=1000)
    mediaIDs:list[str]=Field(default_factory=list,max_length=3)

    @field_validator("mediaIDs")
    @classmethod
    def identifiers(cls,value):
        if any(not re.fullmatch(UUID_PATTERN,item) for item in value) or len(set(value))!=len(value):
            raise ValueError("Invalid media IDs")
        return [str(uuid.UUID(item)) for item in value]

    @model_validator(mode="after")
    def not_empty(self):
        if not self.text and not self.mediaIDs:
            raise ValueError("Moment requires text or images")
        return self


class CommentCreate(ContentMutation):
    text:str=Field(min_length=1,max_length=300)


class MessageRead(ContentModel):
    throughMessageID:str=Field(pattern=UUID_PATTERN)

    @field_validator("throughMessageID")
    @classmethod
    def identifier(cls,value):
        return str(uuid.UUID(value))


class SocialReport(ContentMutation):
    targetType:Literal["profile","moment","comment","direct_message"]
    targetID:str=Field(min_length=3,max_length=80)
    reason:Literal["harassment","spam","sexual","fraud","other"]
    details:str=Field(default="",max_length=500)


class SocialModerationQuery(ContentModel):
    status:Literal["pending","resolved","all"]="pending"
    limit:int=Field(default=30,ge=1,le=50)
    cursor:str|None=Field(default=None,max_length=1024)


class SocialModerationAction(ContentMutation):
    reportID:str=Field(pattern=UUID_PATTERN)
    action:Literal["warn","remove_content","restrict_posting","restore_user","dismiss"]
    durationSeconds:int|None=Field(default=None,ge=60,le=2592000)
    note:str=Field(min_length=1,max_length=500)

    @model_validator(mode="after")
    def duration(self):
        if (self.action=="restrict_posting")!=(self.durationSeconds is not None):
            raise ValueError("Duration required only for posting restriction")
        return self


def initialize_content(db):
    db.executescript(CONTENT_SCHEMA)
    # Preserve the handshake of existing conversations before the normal 30-day
    # content purge. Only direction counts survive; no message content is kept.
    # MAX makes startup/restart idempotent and never restores a consumed quota.
    db.execute("""INSERT INTO social_dm_contact_state(first_id,second_id,first_sent_count,second_sent_count)
      SELECT c.first_id,c.second_id,SUM(m.sender_id=c.first_id),SUM(m.sender_id=c.second_id)
      FROM social_conversations c JOIN social_messages m ON m.conversation_id=c.id
      GROUP BY c.first_id,c.second_id
      ON CONFLICT(first_id,second_id) DO UPDATE SET
        first_sent_count=MAX(first_sent_count,excluded.first_sent_count),
        second_sent_count=MAX(second_sent_count,excluded.second_sent_count)""")


def purge_content(db,now=None):
    now=int(time.time()) if now is None else now
    db.execute("DELETE FROM social_messages WHERE created_at<=?",(now-30*86400,))
    db.execute("DELETE FROM social_conversations WHERE updated_at<=? AND NOT EXISTS(SELECT 1 FROM social_messages m WHERE m.conversation_id=social_conversations.id)",(now-30*86400,))


def erase_content(db,account_id):
    db.execute("DELETE FROM social_dm_contact_state WHERE first_id=? OR second_id=?",(account_id,account_id))
    db.execute("DELETE FROM social_conversations WHERE first_id=? OR second_id=?",(account_id,account_id))
    db.execute("DELETE FROM social_moments WHERE author_id=?",(account_id,))
    db.execute("DELETE FROM social_comments WHERE author_id=?",(account_id,))
    db.execute("DELETE FROM social_likes WHERE actor_id=?",(account_id,))
    db.execute("DELETE FROM social_media WHERE owner_id=?",(account_id,))


class ContentMethods:
    @property
    def media_directory(self):
        directory=Path(self.settings.db_path).parent/"social-media"
        directory.mkdir(parents=True,exist_ok=True,mode=0o700)
        directory.chmod(0o700)
        return directory

    def media_item(self,row):
        return {"id":row["id"],"path":"/v1/social/media/"+row["id"]+".jpg","width":row["width"],"height":row["height"]}

    def sweep_media(self):
        """Delete unsubmitted24h uploads and orphaned files after committed erasure."""
        now=int(time.time())
        with self.database(self.settings) as db:
            referenced=set()
            for report in db.execute("SELECT evidence FROM social_reports WHERE created_at>?",(now-30*86400,)):
                try:
                    referenced.update(item["id"] for item in json.loads(report[0]).get("media",[]) if isinstance(item,dict))
                except (ValueError,TypeError,KeyError):
                    continue
            rows=db.execute("SELECT m.id,m.created_at,EXISTS(SELECT 1 FROM social_moment_media x WHERE x.media_id=m.id) AS attached FROM social_media m").fetchall()
            for row in rows:
                if not row["attached"] and row["id"] not in referenced and row["created_at"]<=now-86400:
                    db.execute("DELETE FROM social_media WHERE id=?",(row["id"],))
            keep={row[0] for row in db.execute("SELECT id FROM social_media")}
        for file in self.media_directory.iterdir():
            if file.is_file() and file.name.startswith(".upload-"):
                try:
                    if file.stat().st_mtime<time.time()-86400:
                        file.unlink()
                except FileNotFoundError:
                    pass
            if file.is_file() and file.suffix==".jpg" and re.fullmatch(UUID_PATTERN,file.stem) and file.stem not in keep:
                try:
                    # Never delete an upload while its file-to-database commit is in flight.
                    if file.stat().st_mtime<time.time()-60:
                        file.unlink()
                except FileNotFoundError:
                    pass

    def remove_unreferenced_media(self,db,media_ids):
        referenced=set()
        for report in db.execute("SELECT evidence FROM social_reports WHERE created_at>?",(int(time.time())-30*86400,)):
            try:
                referenced.update(item["id"] for item in json.loads(report[0]).get("media",[]))
            except (ValueError,TypeError,KeyError):
                continue
        for media_id in media_ids:
            if media_id not in referenced and not db.execute("SELECT 1 FROM social_moment_media WHERE media_id=?",(media_id,)).fetchone():
                db.execute("DELETE FROM social_media WHERE id=?",(media_id,))

    def upload_media(self,user,content,content_type):
        if content_type.split(";",1)[0].lower()!="image/jpeg" or not 0<len(content)<=2*1024*1024:
            raise HTTPException(422,"请上传不超过2MB的静态JPEG图片")
        self.policy(user)
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error",Image.DecompressionBombWarning)
                with Image.open(BytesIO(content)) as source:
                    if source.format!="JPEG" or source.width*source.height>10_000_000 or getattr(source,"n_frames",1)!=1:
                        raise ValueError("Invalid static image")
                    source.load()
                    image=ImageOps.exif_transpose(source).convert("RGB")
                    image.thumbnail((1280,1280),Image.Resampling.LANCZOS)
                    clean=Image.new("RGB",image.size)
                    clean.paste(image)
                    output=BytesIO()
                    clean.save(output,"JPEG",quality=85,optimize=True)
                    encoded=output.getvalue()
                    width,height=clean.size
        except (UnidentifiedImageError,OSError,ValueError,Image.DecompressionBombError,Image.DecompressionBombWarning):
            raise HTTPException(422,"图片无法读取，请重新选择静态图片") from None
        media_id=str(uuid.uuid4())
        path=self.media_directory/(media_id+".jpg")
        fd,temp=tempfile.mkstemp(prefix=".upload-",dir=self.media_directory)
        try:
            with os.fdopen(fd,"wb") as stream:
                stream.write(encoded)
            os.chmod(temp,0o600)
            os.replace(temp,path)
            with self.database(self.settings) as db:
                db.execute("BEGIN IMMEDIATE")
                self.check(db,user,publishing=True)
                self.rate(db,user,"media",40,90)
                if db.execute("SELECT COUNT(*) FROM social_media WHERE owner_id=?",(user["account_id"],)).fetchone()[0]>=600:
                    raise HTTPException(409,"图片已达到600张上限，请先删除旧动态")
                db.execute("INSERT INTO social_media VALUES(?,?,?,?,?)",(media_id,user["account_id"],width,height,int(time.time())))
        except BaseException:
            path.unlink(missing_ok=True)
            Path(temp).unlink(missing_ok=True)
            raise
        return {"id":media_id,"path":"/v1/social/media/"+media_id+".jpg","width":width,"height":height}

    def media_response(self,user,media_id):
        if not re.fullmatch(UUID_PATTERN,media_id):
            raise HTTPException(404,"图片不存在或已删除")
        policy=self.policy(user)
        with self.database(self.settings) as db:
            self.check(db,user)
            row=db.execute(f"SELECT m.*,a.login_id FROM social_media m JOIN accounts a ON a.account_id=m.owner_id WHERE m.id=? AND {self.valid_account_sql()}",(media_id,*self.legal_args)).fetchone()
            if row is None or row["login_id"] in policy.blockedUserIDs:
                raise HTTPException(404,"图片不存在或已删除")
            attached=db.execute("SELECT 1 FROM social_moment_media x JOIN social_moments p ON p.id=x.moment_id WHERE x.media_id=?",(media_id,)).fetchone()
            if not attached and (row["owner_id"]!=user["account_id"] or row["created_at"]<=int(time.time())-86400):
                raise HTTPException(404,"图片不存在或已删除")
        path=self.media_directory/(media_id+".jpg")
        if not path.is_file() or path.is_symlink():
            raise HTTPException(404,"图片不存在或已删除")
        return FileResponse(path,media_type="image/jpeg",headers={"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"})

    def dm_access(self,db,actor,target):
        """The server owns the five-message introduction and reply handshake.

        This state belongs to the account pair, independently of follow edges,
        a viewer's clear watermark, or expiry of the retained message bodies.
        Current account/consent/block/publication checks remain with callers.
        """
        first,second=sorted((actor,target))
        state=db.execute("SELECT first_sent_count,second_sent_count FROM social_dm_contact_state WHERE first_id=? AND second_id=?",(first,second)).fetchone()
        sent=(state["first_sent_count"] if actor==first else state["second_sent_count"]) if state else 0
        received=(state["second_sent_count"] if actor==first else state["first_sent_count"]) if state else 0
        established=sent>0 and received>0
        remaining=None if established else max(0,INITIAL_MESSAGE_LIMIT-sent)
        return {"canSend":established or remaining>0,"remainingBeforeReply":remaining,
                "requiresReply":not established and remaining==0,
                "replyEstablished":established,"initialMessageLimit":INITIAL_MESSAGE_LIMIT}

    def record_dm_send(self,db,actor,target):
        first,second=sorted((actor,target))
        first_count,second_count=(1,0) if actor==first else (0,1)
        # Once both directions have committed a message the relationship stays
        # unlocked; counters only describe the bounded introduction phase.
        db.execute("""INSERT INTO social_dm_contact_state VALUES(?,?,?,?)
          ON CONFLICT(first_id,second_id) DO UPDATE SET
            first_sent_count=first_sent_count+excluded.first_sent_count,
            second_sent_count=second_sent_count+excluded.second_sent_count
          WHERE first_sent_count=0 OR second_sent_count=0""",(first,second,first_count,second_count))

    def conversation(self,db,actor,target):
        first,second=sorted((actor,target))
        return db.execute("SELECT * FROM social_conversations WHERE first_id=? AND second_id=?",(first,second)).fetchone()

    def message_json(self,db,row):
        return {"id":row["id"],"seq":row["seq"],"senderID":db.execute("SELECT login_id FROM accounts WHERE account_id=?",(row["sender_id"],)).fetchone()[0],"text":row["text"],"createdAt":row["created_at"]}

    def conversation_unread(self,db,user,conversation_id):
        return db.execute("SELECT COUNT(*) FROM social_messages m WHERE m.conversation_id=? AND m.recipient_id=? AND m.created_at>? AND m.seq>MAX(COALESCE((SELECT through_seq FROM social_reads WHERE conversation_id=? AND account_id=?),0),COALESCE((SELECT cleared_through_seq FROM social_conversation_state WHERE conversation_id=? AND account_id=?),0))",(conversation_id,user["account_id"],int(time.time())-30*86400,conversation_id,user["account_id"],conversation_id,user["account_id"])).fetchone()[0]

    def conversation_state(self,db,user,conversation_id):
        row=db.execute("SELECT is_pinned,cleared_through_seq FROM social_conversation_state WHERE conversation_id=? AND account_id=?",(conversation_id,user["account_id"])).fetchone()
        return row if row is not None else {"is_pinned":0,"cleared_through_seq":0}

    def conversations(self,user,limit=20,cursor=None):
        try:
            key=self.cursor(user,"conversations-v2",value=cursor)
        except HTTPException as error:
            if error.status_code!=422: raise
            # Existing installed clients can finish an ordinary-list cursor.
            # A fresh first page always includes the current pinned ordering.
            legacy=self.cursor(user,"conversations",value=cursor)
            key=[0,*legacy]
        with self.database(self.settings) as db:
            self.check(db,user)
            rows=db.execute("SELECT c.*,a.login_id AS target_public,a.account_id AS target_account,COALESCE(s.is_pinned,0) AS is_pinned FROM social_conversations c JOIN accounts a ON a.account_id=CASE WHEN c.first_id=? THEN c.second_id ELSE c.first_id END LEFT JOIN social_conversation_state s ON s.conversation_id=c.id AND s.account_id=? WHERE (c.first_id=? OR c.second_id=?) AND "+self.valid_account_sql()+
                " AND EXISTS(SELECT 1 FROM social_messages m WHERE m.conversation_id=c.id AND m.created_at>? AND m.seq>COALESCE(s.cleared_through_seq,0))"+
                (" AND (COALESCE(s.is_pinned,0),c.updated_at,c.id)<(?,?,?)" if key else "")+" ORDER BY is_pinned DESC,c.updated_at DESC,c.id DESC LIMIT ?",(user["account_id"],user["account_id"],user["account_id"],user["account_id"],*self.legal_args,int(time.time())-30*86400,*((key[0],key[1],key[2]) if key else ()),limit+1)).fetchall()
        candidates=rows[:limit]
        policy=self.policy(user,[row["target_public"] for row in candidates])
        with self.database(self.settings) as db:
            db.execute("BEGIN")
            self.check(db,user)
            result=[]
            for row in candidates:
                if row["target_public"] in policy.blockedUserIDs or not db.execute("SELECT 1 FROM social_conversations WHERE id=? AND (first_id=? OR second_id=?)",(row["id"],user["account_id"],user["account_id"])).fetchone():
                    continue
                try:
                    person=self.person(db,user,self.account(db,row["target_public"]),policy)
                except HTTPException as error:
                    if error.status_code==404: continue
                    raise
                state=self.conversation_state(db,user,row["id"])
                last=db.execute("SELECT * FROM social_messages WHERE conversation_id=? AND created_at>? AND seq>? ORDER BY seq DESC LIMIT 1",(row["id"],int(time.time())-30*86400,state["cleared_through_seq"])).fetchone()
                if last is None: continue
                result.append({"id":row["id"],"person":person,"lastMessage":self.message_json(db,last),"unreadCount":self.conversation_unread(db,user,row["id"]),**self.dm_access(db,user["account_id"],row["target_account"]),"isPinned":bool(state["is_pinned"])})
            # Global unread must respect the complete bilateral block snapshot.
            unread=0
            for conv in db.execute("SELECT c.id,a.login_id FROM social_conversations c JOIN accounts a ON a.account_id=CASE WHEN c.first_id=? THEN c.second_id ELSE c.first_id END WHERE (c.first_id=? OR c.second_id=?) AND "+self.valid_account_sql(),(user["account_id"],user["account_id"],user["account_id"],*self.legal_args)):
                if conv["login_id"] not in policy.blockedUserIDs: unread+=self.conversation_unread(db,user,conv["id"])
        return {"conversations":result,"nextCursor":self.cursor(user,"conversations-v2",key=[candidates[-1]["is_pinned"],candidates[-1]["updated_at"],candidates[-1]["id"]]) if len(rows)>limit and candidates else None,"unreadCount":unread}

    def messages(self,user,target_id,limit=30,cursor=None):
        policy=self.policy(user,[target_id])
        key=self.cursor(user,"messages:"+target_id,value=cursor)
        with self.database(self.settings) as db:
            # The cached-history cutoff and returned page share one snapshot.
            db.execute("BEGIN")
            self.check(db,user)
            target=self.account(db,target_id)
            self.person(db,user,target,policy)
            if target["account_id"]==user["account_id"]: raise HTTPException(422,"不能私聊自己")
            conv=self.conversation(db,user["account_id"],target["account_id"])
            access=self.dm_access(db,user["account_id"],target["account_id"])
            if conv is None:
                return {"conversationID":None,"messages":[],"nextCursor":None,**access,"unreadCount":0,"clearedThroughSeq":0}
            state=self.conversation_state(db,user,conv["id"])
            rows=db.execute("SELECT * FROM social_messages WHERE conversation_id=? AND created_at>? AND seq>?"+(" AND seq<?" if key else "")+" ORDER BY seq DESC LIMIT ?",(conv["id"],int(time.time())-30*86400,state["cleared_through_seq"],*((key[0],) if key else ()),limit+1)).fetchall()
            candidates=rows[:limit]
            return {"conversationID":conv["id"],"messages":[self.message_json(db,row) for row in candidates],"nextCursor":self.cursor(user,"messages:"+target_id,key=[candidates[-1]["seq"],candidates[-1]["id"]]) if len(rows)>limit and candidates else None,**access,"unreadCount":self.conversation_unread(db,user,conv["id"]),"clearedThroughSeq":state["cleared_through_seq"]}

    def send_message(self,user,target_id,payload):
        from .social import clean_text,purge
        text=clean_text(payload.text,1000,multiline=True)
        self.text_policy.check_profile(bio=text)
        policy=self.policy(user,[target_id])
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user,publishing=True)
            purge(db)
            target=self.account(db,target_id)
            self.person(db,user,target,policy)
            if target["account_id"]==user["account_id"]: raise HTTPException(422,"不能私聊自己")
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"dm","target":target_id,"text":text})
            if old:
                row=db.execute("SELECT * FROM social_messages WHERE id=? AND sender_id=?",(old["result_id"],user["account_id"])).fetchone()
                if row is None or row["seq"]<=self.conversation_state(db,user,row["conversation_id"])["cleared_through_seq"]: raise HTTPException(404,"消息已清理或超过保留期限")
                return {"message":self.message_json(db,row),"conversationID":row["conversation_id"],**self.dm_access(db,user["account_id"],target["account_id"])}
            access=self.dm_access(db,user["account_id"],target["account_id"])
            if not access["canSend"]:
                raise HTTPException(403,{"code":"direct_message_reply_required","message":"已发送5条消息，等待对方回复后可继续聊天。",**access})
            self.rate(db,user,"dm",300,1000)
            conv=self.conversation(db,user["account_id"],target["account_id"])
            now=int(time.time())
            if conv is None:
                first,second=sorted((user["account_id"],target["account_id"]))
                conv_id=str(uuid.uuid4())
                db.execute("INSERT INTO social_conversations VALUES(?,?,?,?,?)",(conv_id,first,second,now,now))
            else: conv_id=conv["id"]
            message_id=str(uuid.uuid4())
            db.execute("INSERT INTO social_messages(id,conversation_id,sender_id,recipient_id,text,created_at) VALUES(?,?,?,?,?,?)",(message_id,conv_id,user["account_id"],target["account_id"],text,now))
            self.record_dm_send(db,user["account_id"],target["account_id"])
            db.execute("UPDATE social_conversations SET updated_at=? WHERE id=?",(now,conv_id))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,?)",(user["account_id"],payload.requestID,hashed,now,message_id))
            if hasattr(self,"push"):
                self.push.enqueue(db,target["account_id"],"direct_message",message_id,user["account_id"])
            return {"message":self.message_json(db,db.execute("SELECT * FROM social_messages WHERE id=?",(message_id,)).fetchone()),"conversationID":conv_id,**self.dm_access(db,user["account_id"],target["account_id"])}

    def read_messages(self,user,target_id,payload):
        policy=self.policy(user,[target_id])
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            target=self.account(db,target_id)
            self.person(db,user,target,policy)
            conv=self.conversation(db,user["account_id"],target["account_id"])
            row=None if conv is None else db.execute("SELECT seq FROM social_messages WHERE id=? AND conversation_id=? AND created_at>?",(payload.throughMessageID,conv["id"],int(time.time())-30*86400)).fetchone()
            if row is None or row["seq"]<=self.conversation_state(db,user,conv["id"])["cleared_through_seq"]: raise HTTPException(404,"消息不存在或已过期")
            db.execute("INSERT INTO social_reads VALUES(?,?,?) ON CONFLICT(conversation_id,account_id) DO UPDATE SET through_seq=MAX(through_seq,excluded.through_seq)",(conv["id"],user["account_id"],row["seq"]))
            return {"unreadCount":self.conversation_unread(db,user,conv["id"])}

    def pin_conversation(self,user,target_id,payload):
        policy=self.policy(user,[target_id])
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            target=self.account(db,target_id)
            self.person(db,user,target,policy)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"conversation-pin","target":target_id,"pinned":payload.pinned})
            if old: return {"ok":True}
            conv=self.conversation(db,user["account_id"],target["account_id"])
            if conv is None: raise HTTPException(404,"会话不存在或已清理")
            state=self.conversation_state(db,user,conv["id"])
            if not db.execute("SELECT 1 FROM social_messages WHERE conversation_id=? AND seq>? AND created_at>? LIMIT 1",(conv["id"],state["cleared_through_seq"],int(time.time())-30*86400)).fetchone():
                raise HTTPException(404,"会话不存在或已清理")
            self.rate(db,user,"inbox",300,1000)
            db.execute("INSERT INTO social_conversation_state(conversation_id,account_id,is_pinned) VALUES(?,?,?) ON CONFLICT(conversation_id,account_id) DO UPDATE SET is_pinned=excluded.is_pinned",(conv["id"],user["account_id"],int(payload.pinned)))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",(user["account_id"],payload.requestID,hashed,int(time.time())))
            return {"ok":True}

    def clear_conversation(self,user,target_id,payload):
        policy=self.policy(user,[target_id])
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            target=self.account(db,target_id)
            self.person(db,user,target,policy)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"conversation-clear","target":target_id,"throughMessageID":payload.throughMessageID})
            if old: return {"ok":True}
            conv=self.conversation(db,user["account_id"],target["account_id"])
            row=None if conv is None else db.execute("SELECT seq FROM social_messages WHERE conversation_id=? AND id=? AND created_at>?",(conv["id"],payload.throughMessageID,int(time.time())-30*86400)).fetchone()
            if row is None: raise HTTPException(404,"消息不存在或已过期")
            self.rate(db,user,"inbox",300,1000)
            db.execute("INSERT INTO social_conversation_state(conversation_id,account_id,is_pinned,cleared_through_seq) VALUES(?,?,0,?) ON CONFLICT(conversation_id,account_id) DO UPDATE SET is_pinned=0,cleared_through_seq=MAX(cleared_through_seq,excluded.cleared_through_seq)",(conv["id"],user["account_id"],row["seq"]))
            db.execute("INSERT INTO social_reads VALUES(?,?,?) ON CONFLICT(conversation_id,account_id) DO UPDATE SET through_seq=MAX(through_seq,excluded.through_seq)",(conv["id"],user["account_id"],row["seq"]))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,NULL)",(user["account_id"],payload.requestID,hashed,int(time.time())))
            return {"ok":True}

    def moment_row(self,db,moment_id,user,policy):
        row=db.execute("SELECT p.*,a.login_id AS author_public FROM social_moments p JOIN accounts a ON a.account_id=p.author_id WHERE p.id=? AND "+self.valid_account_sql(),(moment_id,*self.legal_args)).fetchone()
        if row is None or row["author_public"] in policy.blockedUserIDs:
            raise HTTPException(404,"动态不存在或暂不可见")
        return row

    def moment_json(self,db,user,row,policy):
        author=self.person(db,user,self.account(db,row["author_public"]),policy)
        media=[self.media_item(item) for item in db.execute("SELECT m.* FROM social_media m JOIN social_moment_media x ON x.media_id=m.id WHERE x.moment_id=? ORDER BY x.position",(row["id"],))]
        # Apply visibility before LIMIT, so hidden newest comments neither leak
        # into the preview/count nor displace the three visible comments. The
        # window count keeps the existing total without loading all comment text.
        blocked=tuple(policy.blockedUserIDs)
        visible="c.moment_id=? AND "+self.valid_account_sql()
        if blocked:visible+=" AND a.login_id NOT IN ("+",".join("?" for _ in blocked)+")"
        comments=db.execute("SELECT c.*,a.login_id AS author_public,COUNT(*) OVER() AS visible_count FROM social_comments c JOIN accounts a ON a.account_id=c.author_id WHERE "+visible+" ORDER BY c.created_at DESC,c.id DESC LIMIT 3",(row["id"],*self.legal_args,*blocked)).fetchall()
        likes=db.execute("SELECT a.login_id FROM social_likes l JOIN accounts a ON a.account_id=l.actor_id WHERE l.moment_id=? AND "+self.valid_account_sql(),(row["id"],*self.legal_args)).fetchall()
        return {"id":row["id"],"author":author,"text":row["text"],"media":media,"createdAt":row["created_at"]/1e9,
                "likeCount":sum(x[0] not in policy.blockedUserIDs for x in likes),"commentCount":comments[0]["visible_count"] if comments else 0,
                "commentPreview":[self.comment_json(db,user,item,policy) for item in comments],
                "liked":bool(db.execute("SELECT 1 FROM social_likes WHERE moment_id=? AND actor_id=?",(row["id"],user["account_id"])).fetchone()),"canDelete":row["author_id"]==user["account_id"]}

    def moments(self,user,kind="all",target_id=None,limit=20,cursor=None):
        from .social import digest
        scope="moments:"+digest({"kind":kind,"target":target_id})
        key=self.cursor(user,scope,value=cursor)
        with self.database(self.settings) as db:
            self.check(db,user)
            where=[self.valid_account_sql()]
            args=list(self.legal_args)
            if target_id:
                self.account(db,target_id)
                where.append("a.login_id=?");args.append(target_id)
            elif kind=="mine":where.append("p.author_id=?");args.append(user["account_id"])
            elif kind=="following":where.append("EXISTS(SELECT 1 FROM social_follows f WHERE f.follower_id=? AND f.followed_id=p.author_id)");args.append(user["account_id"])
            if key:where.append("(p.created_at<? OR (p.created_at=? AND p.id<?))");args.extend((key[0],key[0],key[1]))
            rows=db.execute("SELECT p.*,a.login_id AS author_public FROM social_moments p JOIN accounts a ON a.account_id=p.author_id WHERE "+" AND ".join(where)+" ORDER BY p.created_at DESC,p.id DESC LIMIT ?",(*args,limit+1)).fetchall()
        candidates=rows[:limit]
        policy=self.policy(user,[row["author_public"] for row in candidates])
        if target_id and target_id in policy.blockedUserIDs: raise HTTPException(404,"用户不存在或暂不可见")
        with self.database(self.settings) as db:
            self.check(db,user)
            result=[]
            for old in candidates:
                try:row=self.moment_row(db,old["id"],user,policy)
                except HTTPException as error:
                    if error.status_code==404:continue
                    raise
                result.append(self.moment_json(db,user,row,policy))
        return {"moments":result,"nextCursor":self.cursor(user,scope,key=[candidates[-1]["created_at"],candidates[-1]["id"]]) if len(rows)>limit and candidates else None}

    def get_moment(self,user,moment_id):
        policy=self.policy(user)
        with self.database(self.settings) as db:
            self.check(db,user)
            return {"moment":self.moment_json(db,user,self.moment_row(db,moment_id,user,policy),policy)}

    def create_moment(self,user,payload):
        from .social import clean_text,purge
        text=clean_text(payload.text,1000,multiline=True) if payload.text else ""
        self.text_policy.check_profile(bio=text)
        policy=self.policy(user,[user["login_id"]])
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user,publishing=True)
            purge(db)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"moment","text":text,"media":payload.mediaIDs})
            if old:
                return {"moment":self.moment_json(db,user,self.moment_row(db,old["result_id"],user,policy),policy)}
            self.rate(db,user,"moment",10,30)
            if db.execute("SELECT COUNT(*) FROM social_moments WHERE author_id=?",(user["account_id"],)).fetchone()[0]>=200:
                raise HTTPException(409,"动态已达到200条上限，请先删除旧动态")
            for media_id in payload.mediaIDs:
                item=db.execute("SELECT * FROM social_media m WHERE id=? AND owner_id=? AND created_at>? AND NOT EXISTS(SELECT 1 FROM social_moment_media x WHERE x.media_id=m.id)",(media_id,user["account_id"],int(time.time())-86400)).fetchone()
                if item is None: raise HTTPException(422,"图片不存在、已使用或上传已过期，请重新选择")
            moment_id=str(uuid.uuid4())
            db.execute("INSERT INTO social_moments VALUES(?,?,?,?)",(moment_id,user["account_id"],text,time.time_ns()))
            for index,media_id in enumerate(payload.mediaIDs):db.execute("INSERT INTO social_moment_media VALUES(?,?,?)",(moment_id,media_id,index))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,?)",(user["account_id"],payload.requestID,hashed,int(time.time()),moment_id))
            return {"moment":self.moment_json(db,user,self.moment_row(db,moment_id,user,policy),policy)}

    def delete_moment_in_db(self,db,moment_id):
        media_ids=[row[0] for row in db.execute("SELECT media_id FROM social_moment_media WHERE moment_id=?",(moment_id,))]
        db.execute("DELETE FROM social_moments WHERE id=?",(moment_id,))
        self.remove_unreferenced_media(db,media_ids)

    def delete_moment(self,user,moment_id):
        self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            row=db.execute("SELECT author_id FROM social_moments WHERE id=?",(moment_id,)).fetchone()
            if row is not None and row[0]!=user["account_id"]:raise HTTPException(404,"动态不存在或不可删除")
            if row:self.delete_moment_in_db(db,moment_id)
        self.sweep_media()
        return {"ok":True}

    def like_moment(self,user,moment_id,payload,enabled):
        policy=self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user,publishing=enabled)
            row=self.moment_row(db,moment_id,user,policy)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"like","moment":moment_id,"enabled":enabled})
            if not old:
                self.rate(db,user,"like",600,1000)
                if enabled:
                    inserted=db.execute("INSERT OR IGNORE INTO social_likes VALUES(?,?,?)",(moment_id,user["account_id"],int(time.time()))).rowcount
                    if inserted and row["author_id"]!=user["account_id"]:self.notice(db,row["author_id"],"system","赞了你的动态",user["account_id"],f"like:{moment_id}:{user['account_id']}",moment_id=moment_id)
                else:db.execute("DELETE FROM social_likes WHERE moment_id=? AND actor_id=?",(moment_id,user["account_id"]))
                db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,?)",(user["account_id"],payload.requestID,hashed,int(time.time()),moment_id))
            return {"moment":self.moment_json(db,user,row,policy)}

    def comment_json(self,db,user,row,policy):
        return {"id":row["id"],"momentID":row["moment_id"],"author":self.person(db,user,self.account(db,row["author_public"]),policy),"text":row["text"],"createdAt":row["created_at"]/1e9,"canDelete":row["author_id"]==user["account_id"]}

    def comments(self,user,moment_id,limit=20,cursor=None):
        scope="comments:"+moment_id
        key=self.cursor(user,scope,value=cursor)
        with self.database(self.settings) as db:
            self.check(db,user)
            rows=db.execute("SELECT c.*,a.login_id AS author_public FROM social_comments c JOIN accounts a ON a.account_id=c.author_id WHERE c.moment_id=? AND "+self.valid_account_sql()+(" AND (c.created_at<? OR (c.created_at=? AND c.id<?))" if key else "")+" ORDER BY c.created_at DESC,c.id DESC LIMIT ?",(moment_id,*self.legal_args,*((key[0],key[0],key[1]) if key else ()),limit+1)).fetchall()
        candidates=rows[:limit]
        policy=self.policy(user,[row["author_public"] for row in candidates])
        with self.database(self.settings) as db:
            self.check(db,user)
            self.moment_row(db,moment_id,user,policy)
            items=[]
            for old in candidates:
                row=db.execute("SELECT c.*,a.login_id AS author_public FROM social_comments c JOIN accounts a ON a.account_id=c.author_id WHERE c.id=? AND "+self.valid_account_sql(),(old["id"],*self.legal_args)).fetchone()
                if row and row["author_public"] not in policy.blockedUserIDs:items.append(self.comment_json(db,user,row,policy))
        return {"comments":items,"nextCursor":self.cursor(user,scope,key=[candidates[-1]["created_at"],candidates[-1]["id"]]) if len(rows)>limit and candidates else None}

    def create_comment(self,user,moment_id,payload):
        from .social import clean_text,purge
        text=clean_text(payload.text,300,multiline=True)
        self.text_policy.check_profile(bio=text)
        policy=self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user,publishing=True)
            purge(db)
            moment=self.moment_row(db,moment_id,user,policy)
            old,hashed=self.receipt(db,user,payload.requestID,{"kind":"comment","moment":moment_id,"text":text})
            if old:
                row=db.execute("SELECT c.*,a.login_id AS author_public FROM social_comments c JOIN accounts a ON a.account_id=c.author_id WHERE c.id=?",(old["result_id"],)).fetchone()
                if row is None:raise HTTPException(404,"评论已删除")
                return {"comment":self.comment_json(db,user,row,policy)}
            self.rate(db,user,"comment",120,300)
            comment_id=str(uuid.uuid4())
            db.execute("INSERT INTO social_comments VALUES(?,?,?,?,?)",(comment_id,moment_id,user["account_id"],text,time.time_ns()))
            db.execute("INSERT INTO social_receipts VALUES(?,?,?,?,?)",(user["account_id"],payload.requestID,hashed,int(time.time()),comment_id))
            if moment["author_id"]!=user["account_id"]:self.notice(db,moment["author_id"],"system","评论了你的动态",user["account_id"],"comment:"+comment_id,moment_id=moment_id)
            row=db.execute("SELECT c.*,a.login_id AS author_public FROM social_comments c JOIN accounts a ON a.account_id=c.author_id WHERE c.id=?",(comment_id,)).fetchone()
            return {"comment":self.comment_json(db,user,row,policy)}

    def delete_comment(self,user,comment_id):
        self.policy(user)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            row=db.execute("SELECT author_id FROM social_comments WHERE id=?",(comment_id,)).fetchone()
            if row is not None and row[0]!=user["account_id"]:raise HTTPException(404,"评论不存在或不可删除")
            db.execute("DELETE FROM social_comments WHERE id=? AND author_id=?",(comment_id,user["account_id"]))
        return {"ok":True}

    def report_json(self,db,row,operator=False):
        result={"id":row["id"],"targetType":row["target_type"],"reason":row["reason"],"status":row["status"],"createdAt":row["created_at"],"resolvedAt":row["resolved_at"],"lastAction":row["last_action"]}
        if operator:
            reporter=db.execute("SELECT login_id,name FROM accounts WHERE account_id=?",(row["reporter_id"],)).fetchone()
            target=db.execute("SELECT login_id,name FROM accounts WHERE account_id=?",(row["target_id"],)).fetchone()
            evidence=json.loads(row["evidence"])
            result.update({"reporterID":reporter[0] if reporter else "已删除","reporterName":reporter[1] if reporter else "已删除用户",
                           "targetUserID":target[0] if target else "已删除","targetName":target[1] if target else "已删除用户",
                           "contentID":row["content_id"],"details":row["details"],"evidence":evidence})
        return result

    def submit_report(self,user,payload):
        from .social import clean_text,digest,purge
        details=clean_text(payload.details,500,multiline=True) if payload.details else ""
        policy=self.policy(user)
        content={**payload.model_dump(),"details":details}
        content.pop("requestID")
        hashed=digest(content)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            self.check(db,user)
            purge(db)
            old=db.execute("SELECT * FROM social_reports WHERE reporter_id=? AND client_request_id=?",(user["account_id"],payload.requestID)).fetchone()
            if old:
                if old["request_hash"]!=hashed:raise HTTPException(409,"举报编号已用于其他内容")
                return {"report":self.report_json(db,old)}
            media=[]
            content_id=None
            if payload.targetType=="profile":
                target=self.account(db,payload.targetID)
                self.person(db,user,target,policy)
                evidence=target["name"]+"\n"+target["bio"]
            elif payload.targetType=="moment":
                row=self.moment_row(db,payload.targetID,user,policy)
                target=self.account(db,row["author_public"])
                evidence=row["text"]
                content_id=row["id"]
                media=[self.media_item(item) for item in db.execute("SELECT m.* FROM social_media m JOIN social_moment_media x ON x.media_id=m.id WHERE x.moment_id=? ORDER BY x.position",(row["id"],))]
            elif payload.targetType=="comment":
                row=db.execute("SELECT c.*,a.login_id FROM social_comments c JOIN accounts a ON a.account_id=c.author_id WHERE c.id=?",(payload.targetID,)).fetchone()
                if row is None:raise HTTPException(404,"评论不存在或已删除")
                self.moment_row(db,row["moment_id"],user,policy)
                target=self.account(db,row["login_id"])
                self.person(db,user,target,policy)
                evidence=row["text"]
                content_id=row["id"]
            else:
                row=db.execute("SELECT m.*,a.login_id FROM social_messages m JOIN accounts a ON a.account_id=m.sender_id WHERE m.id=? AND (m.sender_id=? OR m.recipient_id=?) AND m.created_at>?",(payload.targetID,user["account_id"],user["account_id"],int(time.time())-30*86400)).fetchone()
                if row is None:raise HTTPException(404,"消息不存在或已过期")
                target=self.account(db,row["login_id"])
                self.person(db,user,target,policy)
                evidence=row["text"]
                content_id=row["id"]
            if target["account_id"]==user["account_id"]:raise HTTPException(422,"不能举报自己")
            self.rate(db,user,"report",10,20)
            report_id=str(uuid.uuid4())
            db.execute("INSERT INTO social_reports(id,reporter_id,target_id,client_request_id,request_hash,target_type,content_id,reason,details,evidence,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                       (report_id,user["account_id"],target["account_id"],payload.requestID,hashed,payload.targetType,content_id,payload.reason,details,json.dumps({"text":evidence,"media":media},ensure_ascii=False),int(time.time())))
            return {"report":self.report_json(db,db.execute("SELECT * FROM social_reports WHERE id=?",(report_id,)).fetchone())}

    def my_reports(self,user):
        self.policy(user)
        with self.database(self.settings) as db:
            self.check(db,user)
            rows=db.execute("SELECT * FROM social_reports WHERE reporter_id=? AND created_at>? ORDER BY created_at DESC,id DESC LIMIT100".replace("LIMIT100","LIMIT 100"),(user["account_id"],int(time.time())-30*86400)).fetchall()
            return {"reports":[self.report_json(db,row) for row in rows],"retentionDays":30}

    def moderation_query(self,request,payload):
        with self.database(self.settings) as db:
            operator=self.ops.scope(request,db,"community")
            scope="moderation:"+payload.status
            key=self.cursor(operator,scope,value=payload.cursor)
            rows=db.execute("SELECT * FROM social_reports WHERE created_at>?"+(" AND status IN ('resolved','dismissed')" if payload.status=="resolved" else " AND status=?" if payload.status!="all" else "")+
                            (" AND (created_at>? OR (created_at=? AND id>?))" if key else "")+
                            " ORDER BY created_at ASC,id ASC LIMIT ?",(int(time.time())-30*86400,*((payload.status,) if payload.status=="pending" else ()),*((key[0],key[0],key[1]) if key else ()),payload.limit+1)).fetchall()
            candidates=rows[:payload.limit]
            reports=[self.report_json(db,row,operator=True) for row in candidates]
            restrictions=[{"userID":row["login_id"],"userName":row["name"],"until":row["muted_until"],"sourceReportID":row["source_report_id"]}
                          for row in db.execute("SELECT r.*,a.login_id,a.name FROM social_restrictions r JOIN accounts a ON a.account_id=r.account_id WHERE r.muted_until>? ORDER BY r.muted_until,a.login_id LIMIT5000".replace("LIMIT5000","LIMIT 5000"),(int(time.time()),))]
        return {"schemaVersion":1,"reports":reports,"nextCursor":self.cursor(operator,scope,key=[candidates[-1]["created_at"],candidates[-1]["id"]]) if len(rows)>payload.limit and candidates else None,"retentionDays":30,"activeRestrictions":restrictions}

    def moderation_action(self,request,payload):
        from .social import clean_text,digest,purge
        note=clean_text(payload.note,500,multiline=True)
        with self.database(self.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            operator=self.ops.scope(request,db,"community")
            self.ops.limiter.check(("social-mod-action",operator["account_id"]),20,60)
            purge(db)
            hashed=digest({**payload.model_dump(),"actor":operator["account_id"],"note":note})
            old=db.execute("SELECT * FROM social_actions WHERE request_id=?",(payload.requestID,)).fetchone()
            if old:
                if old["request_hash"]!=hashed:raise HTTPException(409,"操作编号已用于其他内容")
                return json.loads(old["result"])
            report=db.execute("SELECT * FROM social_reports WHERE id=? AND created_at>?",(payload.reportID,int(time.time())-30*86400)).fetchone()
            restriction=db.execute("SELECT * FROM social_restrictions WHERE source_report_id=? AND muted_until>?",(payload.reportID,int(time.time()))).fetchone()
            if report is None and not (payload.action=="restore_user" and restriction):
                raise HTTPException(404,"举报记录不存在或证据已过期")
            target_id=report["target_id"] if report else restriction["account_id"]
            now=int(time.time())
            if payload.action=="remove_content":
                if report["target_type"]=="moment":
                    self.delete_moment_in_db(db,report["content_id"])
                elif report["target_type"]=="comment":db.execute("DELETE FROM social_comments WHERE id=? AND author_id=?",(report["content_id"],target_id))
                elif report["target_type"]=="direct_message":db.execute("DELETE FROM social_messages WHERE id=? AND sender_id=?",(report["content_id"],target_id))
                else:raise HTTPException(422,"资料举报请使用警告或社交发布限制")
                self.notice(db,target_id,"safety","你的一条社交内容因违反社区规则被移除。")
            elif payload.action=="restrict_posting":
                db.execute("INSERT INTO social_restrictions VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET muted_until=MAX(muted_until,excluded.muted_until),source_report_id=excluded.source_report_id",(target_id,now+payload.durationSeconds,payload.reportID))
                self.notice(db,target_id,"safety","你的社交发布暂受限制，请遵守社区规则；限制不影响登录和查看通知。")
            elif payload.action=="restore_user":
                db.execute("DELETE FROM social_restrictions WHERE account_id=?",(target_id,))
                self.notice(db,target_id,"safety","你的社交发布限制已解除。")
            elif payload.action=="warn":self.notice(db,target_id,"safety","社区提醒：请文明交流，遵守社区规则。")
            if report:
                db.execute("UPDATE social_reports SET status=?,resolved_at=?,last_action=? WHERE id=?",("dismissed" if payload.action=="dismiss" else "resolved",now,payload.action,payload.reportID))
            result={"ok":True,"requestID":payload.requestID,"reportID":payload.reportID,"action":payload.action}
            db.execute("INSERT INTO social_actions VALUES(?,?,?,?,?,?,?,?,?)",(payload.requestID,hashed,payload.reportID,operator["account_id"],target_id,note,payload.action,now,json.dumps(result)))
        self.sweep_media()
        return result

    def operator_media(self,request,media_id):
        if not re.fullmatch(UUID_PATTERN,media_id):raise HTTPException(404,"图片不存在或已过期")
        with self.database(self.settings) as db:
            self.ops.scope(request,db,"community")
            available=False
            for row in db.execute("SELECT evidence FROM social_reports WHERE created_at>?",(int(time.time())-30*86400,)):
                try:
                    if any(item["id"]==media_id for item in json.loads(row[0]).get("media",[])):available=True;break
                except (ValueError,KeyError,TypeError):continue
            if not available or not db.execute("SELECT1 FROM social_media WHERE id=?".replace("SELECT1","SELECT 1"),(media_id,)).fetchone():raise HTTPException(404,"图片不存在或已过期")
        path=self.media_directory/(media_id+".jpg")
        if not path.is_file() or path.is_symlink():raise HTTPException(404,"图片不存在或已过期")
        return FileResponse(path,media_type="image/jpeg",headers={"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"})


def install_content_routes(router,app,social_user):
    @router.post("/media")
    async def upload(request:Request,user=Depends(social_user)):
        from fastapi.concurrency import run_in_threadpool
        content=await request.body()
        return await run_in_threadpool(app.state.social.upload_media,user,content,request.headers.get("content-type",""))

    @router.get("/media/{media_id}.jpg")
    def media(media_id:str,user=Depends(social_user)):
        return app.state.social.media_response(user,media_id)

    @router.get("/conversations")
    def conversations(limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.conversations(user,limit,cursor)

    @router.get("/conversations/{target_id}/messages")
    def messages(target_id:str,limit:int=Query(default=30,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.messages(user,target_id,limit,cursor)

    @router.post("/conversations/{target_id}/messages")
    def send(target_id:str,payload:MessageCreate,user=Depends(social_user)):
        return app.state.social.send_message(user,target_id,payload)

    @router.post("/conversations/{target_id}/read")
    def read(target_id:str,payload:MessageRead,user=Depends(social_user)):
        return app.state.social.read_messages(user,target_id,payload)

    @router.put("/conversations/{target_id}/pin")
    def pin_conversation(target_id:str,payload:ConversationPin,user=Depends(social_user)):
        return app.state.social.pin_conversation(user,target_id,payload)

    @router.post("/conversations/{target_id}/clear")
    def clear_conversation(target_id:str,payload:ConversationClear,user=Depends(social_user)):
        return app.state.social.clear_conversation(user,target_id,payload)

    @router.get("/moments")
    def moments(kind:Literal["all","following","mine"]="all",userID:str|None=Query(default=None,min_length=3,max_length=80),limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.moments(user,kind,userID,limit,cursor)

    @router.post("/moments")
    def create_moment(payload:MomentCreate,user=Depends(social_user)):
        return app.state.social.create_moment(user,payload)

    @router.get("/moments/{moment_id}")
    def get_moment(moment_id:str,user=Depends(social_user)):
        return app.state.social.get_moment(user,moment_id)

    @router.delete("/moments/{moment_id}")
    def delete_moment(moment_id:str,user=Depends(social_user)):
        return app.state.social.delete_moment(user,moment_id)

    @router.put("/moments/{moment_id}/like")
    def like(moment_id:str,payload:ContentMutation,user=Depends(social_user)):
        return app.state.social.like_moment(user,moment_id,payload,True)

    @router.delete("/moments/{moment_id}/like")
    def unlike(moment_id:str,payload:ContentMutation,user=Depends(social_user)):
        return app.state.social.like_moment(user,moment_id,payload,False)

    @router.get("/moments/{moment_id}/comments")
    def comments(moment_id:str,limit:int=Query(default=20,ge=1,le=50),cursor:str|None=Query(default=None,max_length=1024),user=Depends(social_user)):
        return app.state.social.comments(user,moment_id,limit,cursor)

    @router.post("/moments/{moment_id}/comments")
    def comment(moment_id:str,payload:CommentCreate,user=Depends(social_user)):
        return app.state.social.create_comment(user,moment_id,payload)

    @router.delete("/comments/{comment_id}")
    def delete_comment(comment_id:str,user=Depends(social_user)):
        return app.state.social.delete_comment(user,comment_id)

    @router.post("/reports")
    def report(payload:SocialReport,user=Depends(social_user)):
        return app.state.social.submit_report(user,payload)

    @router.get("/reports/mine")
    def my_reports(user=Depends(social_user)):
        return app.state.social.my_reports(user)

    admin=APIRouter(prefix="/admin/v2/services/account/social")

    @admin.post("/moderation/query")
    def query(payload:SocialModerationQuery,request:Request):
        return app.state.social.moderation_query(request,payload)

    @admin.post("/moderation/action")
    def action(payload:SocialModerationAction,request:Request):
        return app.state.social.moderation_action(request,payload)

    @admin.get("/media/{media_id}.jpg")
    def operator_media(media_id:str,request:Request):
        return app.state.social.operator_media(request,media_id)

    app.include_router(admin)
