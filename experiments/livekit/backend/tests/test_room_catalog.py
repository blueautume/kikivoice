"""The directory wait endpoint is a hint, never another SFU/room polling loop."""
import asyncio
from contextlib import suppress
import hashlib
import sqlite3
import time

import httpx
import pytest

from app.room_catalog import initialize_database
from conftest import create_room, headers, login
from test_room_actions import setup_room, state


PATH = "/v1/room-catalog/changes"


def watch(lab, account, **params):
    return lab.client.get(PATH, headers=headers(account), params=params)


def observe_waits(lab, monkeypatch, count=1):
    """A barrier at the real await boundary; no timing race with request startup."""
    reached = asyncio.Event()
    original = lab.app.state.room_catalog.wait
    observed = []

    async def wait(event, seconds):
        observed.append(event)
        if len(observed) == count:
            reached.set()
        await original(event, seconds)

    monkeypatch.setattr(lab.app.state.room_catalog, "wait", wait)
    return reached, observed


def test_initial_mismatch_and_restored_older_revision_return_without_wait(lab):
    account = login(lab)
    initial = watch(lab, account)
    assert initial.status_code == 200
    assert initial.headers["cache-control"] == "no-store"
    assert initial.json() == {"revision": 0, "changed": True}
    assert watch(lab, account, after=20, waitSeconds=20).json() == initial.json()
    assert watch(lab, account, after=0, waitSeconds=0).json() == {"revision": 0, "changed": False}


@pytest.mark.parametrize("params", [{"after": -1}, {"after": 9223372036854775808},
                                    {"after": "invalid"}, {"waitSeconds": -1}, {"waitSeconds": 21}])
def test_watch_parameters_are_bounded(lab, params):
    assert watch(lab, login(lab), **params).status_code == 422


def test_concurrent_waiters_wake_immediately_after_create_and_close_without_extra_sfu_reads(lab, monkeypatch):
    owner, reader = login(lab, "Owner"), login(lab, "Reader")
    baseline = watch(lab, reader).json()["revision"]
    reached, _ = observe_waits(lab, monkeypatch, count=4)
    calls = []
    original_rooms, original_participants = lab.rtc.list_rooms, lab.rtc.participants

    async def rooms():
        calls.append("rooms")
        return await original_rooms()

    async def participants(room_id):
        calls.append("participants")
        return await original_participants(room_id)

    lab.rtc.list_rooms, lab.rtc.participants = rooms, participants

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=lab.app), base_url="http://testserver") as client:
            waiters = [asyncio.create_task(client.get(PATH, headers=headers(reader),
                       params={"after": baseline, "waitSeconds": 20})) for _ in range(4)]
            await asyncio.wait_for(reached.wait(), 1)
            assert not calls, "Starting a directory wait must not synchronize or enumerate SFU rooms"
            created = await asyncio.wait_for(client.post("/v1/rooms", headers=headers(owner), json={
                "title": "即时新房间", "category": "闲聊", "isLive": False, "theme": 0}), 1)
            assert created.status_code == 200, created.text
            responses = await asyncio.wait_for(asyncio.gather(*waiters), 1)
            latest = responses[0].json()["revision"]
            assert latest > baseline
            assert all(response.status_code == 200 and response.json() == {"revision": latest, "changed": True}
                       for response in responses)
            assert calls == ["rooms"], "Only the authoritative create operation may synchronize SFU state"
            reached.clear()
            # The observer counts the four first waits; replace it for the next request.
            closed_waiting, _ = observe_waits(lab, monkeypatch)
            waiter = asyncio.create_task(client.get(PATH, headers=headers(reader),
                         params={"after": latest, "waitSeconds": 20}))
            await asyncio.wait_for(closed_waiting.wait(), 1)
            closed = await asyncio.wait_for(client.patch("/v1/rooms/" + created.json()["id"],
                           headers=headers(owner), json={"status": "closed"}), 1)
            assert closed.status_code == 200, closed.text
            response = await asyncio.wait_for(waiter, 1)
            assert response.json()["changed"] and response.json()["revision"] > latest
            assert calls == ["rooms"]

    lab.client.portal.call(scenario)


