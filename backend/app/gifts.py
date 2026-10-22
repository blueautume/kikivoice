"""Free, server-priced gifts. No recharge, cash balance or recipient earnings."""

import hashlib
import json
import re
import time
import uuid

from fastapi import Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field, field_validator

INITIAL_DIAMONDS = 100_000_000
GIFT_EVENT_SECONDS = 7 * 86400
MAX_GIFT_EVENTS = 100_000
NOTICE_VERSION = "2026-10-18"
MAX_RECIPIENTS = 50
GIFTS = (
    {"id": "heart", "name": "初见心动", "price": 1, "animationAsset": "heart.gif", "effectTier": 1, "durationMilliseconds": 1500},
    {"id": "flower_rain", "name": "星光花雨", "price": 99, "animationAsset": "flower_rain.gif", "effectTier": 2, "durationMilliseconds": 2200},
    {"id": "aurora_car", "name": "极光跑车", "price": 999, "animationAsset": "aurora_car.gif", "effectTier": 3, "durationMilliseconds": 2800},
    {"id": "galaxy_rocket", "name": "星河火箭", "price": 4999, "animationAsset": "galaxy_rocket.gif", "effectTier": 4, "durationMilliseconds": 3200},
    {"id": "cosmic_heart", "name": "宇宙之心", "price": 10000, "animationAsset": "cosmic_heart.gif", "effectTier": 5, "durationMilliseconds": 4000},
)
CATALOG = {gift["id"]: gift for gift in GIFTS}

SCHEMA = """
CREATE TABLE IF NOT EXISTS gift_wallets (
  account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  balance INTEGER NOT NULL CHECK(balance>=0),
  created_at INTEGER NOT NULL
);
-- Economic entries are append-only. Only account deletion removes them; editing
-- a profile never changes amounts, prices, request IDs or balances in the ledger.
CREATE TABLE IF NOT EXISTS gift_wallet_entries (
  entry_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  request_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('initial_grant','gift')),
  amount INTEGER NOT NULL,
  balance_after INTEGER NOT NULL CHECK(balance_after>=0),
  room_id TEXT,
  gift_id TEXT,
  quantity INTEGER,
  unit_price INTEGER,
  recipient_account_id TEXT REFERENCES accounts(account_id) ON DELETE SET NULL,
  event_id TEXT,
  event_sequence INTEGER,
  notice_version TEXT,
  delivery_mode TEXT NOT NULL DEFAULT 'single',
  recipient_set_hash TEXT,
  created_at INTEGER NOT NULL,
  UNIQUE(account_id,request_id)
);
CREATE INDEX IF NOT EXISTS gift_wallet_account ON gift_wallet_entries(account_id,created_at DESC);
CREATE INDEX IF NOT EXISTS gift_wallet_recipient ON gift_wallet_entries(recipient_account_id);
-- A batch is one debit with durable child deliveries. No profile snapshot or
-- SDK ID is retained here; deletion detaches only the relevant recipient.
CREATE TABLE IF NOT EXISTS gift_batch_recipients (
  entry_id TEXT NOT NULL REFERENCES gift_wallet_entries(entry_id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  recipient_account_id TEXT REFERENCES accounts(account_id) ON DELETE SET NULL,
  event_id TEXT NOT NULL UNIQUE,
  event_sequence INTEGER NOT NULL,
  PRIMARY KEY(entry_id,position)
);
CREATE INDEX IF NOT EXISTS gift_batch_recipient ON gift_batch_recipients(recipient_account_id);
-- Public event data contains no copied names, avatars, Apple IDs or login IDs.
-- Profiles are resolved on read; deleting either participant deletes the event.
CREATE TABLE IF NOT EXISTS room_gift_events (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  sender_account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  recipient_account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  gift_id TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  unit_price INTEGER NOT NULL,
  total_cost INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS gift_events_room_sequence ON room_gift_events(room_id,sequence);
CREATE INDEX IF NOT EXISTS gift_events_created_at ON room_gift_events(created_at);
CREATE INDEX IF NOT EXISTS gift_events_sender ON room_gift_events(sender_account_id);
CREATE INDEX IF NOT EXISTS gift_events_recipient ON room_gift_events(recipient_account_id);
"""


