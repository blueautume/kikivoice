#!/usr/bin/env bash
# Creates a consistent SQLite and avatar snapshot, without stopping API.
set -euo pipefail
ssh -i "${KIKI_SSH_IDENTITY:-$HOME/.ssh/kikitalk_server.pem}" \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=${KIKI_KNOWN_HOSTS:-$HOME/.ssh/kikitalk_known_hosts}" \
  "root@${KIKI_SERVER_HOST:-43.138.219.160}" 'umask 077; python3 -' <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import re
import shutil
import sqlite3

directory = Path("/var/backups/kikitalk")
directory.mkdir(mode=0o700, parents=True, exist_ok=True)
destination = directory / ("kikitalk-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
pending = directory / ("." + destination.name + ".pending")
pending.mkdir(mode=0o700)
try:
    # Hold the writer lock across both snapshots. API reads remain available;
    # profile/room writes wait briefly, so an avatar cannot be replaced midway.
    with sqlite3.connect("/var/lib/kikitalk/kikitalk.sqlite3", timeout=10) as lock:
        lock.execute("BEGIN IMMEDIATE")
        with sqlite3.connect("/var/lib/kikitalk/kikitalk.sqlite3") as source:
            with sqlite3.connect(pending / "kikitalk.sqlite3") as target:
                source.backup(target)
        (pending / "kikitalk.sqlite3").chmod(0o600)
        avatar_directory = pending / "avatars"
        avatar_directory.mkdir(mode=0o700)
        columns = {row[1] for row in lock.execute("PRAGMA table_info(accounts)")}
        if "avatar_filename" in columns:
            for (filename,) in lock.execute("SELECT DISTINCT avatar_filename FROM accounts WHERE avatar_filename IS NOT NULL"):
                if not re.fullmatch(r"[a-f0-9]{64}\.jpg", filename):
                    raise RuntimeError("Invalid avatar filename in database")
                shutil.copy2(Path("/var/lib/kikitalk/avatars") / filename, avatar_directory / filename)
                (avatar_directory / filename).chmod(0o600)
    pending.rename(destination)
except Exception:
    shutil.rmtree(pending)
    raise
print("数据库与头像备份已保存：" + str(destination))
PY
