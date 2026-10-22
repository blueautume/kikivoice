from dataclasses import replace
import hashlib
import json
from pathlib import Path
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa
import httpx
import jwt
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.apple_auth import AppleAuth, AppleGrantRevoked, ISSUER, JWKS_URL, TOKEN_URL, REVOKE_URL
from app.main import Settings, create_app, load_legal_requirements
from conftest import apple_settings, apple_payload
from test_api import TEST_KEY, authorization, login


@pytest.fixture
def client(tmp_path, fake_apple):
    settings = apple_settings(Settings(str(tmp_path / "apple.sqlite3"), 123, TEST_KEY, False))
    with TestClient(create_app(settings)) as instance:
        instance.settings = settings
        instance.fake_apple = fake_apple
        yield instance


def count(client, table):
    with sqlite3.connect(client.settings.db_path) as db:
        return db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]


def test_challenge_random_single_use_and_only_hash_persisted(client):
    payload = apple_payload(client)
    with sqlite3.connect(client.settings.db_path) as db:
        row = db.execute("SELECT * FROM apple_challenges").fetchone()
        assert len(row[1]) == 64 and row[3] - row[2] == 300
    assert client.post("/v1/auth/apple", json=payload).status_code == 200
    assert client.post("/v1/auth/apple", json=payload).status_code == 401
    assert count(client, "apple_challenges") == 0
    assert count(client, "accounts") == 1


def test_expired_challenges_are_rejected_and_purged(client):
    payload = apple_payload(client)
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE apple_challenges SET expires_at=1")
    assert client.post("/v1/auth/apple", json=payload).status_code == 401
    client.post("/v1/auth/apple/challenge")
    assert count(client, "apple_challenges") == 1


@pytest.mark.parametrize("claims", [
    {"iss": "https://attacker.test"}, {"aud": "wrong.app"}, {"aud": ["com.kikitalk.demo", "other.app"]},
    {"exp": 1}, {"iat": int(time.time()) + 3600}, {"iat": 1}, {"iat": True}, {"exp": True},
    {"nonce": "wrong"}, {"nonce": None}, {"sub": ""}, {"sub": 123}, {"sub": "x" * 256},
])
def test_invalid_identity_claims_never_exchange_or_create_accounts(client, claims):
    payload = apple_payload(client, **claims)
    response = client.post("/v1/auth/apple", json=payload)
    assert response.status_code == 401
    assert count(client, "accounts") == 0 and count(client, "sessions") == 0
    assert not any(str(request.url) == TOKEN_URL for request in client.fake_apple.requests)
    assert client.post("/v1/auth/apple", json=payload).status_code == 401


def test_untrusted_signatures_none_alg_and_header_urls_rejected(client):
    for algorithm in ("HS256", "none", "RS256"):
        payload = apple_payload(client)
        claims = jwt.decode(payload["identityToken"], options={"verify_signature": False})
        key = "attacker-key" * 4 if algorithm == "HS256" else None
        if algorithm == "RS256":
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        payload["identityToken"] = jwt.encode(claims, key, algorithm=algorithm,
            headers={"kid": client.fake_apple.key_id, "jku": "https://attacker.test/jwks"})
        assert client.post("/v1/auth/apple", json=payload).status_code == 401
    assert count(client, "accounts") == 0
    assert all(str(request.url) == JWKS_URL for request in client.fake_apple.requests)


def test_code_exchange_subject_nonce_and_code_hash_are_bound(client):
    for changes in ({"sub": "attacker"}, {"nonce": "wrong"}, {"c_hash": "wrong"}):
        payload = apple_payload(client)
        claims = jwt.decode(payload["identityToken"], options={"verify_signature": False})
        client.fake_apple.exchange_override = client.fake_apple.token(claims["sub"], claims["nonce"], **changes)
        assert client.post("/v1/auth/apple", json=payload).status_code == 401
        assert count(client, "accounts") == 0
    client.fake_apple.exchange_override = None
    payload = apple_payload(client)
    payload["authorizationCode"] = "another-code"
    assert client.post("/v1/auth/apple", json=payload).status_code == 401


def test_initial_c_hash_is_verified_before_exchange(client):
    payload = apple_payload(client, c_hash="invalid")
    assert client.post("/v1/auth/apple", json=payload).status_code == 401
    assert not any(str(request.url) == TOKEN_URL for request in client.fake_apple.requests)


def test_no_name_email_access_token_or_identity_token_are_persisted(client):
    payload = apple_payload(client, email="private@example.test", name="Apple name")
    response = client.post("/v1/auth/apple", json=payload)
    assert response.status_code == 200
    assert response.json()["user"]["needsNickname"] is True
    assert response.json()["user"]["name"] == "新朋友"
    with sqlite3.connect(client.settings.db_path) as db:
        dump = "\n".join(db.iterdump())
    for private in ("private@example.test", "Apple name", payload["identityToken"], payload["authorizationCode"], "refresh-", "not-stored"):
        assert private not in dump


