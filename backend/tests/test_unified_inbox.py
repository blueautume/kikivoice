"""Flat inbox pages and owner-only bulk mutations against local account storage."""
import time
import uuid

from fastapi import HTTPException
import pytest

from app.main import database
from app.social import Policy
from test_api import authorization, client, login
from test_push import env, friends, register, rows
from test_inbox_actions import (account_id, conversation_path, conversations, discard_setup_notices,
                                messages, mutation, notice, notifications, ok, request, send)


BASE = "/v1/social/inbox"


def inbox(e, actor, **params):
    response=e.c.get(BASE,headers=authorization(actor),params=params)
    assert response.status_code==200,response.text
    return response.json()


def snapshot(e, actor):
    response=e.c.get(BASE+"/snapshot",headers=authorization(actor))
    assert response.status_code==200,response.text
    assert set(response.json())=={"snapshot"}
    return response.json()["snapshot"]


def all_entries(e, actor, limit=2):
    result=[];cursor=None
    for _ in range(100):
        page=inbox(e,actor,limit=limit,**({"cursor":cursor} if cursor else {}))
        result.extend(page["entries"])
        cursor=page["nextCursor"]
        if cursor is None: return result
    pytest.fail("Inbox pagination did not terminate")


def entry_id(entry):
    return entry["kind"]+":"+entry.get("notification",entry.get("conversation"))["id"]


def add_notices(e, actor, count):
    owner=account_id(e,actor)
    with database(e.c.settings) as db:
        for index in range(count): e.social.notice(db,owner,"safety",f"本地测试通知 {index}")
    return notifications(e,actor,limit=50)["notifications"]


def use_one_arrival_second(e):
    with database(e.c.settings) as db:
        for table in ("social_messages","social_notifications"):
            db.execute("UPDATE "+table+" SET created_at=?",(int(time.time()),))


def test_flat_inbox_pages_pin_directs_then_sort_notifications_and_conversations_together(env):
    e=env
    a=login(e.c,"flat-owner")
    peers=[login(e.c,name) for name in ("flat-first","flat-second","flat-third")]
    created=[]
    for peer in peers:
        friends(e,a,peer);created.append(send(e,peer,a))
    discard_setup_notices(e)
    notices=add_notices(e,a,7)
    now=int(time.time())
    activity={}
    with database(e.c.settings) as db:
        for index,item in enumerate(created):
            value=now-30+index*10
            db.execute("UPDATE social_conversations SET updated_at=? WHERE id=?",(value,item["conversationID"]))
            activity["direct:"+item["conversationID"]]=value
        for item in notices:
            db.execute("UPDATE social_notifications SET created_at=? WHERE id=?",(now-15,item["id"]))
            activity["notification:"+item["id"]]=now-15
    ok(e,"PUT",conversation_path(peers[0])+"/pin",a,mutation(pinned=True))
    page=inbox(e,a,limit=2)
    assert set(page)=={"entries","nextCursor","unreadNotificationCount","unreadDirectMessageCount"}
    assert page["unreadNotificationCount"]==7 and page["unreadDirectMessageCount"]==3
    entries=all_entries(e,a)
    ids=[entry_id(item) for item in entries]
    pinned="direct:"+created[0]["conversationID"]
    assert ids==[pinned]+sorted((key for key in activity if key!=pinned),key=lambda key:(activity[key],key),reverse=True)
    assert len(ids)==len(set(ids))==10
    legacy_notices={item["id"]:item for item in notifications(e,a)["notifications"]}
    legacy_conversations={item["id"]:item for item in conversations(e,a)["conversations"]}
    for item in entries:
        if item["kind"]=="notification": assert item["notification"]==legacy_notices[item["notification"]["id"]]
        else: assert item["conversation"]==legacy_conversations[item["conversation"]["id"]]
    assert e.c.get(BASE,headers=authorization(peers[0]),params={"cursor":page["nextCursor"]}).status_code==422
    legacy_cursor=notifications(e,a,limit=1)["nextCursor"]
    assert e.c.get(BASE,headers=authorization(a),params={"cursor":legacy_cursor}).status_code==422


