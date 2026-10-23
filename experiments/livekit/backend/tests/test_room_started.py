"""Confirmed starts and signed delivery, entirely offline synthetic fixtures."""
import asyncio
import hashlib
import hmac
import json
import secrets
import time
import uuid

from fastapi.testclient import TestClient
import httpx
import pytest

from app import room_started
from app.main import create_app
from conftest import FakeLiveKit, create_room, headers
from test_account_bridge import account_service, payload, signed, SECRET
from test_ordered_rooms import signal_connection
from test_room_actions import state, token, authorize

ORIGINAL_POST = room_started.RoomStarted.post


@pytest.fixture(autouse=True)
def offline_notifications(monkeypatch):
    async def post(self, event):
        calls=getattr(self.app.state,"test_room_start_posts",None)
        if calls is None:self.app.state.test_room_start_posts=[]
        self.app.state.test_room_start_posts.append(dict(event))
    async def idle(self):
        # Each test drives dispatch explicitly, without a two-second race.
        await asyncio.Event().wait()
    monkeypatch.setattr(room_started.RoomStarted,"post",post)
    monkeypatch.setattr(room_started.RoomStarted,"maintain",idle)


def exchange_host(service,*,epoch=11,auth=None):
    data=payload(service,auth=auth)
    data.update(consentEpoch=epoch,lastWithdrawalEpoch=0)
    response=signed(service,"session",data)
    assert response.status_code==200,response.text
    return response.json(),data


def outbox(service):
    return [dict(row) for row in service.app.state.db.execute("SELECT * FROM room_start_outbox ORDER BY created_at,event_id")]


def confirm(service,room,host,raw=None):
    raw=raw or token(service,room,host)
    connection=signal_connection(service,raw)
    connection.upstream_connected=True
    connection.upstream_connected_at=time.time()
    service.rtc.rooms[room["id"]].add(host["user"]["id"])
    state(service,room,host)
    return connection


def started(service):
    host,source=exchange_host(service)
    room=create_room(service,host)
    connection=confirm(service,room,host)
    assert len(outbox(service))==1
    return host,source,room,connection


def query(row):
    return {"eventID":row["event_id"],"roomID":row["room_id"],"hostID":row["host_id"],
            "hostConsentEpoch":row["host_consent_epoch"]}


def test_create_token_pending_validation_and_missing_sfu_never_announce(account_service):
    s=account_service;host,_=exchange_host(s);room=create_room(s,host)
    assert outbox(s)==[]
    raw=token(s,room,host,online=False)
    assert outbox(s)==[]
    validation=authorize(s,raw)
    validation.upstream_connected=True;validation.upstream_connected_at=time.time()
    s.rtc.rooms[room["id"]].add(host["user"]["id"])
    state(s,room,host)
    assert outbox(s)==[],"Validation cannot replace a real signaling connection"
    pending=signal_connection(s,raw)
    state(s,room,host)
    assert outbox(s)==[],"Token authorization and a pending upstream are insufficient"
    pending.upstream_connected=True;pending.upstream_connected_at=time.time()
    s.rtc.rooms[room["id"]].clear()
    state(s,room,host)
    assert outbox(s)==[],"A completed handshake without SFU owner presence is insufficient"
    s.rtc.rooms[room["id"]].add(host["user"]["id"])
    state(s,room,host)
    first=outbox(s)[0]
    assert first["host_consent_epoch"]==11
    assert first["started_at_ns"]//1_000_000_000==first["created_at"]
    assert s.app.state.db.execute("SELECT started_at_ns FROM room_start_markers WHERE room_id=?",(room["id"],)).fetchone()[0]==first["started_at_ns"]


@pytest.mark.parametrize("missing",["timestamp","generation","session","revoked","epoch"])
def test_start_requires_current_generation_source_handshake_and_epoch(account_service,missing):
    s=account_service;host,_=exchange_host(s);room=create_room(s,host)
    raw=token(s,room,host);connection=signal_connection(s,raw)
    connection.upstream_connected=True;connection.upstream_connected_at=time.time()
    if missing=="timestamp":connection.upstream_connected_at=None
    elif missing=="generation":
        with s.app.state.db:s.app.state.db.execute("UPDATE room_members SET generation=generation+1 WHERE room_id=?",(room["id"],))
    elif missing=="session":
        with s.app.state.db:s.app.state.db.execute("UPDATE sessions SET expires_at=0 WHERE user_id=?",(host["user"]["id"],))
    elif missing=="revoked":connection.revoked.set()
    else:
        with s.app.state.db:s.app.state.db.execute("UPDATE account_authorization_privacy SET consent_epoch=0")
    response=s.client.get("/v1/rooms/"+room["id"]+"/state",headers=headers(host))
    assert response.status_code in (200,401,403,409)
    assert outbox(s)==[]


