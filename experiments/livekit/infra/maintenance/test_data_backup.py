import importlib.util
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("data_backup", Path(__file__).with_name("data_backup.py"))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.snapshots = self.root / "snapshots"
        self.avatar_name = "a" * 64 + ".jpg"
        (self.data / "avatars").mkdir()
        (self.data / "avatars" / self.avatar_name).write_bytes(b"avatar-fixture")
        with closing(sqlite3.connect(self.data / "kikitalk.sqlite3")) as db, db:
            db.execute("CREATE TABLE accounts(id TEXT PRIMARY KEY,avatar_filename TEXT)")
            db.execute("INSERT INTO accounts VALUES(?,?)", ("fixture", self.avatar_name))

    def tearDown(self):
        self.temp.cleanup()

    def create(self, now=1800000000):
        return backup.create_backup("account", data_directory=self.data, backup_directory=self.snapshots, now=now)

    def test_consistent_snapshot_restores_without_touching_live_data(self):
        original = backup.digest(self.data / "kikitalk.sqlite3")
        status = self.create()
        snapshot = next(self.snapshots.glob("snapshot-*"))
        self.assertEqual(backup.verify_restore(snapshot, "account"), 2)
        self.assertEqual(backup.digest(self.data / "kikitalk.sqlite3"), original)
        self.assertEqual(status["verifiedAt"], status["lastSuccessAt"])
        self.assertIsNone(status["lastError"])
        self.assertEqual((self.data / "backup-status.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((snapshot / "kikitalk.sqlite3").stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.snapshots.glob(".restore-check-*")))

    def test_modified_avatar_or_database_is_rejected(self):
        self.create()
        snapshot = next(self.snapshots.glob("snapshot-*"))
        (snapshot / "avatars" / self.avatar_name).write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            backup.verify_restore(snapshot, "account")
        with self.assertRaises(ValueError):
            backup.verify_restore(snapshot, "voice")

    def test_failed_backup_preserves_previous_success_and_live_data(self):
        self.create()
        (self.data / "avatars" / self.avatar_name).unlink()
        with self.assertRaises(ValueError):
            self.create(now=1800000100)
        status = json.loads((self.data / "backup-status.json").read_text())
        self.assertEqual(status["lastSuccessAt"], 1800000000)
        self.assertEqual(status["lastAttemptAt"], 1800000100)
        self.assertIsNotNone(status["lastError"])
        self.assertEqual(len(list(self.snapshots.glob("snapshot-*"))), 1)
        self.assertFalse(list(self.snapshots.glob("*.pending")))

    def test_retention_only_removes_old_managed_snapshots_after_success(self):
        self.create(now=1800000000 - 8 * 86400)
        unrelated = self.snapshots / "manual-archive"
        unrelated.mkdir()
        self.create()
        self.assertEqual(len(list(self.snapshots.glob("snapshot-*"))), 1)
        self.assertTrue(unrelated.exists())

    def test_voice_database_references_and_snapshot_verify(self):
        with closing(sqlite3.connect(self.data / "lab.sqlite3")) as db, db:
            db.executescript("CREATE TABLE users(id TEXT PRIMARY KEY); CREATE TABLE rooms(id TEXT,owner_id TEXT REFERENCES users(id));")
            db.execute("INSERT INTO users VALUES('u')")
            db.execute("INSERT INTO rooms VALUES('r','u')")
        backup.create_backup("voice", data_directory=self.data, backup_directory=self.snapshots)
        snapshot = next(self.snapshots.glob("snapshot-*"))
        self.assertEqual(backup.verify_restore(snapshot, "voice"), 1)
        with closing(sqlite3.connect(self.data / "lab.sqlite3")) as db, db:
            db.execute("UPDATE rooms SET owner_id='missing'")
        with self.assertRaises(ValueError):
            backup.create_backup("voice", data_directory=self.data, backup_directory=self.snapshots)

    def test_manifest_path_traversal_is_rejected(self):
        self.create()
        snapshot = next(self.snapshots.glob("snapshot-*"))
        manifest = json.loads((snapshot / "manifest.json").read_text())
        manifest["files"]["../outside"] = "a" * 64
        (snapshot / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            backup.verify_restore(snapshot, "account")

    def test_social_images_and_report_only_references_are_in_consistent_snapshot(self):
        identifier = "11111111-2222-4333-8444-555555555555"
        (self.data / "social-media").mkdir()
        media = self.data / "social-media" / (identifier + ".jpg")
        media.write_bytes(b"private-image-fixture")
        with closing(sqlite3.connect(self.data / "kikitalk.sqlite3")) as db, db:
            db.execute("CREATE TABLE social_media(id TEXT PRIMARY KEY)")
            db.execute("INSERT INTO social_media VALUES(?)", (identifier,))
        self.create()
        snapshot = next(self.snapshots.glob("snapshot-*"))
        self.assertEqual(backup.verify_restore(snapshot, "account"), 3)
        copied = snapshot / "social-media" / media.name
        self.assertEqual(copied.read_bytes(), media.read_bytes())
        self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
        copied.write_bytes(b"tampered")
        with self.assertRaises(ValueError): backup.verify_restore(snapshot, "account")

    def test_missing_social_image_aborts_snapshot_and_preserves_previous_success(self):
        self.create()
        with closing(sqlite3.connect(self.data / "kikitalk.sqlite3")) as db, db:
            db.execute("CREATE TABLE social_media(id TEXT PRIMARY KEY)")
            db.execute("INSERT INTO social_media VALUES('11111111-2222-4333-8444-555555555555')")
        with self.assertRaises(ValueError): self.create(now=1800000100)
        self.assertEqual(len(list(self.snapshots.glob("snapshot-*"))), 1)
        status = json.loads((self.data / "backup-status.json").read_text())
        self.assertEqual(status["lastSuccessAt"], 1800000000)
        self.assertIsNotNone(status["lastError"])



if __name__ == "__main__":
    unittest.main()
