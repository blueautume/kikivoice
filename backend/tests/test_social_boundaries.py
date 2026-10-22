"""Independent P1 privacy/authorization regression tests; all data is temporary.

The voice policy boundary is mocked here, with a bilateral canonical relation.
Actual HMAC/epoch behavior is covered by the voice service's social-policy tests.
"""
from io import BytesIO
import base64
from dataclasses import replace
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace
import time
import uuid

from PIL import Image
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


def upload(env,a):
    response = env.c.post(BASE+"/media",headers={**authorization(a),"Content-Type":"image/jpeg"},
                          content=jpeg_bytes(with_metadata=True))
    assert response.status_code == 200,response.text
    return response.json()


def moment(env,a,text="简洁的动态",media=()):
    response = env.c.post(BASE+"/moments",headers=authorization(a),json=mutation(text=text,mediaIDs=list(media)))
    assert response.status_code == 200,response.text
    return response.json()["moment"]


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


def test_bilateral_block_hides_dm_profile_moment_and_media(social_env):
    e = social_env
    a,b = person(e,"屏蔽甲"),person(e,"屏蔽乙")
    friends(e,a,b)
    message = send(e,a,b)
    assert message.status_code == 200,message.text
    image = upload(e,a)
    post = moment(e,a,media=[image["id"]])
    e.blocks.add((a["user"]["id"],b["user"]["id"]))
    for actor,target in ((a,b),(b,a)):
        assert e.c.get(BASE+"/people/"+target["user"]["id"],headers=authorization(actor)).status_code == 404
        assert e.c.get(BASE+"/conversations/"+target["user"]["id"]+"/messages",headers=authorization(actor)).status_code == 404
        assert send(e,actor,target).status_code == 404
        assert e.c.get(BASE+"/relationships?kind=mutual",headers=authorization(actor)).json()["people"] == []
    assert e.c.get(image["path"],headers=authorization(b)).status_code == 404
    assert e.c.get(BASE+"/moments",headers=authorization(b)).json()["moments"] == []
    assert e.c.get(BASE+"/moments/"+post["id"]+"/comments",headers=authorization(b)).status_code == 404
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


def test_upload_is_private_strips_metadata_and_only_owner_can_attach_once(social_env):
    e = social_env
    a,b = person(e,"图片甲"),person(e,"图片乙")
    image = upload(e,a)
    assert e.c.get(image["path"]).status_code == 401
    assert e.c.get(image["path"],headers=authorization(b)).status_code == 404
    content = e.c.get(image["path"],headers=authorization(a))
    assert content.status_code == 200 and content.headers["Cache-Control"] == "no-store"
    with Image.open(BytesIO(content.content)) as clean:
        assert not clean.getexif() and not clean.info.get("icc_profile")
        assert clean.size == (240,320)
    assert b"private artist" not in content.content and b"private location" not in content.content
    assert e.c.post(BASE+"/moments",headers=authorization(b),json=mutation(text="借图",mediaIDs=[image["id"]])).status_code == 422
    post = moment(e,a,media=[image["id"]])
    assert e.c.get(image["path"],headers=authorization(b)).status_code == 200
    assert e.c.post(BASE+"/moments",headers=authorization(a),json=mutation(text="重复图",mediaIDs=[image["id"]])).status_code == 422
    assert e.c.delete(BASE+"/moments/"+post["id"],headers=authorization(b)).status_code == 404
    assert e.c.post(BASE+"/media",headers={**authorization(a),"Content-Type":"image/png"},content=jpeg_bytes()).status_code == 422
    assert e.c.post(BASE+"/media",headers={**authorization(a),"Content-Type":"image/jpeg"},content=b"not an image").status_code == 422


def test_deleted_moment_loses_media_reference_and_orphan_file_is_swept(social_env):
    e = social_env
    a,b = person(e,"删图甲"),person(e,"删图乙")
    image = upload(e,a)
    post = moment(e,a,media=[image["id"]])
    path = e.service.media_directory/(image["id"]+".jpg")
    assert path.stat().st_mode & 0o777 == 0o600
    os.utime(path,(time.time()-61,time.time()-61))
    assert e.c.delete(BASE+"/moments/"+post["id"],headers=authorization(a)).status_code == 200
    assert e.c.get(image["path"],headers=authorization(a)).status_code == 404
    assert e.c.get(image["path"],headers=authorization(b)).status_code == 404
    assert not path.exists()
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM social_media").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM social_moment_media").fetchone()[0] == 0


