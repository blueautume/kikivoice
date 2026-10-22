import hashlib
import sqlite3
import time

from app import safety
from conftest import create_room, headers, login
from test_account_bridge import account_service, exchange, payload, profile, signed


A = "kiki_aaaaaaaaaaaaaaaa"
B = "kiki_bbbbbbbbbbbbbbbb"
C = "kiki_cccccccccccccccc"


def block(service, actor=A, target=B, enabled=True, epoch=1, withdrawal=0):
    return signed(service,"social-block",{"accountID":actor,"targetID":target,"blocked":enabled,
        "consentEpoch":epoch,"lastWithdrawalEpoch":withdrawal})


def policy(service, actor=A, targets=None):
    return signed(service,"social-policy",{"accountID":actor,"targetIDs":targets or []})


def test_account_only_blocks_share_authority_without_creating_media_users(account_service):
    s = account_service
    assert block(s).json() == {"schemaVersion":1,"accountID":A,"targetID":B,"blocked":True}
    assert block(s,actor=C,target=A).status_code == 200
    result = policy(s,A,[B,C]).json()
    assert result == {"schemaVersion":1,"accountID":A,"blockedUserIDs":[B,C],"currentRooms":[],"roomsStale":True}
    assert policy(s,B).json()["blockedUserIDs"] == [A]
    assert s.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    assert s.app.state.db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
    assert block(s,enabled=False).json()["blocked"] is False
    assert policy(s,A).json()["blockedUserIDs"] == [C]


def test_voice_safety_and_account_blocks_are_one_relation(account_service):
    s = account_service
    first = exchange(s,user=profile(account_id=A)).json()
    second = exchange(s,auth=hashlib.sha256(b"second").hexdigest(),user=profile(account_id=B)).json()
    assert s.client.put("/v1/safety/blocks/"+B,headers=headers(first)).status_code == 200
    assert policy(s,B).json()["blockedUserIDs"] == [A]
    assert block(s,enabled=False).status_code == 200
    assert s.client.get("/v1/safety",headers=headers(first)).json()["blockedUsers"] == []
    assert block(s).status_code == 200
    snapshot = s.client.get("/v1/safety",headers=headers(first)).json()
    assert snapshot["blockedUsers"][0]["userID"] == B
    assert block(s,target=C).status_code == 200
    # The safety screen still permits removing account-only targets.
    assert {r["userID"] for r in s.client.get("/v1/safety",headers=headers(first)).json()["blockedUsers"]} == {B,C}
    assert s.client.delete("/v1/safety/blocks/"+C,headers=headers(first)).status_code == 200
    assert policy(s,A).json()["blockedUserIDs"] == [B]


def test_voice_ban_does_not_disable_account_social(account_service):
    s = account_service
    first = exchange(s,user=profile(account_id=A)).json()
    with s.app.state.db:
        s.app.state.db.execute("INSERT INTO safety_restrictions(user_id,banned_until) VALUES(?,?)",(A,int(time.time())+3600))
    assert block(s).status_code == 200
    assert policy(s).json()["blockedUserIDs"] == [B]
    assert s.client.get("/v1/rooms",headers=headers(first)).status_code == 403


def test_signed_policy_rejects_replay_forgery_invalid_targets_and_unsupported_paths(account_service):
    s = account_service
    query = {"accountID":A,"targetIDs":[B]}
    assert signed(s,"social-policy",query,secret="wrong").status_code == 401
    nonce = "a"*32
    assert signed(s,"social-policy",query,nonce=nonce).status_code == 200
    assert signed(s,"social-block",{"accountID":A,"targetID":B,"blocked":True,"consentEpoch":1,"lastWithdrawalEpoch":0},nonce=nonce).status_code == 401
    assert signed(s,"social-policy",{"accountID":A,"targetIDs":[B,B]}).status_code == 422
    assert signed(s,"social-policy",{"accountID":A,"targetIDs":["missing"]}).status_code == 422
    assert signed(s,"social-policy",{"accountID":A,"targetIDs":[B]*51}).status_code == 422
    assert signed(s,"social-policy",{"accountID":A,"targetIDs":[],"admin":True}).status_code == 422
    assert block(s,target=A).status_code == 422
    assert signed(s,"social-block",{"accountID":A,"targetID":B,"blocked":1,"consentEpoch":1,"lastWithdrawalEpoch":0}).status_code == 422
    assert signed(s,"social-policy/",query).status_code == 404
    assert signed(s,"social-policy?unexpected=1",query).status_code == 404


