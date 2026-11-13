"""Privacy, durable evidence and exact operator bridge regression coverage."""
import json
import secrets
import time
import uuid
from fastapi.testclient import TestClient
import pytest
from app import incidents
from app.main import create_app
from app.ops_gateway import INCIDENT_QUERY_PATH
from conftest import FakeLiveKit, create_room, headers, login
from test_account_bridge import account_service, payload as exchange_payload, signed
from test_ops_gateway import ops, signed as ops_signed


def event(**changes):
    return {"eventID":str(uuid.uuid4()),"attemptID":str(uuid.uuid4()),"operation":"join_room","stage":"media_connect","severity":"error","code":"media_connect_timeout","occurredAt":int(time.time()),"elapsedMs":15000,"roomID":None,"requestID":None,"httpStatus":None,"platform":"ipados","appVersion":"1.0(3)","osVersion":"26.0",**changes}


def report(s,user,data):
    return s.client.post("/v1/telemetry/incidents",headers=headers(user),json=data)


def query_incidents(service, **parameters):
    body=json.dumps(parameters).encode()
    response=service.client.post(INCIDENT_QUERY_PATH,content=body,headers=ops_signed(body=body,path=INCIDENT_QUERY_PATH))
    assert response.status_code==200,response.text
    return response.json()


def internal_event(**changes):
    return {"accountID":"kiki_0123456789abcdef","name":"可信账号","consentEpoch":10,"lastWithdrawalEpoch":0,"source":"client","event":event(),**changes}


def test_identity_injected_and_no_public_read(lab):
    user=login(lab,"穷奇0000");data=event();r=report(lab,user,data)
    assert r.status_code==202 and r.json()=={"accepted":True,"eventID":data["eventID"],"duplicate":False}
    row=lab.app.state.incidents.dashboard()["events"][0]
    assert row["userID"]==user["user"]["id"] and row["userName"]=="穷奇0000" and row["source"]=="client"
    assert row["message"]==incidents.CODES[data["code"]] and "token" not in json.dumps(row)
    assert lab.client.get("/v1/telemetry/incidents",headers=headers(user)).status_code in {404,405}
    assert lab.client.post("/v1/telemetry/incidents",json=data).status_code==401


@pytest.mark.parametrize("changes",[{"userID":"another"},{"userDisplayID":"kiki_123456"},{"name":"伪造"},{"source":"server"},{"message":"secret"},{"url":"https://evil.test/?token=secret"},{"code":"secret-error-text"},{"appVersion":"a"*33},{"osVersion":"26.0\nsecret"},{"roomID":"arbitrary"},{"eventID":"not-uuid"},{"attemptID":None},{"requestID":"secret"},{"occurredAt":True},{"httpStatus":200},{"elapsedMs":-1},{"platform":"server"}])
def test_strict_bounded_schema(lab,changes):
    assert report(lab,login(lab),event(**changes)).status_code==422
    assert lab.app.state.incidents.dashboard()["totalEvents"]==0


def test_idempotency_conflict_and_restart_durable_limit(lab):
    user=login(lab);data=event()
    assert report(lab,user,data).status_code==202
    assert report(lab,user,data).json()["duplicate"]
    assert report(lab,user,{**data,"code":"network_error"}).status_code==409
    assert report(lab,login(lab),data).status_code==409
    for _ in range(19):
        assert report(lab,user,event()).status_code==202
    assert report(lab,user,event()).status_code==429
    with TestClient(create_app(lab.settings,FakeLiveKit(lab.settings))) as c:
        assert c.post("/v1/telemetry/incidents",headers=headers(user),json=event()).status_code==429
        assert c.post("/v1/telemetry/incidents",headers=headers(user),json=data).json()["duplicate"]


