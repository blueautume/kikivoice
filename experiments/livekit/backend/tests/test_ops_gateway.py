"""Central Passkey/ACL voice gateway: fixed aggregate request and durable replay fence."""
import asyncio
from contextlib import suppress
from dataclasses import replace
import hashlib
import hmac
import secrets
import sqlite3
import time
from types import SimpleNamespace

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest
from starlette.requests import Request

from app.admin import HostCollector, empty_host_snapshot, hash_passphrase
from app.main import Settings, create_app
from app.ops_gateway import DASHBOARD_PATH, MAX_ACTIVE_NONCES
from conftest import FakeLiveKit

OPS_SECRET = "independent-operations-bridge-secret-0123456789abcdef"
LEGACY_PHRASE = "legacy-voice-management-passphrase"
LEGACY_HASH = hash_passphrase(LEGACY_PHRASE)


def signed(*, body=b"{}", timestamp=None, nonce=None, secret=OPS_SECRET,
           domain="account-voice-ops-v2", path=DASHBOARD_PATH):
    timestamp = str(int(time.time()) if timestamp is None else timestamp)
    nonce = nonce or secrets.token_hex(16)
    message = "\n".join((domain, "POST", path, timestamp, nonce, hashlib.sha256(body).hexdigest())).encode()
    return {"Content-Type":"application/json", "X-Kiki-Ops-Timestamp":timestamp,
            "X-Kiki-Ops-Nonce":nonce,
            "X-Kiki-Ops-Signature":hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()}


@pytest.fixture
def ops(lab, monkeypatch):
    monkeypatch.setattr(HostCollector, "collect", lambda self: {**empty_host_snapshot(), "sampledAt":"2026-10-19T00:00:00Z", "stale":False, "cpuPercent":21.5})
    settings = replace(lab.settings, db_path=lab.settings.db_path + ".ops", admin_auth_mode="passkey",
                       ops_bridge_secret=OPS_SECRET, admin_passphrase_hash="")
    rtc = FakeLiveKit(settings)
    app = create_app(settings, rtc)
    with TestClient(app) as client:
        sampler_started = app.state.admin.task is not None
        # Tests intentionally inspect/write the SQLite fixture from their own
        # thread. Stop the periodic sampler before those out-of-loop fixtures.
        client.portal.call(app.state.admin.close)
        yield SimpleNamespace(settings=settings, rtc=rtc, app=app, client=client,
                              sampler_started=sampler_started)


def test_passkey_mode_samples_and_serves_dashboard_without_password_hash(ops):
    service = ops.app.state.admin
    assert service.enabled and not service.legacy_enabled and ops.sampler_started
    ops.client.portal.call(service.sample_host)
    ops.client.portal.call(service.sample_sfu)
    response = ops.client.post(DASHBOARD_PATH, content=b"{}", headers=signed())
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    data = response.json()
    assert data["service"]["id"] == "voice-lab" and data["service"]["host"] == "furby.top"
    assert data["service"]["readOnly"] is True
    assert data["infrastructure"]["cpuPercent"] == 21.5
    assert data["capacity"]["activeParticipants"] == 0 and not data["capacity"]["sfuStale"]
    assert not {"account", "permissions", "operator", "credential", "token"}.intersection(data)
    columns = [row["name"] for row in ops.app.state.db.execute("PRAGMA table_info(ops_bridge_nonces)")]
    assert columns == ["nonce", "expires_at"]
    assert not ops.app.state.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name LIKE 'ops_%' AND name!='ops_bridge_nonces'").fetchone()


def test_gateway_is_absent_in_legacy_mode(lab):
    assert lab.client.post(DASHBOARD_PATH, content=b"{}", headers=signed()).status_code == 404
    assert lab.client.get("/admin/v1/dashboard").status_code == 503  # Legacy behavior retained.


