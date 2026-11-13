#!/usr/bin/env python3
"""Check a Kiki application's source and packaged declaration before uploading.

KikiTalk uses standard system/WebRTC encryption, no proprietary algorithms,
with France excluded from distribution (confirmed by the owner).
KikiVoiceOps uses only Apple system networking and Passkey cryptography.
Reassess the declaration when encryption dependencies, use, or territories change.
"""
import argparse
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {"KikiTalk": "com.kikitalk.demo", "KikiVoiceOps": "com.kikitalk.voiceops"}
KEY = "ITSAppUsesNonExemptEncryption"


def verify(path):
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    if KEY not in info or type(info[KEY]) is not bool:
        raise SystemExit(f"{path}: {KEY} must be an explicit Boolean")
    if info[KEY] is not False:
        raise SystemExit(f"{path}: export declaration changed; reassess it before uploading")
    if info.get("ITSEncryptionExportComplianceCode"):
        raise SystemExit(f"{path}: unexpected compliance code for the current declaration; review it")
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, default="KikiTalk")
    parser.add_argument("--app", type=Path, help="Final application inside the archive")
    args = parser.parse_args()
    verify(ROOT / "ios" / args.target / "Configuration/Info.plist")
    result = {"target": args.target, "sourceVerified": True, KEY: False, "packagedAppVerified": False}
    if args.app:
        app = args.app.resolve()
        info = verify(app / "Info.plist")
        if info.get("CFBundleIdentifier") != TARGETS[args.target]:
            raise SystemExit("Refusing to validate a different application target")
        result.update(packagedAppVerified=True,
                      version=info.get("CFBundleShortVersionString"),
                      build=info.get("CFBundleVersion"))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
