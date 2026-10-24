"""Independent P1 privacy/authorization regression tests; all data is temporary.

The voice policy boundary is mocked here, with a bilateral canonical relation.
Actual HMAC/epoch behavior is covered by the voice service's social-policy tests.
"""
import base64
import hmac
from dataclasses import replace
import hashlib
import json
from types import SimpleNamespace
import time
import uuid

from fastapi import HTTPException
import pytest

from app.main import database
from app.social import Policy, purge
from test_api import authorization, jpeg_bytes, login
from test_ops_auth import ops, register, grant
from test_voice_bridge import bridge_client, real_voice_service


BASE = "/v1/social"
MOD = "/admin/v2/services/account/social"


def mutation(**fields):
    return {"requestID":str(uuid.uuid4()),**fields}


@pytest.fixture
def social_env(ops, monkeypatch):
    service = ops.app.state.social
    blocks = set()
    def policy(user,target_ids=()):
        actor = user["login_id"]
        peers = sorted({b if a == actor else a for a,b in blocks if actor in (a,b)})
        return Policy(schemaVersion=1,accountID=actor,blockedUserIDs=peers,currentRooms=[],roomsStale=True)
    def privacy_post(path,payload):
        assert path == "/internal/v1/account/social-block"
        pair = (payload["accountID"],payload["targetID"])
        assert payload["consentEpoch"] > payload["lastWithdrawalEpoch"]
        if payload["blocked"]:
            blocks.add(pair)
        else:
            blocks.discard(pair)
        return {"schemaVersion":1,"accountID":pair[0],"targetID":pair[1],"blocked":payload["blocked"]}
    monkeypatch.setattr(service,"policy",policy)
    monkeypatch.setattr(service,"privacy_post",privacy_post)
    return SimpleNamespace(c=ops.client,ops=ops,service=service,blocks=blocks)


def person(env,name):
    actor = login(env.c,"bound-"+hashlib.sha256(name.encode()).hexdigest()[:16])
    response = env.c.patch("/v1/me",headers=authorization(actor),json={"name":name})
    assert response.status_code == 200,response.text
    actor["user"] = response.json()
    return actor


def follow(env,a,b,enabled=True):
    response = env.c.request("PUT" if enabled else "DELETE",BASE+"/follows/"+b["user"]["id"],
                             headers=authorization(a),json=mutation())
    assert response.status_code == 200,response.text
    return response.json()


def friends(env,a,b):
    follow(env,a,b)
    follow(env,b,a)


def send(env,a,b,text="私聊边界",request=None):
    return env.c.post(BASE+"/conversations/"+b["user"]["id"]+"/messages",headers=authorization(a),
                      json=request or mutation(text=text))


def report(env,a,kind,target):
    response = env.c.post(BASE+"/reports",headers=authorization(a),
                          json=mutation(targetType=kind,targetID=target,reason="other",details="边界验收"))
    assert response.status_code == 200,response.text
    return response.json()["report"]


def internal_id(env,actor):
    with database(env.c.settings) as db:
        return db.execute("SELECT account_id FROM accounts WHERE login_id=?",(actor["user"]["id"],)).fetchone()[0]


def operator(env,name="边界审核"):
    account,_ = register(env.ops,name)
    grant(env.ops,account,"community")
    return account


def test_dm_retry_unfollow_and_read_are_scoped(social_env):
    e = social_env
    a,b,c = (person(e,name) for name in ("dm甲","dm乙","dm丙"))
    request = mutation(text="已提交的原文")
    first = send(e,a,b,request=request)
    assert first.status_code == 200,first.text
    assert send(e,a,b,request=request).json() == first.json()
    assert send(e,a,b,request={**request,"text":"重用编号修改原文"}).status_code == 409
    item = first.json()["message"]
    path = BASE+"/conversations/"+a["user"]["id"]
    assert e.c.post(path+"/read",headers=authorization(c),json={"throughMessageID":item["id"]}).status_code == 404
    assert e.c.post(path+"/read",headers=authorization(b),json={"throughMessageID":item["id"]}).json()["unreadCount"] == 0
    follow(e,b,a,False)
    page = e.c.get(path+"/messages",headers=authorization(b)).json()
    assert page["canSend"] is True and [m["id"] for m in page["messages"]] == [item["id"]]
    # Retrying an already committed action returns its receipt, never a new send.
    assert send(e,a,b,request=request).json() == first.json()
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM social_messages").fetchone()[0] == 1


