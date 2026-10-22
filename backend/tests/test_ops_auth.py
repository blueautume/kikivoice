from dataclasses import replace
import hashlib
import importlib.util
import json
from pathlib import Path
import secrets
import struct
import subprocess
import sys
import time
from types import SimpleNamespace

import cbor2
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
import httpx
import pytest

from app.main import Settings,create_app,database
from app.ops_auth import encode,decode,change_grant,signed_ops_headers
from conftest import apple_settings,apple_payload
from test_api import authorization

SECRET="ops-exclusive-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


@pytest.fixture
def ops(tmp_path,fake_apple):
    settings=apple_settings(Settings(str(tmp_path/"ops.sqlite3"),123,"legacy-tencent-"+"a"*50,False,
        admin_auth_mode="passkey",ops_bridge_secret=SECRET))
    app=create_app(settings)
    with TestClient(app) as client:
        client.settings,client.fake_apple=settings,fake_apple
        yield SimpleNamespace(client=client,app=app,settings=settings)


class Authenticator:
    def __init__(self):
        self.key=ec.generate_private_key(ec.SECP256R1())
        self.credential_id=secrets.token_bytes(32)
        self.user_handle=None
        self.counter=0

    def client_data(self,options,kind,*,origin="https://kiki.group",challenge=None,cross_origin=False):
        return json.dumps({"type":"webauthn."+kind,"challenge":challenge or options["publicKey"]["challenge"],
            "origin":origin,"crossOrigin":cross_origin},separators=(",",":")).encode()

    def registration(self,options,*,flags=0x45,rp_id="kiki.group",**changes):
        self.user_handle=decode(options["publicKey"]["user"]["id"])
        numbers=self.key.public_key().public_numbers()
        cose={1:2,3:-7,-1:1,-2:numbers.x.to_bytes(32,"big"),-3:numbers.y.to_bytes(32,"big")}
        auth_data=hashlib.sha256(rp_id.encode()).digest()+bytes([flags])+struct.pack(">I",self.counter)
        auth_data+=bytes(16)+struct.pack(">H",len(self.credential_id))+self.credential_id+cbor2.dumps(cose)
        attestation=cbor2.dumps({"fmt":"none","attStmt":{},"authData":auth_data})
        return {"id":encode(self.credential_id),"rawId":encode(self.credential_id),"type":"public-key",
                "response":{"clientDataJSON":encode(self.client_data(options,"create",**changes)),
                            "attestationObject":encode(attestation)},"clientExtensionResults":{}}

    def assertion(self,options,*,flags=0x05,rp_id="kiki.group",user_handle=None,counter=None,**changes):
        self.counter=self.counter+1 if counter is None else counter
        client_data=self.client_data(options,"get",**changes)
        auth_data=hashlib.sha256(rp_id.encode()).digest()+bytes([flags])+struct.pack(">I",self.counter)
        signature=self.key.sign(auth_data+hashlib.sha256(client_data).digest(),ec.ECDSA(hashes.SHA256()))
        return {"id":encode(self.credential_id),"rawId":encode(self.credential_id),"type":"public-key",
                "response":{"clientDataJSON":encode(client_data),"authenticatorData":encode(auth_data),
                            "signature":encode(signature),"userHandle":encode(user_handle or self.user_handle)},
                "clientExtensionResults":{}}


def options(ops,kind):
    response=ops.client.post(f"/admin/v2/auth/{kind}/options",json={})
    assert response.status_code==200,response.text
    return response.json()


def verify(ops,kind,option,credential):
    return ops.client.post(f"/admin/v2/auth/{kind}/verify",json={"transactionID":option["transactionID"],"credential":credential})


def register(ops,name=None,authenticator=None):
    auth=authenticator or Authenticator();option=options(ops,"registration")
    response=verify(ops,"registration",option,auth.registration(option))
    assert response.status_code==200,response.text
    session=response.json()
    if name is not None:
        response=ops.client.patch("/admin/v2/me",headers=authorization(session),json={"name":name})
        assert response.status_code==200,response.text
        session["account"]=response.json()["account"]
    return session,auth


def grant(ops,session,service,action="grant",name=None):
    return change_grant(ops.settings,database,account_id=session["account"]["id"],
        name=session["account"]["name"] if name is None else name,service=service,action=action,actor="local:test")


