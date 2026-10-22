"""Reply-gated DM introductions; temporary accounts only, no real messages."""
from concurrent.futures import ThreadPoolExecutor
import time
import uuid

from fastapi import HTTPException
import pytest

from app.main import database
from app.social import purge
from app.social_content import initialize_content
from test_api import authorization
from test_ops_auth import ops
from test_social_boundaries import (
    BASE, follow, friends, internal_id, mutation, person, send, social_env,
)


def history(env, actor, peer):
    response=env.c.get(BASE+"/conversations/"+peer["user"]["id"]+"/messages",headers=authorization(actor))
    assert response.status_code==200,response.text
    return response.json()


def contact_rows(env):
    with database(env.c.settings) as db:
        return [dict(row) for row in db.execute("SELECT * FROM social_dm_contact_state")]


def test_strangers_have_five_committed_messages_and_recipient_reply_unlocks_both(social_env):
    e=social_env
    a,b=person(e,"首聊甲"),person(e,"首聊乙")
    page=history(e,a,b)
    assert page["canSend"] and page["remainingBeforeReply"]==5
    assert not page["requiresReply"] and not page["replyEstablished"]
    assert page["initialMessageLimit"]==5
    for remaining in range(4,-1,-1):
        result=send(e,a,b)
        assert result.status_code==200,result.text
        assert result.json()["remainingBeforeReply"]==remaining
        assert result.json()["canSend"] is (remaining>0)
    sixth=mutation(text="等待对方回复的下一条")
    denied=send(e,a,b,request=sixth)
    assert denied.status_code==403
    assert denied.json()["detail"]["code"]=="direct_message_reply_required"
    assert denied.json()["detail"]["requiresReply"] is True
    page=history(e,a,b)
    assert len(page["messages"])==5 and page["remainingBeforeReply"]==0 and not page["canSend"]
    inbox=e.c.get(BASE+"/conversations",headers=authorization(a)).json()["conversations"][0]
    assert inbox["requiresReply"] and not inbox["canSend"]
    assert history(e,b,a)["canSend"]
    answer=send(e,b,a)
    assert answer.status_code==200,answer.text
    assert answer.json()["replyEstablished"] and answer.json()["remainingBeforeReply"] is None
    accepted_after_reply=send(e,a,b,request=sixth)
    assert accepted_after_reply.status_code==200
    assert send(e,a,b,request=sixth).json()==accepted_after_reply.json()
    for actor,peer in ((a,b),(b,a)):
        for _ in range(7):
            result=send(e,actor,peer)
            assert result.status_code==200,result.text
            assert result.json()["canSend"] and result.json()["replyEstablished"]
            assert not result.json()["requiresReply"] and result.json()["remainingBeforeReply"] is None


def test_reply_before_five_unlocks_and_follow_changes_never_change_allowance(social_env):
    e=social_env
    a,b=person(e,"关注首聊甲"),person(e,"关注首聊乙")
    friends(e,a,b)
    assert send(e,a,b).json()["remainingBeforeReply"]==4
    follow(e,a,b,False)
    follow(e,b,a,False)
    assert history(e,a,b)["remainingBeforeReply"]==4
    assert send(e,b,a).json()["replyEstablished"]
    for _ in range(6):
        assert send(e,a,b).status_code==200
    friends(e,a,b)
    assert history(e,a,b)["replyEstablished"]


def test_following_cannot_bypass_exhausted_introduction(social_env):
    e=social_env
    a,b=person(e,"关注不解锁甲"),person(e,"关注不解锁乙")
    for _ in range(5):
        assert send(e,a,b).status_code==200
    friends(e,a,b)
    assert send(e,a,b).status_code==403
    assert not history(e,a,b)["canSend"]


