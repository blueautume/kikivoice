"""Account admin boundary and read-only aggregate contract, without network I/O."""
from dataclasses import replace
from pathlib import Path
import hashlib
import json
import sqlite3
import time

from fastapi.testclient import TestClient
import pytest

from app.admin import (HASH_ITERATIONS, HostCollector, hash_passphrase, verify_passphrase,
                       validate_admin_settings, collect_storage)
from app.main import Settings, create_app, database
from conftest import apple_settings, apple_payload

PASSPHRASE = "account-test-independent-credential"


@pytest.fixture(scope="module")
def credential_hash():
    return hash_passphrase(PASSPHRASE)


@pytest.fixture
def admin_client(tmp_path, fake_apple, credential_hash):
    settings = apple_settings(Settings(str(tmp_path / "test.sqlite3"), 1234567890, "a" * 64, False))
    settings = replace(settings, admin_passphrase_hash=credential_hash,
                       admin_tls_cert_path=str(tmp_path / "public-certificate.pem"))
    with TestClient(create_app(settings)) as client:
        client.settings = settings
        client.fake_apple = fake_apple
        yield client


def admin_login(client):
    response = client.post("/admin/v1/auth/session", json={"passphrase": PASSPHRASE})
    assert response.status_code == 200
    body = response.json()
    assert body["serviceID"] == "account" and body["role"] == "viewer"
    assert 8 * 3600 - 5 <= body["expiresAt"] - time.time() <= 8 * 3600
    return body, {"Authorization": "Bearer " + body["token"]}


def test_exact_hash_format_and_constant_credential_verification(credential_hash):
    assert HASH_ITERATIONS == 600_000
    assert verify_passphrase(PASSPHRASE, credential_hash)
    assert not verify_passphrase(PASSPHRASE + " ", credential_hash)
    assert not verify_passphrase(PASSPHRASE, "invalid")
    with pytest.raises(ValueError):
        hash_passphrase("short")


def test_admin_authentication_hash_storage_logout_and_no_cache(admin_client):
    body, headers = admin_login(admin_client)
    with database(admin_client.settings) as db:
        rows = db.execute("SELECT * FROM account_admin_sessions").fetchall()
    assert len(rows) == 1 and rows[0]["token_hash"] == hashlib.sha256(body["token"].encode()).hexdigest()
    assert body["token"] not in str([dict(row) for row in rows])
    response = admin_client.get("/admin/v1/dashboard", headers=headers)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert admin_client.delete("/admin/v1/auth/session", headers=headers).json() == {"revoked": True}
    assert admin_client.get("/admin/v1/dashboard", headers=headers).status_code == 401


def test_business_and_admin_bearer_namespaces_are_separate(admin_client):
    business = admin_client.post("/v1/auth/apple", json=apple_payload(admin_client)).json()
    assert admin_client.get("/admin/v1/dashboard", headers={"Authorization":"Bearer " + business["token"]}).status_code == 401
    _body, headers = admin_login(admin_client)
    assert admin_client.get("/v1/me", headers=headers).status_code == 401


def test_cross_origin_browser_requests_are_rejected(admin_client):
    for headers in ({"Origin":"https://furby.top"}, {"Origin":"null"},
                    {"Sec-Fetch-Site":"cross-site"}, {"Sec-Fetch-Site":"same-site"}):
        response = admin_client.post("/admin/v1/auth/session", headers=headers, json={"passphrase":PASSPHRASE})
        assert response.status_code == 403
        assert response.headers["cache-control"] == "no-store"


def test_login_limit_cannot_be_disabled_by_user_rate_limit_flag(admin_client):
    for _ in range(5):
        response = admin_client.post("/admin/v1/auth/session", json={"passphrase":"wrong-independent-credential"})
        assert response.status_code == 401
    response = admin_client.post("/admin/v1/auth/session", json={"passphrase":PASSPHRASE})
    assert response.status_code == 429 and response.headers["retry-after"] == "300"


