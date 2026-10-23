"""Synthetic signed voice events; no real users, SFU or APNs requests."""
from dataclasses import replace
import hashlib
import hmac
import json
import secrets
import time
import uuid

from fastapi import HTTPException
import httpx
import pytest

from app import room_started
from app.main import database
from app.social import Policy
from test_api import client, login, authorization
from test_push import env, register, follow, rows
from test_social_api import rid

SECRET = "RoomStartedSyntheticBridgeSecret_49UnequalCharacters123"


@pytest.fixture
def live(env):
    e=env
    e.c.app.state.room_started.settings=replace(e.c.settings,voice_bridge_enabled=True,voice_bridge_secret=SECRET)
    e.social.settings=replace(e.social.settings,voice_bridge_enabled=True,voice_bridge_secret=SECRET)
    e.active=True; e.status_error=False; e.status_requests=[]; e.during_status=None; e.blocks={}
    e.social.policy=lambda user,target_ids=():Policy(schemaVersion=1,accountID=user["login_id"],
        blockedUserIDs=e.blocks.get(user["login_id"],[]),currentRooms=[],roomsStale=True)
    def transport(request):
        assert request.url.path==room_started.STATUS_PATH and str(request.url).startswith("https://furby.top/")
        payload=json.loads(request.content)
        assert set(payload)=={"eventID","roomID","hostID","hostConsentEpoch"}
        message="\n".join(("account-voice-v1","POST",room_started.STATUS_PATH,
            request.headers["X-Kiki-Timestamp"],request.headers["X-Kiki-Nonce"],hashlib.sha256(request.content).hexdigest())).encode()
        assert hmac.compare_digest(request.headers["X-Kiki-Signature"],hmac.new(SECRET.encode(),message,hashlib.sha256).hexdigest())
        e.status_requests.append(payload)
        if e.during_status:e.during_status()
        if e.status_error:raise httpx.ConnectError("synthetic status outage",request=request)
        return httpx.Response(200,json={"schemaVersion":1,**payload,"active":e.active})
    e.social.bridge.http.close()
    e.social.bridge.http=httpx.Client(transport=httpx.MockTransport(transport))
    return e


def account_id(e,person):
    with database(e.c.settings) as db:
        return db.execute("SELECT account_id FROM accounts WHERE login_id=?",(person["user"]["id"],)).fetchone()[0]


def payload(e,host,**changes):
    with database(e.c.settings) as db:
        epoch=db.execute("SELECT MAX(event_id) FROM legal_consent_events WHERE account_id=?",(account_id(e,host),)).fetchone()[0]
    start=changes.get("startedAt",int(time.time()))
    start_ns=changes.get("startedAtNs",start*1_000_000_000)
    return {"schemaVersion":1,"eventID":rid(),"roomID":"lk_"+uuid.uuid4().hex,
            "hostID":host["user"]["id"],"startedAt":start,"startedAtNs":start_ns,"hostConsentEpoch":epoch,**changes}


def existing_follow(e,follower,host):
    follow(e,follower,host)
    with database(e.c.settings) as db:
        db.execute("UPDATE social_follows SET created_at=? WHERE follower_id=? AND followed_id=?",
                   ((int(time.time())-5)*1_000_000_000,account_id(e,follower),account_id(e,host)))


def signed(e,event,*,nonce=None,stamp=None,secret=SECRET,domain=room_started.DOMAIN,path=room_started.PATH):
    body=json.dumps(event,separators=(",",":")).encode()
    stamp=str(int(time.time()) if stamp is None else stamp);nonce=nonce or secrets.token_hex(16)
    message="\n".join((domain,"POST",path,stamp,nonce,hashlib.sha256(body).hexdigest())).encode()
    headers={"Content-Type":"application/json","X-Kiki-Timestamp":stamp,"X-Kiki-Nonce":nonce,
             "X-Kiki-Signature":hmac.new(secret.encode(),message,hashlib.sha256).hexdigest()}
    return e.c.post(path,content=body,headers=headers)


def notices(e):
    return [n for n in rows(e,"social_notifications") if n["kind"]=="room_started"]


def seed(e,*,registered=True):
    host,fan=login(e.c,"room-host"),login(e.c,"room-fan")
    if registered:assert register(e,fan)[2].status_code==200
    existing_follow(e,fan,host)
    event=payload(e,host)
    response=signed(e,event)
    assert response.status_code==200,response.text
    return host,fan,event