def test_legacy_login_and_bearers_cannot_bypass_central_permissions(ops):
    token = secrets.token_urlsafe(32)
    digest = hashlib.sha256(token.encode()).hexdigest()
    with ops.app.state.db:
        ops.app.state.db.execute("INSERT INTO admin_sessions VALUES(?,?,NULL,?)",
            (digest, int(time.time()) + 1000, ops.app.state.admin.credential_fingerprint))
    for method, path, kwargs in (
        ("POST", "/admin/v1/auth/session", {"json":{"passphrase":LEGACY_PHRASE}}),
        ("POST", "/admin/v1/auth/session", {"json":{"passphrase":"x"}}),
        ("DELETE", "/admin/v1/auth/session", {}),
        ("GET", "/admin/v1/dashboard", {}),
        ("POST", "/admin/v1/rooms/anything/end", {})):
        response = ops.client.request(method, path, headers={"Authorization":"Bearer " + token}, **kwargs)
        assert response.status_code == 404
        assert response.headers["cache-control"] == "no-store"
    request = Request({"type":"http", "headers":[(b"authorization", ("Bearer " + token).encode())]})
    with pytest.raises(HTTPException) as error:
        ops.app.state.admin.authenticate(request)
    assert error.value.status_code == 401
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers={"Authorization":"Bearer " + token}).status_code == 401


def test_mode_switch_clears_legacy_sessions_even_if_hash_was_left_configured(ops):
    with ops.app.state.db:
        ops.app.state.db.execute("INSERT INTO admin_sessions VALUES(?,?,NULL,?)", ("f"*64, int(time.time()) + 3600, "e"*64))
    settings = replace(ops.settings, admin_passphrase_hash=LEGACY_HASH)
    with TestClient(create_app(settings, FakeLiveKit(settings))) as restarted:
        assert restarted.app.state.db.execute("SELECT COUNT(*) FROM admin_sessions").fetchone()[0] == 0
        assert restarted.post("/admin/v1/auth/session", json={"passphrase":LEGACY_PHRASE}).status_code == 404
        assert restarted.post(DASHBOARD_PATH, content=b"{}", headers=signed()).status_code == 200


def test_missing_wrong_or_business_bridge_signature_is_rejected_without_consumption(ops):
    for auth in ({}, signed(secret=ops.settings.api_secret), signed(domain="account-voice-v1"),
                 {"X-Kiki-Timestamp":str(int(time.time())), "X-Kiki-Nonce":"a"*32, "X-Kiki-Signature":"b"*64}):
        response = ops.client.post(DASHBOARD_PATH, content=b"{}", headers=auth)
        assert response.status_code == 401
    assert ops.app.state.db.execute("SELECT COUNT(*) FROM ops_bridge_nonces").fetchone()[0] == 0


def test_timestamp_window_and_nonce_format_are_strict(ops):
    now = int(time.time())
    for delta in (-31, 31):
        assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=signed(timestamp=now + delta)).status_code == 401
    for nonce in ("a"*31, "A"*32, "x"*32, "a"*33):
        assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=signed(nonce=nonce)).status_code == 401
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=signed(timestamp=now)).status_code == 200


def test_nonce_is_durable_across_process_restarts(ops):
    auth = signed()
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=auth).status_code == 200
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=auth).status_code == 401
    with TestClient(create_app(ops.settings, FakeLiveKit(ops.settings))) as restarted:
        assert restarted.post(DASHBOARD_PATH, content=b"{}", headers=auth).status_code == 401
    row = ops.app.state.db.execute("SELECT * FROM ops_bridge_nonces").fetchone()
    assert row["nonce"] == auth["X-Kiki-Ops-Nonce"]
    assert 59 <= row["expires_at"] - time.time() <= 61


def test_body_is_exact_empty_object_no_identity_or_acl_claims(ops):
    for body in (b"", b"{ }", b"{}\n", b'{"accountID":"ops_fake"}',
                 b'{"permissions":{"voice":true}}', b'{"name":"operator"}'):
        assert ops.client.post(DASHBOARD_PATH, content=body, headers=signed(body=body)).status_code == 401
    assert ops.app.state.db.execute("SELECT COUNT(*) FROM ops_bridge_nonces").fetchone()[0] == 0