def test_retention_cap_quality_dedup_and_timestamp(lab,monkeypatch):
    user=login(lab)
    for stamp in (int(time.time())-7*86400,int(time.time())+301):
        assert report(lab,user,event(occurredAt=stamp)).status_code==422
    monkeypatch.setattr(incidents,"MAX_EVENTS",3)
    for _ in range(4):
        assert report(lab,user,event()).status_code==202
    assert lab.app.state.incidents.dashboard()["totalEvents"]==3
    attempt=str(uuid.uuid4())
    assert report(lab,user,event(operation="room_runtime",code="quality_poor",attemptID=attempt)).status_code==202
    assert report(lab,user,event(operation="room_runtime",code="quality_poor",attemptID=attempt)).json()["duplicate"]
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE room_incidents SET occurred_at=?",(int(time.time())-7*86400,))
    assert lab.app.state.incidents.dashboard()["totalEvents"]==0


def test_withdrawal_and_deletion_erase(lab):
    a,b=login(lab),login(lab)
    assert report(lab,a,event()).status_code==202 and report(lab,b,event()).status_code==202
    assert lab.client.delete("/v1/me/legal-consent",headers=headers(a)).status_code==200
    assert report(lab,a,event()).status_code==401
    assert lab.app.state.incidents.dashboard()["totalEvents"]==1
    assert lab.client.delete("/v1/account",headers=headers(b)).status_code==200
    assert lab.app.state.incidents.dashboard()["totalEvents"]==0


def test_banned_can_report_without_membership(lab):
    user=login(lab)
    with lab.app.state.db:
        lab.app.state.db.execute("INSERT INTO safety_restrictions(user_id,banned_until,reason) VALUES(?,?,?)",(user["user"]["id"],int(time.time())+3600,"限制"))
    assert report(lab,user,event()).status_code==202
    assert lab.client.get("/v1/rooms",headers=headers(user)).status_code==403


def test_server_create_failure_captured_and_dedup_attempt(lab):
    user=login(lab,"穷奇");attempt=str(uuid.uuid4());lab.rtc.create_failure=True
    r=lab.client.post("/v1/rooms",headers={**headers(user),"X-Kiki-Attempt-ID":attempt},json={"title":"不要保存正文","category":"闲聊","theme":0,"isLive":False})
    assert r.status_code==503
    stored=lab.app.state.incidents.dashboard()["events"][0]
    assert stored["source"]=="server" and stored["operation"]=="create_room" and stored["stage"]=="room_api"
    assert stored["code"]=="request_timeout" and stored["attemptID"]==attempt
    assert stored["requestID"]==r.headers["x-kiki-request-id"] and stored["elapsedMs"]>=0
    assert "不要保存" not in json.dumps(stored,ensure_ascii=False)
    assert report(lab,user,event(operation="create_room",attemptID=attempt)).status_code==202
    stats=lab.app.state.incidents.dashboard()
    assert stats["errorsLast24Hours"]==2 and stats["failedAttemptsLast24Hours"]==1


def test_server_token_503_and_denial_warning(lab):
    owner,other=login(lab),login(lab);room=create_room(lab,owner);lab.rtc.unavailable=True
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token',headers=headers(other)).status_code==503
    lab.rtc.unavailable=False
    with lab.app.state.db:
        lab.app.state.db.execute("INSERT INTO room_bans VALUES(?,?,?)",(room["id"],other["user"]["id"],int(time.time())))
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token',headers=headers(other)).status_code==403
    events=lab.app.state.incidents.dashboard()["events"]
    assert {e["severity"] for e in events}=={"warning","error"}
    assert all(e["stage"]=="token_api" and e["roomID"]==room["id"] for e in events)


def test_internal_before_voice_user_withdraw_and_late_delivery(account_service):
    s=account_service;data=internal_event()
    assert signed(s,"incident",data).status_code==202
    assert not s.app.state.db.execute("SELECT 1 FROM users").fetchone()
    assert signed(s,"incident",data).json()["duplicate"]
    withdrawal={"authorizationID":exchange_payload(s)["authorizationID"],"reason":"withdrawal","accountID":data["accountID"],"consentEpoch":11}
    assert signed(s,"revoke",withdrawal).status_code==200
    assert s.app.state.incidents.dashboard()["totalEvents"]==0
    assert signed(s,"incident",{**data,"event":event()}).status_code==409
    assert signed(s,"incident",{**data,"consentEpoch":12,"lastWithdrawalEpoch":11,"event":event()}).status_code==202
    assert signed(s,"revoke",withdrawal).status_code==200
    assert s.app.state.incidents.dashboard()["totalEvents"]==1
    assert signed(s,"delete",{"accountID":data["accountID"]}).status_code==200
    assert signed(s,"incident",{**data,"consentEpoch":12,"event":event()}).status_code==401