def test_complete_bidirectional_block_list_is_never_silently_truncated(account_service):
    s = account_service
    with s.app.state.db:
        s.app.state.db.executemany("INSERT INTO safety_blocks VALUES(?,?,?)",[(f"kiki_{i:016x}",A,1) for i in range(10001)])
    assert policy(s).status_code == 503
    with s.app.state.db:
        s.app.state.db.execute("DELETE FROM safety_blocks WHERE user_id=?",("kiki_0000000000002710",))
    assert len(policy(s).json()["blockedUserIDs"]) == 10000


def test_actor_outgoing_limit_matches_voice_safety_and_existing_retry_is_idempotent(account_service):
    s = account_service
    with s.app.state.db:
        s.app.state.db.executemany("INSERT INTO safety_blocks VALUES(?,?,?)",[(A,f"kiki_{i:016x}",1) for i in range(500)])
    assert block(s).status_code == 409
    assert block(s,target="kiki_0000000000000000").status_code == 200
    assert block(s,target="kiki_0000000000000000",enabled=False).status_code == 200
    assert block(s).status_code == 200


def test_unknown_or_stale_sfu_never_produces_live_room_shortcuts(account_service):
    s = account_service
    host = exchange(s,user=profile(account_id=B)).json()
    room = create_room(s,host)
    s.rtc.rooms[room["id"]].add(B)
    assert policy(s,A,[B]).json()["currentRooms"] == []
    admin = s.app.state.admin
    admin.sfu_at = admin.clock()-16
    admin.sfu_rooms = {room["id"]:1}
    assert policy(s,A,[B]).json()["roomsStale"] is True
    admin.sfu_at = admin.clock()
    admin.sfu_failed = True
    assert policy(s,A,[B]).json()["currentRooms"] == []


def test_current_rooms_use_fresh_sample_no_sfu_rpc_and_recheck_block_and_rights(account_service):
    s = account_service
    host = exchange(s,user=profile(account_id=B)).json()
    room = create_room(s,host)
    admin = s.app.state.admin
    admin.sfu_at = admin.clock()
    admin.sfu_rooms = {room["id"]:1}
    async def forbidden_rpc():
        raise AssertionError("social policy must never await media")
    s.rtc.list_rooms = forbidden_rpc
    assert policy(s,A,[B]).json()["currentRooms"] == [{"userID":B,"roomID":room["id"]}]
    assert policy(s,A,[C]).json()["currentRooms"] == []
    assert block(s,actor=B,target=A).status_code == 200
    assert policy(s,A,[B]).json()["currentRooms"] == []
    assert block(s,actor=B,target=A,enabled=False).status_code == 200
    with s.app.state.db:
        s.app.state.db.execute("INSERT INTO safety_restrictions(user_id,banned_until) VALUES(?,?)",(B,int(time.time())+600))
    assert policy(s,A,[B]).json()["currentRooms"] == []
    with s.app.state.db:
        s.app.state.db.execute("DELETE FROM safety_restrictions WHERE user_id=?",(B,))
        s.app.state.db.execute("UPDATE consents SET withdrawn_at=? WHERE user_id=?",(int(time.time()),B))
    assert policy(s,A,[B]).json()["currentRooms"] == []


def test_ended_and_deleted_host_never_return_from_fresh_cached_sfu(account_service):
    s = account_service
    host = exchange(s,user=profile(account_id=B)).json()
    room = create_room(s,host)
    admin = s.app.state.admin
    admin.sfu_at = admin.clock()
    admin.sfu_rooms = {room["id"]:1}
    with s.app.state.db:
        s.app.state.db.execute("UPDATE rooms SET status='closed' WHERE id=?",(room["id"],))
    assert policy(s,A,[B]).json()["currentRooms"] == []
    with s.app.state.db:
        s.app.state.db.execute("UPDATE rooms SET status='active' WHERE id=?",(room["id"],))
        s.app.state.db.execute("UPDATE users SET deleted=1 WHERE id=?",(B,))
    assert policy(s,A,[B]).json()["currentRooms"] == []


def test_account_only_withdrawal_and_deletion_clear_both_directions_and_reject_late_write(account_service):
    s = account_service
    assert block(s).status_code == 200
    assert block(s,actor=C,target=A).status_code == 200
    withdrawal = {"authorizationID":"f"*64,"reason":"withdrawal","accountID":A,"consentEpoch":2}
    assert signed(s,"revoke",withdrawal).status_code == 200
    assert policy(s).json()["blockedUserIDs"] == []
    assert block(s).status_code == 409
    late = payload(s,user=profile(account_id=A))
    late.update(consentEpoch=1,lastWithdrawalEpoch=0)
    assert signed(s,"session",late).status_code == 409
    assert block(s,epoch=3,withdrawal=2).status_code == 200
    assert signed(s,"delete",{"accountID":A}).status_code == 200
    assert policy(s).json()["blockedUserIDs"] == []
    assert block(s,epoch=4,withdrawal=2).status_code == 409
    assert block(s,actor=C,target=A).status_code == 409
    assert s.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


