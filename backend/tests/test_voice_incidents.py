import json
import time
import uuid

import httpx
import pytest

from app.main import database
from app import voice_incidents
from app.ops_auth import signed_ops_headers, VOICE_INCIDENT_QUERY_PATH
from test_api import authorization, login
from test_voice_bridge import bridge_client, real_voice_service
from test_ops_auth import ops, register, grant, SECRET as OPS_SECRET


def event(**changes):
    return {"eventID": str(uuid.uuid4()), "attemptID": str(uuid.uuid4()), "operation": "join_room",
        "stage": "media_connect", "severity": "error", "code": "media_connect_timeout",
        "occurredAt": int(time.time()), "elapsedMs": 15000, "platform": "ipados",
        "appVersion": "1.0(9)", "osVersion": "26.0", **changes}


def enqueue(client, user, value=None):
    return client.post("/v1/voice/incidents", headers=authorization(user), json=value or event())


def test_client_incident_binds_account_and_persists_before_async_signed_delivery(bridge_client):
    c=bridge_client; a=login(c); value=event()
    response=enqueue(c,a,value)
    assert response.status_code==200 and response.json()=={"ok":True,"queued":True}
    uuid.UUID(response.headers["X-Kiki-Request-ID"])
    assert not c.sent  # Reporting never waits on the voice server.
    with database(c.settings) as db:
        row=db.execute("SELECT * FROM voice_incident_outbox").fetchone()
        payload=json.loads(row["payload"])
        assert payload["accountID"]==a["user"]["id"] and payload["name"]==a["user"]["name"]
        assert payload["source"]=="client" and payload["consentEpoch"]>0 and payload["lastWithdrawalEpoch"]==0
        assert a["token"] not in row["payload"] and "authorizationID" not in payload
    c.app.state.voice_incidents.retry()
    assert c.sent[-1].url.path==voice_incidents.PATH
    assert not c.sent[-1].headers.get("authorization")
    assert json.loads(c.sent[-1].content)["event"]==value
    with database(c.settings) as db:
        row=db.execute("SELECT * FROM voice_incident_outbox").fetchone()
        assert row["delivered_at"] is not None and row["payload"]=="{}"
    assert enqueue(c,a,value).json()=={"ok":True,"queued":False}
    c.app.state.voice_incidents.retry()
    assert len(c.sent)==1


def test_account_exchange_failure_records_attempt_request_and_sanitized_reason(bridge_client):
    c=bridge_client; a=login(c); attempt=str(uuid.uuid4()); c.fail[0]=True
    response=c.post("/v1/voice/session",headers={**authorization(a),"X-Kiki-Attempt-ID":attempt,
                                               "X-Kiki-Operation":"create_room"})
    assert response.status_code==503
    with database(c.settings) as db:
        payload=json.loads(db.execute("SELECT payload FROM voice_incident_outbox").fetchone()[0])
    value=payload["event"]
    assert payload["source"]=="account" and value["attemptID"]==attempt
    assert value["operation"]=="create_room" and value["stage"]=="account_authorization"
    assert value["requestID"]==response.headers["X-Kiki-Request-ID"]
    assert value["code"]=="http_server_error" and value["httpStatus"]==503
    assert value["platform"]=="server" and value["elapsedMs"]>=0
    c.fail[0]=False; c.app.state.voice_incidents.retry()
    assert json.loads(c.sent[-1].content)==payload


def test_bridge_timeout_is_classified_without_saving_exception_text(bridge_client):
    c=bridge_client;a=login(c)
    def timeout(request):
        raise httpx.ReadTimeout("Bearer very-sensitive-fixture https://private.invalid/body",request=request)
    c.app.state.voice_bridge.http.close()
    c.app.state.voice_bridge.http=httpx.Client(transport=httpx.MockTransport(timeout))
    response=c.post("/v1/voice/session",headers=authorization(a))
    assert response.status_code==503
    with database(c.settings) as db:
        raw=db.execute("SELECT payload FROM voice_incident_outbox").fetchone()[0]
    assert json.loads(raw)["event"]["code"]=="request_timeout"
    assert "sensitive" not in raw and "private.invalid" not in raw and a["token"] not in raw


