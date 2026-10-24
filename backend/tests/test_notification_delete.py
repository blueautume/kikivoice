"""Individual inbox deletion with temporary accounts and synthetic APNs only."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import threading
import time
import uuid

from fastapi import HTTPException
import pytest

from app.main import database
from test_api import authorization, client, login
from test_push import env, register, rows
from test_inbox_actions import (BASE, account_id, mutation, notice, notifications,
                                ok, request, send)


def path(notification_id):
    return BASE+"/notifications/"+notification_id


def test_delete_one_notice_preserves_other_entries_and_unread_totals(env):
    e=env;owner,peer,other=[login(e.c,name) for name in ("delete-owner","delete-peer","delete-other")]
    target=notice(e,owner)
    kept=notice(e,owner)
    theirs=notice(e,other)
    private=send(e,peer,owner)
    ok(e,"PUT",BASE+"/notifications/pin",owner,mutation(pinned=True))
    before=notifications(e,owner)["inboxState"]
    payload=mutation()
    ok(e,"DELETE",path(target),owner,payload)
    newer=notice(e,owner)
    with database(e.c.settings) as db:
        db.execute("UPDATE social_notifications SET created_at=?",(int(time.time()),))
    # A receipt retry cannot apply the deletion to another arrival in that second.
    ok(e,"DELETE",path(target.upper()),owner,{"requestID":payload["requestID"].upper()})
    page=notifications(e,owner)
    assert {item["id"] for item in page["notifications"]}=={kept,newer}
    assert page["unreadCount"]==2
    assert page["inboxState"]["isPinned"] is before["isPinned"] is True
    assert page["inboxState"]["clearedThroughSeq"]==before["clearedThroughSeq"]==0
    assert [item["id"] for item in notifications(e,other)["notifications"]]==[theirs]
    unified=e.c.get(BASE+"/inbox",headers=authorization(owner)).json()
    assert unified["unreadNotificationCount"]==2 and unified["unreadDirectMessageCount"]==1
    assert any(item.get("conversation",{}).get("id")==private["conversationID"] for item in unified["entries"])
    with database(e.c.settings) as db:
        assert db.execute("SELECT 1 FROM social_notifications WHERE id=?",(target,)).fetchone() is None
        assert db.execute("SELECT 1 FROM social_notification_sequence WHERE notification_id=?",(target,)).fetchone() is None
        assert db.execute("PRAGMA foreign_key_check").fetchall()==[]


@pytest.mark.parametrize("read_target",[False,True])
def test_delete_read_and_unread_notice_reconciles_only_its_own_unread_count(env,read_target):
    e=env;owner=login(e.c)
    target,kept=notice(e,owner),notice(e,owner)
    if read_target:
        response=request(e,"POST",BASE+"/notifications/read",owner,{"ids":[target]})
        assert response.status_code==200 and response.json()["unreadCount"]==1
    assert notifications(e,owner)["unreadCount"]==(1 if read_target else 2)
    ok(e,"DELETE",path(target),owner,mutation())
    page=notifications(e,owner)
    assert page["unreadCount"]==1 and page["notifications"][0]["id"]==kept


def test_delete_is_owner_bound_and_request_ids_cannot_cross_targets_or_operations(env):
    e=env;owner,other=login(e.c,"owned"),login(e.c,"foreign")
    target,kept,theirs=notice(e,owner),notice(e,owner),notice(e,other)
    payload=mutation()
    foreign=request(e,"DELETE",path(target),other,payload)
    missing=request(e,"DELETE",path(str(uuid.uuid4())),owner,mutation())
    expired=notice(e,owner,created_at=int(time.time())-30*86400-1)
    old=request(e,"DELETE",path(expired),owner,mutation())
    assert foreign.status_code==missing.status_code==old.status_code==404
    assert foreign.json()==missing.json()==old.json()
    assert request(e,"DELETE",path(target),owner,{"requestID":"bad"}).status_code==422
    assert request(e,"DELETE",path("invalid-id"),owner,mutation()).status_code==422
    assert request(e,"DELETE",path(target),owner,{**payload,"all":True}).status_code==422
    assert e.c.request("DELETE",path(target),json=payload).status_code==401
    assert target in {item["id"] for item in notifications(e,owner)["notifications"]}
    ok(e,"DELETE",path(target),owner,payload)
    assert request(e,"DELETE",path(kept),owner,payload).status_code==409
    assert request(e,"PUT",BASE+"/notifications/pin",owner,{**payload,"pinned":True}).status_code==409
    assert request(e,"DELETE",path(target),owner,mutation()).status_code==404
    # The same UUID in a different authenticated account is an independent receipt.
    ok(e,"DELETE",path(theirs),other,payload)
    assert [item["id"] for item in notifications(e,owner)["notifications"]]==[kept]


def test_delete_cancels_pending_and_claimed_push_but_retains_accepted_receipts_without_routes(env):
    e=env;owner,other=login(e.c,"push-delete-owner"),login(e.c,"push-delete-other")
    for _ in range(3): assert register(e,owner)[2].status_code==200
    assert register(e,other)[2].status_code==200
    target=notice(e,owner)
    accepted=e.s.claim();e.s.send_one(accepted)
    claimed=e.s.claim()
    assert len(e.requests)==1 and claimed["source_id"]==target
    newer,theirs=notice(e,owner),notice(e,other)
    ok(e,"DELETE",path(target),owner,mutation())
    old=[row for row in rows(e) if row["source_id"]==target]
    assert sorted(row["state"] for row in old)==["accepted","cancelled","cancelled"]
    assert all(row["lease_id"] is None and row["lease_until"] is None for row in old)
    assert all(row["state"]=="pending" for row in rows(e) if row["source_id"] in (newer,theirs))
    e.s.send_one(claimed)
    assert len(e.requests)==1, "An already claimed notification cannot send after deletion"
    assert e.c.get("/v1/push/destinations/"+accepted["id"],headers=authorization(owner)).status_code==404
    e.s.dispatch()
    assert len(e.requests)==5, "Only the three newer owner deliveries and the unrelated account delivery may send"
    assert all(row["state"]=="accepted" for row in rows(e) if row["source_id"] in (newer,theirs))
    assert e.c.get("/v1/push/status",headers=authorization(owner)).json()["badgeCount"]==1


def test_delete_and_receipt_are_atomic_and_failed_request_retries_safely(env):
    e=env;owner=login(e.c);register(e,owner)
    target,kept=notice(e,owner),notice(e,owner)
    payload=mutation()
    before=rows(e)
    with database(e.c.settings) as db:
        db.execute("CREATE TRIGGER reject_delete_receipt BEFORE INSERT ON social_receipts WHEN NEW.request_id='"+payload["requestID"]+"' BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END")
    response=request(e,"DELETE",path(target),owner,payload)
    assert response.status_code==500
    assert {item["id"] for item in notifications(e,owner)["notifications"]}=={target,kept}
    assert rows(e)==before
    with database(e.c.settings) as db:
        assert db.execute("SELECT 1 FROM social_notification_sequence WHERE notification_id=?",(target,)).fetchone()
        assert db.execute("SELECT 1 FROM social_receipts WHERE request_id=?",(payload["requestID"],)).fetchone() is None
        db.execute("DROP TRIGGER reject_delete_receipt")
    ok(e,"DELETE",path(target),owner,payload)
    assert [item["id"] for item in notifications(e,owner)["notifications"]]==[kept]


def test_delete_receipts_require_current_auth_and_new_mutations_fail_closed_on_policy_changes(env,monkeypatch):
    e=env;owner=login(e.c)
    target,kept=notice(e,owner),notice(e,owner)
    completed=mutation()
    ok(e,"DELETE",path(target),owner,completed)
    original=e.social.policy
    def unavailable(*args,**kwargs): raise HTTPException(503,"本地隐私服务不可用")
    monkeypatch.setattr(e.social,"policy",unavailable)
    ok(e,"DELETE",path(target),owner,completed)
    assert request(e,"DELETE",path(kept),owner,mutation()).status_code==503
    def revoked_during_policy(user,*args,**kwargs):
        policy=original(user,*args,**kwargs)
        with database(e.c.settings) as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?",(hashlib.sha256(owner["token"].encode()).hexdigest(),))
        return policy
    monkeypatch.setattr(e.social,"policy",revoked_during_policy)
    assert request(e,"DELETE",path(kept),owner,mutation()).status_code==401
    assert request(e,"DELETE",path(target),owner,completed).status_code==401
    with database(e.c.settings) as db:
        assert db.execute("SELECT 1 FROM social_notifications WHERE id=?",(kept,)).fetchone()


def test_individual_deletion_preserves_bulk_snapshot_watermark_and_new_sequences(env):
    e=env;owner=login(e.c)
    first,last=notice(e,owner),notice(e,owner)
    previous={item["id"]:item["seq"] for item in notifications(e,owner)["notifications"]}
    snapshot=e.c.get(BASE+"/inbox/snapshot",headers=authorization(owner)).json()["snapshot"]
    deletion=mutation();ok(e,"DELETE",path(last),owner,deletion)
    newer=notice(e,owner)
    bulk=mutation(snapshot=snapshot)
    ok(e,"POST",BASE+"/inbox/clear",owner,bulk)
    ok(e,"DELETE",path(last),owner,deletion)
    ok(e,"POST",BASE+"/inbox/clear",owner,bulk)
    page=notifications(e,owner)
    assert [item["id"] for item in page["notifications"]]==[newer] and page["unreadCount"]==1
    assert page["notifications"][0]["seq"]>max(previous.values())
    assert page["inboxState"]["clearedThroughSeq"]==previous[last]
    with database(e.c.settings) as db:
        assert db.execute("SELECT 1 FROM social_notifications WHERE id=?",(first,)).fetchone()
        assert db.execute("PRAGMA foreign_key_check").fetchall()==[]


def test_concurrent_same_request_id_commits_one_deletion_receipt(env,monkeypatch):
    e=env;owner=login(e.c)
    target=notice(e,owner);payload=mutation()
    barrier=threading.Barrier(2)
    original=e.social.policy
    def together(*args,**kwargs):
        result=original(*args,**kwargs)
        barrier.wait(timeout=5)
        return result
    monkeypatch.setattr(e.social,"policy",together)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(request,e,"DELETE",path(target),owner,payload) for _ in range(2)]
        responses=[future.result(timeout=10) for future in futures]
    assert all(response.status_code==200 and response.json()=={"ok":True} for response in responses)
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM social_receipts WHERE actor_id=? AND request_id=?",(account_id(e,owner),payload["requestID"])).fetchone()[0]==1
        assert db.execute("SELECT COUNT(*) FROM social_rate_events WHERE actor_id=? AND kind='inbox'",(account_id(e,owner),)).fetchone()[0]==1


def test_follow_source_replay_does_not_recreate_deleted_notification(env):
    e=env;owner,peer=login(e.c,"replay-owner"),login(e.c,"replay-peer")
    follow_path=BASE+"/follows/"+owner["user"]["id"]
    payload=mutation()
    assert request(e,"PUT",follow_path,peer,payload).status_code==200
    notices=notifications(e,owner)["notifications"]
    assert len(notices)==1
    ok(e,"DELETE",path(notices[0]["id"]),owner,mutation())
    for retry in (payload,mutation()):
        assert request(e,"PUT",follow_path,peer,retry).status_code==200
    assert notifications(e,owner)["notifications"]==[]
    assert e.c.get(BASE+"/people/"+owner["user"]["id"],headers=authorization(peer)).json()["person"]["following"] is True