def test_internal_hmac_replay_source_and_exact_path(account_service):
    s=account_service;data=internal_event();nonce=secrets.token_hex(16)
    assert signed(s,"incident",data,secret="wrong").status_code==401
    assert signed(s,"incident",data,nonce=nonce).status_code==202
    assert signed(s,"incident",data,nonce=nonce).status_code==401
    assert signed(s,"incident",{**data,"source":"server"}).status_code==422
    assert signed(s,"incident",{**data,"source":"account"}).status_code==422
    account=internal_event(source="account",event=event(platform="server",appVersion="account-api",osVersion="server"))
    assert signed(s,"incident",account).status_code==202
    assert signed(s,"incident?extra=1",data).status_code==401
    assert s.client.post("/internal/v1/account/incident",json=data).status_code==401


def test_ops_query_permission_pagination_filter_and_like_literal(ops):
    ops.consent={**ops.app.state.legal,"accepted":True,"adultConfirmed":True}
    user=login(ops,"百分%_号")
    for i in range(4):
        assert report(ops,user,event(operation="create_room" if i%2 else "join_room",severity="warning" if i%2 else "error")).status_code==202
    body=json.dumps({"limit":2}).encode()
    assert ops.client.post(INCIDENT_QUERY_PATH,content=body,headers=headers(user)).status_code==401
    first=ops.client.post(INCIDENT_QUERY_PATH,content=body,headers=ops_signed(body=body,path=INCIDENT_QUERY_PATH))
    assert first.status_code==200,first.text
    data=first.json();assert len(data["events"])==2 and data["nextCursor"]
    body=json.dumps({"limit":2,"cursor":data["nextCursor"]}).encode()
    second=ops.client.post(INCIDENT_QUERY_PATH,content=body,headers=ops_signed(body=body,path=INCIDENT_QUERY_PATH)).json()
    assert len(second["events"])==2 and second["nextCursor"] is None
    assert not {e["eventID"] for e in data["events"]}&{e["eventID"] for e in second["events"]}
    body=json.dumps({"severity":"warning","operation":"create_room","userQuery":"%_"}).encode()
    assert len(ops.client.post(INCIDENT_QUERY_PATH,content=body,headers=ops_signed(body=body,path=INCIDENT_QUERY_PATH)).json()["events"])==2
    body=json.dumps({"userQuery":"nonexistent%"}).encode()
    assert ops.client.post(INCIDENT_QUERY_PATH,content=body,headers=ops_signed(body=body,path=INCIDENT_QUERY_PATH)).json()["events"]==[]
    body=json.dumps({"cursor":str(uuid.uuid4())}).encode()
    assert ops.client.post(INCIDENT_QUERY_PATH,content=body,headers=ops_signed(body=body,path=INCIDENT_QUERY_PATH)).status_code==422