def test_real_registration_usernameless_auth_and_opaque_ops_only_session(ops):
    option=options(ops,"registration");key=Authenticator();credential=key.registration(option)
    assert option["publicKey"]["authenticatorSelection"]["residentKey"]=="required"
    assert option["publicKey"]["authenticatorSelection"]["userVerification"]=="required"
    assert option["publicKey"]["attestation"]=="none" and option["publicKey"]["pubKeyCredParams"]==[{"type":"public-key","alg":-7}]
    result=verify(ops,"registration",option,credential)
    assert result.status_code==200,result.text
    session=result.json();account=session["account"]
    assert session["serviceID"]=="ops-identity" and session["role"]=="member" and len(session["token"])==43
    assert account["id"].startswith("ops_") and account["name"] is None and account["needsName"]
    assert account["permissions"]=={"account":False,"voice":False,"community":False}
    assert 28790<=session["expiresAt"]-int(time.time())<=28800
    auth_options=options(ops,"authentication")
    assert not auth_options["publicKey"].get("allowCredentials")
    signed=verify(ops,"authentication",auth_options,key.assertion(auth_options))
    assert signed.status_code==200 and signed.json()["account"]["id"]==account["id"]
    assert ops.client.get("/v1/me",headers=authorization(session)).status_code==401
    assert ops.client.get("/admin/v1/dashboard",headers=authorization(session)).status_code==404
    with database(ops.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]==0
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]==0
        assert session["token"] not in str(db.execute("SELECT * FROM ops_sessions").fetchall())


def test_registration_and_auth_challenges_are_one_use_even_after_crypto_failure(ops):
    option=options(ops,"registration");key=Authenticator();credential=key.registration(option,flags=0x41)
    assert verify(ops,"registration",option,credential).status_code==401
    assert verify(ops,"registration",option,key.registration(option)).status_code==409
    session,key=register(ops)
    option=options(ops,"authentication");credential=key.assertion(option)
    assert verify(ops,"authentication",option,credential).status_code==200
    assert verify(ops,"authentication",option,credential).status_code==409


@pytest.mark.parametrize("changes",[{"origin":"https://evil.test"},{"rp_id":"evil.test"},
    {"challenge":encode(b"wrong-challenge")},{"cross_origin":True},{"flags":0x41},{"flags":0x44}])
