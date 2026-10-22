"""Community capability boundaries, real foreground metrics and public text policy."""
from dataclasses import replace
from datetime import datetime, timedelta
import hashlib
import hmac
import json
import importlib.util
from pathlib import Path
import sqlite3
import sys
import time
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient
import httpx
import pytest

from app import activity, maintenance, ops_auth, voice_bridge
from app.community_content import PublicTextPolicy
from app.main import create_app, database
from conftest import apple_payload
from test_api import client, authorization, login
from test_ops_auth import ops, register, grant, SECRET


def mock_moderation(ops, send):
    ops.app.state.ops.http = httpx.AsyncClient(transport=httpx.MockTransport(send))


def test_community_is_independent_and_forbidden_to_viewers_and_apple_accounts(ops):
    community, _ = register(ops, "社区管理员")
    viewer, _ = register(ops, "看板观察员")
    grant(ops, viewer, "account"); grant(ops, viewer, "voice")
    business = ops.client.post("/v1/auth/apple", json=apple_payload(ops.client)).json()
    paths = ("/admin/v2/services/voice/moderation/query", "/admin/v2/services/voice/moderation/action")
    action = {"requestID": "86c3cc84-6d62-407c-ac87-cdb4c2874a41", "reportID": "report-1", "action": "warn", "note": "请遵守社区规则"}
    sent = []
    def send(request):
        sent.append(request)
        value = json.loads(request.content)
        if request.url.path.endswith("query"):
            return httpx.Response(200, json={"schemaVersion": 1, "reports": [], "retentionDays": 30})
        return httpx.Response(200, json={"ok": True, **{k:value[k] for k in ("requestID", "reportID", "action")}})
    mock_moderation(ops, send)
    for session, status in ((community, 403), (viewer, 403), (business, 401)):
        for path, payload in zip(paths, ({}, action)):
            assert ops.client.post(path, headers=authorization(session), json=payload).status_code == status
    assert not sent
    grant(ops, community, "community")
    permissions = ops.client.get("/admin/v2/me", headers=authorization(community)).json()["account"]["permissions"]
    assert permissions == {"account": False, "voice": False, "community": True}
    for path, payload in zip(paths, ({}, action)):
        assert ops.client.post(path, headers=authorization(community), json=payload).status_code == 200
    assert ops.client.get("/admin/v2/services/account/dashboard", headers=authorization(community)).status_code == 403
    assert ops.client.get("/admin/v2/services/voice/dashboard", headers=authorization(community)).status_code == 403
    grant(ops, community, "community", action="revoke")
    assert ops.client.post(paths[0], headers=authorization(community), json={}).status_code == 403
    assert len(sent) == 2


def test_moderation_gateway_fixed_route_actor_and_signed_exact_body_path_method(ops):
    session, _ = register(ops, "签名验收"); grant(ops, session, "community")
    captured = []
    def send(request):
        captured.append(request)
        payload = json.loads(request.content)
        assert payload["opsActorID"] == session["account"]["id"]
        assert str(request.url) == "https://furby.top/internal/admin/v2/moderation/action"
        assert request.method == "POST" and "authorization" not in request.headers
        message = "\n".join(("account-voice-ops-v2", "POST", request.url.path,
                             request.headers["X-Kiki-Ops-Timestamp"], request.headers["X-Kiki-Ops-Nonce"],
                             hashlib.sha256(request.content).hexdigest())).encode()
        assert hmac.compare_digest(request.headers["X-Kiki-Ops-Signature"],
                                   hmac.new(SECRET.encode(), message, hashlib.sha256).hexdigest())
        same = {"timestamp": request.headers["X-Kiki-Ops-Timestamp"], "nonce": request.headers["X-Kiki-Ops-Nonce"]}
        for change in ({"path": "/internal/admin/v2/dashboard"}, {"body": b"{}"}, {"method": "GET"}):
            arguments = {"path": request.url.path, "body": request.content, **same, **change}
            assert ops_auth.signed_ops_headers(SECRET, **arguments)["X-Kiki-Ops-Signature"] != request.headers["X-Kiki-Ops-Signature"]
        return httpx.Response(200, json={"ok": True, **{k:payload[k] for k in ("requestID", "reportID", "action")}})
    mock_moderation(ops, send)
    payload = {"requestID": "86C3CC84-6D62-407C-AC87-CDB4C2874A41", "reportID": "report_1", "action": "ban_user", "durationSeconds": 600, "note": "持续骚扰"}
    path = "/admin/v2/services/voice/moderation/action"
    assert ops.client.post(path, headers=authorization(session), json=payload).status_code == 200
    for extra in ({"opsActorID": "ops_forged"}, {"url": "https://evil.test"}, {"targetUserID": "another-user"}):
        assert ops.client.post(path, headers=authorization(session), json={**payload, **extra}).status_code == 422
    assert len(captured) == 1