def test_report_case_media_retained_for_authorized_operator_only_until_30_days(social_env):
    e = social_env
    a,b,c = (person(e,name) for name in ("证据甲","证据乙","证据丙"))
    image = upload(e,a)
    post = moment(e,a,media=[image["id"]])
    case = report(e,b,"moment",post["id"])
    operator_session = operator(e)
    unprivileged,_ = register(e.ops,"无权审核")
    grant(e.ops,unprivileged,"account")
    op_path = MOD+"/media/"+image["id"]+".jpg"
    assert e.c.get(op_path,headers=authorization(unprivileged)).status_code == 403
    assert e.c.get(op_path,headers=authorization(c)).status_code == 401
    media_path = e.service.media_directory/(image["id"]+".jpg")
    os.utime(media_path,(time.time()-61,time.time()-61))
    assert e.c.delete(BASE+"/moments/"+post["id"],headers=authorization(a)).status_code == 200
    assert media_path.exists()
    assert e.c.get(image["path"],headers=authorization(b)).status_code == 404
    assert e.c.get(op_path,headers=authorization(operator_session)).status_code == 200
    query = e.c.post(MOD+"/moderation/query",headers=authorization(operator_session),json={"status":"all"})
    assert query.status_code == 200,query.text
    assert query.json()["reports"][0]["id"] == case["id"]
    with database(e.c.settings) as db:
        db.execute("UPDATE social_reports SET created_at=? WHERE id=?",(int(time.time())-30*86400,case["id"]))
        db.execute("UPDATE social_media SET created_at=? WHERE id=?",(int(time.time())-86401,image["id"]))
        purge(db)
    e.service.sweep_media()
    assert e.c.get(op_path,headers=authorization(operator_session)).status_code == 404
    assert not media_path.exists()


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
    assert e.c.post(BASE+"/moments",headers=authorization(a),json=mutation(text="被限制")).status_code == 403
    with database(e.c.settings) as db:
        db.execute("UPDATE social_reports SET created_at=? WHERE id=?",(int(time.time())-30*86400,case["id"]))
        purge(db)
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=request).json() == response.json()
    restore = mutation(reportID=case["id"],action="restore_user",note="提前解除")
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=restore).status_code == 200
    assert moment(e,a)["author"]["id"] == a["user"]["id"]
    with database(e.c.settings) as db:
        db.execute("UPDATE social_actions SET created_at=?",(int(time.time())-90*86400,))
        purge(db)
        assert db.execute("SELECT COUNT(*) FROM social_actions").fetchone()[0] == 0


def test_withdrawal_erases_social_graph_dm_posts_reports_media_but_not_active_sanction(social_env):
    e = social_env
    a,b = person(e,"撤回甲"),person(e,"撤回乙")
    friends(e,a,b)
    assert send(e,a,b).status_code == 200
    image = upload(e,a)
    post = moment(e,a,media=[image["id"]])
    case = report(e,b,"moment",post["id"])
    op = operator(e)
    assert e.c.post(MOD+"/moderation/action",headers=authorization(op),json=mutation(reportID=case["id"],action="restrict_posting",durationSeconds=3600,note="限制不可撤回绕过")).status_code == 200
    uid = internal_id(e,a)
    path = e.service.media_directory/(image["id"]+".jpg")
    os.utime(path,(time.time()-61,time.time()-61))
    assert e.c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code == 200
    e.service.sweep_media()
    with database(e.c.settings) as db:
        for table in ("social_follows","social_messages","social_dm_contact_state","social_moments","social_comments","social_media","social_reports"):
            assert db.execute("SELECT COUNT(*) FROM "+table).fetchone()[0] == 0,table
        assert db.execute("SELECT COUNT(*) FROM social_restrictions WHERE account_id=?",(uid,)).fetchone()[0] == 1
        row = db.execute("SELECT target_id,note FROM social_actions").fetchone()
        assert row[0] is None and row[1] is None
    assert not path.exists()
    assert e.c.get(BASE+"/moments",headers=authorization(a)).status_code == 401
    fresh = person(e,"撤回甲")
    assert e.c.post(BASE+"/moments",headers=authorization(fresh),json=mutation(text="仍受限制")).status_code == 403