def test_registration_rejects_wrong_origin_rp_challenge_and_missing_up_uv(ops,changes):
    option=options(ops,"registration");key=Authenticator()
    response=verify(ops,"registration",option,key.registration(option,**changes))
    assert response.status_code==401
    with database(ops.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM ops_accounts").fetchone()[0]==0


@pytest.mark.parametrize("changes",[{"origin":"https://evil.test"},{"rp_id":"evil.test"},
    {"challenge":encode(b"wrong-challenge")},{"cross_origin":True},{"flags":0x01},
    {"user_handle":b"different-user"}])
def test_authentication_rejects_wrong_binding_and_missing_uv(ops,changes):
    _,key=register(ops);option=options(ops,"authentication")
    assert verify(ops,"authentication",option,key.assertion(option,**changes)).status_code==401


def test_forged_signature_duplicate_credential_and_counter_rollback_fail(ops):
    _,key=register(ops);option=options(ops,"authentication")
    credential=key.assertion(option);credential["response"]["signature"]=encode(b"forged-signature")
    assert verify(ops,"authentication",option,credential).status_code==401
    option=options(ops,"authentication")
    assert verify(ops,"authentication",option,key.assertion(option,counter=2)).status_code==200
    option=options(ops,"authentication")
    assert verify(ops,"authentication",option,key.assertion(option,counter=1)).status_code==401
    option=options(ops,"registration")
    assert verify(ops,"registration",option,key.registration(option)).status_code==409


def test_same_names_never_share_grants_and_mutable_name_preserves_id_only(ops):
    a,_=register(ops,"运维同名");b,_=register(ops,"运维同名")
    assert a["account"]["id"]!=b["account"]["id"]
    for session in (a,b):
        assert ops.client.get("/admin/v2/services/account/dashboard",headers=authorization(session)).status_code==403
        assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session)).status_code==403
    grant(ops,b,"account")
    assert ops.client.get("/admin/v2/services/account/dashboard",headers=authorization(b)).status_code==200
    assert ops.client.get("/admin/v2/services/account/dashboard",headers=authorization(a)).status_code==403
    assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(b)).status_code==403
    renamed=ops.client.patch("/admin/v2/me",headers=authorization(b),json={"name":" 更名运维 "}).json()["account"]
    assert renamed["id"]==b["account"]["id"] and renamed["name"]=="更名运维" and renamed["permissions"]["account"]
    with pytest.raises(ValueError):grant(ops,b,"voice")
    b["account"]=renamed;grant(ops,b,"account",action="revoke")
    assert ops.client.get("/admin/v2/services/account/dashboard",headers=authorization(b)).status_code==403
    with database(ops.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM ops_audit WHERE action='name'").fetchone()[0]==3


def test_name_validation_server_only_acl_and_stale_expired_sessions(ops):
    session,_=register(ops)
    for name in (""," ","x"*33,"a\nname","a\u200bname"):
        assert ops.client.patch("/admin/v2/me",headers=authorization(session),json={"name":name}).status_code==422
    name=ops.client.patch("/admin/v2/me",headers=authorization(session),json={"name":" e\u0301 "}).json()["account"]
    assert name["name"]=="é" and name["id"]==session["account"]["id"]
    assert ops.client.patch("/admin/v2/me",headers=authorization(session),json={"name":"管理员","permissions":{"account":True}}).status_code==422
    for path in ("/admin/v2/grant","/admin/v2/accounts/x/grant"):
        assert ops.client.post(path,headers=authorization(session),json={"service":"account"}).status_code==404
    with database(ops.settings) as db:db.execute("UPDATE ops_sessions SET expires_at=0")
    assert ops.client.get("/admin/v2/me",headers=authorization(session)).status_code==401


def test_apple_and_legacy_admin_bearers_cannot_enter_ops_and_logout_revokes(ops):
    account=ops.client.post("/v1/auth/apple",json=apple_payload(ops.client)).json()
    assert ops.client.get("/admin/v2/me",headers=authorization(account)).status_code==401
    session,_=register(ops,"验收")
    assert ops.client.delete("/admin/v2/auth/session",headers=authorization(session)).json()=={"revoked":True}
    assert ops.client.get("/admin/v2/me",headers=authorization(session)).status_code==401
    assert ops.client.post("/admin/v1/auth/session",json={"passphrase":"old-password-value"}).status_code==404


def test_voice_gateway_is_fixed_signed_and_rechecks_revocation_after_request(ops):
    session,_=register(ops,"网关验收");grant(ops,session,"voice")
    sent=[]
    def send(request):
        sent.append(request)
        assert str(request.url)=="https://furby.top/internal/admin/v2/dashboard"
        assert request.content==b"{}" and "authorization" not in request.headers
        expected=signed_ops_headers(SECRET,timestamp=int(request.headers["X-Kiki-Ops-Timestamp"]),nonce=request.headers["X-Kiki-Ops-Nonce"])
        assert request.headers["X-Kiki-Ops-Signature"]==expected["X-Kiki-Ops-Signature"]
        return httpx.Response(200,json={"schemaVersion":1,"service":{"id":"voice-lab","host":"furby.top","readOnly":True},
            "accountService":{"connected":False},"operations":{}})
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(send))
    assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session)).status_code==200
    def revoked(request):
        grant(ops,session,"voice",action="revoke")
        return send(request)
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(revoked))
    assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session)).status_code==403
    assert len(sent)==2
    assert ops.client.get("/admin/v2/me",headers=authorization(session)).json()["account"]["permissions"]["voice"] is False


@pytest.mark.parametrize("reply",[httpx.Response(302,headers={"Location":"https://evil.test"}),
    httpx.Response(503),httpx.Response(200,json={"schemaVersion":1,"service":{"id":"account-service"}})])
def test_voice_errors_never_redirect_or_fabricate_metrics(ops,reply):
    session,_=register(ops,"网关验收");grant(ops,session,"voice")
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(lambda request:reply))
    assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session)).status_code==503


