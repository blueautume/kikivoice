"""Reusable public profile numbers, separate from permanent account identities.

Only these display numbers may be reused after account deletion. Login, SDK and
account IDs remain random, permanent identities for all relationships and data.
"""

from fastapi import HTTPException

MAX_PUBLIC_NUMBER = 999999
NUMBER_CONSTRAINT = "public_number IS NULL OR (typeof(public_number)='integer' AND public_number BETWEEN 1 AND 999999)"


def display_id(row):
    number = row["public_number"] if "public_number" in row.keys() else None
    return f"kiki_{number:06d}" if number is not None else row["login_id"]


def assign(db, account_id):
    """Assign the lowest free number inside the caller's immediate transaction."""
    if not db.in_transaction:
        raise RuntimeError("Public number allocation requires a write transaction")
    row = db.execute("SELECT public_number FROM accounts WHERE account_id=?", (account_id,)).fetchone()
    if row is None:
        raise ValueError("Account does not exist")
    if row[0] is not None:
        return row[0]
    available = db.execute("""SELECT candidate FROM (
        SELECT 1 AS candidate UNION ALL
        SELECT public_number+1 FROM accounts
        WHERE public_number IS NOT NULL AND public_number<?
      ) WHERE NOT EXISTS(SELECT 1 FROM accounts WHERE public_number=candidate)
      ORDER BY candidate LIMIT 1""", (MAX_PUBLIC_NUMBER,)).fetchone()
    if available is None:
        raise HTTPException(503, "账号号码已用完，暂时无法注册")
    number = available[0]
    db.execute("UPDATE accounts SET public_number=? WHERE account_id=?", (number, account_id))
    return number


def initialize(db):
    """Backfill surviving accounts once, preserving every previously assigned ID."""
    # A write lock also serializes two API workers performing a first upgrade.
    if not db.in_transaction:
        db.execute("BEGIN IMMEDIATE")
    columns = {row[1] for row in db.execute("PRAGMA table_info(accounts)")}
    if "public_number" not in columns:
        db.execute(f"ALTER TABLE accounts ADD COLUMN public_number INTEGER CHECK({NUMBER_CONSTRAINT})")
    db.execute("CREATE UNIQUE INDEX IF NOT EXISTS account_public_number ON accounts(public_number) WHERE public_number IS NOT NULL")
    accounts = db.execute("SELECT account_id FROM accounts WHERE public_number IS NULL ORDER BY created_at,account_id").fetchall()
    # One pass makes a first deployment linear in the number of existing users.
    # The same transaction preserves old assignments if this is a later restart.
    occupied = {row[0] for row in db.execute("SELECT public_number FROM accounts WHERE public_number IS NOT NULL")}
    candidate = 1
    for account in accounts:
        while candidate in occupied:
            candidate += 1
        if candidate > MAX_PUBLIC_NUMBER:
            raise HTTPException(503, "账号号码已用完，暂时无法注册")
        db.execute("UPDATE accounts SET public_number=? WHERE account_id=?", (candidate, account[0]))
        candidate += 1