def test_notification_storage_failure_preserves_room_and_next_sample_retries_atomically(account_service):
    s=account_service;host,_=exchange_host(s);room=create_room(s,host)
    raw=token(s,room,host);connection=signal_connection(s,raw)
    connection.upstream_connected=True;connection.upstream_connected_at=time.time()
    with s.app.state.db:
        s.app.state.db.execute("CREATE TEMP TRIGGER fail_room_start BEFORE INSERT ON room_start_outbox BEGIN SELECT RAISE(ABORT,'synthetic notification storage failure'); END")
    result=state(s,room,host)
    assert result["room"]["id"]==room["id"] and result["me"]["online"]
    assert outbox(s)==[]
    assert s.app.state.db.execute("SELECT COUNT(*) FROM room_start_markers WHERE room_id=?",(room["id"],)).fetchone()[0]==0
    with s.app.state.db:s.app.state.db.execute("DROP TRIGGER fail_room_start")
    state(s,room,host)
    assert len(outbox(s))==1
    assert s.app.state.db.execute("SELECT COUNT(*) FROM room_start_markers WHERE room_id=?",(room["id"],)).fetchone()[0]==1


def test_reconnect_same_room_deduplicates_and_new_room_announces_again(account_service):
    s=account_service;host,source,room,connection=started(s);first=outbox(s)[0]
    s.client.portal.call(s.app.state.signal_disconnected,connection)
    assert signed(s,"room-started-status",query(first)).json()["active"] is True,"Existing reconnect grace remains an active room"
    confirm(s,room,host)
    state(s,room,host)
    assert len(outbox(s))==1 and outbox(s)[0]["event_id"]==first["event_id"]
    assert s.client.post("/v1/rooms/"+room["id"]+"/leave",headers=headers(host)).status_code==200
    second=create_room(s,host);confirm(s,second,host)
    assert len(outbox(s))==2
    assert len({row["event_id"] for row in outbox(s)})==2


def test_dispatch_retries_same_event_and_releases_voice_lock_for_status_callback(account_service):
    s=account_service;host,source,room,connection=started(s)
    attempts=[];statuses=[]
    async def post(event):
        attempts.append(dict(event))
        body=json.dumps({key:event[key] for key in ("eventID","roomID","hostID","hostConsentEpoch")},separators=(",",":")).encode()
        timestamp=str(int(time.time()));nonce=secrets.token_hex(16)
        message="\n".join(("account-voice-v1","POST",room_started.STATUS_PATH,timestamp,nonce,hashlib.sha256(body).hexdigest())).encode()
        request_headers={"Content-Type":"application/json","X-Kiki-Timestamp":timestamp,"X-Kiki-Nonce":nonce,
            "X-Kiki-Signature":hmac.new(SECRET.encode(),message,hashlib.sha256).hexdigest()}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=s.app),base_url="http://testserver") as client:
            response=await asyncio.wait_for(client.post(room_started.STATUS_PATH,content=body,headers=request_headers),timeout=1)
        assert response.status_code==200,response.text
        statuses.append(response.json()["active"])
        if len(attempts)==1:raise TimeoutError("synthetic ambiguous account response")
    sender=s.app.state.room_started;sender.post=post
    s.client.portal.call(sender.dispatch)
    first=outbox(s)[0]
    assert first["state"]=="pending" and first["attempts"]==1
    assert statuses==[True],"The account callback must acquire the actual voice lock during POST"
    s.client.portal.call(sender.dispatch)
    assert len(attempts)==1,"An immediate dispatch cannot bypass the committed retry deadline"
    with s.app.state.db:s.app.state.db.execute("UPDATE room_start_outbox SET next_attempt_at=0")
    s.client.portal.call(sender.dispatch)
    final=outbox(s)[0]
    assert final["state"]=="delivered" and final["attempts"]==2
    assert attempts[0]==attempts[1] and statuses==[True,True]
    assert set(attempts[0])=={"schemaVersion","eventID","roomID","hostID","hostConsentEpoch","startedAt","startedAtNs"}
    assert attempts[0]["startedAtNs"]//1_000_000_000==attempts[0]["startedAt"]
    assert all(key not in attempts[0] for key in ("name","title","text","recipientIDs"))


