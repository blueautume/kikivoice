"""Polling does not repeat whole-server per-member SQL or cache authorization."""
from collections import Counter
import hashlib
import time

from fastapi import HTTPException
import pytest

from conftest import create_room, headers, login
from test_room_actions import act, authorize, setup_room, state, token


def trace_state(lab, room, account, count=1):
    statements = []
    db = lab.app.state.db
    db.set_trace_callback(statements.append)
    try:
        for _ in range(count):
            state(lab, room, account)
    finally:
        db.set_trace_callback(None)
    return statements


def test_repeated_state_reads_reuse_request_presence_and_leave_stable_model_read_only(lab):
    owner, other = login(lab,"Owner"),login(lab,"Other")
    first, second = create_room(lab,owner),create_room(lab,other)
    token(lab,first,owner)
    token(lab,second,other)
    state(lab,first,owner)  # Establish presence once.
    baseline_sql = trace_state(lab,first,owner)
    # Populate a different room: the number of auth queries for first stays constant.
    for index in range(20):
        account = login(lab,f'Listener{index}')
        token(lab,second,account)
    state(lab,first,owner)
    expanded_sql = trace_state(lab,first,owner)
    assert len(expanded_sql) == len(baseline_sql)
    calls = Counter()
    original_participants, original_rooms = lab.rtc.participants,lab.rtc.list_rooms
    async def participants(room_id):
        calls[("participants",room_id)] += 1
        return await original_participants(room_id)
    async def rooms():
        calls["rooms"] += 1
        return await original_rooms()
    lab.rtc.participants,lab.rtc.list_rooms = participants,rooms
    changes = lab.app.state.db.total_changes
    statements = trace_state(lab,first,owner,count=5)
    assert calls[("participants",first["id"])] == 5
    assert calls[("participants",second["id"])] == 0
    assert calls["rooms"] == 5
    assert lab.app.state.db.total_changes == changes
    assert not lab.app.state.db.in_transaction
    assert not any(statement.lstrip().upper().startswith(("INSERT ","UPDATE ","DELETE ","COMMIT","BEGIN")) for statement in statements)


@pytest.mark.parametrize("change", ["revoked", "expired", "withdrawn", "wrong-document", "deleted"])
def test_next_state_query_rechecks_current_session_consent_and_expiry(lab,change):
    room,(owner,member),tokens = setup_room(lab)
    act(lab,room,member,"request_seat")
    act(lab,room,owner,"approve_request",targetUserID=member["user"]["id"])
    before = state(lab,room,owner)
    assert any(row["userID"]==member["user"]["id"] for row in before["members"])
    digest = hashlib.sha256(member["token"].encode()).hexdigest()
    with lab.app.state.db:
        if change == "revoked":
            lab.app.state.db.execute("UPDATE sessions SET revoked_at=?,revoked_reason='logout' WHERE token_hash=?",(int(time.time()),digest))
        elif change == "expired":
            lab.app.state.db.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?",(int(time.time())-1,digest))
        elif change == "withdrawn":
            lab.app.state.db.execute("UPDATE consents SET withdrawn_at=? WHERE user_id=?",(int(time.time()),member["user"]["id"]))
        elif change == "wrong-document":
            lab.app.state.db.execute("UPDATE consents SET document_hash=? WHERE user_id=?",("0"*64,member["user"]["id"]))
        else:
            lab.app.state.db.execute("UPDATE users SET deleted=1 WHERE id=?",(member["user"]["id"],))
    with pytest.raises(HTTPException):
        authorize(lab,tokens[1])
    after = state(lab,room,owner)
    assert not any(row["userID"]==member["user"]["id"] for row in after["members"])
    assert after["seats"][1]["userID"] is None
    assert member["user"]["id"] not in lab.rtc.rooms[room["id"]]


@pytest.mark.parametrize("method,path", [("POST","/v1/auth/logout"),("DELETE","/v1/me/legal-consent")])
def test_explicit_revocation_between_polls_is_immediate(lab,method,path):
    room,(owner,member),tokens = setup_room(lab)
    state(lab,room,owner)
    assert lab.client.request(method,path,headers=headers(member)).status_code == 200
    result = state(lab,room,owner)
    assert len(result["members"]) == 1 and result["members"][0]["userID"] == owner["user"]["id"]
    with pytest.raises(HTTPException):
        authorize(lab,tokens[1])


def test_partial_room_model_is_repaired_without_replacing_existing_occupied_seats(lab):
    room,(owner,member),_ = setup_room(lab)
    original = state(lab,room,owner)
    with lab.app.state.db:
        lab.app.state.db.execute("DELETE FROM room_seats WHERE room_id=? AND seat_index=8",(room["id"],))
    repaired = state(lab,room,owner)
    assert len(repaired["seats"]) == 8
    assert repaired["seats"][:7] == original["seats"][:7]
    assert repaired["seats"][7] == {"index":8,"userID":None,"locked":False,"audioLocked":False}
    assert not lab.app.state.db.in_transaction
    assert not any(sql.lstrip().upper().startswith(("INSERT ","UPDATE ","DELETE ")) for sql in trace_state(lab,room,owner))