def test_one_response_keeps_retention_cutoff_when_clock_crosses_boundary_after_query(env,monkeypatch):
    e=env
    a,b=login(e.c,"retention-owner"),login(e.c,"retention-peer")
    friends(e,a,b)
    message=send(e,b,a)
    discard_setup_notices(e)
    notice_id=notice(e,a)
    clock=[int(time.time())]
    retained_at=clock[0]-30*86400+1
    with database(e.c.settings) as db:
        db.execute("UPDATE social_messages SET created_at=? WHERE id=?",(retained_at,message["message"]["id"]))
        db.execute("UPDATE social_notifications SET created_at=? WHERE id=?",(retained_at,notice_id))
    monkeypatch.setattr(time,"time",lambda:clock[0])
    original=e.social.inbox_rows
    calls=0
    def advance_after_final_rows(*args,**kwargs):
        nonlocal calls
        result=original(*args,**kwargs)
        calls+=1
        if calls==2: clock[0]+=2
        return result
    monkeypatch.setattr(e.social,"inbox_rows",advance_after_final_rows)
    first=inbox(e,a,limit=1)
    assert first["entries"][0]["conversation"]["lastMessage"]["id"]==message["message"]["id"]
    assert first["entries"][0]["conversation"]["unreadCount"]==1
    assert first["unreadNotificationCount"]==1 and first["unreadDirectMessageCount"]==1
    assert first["nextCursor"]
    expired_page=inbox(e,a,limit=1,cursor=first["nextCursor"])
    assert expired_page=={"entries":[],"nextCursor":None,"unreadNotificationCount":0,"unreadDirectMessageCount":0}
    assert inbox(e,a)==expired_page


def test_bulk_read_covers_unloaded_pages_but_preserves_confirmed_after_snapshot_arrivals(env):
    e=env
    a,b,c=[login(e.c,name) for name in ("read-owner","read-peer","read-other")]
    for peer in (b,c): friends(e,a,peer)
    outbound=send(e,a,b)
    old_messages=[send(e,peer,a) for peer in (b,c)]
    discard_setup_notices(e)
    old_notices=add_notices(e,a,26)
    ok(e,"PUT",conversation_path(b)+"/pin",a,mutation(pinned=True))
    first=inbox(e,a)
    assert len(first["entries"])==20 and first["nextCursor"]
    cutoff=snapshot(e,a)
    newer=send(e,b,a,text="快照后同一秒的新消息")
    newer_notice=notice(e,a)
    use_one_arrival_second(e)
    payload=mutation(snapshot=cutoff)
    ok(e,"POST",BASE+"/read",a,payload)
    result=inbox(e,a)
    assert result["unreadNotificationCount"]==1 and result["unreadDirectMessageCount"]==1
    assert len(all_entries(e,a))==29
    visible={item["id"]:item for item in notifications(e,a,limit=50)["notifications"]}
    assert all(visible[item["id"]]["readAt"] is not None for item in old_notices)
    assert visible[newer_notice]["readAt"] is None
    assert messages(e,a,b)["unreadCount"]==1 and conversations(e,a)["conversations"][0]["isPinned"]
    assert messages(e,b,a)["unreadCount"]==1,"Reading my inbox cannot read my peer's copy"
    assert outbound["message"]["id"] in {item["id"] for item in messages(e,b,a)["messages"]}
    ok(e,"POST",BASE+"/read",a,payload)
    assert inbox(e,a)["unreadDirectMessageCount"]==1
    assert newer["message"]["seq"]>max(item["message"]["seq"] for item in old_messages)