def test_validation_does_not_echo_submitted_passphrase(admin_client):
    secret = "private-value-must-never-echo"
    response = admin_client.post("/admin/v1/auth/session", json={"passphrase":secret,"unexpected":secret})
    assert response.status_code == 422
    assert secret not in response.text


def test_aggregate_counts_and_no_personal_fields(admin_client):
    first = admin_client.post("/v1/auth/apple", json=apple_payload(admin_client, "private-apple-subject")).json()
    _body, headers = admin_login(admin_client)
    data = admin_client.get("/admin/v1/dashboard", headers=headers).json()
    assert data["service"] == {"id":"account", "name":"Kiki 账号服务", "host":"kiki.group", "mode":"account", "readOnly":True}
    assert data["operations"]["totalAccounts"] == 1
    assert data["operations"]["accountsCreatedToday"] == 1
    assert data["operations"]["validBusinessSessions"] == 1
    assert data["operations"]["accountsWithValidSessions"] == 1
    assert data["operations"]["appleAuthorizedAccounts"] == 1
    assert data["operations"]["pendingAppleRevocations"] == 0
    assert data["voiceService"]["included"] is False
    serialized = json.dumps(data)
    for private in (first["token"], first["user"]["id"], "private-apple-subject", "refresh_token_encrypted", "sdkUserID"):
        assert private not in serialized
    assert "capacity" not in data and "rooms" not in data and "quality" not in data
    assert "不代表在线人数" in data["operations"]["sessionMetricNote"]


def test_expiry_and_credential_rotation_reject_previous_session(admin_client):
    body, headers = admin_login(admin_client)
    with database(admin_client.settings) as db:
        db.execute("UPDATE account_admin_sessions SET expires_at=0")
    assert admin_client.get("/admin/v1/dashboard", headers=headers).status_code == 401
    body, headers = admin_login(admin_client)
    admin_client.app.state.admin.fingerprint = "different-credential"
    assert admin_client.get("/admin/v1/dashboard", headers=headers).status_code == 401


def test_avatar_scan_excludes_symlinks_and_unknown_files(admin_client, tmp_path):
    target = tmp_path / "private.txt"
    target.write_text("hidden")
    avatars = admin_client.settings.avatar_path
    (avatars / ("a"*64 + ".jpg")).write_bytes(b"image-bytes")
    (avatars / ("b"*64 + ".jpg")).symlink_to(target)
    (avatars / "unrecognized.jpg").write_bytes(b"excluded")
    admin_client.app.state.admin.storage = collect_storage(admin_client.settings)
    _body, headers = admin_login(admin_client)
    data = admin_client.get("/admin/v1/dashboard", headers=headers).json()
    assert data["storage"]["avatarFiles"] == 1
    assert data["storage"]["avatarBytes"] == len(b"image-bytes")
    assert data["storage"]["databaseBytes"] > 0
    assert "hidden" not in json.dumps(data)


def test_unknown_host_metrics_are_null_and_marked_stale(admin_client):
    admin_client.portal.call(admin_client.app.state.admin.close)
    admin_client.app.state.admin.host_at = None
    _body, headers = admin_login(admin_client)
    data = admin_client.get("/admin/v1/dashboard", headers=headers).json()
    assert data["infrastructure"]["stale"] is True
    assert data["health"]["api"] == "healthy"


def test_invalid_certificate_path_or_systemd_unit_rejected(tmp_path, credential_hash):
    settings = Settings(str(tmp_path / "test.sqlite3"), 1, "a"*64, admin_passphrase_hash=credential_hash)
    with pytest.raises(RuntimeError):
        validate_admin_settings(replace(settings, admin_tls_cert_path="relative.pem"))
    with pytest.raises(RuntimeError):
        validate_admin_settings(replace(settings, admin_api_systemd_unit="nginx; cat secret.service"))
