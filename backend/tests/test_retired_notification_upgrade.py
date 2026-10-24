"""The one-time upgrade belongs to offline deployment, including old restores."""
import builtins
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
from types import SimpleNamespace

import pytest

from deploy import deploy_remove_moments as publisher
from deploy.retire_legacy_notifications import migrate_database


def legacy_database(path, *, marker=False, reference=True):
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE social_notifications(id TEXT PRIMARY KEY,text TEXT NOT NULL" +
                   (",moment_id TEXT" if reference else "") +
                   (",is_retired INTEGER NOT NULL DEFAULT 0 CHECK(is_retired IN (0,1))" if marker else "") + ")")
        db.execute("INSERT INTO social_notifications(id,text) VALUES('current','current text')")
        db.execute("INSERT INTO social_notifications(id,text) VALUES('old','private legacy text')")
        if reference:
            db.execute("UPDATE social_notifications SET moment_id='source-reference' WHERE id='old'")
        db.execute("CREATE TABLE social_moments(id TEXT,text TEXT)")
        db.execute("INSERT INTO social_moments VALUES('source-reference','private rollback record')")


@pytest.mark.parametrize("marker", [False, True])
@pytest.mark.parametrize("reference", [False, True])
def test_existing_databases_upgrade_once_without_erasing_records(tmp_path, marker, reference):
    path = tmp_path / "account.sqlite3"
    legacy_database(path, marker=marker, reference=reference)
    result = migrate_database(path)
    assert result == {"database": str(path), "tablePresent": True,
                      "columnAdded": not marker, "notificationsMarked": int(reference)}
    assert migrate_database(path) == {**result, "columnAdded": False, "notificationsMarked": 0}
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT id,text,is_retired FROM social_notifications ORDER BY id").fetchall() == [
            ("current", "current text", 0), ("old", "private legacy text", int(reference))]
        assert db.execute("SELECT * FROM social_moments").fetchall() == [
            ("source-reference", "private rollback record")]
        if reference:
            assert db.execute("SELECT moment_id FROM social_notifications WHERE id='old'").fetchone()[0] == "source-reference"


def test_empty_database_is_left_for_current_application_schema(tmp_path):
    path = tmp_path / "fresh.sqlite3"
    sqlite3.connect(path).close()
    assert migrate_database(path) == {"database": str(path), "tablePresent": False,
                                      "columnAdded": False, "notificationsMarked": 0}
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT name FROM sqlite_master").fetchall() == []


def test_missing_database_is_not_created(tmp_path):
    path = tmp_path / "wrong-name.sqlite3"
    with pytest.raises(FileNotFoundError):
        migrate_database(path)
    assert not path.exists()


def test_restoring_old_database_requires_and_accepts_same_upgrade(tmp_path):
    path, backup, restored = [tmp_path / name for name in ("active.sqlite3", "before.sqlite3", "restored.sqlite3")]
    legacy_database(path)
    shutil.copyfile(path, backup)
    assert migrate_database(path)["notificationsMarked"] == 1
    shutil.copyfile(backup, restored)
    assert migrate_database(restored)["notificationsMarked"] == 1
    assert migrate_database(restored)["notificationsMarked"] == 0


def test_failed_upgrade_rolls_back_schema_and_marker_changes(tmp_path):
    path = tmp_path / "blocked.sqlite3"
    legacy_database(path)
    with sqlite3.connect(path) as db:
        db.execute("CREATE TRIGGER reject_upgrade BEFORE UPDATE ON social_notifications BEGIN SELECT RAISE(ABORT,'blocked'); END")
    with pytest.raises(sqlite3.IntegrityError):
        migrate_database(path)
    with sqlite3.connect(path) as db:
        assert "is_retired" not in {row[1] for row in db.execute("PRAGMA table_info(social_notifications)")}
        assert db.execute("SELECT COUNT(*) FROM social_notifications").fetchone()[0] == 2


def test_standalone_cli_works_without_application_imports(tmp_path):
    path = tmp_path / "offline.sqlite3"
    legacy_database(path)
    cli = Path(publisher.__file__).with_name("retire_legacy_notifications.py")
    result = subprocess.run([sys.executable, str(cli), "--database", str(path)],
                            cwd=tmp_path, check=True, capture_output=True, text=True)
    assert json.loads(result.stdout)["notificationsMarked"] == 1


def test_release_runs_upgrade_between_verified_backup_stop_and_code_replacement(monkeypatch, capsys):
    calls, scripts = [], []
    monkeypatch.setattr(publisher, "subprocess", SimpleNamespace(run=lambda args, **kwargs: calls.append(args)))

    def capture_script(source, filename, mode):
        scripts.append(source)
        return builtins.compile(source, filename, mode)

    monkeypatch.setattr(publisher, "compile", capture_script, raising=False)
    publisher.deploy("account", check=True)
    assert len(calls) == 1 and calls[0][1].endswith("tools/build_legal_documents.py")
    assert json.loads(capsys.readouterr().out)["networkActions"] is False
    script, = scripts
    verified = script.index("Verified data backup required")
    stopped = script.index("subprocess.run(['systemctl','stop',unit],check=True)")
    snapshot = script.index("original.backup(snapshot)")
    upgrade = script.index("upgrade=subprocess.run(")
    replace = script.index("shutil.rmtree(app/'app');shutil.copytree(payload/'app',app/'app')")
    started = script.index("subprocess.run(['systemctl','start',unit],check=True)")
    assert verified < stopped < snapshot < upgrade < replace < started
    assert "Actual database is not covered by the configured verified backup" in script
    assert "'--database',str(database)" in script
    assert "user='kikitalk',group='kikitalk'" in script