def test_signed_start_fans_out_once_and_both_lists_route_to_room(live):
    e=live;host,fan,event=seed(e)
    assert len(notices(e))==1 and len(rows(e))==1
    notice=notices(e)[0]
    assert notice["text"]==room_started.TEXT and notice["room_id"]==event["roomID"]
    for route,key in [("/v1/social/notifications","notifications"),("/v1/social/inbox","entries")]:
        response=e.c.get(route,headers=authorization(fan))
        assert response.status_code==200,response.text
        item=response.json()[key][0]
        if key=="entries":item=item["notification"]
        assert item["roomID"]==event["roomID"] and item["actor"]["id"]==host["user"]["id"]
    assert signed(e,event).json()=={"ok":True}
    assert len(notices(e))==1 and len(rows(e))==1 and len(e.status_requests)==1
    e.s.dispatch()
    assert len(e.requests)==1
    alert=json.loads(e.requests[0].content)
    assert alert["aps"]["alert"]=={"title":host["user"]["name"],"body":room_started.TEXT}
    assert event["roomID"] not in e.requests[0].content.decode()
    assert rows(e)[0]["expires_at"]==event["startedAt"]+300
    route=e.c.get("/v1/push/destinations/"+alert["deliveryID"],headers=authorization(fan))
    assert route.json()=={"type":"notification","notificationID":notice["id"],"roomID":event["roomID"]}
    assert e.c.get("/v1/push/status",headers=authorization(fan)).json()["badgeCount"]==1


@pytest.mark.parametrize("change",[{"schemaVersion":True},{"startedAt":True},{"hostConsentEpoch":True},
    {"name":"untrusted"},{"recipientIDs":[]},{"title":"room title"},{"text":"arbitrary"},{"roomID":"arbitrary"}])
def test_event_strict_shape_rejects_client_controlled_content(live,change):
    e=live;host=login(e.c)
    assert signed(e,payload(e,host,**change)).status_code==422
    assert notices(e)==[] and rows(e,"social_room_started_events")==[]


def test_exact_signature_domain_body_timestamp_nonce_and_enabled_boundary(live):
    e=live;host=login(e.c);event=payload(e,host)
    assert e.c.post(room_started.PATH,json=event).status_code==401
    for changes in [{"secret":"wrong"},{"domain":"account-voice-v1"},{"stamp":int(time.time())-31}]:
        assert signed(e,event,**changes).status_code==401
    nonce=secrets.token_hex(16)
    assert signed(e,event,nonce=nonce).status_code==200
    assert signed(e,event,nonce=nonce).status_code==401
    assert signed(e,event,path=room_started.PATH+"/").status_code==404
    assert signed(e,event,path=room_started.PATH+"?extra=1").status_code==404
    e.c.app.state.room_started.settings=replace(e.c.app.state.room_started.settings,voice_bridge_enabled=False)
    assert signed(e,event).status_code==404


def test_receipt_survives_delete_and_other_recipient_withdrawal_and_rejects_changed_identity(live):
    e=live;host,fan,other=[login(e.c,name) for name in ("receipt-host","receipt-fan","receipt-other")]
    for person in [fan,other]:existing_follow(e,person,host)
    event=payload(e,host)
    assert signed(e,event).status_code==200 and len(notices(e))==2
    notice=next(n for n in notices(e) if n["recipient_id"]==account_id(e,fan))
    assert e.c.request("DELETE","/v1/social/notifications/"+notice["id"],headers=authorization(fan),json={"requestID":rid()}).status_code==200
    assert signed(e,event).status_code==200 and len(notices(e))==1
    assert e.c.delete("/v1/me/legal-consent",headers=authorization(other)).status_code==200
    assert len(rows(e,"social_room_started_events"))==1
    assert signed(e,event).status_code==200 and notices(e)==[]
    assert signed(e,{**event,"startedAtNs":event["startedAtNs"]+1}).status_code==409
    assert signed(e,{**event,"eventID":rid()}).status_code==409
    e.c.app.state.room_started.clock=lambda:event["startedAt"]+301
    assert signed(e,event,stamp=event["startedAt"]+301).status_code==200,"A successful receipt is stable after the five-minute event window"


def test_fanout_excludes_new_follows_blocks_and_invalid_consent_but_keeps_inapp_when_disabled(live):
    e=live;host=login(e.c,"audience-host")
    fans=[login(e.c,"audience-"+str(i)) for i in range(5)]
    for fan in fans:existing_follow(e,fan,host)
    event=payload(e,host)
    with database(e.c.settings) as db:
        db.execute("UPDATE social_follows SET created_at=? WHERE follower_id=?",((event["startedAt"]+1)*1_000_000_000,account_id(e,fans[0])))
        db.execute("UPDATE legal_consent_events SET document_hash='obsolete' WHERE account_id=?",(account_id(e,fans[2]),))
    e.blocks[host["user"]["id"]]=[fans[1]["user"]["id"]]
    for fan in [fans[3],fans[4]]:assert register(e,fan)[2].status_code==200
    assert e.c.patch("/v1/me",headers=authorization(fans[3]),json={"notificationsEnabled":False}).status_code==200
    assert signed(e,event).status_code==200
    assert {n["recipient_id"] for n in notices(e)}=={account_id(e,fans[3]),account_id(e,fans[4])}
    assert [r["recipient_id"] for r in rows(e)]==[account_id(e,fans[4])]