def test_dm_same_second_order_cursor_and_read_watermark_use_sequence(social_env):
    e = social_env
    a,b = person(e,"顺序甲"),person(e,"顺序乙")
    friends(e,a,b)
    first = send(e,a,b).json()
    ids = ["00000000-0000-4000-8000-000000000003","00000000-0000-4000-8000-000000000001","00000000-0000-4000-8000-000000000002"]
    with database(e.c.settings) as db:
        db.execute("DELETE FROM social_messages")
        for i,mid in enumerate(ids):
            db.execute("INSERT INTO social_messages(id,conversation_id,sender_id,recipient_id,text,created_at) VALUES(?,?,?,?,?,?)",
                       (mid,first["conversationID"],internal_id(e,a),internal_id(e,b),str(i),int(time.time())))
    path = BASE+"/conversations/"+a["user"]["id"]
    page = e.c.get(path+"/messages?limit=2",headers=authorization(b))
    assert page.status_code == 200,page.text
    assert [m["id"] for m in page.json()["messages"]] == list(reversed(ids))[0:2]
    older = e.c.get(path+"/messages",headers=authorization(b),params={"limit":2,"cursor":page.json()["nextCursor"]})
    assert [m["id"] for m in older.json()["messages"]] == ids[0:1]
    assert e.c.post(path+"/read",headers=authorization(b),json={"throughMessageID":ids[-1]}).json()["unreadCount"] == 0
    assert e.c.post(path+"/read",headers=authorization(b),json={"throughMessageID":ids[0]}).json()["unreadCount"] == 0
    assert e.c.get(BASE+"/conversations/"+b["user"]["id"]+"/messages",headers=authorization(a),params={"cursor":page.json()["nextCursor"]}).status_code == 422


def test_bilateral_block_hides_dm_profile_and_relations(social_env):
    e = social_env
    a,b = person(e,"屏蔽甲"),person(e,"屏蔽乙")
    friends(e,a,b)
    message = send(e,a,b)
    assert message.status_code == 200,message.text
    e.blocks.add((a["user"]["id"],b["user"]["id"]))
    for actor,target in ((a,b),(b,a)):
        assert e.c.get(BASE+"/people/"+target["user"]["id"],headers=authorization(actor)).status_code == 404
        assert e.c.get(BASE+"/conversations/"+target["user"]["id"]+"/messages",headers=authorization(actor)).status_code == 404
        assert send(e,actor,target).status_code == 404
        assert e.c.get(BASE+"/relationships?kind=mutual",headers=authorization(actor)).json()["people"] == []
    assert e.c.get(BASE+"/conversations",headers=authorization(b)).json()["unreadCount"] == 0


def test_dm_persistent_rate_limit_and_expiry_are_enforced(social_env):
    e = social_env
    a,b = person(e,"限频甲"),person(e,"限频乙")
    friends(e,a,b)
    committed = send(e,a,b)
    assert committed.status_code == 200
    uid = internal_id(e,a)
    now = int(time.time())
    with database(e.c.settings) as db:
        db.executemany("INSERT INTO social_rate_events VALUES(?,?,?,?)",[(str(uuid.uuid4()),uid,"dm",now) for _ in range(299)])
    limited = send(e,a,b)
    assert limited.status_code == 429 and limited.headers["Retry-After"]
    with database(e.c.settings) as db:
        db.execute("UPDATE social_messages SET created_at=?",(now-30*86400,))
    path = BASE+"/conversations/"+a["user"]["id"]
    assert e.c.get(path+"/messages",headers=authorization(b)).json()["messages"] == []
    assert e.c.post(path+"/read",headers=authorization(b),json={"throughMessageID":committed.json()["message"]["id"]}).status_code == 404


def test_direct_message_reports_require_participation_and_keep_server_evidence(social_env):
    e = social_env
    a,b,c = (person(e,name) for name in ("举报甲","举报乙","举报丙"))
    friends(e,a,b)
    message = send(e,a,b,text="服务端确认的证据").json()["message"]
    request = mutation(targetType="direct_message",targetID=message["id"],reason="harassment",details="已提交")
    assert e.c.post(BASE+"/reports",headers=authorization(c),json=request).status_code == 404
    first = e.c.post(BASE+"/reports",headers=authorization(b),json=request)
    assert first.status_code == 200,first.text
    assert e.c.post(BASE+"/reports",headers=authorization(b),json=request).json() == first.json()
    assert e.c.post(BASE+"/reports",headers=authorization(b),json={**request,"reason":"spam"}).status_code == 409
    assert "evidence" not in first.json()["report"]
    with database(e.c.settings) as db:
        evidence = db.execute("SELECT evidence FROM social_reports WHERE id=?",(first.json()["report"]["id"],)).fetchone()[0]
    assert json.loads(evidence)["text"] == message["text"]


