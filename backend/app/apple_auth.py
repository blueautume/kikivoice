"""Apple's fixed HTTPS endpoints and cryptographic validation, with no test bypass.

All callers run in FastAPI's worker pool, outside SQLite transactions. The only
persisted Apple credential is a Fernet-encrypted refresh token; id/access tokens,
email and Apple's name are deliberately not stored.
"""

import base64
import hashlib
import hmac
import json
import re
import threading
import time
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
import httpx
import jwt
from fastapi import HTTPException

ISSUER = "https://appleid.apple.com"
JWKS_URL = ISSUER + "/auth/keys"
TOKEN_URL = ISSUER + "/auth/token"
REVOKE_URL = ISSUER + "/auth/revoke"
CHALLENGE_SECONDS = 300
VALIDATION_SECONDS = 86400
NOTIFICATION_SECONDS = 7 * 86400
REVOCATION_SECONDS = 7 * 86400


class AppleGrantRevoked(Exception):
    """The authorization grant is no longer usable, not a network failure."""


class AppleAuth:
    def __init__(self, settings):
        self.client_id = settings.apple_client_id
        self.team_id = settings.apple_team_id
        self.key_id = settings.apple_key_id
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{2,254}", self.client_id or "") or not all(
                re.fullmatch(r"[A-Z0-9]{10}", value or "") for value in (self.team_id, self.key_id)):
            raise RuntimeError("必须配置有效的 Apple Client ID、Team ID 和 Key ID")
        try:
            path = Path(settings.apple_private_key_path)
            if not path.is_file() or path.stat().st_mode & 0o077:
                raise ValueError("Private key must only be readable by its owner")
            self.private_key = serialization.load_pem_private_key(path.read_bytes(), password=None)
            if not isinstance(self.private_key, ec.EllipticCurvePrivateKey) or not isinstance(
                    self.private_key.curve, ec.SECP256R1):
                raise ValueError("Sign in with Apple needs a P-256 private key")
            self.cipher = Fernet(settings.apple_token_encryption_key.encode("ascii"))
        except (OSError, TypeError, ValueError) as error:
            raise RuntimeError("Apple 登录私钥路径、权限或令牌加密密钥无效") from error
        self.http = httpx.Client(timeout=httpx.Timeout(10, connect=5), follow_redirects=False,
                                 trust_env=False, limits=httpx.Limits(max_connections=12, max_keepalive_connections=6))
        self.lock = threading.Lock()
        self.keys = {}
        self.keys_loaded_at = 0.0
        self.last_unknown_refresh = 0.0

    def close(self):
        self.http.close()

    def client_secret(self):
        # Generate a fresh short-lived client secret; no 6-month static secret to
        # expire silently, and the .p8 never leaves the process.
        now = int(time.time())
        return jwt.encode({"iss": self.team_id, "iat": now, "exp": now + 300,
                           "aud": ISSUER, "sub": self.client_id}, self.private_key,
                          algorithm="ES256", headers={"kid": self.key_id})

    def _signing_key(self, token):
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str) or len(header["kid"]) > 128:
                raise jwt.InvalidTokenError("Unsupported Apple signing header")
            kid = header["kid"]
            with self.lock:
                now = time.monotonic()
                expired = not self.keys or now - self.keys_loaded_at >= 3600
                unknown = kid not in self.keys and now - self.last_unknown_refresh >= 30
                if expired or unknown:
                    if unknown:
                        self.last_unknown_refresh = now
                    try:
                        response = self.http.get(JWKS_URL)
                        response.raise_for_status()
                        data = response.json()
                        keys = jwt.PyJWKSet.from_dict(data).keys
                        self.keys = {key.key_id: key for key in keys if key.algorithm_name == "RS256"
                                     and key.public_key_use in (None, "sig") and key.key_id}
                        if not self.keys:
                            raise ValueError("No Apple RSA signing keys")
                        self.keys_loaded_at = now
                    except (httpx.HTTPError, ValueError, jwt.PyJWTError) as error:
                        raise HTTPException(503, "暂时无法验证 Apple 登录，请稍后重试") from error
                key = self.keys.get(kid)
                if key is None:
                    raise jwt.InvalidTokenError("Unknown Apple signing key")
                return key.key
        except jwt.PyJWTError as error:
            raise HTTPException(401, "Apple 授权无效，请重新登录") from error

    def verify_identity(self, token, *, nonce=None, fresh_since=None, subject=None):
        try:
            claims = jwt.decode(token, self._signing_key(token), algorithms=["RS256"],
                                issuer=ISSUER, audience=self.client_id, leeway=30,
                                options={"require": ["iss", "aud", "exp", "iat", "sub"], "strict_aud": True})
            if any(type(claims[key]) is not int for key in ("iat", "exp")):
                raise jwt.InvalidTokenError("Invalid numeric claims")
            if not isinstance(claims["sub"], str) or not 1 <= len(claims["sub"]) <= 255:
                raise jwt.InvalidTokenError("Invalid subject")
            if subject is not None and not hmac.compare_digest(claims["sub"], subject):
                raise jwt.InvalidTokenError("Mismatched subject")
            if nonce is not None and (not isinstance(claims.get("nonce"), str) or not hmac.compare_digest(claims["nonce"], nonce)):
                raise jwt.InvalidTokenError("Mismatched nonce")
            if fresh_since is not None and (type(claims["iat"]) is not int or claims["iat"] < fresh_since - 60):
                raise jwt.InvalidTokenError("Stale authorization")
            return claims
        except (jwt.PyJWTError, TypeError, ValueError) as error:
            raise HTTPException(401, "Apple 授权无效，请重新登录") from error

    def _post(self, url, form, *, refresh=False):
        try:
            response = self.http.post(url, data={"client_id": self.client_id,
                                      "client_secret": self.client_secret(), **form})
            result = response.json() if response.content else {}
            if not isinstance(result, dict):
                raise ValueError("Malformed Apple response")
            if response.status_code == 400 and result.get("error") == "invalid_grant":
                if refresh:
                    raise AppleGrantRevoked()
                raise HTTPException(401, "Apple 授权已过期，请重新登录")
            if response.status_code != 200 or not isinstance(result, dict):
                raise ValueError("Apple endpoint rejected request")
            return result
        except (httpx.HTTPError, ValueError, TypeError) as error:
            raise HTTPException(503, "Apple 登录服务暂时不可用，请稍后重试") from error

    def exchange_code(self, code, *, nonce, subject, fresh_since):
        result = self._post(TOKEN_URL, {"grant_type": "authorization_code", "code": code})
        token = result.get("id_token")
        refresh_token = result.get("refresh_token")
        if not isinstance(token, str) or not isinstance(refresh_token, str) or not 1 <= len(refresh_token) <= 8192:
            raise HTTPException(503, "Apple 未返回完整授权，请重新登录")
        claims = self.verify_identity(token, nonce=nonce, subject=subject, fresh_since=fresh_since)
        # c_hash is optional in native responses; when present it binds the exact
        # authorization code in addition to Apple's server-side code exchange.
        if "c_hash" in claims:
            self.verify_code_hash(code, claims["c_hash"])
        return self.encrypt(refresh_token)

    @staticmethod
    def verify_code_hash(code, value):
        expected = base64.urlsafe_b64encode(hashlib.sha256(code.encode()).digest()[:16]).rstrip(b"=").decode()
        if not isinstance(value, str) or not hmac.compare_digest(value, expected):
            raise HTTPException(401, "Apple 授权码不匹配，请重新登录")

    def encrypt(self, token):
        return self.cipher.encrypt(token.encode()).decode()

    def decrypt(self, encrypted):
        try:
            return self.cipher.decrypt(encrypted.encode()).decode()
        except (InvalidToken, ValueError, UnicodeError) as error:
            raise HTTPException(503, "Apple 授权暂时不可用，请联系开发者") from error

    def validate_refresh(self, encrypted, subject):
        result = self._post(TOKEN_URL, {"grant_type": "refresh_token", "refresh_token": self.decrypt(encrypted)}, refresh=True)
        if not isinstance(result.get("id_token"), str):
            raise HTTPException(503, "Apple 未返回完整授权，请稍后重试")
        self.verify_identity(result["id_token"], subject=subject)
        replacement = result.get("refresh_token")
        return self.encrypt(replacement) if isinstance(replacement, str) and replacement else encrypted

    def revoke(self, encrypted):
        # Apple returns success even for already-invalid tokens; retries are safe.
        self._post(REVOKE_URL, {"token": self.decrypt(encrypted), "token_type_hint": "refresh_token"}, refresh=True)

    def verify_notification(self, token):
        try:
            claims = jwt.decode(token, self._signing_key(token), algorithms=["RS256"], issuer=ISSUER,
                                audience=self.client_id, leeway=30,
                                options={"require": ["iss", "aud", "iat", "jti", "events"], "strict_aud": True})
            now = int(time.time())
            if type(claims["iat"]) is not int or not now - NOTIFICATION_SECONDS <= claims["iat"] <= now + 30:
                raise ValueError("Stale notification")
            if not isinstance(claims["jti"], str) or not 1 <= len(claims["jti"]) <= 255:
                raise ValueError("Invalid notification id")
            event = claims["events"]
            if isinstance(event, str):
                event = json.loads(event)
            if not isinstance(event, dict) or event.get("type") not in {
                    "consent-revoked", "account-deleted", "email-enabled", "email-disabled"}:
                raise ValueError("Invalid event")
            if not isinstance(event.get("sub"), str) or not 1 <= len(event["sub"]) <= 255:
                raise ValueError("Invalid event subject")
            if type(event.get("event_time")) is not int or not 0 < event["event_time"] <= claims["iat"] + 60:
                raise ValueError("Invalid event time")
            return claims["jti"], event
        except (jwt.PyJWTError, ValueError, TypeError) as error:
            raise HTTPException(401, "Apple 通知验证失败") from error