def test_request_presence_is_invalidated_when_pending_permissions_fall_back_to_media_removal(lab):
    room,(owner,member),_ = setup_room(lab)
    state(lab,room,owner)
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE room_members SET audio_muted=1 WHERE room_id=? AND user_id=?",(room["id"],member["user"]["id"]))
        lab.app.state.db.execute("INSERT INTO media_cleanup VALUES(?,?,'permissions')",(room["id"],member["user"]["id"]))
    lab.rtc.permission_failure = True
    calls = []
    original = lab.rtc.participants
    async def participants(room_id):
        calls.append(room_id)
        return await original(room_id)
    lab.rtc.participants = participants
    result = state(lab,room,owner)
    participant = next(row for row in result["members"] if row["userID"]==member["user"]["id"])
    assert participant["audioMuted"] is True and participant["online"] is False
    assert calls == [room["id"],room["id"]]
    assert not lab.app.state.db.execute("SELECT 1 FROM media_cleanup").fetchone()


def test_target_room_poll_still_expires_due_disconnection_in_another_room(lab):
    first_owner = login(lab,"FirstOwner")
    first = create_room(lab,first_owner)
    token(lab,first,first_owner)
    second,(second_owner,guest),_ = setup_room(lab)
    act(lab,second,guest,"request_seat")
    act(lab,second,second_owner,"approve_request",targetUserID=guest["user"]["id"])
    lab.rtc.rooms[second["id"]].discard(guest["user"]["id"])
    with lab.app.state.db:
        lab.app.state.db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=excluded.offline_since",
            (second["id"],guest["user"]["id"],int(time.time())-59))
    calls = []
    original = lab.rtc.participants
    async def participants(room_id):
        calls.append(room_id)
        return await original(room_id)
    lab.rtc.participants = participants
    state(lab,first,first_owner)
    assert second["id"] not in calls
    assert lab.app.state.db.execute("SELECT active FROM room_members WHERE room_id=? AND user_id=?",(second["id"],guest["user"]["id"])).fetchone()[0] == 1
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE room_presence SET offline_since=? WHERE room_id=? AND user_id=?",(int(time.time())-61,second["id"],guest["user"]["id"]))
    calls.clear()
    state(lab,first,first_owner)
    assert calls.count(first["id"]) == 1 and calls.count(second["id"]) == 1
    assert lab.app.state.db.execute("SELECT active FROM room_members WHERE room_id=? AND user_id=?",(second["id"],guest["user"]["id"])).fetchone()[0] == 0
    assert lab.app.state.db.execute("SELECT user_id FROM room_seats WHERE room_id=? AND seat_index=2",(second["id"],)).fetchone()[0] is None


def test_due_presence_elsewhere_is_refreshed_before_removing_a_reconnected_member(lab):
    first_owner = login(lab,"FirstOwner")
    first = create_room(lab,first_owner)
    token(lab,first,first_owner)
    second,(second_owner,guest),tokens = setup_room(lab)
    act(lab,second,guest,"request_seat")
    act(lab,second,second_owner,"approve_request",targetUserID=guest["user"]["id"])
    with lab.app.state.db:
        lab.app.state.db.execute("INSERT INTO room_presence VALUES(?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=excluded.offline_since",
            (second["id"],guest["user"]["id"],int(time.time())-61))
    state(lab,first,first_owner)
    result = state(lab,second,second_owner)
    member = next(row for row in result["members"] if row["userID"]==guest["user"]["id"])
    assert member["online"] is True and member["seatIndex"] == 2
    assert lab.app.state.db.execute("SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?",(second["id"],guest["user"]["id"])).fetchone()[0] is None
    assert authorize(lab,tokens[1]).user_id == guest["user"]["id"]


def test_target_room_poll_still_removes_other_room_revoked_identity_immediately(lab):
    first_owner = login(lab,"FirstOwner")
    first = create_room(lab,first_owner)
    token(lab,first,first_owner)
    second,(second_owner,guest),tokens = setup_room(lab)
    state(lab,second,second_owner)
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE consents SET withdrawn_at=? WHERE user_id=?",(int(time.time()),guest["user"]["id"]))
    state(lab,first,first_owner)
    assert guest["user"]["id"] not in lab.rtc.rooms[second["id"]]
    assert lab.app.state.db.execute("SELECT active FROM room_members WHERE room_id=? AND user_id=?",(second["id"],guest["user"]["id"])).fetchone()[0] == 0
    with pytest.raises(HTTPException):
        authorize(lab,tokens[1])


def test_target_room_state_queries_do_not_grow_with_its_audience(lab):
    owner = login(lab,"Owner")
    room = create_room(lab,owner)
    token(lab,room,owner)
    state(lab,room,owner)
    small = trace_state(lab,room,owner)
    for index in range(20):
        guest = login(lab,f'Guest{index}')
        token(lab,room,guest)
    state(lab,room,owner)
    large = trace_state(lab,room,owner)
    assert len(large) == len(small)
    result = state(lab,room,owner)
    assert len(result["members"]) == 21 and len(result["seats"]) == 8
    assert result["me"]["seatIndex"] == 1 and result["me"]["canPublishAudio"] is True
    listeners = [member for member in result["members"] if member["userID"] != owner["user"]["id"]]
    assert all(member["seatIndex"] is None and member["canPublishAudio"] is False for member in listeners)