def test_bulk_clear_only_hides_owners_history_and_never_reapplies_to_new_messages(env):
    e=env
    a,b,c=[login(e.c,name) for name in ("clear-all-owner","clear-all-peer","clear-all-new")]
    for peer in (b,c): friends(e,a,peer)
    old=send(e,b,a)
    discard_setup_notices(e)
    add_notices(e,a,27)
    old_page=inbox(e,a,limit=1)
    cutoff=snapshot(e,a)
    new=send(e,b,a,text="删除确认期间到达")
    new_conversation=send(e,c,a,text="确认期间新会话")
    new_notice=notice(e,a)
    use_one_arrival_second(e)
    payload=mutation(snapshot=cutoff)
    ok(e,"POST",BASE+"/clear",a,payload)
    current=inbox(e,a)
    assert current["unreadNotificationCount"]==1 and current["unreadDirectMessageCount"]==2
    assert {entry_id(item) for item in all_entries(e,a)}=={
        "direct:"+new["conversationID"],"direct:"+new_conversation["conversationID"],"notification:"+new_notice}
    assert [item["id"] for item in messages(e,a,b)["messages"]]==[new["message"]["id"]]
    assert old["message"]["id"] in {item["id"] for item in messages(e,b,a)["messages"]}
    assert inbox(e,a,cursor=old_page["nextCursor"])["unreadDirectMessageCount"]==2
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM social_messages").fetchone()[0]==3
        assert db.execute("SELECT COUNT(*) FROM social_notifications").fetchone()[0]==28
        assert db.execute("PRAGMA foreign_key_check").fetchall()==[]
    ok(e,"PUT",conversation_path(b)+"/pin",a,mutation(pinned=True))
    newest=send(e,b,a,text="成功重试前到达")
    ok(e,"POST",BASE+"/clear",a,payload)
    assert conversations(e,a)["conversations"][0]["isPinned"] is True
    assert inbox(e,a)["unreadDirectMessageCount"]==3
    assert newest["message"]["id"] in {item["id"] for item in messages(e,a,b)["messages"]}


def test_snapshot_is_signed_owner_bound_and_completed_receipts_survive_expiry(env,monkeypatch):
    e=env
    a,b=login(e.c,"snapshot-owner"),login(e.c,"snapshot-other")
    notice(e,a)
    token=snapshot(e,a)
    assert request(e,"POST",BASE+"/clear",b,mutation(snapshot=token)).status_code==422
    corrupt=("A" if token[0]!="A" else "B")+token[1:]
    assert request(e,"POST",BASE+"/clear",a,mutation(snapshot=corrupt)).status_code==422
    payload=mutation(snapshot=token)
    ok(e,"POST",BASE+"/clear",a,payload)
    new=notice(e,a)
    now=time.time()
    monkeypatch.setattr(time,"time",lambda:now+601)
    assert request(e,"POST",BASE+"/clear",a,mutation(snapshot=token)).status_code==422
    ok(e,"POST",BASE+"/clear",a,payload)
    assert notifications(e,a)["notifications"][0]["id"]==new
    assert request(e,"POST",BASE+"/read",a,payload).status_code==409
    def unavailable(*args,**kwargs): raise HTTPException(503,"privacy unavailable")
    monkeypatch.setattr(e.social,"policy",unavailable)
    ok(e,"POST",BASE+"/clear",a,payload)
    assert request(e,"POST",BASE+"/read",a,mutation(snapshot=token)).status_code==503


def test_withdrawal_and_new_consent_invalidate_old_snapshot_and_receipts(env):
    e=env
    a=login(e.c,"snapshot-consent")
    notice(e,a)
    payload=mutation(snapshot=snapshot(e,a))
    ok(e,"POST",BASE+"/read",a,payload)
    assert e.c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code==200
    assert e.c.get(BASE,headers=authorization(a)).status_code in (401,409)
    again=login(e.c,"snapshot-consent")
    assert again["user"]["id"]==a["user"]["id"]
    assert request(e,"POST",BASE+"/read",again,payload).status_code==422
    ok(e,"POST",BASE+"/read",again,mutation(snapshot=snapshot(e,again)))


