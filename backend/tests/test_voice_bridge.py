from dataclasses import replace
import hashlib
import hmac
import json
import sqlite3
import time

from fastapi.testclient import TestClient
import httpx
import pytest

from app.main import Settings, create_app, database
from app.voice_bridge import authorization_id, signed_headers
from conftest import apple_settings, apple_payload
from test_api import authorization, login

SECRET = "voice-bridge-test-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


@pytest.fixture
def bridge_client(tmp_path, fake_apple):
    settings = apple_settings(Settings(str(tmp_path / "bridge.sqlite3"), 0, "", False,
        voice_bridge_enabled=True, voice_bridge_secret=SECRET))
    app = create_app(settings)
    sent = []
    fail = [False]
    def request(req):
        sent.append(req)
        assert req.url.host == "furby.top"
        payload = json.loads(req.content)
        headers = signed_headers(SECRET, req.url.path, req.content,
            timestamp=int(req.headers["x-kiki-timestamp"]), nonce=req.headers["x-kiki-nonce"])
        assert hmac.compare_digest(req.headers["x-kiki-signature"], headers["X-Kiki-Signature"])
        if fail[0]:
            return httpx.Response(503)
        if req.url.path.endswith("/session"):
            expires = min(payload["sourceExpiresAt"], int(time.time()) + 900)
            return httpx.Response(200, json={"token": "v"*43, "expiresAt": expires,
                "user": payload["user"], "sdk": {"provider": "livekit", "serverURL": "wss://furby.top",
                    "userID": payload["user"]["id"], "expiresAt": expires}})
        return httpx.Response(200, json={"ok": True})
    app.state.voice_bridge.http.close()
    app.state.voice_bridge.http = httpx.Client(transport=httpx.MockTransport(request))
    with TestClient(app) as client:
        client.settings, client.fake_apple = settings, fake_apple
        client.sent, client.fail = sent, fail
        yield client


def test_account_login_has_no_tencent_credentials_and_exchange_is_separate(bridge_client):
    c=bridge_client; value=login(c)
    assert "sdk" not in value and not c.sent
    refresh=c.post("/v1/auth/refresh",headers=authorization(value))
    assert refresh.status_code == 200 and "sdk" not in refresh.json()
    exchanged=c.post("/v1/voice/session",headers=authorization(value))
    assert exchanged.status_code == 200
    assert exchanged.json()["sdk"]["provider"] == "livekit"
    request=c.sent[-1]; body=json.loads(request.content)
    assert body["user"]["sdkUserID"] == value["user"]["id"]
    assert body["consentEpoch"] > 0 and body["lastWithdrawalEpoch"] == 0
    assert body["authorizationID"] != hashlib.sha256(value["token"].encode()).hexdigest()
    assert value["token"] not in request.content.decode() and not request.headers.get("authorization")
    assert c.get("/v1/me",headers={"Authorization":"Bearer "+exchanged.json()["token"]}).status_code == 401
    assert c.post("/v1/rooms",headers=authorization(value),json={}).status_code == 426


def test_logout_revokes_only_exact_source_and_durable_outbox_retries(bridge_client):
    c=bridge_client; old=login(c); fresh=login(c)
    c.post("/v1/voice/session",headers=authorization(old))
    c.fail[0]=True
    assert c.post("/v1/auth/logout",headers=authorization(old)).status_code == 200
    with database(c.settings) as db:
        rows=db.execute("SELECT * FROM voice_revocation_outbox").fetchall()
        assert len(rows)==1 and rows[0]["attempts"] == 1
        source=hashlib.sha256(old["token"].encode()).hexdigest()
        assert rows[0]["subject"] == source
        db.execute("UPDATE voice_revocation_outbox SET next_attempt_at=0")
    assert c.post("/v1/voice/session",headers=authorization(old)).status_code == 401
    assert c.get("/v1/me",headers=authorization(fresh)).status_code == 200
    c.fail[0]=False; c.app.state.voice_bridge.retry_revocations()
    body=json.loads(c.sent[-1].content)
    assert body == {"authorizationID":authorization_id(SECRET,source)}
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_revocation_outbox").fetchone()[0]==0