def test_status_outage_is_retryable_without_receipt_and_inactive_event_is_terminal(live):
    e=live;host=login(e.c);fan=login(e.c,"retry-fan");existing_follow(e,fan,host)
    event=payload(e,host);e.status_error=True
    assert signed(e,event).status_code==503
    assert notices(e)==[] and rows(e,"social_room_started_events")==[]
    e.status_error=False;e.active=False
    assert signed(e,event).status_code==200
    assert notices(e)==[] and len(rows(e,"social_room_started_events"))==1
    e.active=True
    assert signed(e,event).status_code==200 and notices(e)==[]


@pytest.mark.parametrize("reason",["unfollow","ended","blocked","epoch","clear","delete","withdraw"])
def test_send_and_destination_recheck_current_eligibility(live,reason):
    e=live;host,fan,event=seed(e);notice=notices(e)[0];delivery=rows(e)[0]
    if reason=="unfollow":follow(e,fan,host,False)
    elif reason=="ended":e.active=False
    elif reason=="blocked":e.blocks[fan["user"]["id"]]=[host["user"]["id"]]
    elif reason=="epoch":
        with database(e.c.settings) as db:
            db.execute("INSERT INTO legal_consent_events(account_id,privacy_version,terms_version,document_hash,accepted,adult_confirmed,recorded_at) SELECT account_id,privacy_version,terms_version,document_hash,accepted,adult_confirmed,recorded_at FROM legal_consent_events WHERE account_id=? ORDER BY event_id DESC LIMIT 1",(account_id(e,host),))
    elif reason=="clear":
        snapshot=e.c.get("/v1/social/inbox/snapshot",headers=authorization(fan)).json()["snapshot"]
        assert e.c.post("/v1/social/inbox/clear",headers=authorization(fan),json={"requestID":rid(),"snapshot":snapshot}).status_code==200
    elif reason=="delete":
        assert e.c.request("DELETE","/v1/social/notifications/"+notice["id"],headers=authorization(fan),json={"requestID":rid()}).status_code==200
    elif reason=="withdraw":assert e.c.delete("/v1/me/legal-consent",headers=authorization(host)).status_code==200
    e.s.dispatch()
    assert e.requests==[]
    assert e.c.get("/v1/push/destinations/"+delivery["id"],headers=authorization(fan)).status_code==404
    assert e.c.get("/v1/social/notifications/"+notice["id"]+"/destination",headers=authorization(fan)).status_code==404


def test_status_outage_retries_same_delivery_and_latest_content_preference(live):
    e=live;host,fan,event=seed(e);delivery=rows(e)[0]
    e.status_error=True;e.s.dispatch()
    assert e.requests==[] and rows(e)[0]["state"]=="pending" and rows(e)[0]["error_code"]=="room_status_unavailable"
    assert e.c.get("/v1/push/destinations/"+delivery["id"],headers=authorization(fan)).status_code==503
    assert e.c.patch("/v1/me",headers=authorization(fan),json={"hideNotificationContent":True}).status_code==200
    with database(e.c.settings) as db:db.execute("UPDATE push_outbox SET next_attempt_at=0")
    e.status_error=False;e.s.dispatch()
    assert len(e.requests)==1 and json.loads(e.requests[0].content)["deliveryID"]==delivery["id"]
    from app.push import GENERIC_ALERT
    assert json.loads(e.requests[0].content)["aps"]["alert"]==GENERIC_ALERT


def test_notification_destination_is_owner_only_readable_after_read_and_rechecks_after_network(live):
    e=live;host,fan,event=seed(e);notice=notices(e)[0];delivery=rows(e)[0]
    path="/v1/social/notifications/"+notice["id"]+"/destination"
    assert e.c.get(path).status_code==401
    assert e.c.get(path,headers=authorization(host)).status_code==404
    assert e.c.post("/v1/social/notifications/read",headers=authorization(fan),json={"ids":[notice["id"]]}).status_code==200
    assert e.c.get(path,headers=authorization(fan)).json()=={"type":"notification","notificationID":notice["id"],"roomID":event["roomID"]}
    assert e.c.get("/v1/push/destinations/"+delivery["id"],headers=authorization(fan)).status_code==404
    def unfollow_while_status_runs():
        # A local mutation during the remote check must win at the final gate.
        with database(e.c.settings) as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM social_follows WHERE follower_id=?",(account_id(e,fan),))
    e.during_status=unfollow_while_status_runs
    assert e.c.get(path,headers=authorization(fan)).status_code==404


