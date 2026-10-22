#!/usr/bin/env python3
"""Create a consistent, private data snapshot and verify an isolated restored copy.

Run as the corresponding API service user. This never replaces the live database,
starts an API, contacts Apple/LiveKit, or prints database contents or credentials.
"""
from __future__ import annotations

import argparse
from contextlib import closing, suppress
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import time

RETENTION_DAYS = 7
SERVICES = {
    "account": {"data": "/var/lib/kikitalk", "database": "kikitalk.sqlite3",
                "backups": "/var/lib/kikitalk-backups"},
    "voice": {"data": "/var/lib/kiki-livekit-lab", "database": "lab.sqlite3",
              "backups": "/var/lib/kiki-livekit-backups"},
}
SNAPSHOT_NAME = re.compile(r"snapshot-[0-9]{8}T[0-9]{12}Z")
AVATAR_NAME = re.compile(r"[a-f0-9]{64}\.jpg")
SOCIAL_MEDIA_NAME = re.compile(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\.jpg")


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def private_directory(path):
    if path.is_symlink():
        raise ValueError("Unsafe directory")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def database_check(path):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
        if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("Snapshot integrity check failed")
        if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise ValueError("Snapshot reference check failed")
        return sorted(row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))


def verify_restore(snapshot, service):
    """Copy into a disposable directory, then verify all files and DB references."""
    manifest = json.loads((snapshot / "manifest.json").read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("service") != service:
        raise ValueError("Snapshot service mismatch")
    expected_database = SERVICES[service]["database"]
    expected = manifest.get("files")
    if not isinstance(expected, dict) or expected_database not in expected:
        raise ValueError("Snapshot manifest incomplete")
    if len(expected) > 3_100_001:
        raise ValueError("Snapshot manifest exceeds limit")
    for name, checksum in expected.items():
        if (name != expected_database and not re.fullmatch(r"avatars/[a-f0-9]{64}\.jpg", name)
                and not (name.startswith("social-media/") and SOCIAL_MEDIA_NAME.fullmatch(name.removeprefix("social-media/")))
                or not isinstance(checksum, str) or not re.fullmatch(r"[a-f0-9]{64}", checksum)):
            raise ValueError("Unsafe snapshot manifest")
        if service == "voice" and name != expected_database:
            raise ValueError("Unexpected voice snapshot content")
        source = snapshot / name
        if source.is_symlink() or not source.is_file() or digest(source) != checksum:
            raise ValueError("Snapshot file validation failed")
    with tempfile.TemporaryDirectory(prefix=".restore-check-", dir=snapshot.parent) as temp:
        restored = Path(temp)
        restored.chmod(0o700)
        for name in expected:
            destination = restored / name
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(snapshot / name, destination)
            destination.chmod(0o600)
            if digest(destination) != expected[name]:
                raise ValueError("Restored copy validation failed")
        tables = database_check(restored / expected_database)
        if tables != manifest["tables"]:
            raise ValueError("Restored database schema mismatch")
        if service == "account":
            with closing(sqlite3.connect(restored / expected_database)) as db:
                for (filename,) in db.execute(
                        "SELECT DISTINCT avatar_filename FROM accounts WHERE avatar_filename IS NOT NULL"):
                    if not AVATAR_NAME.fullmatch(filename) or "avatars/" + filename not in expected:
                        raise ValueError("Restored avatar reference missing")
                if "social_media" in tables:
                    for (identifier,) in db.execute("SELECT id FROM social_media"):
                        filename = identifier + ".jpg"
                        if not SOCIAL_MEDIA_NAME.fullmatch(filename) or "social-media/" + filename not in expected:
                            raise ValueError("Restored social media reference missing")
    return len(expected)


def write_status(data_directory, value):
    path = data_directory / "backup-status.json"
    descriptor, name = tempfile.mkstemp(prefix=".backup-status-", dir=data_directory)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def create_backup(service, *, data_directory=None, backup_directory=None, now=None):
    config = SERVICES[service]
    data_directory = Path(data_directory or config["data"]).resolve()
    backup_directory = Path(backup_directory or config["backups"]).absolute()
    at = time.time() if now is None else now
    previous = {}
    try:
        previous = json.loads((data_directory / "backup-status.json").read_text())
    except (OSError, ValueError):
        pass
    stamp = datetime.fromtimestamp(at, timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    destination = backup_directory / ("snapshot-" + stamp)
    pending = backup_directory / ("." + destination.name + ".pending")
    status = {"schemaVersion": 1, "service": service, "retentionDays": RETENTION_DAYS,
              "lastSuccessAt": previous.get("lastSuccessAt"), "verifiedAt": previous.get("verifiedAt"),
              "lastAttemptAt": at, "lastError": None}
    try:
        private_directory(backup_directory)
        pending.mkdir(mode=0o700)
        source_path = data_directory / config["database"]
        if not source_path.is_file() or source_path.is_symlink():
            raise ValueError("Live database unavailable")
        files = {}
        # A second read connection allows SQLite backup while the first connection
        # holds a writer reservation across DB and avatar copying.
        with closing(sqlite3.connect(source_path, timeout=10)) as lock, lock:
            lock.execute("PRAGMA busy_timeout=10000")
            lock.execute("BEGIN IMMEDIATE")
            with closing(sqlite3.connect(source_path)) as source:
                with closing(sqlite3.connect(pending / config["database"])) as target, target:
                    source.backup(target)
            (pending / config["database"]).chmod(0o600)
            if service == "account":
                (pending / "avatars").mkdir(mode=0o700)
                for (filename,) in lock.execute(
                        "SELECT DISTINCT avatar_filename FROM accounts WHERE avatar_filename IS NOT NULL"):
                    if not AVATAR_NAME.fullmatch(filename):
                        raise ValueError("Unsafe avatar reference")
                    avatar = data_directory / "avatars" / filename
                    if avatar.is_symlink() or not avatar.is_file():
                        raise ValueError("Avatar snapshot unavailable")
                    copied = pending / "avatars" / filename
                    shutil.copyfile(avatar, copied)
                    copied.chmod(0o600)
                    files["avatars/" + filename] = digest(copied)
                if lock.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='social_media'").fetchone():
                    (pending / "social-media").mkdir(mode=0o700)
                    for (identifier,) in lock.execute("SELECT id FROM social_media"):
                        filename = identifier + ".jpg"
                        if not SOCIAL_MEDIA_NAME.fullmatch(filename):
                            raise ValueError("Unsafe social media reference")
                        media = data_directory / "social-media" / filename
                        if media.is_symlink() or not media.is_file():
                            raise ValueError("Social media snapshot unavailable")
                        copied = pending / "social-media" / filename
                        shutil.copyfile(media, copied); copied.chmod(0o600)
                        files["social-media/" + filename] = digest(copied)
        database = pending / config["database"]
        files[config["database"]] = digest(database)
        manifest = {"schemaVersion": 1, "service": service, "createdAt": at,
                    "files": files, "tables": database_check(database)}
        (pending / "manifest.json").write_text(json.dumps(manifest, separators=(",", ":")))
        (pending / "manifest.json").chmod(0o600)
        verify_restore(pending, service)
        pending.rename(destination)
        status.update(lastSuccessAt=at, verifiedAt=at)
        # Delete only snapshots created by this script after a new verified success.
        for path in backup_directory.iterdir():
            if (SNAPSHOT_NAME.fullmatch(path.name) and path.is_dir() and not path.is_symlink()
                    and path != destination):
                created = datetime.strptime(path.name.removeprefix("snapshot-"), "%Y%m%dT%H%M%S%fZ").replace(tzinfo=timezone.utc).timestamp()
                if created < at - RETENTION_DAYS * 86400:
                    shutil.rmtree(path)
        write_status(data_directory, status)
        return status
    except Exception:
        with suppress(OSError):
            if pending.is_dir() and not pending.is_symlink():
                shutil.rmtree(pending)
        status["lastError"] = "备份或副本恢复校验失败，请检查维护日志。"
        write_status(data_directory, status)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=SERVICES)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        create_backup(args.service)
    except Exception:
        print("备份或副本恢复校验失败；状态已记录，未覆盖在线数据。")
        return 1
    print("一致性备份与隔离副本恢复校验完成，保留 7 天；在线数据未替换。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