def test_uuid_retries_do_not_spend_quota_and_changed_body_is_conflict(social_env):
    e=social_env
    a,b=person(e,"重试首聊甲"),person(e,"重试首聊乙")
    payload=mutation(text="同一条消息")
    first=send(e,a,b,request=payload)
    assert first.status_code==200
    for _ in range(6):
        assert send(e,a,b,request=payload).json()==first.json()
    assert send(e,a,b,request={**payload,"text":"换正文"}).status_code==409
    assert history(e,a,b)["remainingBeforeReply"]==4
    for _ in range(4):
        assert send(e,a,b).status_code==200
    assert send(e,a,b,request=payload).json()["message"]==first.json()["message"]
    assert send(e,a,b).status_code==403
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM social_messages").fetchone()[0]==5


def test_concurrent_unique_and_duplicate_requests_cannot_spend_more_than_five(social_env):
    e=social_env
    a,b=person(e,"并发首聊甲"),person(e,"并发首聊乙")
    payload=mutation(text="并发重试同条")
    with ThreadPoolExecutor(max_workers=8) as pool:
        duplicates=list(pool.map(lambda _:send(e,a,b,request=payload),range(8)))
    assert all(result.status_code==200 for result in duplicates)
    assert len({result.json()["message"]["id"] for result in duplicates})==1
    with ThreadPoolExecutor(max_workers=8) as pool:
        independent=list(pool.map(lambda _:send(e,a,b),range(8)))
    assert sorted(result.status_code for result in independent)==[200]*4+[403]*4
    assert len(history(e,a,b)["messages"])==5
    assert history(e,a,b)["remainingBeforeReply"]==0


def test_local_clear_and_content_expiry_cannot_reset_introduction(social_env):
    e=social_env
    a,b=person(e,"清空首聊甲"),person(e,"清空首聊乙")
    committed=[send(e,a,b).json() for _ in range(5)]
    path=BASE+"/conversations/"+b["user"]["id"]
    clear=e.c.post(path+"/clear",headers=authorization(a),json=mutation(throughMessageID=committed[-1]["message"]["id"]))
    assert clear.status_code==200,clear.text
    assert history(e,a,b)["messages"]==[]
    assert not history(e,a,b)["canSend"]
    assert send(e,a,b).status_code==403
    with database(e.c.settings) as db:
        old=int(time.time())-31*86400
        db.execute("UPDATE social_messages SET created_at=?",(old,))
        db.execute("UPDATE social_conversations SET updated_at=?",(old,))
        purge(db)
        assert db.execute("SELECT COUNT(*) FROM social_conversations").fetchone()[0]==0
        assert db.execute("SELECT COUNT(*) FROM social_messages").fetchone()[0]==0
        initialize_content(db)
    assert history(e,a,b)["conversationID"] is None
    assert not history(e,a,b)["canSend"]
    assert send(e,a,b).status_code==403
    assert send(e,b,a).json()["replyEstablished"]
    assert send(e,a,b).status_code==200


def test_established_reply_survives_expired_content_and_restart(social_env):
    e=social_env
    a,b=person(e,"持久首聊甲"),person(e,"持久首聊乙")
    assert send(e,a,b).status_code==200
    assert send(e,b,a).status_code==200
    with database(e.c.settings) as db:
        db.execute("UPDATE social_messages SET created_at=0")
        db.execute("UPDATE social_conversations SET updated_at=0")
        purge(db)
        initialize_content(db)
    assert contact_rows(e)
    for actor,peer in ((a,b),(b,a)):
        assert history(e,actor,peer)["replyEstablished"]
        for _ in range(6):
            assert send(e,actor,peer).status_code==200