def test_jwks_cached_rotated_and_unknown_ids_throttled(client):
    login(client)
    login(client, "bob")
    assert sum(str(request.url) == JWKS_URL for request in client.fake_apple.requests) == 1
    client.fake_apple.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    client.fake_apple.key_id = "fixture-rsa-2"
    client.app.state.apple_auth.last_unknown_refresh = 0
    login(client, "carol")
    assert sum(str(request.url) == JWKS_URL for request in client.fake_apple.requests) == 2
    for index in range(3):
        client.fake_apple.key_id = "unknown-" + str(index)
        assert client.post("/v1/auth/apple", json=apple_payload(client)).status_code == 401
    assert sum(str(request.url) == JWKS_URL for request in client.fake_apple.requests) == 2


def test_apple_outage_fails_closed_without_credential_leak(client):
    client.fake_apple.jwks_error = True
    payload = apple_payload(client)
    response = client.post("/v1/auth/apple", json=payload)
    assert response.status_code == 503
    assert count(client, "accounts") == 0
    assert payload["identityToken"] not in response.text
    assert payload["authorizationCode"] not in response.text


def test_refresh_daily_validation_and_revocation_invalidates_all_sessions(client):
    first, second = login(client), login(client)
    headers = authorization(first)
    before = sum(str(request.url) == TOKEN_URL for request in client.fake_apple.requests)
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 200
    assert sum(str(request.url) == TOKEN_URL for request in client.fake_apple.requests) == before
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE apple_credentials SET validated_at=1")
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 200
    assert sum(str(request.url) == TOKEN_URL for request in client.fake_apple.requests) == before + 1
    client.fake_apple.refresh_revoked = True
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE apple_credentials SET validated_at=1")
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 401
    assert client.get("/v1/me", headers=authorization(second)).status_code == 401


@pytest.mark.parametrize("revoked", [True, False])
def test_old_refresh_cannot_erase_or_overwrite_new_apple_grant(client, monkeypatch, revoked):
    result = login(client)
    headers = authorization(result)
    auth = client.app.state.apple_auth
    captured = {}
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE apple_credentials SET validated_at=1")

    def interleaving_refresh(encrypted, subject):
        fresh = login(client)
        captured["headers"] = authorization(fresh)
        with sqlite3.connect(client.settings.db_path) as db:
            captured["credential"] = db.execute("SELECT refresh_token_encrypted FROM apple_credentials").fetchone()[0]
        if revoked:
            raise AppleGrantRevoked()
        return auth.encrypt("stale-refreshed-token")

    monkeypatch.setattr(auth, "validate_refresh", interleaving_refresh)
    assert client.post("/v1/auth/refresh", headers=headers).status_code == 200
    assert client.get("/v1/me", headers=captured["headers"]).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT refresh_token_encrypted FROM apple_credentials").fetchone()[0] == captured["credential"]


def test_client_report_revocation_all_current_sessions_but_preserves_new_grant(client):
    old = login(client)
    fresh = login(client)
    assert client.post("/v1/auth/apple/revoked", headers=authorization(old)).status_code == 200
    assert client.get("/v1/me", headers=authorization(old)).status_code == 401
    assert client.get("/v1/me", headers=authorization(fresh)).status_code == 200
    assert client.post("/v1/auth/apple/revoked", headers=authorization(fresh)).status_code == 200
    assert client.get("/v1/me", headers=authorization(fresh)).status_code == 401
    assert count(client, "accounts") == 1


def test_delete_local_data_even_if_apple_unavailable_then_retries(client, caplog):
    headers = authorization(login(client))
    client.fake_apple.revoke_error = True
    assert client.delete("/v1/account", headers=headers).json() == {"ok": True}
    for table in ("accounts", "identities", "sessions", "legal_consent_events", "apple_credentials"):
        assert count(client, table) == 0
    assert count(client, "apple_revocations") == 1
    with sqlite3.connect(client.settings.db_path) as db:
        row = db.execute("SELECT * FROM apple_revocations").fetchone()
        assert "refresh-" not in row[1]
        assert row[2] == 1 and row[3] > int(time.time())
        db.execute("UPDATE apple_revocations SET next_attempt_at=1,attempts=25")
    client.fake_apple.revoke_error = False
    client.app.state.retry_apple_revocations()
    assert count(client, "apple_revocations") == 0
    assert "refresh-" not in caplog.text


def test_revocation_queue_expiry_logs_unresolved_status_and_removes_token(client, caplog):
    client.fake_apple.revoke_error = True
    client.delete("/v1/account", headers=authorization(login(client)))
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE apple_revocations SET created_at=1")
    client.app.state.retry_apple_revocations()
    assert count(client, "apple_revocations") == 0
    assert "unresolved grants" in caplog.text


def notification(client, *, subject="alice", event_type="consent-revoked", event_time=None, **changes):
    now = int(time.time())
    claims = {"iss": ISSUER, "aud": "com.kikitalk.demo", "iat": now, "jti": "event-" + str(time.time_ns()),
              "events": {"type": event_type, "sub": subject, "event_time": event_time if event_time is not None else now}}
    claims.update(changes)
    return {"payload": jwt.encode(claims, client.fake_apple.key, algorithm="RS256", headers={"kid": client.fake_apple.key_id})}


