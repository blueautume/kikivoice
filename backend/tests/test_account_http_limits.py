"""Functional rate-limit boundaries, using real account sessions on one source IP.

These are sequential local API unit checks, not a capacity/throughput load test.
"""
from dataclasses import replace
import hashlib

from fastapi.testclient import TestClient
import pytest

from app.main import Settings, create_app, database
from conftest import apple_settings
from test_api import TEST_KEY, authorization, login


@pytest.fixture
def rate_accounts(tmp_path, fake_apple):
    # Seed through real Apple signature fixtures with limits disabled, then
    # restart with the production limiter and the same persistent sessions.
    settings=apple_settings(Settings(str(tmp_path/'http-rate.sqlite3'),123,TEST_KEY,False))
    with TestClient(create_app(settings)) as seed:
        seed.settings=settings;seed.fake_apple=fake_apple
        accounts=[login(seed,'rate-'+str(index)) for index in range(8)]
    enabled=replace(settings,rate_limit_enabled=True)
    with TestClient(create_app(enabled)) as client:
        client.settings=enabled;client.fake_apple=fake_apple
        yield client,accounts


def test_shared_ip_accounts_do_not_consume_one_anonymous_240_request_pool(rate_accounts):
    client,accounts=rate_accounts
    # 320 total requests from exactly the same TestClient source IP, but only40
    # per genuine account session. No network/concurrency load is generated.
    for _ in range(40):
        for account in accounts:
            response=client.get('/v1/me',headers=authorization(account))
            assert response.status_code==200,response.text


def test_one_valid_session_is_limited_without_exhausting_other_sessions(rate_accounts):
    client,accounts=rate_accounts
    for _ in range(180):
        assert client.get('/v1/me',headers=authorization(accounts[0])).status_code==200
    rejected=client.get('/v1/me',headers=authorization(accounts[0]))
    assert rejected.status_code==429 and rejected.headers['Retry-After']=='60'
    assert client.get('/v1/me',headers=authorization(accounts[1])).status_code==200


@pytest.mark.parametrize('token_kind',['forged','expired','revoked'])
def test_invalid_bearers_cannot_escape_anonymous_limit(rate_accounts,token_kind):
    client,accounts=rate_accounts
    token=accounts[0]['token']
    if token_kind=='forged':token='x'*43
    else:
        token_hash=hashlib.sha256(token.encode()).hexdigest()
        with database(client.settings) as db:
            if token_kind=='expired':db.execute('UPDATE sessions SET expires_at=0 WHERE token_hash=?',(token_hash,))
            else:db.execute('DELETE FROM sessions WHERE token_hash=?',(token_hash,))
    for _ in range(240):
        assert client.get('/v1/me',headers={'Authorization':'Bearer '+token}).status_code==401
    rejected=client.get('/v1/me',headers={'Authorization':'Bearer '+token})
    assert rejected.status_code==429 and rejected.headers['Retry-After']=='60'
    assert client.get('/v1/me',headers=authorization(accounts[1])).status_code==200


def test_bearer_does_not_relax_authentication_or_ops_endpoints(rate_accounts):
    client,accounts=rate_accounts
    for _ in range(240):assert client.get('/health').status_code==200
    # A genuine business token does not move Apple authorization into its larger
    # allowance; existing route-specific challenge/login protections also stay.
    assert client.post('/v1/auth/apple/challenge',headers=authorization(accounts[0])).status_code==429
    assert client.get('/admin/v2/me',headers=authorization(accounts[0])).status_code==429
    assert client.get('/v1/me',headers=authorization(accounts[0])).status_code==200
