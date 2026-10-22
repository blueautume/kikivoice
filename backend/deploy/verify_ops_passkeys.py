"""Opt-in production protocol probe using disposable software WebAuthn keys.

This exercises the real server cryptographic verifier, never Apple/Face ID UI.
It creates zero-grant operations identities. Permissions must be changed via the
separate, exact-name-and-ID server CLI; no grant API or bootstrap is assumed.
Keep --state and --export outside Git, private (0600), and delete test identities
via the server CLI after validation. Never use this probe for a human account.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import struct
import time

import cbor2
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
import httpx

ORIGIN = "https://kiki.group"
RP_ID = "kiki.group"
PREFIX = "/admin/v2"


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def private_write(path, value):
    path = Path(path)
    repository = Path(__file__).resolve().parents[2]
    if path.resolve().is_relative_to(repository):
        raise RuntimeError("Private probe files must be outside the repository")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise RuntimeError("Refuse symlink private file")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)


def client_data(kind, challenge):
    return json.dumps({"type": kind, "challenge": challenge, "origin": ORIGIN,
                       "crossOrigin": False}, separators=(",", ":")).encode()


def create_credential(options, fixture):
    key = serialization.load_pem_private_key(fixture["privateKey"].encode(), password=None)
    numbers = key.public_key().public_numbers()
    credential = base64.urlsafe_b64decode(fixture["credentialID"] + "==")
    cose = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: numbers.x.to_bytes(32, "big"),
                       -3: numbers.y.to_bytes(32, "big")})
    # UP + UV + attested credential. This is a software fixture, not Face ID.
    auth = hashlib.sha256(RP_ID.encode()).digest() + b"\x45" + struct.pack(">I", 0)
    auth += bytes(16) + struct.pack(">H", len(credential)) + credential + cose
    attestation = cbor2.dumps({"fmt": "none", "attStmt": {}, "authData": auth})
    data = client_data("webauthn.create", options["challenge"])
    return {"id": fixture["credentialID"], "rawId": fixture["credentialID"], "type": "public-key",
            "response": {"clientDataJSON": b64(data), "attestationObject": b64(attestation)},
            "clientExtensionResults": {}}


def assertion(options, fixture):
    fixture["signCount"] += 1
    auth = hashlib.sha256(RP_ID.encode()).digest() + b"\x05" + struct.pack(">I", fixture["signCount"])
    data = client_data("webauthn.get", options["challenge"])
    key = serialization.load_pem_private_key(fixture["privateKey"].encode(), password=None)
    signature = key.sign(auth + hashlib.sha256(data).digest(), ec.ECDSA(hashes.SHA256()))
    return {"id": fixture["credentialID"], "rawId": fixture["credentialID"], "type": "public-key",
            "response": {"clientDataJSON": b64(data), "authenticatorData": b64(auth),
                         "signature": b64(signature), "userHandle": fixture["userHandle"]},
            "clientExtensionResults": {}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("register", "assert", "export-ios", "logout"))
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--permissions", choices=("none", "account", "voice", "both", "community", "all"), default="none")
    parser.add_argument("--export", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == "register":
        if args.state.exists():
            raise RuntimeError("Refuse replacing credential fixture")
        state = {"purpose": "software-webauthn-production-validation", "createdAt": int(time.time()),
                 "fixtures": []}
    else:
        state = json.loads(args.state.read_text())
        if state.get("purpose") != "software-webauthn-production-validation" or len(state["fixtures"]) != 2:
            raise RuntimeError("Refuse non-validation identities")

    with httpx.Client(timeout=20, trust_env=False, follow_redirects=False) as client:
        def request(method, path, *, fixture=None, expected=200, payload=None):
            headers = {"Authorization": "Bearer " + fixture["session"]["token"]} if fixture else {}
            response = client.request(method, ORIGIN + PREFIX + path, headers=headers, json=payload)
            if response.status_code not in (expected if isinstance(expected, tuple) else (expected,)):
                raise RuntimeError("Unexpected HTTP status " + str(response.status_code) + " on " + path)
            return response.json() if response.content else None

        if args.action == "register":
            name = "自动验收-" + secrets.token_hex(4)
            for _ in range(2):
                key = ec.generate_private_key(ec.SECP256R1())
                fixture = {"privateKey": key.private_bytes(serialization.Encoding.PEM,
                           serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode(),
                           "credentialID": b64(secrets.token_bytes(32)), "signCount": 0, "name": name}
                options = request("POST", "/auth/registration/options", payload={})
                public = options["publicKey"]
                if public["rp"]["id"] != RP_ID:
                    raise RuntimeError("Unexpected relying party")
                fixture["userHandle"] = public["user"]["id"]
                body = {"transactionID": options["transactionID"], "credential": create_credential(public, fixture)}
                fixture["session"] = request("POST", "/auth/registration/verify", payload=body)
                fixture["accountID"] = fixture["session"]["account"]["id"]
                state["fixtures"].append(fixture)
                private_write(args.state, state)  # Record removable ID before any further network call.
                request("PATCH", "/me", fixture=fixture, payload={"name": name})
                request("POST", "/auth/registration/verify", payload=body, expected=(401, 409))
                request("DELETE", "/auth/session", fixture=fixture)
                challenge = request("POST", "/auth/authentication/options", payload={})
                body = {"transactionID": challenge["transactionID"],
                        "credential": assertion(challenge["publicKey"], fixture)}
                fixture["session"] = request("POST", "/auth/authentication/verify", payload=body)
                private_write(args.state, state)
            if state["fixtures"][0]["accountID"] == state["fixtures"][1]["accountID"]:
                raise RuntimeError("Same-name identities were merged")

        expected = {"account": args.permissions in {"account", "both", "all"},
                    "voice": args.permissions in {"voice", "both", "all"},
                    "community": args.permissions in {"community", "all"}}
        if args.action in {"register", "assert", "export-ios"}:
            for index, fixture in enumerate(state["fixtures"]):
                me = request("GET", "/me", fixture=fixture)
                wanted = {"account": False, "voice": False, "community": False} if index == 0 else expected
                if me["account"]["permissions"] != wanted or me["account"]["needsName"]:
                    raise RuntimeError("Unexpected permissions or naming state")
                fixture["session"]["account"] = me["account"]
                for service in ("account", "voice"):
                    data = request("GET", "/services/" + service + "/dashboard", fixture=fixture,
                                   expected=200 if wanted[service] else 403)
                    if wanted[service] and data["service"]["id"] != ("account" if service == "account" else "voice-lab"):
                        raise RuntimeError("Wrong dashboard source")
                request("POST", "/services/voice/moderation/query", fixture=fixture,
                        expected=200 if wanted["community"] else 403, payload={})
            private_write(args.state, state)

        if args.action == "export-ios":
            if not args.export:
                raise RuntimeError("An external private export path is required")
            private_write(args.export, {"pending": state["fixtures"][0]["session"],
                                        "authorized": state["fixtures"][1]["session"]})
        if args.action == "logout":
            for fixture in state["fixtures"]:
                request("DELETE", "/auth/session", fixture=fixture)
                request("GET", "/me", fixture=fixture, expected=401)
    print(json.dumps({"purpose": state["purpose"], "action": args.action,
                      "identities": len(state["fixtures"]), "expectedSecondPermissions": expected,
                      "credentialValuesLogged": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "errorType": type(error).__name__}))
        raise SystemExit(1)