def test_moderation_idempotency_restore_after_report_expiry_and_90_day_receipt(social_env):
    e = social_env
    a,b = person(e,"治理甲"),person(e,"治理乙")
    case = report(e,b,"profile",a["user"]["id"])
    op = operator(e)
    request = mutation(reportID=case["id"],action="restrict_posting",durationSeconds=3600,note="临时限制")
    response = e.c.post(MOD+"/moderation/action",headers=authorization(op),json=request)
    assert response.status_code == 200,response.text
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=request).json() == response.json()
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json={**request,"note":"修改内容"}).status_code == 409
    assert send(e,a,b,text="被限制").status_code == 403
    with database(e.c.settings) as db:
        db.execute("UPDATE social_reports SET created_at=? WHERE id=?",(int(time.time())-30*86400,case["id"]))
        purge(db)
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=request).json() == response.json()
    restore = mutation(reportID=case["id"],action="restore_user",note="提前解除")
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=restore).status_code == 200
    assert send(e,a,b,text="已恢复").status_code == 200
    with database(e.c.settings) as db:
        db.execute("UPDATE social_actions SET created_at=?",(int(time.time())-90*86400,))
        purge(db)
        assert db.execute("SELECT COUNT(*) FROM social_actions").fetchone()[0] == 0


def test_withdrawal_erases_social_graph_dm_and_reports_but_not_active_sanction(social_env):
    e = social_env
    a,b = person(e,"撤回甲"),person(e,"撤回乙")
    friends(e,a,b)
    assert send(e,a,b).status_code == 200
    case = report(e,b,"profile",a["user"]["id"])
    op = operator(e)
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=mutation(reportID=case["id"],action="restrict_posting",durationSeconds=3600,note="限制不可撤回绕过")).status_code == 200
    uid = internal_id(e,a)
    assert e.c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code == 200
    with database(e.c.settings) as db:
        for table in ("social_follows","social_messages","social_dm_contact_state","social_reports"):
            assert db.execute("SELECT COUNT(*) FROM "+table).fetchone()[0] == 0,table
        assert db.execute("SELECT COUNT(*) FROM social_restrictions WHERE account_id=?",(uid,)).fetchone()[0] == 1
        row = db.execute("SELECT target_id,note FROM social_actions").fetchone()
        assert row[0] is None and row[1] is None
    assert e.c.get(BASE+"/relationships",headers=authorization(a)).status_code == 401
    fresh = person(e,"撤回甲")
    assert send(e,fresh,b,text="仍受限制").status_code == 403


def test_account_deletion_cascades_both_sides_of_social_data(social_env):
    e = social_env
    a,b = person(e,"注销甲"),person(e,"注销乙")
    friends(e,a,b)
    assert send(e,b,a).status_code == 200
    report(e,b,"profile",a["user"]["id"])
    assert e.c.delete("/v1/account",headers=authorization(a)).status_code == 200
    assert e.c.get(BASE+"/people/"+a["user"]["id"],headers=authorization(b)).status_code == 404
    assert e.c.get(BASE+"/conversations",headers=authorization(b)).json()["conversations"] == []
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1
        for table in ("social_conversations","social_messages","social_dm_contact_state","social_reports","social_follows"):
            assert db.execute("SELECT COUNT(*) FROM "+table).fetchone()[0] == 0,table
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def test_read_only_grant_cannot_moderate_and_revoked_operator_cannot_replay(social_env):
    e = social_env
    a,b = person(e,"授权甲"),person(e,"授权乙")
    case = report(e,b,"profile",a["user"]["id"])
    readonly,_ = register(e.ops,"只读边界")
    grant(e.ops,readonly,"account")
    action = mutation(reportID=case["id"],action="warn",note="权限验收")
    assert e.c.post(MOD+"/moderation/action",headers=authorization(readonly),json=action).status_code == 403
    op = operator(e)
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=action).status_code == 200
    grant(e.ops,op,"community",action="revoke")
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=action).status_code == 403
    assert e.c.post(MOD+"/moderation/query",headers=authorization(op),json={"status":"all"}).status_code == 403


