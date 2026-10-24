#!/usr/bin/env python3
"""Offline, repeatable upgrade for databases from before feed removal.

Run against an existing database after a verified backup and while the API is
stopped, including after restoring an older database. No rows or legacy columns
are removed. The online application never imports this maintenance module.
"""
import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3


def retire_legacy_notifications(db):
    """Apply the additive upgrade inside the caller's database transaction."""
    columns = {row[1] for row in db.execute("PRAGMA table_info(social_notifications)")}
    result = {"tablePresent": bool(columns), "columnAdded": False, "notificationsMarked": 0}
    if not columns:
        # A fresh database will get the current schema when the API starts.
        return result
    if "is_retired" not in columns:
        db.execute("ALTER TABLE social_notifications ADD COLUMN is_retired INTEGER NOT NULL DEFAULT 0 CHECK(is_retired IN (0,1))")
        result["columnAdded"] = True
    if "moment_id" in columns:
        result["notificationsMarked"] = db.execute(
            "UPDATE social_notifications SET is_retired=1 WHERE moment_id IS NOT NULL AND is_retired!=1"
        ).rowcount
    return result


def migrate_database(path):
    path = Path(path).resolve(strict=True)
    if not path.is_file():
        raise ValueError("An existing SQLite database file is required")
    # mode=rw prevents a misspelled production path from creating a new database.
    with closing(sqlite3.connect(path.as_uri() + "?mode=rw", uri=True, timeout=10)) as db, db:
        db.execute("BEGIN IMMEDIATE")
        result = retire_legacy_notifications(db)
        if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("Database integrity check failed")
    return {"database": str(path), **result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True, help="Existing account SQLite database; stop the API first")
    arguments = parser.parse_args()
    print(json.dumps(migrate_database(arguments.database), sort_keys=True))
