#!/usr/bin/env python3
"""Check KikiTalk's source and packaged export declaration before uploading.

Current scope: standard system/WebRTC encryption, no proprietary algorithms,
and France excluded from distribution (confirmed by the owner). Reassess the
declaration when encryption dependencies, use, or distribution territories change.
"""
import argparse
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ios/KikiTalk/Configuration/Info.plist"
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
    parser.add_argument("--app", type=Path, help="Final KikiTalk.app inside the archive")
    args = parser.parse_args()
    verify(SOURCE)
    result = {"sourceVerified": True, KEY: False, "packagedAppVerified": False}
    if args.app:
        app = args.app.resolve()
        info = verify(app / "Info.plist")
        if info.get("CFBundleIdentifier") != "com.kikitalk.demo":
            raise SystemExit("Refusing to validate a different application target")
        result.update(packagedAppVerified=True,
                      version=info.get("CFBundleShortVersionString"),
                      build=info.get("CFBundleVersion"))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