@pytest.mark.parametrize("changes",[
    {"message":"arbitrary body"}, {"token":"secret"}, {"source":"account"}, {"accountID":"kiki_"+"a"*32},
    {"name":"伪造账号"}, {"eventID":"not-a-uuid"}, {"attemptID":"a"*32}, {"requestID":"https://example.invalid"},
    {"stage":"url"}, {"code":"error:my secret"}, {"severity":"info"}, {"operation":"cancelled"},
    {"occurredAt":True}, {"occurredAt":int(time.time())+1000}, {"occurredAt":int(time.time())-7*86400},
    {"elapsedMs":-1}, {"elapsedMs":True}, {"httpStatus":200}, {"httpStatus":500.0},
    {"roomID":"https://private.invalid"}, {"platform":"server"}, {"appVersion":"https://test"},
    {"osVersion":"a\nsecret"}, {"appVersion":"a"*33}])
def test_client_schema_rejects_sensitive_unknown_or_malformed_fields(bridge_client,changes):
    c=bridge_client;a=login(c)
    assert enqueue(c,a,event(**changes)).status_code==422
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_incident_outbox").fetchone()[0]==0


def test_incident_ingress_requires_current_ordinary_account_consent(bridge_client):
    c=bridge_client;a=login(c)
    assert c.post("/v1/voice/incidents",json=event()).status_code==401
    assert c.post("/v1/voice/incidents",headers={"Authorization":"Bearer ops-token"},json=event()).status_code==401
    with database(c.settings) as db:
        db.execute("UPDATE legal_consent_events SET document_hash=?",("0"*64,))
    assert enqueue(c,a).status_code==428 and not c.sent


def test_outbox_retries_after_restart_and_retention_expires_without_delivery(bridge_client):
    c=bridge_client;a=login(c);value=event();c.fail[0]=True
    assert enqueue(c,a,value).status_code==200
    c.app.state.voice_incidents.retry()
    with database(c.settings) as db:
        row=db.execute("SELECT * FROM voice_incident_outbox").fetchone()
        assert row["attempts"]==1 and row["next_attempt_at"]>int(time.time())
        db.execute("UPDATE voice_incident_outbox SET next_attempt_at=0")
    restarted=voice_incidents.IncidentOutbox(c.settings,database,c.app.state.voice_bridge)
    c.fail[0]=False; restarted.retry()
    assert json.loads(c.sent[-1].content)["event"]["eventID"]==value["eventID"]
    assert enqueue(c,a,event()).status_code==200
    before=len(c.sent)
    with database(c.settings) as db:
        db.execute("UPDATE voice_incident_outbox SET expires_at=0")
    restarted.retry()
    assert len(c.sent)==before
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_incident_outbox").fetchone()[0]==0


def test_durable_limits_and_duplicate_event_do_not_overcount(bridge_client,monkeypatch):
    c=bridge_client;a=login(c);b=login(c,"bob");value=event()
    monkeypatch.setattr(voice_incidents,"HOURLY_LIMIT",2)
    assert enqueue(c,a,value).status_code==200
    assert enqueue(c,a,value).status_code==200
    assert enqueue(c,b,value).status_code==409
    assert enqueue(c,a).status_code==200
    blocked=enqueue(c,a)
    assert blocked.status_code==429 and blocked.headers["Retry-After"]=="3600"
    assert enqueue(c,b).status_code==200
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_incident_outbox").fetchone()[0]==3


@pytest.mark.parametrize("action",["withdraw","delete"])
def test_privacy_action_clears_pending_and_sent_receipts(bridge_client,action):
    c=bridge_client;a=login(c)
    assert enqueue(c,a).status_code==200
    c.app.state.voice_incidents.retry()
    assert enqueue(c,a).status_code==200
    path="/v1/me/legal-consent" if action=="withdraw" else "/v1/account"
    assert c.delete(path,headers=authorization(a)).status_code==200
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_incident_outbox").fetchone()[0]==0
    if action=="withdraw":
        payload=next(json.loads(r.content) for r in c.sent if r.url.path.endswith("/revoke"))
        assert payload["accountID"]==a["user"]["id"] and payload["reason"]=="withdrawal"
    assert enqueue(c,a).status_code==401


@pytest.mark.parametrize("headers",[{"X-Kiki-Attempt-ID":"bad"},{"X-Kiki-Operation":"https://example.invalid"}])
def test_invalid_attempt_headers_never_forward_or_record(bridge_client,headers):
    c=bridge_client;a=login(c)
    response=c.post("/v1/voice/session",headers={**authorization(a),**headers})
    assert response.status_code==422 and not c.sent
    uuid.UUID(response.headers["X-Kiki-Request-ID"])


