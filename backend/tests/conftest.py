"""Local Apple cryptographic fixtures; production verifier is never bypassed."""
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import secrets
import time
from urllib.parse import parse_qs

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
import httpx
import jwt
import pytest

from app.apple_auth import AppleAuth, ISSUER, JWKS_URL, TOKEN_URL, REVOKE_URL
from app.main import load_legal_requirements


def apple_settings(settings):
    path = Path(settings.db_path).parent / "test-apple.p8"
    key = ec.generate_private_key(ec.SECP256R1())
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                     serialization.NoEncryption()))
    path.chmod(0o600)
    return replace(settings, apple_client_id="com.kikitalk.demo", apple_team_id="A82X46N3WS",
                   apple_key_id="6NH7S6KJ92", apple_private_key_path=str(path),
                   apple_token_encryption_key=Fernet.generate_key().decode())


class FakeApple:
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.key_id = "fixture-rsa-1"
        self.codes = {}
        self.refreshes = {}
        self.requests = []
        self.revoke_error = False
        self.refresh_revoked = False
        self.exchange_override = None
        self.jwks_error = False

    def token(self, subject, nonce_value=None, **changes):
        now = int(time.time())
        claims = {"iss": ISSUER, "aud": "com.kikitalk.demo", "sub": subject,
                  "iat": now, "exp": now + 300}
        if nonce_value is not None:
            claims["nonce"] = nonce_value
        claims.update(changes)
        return jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": self.key_id})

    def request(self, request, auth):
        self.requests.append(request)
        if str(request.url) == JWKS_URL:
            if self.jwks_error:
                return httpx.Response(503)
            key = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key()))
            return httpx.Response(200, json={"keys": [{**key, "kid": self.key_id, "alg": "RS256", "use": "sig"}]})
        form = {key: values[0] for key, values in parse_qs(request.content.decode()).items()}
        # Verify outbound client_secret using the real configured EC public key.
        claims = jwt.decode(form["client_secret"], auth.private_key.public_key(), algorithms=["ES256"],
                            issuer="A82X46N3WS", audience=ISSUER)
        assert claims["sub"] == form["client_id"] == "com.kikitalk.demo"
        assert claims["exp"] - claims["iat"] == 300
        assert jwt.get_unverified_header(form["client_secret"])["kid"] == "6NH7S6KJ92"
        assert "redirect_uri" not in form
        if str(request.url) == REVOKE_URL:
            return httpx.Response(503 if self.revoke_error else 200)
        if str(request.url) != TOKEN_URL:
            raise AssertionError("Unexpected outbound host")
        if form["grant_type"] == "authorization_code":
            claims = self.codes.pop(form["code"], None)
            if not claims:
                return httpx.Response(400, json={"error": "invalid_grant"})
            refresh = "refresh-" + secrets.token_hex(24)
            self.refreshes[refresh] = claims["sub"]
            token = self.exchange_override or self.token(claims["sub"], claims["nonce"])
            return httpx.Response(200, json={"id_token": token, "refresh_token": refresh,
                                           "access_token": "not-stored", "token_type": "Bearer"})
        if self.refresh_revoked:
            return httpx.Response(400, json={"error": "invalid_grant"})
        return httpx.Response(200, json={"id_token": self.token(self.refreshes[form["refresh_token"]]),
                                       "access_token": "not-stored"})


@pytest.fixture(autouse=True)
def fake_apple(monkeypatch):
    server = FakeApple()
    original = AppleAuth.__init__

    def initialize(auth, settings):
        original(auth, settings)
        auth.http.close()
        auth.http = httpx.Client(transport=httpx.MockTransport(lambda request: server.request(request, auth)))

    monkeypatch.setattr(AppleAuth, "__init__", initialize)
    return server


def apple_payload(client, subject="alice", *, consent=True, **token_changes):
    challenge = client.post("/v1/auth/apple/challenge").json()
    nonce = hashlib.sha256(challenge["nonce"].encode()).hexdigest()
    token = client.fake_apple.token(subject, nonce, **token_changes)
    code = "code-" + secrets.token_hex(24)
    client.fake_apple.codes[code] = {"sub": subject, "nonce": nonce}
    payload = {"challengeID": challenge["challengeID"], "identityToken": token, "authorizationCode": code}
    if consent:
        payload["legalConsent"] = {**load_legal_requirements(), "accepted": True, "adultConfirmed": True}
    return payload