def test_origin_payload_limits_challenge_expiry_and_passkey_limits_stay_on(ops):
    assert ops.client.post("/admin/v2/auth/registration/options",json={},headers={"Origin":"https://evil.test"}).status_code==403
    assert ops.client.post("/admin/v2/auth/registration/options",json={"scope":"account"}).status_code==422
    assert ops.client.post("/admin/v2/auth/registration/verify",content=b"x"*32769).status_code==413
    option=options(ops,"registration");key=Authenticator()
    with database(ops.settings) as db:db.execute("UPDATE ops_challenges SET expires_at=0")
    assert verify(ops,"registration",option,key.registration(option)).status_code==409
    for _ in range(9):assert ops.client.post("/admin/v2/auth/registration/options",json={}).status_code==200
    assert ops.client.post("/admin/v2/auth/registration/options",json={}).status_code==429


def test_cli_exact_name_delete_only_ops_namespace_and_keeps_audit(ops):
    session,_=register(ops,"待删除验收");grant(ops,session,"account")
    account=ops.client.post("/v1/auth/apple",json=apple_payload(ops.client)).json()
    with pytest.raises(ValueError):grant(ops,session,"account",action="delete",name="名字不符")
    grant(ops,session,None,action="delete")
    assert ops.client.get("/admin/v2/me",headers=authorization(session)).status_code==401
    assert ops.client.get("/v1/me",headers=authorization(account)).status_code==200
    with database(ops.settings) as db:
        for table in ("ops_accounts","ops_credentials","ops_grants","ops_sessions"):
            assert db.execute("SELECT COUNT(*) FROM "+table).fetchone()[0]==0
        assert db.execute("SELECT action FROM ops_audit ORDER BY event_id DESC LIMIT 1").fetchone()[0]=="delete"


def test_configuration_requires_separate_high_entropy_ops_key(ops):
    for changes in ({"admin_auth_mode":"invalid"},{"ops_bridge_secret":"a"*64},
                    {"ops_bridge_secret":ops.settings.secret_key}):
        with pytest.raises(RuntimeError):create_app(replace(ops.settings,**changes))


def test_synced_passkey_zero_counter_and_backup_flags_are_supported(ops):
    key=Authenticator();option=options(ops,"registration")
    result=verify(ops,"registration",option,key.registration(option,flags=0x5d))
    assert result.status_code==200,result.text
    for _ in range(2):
        option=options(ops,"authentication")
        assert verify(ops,"authentication",option,key.assertion(option,flags=0x1d,counter=0)).status_code==200


def test_real_signed_account_to_voice_gateway_replay_and_acl_isolation(ops,tmp_path):
    package="kiki_voice_ops_integration_app"
    app_path=Path(__file__).resolve().parents[2]/"experiments/livekit/backend/app"
    if package not in sys.modules:
        spec=importlib.util.spec_from_file_location(package,app_path/"__init__.py",submodule_search_locations=[str(app_path)])
        module=importlib.util.module_from_spec(spec);sys.modules[package]=module;spec.loader.exec_module(module)
    voice_main=__import__(package+".main",fromlist=["Settings","create_app"])
    class Media:
        async def list_rooms(self):return {}
        async def close(self):pass
    settings=voice_main.Settings(db_path=str(tmp_path/"voice-ops.sqlite3"),
        legal_path=str(app_path.parents[1]/"shared/legal_documents.json"),
        api_key="independent-media-key",api_secret="independent-media-secret-"+"a"*48,
        access_code="unused-lab-compatibility-invite",auth_mode="account",
        account_bridge_secret="business-bridge-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        admin_auth_mode="passkey",ops_bridge_secret=SECRET,rate_limit_enabled=False)
    app=voice_main.create_app(settings,Media())
    with TestClient(app) as voice:
        captured=[]
        def send(request):
            captured.append(request)
            response=voice.request(request.method,str(request.url),content=request.content,headers=dict(request.headers))
            return httpx.Response(response.status_code,content=response.content,headers=response.headers)
        ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(send))
        session,_=register(ops,"双服务验收")
        assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session)).status_code==403
        assert not captured
        grant(ops,session,"voice")
        result=ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session))
        assert result.status_code==200,result.text
        data=result.json()
        assert data["service"]["id"]=="voice-lab" and data["service"]["host"]=="furby.top"
        assert data["accountService"]["connected"] is False
        assert ops.client.get("/admin/v2/services/account/dashboard",headers=authorization(session)).status_code==403
        request=captured[-1]
        assert voice.request(request.method,str(request.url),content=request.content,headers=dict(request.headers)).status_code==401
        assert voice.get("/admin/v1/dashboard",headers=authorization(session)).status_code==404
        grant(ops,session,"voice",action="revoke")
        assert ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session)).status_code==403
        assert len(captured)==1