class GiftSend(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    giftID: str = Field(min_length=1, max_length=40)
    quantity: int = Field(strict=True, ge=1, le=99)
    requestID: uuid.UUID
    noticeVersion: str = Field(min_length=1, max_length=32)

    @field_validator("quantity")
    @classmethod
    def allowed_quantity(cls, value):
        if value not in (1, 10, 99):
            raise ValueError("赠送数量仅支持1、10或99")
        return value


class GiftBatchSend(GiftSend):
    recipientIDs: list[str] = Field(min_length=1, max_length=MAX_RECIPIENTS, strict=True)

    @field_validator("recipientIDs", mode="before")
    @classmethod
    def allowed_recipients(cls, value):
        if not isinstance(value, list) or any(not isinstance(item, str) or
                re.fullmatch(r"[A-Za-z0-9_]{1,128}", item) is None for item in value):
            raise ValueError("收礼人ID格式不正确")
        if len(set(value)) != len(value):
            raise ValueError("收礼人不能重复")
        return value


def recipient_set_hash(recipient_ids):
    # Retain a stable equality check after a recipient deletes their account,
    # without retaining the recipient's public SDK ID in an economic record.
    return hashlib.sha256(json.dumps(sorted(recipient_ids), separators=(",", ":")).encode()).hexdigest()


def initialize_wallet(db, account_id, now=None):
    now = int(time.time()) if now is None else now
    inserted = db.execute("INSERT OR IGNORE INTO gift_wallets VALUES(?,?,?)",
                          (account_id, INITIAL_DIAMONDS, now)).rowcount
    if inserted:
        db.execute("""INSERT INTO gift_wallet_entries
            (entry_id,account_id,request_id,kind,amount,balance_after,created_at)
            VALUES(?,?,?,'initial_grant',?,?,?)""",
            (uuid.uuid4().hex, account_id, "initial-grant", INITIAL_DIAMONDS, INITIAL_DIAMONDS, now))


def migrate_wallets(db):
    columns = {row["name"] for row in db.execute("PRAGMA table_info(gift_wallet_entries)")}
    if "notice_version" not in columns:
        db.execute("ALTER TABLE gift_wallet_entries ADD COLUMN notice_version TEXT")
    if "delivery_mode" not in columns:
        db.execute("ALTER TABLE gift_wallet_entries ADD COLUMN delivery_mode TEXT NOT NULL DEFAULT 'single'")
    if "recipient_set_hash" not in columns:
        db.execute("ALTER TABLE gift_wallet_entries ADD COLUMN recipient_set_hash TEXT")
    for row in db.execute("SELECT account_id FROM accounts").fetchall():
        initialize_wallet(db, row["account_id"])


def purge_gift_events(db, now):
    db.execute("DELETE FROM room_gift_events WHERE created_at<=?", (now - GIFT_EVENT_SECONDS,))
    # A fixed ceiling also bounds storage during a burst, rather than relying on
    # age alone. Ledger entries remain available for idempotency after event TTL.
    latest = db.execute("SELECT MAX(sequence) FROM room_gift_events").fetchone()[0]
    if latest is not None and latest > MAX_GIFT_EVENTS:
        db.execute("DELETE FROM room_gift_events WHERE sequence<=?", (latest - MAX_GIFT_EVENTS,))


def install_routes(app, settings, *, database, consented_user, require_active_session,
                   require_nickname, avatar_url, find_room, limits):
    def wallet(db, account_id):
        initialize_wallet(db, account_id)
        row = db.execute("SELECT balance FROM gift_wallets WHERE account_id=?", (account_id,)).fetchone()
        return {"balance": row["balance"], "currency": "diamond", "initialGrant": INITIAL_DIAMONDS}

    def live_room(db, room_id):
        room = find_room(db, room_id)
        if room["status"] != "live" or not room["owner_id"]:
            raise HTTPException(409, "房间已结束或尚未开启，暂时不能赠送礼物")
        recipient = db.execute("SELECT * FROM accounts WHERE account_id=?", (room["owner_id"],)).fetchone()
        if recipient is None:
            raise HTTPException(409, "房主账号已不可用")
        return room, recipient

    def profile(db, account_id):
        return db.execute("SELECT * FROM accounts WHERE account_id=?", (account_id,)).fetchone() if account_id else None

    def event_response(db, row, *, ledger=False, batch=None):
        sender = profile(db, row["account_id"] if ledger else row["sender_account_id"])
        recipient = profile(db, row["recipient_account_id"])
        gift = CATALOG.get(row["gift_id"])
        result = {"sequence": row["event_sequence"] if ledger else row["sequence"], "id": row["event_id"],
                "giftID": row["gift_id"], "giftName": gift["name"] if gift else "礼物",
                "unitPrice": row["unit_price"], "quantity": row["quantity"],
                "totalCost": -row["amount"] if ledger else row["total_cost"],
                "senderID": sender["sdk_user_id"] if sender else "", "senderName": sender["name"] if sender else "已注销用户",
                "senderAvatarIndex": sender["avatar_index"] if sender else 0,
                "senderAvatarURL": avatar_url(sender["avatar_filename"], settings) if sender else None,
                "recipientID": recipient["sdk_user_id"] if recipient else "",
                "recipientName": recipient["name"] if recipient else "已注销用户", "createdAt": row["created_at"]}
        if batch:
            result.update(batchID=batch["entry_id"], batchRecipientCount=batch["recipient_count"])
        return result

    def event_batch_metadata(db, rows):
        if not rows:
            return {}
        placeholders = ",".join("?" for _ in rows)
        # Resolve the entire page together. Each matching batch is counted once
        # through the (entry_id,position) primary key, including detached users.
        batches = db.execute(f"""WITH matched AS (
                SELECT event_id,entry_id FROM gift_batch_recipients WHERE event_id IN ({placeholders})
            ), counts AS (
                SELECT entry_id,COUNT(*) AS recipient_count FROM gift_batch_recipients
                WHERE entry_id IN (SELECT DISTINCT entry_id FROM matched) GROUP BY entry_id
            ) SELECT matched.event_id,matched.entry_id,counts.recipient_count
              FROM matched JOIN counts ON counts.entry_id=matched.entry_id""",
            tuple(row["event_id"] for row in rows)).fetchall()
        return {batch["event_id"]: batch for batch in batches}

    def batch_response(db, entry, account_id):
        children = db.execute("SELECT * FROM gift_batch_recipients WHERE entry_id=? ORDER BY position",
                              (entry["entry_id"],)).fetchall()
        events = []
        for child in children:
            delivery = dict(entry)
            delivery.update(recipient_account_id=child["recipient_account_id"], event_id=child["event_id"],
                            event_sequence=child["event_sequence"], amount=-entry["unit_price"] * entry["quantity"])
            events.append(event_response(db, delivery, ledger=True,
                                         batch={"entry_id": entry["entry_id"], "recipient_count": len(children)}))
        return {"events": events, "wallet": wallet(db, account_id), "totalCost": -entry["amount"],
                "recipientCount": len(children), "quantityPerRecipient": entry["quantity"]}

    @app.get("/v1/gifts/catalog")
    def catalog(user=Depends(consented_user)):
        return {"gifts": list(GIFTS), "currency": "diamond", "initialBalance": INITIAL_DIAMONDS,
                "notice": {"version": NOTICE_VERSION, "title": "免费礼物体验说明",
                           "text": "每个账号一次性获赠1亿免费体验钻石，可在房内选择一位或多位成员赠送礼物，也可赠送给自己。每次最多选择50人，数量为每人获赠数量，总价为礼物单价×每人数量×人数。钻石及礼物不可购买、转让、提现或兑换现金，收礼方不会获得收益。赠送按服务端价格扣除钻石，昵称、头像、礼物及数量对同房成员可见。房间礼物动态最多保留7天，钱包收支及重复请求处理账目保留至账号注销。注销删除个人关联数据，历史备份按隐私政策处理。",
                           "url": settings.public_base_url.rstrip("/") + "/gifts/notice/"}}

    @app.get("/v1/me/wallet")
    def get_wallet(user=Depends(consented_user)):
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            return wallet(db, user["account_id"])

    @app.post("/v1/rooms/{room_id}/gifts")
    def send_gift(room_id: str, payload: GiftSend, user=Depends(consented_user)):
        if payload.noticeVersion != NOTICE_VERSION:
            raise HTTPException(412, "请先阅读并确认当前版本的免费礼物体验说明")
        gift = CATALOG.get(payload.giftID)
        if gift is None:
            raise HTTPException(404, "该礼物暂不可用，请刷新礼物列表")
        request_id = str(payload.requestID)
        if settings.rate_limit_enabled:
            limits.check(("gift_send", user["account_id"]), 30, 10)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            current = profile(db, user["account_id"])
            require_nickname(current)
            previous = db.execute("SELECT * FROM gift_wallet_entries WHERE account_id=? AND request_id=?",
                                  (user["account_id"], request_id)).fetchone()
            if previous:
                if previous["delivery_mode"] != "single" or previous["room_id"] != room_id or previous["gift_id"] != payload.giftID or previous["quantity"] != payload.quantity:
                    raise HTTPException(409, "同一次赠送请求的内容不能修改，请重新发起赠送")
                return {"event": event_response(db, previous, ledger=True), "wallet": wallet(db, user["account_id"])}
            room, recipient = live_room(db, room_id)
            now = int(time.time())
            initialize_wallet(db, user["account_id"], now)
            total = gift["price"] * payload.quantity
            updated = db.execute("UPDATE gift_wallets SET balance=balance-? WHERE account_id=? AND balance>=?",
                                 (total, user["account_id"], total)).rowcount
            if not updated:
                raise HTTPException(402, "钻石余额不足，无法赠送该礼物")
            balance = db.execute("SELECT balance FROM gift_wallets WHERE account_id=?", (user["account_id"],)).fetchone()["balance"]
            event_id = str(uuid.uuid4())
            inserted = db.execute("""INSERT INTO room_gift_events
                (event_id,room_id,sender_account_id,recipient_account_id,gift_id,quantity,unit_price,total_cost,created_at)
                VALUES(?,?,?,?,?,?,?,?,?)""", (event_id, room_id, user["account_id"], recipient["account_id"],
                    payload.giftID, payload.quantity, gift["price"], total, now))
            sequence = inserted.lastrowid
            db.execute("""INSERT INTO gift_wallet_entries
                (entry_id,account_id,request_id,kind,amount,balance_after,room_id,gift_id,quantity,unit_price,
                 recipient_account_id,event_id,event_sequence,notice_version,created_at) VALUES(?,?,?,'gift',?,?,?,?,?,?,?,?,?,?,?)""",
                (uuid.uuid4().hex, user["account_id"], request_id, -total, balance, room_id, payload.giftID,
                 payload.quantity, gift["price"], recipient["account_id"], event_id, sequence, NOTICE_VERSION, now))
            entry = db.execute("SELECT * FROM gift_wallet_entries WHERE account_id=? AND request_id=?",
                               (user["account_id"], request_id)).fetchone()
            result = {"event": event_response(db, entry, ledger=True), "wallet": wallet(db, user["account_id"])}
            purge_gift_events(db, now)
            return result

    @app.post("/v1/rooms/{room_id}/gifts/batch")
    def send_gift_batch(room_id: str, payload: GiftBatchSend, user=Depends(consented_user)):
        if payload.noticeVersion != NOTICE_VERSION:
            raise HTTPException(412, "请先阅读并确认当前版本的免费礼物体验说明")
        gift = CATALOG.get(payload.giftID)
        if gift is None:
            raise HTTPException(404, "该礼物暂不可用，请刷新礼物列表")
        request_id = str(payload.requestID)
        target_hash = recipient_set_hash(payload.recipientIDs)
        if settings.rate_limit_enabled:
            limits.check(("gift_send", user["account_id"]), 30, 10)
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            current = profile(db, user["account_id"])
            require_nickname(current)
            previous = db.execute("SELECT * FROM gift_wallet_entries WHERE account_id=? AND request_id=?",
                                  (user["account_id"], request_id)).fetchone()
            if previous:
                if (previous["delivery_mode"] != "batch" or previous["room_id"] != room_id or
                        previous["gift_id"] != payload.giftID or previous["quantity"] != payload.quantity or
                        previous["recipient_set_hash"] != target_hash):
                    raise HTTPException(409, "同一次赠送请求的内容不能修改，请重新发起赠送")
                return batch_response(db, previous, user["account_id"])
            room, _ = live_room(db, room_id)
            placeholders = ",".join("?" for _ in payload.recipientIDs)
            recipients = db.execute(f"""SELECT a.* FROM accounts a WHERE a.sdk_user_id IN ({placeholders})
                AND a.needs_nickname=0 AND (a.account_id=? OR EXISTS
                    (SELECT 1 FROM history h WHERE h.account_id=a.account_id AND h.room_id=?))""",
                (*payload.recipientIDs, room["owner_id"], room_id)).fetchall()
            # SDK membership supplies the client selection list. History is only
            # a durable room-association check, never proof of current presence.
            if len(recipients) != len(payload.recipientIDs):
                raise HTTPException(409, "部分收礼人已不可用或尚未进入过该房间，请刷新收礼人列表")
            by_sdk_id = {recipient["sdk_user_id"]: recipient for recipient in recipients}
            now = int(time.time())
            initialize_wallet(db, user["account_id"], now)
            per_recipient_cost = gift["price"] * payload.quantity
            total = per_recipient_cost * len(recipients)
            updated = db.execute("UPDATE gift_wallets SET balance=balance-? WHERE account_id=? AND balance>=?",
                                 (total, user["account_id"], total)).rowcount
            if not updated:
                raise HTTPException(402, "钻石余额不足，无法赠送该礼物")
            balance = db.execute("SELECT balance FROM gift_wallets WHERE account_id=?", (user["account_id"],)).fetchone()["balance"]
            entry_id = uuid.uuid4().hex
            db.execute("""INSERT INTO gift_wallet_entries
                (entry_id,account_id,request_id,kind,amount,balance_after,room_id,gift_id,quantity,unit_price,
                 notice_version,delivery_mode,recipient_set_hash,created_at)
                VALUES(?,?,?,'gift',?,?,?,?,?,?,?,'batch',?,?)""",
                (entry_id, user["account_id"], request_id, -total, balance, room_id, payload.giftID,
                 payload.quantity, gift["price"], NOTICE_VERSION, target_hash, now))
            # Sorted SDK IDs produce deterministic event ordering regardless of
            # chip selection order or retry order, while charging just once.
            for position, sdk_id in enumerate(sorted(payload.recipientIDs)):
                recipient = by_sdk_id[sdk_id]
                event_id = str(uuid.uuid4())
                inserted = db.execute("""INSERT INTO room_gift_events
                    (event_id,room_id,sender_account_id,recipient_account_id,gift_id,quantity,unit_price,total_cost,created_at)
                    VALUES(?,?,?,?,?,?,?,?,?)""", (event_id, room_id, user["account_id"], recipient["account_id"],
                        payload.giftID, payload.quantity, gift["price"], per_recipient_cost, now))
                db.execute("INSERT INTO gift_batch_recipients VALUES(?,?,?,?,?)",
                           (entry_id, position, recipient["account_id"], event_id, inserted.lastrowid))
            entry = db.execute("SELECT * FROM gift_wallet_entries WHERE entry_id=?", (entry_id,)).fetchone()
            result = batch_response(db, entry, user["account_id"])
            purge_gift_events(db, now)
            return result

    @app.get("/v1/rooms/{room_id}/gifts")
    def room_events(room_id: str, after: int | None = Query(default=None, ge=0, le=2**63-1),
                    limit: int = Query(default=30, ge=1, le=50), user=Depends(consented_user)):
        with database(settings) as db:
            require_active_session(db, user)
            require_nickname(user)
            find_room(db, room_id)
            # Global AUTOINCREMENT survives pruning, so empty rooms and expired
            # histories can still advance their cursor without replaying events.
            last = db.execute("SELECT seq FROM sqlite_sequence WHERE name='room_gift_events'").fetchone()
            latest = last["seq"] if last else 0
            if after is None:
                return {"events": [], "nextCursor": latest, "hasMore": False}
            rows = db.execute("""SELECT * FROM room_gift_events WHERE room_id=? AND sequence>? AND created_at>?
                ORDER BY sequence LIMIT ?""", (room_id, after, int(time.time()) - GIFT_EVENT_SECONDS, limit + 1)).fetchall()
            more = len(rows) > limit
            rows = rows[:limit]
            next_cursor = rows[-1]["sequence"] if rows else max(after, latest)
            batches = event_batch_metadata(db, rows)
            return {"events": [event_response(db, row, batch=batches.get(row["event_id"])) for row in rows],
                    "nextCursor": next_cursor, "hasMore": more}