def test_real_fallback_before_first_voice_session_and_late_withdrawal_replay(real_voice_service):
    pair=real_voice_service;c=pair.account;a=login(c);value=event()
    assert enqueue(c,a,value).status_code==200
    c.app.state.voice_incidents.retry()
    rows=pair.app.state.db.execute("SELECT * FROM room_incidents").fetchall()
    assert len(rows)==1 and rows[0]["user_id"]==a["user"]["id"]
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM users").fetchone()[0]==0
    original=json.loads(pair.captured[-1].content)
    assert original["event"]["eventID"]==value["eventID"]
    assert c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code==200
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM room_incidents").fetchone()[0]==0
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as rejected:
        c.app.state.voice_bridge.post(voice_incidents.PATH,original)
    assert rejected.value.status_code==409
    fresh=login(c);new_value=event()
    assert enqueue(c,fresh,new_value).status_code==200
    c.app.state.voice_incidents.retry()
    rows=pair.app.state.db.execute("SELECT * FROM room_incidents").fetchall()
    assert len(rows)==1 and rows[0]["event_id"]==new_value["eventID"]
    # A delayed old withdrawal cannot erase fresh-consent diagnostics.
    withdrawal=next(json.loads(r.content) for r in pair.captured if r.url.path.endswith("/revoke"))
    c.app.state.voice_bridge.post("/internal/v1/account/revoke",withdrawal)
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM room_incidents").fetchone()[0]==1


def test_real_direct_and_fallback_same_event_are_idempotent(real_voice_service):
    pair=real_voice_service;c=pair.account;a=login(c);value=event()
    voice=c.post("/v1/voice/session",headers=authorization(a)).json()
    direct=pair.voice.post("/v1/telemetry/incidents",headers=authorization(voice),json=value)
    assert direct.status_code==202,direct.text
    assert enqueue(c,a,value).status_code==200
    c.app.state.voice_incidents.retry()
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM room_incidents").fetchone()[0]==1
    with database(c.settings) as db:
        assert db.execute("SELECT delivered_at FROM voice_incident_outbox").fetchone()[0] is not None


def test_inflight_delivery_cannot_recreate_deleted_account_journal(bridge_client):
    c=bridge_client;a=login(c);value=event()
    assert enqueue(c,a,value).status_code==200
    original=c.app.state.voice_bridge.post
    def erased(path,payload):
        if path==voice_incidents.PATH:
            with database(c.settings) as db:
                db.execute("DELETE FROM accounts")
        return original(path,payload)
    c.app.state.voice_bridge.post=erased
    c.app.state.voice_incidents.retry()
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_incident_outbox").fetchone()[0]==0


def query_reply():
    return {"schemaVersion":1,"events":[],"nextCursor":None,"retentionDays":7}


def test_ops_voice_viewer_can_query_fixed_signed_path_and_rechecks_grant(ops):
    session,_=register(ops,"查看日志");grant(ops,session,"voice");sent=[]
    payload={"severity":"error","operation":"join_room","userQuery":"穷奇0000","limit":20}
    def send(request):
        sent.append(request)
        assert str(request.url)=="https://furby.top"+VOICE_INCIDENT_QUERY_PATH
        assert "authorization" not in request.headers and json.loads(request.content)==payload
        expected=signed_ops_headers(OPS_SECRET,path=VOICE_INCIDENT_QUERY_PATH,body=request.content,
            timestamp=int(request.headers["X-Kiki-Ops-Timestamp"]),nonce=request.headers["X-Kiki-Ops-Nonce"])
        assert request.headers["X-Kiki-Ops-Signature"]==expected["X-Kiki-Ops-Signature"]
        return httpx.Response(200,json=query_reply())
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(send))
    path="/admin/v2/services/voice/incidents/query"
    assert ops.client.post(path,headers=authorization(session),json=payload).status_code==200
    def revoke(request):
        grant(ops,session,"voice",action="revoke")
        return send(request)
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(revoke))
    assert ops.client.post(path,headers=authorization(session),json=payload).status_code==403
    assert len(sent)==2