@pytest.mark.parametrize("path",["/v1/me/legal-consent","/v1/account"])
def test_host_withdrawal_cleanup_and_expiry_do_not_restore_audience(live,path):
    e=live;host,fan,event=seed(e)
    assert e.c.delete(path,headers=authorization(host)).status_code==200
    assert rows(e,"social_room_started_events")==[] and notices(e)==[] and rows(e)==[]
    renewed=login(e.c,"room-host");existing_follow(e,fan,renewed)
    assert signed(e,event).status_code==200 and notices(e)==[]
    new=payload(e,renewed,startedAt=int(time.time())-301)
    assert signed(e,new).status_code==422
    assert signed(e,payload(e,renewed)).status_code==200
    assert len(rows(e,"social_room_started_events"))==1
    with database(e.c.settings) as db:
        db.execute("INSERT INTO voice_room_started_nonces VALUES('old',0)")
        room_started.purge(db,int(time.time())+room_started.RECEIPT_TTL+1)
        assert db.execute("SELECT COUNT(*) FROM voice_room_started_nonces").fetchone()[0]==0
        assert db.execute("SELECT COUNT(*) FROM social_room_started_events").fetchone()[0]==0
        assert db.execute("PRAGMA foreign_key_check").fetchall()==[]


def test_nanosecond_follow_boundary_and_consistent_timestamps(live):
    e=live;host=login(e.c,"precise-host")
    before,after=login(e.c,"before-start"),login(e.c,"after-start")
    for fan in [before,after]:existing_follow(e,fan,host)
    second=int(time.time());start_ns=second*1_000_000_000+500_000_000
    event=payload(e,host,startedAt=second,startedAtNs=start_ns)
    with database(e.c.settings) as db:
        for person,created in [(before,start_ns-1),(after,start_ns+1)]:
            db.execute("UPDATE social_follows SET created_at=? WHERE follower_id=?",(created,account_id(e,person)))
    assert signed(e,{**event,"startedAtNs":start_ns+1_000_000_000}).status_code==422
    assert signed(e,event).status_code==200
    assert [n["recipient_id"] for n in notices(e)]==[account_id(e,before)]


@pytest.mark.parametrize("mutation",["block","unfollow","hide","notifications"])
def test_dispatch_rechecks_changes_during_remote_room_status(live,mutation):
    e=live;host,fan,event=seed(e)
    def change():
        if mutation=="block":e.blocks[fan["user"]["id"]]=[host["user"]["id"]]
        else:
            with database(e.c.settings) as db:
                db.execute("BEGIN IMMEDIATE")
                if mutation=="unfollow":db.execute("DELETE FROM social_follows WHERE follower_id=?",(account_id(e,fan),))
                elif mutation=="hide":db.execute("UPDATE accounts SET hide_notification_content=1 WHERE account_id=?",(account_id(e,fan),))
                else:db.execute("UPDATE accounts SET notifications=0 WHERE account_id=?",(account_id(e,fan),))
    e.during_status=change;e.s.dispatch()
    if mutation=="hide":
        from app.push import GENERIC_ALERT
        assert len(e.requests)==1 and json.loads(e.requests[0].content)["aps"]["alert"]==GENERIC_ALERT
    else:assert e.requests==[] and rows(e)[0]["state"]=="cancelled"


def test_notice_and_push_fanout_rollback_is_atomic_and_retryable(live,monkeypatch):
    e=live;host,fan=login(e.c,"atomic-host"),login(e.c,"atomic-fan")
    register(e,fan);existing_follow(e,fan,host);event=payload(e,host)
    original=e.social.notice
    def failing(*args,**kwargs):
        original(*args,**kwargs)
        raise RuntimeError("synthetic transaction failure")
    monkeypatch.setattr(e.social,"notice",failing)
    assert signed(e,event).status_code==500
    assert notices(e)==[] and rows(e)==[] and rows(e,"social_room_started_events")==[]
    monkeypatch.setattr(e.social,"notice",original)
    assert signed(e,event).status_code==200
    assert len(notices(e))==len(rows(e))==len(rows(e,"social_room_started_events"))==1


def test_status_contract_mismatch_fails_closed(live,monkeypatch):
    e=live;host=login(e.c,"bad-status-host");event=payload(e,host)
    wrong={"schemaVersion":1,"eventID":event["eventID"],"roomID":event["roomID"],
           "hostID":event["hostID"],"hostConsentEpoch":event["hostConsentEpoch"],"active":True}
    for change in [{"active":1},{"schemaVersion":True},{"roomID":"lk_"+"a"*32},{"hostConsentEpoch":False},{"extra":1}]:
        monkeypatch.setattr(e.social,"privacy_post",lambda path,payload,change=change:{**wrong,**change})
        assert signed(e,event).status_code==503
        assert notices(e)==[] and rows(e,"social_room_started_events")==[]