@pytest.mark.parametrize("reason",["expired","closed","revoked"])
def test_outbox_cancels_before_send_when_expired_closed_or_source_revoked(account_service,reason):
    s=account_service;host,source,room,connection=started(s);row=outbox(s)[0]
    if reason=="expired":s.app.state.room_started.clock=lambda:row["expires_at"]
    elif reason=="closed":
        assert s.client.post("/v1/rooms/"+room["id"]+"/leave",headers=headers(host)).status_code==200
    else:assert signed(s,"revoke",{"authorizationID":source["authorizationID"]}).status_code==200
    s.client.portal.call(s.app.state.room_started.dispatch)
    assert outbox(s)[0]["state"]=="cancelled"
    assert getattr(s.app.state,"test_room_start_posts",[])==[]


def test_pending_event_survives_process_restart_without_reannouncing(account_service):
    s=account_service;host,source,room,connection=started(s);first=outbox(s)[0]
    # A second app reconstructs service state from the same durable database.
    rtc=FakeLiveKit(s.settings);rtc.rooms={key:set(value) for key,value in s.rtc.rooms.items()}
    app=create_app(s.settings,rtc)
    with TestClient(app) as client:
        restarted=type("Service",(),{"app":app,"client":client,"rtc":rtc,"settings":s.settings})()
        assert outbox(restarted)[0]["event_id"]==first["event_id"]
        client.portal.call(app.state.room_started.dispatch)
        assert outbox(restarted)[0]["state"]=="delivered"
        assert app.state.test_room_start_posts[0]["eventID"]==first["event_id"]
        assert len(outbox(restarted))==1


def test_signed_status_requires_exact_identity_domain_nonce_and_current_rights(account_service):
    s=account_service;host,source,room,connection=started(s);event=query(outbox(s)[0])
    path=room_started.STATUS_PATH
    assert s.client.post(path,json=event).status_code==401
    assert signed(s,"room-started-status",event,secret="wrong").status_code==401
    assert signed(s,"room-started-status",event,timestamp=int(time.time())-31).status_code==401
    nonce=secrets.token_hex(16)
    assert signed(s,"room-started-status",event,nonce=nonce).json()=={"schemaVersion":1,**event,"active":True}
    assert signed(s,"room-started-status",event,nonce=nonce).status_code==401
    assert signed(s,"room-started-status/",event).status_code==404
    assert signed(s,"room-started-status?extra=1",event).status_code==404
    for change in [{"eventID":str(uuid.uuid4())},{"roomID":"lk_"+"f"*32},{"hostID":"kiki_other_host0001"},{"hostConsentEpoch":12}]:
        assert signed(s,"room-started-status",{**event,**change}).json()["active"] is False
    assert signed(s,"room-started-status",{**event,"hostConsentEpoch":True}).status_code==422
    assert signed(s,"room-started-status",{**event,"name":"untrusted"}).status_code==422
    body=json.dumps(event).encode()
    # Reverse-direction event signatures cannot authorize the status interface.
    stamp=str(int(time.time()));nonce=secrets.token_hex(16)
    wrong_domain="\n".join(("voice-account-room-started-v1","POST",path,stamp,nonce,hashlib.sha256(body).hexdigest())).encode()
    wrong_headers={"Content-Type":"application/json","X-Kiki-Timestamp":stamp,"X-Kiki-Nonce":nonce,
        "X-Kiki-Signature":hmac.new(SECRET.encode(),wrong_domain,hashlib.sha256).hexdigest()}
    assert s.client.post(path,content=body,headers=wrong_headers).status_code==401
    with s.app.state.db:s.app.state.db.execute("UPDATE account_authorization_privacy SET consent_epoch=12")
    assert signed(s,"room-started-status",event).json()["active"] is False