def test_timeout_is_quiet_read_only_and_does_not_poll_sfu(lab):
    account = login(lab)
    revision = watch(lab, account).json()["revision"]
    calls = []

    async def unexpected(*_args):
        calls.append("SFU")
        raise AssertionError("Directory waits cannot query the SFU")

    lab.rtc.list_rooms = unexpected
    lab.rtc.participants = unexpected
    statements = []
    changes = lab.app.state.db.total_changes
    lab.app.state.db.set_trace_callback(statements.append)
    try:
        response = watch(lab, account, after=revision, waitSeconds=1)
    finally:
        lab.app.state.db.set_trace_callback(None)
    assert response.json() == {"revision": revision, "changed": False}
    assert not calls
    assert lab.app.state.db.total_changes == changes
    assert sum("SELECT revision FROM room_catalog_revision" in sql for sql in statements) == 2
    assert not any("SELECT * FROM rooms" in sql for sql in statements)


def test_cancelled_watch_releases_waiter_and_database_lock(lab, monkeypatch):
    account = login(lab)
    revision = watch(lab, account).json()["revision"]
    reached, events = observe_waits(lab, monkeypatch)

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=lab.app), base_url="http://testserver") as client:
            before = set(asyncio.all_tasks())
            request = asyncio.create_task(client.get(PATH, headers=headers(account),
                       params={"after": revision, "waitSeconds": 20}))
            await asyncio.wait_for(reached.wait(), 1)
            request.cancel()
            with suppress(asyncio.CancelledError):
                await request
            for _ in range(5):
                await asyncio.sleep(0)
            assert not [task for task in asyncio.all_tasks() if task not in before and not task.done()]
            assert all(not event._waiters for event in events)
            response = await asyncio.wait_for(client.get(PATH, headers=headers(account)), 1)
            assert response.status_code == 200

    lab.client.portal.call(scenario)


@pytest.mark.parametrize("change,status", [("revoked", 401), ("expired", 401), ("deleted", 401),
                                         ("withdrawn", 428), ("banned", 403)])
def test_wait_revalidates_session_consent_and_restriction_before_returning(lab, monkeypatch, change, status):
    reader = login(lab)
    revision = watch(lab, reader).json()["revision"]
    reached, _ = observe_waits(lab, monkeypatch)
    digest = hashlib.sha256(reader["token"].encode()).hexdigest()
    user_id = reader["user"]["id"]

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=lab.app), base_url="http://testserver") as client:
            request = asyncio.create_task(client.get(PATH, headers=headers(reader),
                       params={"after": revision, "waitSeconds": 1}))
            await asyncio.wait_for(reached.wait(), 1)
            async with lab.app.state.room_catalog.lock:
                with lab.app.state.db:
                    if change == "revoked":
                        lab.app.state.db.execute("UPDATE sessions SET revoked_at=? WHERE token_hash=?", (int(time.time()), digest))
                    elif change == "expired":
                        lab.app.state.db.execute("UPDATE sessions SET expires_at=0 WHERE token_hash=?", (digest,))
                    elif change == "deleted":
                        lab.app.state.db.execute("UPDATE users SET deleted=1 WHERE id=?", (user_id,))
                    elif change == "withdrawn":
                        lab.app.state.db.execute("UPDATE consents SET withdrawn_at=? WHERE user_id=?", (int(time.time()), user_id))
                    else:
                        lab.app.state.db.execute("INSERT INTO safety_restrictions(user_id,banned_until,reason) VALUES(?,?,?)",
                                                (user_id, int(time.time()) + 60, "测试暂停"))
            response = await asyncio.wait_for(request, 2)
            assert response.status_code == status, response.text
            assert "revision" not in response.json()
            assert response.headers["cache-control"] == "no-store"

    lab.client.portal.call(scenario)


def test_unauthenticated_watch_cannot_observe_directory(lab):
    assert lab.client.get(PATH).status_code == 401
    assert lab.client.get(PATH, headers={"Authorization": "Bearer " + "a" * 43}).status_code == 401


