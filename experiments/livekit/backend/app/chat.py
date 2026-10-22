"""Bounded, authoritative laboratory room text. No client data packet is trusted."""
from dataclasses import dataclass
import time
import uuid

from fastapi import HTTPException

CHAT_RETENTION_SECONDS = 2 * 3600
CHAT_WINDOW_SIZE = 200
CHAT_MAX_BYTES = 2000


def initialize_chat_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS room_chat_heads (
        room_id TEXT PRIMARY KEY REFERENCES rooms(id),
        latest_seq INTEGER NOT NULL DEFAULT 0, history_revision INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS room_messages (
        id TEXT NOT NULL UNIQUE, room_id TEXT NOT NULL REFERENCES rooms(id), seq INTEGER NOT NULL,
        client_message_id TEXT NOT NULL, sender_user_id TEXT NOT NULL REFERENCES users(id),
        sender_name TEXT NOT NULL, sender_avatar_index INTEGER NOT NULL,
        text TEXT NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY(room_id,seq), UNIQUE(room_id,sender_user_id,client_message_id));
    CREATE INDEX IF NOT EXISTS room_messages_sender ON room_messages(sender_user_id);
    CREATE TABLE IF NOT EXISTS room_announcements (
        room_id TEXT PRIMARY KEY REFERENCES rooms(id), text TEXT NOT NULL DEFAULT '',
        revision INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0,
        updated_by_user_id TEXT REFERENCES users(id));
    """)


def validate_text(value, *, empty=False):
    value = value.strip()
    if ((not empty and not value) or len(value.encode("utf-8")) > CHAT_MAX_BYTES
            or any(ord(char) < 32 and char not in "\n\t" or ord(char) == 127 for char in value)):
        raise ValueError("Invalid room text")
    return value


@dataclass
class RoomChatStore:
    db: object
    limiter: object

    def ensure(self, room_id):
        self.db.execute("INSERT OR IGNORE INTO room_chat_heads(room_id) VALUES(?)", (room_id,))
        self.db.execute("INSERT OR IGNORE INTO room_announcements(room_id) VALUES(?)", (room_id,))

    def bump_history(self, room_id):
        self.ensure(room_id)
        self.db.execute("UPDATE room_chat_heads SET history_revision=history_revision+1 WHERE room_id=?", (room_id,))

    def prune(self, room_id=None):
        now = int(time.time())
        # Global maintenance examines bodies that can actually need deletion.
        # Historical empty heads retain sequence/revision metadata and must not
        # cause per-room no-op writes or lock time on every maintenance tick.
        rooms = [room_id] if room_id else [row[0] for row in self.db.execute("""
            SELECT room_id FROM room_messages GROUP BY room_id
            HAVING MIN(created_at)<=? OR COUNT(*)>?""",
            (now-CHAT_RETENTION_SECONDS, CHAT_WINDOW_SIZE))]
        changed = []
        for identifier in rooms:
            self.ensure(identifier)
            cursor = self.db.execute("""DELETE FROM room_messages WHERE room_id=? AND
                (created_at<=? OR seq NOT IN (SELECT seq FROM room_messages WHERE room_id=? ORDER BY seq DESC LIMIT ?))""",
                (identifier, now-CHAT_RETENTION_SECONDS, identifier, CHAT_WINDOW_SIZE))
            if cursor.rowcount:
                self.bump_history(identifier)
                changed.append(identifier)
        return changed

    def clear_room(self, room_id):
        self.ensure(room_id)
        if self.db.execute("DELETE FROM room_messages WHERE room_id=?", (room_id,)).rowcount:
            self.bump_history(room_id)
        announcement = self.announcement(room_id)
        if announcement["text"]:
            self.db.execute("UPDATE room_announcements SET text='',revision=revision+1,updated_at=?,updated_by_user_id=NULL WHERE room_id=?", (int(time.time()), room_id))

    def clear_sender(self, user_id):
        affected = [row[0] for row in self.db.execute("SELECT DISTINCT room_id FROM room_messages WHERE sender_user_id=?", (user_id,))]
        self.db.execute("DELETE FROM room_messages WHERE sender_user_id=?", (user_id,))
        for room_id in affected:
            self.bump_history(room_id)
        # Announcements authored by this account are text too. Clear rather than
        # retaining the last author's content after withdrawal/deletion.
        announcements = self.db.execute("SELECT room_id FROM room_announcements WHERE updated_by_user_id=? AND text!=''", (user_id,)).fetchall()
        for row in announcements:
            self.db.execute("UPDATE room_announcements SET text='',revision=revision+1,updated_at=?,updated_by_user_id=NULL WHERE room_id=?", (int(time.time()), row[0]))
        return set(affected) | {row[0] for row in announcements}

    @staticmethod
    def message(row):
        return {"id": row["id"], "seq": row["seq"], "clientMessageID": row["client_message_id"],
                "senderUserID": row["sender_user_id"], "senderName": row["sender_name"],
                "senderAvatarIndex": row["sender_avatar_index"], "text": row["text"], "createdAt": row["created_at"]}

    def announcement(self, room_id):
        self.ensure(room_id)
        row = self.db.execute("SELECT * FROM room_announcements WHERE room_id=?", (room_id,)).fetchone()
        return {"text": row["text"], "revision": row["revision"], "updatedAt": row["updated_at"], "updatedByUserID": row["updated_by_user_id"]}

    def put_announcement(self, room_id, user_id, text):
        current = self.announcement(room_id)
        if current["text"] != text:
            self.db.execute("UPDATE room_announcements SET text=?,revision=revision+1,updated_at=?,updated_by_user_id=? WHERE room_id=?", (text, int(time.time()), user_id, room_id))
        return self.announcement(room_id)

    def notification(self, room_id):
        self.ensure(room_id)
        row = self.db.execute("SELECT * FROM room_chat_heads WHERE room_id=?", (room_id,)).fetchone()
        return {"version": 1, "latestSeq": row["latest_seq"], "historyRevision": row["history_revision"],
                "announcementRevision": self.announcement(room_id)["revision"]}

    def read(self, room_id, after_seq, limit):
        # Polling is normally read-only. Fetch the current head and announcement
        # together instead of issuing repeated INSERT OR IGNORE on every read.
        def current():
            return self.db.execute("""SELECT h.latest_seq,h.history_revision,
                a.text,a.revision,a.updated_at,a.updated_by_user_id
                FROM room_chat_heads h JOIN room_announcements a ON a.room_id=h.room_id
                WHERE h.room_id=?""", (room_id,)).fetchone()

        def window():
            return self.db.execute("SELECT COUNT(*) count,MIN(created_at) oldest_created,MIN(seq) oldest_seq FROM room_messages WHERE room_id=?", (room_id,)).fetchone()

        head = current()
        if head is None:
            self.ensure(room_id)
            head = current()
        summary = window()
        if (summary["count"] > CHAT_WINDOW_SIZE or summary["oldest_created"] is not None
                and summary["oldest_created"] <= int(time.time())-CHAT_RETENTION_SECONDS):
            # Expiry/overfull recovery remains synchronous with this read. Deletion
            # must still advance historyRevision before returning a window reset.
            self.prune(room_id)
            head, summary = current(), window()
        latest = head["latest_seq"]
        oldest = summary["oldest_seq"]
        oldest = oldest if oldest is not None else latest+1
        truncated = after_seq > latest or (after_seq > 0 and after_seq < oldest-1)
        # A cursor from another room or stale local state receives an authoritative
        # window reset. A normal gap also returns retained messages after the gap.
        query_after = 0 if after_seq > latest else after_seq
        rows = self.db.execute("SELECT * FROM room_messages WHERE room_id=? AND seq>? ORDER BY seq LIMIT ?", (room_id, query_after, limit+1)).fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]
        return {"messages": [self.message(row) for row in rows],
                "nextAfterSeq": rows[-1]["seq"] if has_more else latest,
                "latestSeq": latest, "oldestSeq": oldest, "truncated": truncated, "hasMore": has_more,
                "historyRevision": head["history_revision"],
                "announcement": {"text":head["text"], "revision":head["revision"],
                    "updatedAt":head["updated_at"], "updatedByUserID":head["updated_by_user_id"]}}

    def send(self, room_id, user, client_id, text):
        self.prune(room_id)
        previous = self.db.execute("SELECT * FROM room_messages WHERE room_id=? AND sender_user_id=? AND client_message_id=?", (room_id, user["id"], client_id)).fetchone()
        if previous:
            if previous["text"] != text:
                raise HTTPException(409, "这条消息的重试标识已用于其他内容")
            return self.message(previous), False
        self.limiter.check(("chat-burst", room_id, user["id"]), 5, 5)
        self.limiter.check(("chat-minute", room_id, user["id"]), 30, 60)
        self.ensure(room_id)
        self.db.execute("UPDATE room_chat_heads SET latest_seq=latest_seq+1 WHERE room_id=?", (room_id,))
        seq = self.db.execute("SELECT latest_seq FROM room_chat_heads WHERE room_id=?", (room_id,)).fetchone()[0]
        self.db.execute("INSERT INTO room_messages VALUES(?,?,?,?,?,?,?,?,?)", (str(uuid.uuid4()), room_id, seq, client_id, user["id"], user["name"], user["avatar_index"], text, int(time.time())))
        self.prune(room_id)
        return self.message(self.db.execute("SELECT * FROM room_messages WHERE room_id=? AND seq=?", (room_id, seq)).fetchone()), True