@pytest.mark.parametrize("action",["withdrawal","delete"])
def test_privacy_erases_outbox_but_keeps_room_marker(account_service,action):
    s=account_service;host,source,room,connection=started(s)
    if action=="withdrawal":
        result=signed(s,"revoke",{"authorizationID":source["authorizationID"],"reason":"withdrawal",
            "consentEpoch":12,"accountID":host["user"]["id"]})
    else:result=signed(s,"delete",{"accountID":host["user"]["id"]})
    assert result.status_code==200,result.text
    assert outbox(s)==[]
    assert s.app.state.db.execute("SELECT COUNT(*) FROM room_start_markers WHERE room_id=?",(room["id"],)).fetchone()[0]==1
    s.client.portal.call(s.app.state.room_started.dispatch)
    assert getattr(s.app.state,"test_room_start_posts",[])==[]


def test_install_migration_marks_existing_rooms_without_backfill(account_service):
    s=account_service;host,_=exchange_host(s);room=create_room(s,host)
    with s.app.state.db:
        s.app.state.db.execute("DROP TABLE room_start_outbox")
        s.app.state.db.execute("DROP TABLE room_start_markers")
        room_started.initialize_database(s.app.state.db)
    assert s.app.state.db.execute("SELECT started_at_ns FROM room_start_markers WHERE room_id=?",(room["id"],)).fetchone()[0]==0
    confirm(s,room,host)
    assert outbox(s)==[]
    with s.app.state.db:room_started.initialize_database(s.app.state.db)
    assert outbox(s)==[]


def test_receipt_retention_and_room_foreign_keys(account_service):
    s=account_service;host,source,room,connection=started(s);created=outbox(s)[0]["created_at"]
    with s.app.state.db:
        room_started.purge(s.app.state.db,created+room_started.RECEIPT_TTL)
        assert s.app.state.db.execute("SELECT COUNT(*) FROM room_start_outbox").fetchone()[0]==0
        assert s.app.state.db.execute("PRAGMA foreign_key_check").fetchall()==[]


@pytest.mark.parametrize("status,body,encoding,valid",[
    (200,b'{"ok":true}',"identity",True),(503,b'{"ok":true}',"identity",False),
    (200,b'{"ok":1}',"identity",False),(200,b'{"ok":true,"extra":1}',"identity",False),
    (200,b'{"ok":true}',"gzip",False),(200,b'x'*4097,"identity",False),
    (200,[b'{"ok":',b'true}'],"identity",True),
    (200,[b'{"ok":true}',b'x'],"identity",False),
    (200,[b'{"ok":true}',b' '*4097],"identity",False)])
def test_post_fixed_https_signature_and_strict_bounded_ack(account_service,monkeypatch,status,body,encoding,valid):
    s=account_service;host,source,room,connection=started(s);row=outbox(s)[0]
    event={"schemaVersion":1,**query(row),"startedAt":row["started_at_ns"]//1_000_000_000,"startedAtNs":row["started_at_ns"]}
    captured=[]
    class Content:
        def __init__(self):self.chunks=list(body) if isinstance(body,list) else [body]
        async def read(self,maximum):
            assert 0<maximum<=4097
            if not self.chunks:return b""
            chunk=self.chunks.pop(0)
            if len(chunk)>maximum:self.chunks.insert(0,chunk[maximum:])
            return chunk[:maximum]
    class Response:
        def __init__(self):self.status=status;self.headers={"Content-Encoding":encoding};self.content=Content()
        async def __aenter__(self):return self
        async def __aexit__(self,*args):return False
    class Session:
        def __init__(self,**kwargs):
            assert kwargs["trust_env"] is False and kwargs["auto_decompress"] is False
            assert kwargs["timeout"].total==3
        async def __aenter__(self):return self
        async def __aexit__(self,*args):return False
        def post(self,url,*,data,headers,allow_redirects):
            assert url=="https://kiki.group"+room_started.EVENT_PATH and allow_redirects is False
            assert json.loads(data)==event
            message="\n".join(("voice-account-room-started-v1","POST",room_started.EVENT_PATH,
                headers["X-Kiki-Timestamp"],headers["X-Kiki-Nonce"],hashlib.sha256(data).hexdigest())).encode()
            assert hmac.compare_digest(headers["X-Kiki-Signature"],hmac.new(SECRET.encode(),message,hashlib.sha256).hexdigest())
            captured.append(data)
            return Response()
    monkeypatch.setattr(room_started.aiohttp,"ClientSession",Session)
    async def run():return await ORIGINAL_POST(s.app.state.room_started,event)
    if valid:s.client.portal.call(run)
    else:
        with pytest.raises(ValueError):s.client.portal.call(run)
    assert len(captured)==1