@pytest.mark.parametrize("replied",[False,True])
def test_upgrade_backfills_existing_direction_history_once_before_purge(social_env,replied):
    e=social_env
    a,b=person(e,"迁移首聊甲"),person(e,"迁移首聊乙")
    initial=send(e,a,b).json()
    aid,bid=internal_id(e,a),internal_id(e,b)
    with database(e.c.settings) as db:
        db.execute("DELETE FROM social_dm_contact_state")
        # Older builds allowed any number while mutually followed.
        for _ in range(6):
            db.execute("INSERT INTO social_messages(id,conversation_id,sender_id,recipient_id,text,created_at) VALUES(?,?,?,?,?,?)",(str(uuid.uuid4()),initial["conversationID"],aid,bid,"旧版单向消息",0))
        if replied:
            db.execute("INSERT INTO social_messages(id,conversation_id,sender_id,recipient_id,text,created_at) VALUES(?,?,?,?,?,?)",(str(uuid.uuid4()),initial["conversationID"],bid,aid,"旧版回复",0))
        initialize_content(db)
        first=[tuple(row) for row in db.execute("SELECT * FROM social_dm_contact_state")]
        initialize_content(db)
        assert [tuple(row) for row in db.execute("SELECT * FROM social_dm_contact_state")]==first
        purge(db)
    access=history(e,a,b)
    assert access["replyEstablished"] is replied and access["canSend"] is replied
    assert send(e,a,b).status_code==(200 if replied else 403)
    assert send(e,b,a).status_code==200
    assert history(e,a,b)["canSend"]


def test_block_revoke_and_failed_transaction_do_not_consume_or_bypass_quota(social_env,monkeypatch):
    e=social_env
    a,b=person(e,"安全首聊甲"),person(e,"安全首聊乙")
    original=e.service.push.enqueue
    def fail(*args,**kwargs):
        raise RuntimeError("simulated outbox transaction failure")
    monkeypatch.setattr(e.service.push,"enqueue",fail)
    assert send(e,a,b).status_code==500
    assert history(e,a,b)["remainingBeforeReply"]==5
    assert contact_rows(e)==[]
    monkeypatch.setattr(e.service.push,"enqueue",original)
    e.blocks.add((a["user"]["id"],b["user"]["id"]))
    assert send(e,a,b).status_code==404
    assert contact_rows(e)==[]
    e.blocks.clear()
    assert send(e,a,b).status_code==200
    assert send(e,b,a).json()["replyEstablished"]
    e.blocks.add((b["user"]["id"],a["user"]["id"]))
    assert send(e,a,b).status_code==404
    e.blocks.clear()
    assert e.c.post("/v1/auth/logout",headers=authorization(a)).status_code==200
    assert send(e,a,b).status_code==401


def test_failed_validation_policy_and_rate_checks_do_not_consume_introduction(social_env,monkeypatch):
    e=social_env
    a,b=person(e,"失败首聊甲"),person(e,"失败首聊乙")
    invalid=e.c.post(BASE+"/conversations/"+b["user"]["id"]+"/messages",headers=authorization(a),json=mutation(text=""))
    assert invalid.status_code==422
    policy=e.service.policy
    def unavailable(*args,**kwargs):
        raise HTTPException(503,"simulated privacy boundary unavailable")
    monkeypatch.setattr(e.service,"policy",unavailable)
    assert send(e,a,b).status_code==503
    monkeypatch.setattr(e.service,"policy",policy)
    original_rate=e.service.rate
    def limited(db,user,kind,*args,**kwargs):
        if kind=="dm":raise HTTPException(429,"simulated message rate limit")
        return original_rate(db,user,kind,*args,**kwargs)
    monkeypatch.setattr(e.service,"rate",limited)
    assert send(e,a,b).status_code==429
    assert contact_rows(e)==[] and history(e,a,b)["remainingBeforeReply"]==5
    monkeypatch.setattr(e.service,"rate",original_rate)
    assert send(e,a,b).json()["remainingBeforeReply"]==4


@pytest.mark.parametrize("path",["/v1/me/legal-consent","/v1/account"])
def test_consent_withdrawal_and_account_deletion_erase_contact_metadata(social_env,path):
    e=social_env
    a,b=person(e,"清理首聊甲"),person(e,"清理首聊乙")
    assert send(e,a,b).status_code==200
    assert contact_rows(e)
    assert e.c.delete(path,headers=authorization(a)).status_code==200
    assert contact_rows(e)==[]
    with database(e.c.settings) as db:
        assert not db.execute("PRAGMA foreign_key_check").fetchall()
