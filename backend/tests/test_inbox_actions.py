"""Inbox pin/clear boundaries with real temporary account and social storage.

Apple and APNs use the existing local cryptographic/mock fixtures.  These tests
never contact a production account, voice room, or Apple push endpoint.
"""
import time
import uuid

import pytest

from app.main import database
from test_api import authorization, client, login
from test_push import env, friends, register, rows


BASE = "/v1/social"


def mutation(**fields):
    return {"requestID": str(uuid.uuid4()), **fields}


def account_id(e, actor):
    with database(e.c.settings) as db:
        return db.execute("SELECT account_id FROM accounts WHERE login_id=?",
                          (actor["user"]["id"],)).fetchone()[0]


def conversation_path(peer):
    return BASE + "/conversations/" + peer["user"]["id"]


def request(e, method, path, actor, payload):
    return e.c.request(method, path, headers=authorization(actor), json=payload)


def ok(e, method, path, actor, payload):
    response = request(e, method, path, actor, payload)
    assert response.status_code == 200, response.text
    assert response.json() == {"ok": True}
    return response


def send(e, actor, peer, text="会话体验", payload=None):
    response = request(e, "POST", conversation_path(peer) + "/messages", actor,
                       payload or mutation(text=text))
    assert response.status_code == 200, response.text
    return response.json()