@pytest.mark.parametrize("change", [{"durationSeconds": None}, {"durationSeconds": 59},
                                     {"durationSeconds": 2592001}, {"durationSeconds": True},
                                     {"action": "warn", "durationSeconds": 600}, {"note": "bad\u200bnote"}])
def test_moderation_duration_and_notes_are_validated_before_forwarding(ops, change):
    session, _ = register(ops, "参数验收"); grant(ops, session, "community")
    mock_moderation(ops, lambda request: pytest.fail("Invalid moderation request was forwarded"))
    payload = {"requestID": "86c3cc84-6d62-407c-ac87-cdb4c2874a41", "reportID": "report-1", "action": "mute_chat", "durationSeconds": 600, "note": "请遵守规则"}
    assert ops.client.post("/admin/v2/services/voice/moderation/action", headers=authorization(session),
                           json={**payload, **change}).status_code == 422


def test_community_revocation_is_rechecked_after_remote_response(ops):
    session, _ = register(ops, "撤权验收"); grant(ops, session, "community")
    def send(request):
        grant(ops, session, "community", action="revoke")
        return httpx.Response(200, json={"schemaVersion": 1, "reports": [{"id": "private-report"}]})
    mock_moderation(ops, send)
    response = ops.client.post("/admin/v2/services/voice/moderation/query", headers=authorization(session), json={})
    assert response.status_code == 403 and "private-report" not in response.text


@pytest.mark.parametrize("response", [httpx.Response(302, headers={"Location": "https://evil.test"}),
    httpx.Response(200, json=[]), httpx.Response(200, json={"schemaVersion": 1, "reports": [{}]*51}),
    httpx.Response(503, json={"detail": "/private/server/path"})])
def test_community_upstream_failures_are_bounded_and_private(ops, response):
    session, _ = register(ops, "来源验收"); grant(ops, session, "community")
    mock_moderation(ops, lambda request: response)
    result = ops.client.post("/admin/v2/services/voice/moderation/query", headers=authorization(session), json={})
    assert result.status_code == 503 and "/private/" not in result.text


def test_existing_acl_schema_upgrade_preserves_grants_and_cascade(tmp_path):
    db = sqlite3.connect(tmp_path/"old.sqlite3")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(ops_auth.SCHEMA.replace("'account','voice','community'", "'account','voice'"))
    now = int(time.time())
    db.execute("INSERT INTO ops_accounts VALUES(?,?,?,?,NULL)", ("ops_old", b"old-handle", "原有观察员", now))
    db.execute("INSERT INTO ops_grants VALUES(?,?,?)", ("ops_old", "voice", now))
    db.commit()
    ops_auth.initialize_database(db)
    assert db.execute("SELECT service FROM ops_grants").fetchall() == [("voice",)]
    db.execute("INSERT INTO ops_grants VALUES(?,?,?)", ("ops_old", "community", now))
    ops_auth.initialize_database(db)
    assert db.execute("SELECT COUNT(*) FROM ops_grants").fetchone()[0] == 2
    db.execute("DELETE FROM ops_accounts")
    assert db.execute("SELECT COUNT(*) FROM ops_grants").fetchone()[0] == 0
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []
    db.close()


def test_existing_outbox_upgrade_preserves_pending_retry_without_duplicate_withdrawal(tmp_path):
    db=sqlite3.connect(tmp_path/"old-outbox.sqlite3"); db.row_factory=sqlite3.Row
    db.execute("CREATE TABLE sessions(token_hash TEXT PRIMARY KEY,account_id TEXT NOT NULL)")
    db.executescript(voice_bridge.SCHEMA.replace("  reason TEXT NOT NULL DEFAULT 'logout',\n", "").replace("  consent_epoch INTEGER,\n", ""))
    db.execute("INSERT INTO sessions VALUES('source','account')")
    db.execute("INSERT INTO voice_revocation_outbox(kind,subject,created_at,attempts,next_attempt_at) VALUES('revoke','source',1,4,99)")
    db.commit(); voice_bridge.initialize_database(db)
    row=db.execute("SELECT * FROM voice_revocation_outbox").fetchone()
    assert row["reason"]=="logout" and row["attempts"]==4 and row["next_attempt_at"]==99
    from types import SimpleNamespace
    bridge=voice_bridge.VoiceBridge(SimpleNamespace(voice_bridge_enabled=True),None)
    try:
        bridge.queue_authorization_withdrawal(db,"account",42)
        db.execute("DELETE FROM sessions WHERE token_hash='source'")
        rows=db.execute("SELECT * FROM voice_revocation_outbox").fetchall()
        assert len(rows)==1 and rows[0]["reason"]=="withdrawal" and rows[0]["next_attempt_at"]==0
        assert rows[0]["attempts"]==4
        assert rows[0]["consent_epoch"]==42
    finally:
        bridge.close(); db.close()