def test_social_new_epoch_also_protects_against_old_account_voice_exchange(account_service):
    s = account_service
    assert block(s,epoch=3,withdrawal=2).status_code == 200
    old = payload(s,user=profile(account_id=A))
    old.update(consentEpoch=1,lastWithdrawalEpoch=0)
    assert signed(s,"session",old).status_code == 409
    assert s.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    fresh = {**old,"consentEpoch":3,"lastWithdrawalEpoch":2}
    assert signed(s,"session",fresh).status_code == 200
    assert policy(s).json()["blockedUserIDs"] == [B]


def test_new_epoch_block_survives_delayed_withdrawal_for_old_voice_source(account_service):
    s = account_service
    first = payload(s,user=profile(account_id=A))
    first.update(consentEpoch=1,lastWithdrawalEpoch=0)
    assert signed(s,"session",first).status_code == 200
    assert block(s,epoch=3,withdrawal=2).status_code == 200
    withdrawal = {"authorizationID":first["authorizationID"],"reason":"withdrawal","accountID":A,"consentEpoch":2}
    assert signed(s,"revoke",withdrawal).status_code == 200
    assert policy(s).json()["blockedUserIDs"] == [B]
    assert block(s,epoch=1).status_code == 409
    assert block(s,epoch=3,withdrawal=2,enabled=False).status_code == 200


def test_original_fk_migration_keeps_existing_blocks_and_reopens_without_loss(tmp_path):
    path = tmp_path/"old.sqlite3"
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("""CREATE TABLE users(id TEXT PRIMARY KEY);
        INSERT INTO users VALUES('first'),('second');
        CREATE TABLE safety_blocks(user_id TEXT NOT NULL REFERENCES users(id),
            blocked_user_id TEXT NOT NULL REFERENCES users(id),created_at INTEGER NOT NULL,
            PRIMARY KEY(user_id,blocked_user_id));
        INSERT INTO safety_blocks VALUES('first','second',123);""")
    safety.initialize_database(db)
    db.commit()
    assert tuple(db.execute("SELECT * FROM safety_blocks").fetchone()) == ("first","second",123)
    assert not db.execute("PRAGMA foreign_key_list(safety_blocks)").fetchall()
    db.execute("INSERT INTO safety_blocks VALUES('account-only','other-account',456)")
    db.commit()
    safety.initialize_database(db)
    assert db.execute("SELECT COUNT(*) FROM safety_blocks").fetchone()[0] == 2
    assert not db.execute("PRAGMA foreign_key_check").fetchall()
    db.close()


def test_recent_history_keeps_only_20_and_erasure_is_scoped_without_deleting_rooms(lab):
    actor, other = login(lab), login(lab)
    uid, other_id = actor["user"]["id"],other["user"]["id"]
    ids = ["lk_"+f"{i:032x}" for i in range(21)]
    with lab.app.state.db:
        lab.app.state.db.executemany("INSERT INTO rooms VALUES(?,?,?,?,?,'closed',?)",[(rid,uid,"历史","闲聊",0,1) for rid in ids])
    for rid in ids:
        assert lab.client.post("/v1/history/"+rid,headers=headers(actor)).status_code == 200
    assert lab.client.post("/v1/history/"+ids[-1],headers=headers(other)).status_code == 200
    data = lab.client.get("/v1/library",headers=headers(actor)).json()
    assert len(data["recents"]) == 20 and data["recents"][0]["id"] == ids[-1]
    assert ids[0] not in {room["id"] for room in data["recents"]}
    assert all(room["status"] == "ended" and room["audience"] == 0 for room in data["recents"])
    assert lab.app.state.db.execute("SELECT COUNT(*) FROM history WHERE user_id=?",(uid,)).fetchone()[0] == 20
    assert lab.client.delete("/v1/history/"+ids[-1],headers=headers(actor)).status_code == 200
    assert len(lab.client.get("/v1/library",headers=headers(actor)).json()["recents"]) == 19
    assert lab.client.delete("/v1/history",headers=headers(actor)).status_code == 200
    assert lab.client.get("/v1/library",headers=headers(actor)).json()["recents"] == []
    assert len(lab.client.get("/v1/library",headers=headers(other)).json()["recents"]) == 1
    assert lab.app.state.db.execute("SELECT COUNT(*) FROM rooms").fetchone()[0] == 21


def test_laboratory_mode_never_accepts_social_account_bridge(lab):
    assert policy(lab).status_code == 404
    assert block(lab).status_code == 404