def test_public_number_maps_retained_events_without_rewriting_identity_or_payload(ops):
    ops.consent={**ops.app.state.legal,"accepted":True,"adultConfirmed":True}
    user=login(ops,"旧问题用户");uid=user["user"]["id"];data=event()
    assert report(ops,user,data).status_code==202
    before=ops.app.state.db.execute("SELECT payload,payload_hash FROM room_incidents WHERE event_id=?",(data["eventID"],)).fetchone()
    assert query_incidents(ops,userQuery="kiki_123456")["events"]==[]
    with ops.app.state.db:
        ops.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?",("kiki_123456",uid))
    for query in ("kiki_123456","123456",uid,"旧问题用户"):
        result=query_incidents(ops,userQuery=query)
        assert len(result["events"])==1
        item=result["events"][0]
        assert item["eventID"]==data["eventID"] and item["userID"]==uid
        assert item["userDisplayID"]=="kiki_123456" and item["userName"]=="旧问题用户"
    dashboard=ops.app.state.incidents.dashboard()
    assert dashboard["events"][0]["userDisplayID"]=="kiki_123456"
    after=ops.app.state.db.execute("SELECT payload,payload_hash FROM room_incidents WHERE event_id=?",(data["eventID"],)).fetchone()
    assert tuple(after)==tuple(before)
    assert "userDisplayID" not in json.loads(after["payload"])
    assert report(ops,user,data).json()["duplicate"]


def test_public_number_filter_paginates_same_timestamp_events_without_duplicates_or_omissions(ops):
    ops.consent={**ops.app.state.legal,"accepted":True,"adultConfirmed":True}
    user,other=login(ops,"同名用户"),login(ops,"同名用户")
    with ops.app.state.db:
        ops.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?",("kiki_123456",user["user"]["id"]))
        ops.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?",("kiki_654321",other["user"]["id"]))
    expected=[]
    for index in range(7):
        value=event(eventID=str(uuid.UUID(int=index+1)))
        assert report(ops,user,value).status_code==202
        expected.append(value["eventID"])
    assert report(ops,other,event()).status_code==202
    assert report(ops,user,event(severity="warning")).status_code==202
    assert report(ops,user,event(operation="create_room")).status_code==202
    with ops.app.state.db:
        ops.app.state.db.execute("UPDATE room_incidents SET received_at=?",(int(time.time()),))
    actual=[];cursor=None
    for _ in range(5):
        page=query_incidents(ops,userQuery="kiki_123456",severity="error",operation="join_room",limit=2,**({"cursor":cursor} if cursor else {}))
        actual.extend(item["eventID"] for item in page["events"])
        assert all(item["userID"]==user["user"]["id"] and item["userDisplayID"]=="kiki_123456" for item in page["events"])
        cursor=page["nextCursor"]
        if cursor is None:break
    assert cursor is None
    assert actual==sorted(expected,reverse=True)


@pytest.mark.parametrize("query,expected_name",[("kiki_123456","编号用户"),("123%456","123%456"),("%_","百分%_号"),("反\\斜","反\\斜")])
def test_public_number_search_preserves_literal_percent_underscore_and_backslash(ops,query,expected_name):
    ops.consent={**ops.app.state.legal,"accepted":True,"adultConfirmed":True}
    for name in ("编号用户","kikiX123456","123%456","百分%_号","反\\斜"):
        user=login(ops,name)
        if name=="编号用户":
            with ops.app.state.db:
                ops.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?",("kiki_123456",user["user"]["id"]))
        assert report(ops,user,event()).status_code==202
    result=query_incidents(ops,userQuery=query)
    assert [item["userName"] for item in result["events"]]==[expected_name]


def test_uncached_fallback_keeps_internal_identity_then_gains_current_public_alias(account_service):
    from test_account_bridge import exchange,profile
    service=account_service;data=internal_event()
    assert signed(service,"incident",data).status_code==202
    assert not service.app.state.db.execute("SELECT 1 FROM users").fetchone()
    for query in (data["accountID"],data["name"]):
        page=service.app.state.incidents.query(incidents.IncidentQuery(userQuery=query))
        assert len(page["events"])==1
        assert page["events"][0]["userID"]==data["accountID"]
        assert page["events"][0]["userDisplayID"] is None
    assert service.app.state.incidents.query(incidents.IncidentQuery(userQuery="kiki_123456"))["events"]==[]
    assert not service.app.state.db.execute("SELECT 1 FROM users").fetchone()
    assert exchange(service,user={**profile(),"displayID":"kiki_123456"}).status_code==200
    page=service.app.state.incidents.query(incidents.IncidentQuery(userQuery="kiki_123456"))
    assert len(page["events"])==1 and page["events"][0]["eventID"]==data["event"]["eventID"]
    assert page["events"][0]["userID"]==data["accountID"] and page["events"][0]["userDisplayID"]=="kiki_123456"


