"""Signed, result-only relationship membership bridge.

Birth details and Four Pillars never enter the voice service. The account
service can ask only for the occupants of a room its requester has joined.
"""
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from .account_bridge import verify_request


class AccountQuery(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    accountID: str = Field(pattern=r"^kiki_[a-zA-Z0-9_]{8,64}$")


class RoomQuery(AccountQuery):
    roomID: str = Field(pattern=r"^lk_[a-f0-9]{32}$")


def build_router(app, settings, lock, valid_session, bump):
    router = APIRouter()

    @router.post("/internal/v1/account/relationship-members")
    async def relationship_members(payload: RoomQuery, request: Request):
        async with lock:
            verify_request(settings, app.state.db, request, await request.body())
            db = app.state.db
            room = db.execute("SELECT status FROM rooms WHERE id=?", (payload.roomID,)).fetchone()
            member = db.execute("""SELECT session_hash FROM room_members
                WHERE room_id=? AND user_id=? AND active=1""",
                (payload.roomID, payload.accountID)).fetchone()
            if room is None or room["status"] != "active" or member is None or not valid_session(member[0]):
                raise HTTPException(403, "请先进入有效的语聊房间")
            blocked = {row[0] for row in db.execute("""SELECT blocked_user_id FROM safety_blocks WHERE user_id=?
                UNION SELECT user_id FROM safety_blocks WHERE blocked_user_id=?""",
                (payload.accountID, payload.accountID))}
            rows = db.execute("""SELECT s.user_id,m.session_hash FROM room_seats s
                JOIN room_members m ON m.room_id=s.room_id AND m.user_id=s.user_id AND m.active=1
                JOIN users u ON u.id=m.user_id AND u.deleted=0
                WHERE s.room_id=? ORDER BY s.seat_index LIMIT 8""", (payload.roomID,)).fetchall()
            ids = [row["user_id"] for row in rows
                   if row["user_id"] not in blocked and valid_session(row["session_hash"])]
            revision = db.execute("SELECT revision FROM room_revisions WHERE room_id=?", (payload.roomID,)).fetchone()
            return JSONResponse({"roomID": payload.roomID, "roomRevision": revision[0] if revision else 0,
                                 "memberIDs": ids}, headers={"Cache-Control": "no-store"})

    @router.post("/internal/v1/account/relationship-refresh")
    async def relationship_refresh(payload: AccountQuery, request: Request):
        async with lock:
            verify_request(settings, app.state.db, request, await request.body())
            # This is an invalidation hint only, containing no birth data or
            # relationship result. Existing room-state polling delivers it.
            db = app.state.db
            rooms = db.execute("""SELECT m.room_id FROM room_members m JOIN rooms r ON r.id=m.room_id
                WHERE m.user_id=? AND m.active=1 AND r.status='active'""", (payload.accountID,)).fetchall()
            with db:
                for row in rooms:
                    bump(row[0])
            return JSONResponse({"ok": True}, headers={"Cache-Control": "no-store"})

    return router