def test_flat_inbox_filters_bilateral_blocks_before_page_limit_and_badges(env,monkeypatch):
    e=env
    a,b,c=[login(e.c,name) for name in ("flat-policy-owner","flat-hidden","flat-visible")]
    for peer in (b,c): friends(e,a,peer);send(e,peer,a)
    discard_setup_notices(e)
    hidden_actor=account_id(e,b)
    with database(e.c.settings) as db:
        e.social.notice(db,account_id(e,a),"follow","不可见提醒",hidden_actor)
    visible=notice(e,a)
    monkeypatch.setattr(e.social,"policy",lambda user,target_ids=():Policy(
        schemaVersion=1,accountID=user["login_id"],blockedUserIDs=[b["user"]["id"]],currentRooms=[],roomsStale=True))
    first=inbox(e,a,limit=1)
    assert first["entries"] and first["unreadNotificationCount"]==1 and first["unreadDirectMessageCount"]==1
    entries=all_entries(e,a,limit=1)
    assert len(entries)==2
    assert {item["notification"]["id"] for item in entries if item["kind"]=="notification"}=={visible}
    assert {item["conversation"]["person"]["id"] for item in entries if item["kind"]=="direct"}=={c["user"]["id"]}
    assert e.c.get("/v1/push/status",headers=authorization(a)).json()["badgeCount"]==2
    def unavailable(*args,**kwargs): raise HTTPException(503,"privacy unavailable")
    monkeypatch.setattr(e.social,"policy",unavailable)
    for path in (BASE,BASE+"/snapshot"):
        assert e.c.get(path,headers=authorization(a)).status_code==503


@pytest.mark.parametrize("action",["read","clear"])
def test_bulk_mutations_cancel_only_snapshot_push_destinations_and_recompute_badge(env,action):
    e=env
    a,b=login(e.c,"bulk-push-owner"),login(e.c,"bulk-push-peer")
    friends(e,a,b);discard_setup_notices(e);register(e,a)
    send(e,b,a);notice(e,a)
    old_deliveries=[row["id"] for row in rows(e)]
    token=snapshot(e,a)
    send(e,b,a,text="新私信");notice(e,a)
    new_deliveries={row["id"] for row in rows(e)}-set(old_deliveries)
    ok(e,"POST",BASE+"/"+action,a,mutation(snapshot=token))
    assert e.c.get("/v1/push/status",headers=authorization(a)).json()["badgeCount"]==2
    for delivery in old_deliveries:
        assert e.c.get("/v1/push/destinations/"+delivery,headers=authorization(a)).status_code==404
    for delivery in new_deliveries:
        assert e.c.get("/v1/push/destinations/"+delivery,headers=authorization(a)).status_code==200
    e.s.dispatch()
    assert len(e.requests)==2
    assert {row["id"] for row in rows(e) if row["state"]=="cancelled"}==set(old_deliveries)


@pytest.mark.parametrize("action",["read","clear"])
def test_new_inbox_routes_reject_unauthenticated_and_ambiguous_mutations(env,action):
    e=env;a=login(e.c,"inbox-strict")
    token=snapshot(e,a)
    valid=mutation(snapshot=token)
    assert e.c.get(BASE).status_code==401 and e.c.get(BASE+"/snapshot").status_code==401
    assert e.c.post(BASE+"/"+action,json=valid).status_code==401
    for bad in ({"snapshot":token},{**valid,"requestID":"bad"},{**valid,"snapshot":True},
                {**valid,"snapshot":""},{**valid,"extra":True},{**valid,"snapshot":"x"*1025}):
        assert request(e,"POST",BASE+"/"+action,a,bad).status_code==422
    for bad in ({"limit":0},{"limit":51},{"cursor":"bad"},{"cursor":"x"*1025}):
        assert e.c.get(BASE,headers=authorization(a),params=bad).status_code==422