def test_withdrawal_queues_every_existing_source_and_old_retry_preserves_new_login(bridge_client):
    c=bridge_client; a=login(c); b=login(c)
    assert c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code == 200
    c.app.state.voice_bridge.retry_revocations()
    revokes=[json.loads(r.content)["authorizationID"] for r in c.sent if r.url.path.endswith("/revoke")]
    assert set(revokes)=={authorization_id(SECRET,hashlib.sha256(v["token"].encode()).hexdigest()) for v in (a,b)}
    withdrawals=[json.loads(r.content) for r in c.sent if r.url.path.endswith("/revoke") and json.loads(r.content).get("reason")=="withdrawal"]
    assert len(withdrawals)==2
    assert all(row["consentEpoch"] > 0 for row in withdrawals)
    fresh=login(c)
    assert c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code == 200
    assert c.post("/v1/voice/session",headers=authorization(fresh)).status_code == 200
    body=json.loads(c.sent[-1].content)
    assert body["consentEpoch"] > body["lastWithdrawalEpoch"] == withdrawals[0]["consentEpoch"]


def test_delete_queues_account_erasure_without_personal_data_in_outbox(bridge_client):
    c=bridge_client; a=login(c)
    c.fail[0]=True
    assert c.delete("/v1/account",headers=authorization(a)).status_code == 200
    with database(c.settings) as db:
        rows=db.execute("SELECT kind,subject FROM voice_revocation_outbox").fetchall()
        assert {r["kind"] for r in rows} == {"delete","revoke"}
        assert all(a["token"] not in r["subject"] and "alice" not in r["subject"] for r in rows)
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        db.execute("UPDATE voice_revocation_outbox SET next_attempt_at=0")
    c.fail[0]=False; c.app.state.voice_bridge.retry_revocations()
    assert any(r.url.path.endswith("/delete") and json.loads(r.content)=={"accountID":a["user"]["id"]} for r in c.sent)


def test_voice_exchange_requires_current_legal_consent_and_source_session(bridge_client):
    c=bridge_client; a=login(c)
    with database(c.settings) as db:
        db.execute("UPDATE legal_consent_events SET document_hash=?",("0"*64,))
    assert c.post("/v1/voice/session",headers=authorization(a)).status_code == 428
    assert not c.sent


def test_fresh_voice_token_not_returned_when_account_logout_wins_exchange_race(bridge_client):
    c=bridge_client; a=login(c)
    def raced_exchange(*args):
        with database(c.settings) as db:
            db.execute("DELETE FROM sessions")
        return {"token":"v"*43}
    c.app.state.voice_bridge.exchange=raced_exchange
    assert c.post("/v1/voice/session",headers=authorization(a)).status_code == 401
    with database(c.settings) as db:
        assert {row[0] for row in db.execute("SELECT kind FROM voice_revocation_outbox")}=={"revoke"}


def test_real_withdrawal_clears_safety_data_but_ordinary_logout_preserves_it(real_voice_service):
    pair=real_voice_service;c=pair.account; a=login(c); b=login(c,"bob")
    voice_a=c.post("/v1/voice/session",headers=authorization(a)).json()
    c.post("/v1/voice/session",headers=authorization(b))
    target=b["user"]["id"]
    assert pair.voice.put("/v1/safety/blocks/"+target,headers=authorization(voice_a)).status_code==200
    assert c.post("/v1/auth/logout",headers=authorization(a)).status_code==200
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks WHERE user_id=?",(a["user"]["id"],)).fetchone()[0]==1
    fresh=login(c); fresh_voice=c.post("/v1/voice/session",headers=authorization(fresh)).json()
    assert pair.voice.get("/v1/safety",headers=authorization(fresh_voice)).status_code==200
    assert c.post("/v1/me/activity",headers=authorization(fresh),json={}).status_code==200
    assert c.delete("/v1/me/legal-consent",headers=authorization(fresh)).status_code==200
    c.app.state.voice_bridge.retry_revocations()
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks WHERE user_id=?",(fresh["user"]["id"],)).fetchone()[0]==0
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM account_activity_daily").fetchone()[0]==0
        assert db.execute("SELECT COUNT(*) FROM voice_revocation_outbox").fetchone()[0]==0


