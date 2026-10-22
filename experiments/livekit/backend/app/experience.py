"""Free experience diamonds, authoritative room gifts and permanent decorations.

All calls run under the application's database lock. Mutations and their retry
records share one SQLite transaction; clients never provide prices or balances.
"""
from dataclasses import dataclass
import hashlib
import json
import re
import time
from typing import Literal
import uuid

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

INITIAL_DIAMONDS = 100_000_000
STARTER_GIFT_PACK = {"heart": 10, "flower_rain": 3, "aurora_car": 1}
STARTER_GIFT_GRANT_ID = "experience-starter-v1"
MAX_RECIPIENTS = 50
EVENT_RETENTION_SECONDS = 2 * 3600
EVENT_WINDOW_SIZE = 1000
DecorationKind = Literal["avatarFrame", "micEffect", "chatBubble", "roomBackground"]
KINDS = ("avatarFrame", "micEffect", "chatBubble", "roomBackground")
GIFTS = tuple({"id": identifier, "name": name, "price": price,
               "animationAsset": identifier + ".gif", "posterAsset": identifier + ".png"}
              for identifier, name, price in (
                  ("heart", "初见心动", 1), ("flower_rain", "星光花雨", 99),
                  ("aurora_car", "极光跑车", 999), ("galaxy_rocket", "星河火箭", 4999),
                  ("cosmic_heart", "宇宙之心", 10000)))
DECORATIONS = tuple({"id": f"{prefix}_{style}", "name": f"{label} · {kind_name}",
                     "summary": summary, "style": style, "kind": kind, "price": price}
                    for kind, prefix, kind_name, summary in (
                        ("avatarFrame", "frame", "头像框", "为头像添上一圈专属光彩"),
                        ("micEffect", "mic", "麦位光效", "开口说话时点亮你的麦位"),
                        ("chatBubble", "bubble", "聊天气泡", "让房间里的每句话更有个性"),
                        ("roomBackground", "background", "房间背景", "为你创建的房间换一种氛围"))
                    for style, label, price in (("violet", "紫色星轨", 1999),
                                                ("aurora", "极光流彩", 4999),
                                                ("gold", "鎏金星辉", 9999)))