def test_account_deletion_cascades_both_sides_and_private_image_files(social_env):
    e = social_env
    a,b = person(e,"注销甲"),person(e,"注销乙")
    friends(e,a,b)
    assert send(e,b,a).status_code == 200
    image = upload(e,a)
    post = moment(e,a,media=[image["id"]])
    report(e,b,"moment",post["id"])
    path = e.service.media_directory/(image["id"]+".jpg")
    os.utime(path,(time.time()-61,time.time()-61))
    assert e.c.delete("/v1/account",headers=authorization(a)).status_code == 200
    e.service.sweep_media()
    assert not path.exists()
    assert e.c.get(BASE+"/people/"+a["user"]["id"],headers=authorization(b)).status_code == 404
    assert e.c.get(BASE+"/conversations",headers=authorization(b)).json()["conversations"] == []
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1
        for table in ("social_conversations","social_messages","social_dm_contact_state","social_media","social_reports","social_follows"):
            assert db.execute("SELECT COUNT(*) FROM "+table).fetchone()[0] == 0,table
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def test_logout_during_upload_policy_recheck_cannot_publish_or_leave_orphan(social_env,monkeypatch):
    e = social_env
    a = person(e,"竞态图片")
    original = e.service.policy
    def raced(user,target_ids=()):
        snapshot = original(user,target_ids)
        assert e.c.post("/v1/auth/logout",headers=authorization(a)).status_code == 200
        return snapshot
    monkeypatch.setattr(e.service,"policy",raced)
    response = e.c.post(BASE+"/media",headers={**authorization(a),"Content-Type":"image/jpeg"},content=jpeg_bytes())
    assert response.status_code == 401,response.text
    assert list(e.service.media_directory.iterdir()) == []
    with database(e.c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM social_media").fetchone()[0] == 0


def test_expired_unsubmitted_upload_is_unreadable_and_swept(social_env):
    e = social_env
    a = person(e,"过期图片")
    image = upload(e,a)
    path = e.service.media_directory/(image["id"]+".jpg")
    os.utime(path,(time.time()-61,time.time()-61))
    with database(e.c.settings) as db:
        db.execute("UPDATE social_media SET created_at=?",(int(time.time())-86400,))
    assert e.c.get(image["path"],headers=authorization(a)).status_code == 404
    assert e.c.post(BASE+"/moments",headers=authorization(a),json=mutation(text="失效附件",mediaIDs=[image["id"]])).status_code == 422
    e.service.sweep_media()
    assert not path.exists()


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


def test_public_acceptance_driver_runs_locally_with_actual_asgi_and_hmac(real_voice_service,tmp_path,monkeypatch):
    """Exercise the opt-in driver without SSH, public HTTP, Apple or real users."""
    import httpx
    import secrets
    import subprocess
    from app.main import load_legal_requirements
    from app.ops_auth import change_grant
    from app.social import erase
    from app.voice_bridge import signed_headers
    pair = real_voice_service
    c = pair.account
    settings = replace(c.settings,admin_auth_mode="passkey",ops_bridge_secret="p1-ops-local-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    c.app.state.ops.settings = settings
    script = Path(__file__).resolve().parents[2]/"experiments/livekit/validation/p1-social-2026-10-19/verify_public.py"
    spec = importlib.util.spec_from_file_location("p1_public_local_driver",script)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    def forbid_subprocess(*args,**kwargs):
        raise AssertionError("Public acceptance local test must never use SSH/subprocess")
    monkeypatch.setattr(subprocess,"run",forbid_subprocess)
    def remote(op,args):
        if op == "create":
            stem = args["stem"];assert stem.startswith("p1social_")
            public = "kiki_"+stem;name = "社交验收-"+args["nonce"]
            token = secrets.token_urlsafe(32);now = int(time.time());legal = load_legal_requirements()
            with database(settings) as db:
                db.execute("INSERT INTO accounts(account_id,login_id,sdk_user_id,name,bio,needs_nickname,notifications,created_at) VALUES(?,?,?,?,?,0,0,?)",(stem,public,public,name,"Synthetic local driver fixture",now))
                db.execute("INSERT INTO identities(provider,subject,account_id) VALUES('apple',?,?)",("codex-p1social-validation:"+stem,stem))
                db.execute("INSERT INTO sessions VALUES(?,?,?,?)",(hashlib.sha256(token.encode()).hexdigest(),stem,now+1800,now))
                event = db.execute("INSERT INTO legal_consent_events(account_id,privacy_version,terms_version,document_hash,accepted,adult_confirmed,recorded_at) VALUES(?,?,?,?,1,1,?)",(stem,legal["privacyVersion"],legal["termsVersion"],legal["documentHash"],now)).lastrowid
            return {"accountID":stem,"publicID":public,"name":name,"token":token,"consentEpoch":event,"legalVersion":legal["privacyVersion"]}
        if op in {"grant","revoke","delete-ops"}:
            item = args["fixture"]
            assert item["name"].startswith("社交验收-")
            if op == "delete-ops":
                with database(settings) as db:
                    db.execute("DELETE FROM social_actions WHERE actor_id=?",(item["accountID"],))
            change_grant(settings,database,account_id=item["accountID"],name=item["name"],
                         service=args.get("scope","voice"),action="delete" if op=="delete-ops" else op,actor="local-p1-driver")
            return {"ok":True}
        if op in {"social-policy-probe","policy-state","late-block"}:
            actor,target = args["fixture"],args["target"]
            path = "/internal/v1/account/social-policy"
            value = {"accountID":actor["publicID"],"targetIDs":[target["publicID"]]}
            if op == "late-block":
                path = "/internal/v1/account/social-block"
                value = {"accountID":actor["publicID"],"targetID":target["publicID"],"blocked":True,"consentEpoch":actor["consentEpoch"],"lastWithdrawalEpoch":0}
            body = json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()
            hs = signed_headers(settings.voice_bridge_secret,path,body)
            first = pair.voice.post(path,headers=hs,content=body)
            if op == "late-block":return {"status":first.status_code}
            assert first.status_code == 200,first.text
            if op == "policy-state":
                result = first.json()
                return {"blocked":target["publicID"] in result["blockedUserIDs"],"roomCount":len(result["currentRooms"]),"roomsStale":result["roomsStale"]}
            return {"first":first.status_code,"replay":pair.voice.post(path,headers=hs,content=body).status_code,
                    "tamperedBody":pair.voice.post(path,headers=signed_headers(settings.voice_bridge_secret,path,body),content=body+b" ").status_code,
                    "queryVariant":pair.voice.post(path+"?unexpected=1",headers=signed_headers(settings.voice_bridge_secret,path,body),content=body).status_code}
        if op == "media-proof":
            item = args["fixture"];media_id = args["mediaID"]
            return {"id":media_id,"proof":hmac.new(settings.voice_bridge_secret.encode(),("p1social-media:"+item["publicID"]+":"+media_id).encode(),hashlib.sha256).hexdigest()}
        if op == "cleanup":
            for item in args["fixtures"]:
                c.app.state.voice_bridge.post("/internal/v1/account/delete",{"accountID":item["publicID"]})
                with database(settings) as db:
                    erase(db,item["accountID"])
                    db.execute("DELETE FROM accounts WHERE account_id=?",(item["accountID"],))
                for media in item["media"]:
                    (c.app.state.social.media_directory/(media["id"]+".jpg")).unlink(missing_ok=True)
            with database(settings) as db:
                return {"remainingBusinessAccounts":db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0],
                        "remainingMediaRows":db.execute("SELECT COUNT(*) FROM social_media").fetchone()[0]}
        if op == "audit-ops":
            with database(settings) as db:return {"remainingOpsAccounts":db.execute("SELECT COUNT(*) FROM ops_accounts").fetchone()[0]}
        raise AssertionError("Unsupported local driver operation "+op)
    def audit(ids):
        return {"remainingBlocks":sum(pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks WHERE user_id=? OR blocked_user_id=?",(uid,uid)).fetchone()[0] for uid in ids),
                "remainingUsers":pair.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0]}
    class LocalHTTP:
        def request(self,method,url,**kwargs):
            assert url.startswith("https://kiki.group/")
            return c.request(method,url,**kwargs)
        def close(self):pass
    monkeypatch.setattr(driver,"remote",remote)
    monkeypatch.setattr(driver,"voice_audit",audit)
    monkeypatch.setattr(httpx,"Client",lambda *args,**kwargs:LocalHTTP())
    output = tmp_path/"local-public-driver-result.json"
    assert driver.run(output) == 0,json.loads(output.read_text())
    result = json.loads(output.read_text())
    assert result["passed"] and result["cleanup"]["verified"]
    assert len(result["checks"]) >= 24


def test_real_account_only_social_block_withdrawal_reconsent_rejects_late_epoch(real_voice_service):
    """No voice user/session is needed to enforce one durable shared policy."""
    from app.voice_bridge import signed_headers
    pair = real_voice_service
    c = pair.account
    a,b = login(c,"p1bridge-alice"),login(c,"p1bridge-bob")
    aid,bid = a["user"]["id"],b["user"]["id"]
    assert c.put(BASE+"/follows/"+bid,headers=authorization(a),json=mutation()).status_code == 200
    assert c.put(BASE+"/follows/"+aid,headers=authorization(b),json=mutation()).status_code == 200
    post = c.post(BASE+"/moments",headers=authorization(a),json=mutation(text="真实HMAC桥接动态")).json()["moment"]
    assert c.post(BASE+"/conversations/"+bid+"/messages",headers=authorization(a),json=mutation(text="真实HMAC桥接消息")).status_code == 200
    assert c.put(BASE+"/blocks/"+bid,headers=authorization(a),json=mutation()).status_code == 200
    old = next(r for r in reversed(pair.captured) if r.url.path.endswith("/social-block"))
    old_payload = json.loads(old.content)
    assert old_payload["accountID"] == aid and old_payload["targetID"] == bid
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    for actor,target in ((a,b),(b,a)):
        assert c.get(BASE+"/people/"+target["user"]["id"],headers=authorization(actor)).status_code == 404
        assert c.get(BASE+"/conversations/"+target["user"]["id"]+"/messages",headers=authorization(actor)).status_code == 404
    assert c.get(BASE+"/moments/"+post["id"],headers=authorization(b)).status_code == 404
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