def test_social_cursor_cannot_be_forged_with_retired_empty_tencent_key(social_env):
    e = social_env
    settings = replace(e.service.settings,secret_key="",voice_bridge_enabled=True,
                       voice_bridge_secret="cursor-separate-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    service = type(e.service)(settings,e.service.database,e.service.bridge,e.service.requirements,
                              e.service.require_active_session,e.service.limits)
    actor = {"account_id":"cursor-boundary-actor"}
    raw = json.dumps({"v":1,"u":actor["account_id"],"s":"cursor-boundary","k":[1,"known"],
                      "exp":int(time.time())+3600},sort_keys=True,separators=(",",":")).encode()
    forged = base64.urlsafe_b64encode(raw+hmac.new(b"",b"social-cursor-v1:"+raw,hashlib.sha256).digest()).rstrip(b"=").decode()
    with pytest.raises(HTTPException) as rejected:
        service.cursor(actor,"cursor-boundary",value=forged)
    assert rejected.value.status_code == 422
    genuine = service.cursor(actor,"cursor-boundary",key=[1,"known"])
    assert service.cursor(actor,"cursor-boundary",value=genuine) == [1,"known"]


def test_real_account_only_social_block_withdrawal_reconsent_rejects_late_epoch(real_voice_service):
    """No voice user/session is needed to enforce one durable shared policy."""
    from app.voice_bridge import signed_headers
    pair = real_voice_service
    c = pair.account
    a,b = login(c,"p1bridge-alice"),login(c,"p1bridge-bob")
    aid,bid = a["user"]["id"],b["user"]["id"]
    assert c.put(BASE+"/follows/"+bid,headers=authorization(a),json=mutation()).status_code == 200
    assert c.put(BASE+"/follows/"+aid,headers=authorization(b),json=mutation()).status_code == 200
    message = c.post(BASE+"/conversations/"+b["user"]["id"]+"/messages",headers=authorization(a),json=mutation(text="真实HMAC桥接私信"))
    assert message.status_code == 200,message.text
    assert c.post(BASE+"/conversations/"+bid+"/messages",headers=authorization(a),json=mutation(text="真实HMAC桥接消息")).status_code == 200
    assert c.put(BASE+"/blocks/"+bid,headers=authorization(a),json=mutation()).status_code == 200
    old = next(r for r in reversed(pair.captured) if r.url.path.endswith("/social-block"))
    old_payload = json.loads(old.content)
    assert old_payload["accountID"] == aid and old_payload["targetID"] == bid
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    for actor,target in ((a,b),(b,a)):
        assert c.get(BASE+"/people/"+target["user"]["id"],headers=authorization(actor)).status_code == 404
        assert c.get(BASE+"/conversations/"+target["user"]["id"]+"/messages",headers=authorization(actor)).status_code == 404
    assert c.get(BASE+"/conversations/"+a["user"]["id"]+"/messages",headers=authorization(b)).status_code == 404
    assert c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code == 200
    c.app.state.voice_bridge.retry_revocations()
    withdrawal = next(r for r in reversed(pair.captured) if r.url.path.endswith("/revoke") and json.loads(r.content).get("reason")=="withdrawal")
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks").fetchone()[0] == 0
    fresh = login(c,"p1bridge-alice")
    assert fresh["user"]["id"] == aid
    assert c.put(BASE+"/blocks/"+bid,headers=authorization(fresh),json=mutation()).status_code == 200
    new = next(r for r in reversed(pair.captured) if r.url.path.endswith("/social-block"))
    assert json.loads(new.content)["consentEpoch"] > old_payload["consentEpoch"]
    path = old.url.path
    rejected = pair.voice.post(path,content=old.content,headers=signed_headers(c.settings.voice_bridge_secret,path,old.content))
    assert rejected.status_code == 409,rejected.text
    path = withdrawal.url.path
    repeated = pair.voice.post(path,content=withdrawal.content,headers=signed_headers(c.settings.voice_bridge_secret,path,withdrawal.content))
    assert repeated.status_code == 200,repeated.text
    assert tuple(pair.app.state.db.execute("SELECT user_id,blocked_user_id FROM safety_blocks").fetchone()) == (aid,bid)
    assert c.delete("/v1/account",headers=authorization(fresh)).status_code == 200
    c.app.state.voice_bridge.retry_revocations()
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks").fetchone()[0] == 0
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