def test_content_type_query_bearer_and_noncanonical_path_are_rejected(ops):
    auth = signed()
    for mime in (None, "text/plain", "application/json; charset=utf-8"):
        values = dict(auth)
        values.pop("Content-Type")
        if mime is not None:
            values["Content-Type"] = mime
        assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=values).status_code == 401
    assert ops.client.post(DASHBOARD_PATH + "?account=voice", content=b"{}", headers=auth).status_code == 401
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers={**auth, "Authorization":"Bearer central-token"}).status_code == 401
    encoded_path = DASHBOARD_PATH.replace("dashboard", "%64ashboard")
    assert ops.client.post(encoded_path, content=b"{}", headers=auth).status_code == 401
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=auth).status_code == 200


def test_duplicate_signature_headers_are_rejected(ops):
    for duplicate in ("X-Kiki-Ops-Timestamp", "X-Kiki-Ops-Nonce", "X-Kiki-Ops-Signature", "Content-Type"):
        auth = signed()
        headers = list(auth.items()) + [(duplicate, auth[duplicate])]
        assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=headers).status_code == 401


def test_nonce_storage_is_bounded_and_expired_rows_are_removed(ops):
    now = int(time.time())
    with ops.app.state.db:
        ops.app.state.db.executemany("INSERT INTO ops_bridge_nonces VALUES(?,?)",
            ((f"{index:032x}", now + 61) for index in range(MAX_ACTIVE_NONCES)))
    response = ops.client.post(DASHBOARD_PATH, content=b"{}", headers=signed())
    assert response.status_code == 429 and response.headers["retry-after"] == "60"
    with ops.app.state.db:
        ops.app.state.db.execute("UPDATE ops_bridge_nonces SET expires_at=?", (now - 1,))
    assert ops.client.post(DASHBOARD_PATH, content=b"{}", headers=signed()).status_code == 200
    assert ops.app.state.db.execute("SELECT COUNT(*) FROM ops_bridge_nonces").fetchone()[0] == 1


def test_readonly_gateway_has_no_control_or_other_http_methods(ops):
    for method, path in (("GET", DASHBOARD_PATH), ("DELETE", DASHBOARD_PATH),
                         ("POST", "/internal/admin/v2/rooms/end"),
                         ("POST", "/internal/admin/v2/users/ban"),
                         ("POST", DASHBOARD_PATH + "/")):
        assert ops.client.request(method, path, content=b"{}", headers=signed()).status_code in {404,405}


def test_configuration_requires_dedicated_high_entropy_secret(lab):
    base = replace(lab.settings, admin_auth_mode="passkey", ops_bridge_secret=OPS_SECRET)
    base.validate()
    for changed in ({"admin_auth_mode":"password"}, {"ops_bridge_secret":""},
                    {"ops_bridge_secret":"a"*48}, {"ops_bridge_secret":base.api_secret},
                    {"account_bridge_secret":OPS_SECRET}, {"access_code":OPS_SECRET},
                    {"admin_passphrase_hash":hash_passphrase(OPS_SECRET)}):
        with pytest.raises(RuntimeError):
            replace(base, **changed).validate()


def test_sampler_database_maintenance_waits_for_shared_transaction_lock(ops):
    service = ops.app.state.admin
    statements = []
    service.db.set_trace_callback(statements.append)

    async def verify():
        task = None
        try:
            async with service.lock:
                task = asyncio.create_task(service.maintain())
                await asyncio.sleep(.02)
                assert not any("DELETE FROM admin_sessions" in sql for sql in statements)
            for _ in range(100):
                if any("DELETE FROM admin_sessions" in sql for sql in statements):
                    break
                await asyncio.sleep(.001)
            assert any("DELETE FROM admin_sessions" in sql for sql in statements)
        finally:
            if task:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task

    try:
        ops.client.portal.call(verify)
    finally:
        service.db.set_trace_callback(None)


def test_environment_mode_defaults_to_legacy_and_reads_explicit_passkey(monkeypatch):
    monkeypatch.delenv("ADMIN_AUTH_MODE", raising=False)
    monkeypatch.delenv("OPS_BRIDGE_SECRET", raising=False)
    assert Settings.from_environment().admin_auth_mode == "legacy"
    monkeypatch.setenv("ADMIN_AUTH_MODE", "passkey")
    monkeypatch.setenv("OPS_BRIDGE_SECRET", OPS_SECRET)
    settings = Settings.from_environment()
    assert settings.admin_auth_mode == "passkey" and settings.ops_bridge_secret == OPS_SECRET
