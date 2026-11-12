import hashlib

from conftest import create_room, headers
from test_account_bridge import account_service, exchange, payload, profile, signed


def person(service, identity):
    response = exchange(service, auth=hashlib.sha256(identity.encode()).hexdigest(),
                        user=profile("关系测试", identity))
    assert response.status_code == 200, response.text
    return response.json()


def joined(service, room, identity):
    account = person(service, identity)
    response = service.client.post(f"/v1/rooms/{room['id']}/token", headers=headers(account))
    assert response.status_code == 200, response.text
    service.rtc.rooms[room["id"]].add(identity)
    return account


def test_membership_snapshot_is_signed_room_scoped_and_occupants_only(account_service):
    s = account_service
    owner = person(s, "kiki_relationship_owner")
    room = create_room(s, owner)
    s.rtc.rooms[room["id"]].add(owner["user"]["id"])
    member = joined(s, room, "kiki_relationship_member")
    listener = joined(s, room, "kiki_relationship_listener")
    with s.app.state.db:
        s.app.state.db.execute("UPDATE room_seats SET user_id=? WHERE room_id=? AND seat_index=2",
                               (member["user"]["id"], room["id"]))
    query = {"accountID": listener["user"]["id"], "roomID": room["id"]}
    assert s.client.post("/internal/v1/account/relationship-members", json=query).status_code == 401
    result = signed(s, "relationship-members", query)
    assert result.status_code == 200, result.text
    assert result.headers["cache-control"] == "no-store"
    assert set(result.json()) == {"roomID", "roomRevision", "memberIDs"}
    assert result.json()["memberIDs"] == [owner["user"]["id"], member["user"]["id"]]
    outsider = person(s, "kiki_relationship_outsider")
    assert signed(s, "relationship-members", {**query, "accountID": outsider["user"]["id"]}).status_code == 403
    assert signed(s, "relationship-members", {**query, "birthDate": "2000-01-01"}).status_code == 422


def test_membership_snapshot_rejects_departed_and_expired_members(account_service):
    s = account_service
    owner = person(s, "kiki_relationship_owner")
    room = create_room(s, owner)
    query = {"accountID": owner["user"]["id"], "roomID": room["id"]}
    assert signed(s, "relationship-members", query).status_code == 200
    with s.app.state.db:
        s.app.state.db.execute("UPDATE sessions SET expires_at=0 WHERE user_id=?", (owner["user"]["id"],))
    assert signed(s, "relationship-members", query).status_code == 403


def test_blocks_filter_the_membership_snapshot_without_exposing_the_block(account_service):
    s = account_service
    owner = person(s, "kiki_relationship_owner")
    room = create_room(s, owner)
    s.rtc.rooms[room["id"]].add(owner["user"]["id"])
    member = joined(s, room, "kiki_relationship_member")
    with s.app.state.db:
        s.app.state.db.execute("UPDATE room_seats SET user_id=? WHERE room_id=? AND seat_index=2",
                               (member["user"]["id"], room["id"]))
        s.app.state.db.execute("INSERT INTO safety_blocks(user_id,blocked_user_id,created_at) VALUES(?,?,0)",
                               (member["user"]["id"], owner["user"]["id"]))
    result = signed(s, "relationship-members", {"accountID": owner["user"]["id"], "roomID": room["id"]})
    assert result.status_code == 200, result.text
    assert result.json()["memberIDs"] == [owner["user"]["id"]]


def test_refresh_only_invalidates_revision_and_never_accepts_private_fields(account_service):
    s = account_service
    owner = person(s, "kiki_relationship_owner")
    room = create_room(s, owner)
    db = s.app.state.db
    revision = db.execute("SELECT revision FROM room_revisions WHERE room_id=?", (room["id"],)).fetchone()[0]
    result = signed(s, "relationship-refresh", {"accountID": owner["user"]["id"]})
    assert result.status_code == 200 and result.json() == {"ok": True}
    assert db.execute("SELECT revision FROM room_revisions WHERE room_id=?", (room["id"],)).fetchone()[0] == revision + 1
    assert signed(s, "relationship-refresh", {"accountID": owner["user"]["id"], "pillars": ["庚辰"]}).status_code == 422


def test_relationship_bridge_not_available_in_lab_mode(lab):
    assert signed(lab, "relationship-refresh", {"accountID": profile()["id"]}).status_code == 404
    assert signed(lab, "relationship-members", {"accountID": profile()["id"], "roomID": "lk_" + "a" * 32}).status_code == 404