def test_delayed_privacy_withdrawal_cannot_clear_new_consent_or_new_safety_data(real_voice_service):
    from fastapi import HTTPException
    pair=real_voice_service;c=pair.account; a=login(c); b=login(c,"bob")
    old_voice=c.post("/v1/voice/session",headers=authorization(a)).json()
    c.post("/v1/voice/session",headers=authorization(b))
    target=b["user"]["id"]
    assert pair.voice.put("/v1/safety/blocks/"+target,headers=authorization(old_voice)).status_code==200
    bridge=c.app.state.voice_bridge; original=bridge.post
    def hold_withdrawal(path,payload):
        if path.endswith("/revoke"): raise HTTPException(503,"temporary fixture outage")
        return original(path,payload)
    bridge.post=hold_withdrawal
    assert c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code==200
    with database(c.settings) as db:
        pending=db.execute("SELECT consent_epoch FROM voice_revocation_outbox WHERE reason='withdrawal'").fetchone()
        assert pending and pending[0] > 0
    bridge.post=original
    fresh=login(c); fresh_voice=c.post("/v1/voice/session",headers=authorization(fresh))
    assert fresh_voice.status_code==200,fresh_voice.text
    fresh_headers=authorization(fresh_voice.json())
    # The new exchange carries a withdrawal watermark and clears the old block
    # before accepting new consent, even though its durable revoke is delayed.
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks WHERE user_id=?",(a["user"]["id"],)).fetchone()[0]==0
    assert pair.voice.put("/v1/safety/blocks/"+target,headers=fresh_headers).status_code==200
    with database(c.settings) as db: db.execute("UPDATE voice_revocation_outbox SET next_attempt_at=0")
    bridge.retry_revocations()
    assert pair.voice.get("/v1/me",headers=fresh_headers).status_code==200
    assert pair.voice.get("/v1/safety",headers=fresh_headers).status_code==200
    assert pair.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks WHERE user_id=?",(a["user"]["id"],)).fetchone()[0]==1
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM voice_revocation_outbox").fetchone()[0]==0


@pytest.mark.parametrize("updates", [{"voice_base_url":"http://furby.top"},
    {"voice_base_url":"https://evil.test"},{"voice_bridge_secret":"a"*64},{"qa_gifts_enabled":True}])
def test_bridge_requires_fixed_tls_endpoint_and_independent_entropy(bridge_client,updates):
    with pytest.raises(RuntimeError):
        create_app(replace(bridge_client.settings,**updates))


@pytest.fixture
def real_voice_service(bridge_client,tmp_path):
    """Two actual ASGI apps + SQLite stores; only Apple and SFU are fixtures."""
    import importlib.util
    from pathlib import Path
    import sys
    from types import SimpleNamespace
    app_path=Path(__file__).resolve().parents[2]/"experiments/livekit/backend/app"
    package="kiki_voice_integration_app"
    if package not in sys.modules:
        spec=importlib.util.spec_from_file_location(package, app_path/"__init__.py",submodule_search_locations=[str(app_path)])
        module=importlib.util.module_from_spec(spec);sys.modules[package]=module;spec.loader.exec_module(module)
    main=__import__(package+".main",fromlist=["Settings","create_app"])
    class Media:
        def __init__(self,settings): self.rooms={}; self.settings=settings
        participant_token=main.LiveKitGateway.participant_token
        async def create_room(self,room): self.rooms[room]=set()
        async def get_participants(self,room):
            return {u:SimpleNamespace(identity=u,tracks=[]) for u in self.rooms.get(room,set())}
        async def update_permissions(self,*args,**kwargs): pass
        async def broadcast_chat_sync(self,*args,**kwargs): pass
        async def list_rooms(self): return {k:len(v) for k,v in self.rooms.items()}
        async def close(self): pass
        async def participants(self,room): return self.rooms.get(room,set())
        async def delete_room(self,room): self.rooms.pop(room,None)
        async def remove_participant(self,room,user): self.rooms.get(room,set()).discard(user)
    legal=Path(__file__).resolve().parents[1]/"app/legal_documents.json"
    settings=main.Settings(db_path=str(tmp_path/"real-voice.sqlite3"),legal_path=str(legal),
        api_key="separate-media-key",api_secret="media-secret-"+"a"*48,auth_mode="account",
        account_bridge_secret=SECRET,rate_limit_enabled=False)
    app=main.create_app(settings,Media(settings))
    with TestClient(app) as voice:
        bridge_client.app.state.voice_bridge.http.close()
        captured=[]
        def send(request):
            captured.append(request)
            response=voice.request(request.method,str(request.url),headers=dict(request.headers),content=request.content)
            return httpx.Response(response.status_code,headers=response.headers,content=response.content)
        bridge_client.app.state.voice_bridge.http=httpx.Client(transport=httpx.MockTransport(send))
        yield SimpleNamespace(account=bridge_client,voice=voice,app=app,captured=captured)


