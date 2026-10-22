"""Ordered seats and durable approval state, called under the room DB lock."""


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS seat_request_states (
        room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
        status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected','seated')),
        updated_at INTEGER NOT NULL, approval_order INTEGER,
        PRIMARY KEY(room_id,user_id));
    """)


class OrderedSeats:
    def __init__(self, db):
        self.db = db

    def status(self, room_id, user_id, seated=False):
        if seated:
            return "seated"
        row = self.db.execute("SELECT status FROM seat_request_states WHERE room_id=? AND user_id=?",
                              (room_id, user_id)).fetchone()
        if row and row[0] in {"pending", "approved", "rejected"}:
            return row[0]
        if self.db.execute("SELECT 1 FROM seat_requests WHERE room_id=? AND user_id=?", (room_id, user_id)).fetchone():
            return "pending"
        return "none"

    def request(self, room_id, user_id, now):
        if self.db.execute("INSERT OR IGNORE INTO seat_requests VALUES(?,?,?)", (room_id, user_id, now)).rowcount:
            self.db.execute("""INSERT INTO seat_request_states VALUES(?,?,'pending',?,NULL)
                ON CONFLICT(room_id,user_id) DO UPDATE SET status='pending',updated_at=excluded.updated_at,approval_order=NULL""",
                (room_id, user_id, now))

    def approve(self, room_id, user_id, now):
        if self.status(room_id, user_id) == "approved":
            return
        sequence = self.db.execute("SELECT COALESCE(MAX(approval_order),0)+1 FROM seat_request_states WHERE room_id=?", (room_id,)).fetchone()[0]
        self.db.execute("""INSERT INTO seat_request_states VALUES(?,?,'approved',?,?)
            ON CONFLICT(room_id,user_id) DO UPDATE SET status='approved',updated_at=excluded.updated_at,approval_order=excluded.approval_order""",
            (room_id, user_id, now, sequence))

    def reject(self, room_id, user_id, now):
        self.db.execute("DELETE FROM seat_requests WHERE room_id=? AND user_id=?", (room_id, user_id))
        self.db.execute("""INSERT INTO seat_request_states VALUES(?,?,'rejected',?,NULL)
            ON CONFLICT(room_id,user_id) DO UPDATE SET status='rejected',updated_at=excluded.updated_at,approval_order=NULL""",
            (room_id, user_id, now))

    def clear(self, room_id, user_id=None):
        where, args = ("room_id=?", (room_id,)) if user_id is None else ("room_id=? AND user_id=?", (room_id, user_id))
        self.db.execute("DELETE FROM seat_requests WHERE " + where, args)
        self.db.execute("DELETE FROM seat_request_states WHERE " + where, args)

    def compact(self, room_id, owner_id):
        seats = self.db.execute("SELECT * FROM room_seats WHERE room_id=? ORDER BY seat_index", (room_id,)).fetchall()
        active = {row[0] for row in self.db.execute("SELECT user_id FROM room_members WHERE room_id=? AND active=1", (room_id,))}
        current = {row["seat_index"]: row["user_id"] for row in seats}
        occupants = [row["user_id"] for row in seats if row["user_id"] in active and row["user_id"] != owner_id]
        slots = [row["seat_index"] for row in seats if row["seat_index"] > 1 and not row["locked"]]
        desired = {index: None for index in current}
        if owner_id in active:
            desired[1] = owner_id
        desired.update(zip(slots, occupants))
        if current == desired and not seats[0]["locked"]:
            return set()
        affected = {person for index in current if current[index] != desired[index]
                    for person in (current[index], desired[index]) if person}
        self.db.execute("UPDATE room_seats SET user_id=NULL WHERE room_id=?", (room_id,))
        self.db.execute("UPDATE room_seats SET locked=0 WHERE room_id=? AND seat_index=1", (room_id,))
        for index, person in desired.items():
            if person:
                self.db.execute("UPDATE room_seats SET user_id=? WHERE room_id=? AND seat_index=?", (person, room_id, index))
        return affected

    def fill(self, room_id, eligible, now):
        available = [row[0] for row in self.db.execute("SELECT seat_index FROM room_seats WHERE room_id=? AND seat_index>1 AND locked=0 AND user_id IS NULL ORDER BY seat_index", (room_id,))]
        waiting = self.db.execute("""SELECT q.user_id FROM seat_requests q
            JOIN seat_request_states a ON a.room_id=q.room_id AND a.user_id=q.user_id AND a.status='approved'
            JOIN room_members m ON m.room_id=q.room_id AND m.user_id=q.user_id AND m.active=1
            WHERE q.room_id=? ORDER BY a.approval_order,q.requested_at,q.rowid""", (room_id,)).fetchall()
        affected = set()
        for row in waiting:
            if not available:
                break
            person = row["user_id"]
            if person not in eligible:
                continue
            if self.db.execute("SELECT 1 FROM room_seats WHERE room_id=? AND user_id=?", (room_id, person)).fetchone():
                continue
            self.db.execute("UPDATE room_seats SET user_id=? WHERE room_id=? AND seat_index=?", (person, room_id, available.pop(0)))
            self.db.execute("DELETE FROM seat_requests WHERE room_id=? AND user_id=?", (room_id, person))
            self.db.execute("DELETE FROM seat_invitations WHERE room_id=? AND user_id=?", (room_id, person))
            self.db.execute("UPDATE seat_request_states SET status='seated',updated_at=? WHERE room_id=? AND user_id=?", (now, room_id, person))
            affected.add(person)
        return affected