@pytest.mark.parametrize("scope",[None,"account","community"])
def test_ops_query_does_not_accept_other_scopes(ops,scope):
    session,_=register(ops,"没有语聊查看权限")
    if scope: grant(ops,session,scope)
    assert ops.client.post("/admin/v2/services/voice/incidents/query",headers=authorization(session),json={}).status_code==403


@pytest.mark.parametrize("payload",[{"limit":True},{"limit":51},{"severity":"debug"},{"operation":"delete"},
    {"cursor":"not-a-uuid"},{"userQuery":"a\nsecret"},{"userQuery":"a"*81},{"url":"https://evil.invalid"}])
def test_ops_query_strict_parameters(ops,payload):
    session,_=register(ops,"日志查看");grant(ops,session,"voice")
    assert ops.client.post("/admin/v2/services/voice/incidents/query",headers=authorization(session),json=payload).status_code==422


@pytest.mark.parametrize("reply",[
    httpx.Response(302,headers={"Location":"https://evil.invalid"}),httpx.Response(503),
    httpx.Response(200,json={"schemaVersion":1,"events":[],"retentionDays":30}),
    httpx.Response(200,json={**query_reply(),"nextCursor":"bad"})])
def test_ops_query_never_redirects_or_returns_invalid_results(ops,reply):
    session,_=register(ops,"日志查看");grant(ops,session,"voice")
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(lambda request:reply))
    assert ops.client.post("/admin/v2/services/voice/incidents/query",headers=authorization(session),json={}).status_code==503


def test_reused_uuid_cannot_change_pending_or_delivered_event(bridge_client):
    c=bridge_client;a=login(c);value=event()
    assert enqueue(c,a,value).status_code==200
    assert enqueue(c,a,{**value,"code":"network_error"}).status_code==409
    with database(c.settings) as db:
        row=db.execute("SELECT payload_hash,payload FROM voice_incident_outbox").fetchone()
        assert len(row["payload_hash"])==64 and json.loads(row["payload"])["event"]["code"]==value["code"]
    c.app.state.voice_incidents.retry()
    with database(c.settings) as db:
        row=db.execute("SELECT payload_hash,payload FROM voice_incident_outbox").fetchone()
        assert len(row["payload_hash"])==64 and row["payload"]=="{}"
    assert enqueue(c,a,value).json()=={"ok":True,"queued":False}
    assert enqueue(c,a,{**value,"elapsedMs":15001}).status_code==409
    assert enqueue(c,a,{**value,"roomID":"lk_"+"a"*32}).status_code==409


def test_duplicate_ignores_profile_envelope_changes_but_not_source(bridge_client):
    from fastapi import HTTPException
    c=bridge_client;a=login(c);value=event()
    assert enqueue(c,a,value).status_code==200
    assert c.patch("/v1/me",headers=authorization(a),json={"name":"改名后"}).status_code==200
    assert enqueue(c,a,value).json()=={"ok":True,"queued":True}
    with database(c.settings) as db:
        user=db.execute("SELECT * FROM accounts").fetchone()
        with pytest.raises(HTTPException) as rejected:
            c.app.state.voice_incidents.enqueue(db,user,voice_incidents.Incident(**value),consent_epoch=100,last_withdrawal_epoch=0,source="account")
        assert rejected.value.status_code==409
        original=json.loads(db.execute("SELECT payload FROM voice_incident_outbox").fetchone()[0])
        assert original["source"]=="client"


def test_hash_migration_recovers_pending_without_restoring_delivered_content(bridge_client):
    c=bridge_client;a=login(c);pending,sent=event(),event()
    assert enqueue(c,a,sent).status_code==200
    c.app.state.voice_incidents.retry()
    assert enqueue(c,a,pending).status_code==200
    with database(c.settings) as db:
        db.execute("ALTER TABLE voice_incident_outbox DROP COLUMN payload_hash")
        voice_incidents.initialize_database(db)
        rows={row["event_id"]:row for row in db.execute("SELECT * FROM voice_incident_outbox")}
        assert rows[sent["eventID"]]["payload"]=="{}" and rows[sent["eventID"]]["payload_hash"]==""
        assert len(rows[pending["eventID"]]["payload_hash"])==64
    assert enqueue(c,a,pending).json()=={"ok":True,"queued":True}
    assert enqueue(c,a,{**pending,"code":"network_error"}).status_code==409
    assert enqueue(c,a,sent).status_code==409
