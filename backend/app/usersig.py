"""Server-only Tencent TLS 2.0 UserSig, HMAC-SHA256.

Protocol reference: Tencent-RTC/tls-sig-api-v2-python, TLSSigAPIv2.py.
No credentials belong in the mobile app or this source tree.
"""

import base64
import hashlib
import hmac
import json
import time
import zlib


def generate_user_sig(sdk_app_id: int, secret_key: str, user_id: str,
                      expires_in: int = 86400, *, now: int | None = None) -> str:
    issued_at = int(time.time()) if now is None else now
    fields = {
        "TLS.ver": "2.0", "TLS.identifier": user_id, "TLS.sdkappid": sdk_app_id,
        "TLS.expire": expires_in, "TLS.time": issued_at,
    }
    payload = (f"TLS.identifier:{user_id}\nTLS.sdkappid:{sdk_app_id}\n"
               f"TLS.time:{issued_at}\nTLS.expire:{expires_in}\n")
    fields["TLS.sig"] = base64.b64encode(hmac.new(
        secret_key.encode(), payload.encode(), hashlib.sha256).digest()).decode()
    compressed = zlib.compress(json.dumps(fields, separators=(",", ":")).encode())
    return base64.b64encode(compressed).decode().translate(str.maketrans("+/=", "*-_"))