def test_server_cli_requires_exact_identity_and_never_emits_auth_material(ops):
    import os
    session,_=register(ops,"命令行验收")
    environment={"PATH":os.environ["PATH"],"DATABASE_PATH":ops.settings.db_path,
                 "PYTHONPATH":str(Path(__file__).resolve().parents[1])}
    def invoke(*arguments):
        return subprocess.run([sys.executable,"-m","app.ops_auth",*arguments],env=environment,
                              capture_output=True,text=True,timeout=10)
    listing=invoke("list")
    assert listing.returncode==0 and session["token"] not in listing.stdout
    assert json.loads(listing.stdout)[0]["id"]==session["account"]["id"]
    bad=invoke("grant","--account-id",session["account"]["id"],"--name","不同姓名","--service","account")
    assert bad.returncode!=0
    good=invoke("grant","--account-id",session["account"]["id"],"--name","命令行验收","--service","account")
    assert good.returncode==0
    assert ops.client.get("/admin/v2/services/account/dashboard",headers=authorization(session)).status_code==200
    community=invoke("grant","--account-id",session["account"]["id"],"--name","命令行验收","--service","community")
    assert community.returncode==0
    assert ops.client.get("/admin/v2/me",headers=authorization(session)).json()["account"]["permissions"]=={
        "account":True,"voice":False,"community":True}
    deleted=invoke("delete","--account-id",session["account"]["id"],"--name","命令行验收")
    assert deleted.returncode==0
    assert ops.client.get("/admin/v2/me",headers=authorization(session)).status_code==401


def test_voice_dashboard_stops_streaming_before_buffering_oversized_body(ops):
    session,_=register(ops,"字节限制验收");grant(ops,session,"voice")
    class LargeBody(httpx.AsyncByteStream):
        yielded=0
        closed=False
        async def __aiter__(self):
            for _ in range(4096):
                self.yielded+=1
                yield b"x"*8192
        async def aclose(self):self.closed=True
    body=LargeBody()
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(
        lambda request:httpx.Response(200,stream=body)))
    response=ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session))
    assert response.status_code==503 and "xxx" not in response.text
    assert body.yielded==257 and body.closed


def test_voice_dashboard_total_deadline_bounds_slow_stream_and_closes_it(ops):
    import asyncio
    session,_=register(ops,"时间限制验收");grant(ops,session,"voice")
    class SlowBody(httpx.AsyncByteStream):
        closed=False
        async def __aiter__(self):
            yield b'{"schemaVersion":1,'
            await asyncio.sleep(4)
            yield b'"service":{"id":"voice-lab","host":"furby.top","readOnly":true},"accountService":{"connected":false}}'
        async def aclose(self):self.closed=True
    body=SlowBody()
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(
        lambda request:httpx.Response(200,stream=body)))
    started=time.monotonic()
    response=ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session))
    assert response.status_code==503 and time.monotonic()-started<4
    assert body.closed


@pytest.mark.parametrize("change",[{"service":[]},{"service":{"id":"voice-lab","host":"kiki.group","readOnly":True}},
    {"service":{"id":"voice-lab","host":"furby.top","readOnly":False}},
    {"accountService":{"connected":True}},{"accountService":[]}])
def test_voice_dashboard_rejects_malformed_or_misidentified_source(ops,change):
    session,_=register(ops,"来源验收");grant(ops,session,"voice")
    payload={"schemaVersion":1,"service":{"id":"voice-lab","host":"furby.top","readOnly":True},
             "accountService":{"connected":False},**change}
    ops.app.state.ops.http=httpx.AsyncClient(transport=httpx.MockTransport(
        lambda request:httpx.Response(200,json=payload)))
    response=ops.client.get("/admin/v2/services/voice/dashboard",headers=authorization(session))
    assert response.status_code==503 and response.json()=={"detail":"语聊服务运维数据暂时不可用"}