def messages(e, actor, peer, **params):
    response = e.c.get(conversation_path(peer) + "/messages",
                       headers=authorization(actor), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def conversations(e, actor, **params):
    response = e.c.get(BASE + "/conversations", headers=authorization(actor), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def notifications(e, actor, **params):
    response = e.c.get(BASE + "/notifications", headers=authorization(actor), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def notice(e, actor, text="系统体验通知", created_at=None):
    recipient = account_id(e, actor)
    with database(e.c.settings) as db:
        previous = {row[0] for row in db.execute("SELECT id FROM social_notifications")}
        e.social.notice(db, recipient, "safety", text)
        added = {row[0] for row in db.execute("SELECT id FROM social_notifications")} - previous
        assert len(added) == 1
        item = added.pop()
        if created_at is not None:
            db.execute("UPDATE social_notifications SET created_at=? WHERE id=?", (created_at, item))
    return item


def discard_setup_notices(e):
    with database(e.c.settings) as db:
        db.execute("DELETE FROM push_outbox")
        db.execute("DELETE FROM social_notifications")


def test_conversation_pin_is_account_scoped_persistent_and_sorted_before_pagination(env):
    e = env
    a = login(e.c, "pin-owner")
    peers = [login(e.c, name) for name in ("pin-old", "pin-middle", "pin-new")]
    created = []
    for peer in peers:
        friends(e, a, peer)
        created.append(send(e, a, peer))
    now = int(time.time())
    with database(e.c.settings) as db:
        for index, item in enumerate(created):
            db.execute("UPDATE social_conversations SET updated_at=? WHERE id=?",
                       (now - 30 + index * 10, item["conversationID"]))
    assert all(row["isPinned"] is False for row in conversations(e, a)["conversations"])
    ok(e, "PUT", conversation_path(peers[0]) + "/pin", a, mutation(pinned=True))
    # A new authenticated session models the same account on another device.
    other_device = login(e.c, "pin-owner")
    pages, cursor = [], None
    while True:
        page = conversations(e, other_device, limit=1, **({"cursor": cursor} if cursor else {}))
        pages.extend(page["conversations"])
        cursor = page["nextCursor"]
        if cursor is None:
            break
        assert len(pages) < 4, "Pagination repeated a pinned row"
    assert [row["person"]["id"] for row in pages] == [peers[i]["user"]["id"] for i in (0, 2, 1)]
    assert [row["isPinned"] for row in pages] == [True, False, False]
    assert conversations(e, peers[0])["conversations"][0]["isPinned"] is False
    first_page = conversations(e, a, limit=1)
    assert e.c.get(BASE + "/conversations", headers=authorization(peers[0]),
                   params={"cursor": first_page["nextCursor"]}).status_code == 422


def test_pin_retry_cannot_override_later_unpin_and_request_ids_bind_operation(env):
    e = env
    a, b = login(e.c, "retry-pin-a"), login(e.c, "retry-pin-b")
    friends(e, a, b)
    message = send(e, a, b)
    payload = mutation(pinned=True)
    path = conversation_path(b)
    ok(e, "PUT", path + "/pin", a, payload)
    ok(e, "PUT", path + "/pin", a, mutation(pinned=False))
    ok(e, "PUT", path + "/pin", a, payload)
    assert conversations(e, a)["conversations"][0]["isPinned"] is False
    assert request(e, "PUT", path + "/pin", a, {**payload, "pinned": False}).status_code == 409
    assert request(e, "POST", path + "/clear", a,
                   {"requestID": payload["requestID"], "throughMessageID": message["message"]["id"]}).status_code == 409


def test_legacy_conversation_cursor_still_finishes_unpinned_history(env):
    e = env
    a, b, c = [login(e.c, name) for name in ("legacy-a", "legacy-b", "legacy-c")]
    for peer in (b, c):
        friends(e, a, peer)
        send(e, a, peer)
    first = conversations(e, a)["conversations"][0]
    with database(e.c.settings) as db:
        row = db.execute("SELECT updated_at,id FROM social_conversations WHERE id=?", (first["id"],)).fetchone()
    cursor = e.social.cursor({"account_id": account_id(e, a)}, "conversations", key=list(row))
    remaining = conversations(e, a, cursor=cursor)["conversations"]
    assert len(remaining) == 1 and remaining[0]["id"] != first["id"]
    assert remaining[0]["isPinned"] is False


@pytest.mark.parametrize("suffix,method,field,value", [
    ("pin", "PUT", "pinned", True),
    ("clear", "POST", "throughMessageID", str(uuid.uuid4())),
])
def test_conversation_mutations_require_auth_membership_and_visible_history(env, suffix, method, field, value):
    e = env
    a, b, c = [login(e.c, name) for name in ("scope-a", "scope-b", "scope-c")]
    friends(e, a, b)
    item = send(e, a, b)
    payload = mutation(**{field: item["message"]["id"] if suffix == "clear" else value})
    path = conversation_path(b) + "/" + suffix
    assert e.c.request(method, path, json=payload).status_code == 401
    assert request(e, method, path, c, payload).status_code == 404
    assert request(e, method, BASE + "/conversations/kiki_missing/" + suffix, a, payload).status_code == 404
    # Unfollowing does not remove the right to manage existing private history.
    response = request(e, "DELETE", BASE + "/follows/" + b["user"]["id"], a, mutation())
    assert response.status_code == 200, response.text
    ok(e, method, path, a, payload)


@pytest.mark.parametrize("path,method,valid", [
    ("/conversations/{peer}/pin", "PUT", {"pinned": True}),
    ("/conversations/{peer}/clear", "POST", {"throughMessageID": str(uuid.uuid4())}),
    ("/notifications/pin", "PUT", {"pinned": True}),
    ("/notifications/clear", "POST", {"throughNotificationID": str(uuid.uuid4())}),
])
def test_inbox_mutations_reject_ambiguous_or_coerced_payloads(env, path, method, valid):
    e = env
    a, b = login(e.c, "strict-a"), login(e.c, "strict-b")
    route = BASE + path.format(peer=b["user"]["id"])
    field = next(iter(valid))
    payload = mutation(**valid)
    invalid = [
        {key: value for key, value in payload.items() if key != "requestID"},
        {**payload, "requestID": "invalid"},
        {**payload, "requestID": True},
        {**payload, "unexpected": True},
        {"requestID": payload["requestID"]},
        {**payload, field: None},
        {**payload, field: ""},
        {**payload, field: 1},
    ]
    for body in invalid:
        result = request(e, method, route, a, body)
        assert result.status_code == 422, (body, result.text)
    assert e.c.request(method, route, json=payload).status_code == 401


def test_clear_uses_sequence_preserves_peer_and_blocks_old_cursor_and_receipt(env):
    e = env
    a, b = login(e.c, "clear-a"), login(e.c, "clear-b")
    friends(e, a, b)
    discard_setup_notices(e)
    outbound = mutation(text="自己的旧消息")
    sent = send(e, a, b, payload=outbound)
    received = [send(e, b, a, text=str(i)) for i in range(3)]
    same_second = int(time.time())
    with database(e.c.settings) as db:
        db.execute("UPDATE social_messages SET created_at=?", (same_second,))
    before = messages(e, a, b, limit=2)
    assert before["nextCursor"] and before["unreadCount"] == 3
    ok(e, "PUT", conversation_path(b) + "/pin", a, mutation(pinned=True))
    clear_payload = mutation(throughMessageID=received[-1]["message"]["id"])
    ok(e, "POST", conversation_path(b) + "/clear", a, clear_payload)
    assert conversations(e, a) == {"conversations": [], "nextCursor": None, "unreadCount": 0}
    cleared = messages(e, a, b)
    assert cleared["messages"] == []
    assert cleared["clearedThroughSeq"] == received[-1]["message"]["seq"]
    assert messages(e, a, b, cursor=before["nextCursor"])["messages"] == []
    peer_history = messages(e, b, a)["messages"]
    assert [item["id"] for item in peer_history] == [item["message"]["id"] for item in reversed(received)] + [sent["message"]["id"]]
    # A late retry cannot put the cleared sender's body back in its cache.
    assert request(e, "POST", conversation_path(b) + "/messages", a, outbound).status_code == 404
    assert request(e, "PUT", conversation_path(b) + "/pin", a, mutation(pinned=True)).status_code == 404
    new = send(e, b, a, text="同一秒产生的新消息")
    with database(e.c.settings) as db:
        db.execute("UPDATE social_messages SET created_at=? WHERE id=?", (same_second, new["message"]["id"]))
    restored = conversations(e, a)
    assert restored["unreadCount"] == 1 and restored["conversations"][0]["isPinned"] is False
    assert [item["id"] for item in messages(e, a, b)["messages"]] == [new["message"]["id"]]
    ok(e, "PUT", conversation_path(b) + "/pin", a, mutation(pinned=True))
    ok(e, "POST", conversation_path(b) + "/clear", a, clear_payload)
    assert conversations(e, a)["conversations"][0]["isPinned"] is True
    assert messages(e, a, b)["unreadCount"] == 1
    assert request(e, "POST", conversation_path(b) + "/clear", a,
                   {**clear_payload, "throughMessageID": new["message"]["id"]}).status_code == 409


def test_clear_fixed_watermark_does_not_drop_unseen_newer_message(env):
    e = env
    a, b, c = [login(e.c, name) for name in ("water-a", "water-b", "water-c")]
    friends(e, a, b)
    friends(e, a, c)
    old = send(e, b, a)
    new = send(e, b, a, text="列表展示后到达")
    foreign = send(e, c, a)
    path = conversation_path(b) + "/clear"
    assert request(e, "POST", path, a, mutation(throughMessageID=foreign["message"]["id"])).status_code == 404
    assert request(e, "POST", path, a, mutation(throughMessageID=str(uuid.uuid4()))).status_code == 404
    ok(e, "POST", path, a, mutation(throughMessageID=old["message"]["id"]))
    assert [item["id"] for item in messages(e, a, b)["messages"]] == [new["message"]["id"]]
    assert messages(e, a, b)["unreadCount"] == 1


def test_cleared_direct_messages_lose_pending_push_destination_and_badge(env):
    e = env
    a, b = login(e.c, "push-clear-a"), login(e.c, "push-clear-b")
    friends(e, a, b)
    discard_setup_notices(e)
    register(e, b)
    old = send(e, a, b)
    delivery = rows(e)[0]["id"]
    assert e.c.get("/v1/push/destinations/" + delivery, headers=authorization(b)).status_code == 200
    ok(e, "POST", conversation_path(a) + "/clear", b,
       mutation(throughMessageID=old["message"]["id"]))
    assert e.c.get("/v1/push/destinations/" + delivery, headers=authorization(b)).status_code == 404
    assert e.c.get("/v1/push/status", headers=authorization(b)).json()["badgeCount"] == 0
    e.s.dispatch()
    assert e.requests == []
    assert rows(e)[0]["state"] == "cancelled"
    send(e, a, b, text="删除之后的新消息")
    e.s.dispatch()
    assert len(e.requests) == 1
    assert e.c.get("/v1/push/status", headers=authorization(b)).json()["badgeCount"] == 1


def test_notification_clear_sequence_pagination_account_scope_and_new_event(env):
    e = env
    a, b = login(e.c, "notice-a"), login(e.c, "notice-b")
    initial = notifications(e, a)
    assert initial["inboxState"] == {
        "isPinned": False, "isHidden": False, "throughNotificationID": None, "clearedThroughSeq": 0,
    }
    same_second = int(time.time())
    # Legacy notification writers insert UUIDs directly.  The trigger must give
    # them increasing sequence values even when UUID order contradicts arrival.
    ids = ["00000000-0000-4000-8000-000000000003",
           "00000000-0000-4000-8000-000000000001",
           "00000000-0000-4000-8000-000000000002"]
    recipient = account_id(e, a)
    with database(e.c.settings) as db:
        for index, item in enumerate(ids):
            db.execute("INSERT INTO social_notifications(id,recipient_id,kind,text,created_at) VALUES(?,?,?,?,?)",
                       (item, recipient, "safety", str(index), same_second))
    foreign = notice(e, b, created_at=same_second)
    page = notifications(e, a, limit=1)
    assert [item["id"] for item in page["notifications"]] == [max(ids)]
    assert page["inboxState"]["throughNotificationID"] == ids[-1]
    all_notices = {item["id"]: item for item in notifications(e, a)["notifications"]}
    through_seq = all_notices[ids[-1]]["seq"]
    assert type(through_seq) is int and through_seq > 0
    assert [all_notices[item]["seq"] for item in ids] == sorted(all_notices[item]["seq"] for item in ids)
    assert page["unreadCount"] == 3 and page["nextCursor"]
    assert notifications(e, a, cursor=page["nextCursor"])["inboxState"]["throughNotificationID"] == ids[-1]
    assert e.c.get(BASE + "/notifications", headers=authorization(b),
                   params={"cursor": page["nextCursor"]}).status_code == 422
    path = BASE + "/notifications"
    assert request(e, "POST", path + "/clear", a, mutation(throughNotificationID=foreign)).status_code == 404
    ok(e, "PUT", path + "/pin", a, mutation(pinned=True))
    clear_payload = mutation(throughNotificationID=ids[-1])
    ok(e, "POST", path + "/clear", a, clear_payload)
    hidden = notifications(e, a)
    assert hidden["notifications"] == [] and hidden["unreadCount"] == 0
    assert hidden["inboxState"]["isHidden"] is True and hidden["inboxState"]["isPinned"] is False
    assert hidden["inboxState"]["clearedThroughSeq"] == through_seq
    assert notifications(e, a, cursor=page["nextCursor"])["notifications"] == []
    assert [item["id"] for item in notifications(e, b)["notifications"]] == [foreign]
    newer = notice(e, a, created_at=same_second)
    ok(e, "PUT", path + "/pin", a, mutation(pinned=True))
    ok(e, "POST", path + "/clear", a, clear_payload)
    restored = notifications(e, a)
    assert [item["id"] for item in restored["notifications"]] == [newer]
    assert restored["unreadCount"] == 1
    assert restored["inboxState"] == {
        "isPinned": True, "isHidden": False, "throughNotificationID": newer, "clearedThroughSeq": through_seq,
    }
    assert restored["notifications"][0]["seq"] > through_seq
    # A delayed acknowledgement for removed IDs cannot read a newer event.
    response = request(e, "POST", path + "/read", a, {"ids": ids})
    assert response.status_code == 200 and response.json()["unreadCount"] == 1
    assert request(e, "POST", path + "/clear", a,
                   {**clear_payload, "throughNotificationID": newer}).status_code == 409


def test_notification_clear_fixed_watermark_and_pin_retry_are_stable_across_sessions(env):
    e = env
    a = login(e.c, "notice-device")
    old = notice(e, a)
    new = notice(e, a)
    path = BASE + "/notifications"
    payload = mutation(pinned=True)
    ok(e, "PUT", path + "/pin", a, payload)
    ok(e, "PUT", path + "/pin", a, mutation(pinned=False))
    ok(e, "PUT", path + "/pin", a, payload)
    assert notifications(e, a)["inboxState"]["isPinned"] is False
    ok(e, "POST", path + "/clear", a, mutation(throughNotificationID=old))
    other_device = login(e.c, "notice-device")
    current = notifications(e, other_device)
    assert [item["id"] for item in current["notifications"]] == [new]
    assert current["unreadCount"] == 1 and current["inboxState"]["isHidden"] is False


def test_empty_notification_entry_can_be_pinned_and_unpinned_without_creating_history(env):
    e = env
    a = login(e.c, "notice-empty")
    path = BASE + "/notifications/pin"
    payload = mutation(pinned=True)
    ok(e, "PUT", path, a, payload)
    state = notifications(e, a)
    assert state["notifications"] == [] and state["unreadCount"] == 0
    assert state["inboxState"]["isPinned"] is True
    ok(e, "PUT", path, a, mutation(pinned=False))
    ok(e, "PUT", path, a, payload)
    assert notifications(e, a)["inboxState"]["isPinned"] is False
    assert request(e, "PUT", path, a, {**payload, "pinned": False}).status_code == 409


def test_clear_retries_survive_retention_purge_without_reapplying_to_new_history(env):
    from app.social import purge

    e = env
    a, b = login(e.c, "retained-a"), login(e.c, "retained-b")
    friends(e, a, b)
    discard_setup_notices(e)
    message = send(e, b, a)
    old_notice = notice(e, a)
    message_clear = mutation(throughMessageID=message["message"]["id"])
    notice_clear = mutation(throughNotificationID=old_notice)
    ok(e, "POST", conversation_path(b) + "/clear", a, message_clear)
    ok(e, "POST", BASE + "/notifications/clear", a, notice_clear)
    expired = int(time.time()) - 31 * 86400
    with database(e.c.settings) as db:
        db.execute("UPDATE social_messages SET created_at=? WHERE id=?", (expired, message["message"]["id"]))
        db.execute("UPDATE social_notifications SET created_at=? WHERE id=?", (expired, old_notice))
        purge(db)
        assert db.execute("SELECT 1 FROM social_messages WHERE id=?", (message["message"]["id"],)).fetchone() is None
        assert db.execute("SELECT 1 FROM social_notifications WHERE id=?", (old_notice,)).fetchone() is None
    newer_message = send(e, b, a)
    newer_notice = notice(e, a)
    ok(e, "PUT", conversation_path(b) + "/pin", a, mutation(pinned=True))
    ok(e, "PUT", BASE + "/notifications/pin", a, mutation(pinned=True))
    ok(e, "POST", conversation_path(b) + "/clear", a, message_clear)
    ok(e, "POST", BASE + "/notifications/clear", a, notice_clear)
    assert [item["id"] for item in messages(e, a, b)["messages"]] == [newer_message["message"]["id"]]
    assert conversations(e, a)["conversations"][0]["isPinned"] is True
    current = notifications(e, a)
    assert [item["id"] for item in current["notifications"]] == [newer_notice]
    assert current["inboxState"]["isPinned"] is True and current["unreadCount"] == 1


@pytest.mark.parametrize("kind", ["conversation", "notifications"])
def test_clear_uuid_case_retry_cannot_reapply_or_reuse_a_pin_receipt(env, kind):
    e = env
    a, b = login(e.c, "uuid-case-a"), login(e.c, "uuid-case-b")
    if kind == "conversation":
        friends(e, a, b)
        discard_setup_notices(e)
        old_id = send(e, b, a)["message"]["id"]
        path = conversation_path(b)
        field = "throughMessageID"
    else:
        old_id = notice(e, a)
        path = BASE + "/notifications"
        field = "throughNotificationID"
    clear_id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    original = {"requestID": clear_id, field: old_id.upper()}
    ok(e, "POST", path + "/clear", a, original)
    if kind == "conversation":
        new_id = send(e, b, a)["message"]["id"]
    else:
        new_id = notice(e, a)
    pin = mutation(pinned=True)
    ok(e, "PUT", path + "/pin", a, pin)
    # Both request UUID and cutoff UUID represent the same values in lowercase.
    retry = {"requestID": clear_id.lower(), field: old_id.lower()}
    ok(e, "POST", path + "/clear", a, retry)
    if kind == "conversation":
        assert conversations(e, a)["conversations"][0]["isPinned"] is True
        assert [item["id"] for item in messages(e, a, b)["messages"]] == [new_id]
    else:
        current = notifications(e, a)
        assert current["inboxState"]["isPinned"] is True
        assert [item["id"] for item in current["notifications"]] == [new_id]
    assert request(e, "POST", path + "/clear", a,
                   {**retry, field: new_id.upper()}).status_code == 409
    # Receipt identity is shared across operation kinds, including UUID casing.
    assert request(e, "PUT", path + "/pin", a,
                   {"requestID": clear_id.lower(), "pinned": False}).status_code == 409
    assert request(e, "POST", path + "/clear", a,
                   {"requestID": pin["requestID"].upper(), field: new_id}).status_code == 409


def test_notification_clear_removes_old_push_routes_and_only_dispatches_new_event(env):
    e = env
    a = login(e.c, "notice-push")
    register(e, a)
    old = notice(e, a)
    old_delivery = rows(e)[0]["id"]
    assert e.c.get("/v1/push/destinations/" + old_delivery, headers=authorization(a)).status_code == 200
    ok(e, "POST", BASE + "/notifications/clear", a, mutation(throughNotificationID=old))
    assert e.c.get("/v1/push/destinations/" + old_delivery, headers=authorization(a)).status_code == 404
    assert e.c.get("/v1/push/status", headers=authorization(a)).json()["badgeCount"] == 0
    e.s.dispatch()
    assert e.requests == [] and rows(e)[0]["state"] == "cancelled"
    newer = notice(e, a)
    e.s.dispatch()
    assert len(e.requests) == 1
    accepted = [row for row in rows(e) if row["state"] == "accepted"]
    assert len(accepted) == 1 and accepted[0]["source_id"] == newer


@pytest.mark.parametrize("kind", ["direct_message", "notification"])
def test_clear_between_push_claim_and_delivery_cancels_the_claimed_event(env, kind):
    e = env
    a, b = login(e.c, "claimed-a"), login(e.c, "claimed-b")
    if kind == "direct_message":
        friends(e, a, b)
        discard_setup_notices(e)
    register(e, b)
    if kind == "direct_message":
        item = send(e, a, b)
        path = conversation_path(a) + "/clear"
        payload = mutation(throughMessageID=item["message"]["id"])
    else:
        item = notice(e, b)
        path = BASE + "/notifications/clear"
        payload = mutation(throughNotificationID=item)
    claimed = e.s.claim()
    assert claimed is not None and claimed["event_kind"] == kind
    ok(e, "POST", path, b, payload)
    e.s.send_one(claimed)
    assert e.requests == []
    assert rows(e)[0]["state"] == "cancelled"


def test_existing_notification_storage_backfills_sequences_once_on_upgrade(env):
    from app.social import initialize

    e = env
    a = login(e.c, "migration-a")
    ids = [notice(e, a, created_at=int(time.time()) - offset) for offset in (20, 10, 0)]
    with database(e.c.settings) as db:
        # Simulate the preceding installed server schema with retained notices.
        db.execute("DROP TRIGGER social_notification_sequence_insert")
        db.execute("DROP TABLE social_notification_sequence")
        initialize(db)
        first = {row["notification_id"]: row["seq"] for row in db.execute("SELECT * FROM social_notification_sequence")}
        initialize(db)
        second = {row["notification_id"]: row["seq"] for row in db.execute("SELECT * FROM social_notification_sequence")}
        assert first == second and set(first) == set(ids)
        assert [first[item] for item in ids] == sorted(first.values())
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []
    current = notifications(e, a)
    assert {item["id"] for item in current["notifications"]} == set(ids)
    assert current["inboxState"]["clearedThroughSeq"] == 0
    ok(e, "POST", BASE + "/notifications/clear", a, mutation(throughNotificationID=ids[-1]))
    newer = notice(e, a)
    result = notifications(e, a)
    assert [item["id"] for item in result["notifications"]] == [newer]
    assert result["notifications"][0]["seq"] > max(first.values())


@pytest.mark.parametrize("path", ["/v1/me/legal-consent", "/v1/account"])
def test_withdrawal_and_deletion_remove_inbox_state_without_orphan_sequence_rows(env, path):
    e = env
    a, b = login(e.c, "erase-a"), login(e.c, "erase-b")
    friends(e, a, b)
    item = send(e, a, b)
    discard_setup_notices(e)
    mine = notice(e, a)
    theirs = notice(e, b)
    ok(e, "PUT", conversation_path(b) + "/pin", a, mutation(pinned=True))
    ok(e, "POST", conversation_path(b) + "/clear", a,
       mutation(throughMessageID=item["message"]["id"]))
    ok(e, "PUT", BASE + "/notifications/pin", a, mutation(pinned=True))
    ok(e, "POST", BASE + "/notifications/clear", a, mutation(throughNotificationID=mine))
    uid = account_id(e, a)
    response = e.c.delete(path, headers=authorization(a))
    assert response.status_code == 200, response.text
    with database(e.c.settings) as db:
        for table in ("social_conversation_state", "social_notification_state"):
            assert db.execute("SELECT COUNT(*) FROM " + table + " WHERE account_id=?", (uid,)).fetchone()[0] == 0
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []
        assert db.execute("SELECT 1 FROM social_notifications WHERE id=?", (mine,)).fetchone() is None
    assert [item["id"] for item in notifications(e, b)["notifications"]] == [theirs]
    if path.endswith("legal-consent"):
        again = login(e.c, "erase-a")
        assert notifications(e, again)["inboxState"] == {
            "isPinned": False, "isHidden": False, "throughNotificationID": None, "clearedThroughSeq": 0,
        }