def test_deleted_profile_cannot_map_retained_incidents_to_a_reused_public_number(ops):
    ops.consent={**ops.app.state.legal,"accepted":True,"adultConfirmed":True}
    old,new=login(ops,"旧账号"),login(ops,"新账号")
    for user in (old,new):
        assert report(ops,user,event()).status_code==202
    with ops.app.state.db:
        ops.app.state.db.execute("UPDATE users SET display_id=? WHERE id IN (?,?)",("kiki_123456",old["user"]["id"],new["user"]["id"]))
        ops.app.state.db.execute("UPDATE users SET deleted=1 WHERE id=?",(old["user"]["id"],))
    page=query_incidents(ops,userQuery="kiki_123456")
    assert [item["userID"] for item in page["events"]]==[new["user"]["id"]]
    old_page=query_incidents(ops,userQuery=old["user"]["id"])
    assert len(old_page["events"])==1 and old_page["events"][0]["userDisplayID"] is None


@pytest.mark.parametrize("cached_number",[None,"","kiki_000000","kiki_12345","kiki_1234567","kiki_abcdef"])
def test_missing_or_invalid_public_cache_falls_back_to_internal_identity(ops,cached_number):
    ops.consent={**ops.app.state.legal,"accepted":True,"adultConfirmed":True}
    user=login(ops,"旧缓存用户");uid=user["user"]["id"]
    assert report(ops,user,event()).status_code==202
    with ops.app.state.db:
        ops.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?",(cached_number,uid))
    page=query_incidents(ops,userQuery=uid)
    assert len(page["events"])==1
    assert page["events"][0]["userID"]==uid and page["events"][0]["userDisplayID"] is None
    assert ops.app.state.incidents.dashboard()["events"][0]["userDisplayID"] is None
    if cached_number and cached_number not in uid:
        assert query_incidents(ops,userQuery=cached_number)["events"]==[]


def test_day_allowance_and_trusted_lane_are_independent(lab):
    user=login(lab);store=lab.app.state.incidents;uid=user["user"]["id"];now=int(time.time())
    for index in range(100):
        with lab.app.state.db:
            assert store.record(uid,"用户",incidents.Incident(**event()),now=now+(index//20)*61)["accepted"]
    with pytest.raises(Exception) as caught:
        with lab.app.state.db:
            store.record(uid,"用户",incidents.Incident(**event()),now=now+305)
    assert caught.value.status_code==429
    with lab.app.state.db:
        assert store.record(uid,"用户",incidents.Incident(**event(platform="server",appVersion="voice-api",osVersion="server")),source="server",now=now+305)["accepted"]


def test_direct_and_signed_fallback_share_uuid_without_changing_identity(account_service):
    from test_account_bridge import exchange
    s=account_service
    user=exchange(s).json();data=event()
    assert report(s,user,data).status_code==202
    # The envelope contains current trusted profile; transport does not change
    # the dedupe key, even if the display name changed after the first upload.
    fallback=internal_event(name="更新昵称",event=data)
    assert signed(s,"incident",fallback).json()["duplicate"]
    assert s.app.state.incidents.dashboard()["totalEvents"]==1


def test_unexpected_server_exception_is_redacted_and_persisted(lab,monkeypatch):
    user=login(lab);room=create_room(lab,user)
    def broken(*args):
        raise RuntimeError("secret token and arbitrary room text")
    monkeypatch.setattr(lab.rtc,"participant_token",broken)
    response=lab.client.post(f'/v1/rooms/{room["id"]}/token',headers=headers(user))
    assert response.status_code==503
    stored=lab.app.state.incidents.dashboard()["events"][0]
    assert stored["source"]=="server" and stored["code"]=="http_server_error"
    assert "secret" not in json.dumps(stored) and "secret" not in response.text
