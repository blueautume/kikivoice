"""A durable room-directory hint; the room listing remains the authority.

SQLite triggers work for both HTTP mutations and external maintenance scripts.
One event per process wakes waiting requests; one shared low-frequency probe
covers writes made by another connection or worker. Waiting never owns the DB lock.
"""
import asyncio
import logging
import sqlite3


LOGGER = logging.getLogger("kiki.livekit.room_catalog")


def initialize_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS room_catalog_revision (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0));
    INSERT OR IGNORE INTO room_catalog_revision(singleton,revision) VALUES(1,0);
    CREATE TRIGGER IF NOT EXISTS room_catalog_insert AFTER INSERT ON rooms BEGIN
        UPDATE room_catalog_revision SET revision=revision+1 WHERE singleton=1;
    END;
    CREATE TRIGGER IF NOT EXISTS room_catalog_delete AFTER DELETE ON rooms BEGIN
        UPDATE room_catalog_revision SET revision=revision+1 WHERE singleton=1;
    END;
    CREATE TRIGGER IF NOT EXISTS room_catalog_update
        AFTER UPDATE OF status,title,category,theme ON rooms
        WHEN NEW.status IS NOT OLD.status OR NEW.title IS NOT OLD.title
          OR NEW.category IS NOT OLD.category OR NEW.theme IS NOT OLD.theme BEGIN
        UPDATE room_catalog_revision SET revision=revision+1 WHERE singleton=1;
    END;
    """)


class RoomCatalog:
    def __init__(self, db, lock):
        self.db = db
        self.lock = lock
        self._event = asyncio.Event()
        self._revision = self._read_revision()
        self._observed_changes = db.total_changes

    def _read_revision(self):
        return self.db.execute("SELECT revision FROM room_catalog_revision WHERE singleton=1").fetchone()[0]

    def publish_locked(self, *, force=False):
        """Call under the app DB lock after commit. Unchanged HTTP reads do no SQL."""
        if not force and self._observed_changes == self.db.total_changes:
            return
        try:
            self.snapshot_locked()
        except sqlite3.Error as error:
            # A hint publication must never prevent closing a room or stop the
            # privacy/disconnect cleanup loop. The shared probe retries it.
            LOGGER.warning("Room catalog publication unavailable: %s", type(error).__name__)

    def snapshot_locked(self):
        revision = self._read_revision()
        self._observed_changes = self.db.total_changes
        if revision != self._revision:
            self._revision = revision
            event, self._event = self._event, asyncio.Event()
            event.set()
        # Capture the event with its revision before releasing the DB lock;
        # publication between this snapshot and await cannot lose a wake-up.
        return self._revision, self._event

    @staticmethod
    async def wait(event, seconds):
        try:
            await asyncio.wait_for(event.wait(), timeout=seconds)
        except TimeoutError:
            pass

    async def monitor(self):
        while True:
            await asyncio.sleep(5)
            try:
                async with self.lock:
                    self.publish_locked(force=True)
            except Exception as error:
                LOGGER.warning("Room catalog probe unavailable: %s", type(error).__name__)