def test_real_community_gateway_to_voice_checks_body_path_nonce_and_scope(ops, tmp_path):
    package = "kiki_voice_ops_integration_app"
    app_path = Path(__file__).resolve().parents[2]/"experiments/livekit/backend/app"
    if package not in sys.modules:
        spec = importlib.util.spec_from_file_location(package, app_path/"__init__.py", submodule_search_locations=[str(app_path)])
        module = importlib.util.module_from_spec(spec); sys.modules[package] = module; spec.loader.exec_module(module)
    voice_main = __import__(package+".main", fromlist=["Settings", "create_app"])
    class Media:
        async def list_rooms(self): return {}
        async def close(self): pass
    settings = voice_main.Settings(db_path=str(tmp_path/"voice-community.sqlite3"),
        legal_path=str(app_path.parents[1]/"shared/legal_documents.json"),
        api_key="independent-media-key", api_secret="independent-media-secret-"+"a"*48,
        access_code="unused-lab-compatibility-invite", auth_mode="account",
        account_bridge_secret="business-bridge-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        admin_auth_mode="passkey", ops_bridge_secret=SECRET, rate_limit_enabled=False)
    with TestClient(voice_main.create_app(settings, Media())) as voice:
        captured = []
        def send(request):
            captured.append(request)
            response = voice.request(request.method, str(request.url), content=request.content, headers=dict(request.headers))
            return httpx.Response(response.status_code, content=response.content, headers=response.headers)
        mock_moderation(ops, send)
        session, _ = register(ops, "真实社区边界验收"); grant(ops, session, "community")
        path = "/admin/v2/services/voice/moderation/query"
        response = ops.client.post(path, headers=authorization(session), json={})
        assert response.status_code == 200 and response.json()["reports"] == []
        original = captured[-1]
        headers = dict(original.headers)
        assert voice.post(str(original.url), content=original.content, headers=headers).status_code == 401
        changed = {**json.loads(original.content), "status": "all"}
        assert voice.post(str(original.url), content=json.dumps(changed).encode(), headers=headers).status_code == 401
        assert voice.post("/internal/admin/v2/dashboard", content=b"{}", headers=headers).status_code == 401
        # Even a freshly valid signature cannot reuse a consumed nonce at a
        # different operations endpoint; all three paths share the replay pool.
        dashboard_headers = ops_auth.signed_ops_headers(SECRET, nonce=original.headers["X-Kiki-Ops-Nonce"])
        assert voice.post("/internal/admin/v2/dashboard", content=b"{}", headers=dashboard_headers).status_code == 401
        payload = {"requestID": "86c3cc84-6d62-407c-ac87-cdb4c2874a41", "reportID": "report_missing",
                   "action": "warn", "note": "测试不存在的举报，不对真实用户执行操作"}
        result = ops.client.post("/admin/v2/services/voice/moderation/action", headers=authorization(session), json=payload)
        assert result.status_code == 404 and result.json()["detail"] == "举报记录不存在或证据已过期"
        assert len(captured) == 2
        grant(ops, session, "community", action="revoke")
        assert ops.client.post(path, headers=authorization(session), json={}).status_code == 403
        assert len(captured) == 2


def test_activity_requires_explicit_foreground_signal_and_deduplicates(client):
    session = login(client)
    headers = authorization(session)
    client.get("/v1/me", headers=headers)
    client.post("/v1/auth/refresh", headers=headers)
    with database(client.settings) as db:
        assert activity.aggregate(db)["activeAccountsToday"] == 0
    for _ in range(3):
        result = client.post("/v1/me/activity", headers=headers, json={})
        assert result.status_code == 200 and result.json()["retentionDays"] == 35
    with database(client.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM account_activity_daily").fetchone()[0] == 1
        data = activity.aggregate(db)
    assert data["activeAccountsToday"] == 1 and data["returningAccountsToday"] == 0
    assert session["user"]["id"] not in json.dumps(data) and session["token"] not in json.dumps(data)
    assert client.post("/v1/me/activity", json={}).status_code == 401
    assert client.post("/v1/me/activity", headers=headers, json={"day": "2000-01-01"}).status_code == 422


def test_activity_calendar_retention_returning_cohort_and_future_data_exclusion(client):
    alice = login(client); bob = login(client, "bob")
    current = datetime(2026, 10, 19, 12, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
    with database(client.settings) as db:
        a = db.execute("SELECT account_id FROM accounts WHERE login_id=?", (alice["user"]["id"],)).fetchone()[0]
        b = db.execute("SELECT account_id FROM accounts WHERE login_id=?", (bob["user"]["id"],)).fetchone()[0]
        for account_id, offset in ((a, -35), (a, -34), (a, -1), (a, 0), (b, -1), (b, 1)):
            day = (activity.today(current)+timedelta(days=offset)).isoformat()
            db.execute("INSERT INTO account_activity_daily VALUES(?,?)", (account_id, day))
        activity.purge(db, current)
        data = activity.aggregate(db, current)
        assert db.execute("SELECT COUNT(*) FROM account_activity_daily WHERE day='2026-09-14'").fetchone()[0] == 0
    assert data["activeAccountsToday"] == 1 and data["returningAccountsToday"] == 1
    assert data["previousDayCohortAccounts"] == 2 and data["previousDayReturnedAccounts"] == 1
    assert data["previousDayReturnPercent"] == 50.0 and data["activeAccountsLast7Days"] == 2


@pytest.mark.parametrize("erase", ["withdraw", "delete", "apple-revoke"])
def test_activity_data_cleared_on_withdrawal_deletion_or_apple_revocation(client, erase):
    session = login(client); headers = authorization(session)
    assert client.post("/v1/me/activity", headers=headers, json={}).status_code == 200
    if erase == "withdraw":
        assert client.delete("/v1/me/legal-consent", headers=headers).status_code == 200
    elif erase == "delete":
        assert client.delete("/v1/account", headers=headers).status_code == 200
    else:
        from test_apple_auth import notification
        assert client.post("/v1/auth/apple/notifications", json=notification(client)).status_code == 200
    with database(client.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM account_activity_daily").fetchone()[0] == 0


@pytest.mark.parametrize("payload", [{"name": "傻 逼"}, {"bio": "提供裸聊交易"},
                                     {"name": "操，你，妈"}, {"bio": "傻\u200b逼"}])
def test_public_profile_filter_rejects_unsafe_content_without_logging_or_mutation(client, payload):
    session = login(client); headers = authorization(session)
    before = client.get("/v1/me", headers=headers).json()
    result = client.patch("/v1/me", headers=headers, json=payload)
    assert result.status_code == 422 and all(value not in result.text for value in payload.values())
    assert client.get("/v1/me", headers=headers).json() == before


def test_configurable_filter_normalizes_width_case_and_ignores_empty_terms():
    policy = PublicTextPolicy("SCAM-LINK,，,\n,,")
    policy.check_profile(name="正常昵称", bio="一起聊天\n欢迎参加")
    with pytest.raises(Exception) as rejected:
        policy.check_profile(bio="ｓｃａｍ－ｌｉｎｋ")
    assert rejected.value.status_code == 422


def test_backup_status_unknown_valid_stale_and_public_error_only(tmp_path, monkeypatch):
    path = tmp_path/"backup-status.json"
    monkeypatch.setattr(maintenance, "STATUS_PATH", path)
    now = time.time()
    assert maintenance.backup_status(now)["healthy"] is None
    value = {"schemaVersion": 1, "service": "account", "retentionDays": 7,
             "lastSuccessAt": now-60, "verifiedAt": now-50, "lastError": None}
    path.write_text(json.dumps(value))
    assert maintenance.backup_status(now)["healthy"] is True
    path.write_text(json.dumps({**value, "lastSuccessAt": now-36*3600-1}))
    assert maintenance.backup_status(now)["healthy"] is False
    path.write_text(json.dumps({**value, "lastError": "/private/backup/key/path"}))
    result = maintenance.backup_status(now)
    assert result["healthy"] is False and "/private/" not in json.dumps(result)
    target = tmp_path/"private-secret"; target.write_text("private")
    path.unlink(); path.symlink_to(target)
    assert maintenance.backup_status(now)["healthy"] is None
    assert "private" not in json.dumps(maintenance.backup_status(now))
