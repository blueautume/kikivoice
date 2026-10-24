"""Public six-digit numbers never become reusable data/auth identities."""
from concurrent.futures import ThreadPoolExecutor
import sqlite3
import uuid

from fastapi.testclient import TestClient
import pytest

from app import account_numbers
from app.main import SCHEMA, Settings, create_app, database
from app.social import Policy
from conftest import apple_payload, apple_settings
from test_api import TEST_KEY, authorization, client, login
from test_ops_auth import ops
from test_social_boundaries import MOD, mutation, operator, person, report, social_env


def open_database(path):
    db = sqlite3.connect(path, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    return db


def insert_account(db, account_id, created_at=1):
    db.execute("INSERT INTO accounts(account_id,login_id,sdk_user_id,name,created_at) VALUES(?,?,?,?,?)",
               (account_id, "kiki_stable_"+account_id, "sdk_"+account_id, account_id, created_at))


def setup_social(client):
    client.app.state.social.policy = lambda user, target_ids=(): Policy(
        schemaVersion=1, accountID=user["login_id"], blockedUserIDs=[], currentRooms=[], roomsStale=True)


def test_startup_migrates_legacy_accounts_in_creation_order_without_changing_identity(tmp_path, fake_apple):
    path = tmp_path / "legacy.sqlite3"
    legacy_schema = "\n".join(line for line in SCHEMA.splitlines() if not line.strip().startswith("public_number "))
    with open_database(path) as db:
        db.executescript(legacy_schema)
        # Equal timestamps use the stable account ID as a deterministic tie break.
        for identifier, created_at in (("c", 20), ("b", 10), ("a", 10)):
            insert_account(db, identifier, created_at)
        original = [tuple(row) for row in db.execute("SELECT account_id,login_id,sdk_user_id,created_at FROM accounts ORDER BY account_id")]
    settings = apple_settings(Settings(str(path), 123, TEST_KEY, False))
    for _ in range(2):
        with TestClient(create_app(settings)):
            with open_database(path) as db:
                migrated = [tuple(row) for row in db.execute("SELECT account_id,public_number FROM accounts ORDER BY account_id")]
                assert migrated == [("a", 1), ("b", 2), ("c", 3)]
                assert [tuple(row) for row in db.execute("SELECT account_id,login_id,sdk_user_id,created_at FROM accounts ORDER BY account_id")] == original


def test_allocator_reuses_smallest_gap_and_preserves_assigned_numbers(tmp_path):
    path = tmp_path / "numbers.sqlite3"
    with open_database(path) as db:
        db.executescript(SCHEMA)
        account_numbers.initialize(db)
        for identifier in ("first", "second", "third"):
            insert_account(db, identifier)
            account_numbers.assign(db, identifier)
        db.execute("DELETE FROM accounts WHERE account_id='second'")
        insert_account(db, "replacement")
        assert account_numbers.assign(db, "replacement") == 2
        assert account_numbers.assign(db, "third") == 3
        account_numbers.initialize(db)
        assert db.execute("SELECT public_number FROM accounts WHERE account_id='third'").fetchone()[0] == 3
        for invalid in (0, 1000000, -1, 1.5):
            with pytest.raises(sqlite3.IntegrityError):
                db.execute("UPDATE accounts SET public_number=? WHERE account_id='third'", (invalid,))
        with pytest.raises(sqlite3.IntegrityError):
            db.execute("UPDATE accounts SET public_number=1 WHERE account_id='third'")


def test_concurrent_registrations_allocate_unique_minimum_available_numbers(tmp_path):
    path = tmp_path / "parallel.sqlite3"
    with open_database(path) as db:
        db.executescript(SCHEMA)
        account_numbers.initialize(db)
    def register(index):
        with open_database(path) as db:
            db.execute("BEGIN IMMEDIATE")
            identifier = "parallel_"+str(index)
            insert_account(db, identifier)
            return account_numbers.assign(db, identifier)
    with ThreadPoolExecutor(max_workers=8) as workers:
        numbers = list(workers.map(register, range(40)))
    assert sorted(numbers) == list(range(1, 41))
    with open_database(path) as db:
        assert db.execute("SELECT COUNT(DISTINCT public_number) FROM accounts").fetchone()[0] == 40


def test_user_and_people_expose_display_id_but_all_actions_keep_stable_id(client):
    setup_social(client)
    alice, bob = login(client), login(client, "bob")
    assert alice["user"]["displayID"] == "kiki_000001"
    assert bob["user"]["displayID"] == "kiki_000002"
    assert bob["user"]["id"] != bob["user"]["displayID"]
    assert client.get("/v1/me", headers=authorization(bob)).json()["displayID"] == "kiki_000002"
    assert client.post("/v1/auth/refresh", headers=authorization(bob)).json()["user"]["displayID"] == "kiki_000002"
    for query in ("000002", "kiki_000002", "KIKI_000002", bob["user"]["id"]):
        people = client.get("/v1/social/people", headers=authorization(alice), params={"query": query}).json()["people"]
        assert len(people) == 1 and people[0]["id"] == bob["user"]["id"]
        assert people[0]["displayID"] == "kiki_000002"
    assert client.get("/v1/social/people", headers=authorization(alice), params={"query": "000000"}).json()["people"] == []
    # Display numbers are for discovery/display only; never resolve old actions
    # or conversation links through a number that may belong to somebody else.
    assert client.get("/v1/social/people/kiki_000002", headers=authorization(alice)).status_code == 404


def test_ops_reports_and_restrictions_show_numbers_while_actions_use_permanent_ids(social_env):
    env = social_env
    reporter, target = person(env, "账号举报甲"), person(env, "账号举报乙")
    case = report(env, reporter, "profile", target["user"]["id"])
    reviewer = operator(env)
    result = env.c.post(MOD+"/moderation/query", headers=authorization(reviewer), json={"status": "all"})
    assert result.status_code == 200
    row = result.json()["reports"][0]
    assert row["reporterID"] == reporter["user"]["id"]
    assert row["reporterDisplayID"] == reporter["user"]["displayID"]
    assert row["targetUserID"] == target["user"]["id"]
    assert row["targetDisplayID"] == target["user"]["displayID"]
    restricted = env.c.post(MOD+"/moderation/action", headers=authorization(reviewer), json=mutation(
        reportID=case["id"], action="restrict_posting", durationSeconds=3600, note="号码展示验证"))
    assert restricted.status_code == 200
    state = env.c.post(MOD+"/moderation/query", headers=authorization(reviewer), json={"status": "all"}).json()
    assert state["activeRestrictions"][0]["userID"] == target["user"]["id"]
    assert state["activeRestrictions"][0]["userDisplayID"] == target["user"]["displayID"]
    assert env.c.delete("/v1/account", headers=authorization(target)).status_code == 200
    replacement = person(env, "账号举报新乙")
    assert replacement["user"]["displayID"] == target["user"]["displayID"]
    fresh_state = env.c.post(MOD+"/moderation/query", headers=authorization(reviewer), json={"status": "all"}).json()
    assert fresh_state["reports"] == [] and fresh_state["activeRestrictions"] == []


def test_deletion_releases_number_without_reconnecting_follows_messages_or_tokens(client):
    setup_social(client)
    alice, bob = login(client), login(client, "bob")
    target = bob["user"]["id"]
    relation = "/v1/social/follows/"+target
    assert client.put(relation, headers=authorization(alice), json={"requestID": str(uuid.uuid4())}).status_code == 200
    message_path = "/v1/social/conversations/"+target+"/messages"
    assert client.post(message_path, headers=authorization(alice), json={"requestID": str(uuid.uuid4()), "text": "只属于原账号的消息"}).status_code == 200
    assert client.delete("/v1/account", headers=authorization(bob)).status_code == 200
    replacement = login(client, "replacement")
    assert replacement["user"]["displayID"] == bob["user"]["displayID"] == "kiki_000002"
    assert replacement["user"]["id"] != target
    assert replacement["user"]["sdkUserID"] != bob["user"]["sdkUserID"]
    assert client.get("/v1/me", headers=authorization(bob)).status_code == 401
    assert client.get(message_path, headers=authorization(alice)).status_code == 404
    assert client.get("/v1/social/relationships/ids", headers=authorization(alice)).json()["followingIDs"] == []
    new_path = "/v1/social/conversations/"+replacement["user"]["id"]+"/messages"
    fresh = client.get(new_path, headers=authorization(alice)).json()
    assert fresh["messages"] == [] and fresh["remainingBeforeReply"] == 5 and not fresh["replyEstablished"]
    # The same Apple subject creates an unrelated account too, with a new slot.
    recreated = login(client, "bob")
    assert recreated["user"]["displayID"] == "kiki_000003"
    assert recreated["user"]["id"] != target


def test_exhaustion_rolls_back_registration_but_existing_login_and_reuse_work(client, monkeypatch):
    monkeypatch.setattr(account_numbers, "MAX_PUBLIC_NUMBER", 2)
    alice, bob = login(client), login(client, "bob")
    rejected = client.post("/v1/auth/apple", json=apple_payload(client, "third"))
    assert rejected.status_code == 503 and "号码已用完" in rejected.json()["detail"]
    with database(client.settings) as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 2
        assert db.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 2
    assert login(client)["user"]["displayID"] == "kiki_000001"
    assert client.delete("/v1/account", headers=authorization(alice)).status_code == 200
    assert login(client, "third")["user"]["displayID"] == "kiki_000001"
    assert client.get("/v1/me", headers=authorization(bob)).json()["displayID"] == "kiki_000002"
