"""Account social policy backed by the same block relation used inside voice.

No account profile/session or voice admission is created by these signed calls.
Policy reads never contact the SFU: a fresh administrator sample is optional and
absence of one hides current-room shortcuts while retaining exact block policy.
"""
import hashlib
import time

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .account_bridge import TOMBSTONE_SECONDS, verify_request

ACCOUNT_ID = r"^kiki_[a-zA-Z0-9_]{8,64}$"
MAX_POLICY_BLOCKS = 10000
ROOM_SAMPLE_SECONDS = 15
PATHS = frozenset({"/internal/v1/account/social-policy", "/internal/v1/account/social-block"})


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class PolicyQuery(Model):
    accountID: str = Field(pattern=ACCOUNT_ID)
    targetIDs: list[str] = Field(default_factory=list, max_length=50)

    @field_validator("targetIDs")
    @classmethod
    def targets(cls, value):
        import re
        if len(set(value)) != len(value) or any(not re.fullmatch(ACCOUNT_ID, item) for item in value):
            raise ValueError("Invalid social account IDs")
        return value


class BlockUpdate(Model):
    accountID: str = Field(pattern=ACCOUNT_ID)
    targetID: str = Field(pattern=ACCOUNT_ID)
    blocked: bool = Field(strict=True)
    consentEpoch: int = Field(strict=True, ge=1, le=9223372036854775807)
    lastWithdrawalEpoch: int = Field(strict=True, ge=0, le=9223372036854775807)


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS account_social_privacy(
      user_id TEXT PRIMARY KEY,consent_epoch INTEGER NOT NULL DEFAULT 0,
      withdrawal_epoch INTEGER NOT NULL DEFAULT 0,expires_at INTEGER NOT NULL);
    """)


def prune(db, now=None):
    db.execute("DELETE FROM account_social_privacy WHERE expires_at<=?",(int(time.time()) if now is None else now,))


def clear_account(app, user_id, *, withdrawal_epoch=None):
    """Erase account-only blocks too; a delayed withdrawal preserves newer data."""
    db = app.state.db
    if withdrawal_epoch is None:
        app.state.safety.clear_user(user_id)
        db.execute("DELETE FROM account_social_privacy WHERE user_id=?", (user_id,))
        return
    row = db.execute("SELECT * FROM account_social_privacy WHERE user_id=?", (user_id,)).fetchone()
    voice = db.execute("SELECT consent_epoch FROM account_privacy_state WHERE user_id=?",(user_id,)).fetchone()
    consent_epoch = max(row["consent_epoch"] if row else 0,voice[0] if voice else 0)
    if consent_epoch <= withdrawal_epoch:
        app.state.safety.clear_user(user_id)
    db.execute("""INSERT INTO account_social_privacy(user_id,withdrawal_epoch,expires_at) VALUES(?,?,?)
        ON CONFLICT(user_id) DO UPDATE SET withdrawal_epoch=MAX(withdrawal_epoch,excluded.withdrawal_epoch),
        expires_at=MAX(expires_at,excluded.expires_at)""", (user_id,withdrawal_epoch,int(time.time())+TOMBSTONE_SECONDS))


def bilateral_blocks(db, user_id):
    rows = db.execute("""SELECT blocked_user_id AS peer FROM safety_blocks WHERE user_id=?
        UNION SELECT user_id AS peer FROM safety_blocks WHERE blocked_user_id=?
        ORDER BY peer LIMIT ?""", (user_id,user_id,MAX_POLICY_BLOCKS+1)).fetchall()
    if len(rows) > MAX_POLICY_BLOCKS:
        # A partial deny list would silently expose blocked accounts.
        raise HTTPException(503,"社交屏蔽信息暂时无法完整取得，请稍后重试")
    return [row[0] for row in rows]


def current_rooms(app, user_id, target_ids, blocked, valid_session):
    admin, db = app.state.admin, app.state.db
    fresh = (admin.sfu_at is not None and not admin.sfu_failed
             and 0 <= admin.clock()-admin.sfu_at <= ROOM_SAMPLE_SECONDS)
    if not fresh:
        return [], True
    result = []
    for target in target_ids:
        if target in blocked:
            continue
        # Select only a durable active room hosted by an undeleted owner with
        # current business admission/consent. The SFU sample must confirm it.
        rows = db.execute("""SELECT r.id,m.session_hash FROM rooms r
            JOIN users u ON u.id=r.owner_id
            JOIN room_members m ON m.room_id=r.id AND m.user_id=r.owner_id
            WHERE r.owner_id=? AND u.deleted=0 AND r.status='active' AND m.active=1
            ORDER BY r.created_at DESC,r.id DESC""", (target,)).fetchall()
        for row in rows:
            if (admin.sfu_rooms.get(row["id"],0) > 0 and valid_session(row["session_hash"])
                    and not db.execute("SELECT 1 FROM room_bans WHERE room_id=? AND user_id=?",(row["id"],target)).fetchone()):
                result.append({"userID":target,"roomID":row["id"]})
                break
    return result, False


def build_router(app, settings, lock, valid_session):
    router = APIRouter()

    async def verify(request):
        if request.url.query:
            raise HTTPException(404,"接口不存在")
        verify_request(settings,app.state.db,request,await request.body())

    @router.post("/internal/v1/account/social-policy")
    async def policy(payload: PolicyQuery, request: Request):
        async with lock:
            await verify(request)
            blocked = bilateral_blocks(app.state.db,payload.accountID)
            rooms, stale = current_rooms(app,payload.accountID,payload.targetIDs,set(blocked),valid_session)
            return {"schemaVersion":1,"accountID":payload.accountID,"blockedUserIDs":blocked,
                    "currentRooms":rooms,"roomsStale":stale}

    @router.post("/internal/v1/account/social-block")
    async def update_block(payload: BlockUpdate, request: Request):
        async with lock:
            db = app.state.db
            await verify(request)
            uid, epoch = payload.accountID,payload.consentEpoch
            if payload.lastWithdrawalEpoch >= epoch:
                raise HTTPException(422,"同意记录版本不正确")
            for identifier in (uid,payload.targetID):
                if db.execute("SELECT 1 FROM account_deletions WHERE subject_hash=?",(hashlib.sha256(identifier.encode()).hexdigest(),)).fetchone():
                    raise HTTPException(409,"账号状态已更新，请刷新后重试")
                person = db.execute("SELECT deleted FROM users WHERE id=?",(identifier,)).fetchone()
                if person and person[0]:
                    raise HTTPException(409,"账号状态已更新，请刷新后重试")
            privacy = db.execute("SELECT * FROM account_privacy_state WHERE user_id=?",(uid,)).fetchone()
            social = db.execute("SELECT * FROM account_social_privacy WHERE user_id=?",(uid,)).fetchone()
            incident = db.execute("SELECT withdrawal_epoch FROM room_incident_privacy WHERE user_id=?",(uid,)).fetchone()
            watermark = max(privacy["withdrawal_epoch"] if privacy else 0,
                            social["withdrawal_epoch"] if social else 0,incident[0] if incident else 0)
            consent = max(privacy["consent_epoch"] if privacy else 0,social["consent_epoch"] if social else 0)
            if epoch <= watermark or epoch < consent:
                raise HTTPException(409,"同意记录已更新，请重新获取账号授权")
            with db:
                if payload.lastWithdrawalEpoch > watermark:
                    clear_account(app,uid,withdrawal_epoch=payload.lastWithdrawalEpoch)
                app.state.safety.block(uid,payload.targetID,payload.blocked,account_verified=True)
                db.execute("""INSERT INTO account_social_privacy VALUES(?,?,?,?)
                    ON CONFLICT(user_id) DO UPDATE SET consent_epoch=MAX(consent_epoch,excluded.consent_epoch),
                    withdrawal_epoch=MAX(withdrawal_epoch,excluded.withdrawal_epoch),
                    expires_at=MAX(expires_at,excluded.expires_at)""",
                    (uid,epoch,payload.lastWithdrawalEpoch,int(time.time())+TOMBSTONE_SECONDS))
            return {"schemaVersion":1,"accountID":uid,"targetID":payload.targetID,"blocked":payload.blocked}

    return router