@pytest.mark.parametrize("event_type", ["consent-revoked", "account-deleted"])
def test_signed_notifications_delete_account_and_are_idempotent(client, event_type):
    result = login(client)
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("UPDATE apple_credentials SET authenticated_at=authenticated_at-1")
    payload = notification(client, event_type=event_type)
    assert client.post("/v1/auth/apple/notifications", json=payload).json() == {"ok": True}
    assert client.get("/v1/me", headers=authorization(result)).status_code == 401
    assert count(client, "accounts") == 0
    assert client.post("/v1/auth/apple/notifications", json=payload).json() == {"ok": True}
    assert count(client, "apple_notification_receipts") == 1
    # Same-old authorization cannot race back into creating a new account.
    assert client.post("/v1/auth/apple", json=apple_payload(client)).status_code == 401


def test_notification_arriving_before_login_commit_prevents_account_creation(client, monkeypatch):
    auth = client.app.state.apple_auth
    original = auth.exchange_code

    def exchange(*args, **kwargs):
        result = original(*args, **kwargs)
        assert client.post("/v1/auth/apple/notifications", json=notification(client)).status_code == 200
        return result

    monkeypatch.setattr(auth, "exchange_code", exchange)
    assert client.post("/v1/auth/apple", json=apple_payload(client)).status_code == 401
    assert count(client, "accounts") == 0


def test_delayed_old_notification_does_not_remove_new_authorization(client):
    result = login(client)
    payload = notification(client, event_time=int(time.time()) - 100)
    assert client.post("/v1/auth/apple/notifications", json=payload).status_code == 200
    assert client.get("/v1/me", headers=authorization(result)).status_code == 200
    assert login(client)["user"]["id"] == result["user"]["id"]


@pytest.mark.parametrize("changes", [
    {"iss": "bad"}, {"aud": "wrong.app"}, {"iat": 1}, {"iat": int(time.time()) + 3600},
    {"iat": True}, {"jti": ""}, {"events": {"type": "account-deleted", "sub": "alice", "event_time": True}},
    {"events": "not-json"}, {"events": {"type": "unknown", "sub": "alice", "event_time": 1}},
])
def test_forged_or_malformed_notifications_cannot_delete_accounts(client, changes):
    result = login(client)
    assert client.post("/v1/auth/apple/notifications", json=notification(client, **changes)).status_code == 401
    assert client.get("/v1/me", headers=authorization(result)).status_code == 200


@pytest.mark.parametrize("field,value", [
    ("apple_client_id", ""), ("apple_team_id", "bad"), ("apple_key_id", ""),
    ("apple_private_key_path", "/missing-file"), ("apple_token_encryption_key", "bad"),
])
def test_apple_configuration_missing_or_invalid_fails_closed(tmp_path, field, value):
    settings = apple_settings(Settings(str(tmp_path / "config.sqlite3"), 123, TEST_KEY, False))
    with pytest.raises(RuntimeError):
        create_app(replace(settings, **{field: value}))


def test_private_key_permissions_checked(tmp_path):
    settings = apple_settings(Settings(str(tmp_path / "config.sqlite3"), 123, TEST_KEY, False))
    Path(settings.apple_private_key_path).chmod(0o644)
    with pytest.raises(RuntimeError):
        create_app(settings)


def test_malformed_apple_response_is_service_unavailable(client):
    auth = client.app.state.apple_auth
    auth.http = httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(400, json=[])))
    with pytest.raises(HTTPException) as error:
        auth._post(TOKEN_URL, {"grant_type": "authorization_code", "code": "redacted"})
    assert error.value.status_code == 503


def test_challenge_atomic_consumption_under_parallel_login(client):
    payload = apple_payload(client)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: client.post("/v1/auth/apple", json=payload).status_code, range(2)))
    assert sorted(results) == [200, 401]
    assert count(client, "accounts") == 1 and count(client, "sessions") == 1


def test_expired_notification_and_challenge_receipts_cleaned_on_new_challenge(client):
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("INSERT INTO apple_notification_receipts VALUES('expired',1)")
        db.execute("INSERT INTO apple_subject_events VALUES('expired',1,1)")
        db.execute("INSERT INTO apple_challenges VALUES('expired','old',1,1)")
    client.post("/v1/auth/apple/challenge")
    assert count(client, "apple_notification_receipts") == 0
    assert count(client, "apple_subject_events") == 0
    assert count(client, "apple_challenges") == 1


@pytest.mark.parametrize("version", ["2026-10-17-r0", "2026-10-17-r01", "2026-10-17-rx", "2026-13-17-r2", "2026-10-17-extra"])
def test_legal_version_rejects_invalid_revision_suffix(tmp_path, monkeypatch, version):
    from app.main import LEGAL_DOCUMENTS_PATH
    document = json.loads(LEGAL_DOCUMENTS_PATH.read_text())
    document["privacyVersion"] = version
    target = tmp_path / "legal.json"
    target.write_text(json.dumps(document))
    monkeypatch.setattr("app.main.LEGAL_DOCUMENTS_PATH", target)
    with pytest.raises(RuntimeError):
        load_legal_requirements()
