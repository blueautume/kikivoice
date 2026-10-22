import pytest

from app.main import default_room_title
from conftest import create_room, headers, login


def joined_owner(lab):
    owner = login(lab, "小岛")
    room = create_room(lab, owner)
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(owner)).status_code == 200
    lab.rtc.rooms[room["id"]].add(owner["user"]["id"])
    return owner, room


def test_blank_and_missing_create_title_use_authenticated_nickname(lab):
    owner = login(lab, "小岛")
    for title in [None, "", "   "]:
        body = {"category": "随心聊", "theme": 2, "isLive": False}
        if title is not None:
            body["title"] = title
        response = lab.client.post('/v1/rooms', headers=headers(owner), json=body)
        assert response.status_code == 200, response.text
        assert response.json()["title"] == "小岛的房间"
        assert lab.client.patch(f'/v1/rooms/{response.json()["id"]}', headers=headers(owner), json={"status": "ended"}).status_code == 200


def test_default_title_keeps_suffix_and_utf8_limits_for_long_name():
    for name in ["中" * 100, "😀" * 100, "a" * 100, "", "\n\x00"]:
        title = default_room_title(name)
        assert title.endswith("的房间")
        assert 3 < len(title) <= 36
        assert len(title.encode('utf-8')) <= 100
        assert all(ord(char) >= 32 and ord(char) != 127 for char in title)


def test_owner_title_update_returns_authoritative_revision_and_updates_all_views(lab):
    owner, room = joined_owner(lab)
    room_id = room["id"]
    before = lab.client.get(f'/v1/rooms/{room_id}/state', headers=headers(owner)).json()
    catalog_before = lab.client.get('/v1/room-catalog/changes', headers=headers(owner)).json()["revision"]
    response = lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(owner), json={"title": "  一起聊电影  "})
    assert response.status_code == 200, response.text
    state = response.json()
    assert state["room"]["title"] == "一起聊电影"
    assert state["room"]["isCreatedByMe"]
    assert state["me"]["role"] == "owner"
    assert state["revision"] > before["revision"]
    assert state["me"]["canPublishAudio"] == before["me"]["canPublishAudio"]
    assert state["seats"] == before["seats"]
    listed = lab.client.get('/v1/rooms', headers=headers(owner)).json()["rooms"]
    assert next(item for item in listed if item["id"] == room_id)["title"] == "一起聊电影"
    library = lab.client.get('/v1/library', headers=headers(owner)).json()
    assert library["created"][0]["title"] == "一起聊电影"
    catalog_after = lab.client.get('/v1/room-catalog/changes', headers=headers(owner), params={"after": catalog_before, "waitSeconds": 0}).json()
    assert catalog_after["changed"] and catalog_after["revision"] > catalog_before
    repeated = lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(owner), json={"title": "一起聊电影"}).json()
    assert repeated["revision"] == state["revision"], "Idempotent retry cannot invent a new room revision"


def test_title_update_rejects_member_and_admin_and_closed_room(lab):
    owner, room = joined_owner(lab)
    guest = login(lab, "朋友")
    room_id = room["id"]
    assert lab.client.post(f'/v1/rooms/{room_id}/token', headers=headers(guest)).status_code == 200
    lab.rtc.rooms[room_id].add(guest["user"]["id"])
    for role in ["member", "admin"]:
        with lab.app.state.db:
            lab.app.state.db.execute("UPDATE room_members SET role=? WHERE room_id=? AND user_id=?", (role, room_id, guest["user"]["id"]))
        assert lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(guest), json={"title": "不能改"}).status_code == 403
    assert lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(owner), json={"status": "ended"}).status_code == 200
    assert lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(owner), json={"title": "不能复活"}).status_code == 409


@pytest.mark.parametrize('payload', [
    {}, {"title": "name", "status": "ended"}, {"title": None},
    {"title": "name", "hostID": "other"}, {"title": "name", "category": "other"},
    {"title": "a" * 41}, {"title": "中" * 34}, {"title": "a\x00b"}, {"title": "a\nb"},
])
def test_title_update_rejects_invalid_shape_or_text_without_mutation(lab, payload):
    owner, room = joined_owner(lab)
    response = lab.client.patch(f'/v1/rooms/{room["id"]}', headers=headers(owner), json=payload)
    assert response.status_code == 422, response.text
    assert lab.app.state.db.execute('SELECT title FROM rooms WHERE id=?', (room["id"],)).fetchone()[0] == room["title"]


def test_empty_rename_restores_default_and_transport_failure_cannot_commit(lab):
    owner, room = joined_owner(lab)
    room_id = room["id"]
    restored = lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(owner), json={"title": ""})
    assert restored.status_code == 200
    assert restored.json()["room"]["title"] == "小岛的房间"
    lab.rtc.unavailable = True
    failed = lab.client.patch(f'/v1/rooms/{room_id}', headers=headers(owner), json={"title": "不应提交"})
    assert failed.status_code == 503
    assert lab.app.state.db.execute('SELECT title FROM rooms WHERE id=?', (room_id,)).fetchone()[0] == "小岛的房间"