GIFT_CATALOG = {item["id"]: item for item in GIFTS}
DECORATION_CATALOG = {item["id"]: item for item in DECORATIONS}


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS experience_wallets (
        user_id TEXT PRIMARY KEY REFERENCES users(id), balance INTEGER NOT NULL CHECK(balance>=0),
        created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS experience_entries (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
        kind TEXT NOT NULL CHECK(kind IN ('initial_grant','gift','decoration')),
        title TEXT NOT NULL, amount INTEGER NOT NULL,
        balance_after INTEGER NOT NULL CHECK(balance_after>=0), created_at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS experience_entries_user ON experience_entries(user_id,created_at DESC);
    CREATE TABLE IF NOT EXISTS experience_requests (
        user_id TEXT NOT NULL REFERENCES users(id), request_id TEXT NOT NULL,
        payload_hash TEXT NOT NULL, kind TEXT NOT NULL, total_cost INTEGER NOT NULL,
        batch_id TEXT, created_at INTEGER NOT NULL, PRIMARY KEY(user_id,request_id));
    CREATE TABLE IF NOT EXISTS experience_gift_inventory (
        user_id TEXT NOT NULL REFERENCES users(id), gift_id TEXT NOT NULL,
        quantity INTEGER NOT NULL CHECK(quantity>=0), PRIMARY KEY(user_id,gift_id));
    CREATE TABLE IF NOT EXISTS experience_gift_grants (
        user_id TEXT NOT NULL REFERENCES users(id), grant_id TEXT NOT NULL,
        created_at INTEGER NOT NULL, PRIMARY KEY(user_id,grant_id));
    CREATE TABLE IF NOT EXISTS experience_gift_settlements (
        user_id TEXT NOT NULL, request_id TEXT NOT NULL,
        inventory_used INTEGER NOT NULL CHECK(inventory_used>=0),
        diamond_quantity INTEGER NOT NULL CHECK(diamond_quantity>=0),
        total_quantity INTEGER NOT NULL CHECK(total_quantity>0),
        PRIMARY KEY(user_id,request_id),
        FOREIGN KEY(user_id,request_id) REFERENCES experience_requests(user_id,request_id),
        CHECK(inventory_used+diamond_quantity=total_quantity));
    CREATE TABLE IF NOT EXISTS experience_inventory (
        user_id TEXT NOT NULL REFERENCES users(id), decoration_id TEXT NOT NULL,
        created_at INTEGER NOT NULL, PRIMARY KEY(user_id,decoration_id));
    CREATE TABLE IF NOT EXISTS experience_equipped (
        user_id TEXT NOT NULL REFERENCES users(id), kind TEXT NOT NULL,
        decoration_id TEXT NOT NULL, PRIMARY KEY(user_id,kind));
    CREATE TABLE IF NOT EXISTS experience_gift_events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        room_id TEXT NOT NULL REFERENCES rooms(id), batch_id TEXT NOT NULL,
        sender_user_id TEXT NOT NULL REFERENCES users(id),
        recipient_user_id TEXT NOT NULL REFERENCES users(id),
        gift_id TEXT NOT NULL, quantity INTEGER NOT NULL, unit_price INTEGER NOT NULL,
        batch_recipient_count INTEGER NOT NULL, created_at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS experience_events_room ON experience_gift_events(room_id,seq);
    CREATE INDEX IF NOT EXISTS experience_events_batch ON experience_gift_events(batch_id);
    CREATE INDEX IF NOT EXISTS experience_events_sender ON experience_gift_events(sender_user_id);
    CREATE INDEX IF NOT EXISTS experience_events_recipient ON experience_gift_events(recipient_user_id);
    CREATE INDEX IF NOT EXISTS experience_events_created ON experience_gift_events(created_at);
    CREATE TABLE IF NOT EXISTS experience_room_heads (
        room_id TEXT PRIMARY KEY REFERENCES rooms(id), latest_seq INTEGER NOT NULL DEFAULT 0);
    """)


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class GiftSend(Model):
    giftID: str = Field(min_length=1, max_length=40)
    quantity: int = Field(strict=True, ge=1, le=99)
    recipientIDs: list[str] = Field(min_length=1, max_length=MAX_RECIPIENTS, strict=True)
    requestID: uuid.UUID

    @field_validator("recipientIDs", mode="before")
    @classmethod
    def recipients(cls, value):
        if (not isinstance(value, list) or any(not isinstance(item, str)
                or not re.fullmatch(r"[A-Za-z0-9_]{1,80}", item) for item in value)
                or len(set(value)) != len(value)):
            raise ValueError("收礼人格式不正确或有重复")
        return value


class DecorationPurchase(Model):
    decorationID: str = Field(min_length=1, max_length=40)
    requestID: uuid.UUID


class DecorationEquip(Model):
    kind: DecorationKind
    decorationID: str | None = Field(max_length=40)


@dataclass
class ExperienceStore:
    db: object
    limiter: object

    def ensure(self, user_id):
        now = int(time.time())
        if self.db.execute("INSERT OR IGNORE INTO experience_wallets VALUES(?,?,?)",
                           (user_id, INITIAL_DIAMONDS, now)).rowcount:
            self.entry(user_id, "initial_grant", "体验钻石到账", INITIAL_DIAMONDS, INITIAL_DIAMONDS, now)
        # Independent of wallet creation so accounts from earlier releases also
        # receive this pack once. Withdrawal and relogin retain the grant marker.
        if self.db.execute("INSERT OR IGNORE INTO experience_gift_grants VALUES(?,?,?)",
                           (user_id, STARTER_GIFT_GRANT_ID, now)).rowcount:
            for gift_id, quantity in STARTER_GIFT_PACK.items():
                self.db.execute("""INSERT INTO experience_gift_inventory VALUES(?,?,?)
                    ON CONFLICT(user_id,gift_id) DO UPDATE SET quantity=quantity+excluded.quantity""",
                    (user_id, gift_id, quantity))

    def wallet(self, user_id):
        self.ensure(user_id)
        balance = self.db.execute("SELECT balance FROM experience_wallets WHERE user_id=?", (user_id,)).fetchone()[0]
        return {"balance": balance, "initialGrant": INITIAL_DIAMONDS, "currency": "diamond"}

    def entry(self, user_id, kind, title, amount, balance, now):
        self.db.execute("INSERT INTO experience_entries VALUES(?,?,?,?,?,?,?)",
                        (str(uuid.uuid4()), user_id, kind, title, amount, balance, now))

    def equipped(self, user_id):
        result = {kind: None for kind in KINDS}
        result.update({row["kind"]: row["decoration_id"] for row in self.db.execute(
            "SELECT kind,decoration_id FROM experience_equipped WHERE user_id=?", (user_id,))})
        return result

    def inventory(self, user_id):
        owned = [row[0] for row in self.db.execute(
            "SELECT decoration_id FROM experience_inventory WHERE user_id=? ORDER BY decoration_id", (user_id,))]
        return {"ownedIDs": owned, "equipped": self.equipped(user_id)}

    def gift_inventory(self, user_id):
        self.ensure(user_id)
        quantities = {row["gift_id"]: row["quantity"] for row in self.db.execute(
            "SELECT gift_id,quantity FROM experience_gift_inventory WHERE user_id=? AND quantity>0", (user_id,))}
        return [{"giftID": gift["id"], "quantity": quantities[gift["id"]]}
                for gift in GIFTS if gift["id"] in quantities]

    def snapshot(self, user_id):
        wallet = self.wallet(user_id)
        entries = [{"id": row["id"], "kind": row["kind"], "title": row["title"],
                    "amount": row["amount"], "balanceAfter": row["balance_after"], "createdAt": row["created_at"]}
                   for row in self.db.execute("SELECT * FROM experience_entries WHERE user_id=? ORDER BY rowid DESC LIMIT 50", (user_id,))]
        return {"wallet": wallet, "inventory": self.inventory(user_id), "entries": entries,
                "giftInventory": self.gift_inventory(user_id)}

    @staticmethod
    def digest(payload):
        return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def previous(self, user_id, request_id, payload):
        previous = self.db.execute("SELECT * FROM experience_requests WHERE user_id=? AND request_id=?",
                                   (user_id, str(request_id))).fetchone()
        if previous and previous["payload_hash"] != self.digest(payload):
            raise HTTPException(409, "这个重试标识已用于其他操作")
        return previous

    def remember(self, user_id, request_id, payload, kind, cost, batch_id=None):
        self.db.execute("INSERT INTO experience_requests VALUES(?,?,?,?,?,?,?)", (user_id, str(request_id),
                        self.digest(payload), kind, cost, batch_id, int(time.time())))

    def debit(self, user_id, cost, kind, title):
        self.ensure(user_id)
        if self.db.execute("UPDATE experience_wallets SET balance=balance-? WHERE user_id=? AND balance>=?",
                           (cost, user_id, cost)).rowcount != 1:
            raise HTTPException(409, "体验钻石不足")
        balance = self.wallet(user_id)["balance"]
        self.entry(user_id, kind, title, -cost, balance, int(time.time()))

    def purchase(self, user_id, payload):
        item = DECORATION_CATALOG.get(payload.decorationID)
        if item is None:
            raise HTTPException(404, "装饰不存在")
        body = {"kind": "decoration", "decorationID": item["id"]}
        if not self.previous(user_id, payload.requestID, body):
            self.limiter.check(("decoration", user_id), 20, 60)
            owned = self.db.execute("SELECT 1 FROM experience_inventory WHERE user_id=? AND decoration_id=?",
                                    (user_id, item["id"])).fetchone()
            cost = 0 if owned else item["price"]
            if not owned:
                self.debit(user_id, cost, "decoration", "解锁 " + item["name"])
                self.db.execute("INSERT INTO experience_inventory VALUES(?,?,?)", (user_id, item["id"], int(time.time())))
            self.remember(user_id, payload.requestID, body, "decoration", cost)
        return {"wallet": self.wallet(user_id), "inventory": self.inventory(user_id)}

    def equip(self, user_id, payload):
        if payload.decorationID is None:
            self.db.execute("DELETE FROM experience_equipped WHERE user_id=? AND kind=?", (user_id, payload.kind))
        else:
            item = DECORATION_CATALOG.get(payload.decorationID)
            if not item or item["kind"] != payload.kind:
                raise HTTPException(422, "装饰与分类不匹配")
            if not self.db.execute("SELECT 1 FROM experience_inventory WHERE user_id=? AND decoration_id=?",
                                   (user_id, item["id"])).fetchone():
                raise HTTPException(403, "请先解锁这件装饰")
            self.db.execute("INSERT INTO experience_equipped VALUES(?,?,?) ON CONFLICT(user_id,kind) DO UPDATE SET decoration_id=excluded.decoration_id",
                            (user_id, payload.kind, item["id"]))
        return self.inventory(user_id)

    def blocked(self, first, second):
        return bool(self.db.execute("SELECT 1 FROM safety_blocks WHERE (user_id=? AND blocked_user_id=?) OR (user_id=? AND blocked_user_id=?)",
                                    (first, second, second, first)).fetchone())

    def event(self, row):
        return {"id": row["id"], "seq": row["seq"], "roomID": row["room_id"], "batchID": row["batch_id"],
                "senderUserID": row["sender_user_id"], "senderName": row["sender_name"],
                "recipientUserID": row["recipient_user_id"], "recipientName": row["recipient_name"],
                "giftID": row["gift_id"], "giftName": GIFT_CATALOG[row["gift_id"]]["name"],
                "quantity": row["quantity"], "unitPrice": row["unit_price"],
                "batchRecipientCount": row["batch_recipient_count"], "createdAt": row["created_at"]}

    def events(self, where, params):
        return self.db.execute("""SELECT e.*,s.name sender_name,r.name recipient_name FROM experience_gift_events e
            JOIN users s ON s.id=e.sender_user_id AND s.deleted=0
            JOIN users r ON r.id=e.recipient_user_id AND r.deleted=0 WHERE """ + where, params).fetchall()

    def visible(self, rows, user_id):
        blocked = {row[0] for row in self.db.execute("""SELECT blocked_user_id FROM safety_blocks WHERE user_id=?
            UNION SELECT user_id FROM safety_blocks WHERE blocked_user_id=?""", (user_id, user_id))}
        return [self.event(row) for row in rows
                if row["sender_user_id"] not in blocked and row["recipient_user_id"] not in blocked]

    @staticmethod
    def gift_body(room_id, payload):
        return {"kind": "gift", "roomID": room_id, "giftID": payload.giftID,
                "quantity": payload.quantity, "recipientIDs": sorted(payload.recipientIDs)}

    @staticmethod
    def validate_new_gift_recipients(user_id, recipient_ids):
        if user_id in recipient_ids:
            raise HTTPException(422, "礼物只能送给别人，不能送给自己")

    def gift_response(self, user_id, batch_id, cost, request_id, total_quantity):
        rows = self.events("e.batch_id=? ORDER BY e.seq", (batch_id,))
        settlement = self.db.execute("SELECT * FROM experience_gift_settlements WHERE user_id=? AND request_id=?",
                                     (user_id, str(request_id))).fetchone()
        # Requests committed before gift bags existed were paid entirely with
        # diamonds. The hash-checked original payload supplies their item count.
        inventory_used = settlement["inventory_used"] if settlement else 0
        diamond_quantity = settlement["diamond_quantity"] if settlement else total_quantity
        total_quantity = settlement["total_quantity"] if settlement else total_quantity
        return {"events": self.visible(rows, user_id), "wallet": self.wallet(user_id), "totalCost": cost,
                "giftInventory": self.gift_inventory(user_id), "inventoryUsed": inventory_used,
                "diamondQuantity": diamond_quantity, "totalQuantity": total_quantity}

    def send(self, room_id, user_id, payload):
        gift = GIFT_CATALOG.get(payload.giftID)
        if gift is None:
            raise HTTPException(404, "礼物不存在")
        body = self.gift_body(room_id, payload)
        total_quantity = payload.quantity * len(payload.recipientIDs)
        previous = self.previous(user_id, payload.requestID, body)
        if previous:
            return self.gift_response(user_id, previous["batch_id"], previous["total_cost"],
                                      payload.requestID, total_quantity)
        self.validate_new_gift_recipients(user_id, payload.recipientIDs)
        self.limiter.check(("gift-burst", user_id), 20, 5)
        self.limiter.check(("gift-minute", user_id), 120, 60)
        self.ensure(user_id)
        stock = self.db.execute("SELECT quantity FROM experience_gift_inventory WHERE user_id=? AND gift_id=?",
                                (user_id, gift["id"])).fetchone()
        inventory_used = min(stock[0] if stock else 0, total_quantity)
        diamond_quantity = total_quantity - inventory_used
        cost = gift["price"] * diamond_quantity
        if inventory_used:
            self.db.execute("UPDATE experience_gift_inventory SET quantity=quantity-? WHERE user_id=? AND gift_id=?",
                            (inventory_used, user_id, gift["id"]))
        self.debit(user_id, cost, "gift", f'{gift["name"]} ×{payload.quantity} · {len(payload.recipientIDs)}人'
                   f'（背包×{inventory_used}，钻石购买×{diamond_quantity}）')
        batch_id, now = str(uuid.uuid4()), int(time.time())
        for recipient in sorted(payload.recipientIDs):
            self.db.execute("""INSERT INTO experience_gift_events(id,room_id,batch_id,sender_user_id,
                recipient_user_id,gift_id,quantity,unit_price,batch_recipient_count,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?)""", (str(uuid.uuid4()), room_id, batch_id, user_id,
                    recipient, gift["id"], payload.quantity, gift["price"], len(payload.recipientIDs), now))
        seq = self.db.execute("SELECT MAX(seq) FROM experience_gift_events WHERE batch_id=?", (batch_id,)).fetchone()[0]
        self.db.execute("INSERT INTO experience_room_heads VALUES(?,?) ON CONFLICT(room_id) DO UPDATE SET latest_seq=excluded.latest_seq", (room_id, seq))
        self.remember(user_id, payload.requestID, body, "gift", cost, batch_id)
        self.db.execute("INSERT INTO experience_gift_settlements VALUES(?,?,?,?,?)",
                        (user_id, str(payload.requestID), inventory_used, diamond_quantity, total_quantity))
        self.prune(room_id)
        return self.gift_response(user_id, batch_id, cost, payload.requestID, total_quantity)

    def read(self, room_id, user_id, after):
        row = self.db.execute("SELECT latest_seq FROM experience_room_heads WHERE room_id=?", (room_id,)).fetchone()
        latest = row[0] if row else 0
        if after is None or after >= latest:
            return {"events": [], "cursor": latest, "hasMore": False}
        rows = self.events("e.room_id=? AND e.seq>? ORDER BY e.seq LIMIT 101", (room_id, after))
        has_more = len(rows) > 100
        page = rows[:100]
        return {"events": self.visible(page, user_id), "cursor": page[-1]["seq"] if has_more else latest,
                "hasMore": has_more}

    def prune_if_needed(self, room_id):
        summary = self.db.execute("SELECT COUNT(*) count,MIN(created_at) oldest FROM experience_gift_events WHERE room_id=?", (room_id,)).fetchone()
        if (summary["count"] > EVENT_WINDOW_SIZE or summary["oldest"] is not None
                and summary["oldest"] <= int(time.time()) - EVENT_RETENTION_SECONDS):
            self.prune(room_id)

    def prune(self, room_id=None):
        self.db.execute("DELETE FROM experience_gift_events WHERE created_at<=? OR room_id IN (SELECT id FROM rooms WHERE status!='active')",
                        (int(time.time()) - EVENT_RETENTION_SECONDS,))
        rooms = [room_id] if room_id else [row[0] for row in self.db.execute("SELECT room_id FROM experience_gift_events GROUP BY room_id HAVING COUNT(*)>?", (EVENT_WINDOW_SIZE,))]
        for identifier in rooms:
            self.db.execute("DELETE FROM experience_gift_events WHERE room_id=? AND seq NOT IN (SELECT seq FROM experience_gift_events WHERE room_id=? ORDER BY seq DESC LIMIT ?)",
                            (identifier, identifier, EVENT_WINDOW_SIZE))

    def clear_user(self, user_id, *, deleted=False):
        # Consent withdrawal stops public rendering, while retaining diamonds,
        # gift stock, one-time grant markers and unlocks. Re-consent cannot mint
        # another pack or lose the settlement needed for a safe retry.
        self.db.execute("DELETE FROM experience_gift_events WHERE sender_user_id=? OR recipient_user_id=?", (user_id, user_id))
        self.db.execute("DELETE FROM experience_equipped WHERE user_id=?", (user_id,))
        if deleted:
            for table in ("experience_gift_settlements", "experience_gift_inventory", "experience_gift_grants",
                          "experience_inventory", "experience_requests", "experience_entries", "experience_wallets"):
                self.db.execute(f"DELETE FROM {table} WHERE user_id=?", (user_id,))


def build_router(app, lock, authenticate, chat_member, participant_ids, member_row, valid_session):
    router = APIRouter()

    def user_for(request, *, nickname=False):
        user, _ = authenticate(request)
        app.state.safety.enforce(user["id"])
        if nickname and user["needs_nickname"]:
            raise HTTPException(403, "请先设置昵称")
        return user

    @router.get("/v1/gifts/catalog")
    async def catalog(request: Request):
        async with lock:
            user_for(request)
            return {"gifts": GIFTS, "decorations": DECORATIONS, "initialGrant": INITIAL_DIAMONDS}

    @router.get("/v1/me/experience")
    async def experience(request: Request):
        async with lock:
            user = user_for(request)
            with app.state.db:
                return app.state.experience.snapshot(user["id"])

    @router.get("/v1/me/wallet")
    async def wallet(request: Request):
        async with lock:
            user = user_for(request)
            with app.state.db:
                return app.state.experience.wallet(user["id"])

    @router.post("/v1/me/decorations/purchase")
    async def purchase(payload: DecorationPurchase, request: Request):
        async with lock:
            user = user_for(request, nickname=True)
            with app.state.db:
                return app.state.experience.purchase(user["id"], payload)

    @router.put("/v1/me/decorations/equipped")
    async def equip(payload: DecorationEquip, request: Request):
        async with lock:
            user = user_for(request, nickname=True)
            app.state.experience.limiter.check(("equip", user["id"]), 30, 60)
            with app.state.db:
                return app.state.experience.equip(user["id"], payload)

    @router.get("/v1/decorations/users")
    async def public_decorations(request: Request, ids: str = Query(max_length=8100)):
        identifiers = ids.split(",")
        if (not 1 <= len(identifiers) <= 100 or len(set(identifiers)) != len(identifiers)
                or any(not re.fullmatch(r"[A-Za-z0-9_]{1,80}", value) for value in identifiers)):
            raise HTTPException(422, "用户列表需要1至100个不重复的用户ID")
        async with lock:
            user = user_for(request)
            store = app.state.experience
            return {"users": [{"userID": identifier, "equipped": store.equipped(identifier)}
                    for identifier in identifiers if not store.blocked(user["id"], identifier)
                    and app.state.db.execute("SELECT 1 FROM users WHERE id=? AND deleted=0", (identifier,)).fetchone()]}

    @router.get("/v1/rooms/{room_id}/gifts")
    async def gifts(room_id: str, request: Request, after: int | None = Query(default=None, ge=0, le=9223372036854775807)):
        async with lock:
            user, _ = chat_member(room_id, request)
            with app.state.db:
                app.state.experience.prune_if_needed(room_id)
                return app.state.experience.read(room_id, user["id"], after)

    @router.post("/v1/rooms/{room_id}/gifts")
    async def send(room_id: str, payload: GiftSend, request: Request):
        async with lock:
            user, member = chat_member(room_id, request)
            if user["needs_nickname"]:
                raise HTTPException(403, "请先设置昵称")
            app.state.safety.enforce(user["id"], "chat")
            if member["chat_muted"]:
                raise HTTPException(403, "你已被禁言，暂时无法送礼")
            store = app.state.experience
            # A committed retry only acknowledges the original settlement, even
            # after disconnect or a change to recipient eligibility. Never
            # reinterpret an old request as a new delivery or another charge.
            previous = store.previous(user["id"], payload.requestID, store.gift_body(room_id, payload))
            if previous:
                with app.state.db:
                    return store.gift_response(user["id"], previous["batch_id"], previous["total_cost"],
                                               payload.requestID, payload.quantity * len(payload.recipientIDs))
            store.validate_new_gift_recipients(user["id"], payload.recipientIDs)
            online = await participant_ids(room_id)
            if user["id"] not in online:
                raise HTTPException(403, "请连接房间后再送礼")
            for identifier in payload.recipientIDs:
                recipient = member_row(room_id, identifier, required=False)
                if not recipient or identifier not in online or not valid_session(recipient["session_hash"]):
                    raise HTTPException(409, "收礼人已离线，请重新选择")
                if app.state.db.execute("SELECT 1 FROM room_bans WHERE room_id=? AND user_id=?", (room_id, identifier)).fetchone():
                    raise HTTPException(409, "收礼人暂时不可用")
                person = app.state.db.execute("SELECT needs_nickname FROM users WHERE id=? AND deleted=0", (identifier,)).fetchone()
                if person is None or person[0]:
                    raise HTTPException(409, "收礼人暂时不可用")
                if store.blocked(user["id"], identifier):
                    raise HTTPException(403, "你与收礼人之间存在拉黑关系")
            with app.state.db:
                return store.send(room_id, user["id"], payload)

    return router