def test_hint_read_failure_does_not_prevent_the_primary_room_close(lab, monkeypatch):
    owner = login(lab)
    room = create_room(lab, owner)

    def unavailable():
        raise sqlite3.OperationalError("simulated catalog hint failure")

    monkeypatch.setattr(lab.app.state.room_catalog, "_read_revision", unavailable)
    response = lab.client.patch("/v1/rooms/" + room["id"], headers=headers(owner), json={"status": "closed"})
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "ended"
    assert lab.app.state.db.execute("SELECT status FROM rooms WHERE id=?", (room["id"],)).fetchone()[0] == "closed"
    assert room["id"] not in lab.rtc.rooms
    assert watch(lab, owner).status_code == 503, "A hint read fails explicitly instead of inventing a revision"


def test_sql_triggers_are_atomic_noop_aware_and_survive_restart_and_external_writes(tmp_path):
    path = tmp_path / "catalog.sqlite3"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE rooms(id TEXT PRIMARY KEY,status TEXT,title TEXT,category TEXT,theme INTEGER)")
        initialize_database(db)
        revision = lambda: db.execute("SELECT revision FROM room_catalog_revision").fetchone()[0]
        assert revision() == 0
        db.execute("INSERT INTO rooms VALUES('room','active','房间','闲聊',0)")
        assert revision() == 1
        db.rollback()
        assert revision() == 0, "A rolled-back room must not publish a durable hint"
        db.execute("INSERT INTO rooms VALUES('room','active','房间','闲聊',0)")
        db.commit()
        for field, value in [("status", "closed"), ("title", "新标题"), ("category", "音乐"), ("theme", 1)]:
            before = revision()
            db.execute(f"UPDATE rooms SET {field}=? WHERE id='room'", (value,))
            assert revision() == before + 1
            db.execute(f"UPDATE rooms SET {field}=? WHERE id='room'", (value,))
            assert revision() == before + 1
        db.commit()
        persisted = revision()
    with sqlite3.connect(path) as external:
        initialize_database(external)
        assert external.execute("SELECT revision FROM room_catalog_revision").fetchone()[0] == persisted
        external.execute("DELETE FROM rooms WHERE id='room'")
    with sqlite3.connect(path) as reopened:
        initialize_database(reopened)
        assert reopened.execute("SELECT revision FROM room_catalog_revision").fetchone()[0] == persisted + 1


def test_shared_probe_discovers_external_commits_without_any_client_polling(lab, monkeypatch):
    owner, reader = login(lab, "Owner"), login(lab, "Reader")
    room = create_room(lab, owner)
    revision = watch(lab, reader).json()["revision"]
    reached, _ = observe_waits(lab, monkeypatch)

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=lab.app), base_url="http://testserver") as client:
            request = asyncio.create_task(client.get(PATH, headers=headers(reader),
                       params={"after": revision, "waitSeconds": 20}))
            await asyncio.wait_for(reached.wait(), 1)
            with sqlite3.connect(lab.settings.db_path) as external:
                external.execute("UPDATE rooms SET title='外部维护更新' WHERE id=?", (room["id"],))
            # No request or per-client SQL loop publishes the change. The one
            # lifespan probe notices this other connection within its 5s bound.
            response = await asyncio.wait_for(request, 6)
            assert response.status_code == 200
            assert response.json()["changed"] and response.json()["revision"] > revision

    lab.client.portal.call(scenario)


def test_owner_timeout_maintenance_wakes_directory_without_client_room_requests(lab, monkeypatch):
    room, (owner, _member), _ = setup_room(lab)
    state(lab, room, owner)
    reader = login(lab, "DirectoryReader")
    revision = watch(lab, reader).json()["revision"]
    reached, _ = observe_waits(lab, monkeypatch)
    lab.rtc.rooms[room["id"]].discard(owner["user"]["id"])
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE room_presence SET offline_since=? WHERE room_id=? AND user_id=?",
                                (int(time.time()) - 16, room["id"], owner["user"]["id"]))

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=lab.app), base_url="http://testserver") as client:
            request = asyncio.create_task(client.get(PATH, headers=headers(reader),
                       params={"after": revision, "waitSeconds": 20}))
            await asyncio.wait_for(reached.wait(), 1)
            response = await asyncio.wait_for(request, 7)
            assert response.status_code == 200
            assert response.json()["changed"] and response.json()["revision"] > revision
            assert lab.app.state.db.execute("SELECT status FROM rooms WHERE id=?", (room["id"],)).fetchone()[0] == "closed"

    lab.client.portal.call(scenario)