def test_real_cross_service_exchange_scope_nonce_and_old_logout_isolation(real_voice_service):
    pair=real_voice_service;c=pair.account; a=login(c)
    first=c.post("/v1/voice/session",headers=authorization(a))
    assert first.status_code==200,first.text
    voice_a=first.json();voice_headers=authorization(voice_a)
    assert pair.voice.get("/v1/me",headers=authorization(a)).status_code==401
    assert c.get("/v1/me",headers=voice_headers).status_code==401
    assert pair.voice.get("/v1/me",headers=voice_headers).json()["id"]==a["user"]["id"]
    request=pair.captured[-1]
    assert pair.voice.post(request.url.path,headers=dict(request.headers),content=request.content).status_code==401
    b=login(c);voice_b=c.post("/v1/voice/session",headers=authorization(b)).json()
    assert voice_b["user"]["id"]==voice_a["user"]["id"] and voice_b["token"]!=voice_a["token"]
    assert c.post("/v1/auth/logout",headers=authorization(a)).status_code==200
    assert pair.voice.get("/v1/me",headers=voice_headers).status_code==401
    assert pair.voice.get("/v1/me",headers=authorization(voice_b)).status_code==200
    assert c.post("/v1/voice/session",headers=authorization(b)).json()["token"]==voice_b["token"]


def test_real_cross_service_withdrawal_and_deletion_erase_voice_profile(real_voice_service):
    pair=real_voice_service;c=pair.account; a=login(c)
    voice_a=c.post("/v1/voice/session",headers=authorization(a)).json()
    assert c.delete("/v1/me/legal-consent",headers=authorization(a)).status_code==200
    assert pair.voice.get("/v1/me",headers=authorization(voice_a)).status_code==401
    fresh=login(c);voice_b=c.post("/v1/voice/session",headers=authorization(fresh)).json()
    assert c.delete("/v1/account",headers=authorization(fresh)).status_code==200
    assert pair.voice.get("/v1/me",headers=authorization(voice_b)).status_code==401
    row=pair.app.state.db.execute("SELECT * FROM users WHERE id=?",(fresh["user"]["id"],)).fetchone()
    assert row["deleted"]==1 and row["name"]=="已注销" and row["bio"]=="" and row["avatar_url"] is None


def test_real_account_logout_closes_authorized_voice_room(real_voice_service):
    pair=real_voice_service;c=pair.account;a=login(c)
    voice=c.post("/v1/voice/session",headers=authorization(a)).json()
    room=pair.voice.post("/v1/rooms",headers=authorization(voice),json={
        "title":"正式桥接房间","category":"闲聊","isLive":False,"theme":0})
    assert room.status_code==200,room.text
    room_id=room.json()["id"]
    token=pair.voice.post(f"/v1/rooms/{room_id}/token",headers=authorization(voice))
    assert token.status_code==200,token.text
    pair.app.state.rtc.rooms[room_id].add(voice["user"]["id"])
    assert c.post("/v1/auth/logout",headers=authorization(a)).status_code==200
    assert pair.voice.get("/v1/me",headers=authorization(voice)).status_code==401
    row=pair.app.state.db.execute("SELECT status FROM rooms WHERE id=?",(room_id,)).fetchone()
    assert row["status"]=="closed" and room_id not in pair.app.state.rtc.rooms


def test_voice_renewal_reuses_daily_apple_grant_validation(bridge_client):
    c=bridge_client; value=login(c)
    with database(c.settings) as db:
        db.execute("UPDATE apple_credentials SET validated_at=?",(int(time.time())-86401,))
    c.fake_apple.refresh_revoked=True
    assert c.post("/v1/voice/session",headers=authorization(value)).status_code==401
    assert not c.sent
    with database(c.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]==0
        assert db.execute("SELECT kind,reason FROM voice_revocation_outbox").fetchone()[:]==("revoke","logout")
