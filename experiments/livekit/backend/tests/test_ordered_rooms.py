"""Ordered approval, temporary presence and host-owned room lifecycle."""
import asyncio
import hashlib
import secrets
import time

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from app.main import create_app
from conftest import create_room, headers, login
from test_room_actions import act, authorize, setup_room, state, token


def approve(lab, room, owner, member, index=8):
    act(lab, room, member, 'request_seat')
    return act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'], seatIndex=index)


def backdate(lab, room, account, seconds):
    now = int(time.time())
    with lab.app.state.db:
        lab.app.state.db.execute('''INSERT INTO room_presence VALUES(?,?,?)
            ON CONFLICT(room_id,user_id) DO UPDATE SET offline_since=excluded.offline_since''',
            (room['id'], account['user']['id'], now-seconds))
    return now-seconds


def test_host_fixed_one_and_approval_ignores_legacy_manual_index(lab):
    room, (owner, first, second), _ = setup_room(lab, 3)
    approve(lab, room, owner, first, index=8)
    result = approve(lab, room, owner, second, index=1)
    assert result['seatMode'] == 'ordered'
    assert (result['disconnectGraceSeconds'], result['ownerDisconnectGraceSeconds']) == (60, 15)
    assert [s['userID'] for s in result['seats'][:3]] == [a['user']['id'] for a in (owner, first, second)]
    act(lab, room, owner, 'leave_seat', status=409)
    act(lab, room, owner, 'move_seat', status=409, seatIndex=8)
    act(lab, room, owner, 'lock_seat', status=409, seatIndex=1, enabled=True)
    assert state(lab, room, owner)['me']['seatIndex'] == 1


def test_full_seats_keep_approved_queue_in_approval_order_then_compact_and_promote(lab):
    room, accounts, _ = setup_room(lab, 11)
    owner = accounts[0]
    for account in accounts[1:8]: approve(lab, room, owner, account)
    for account in accounts[8:]: act(lab, room, account, 'request_seat')
    # Approving in reverse request order is intentional; same-second approvals
    # retain their authoritative sequence, including duplicate approval retries.
    act(lab, room, owner, 'approve_request', targetUserID=accounts[9]['user']['id'])
    act(lab, room, owner, 'approve_request', targetUserID=accounts[8]['user']['id'])
    result = act(lab, room, owner, 'approve_request', targetUserID=accounts[9]['user']['id'])
    assert [q['userID'] for q in result['queue']] == [a['user']['id'] for a in (accounts[9], accounts[8], accounts[10])]
    assert [q['status'] for q in result['queue']] == ['approved', 'approved', 'pending']
    assert state(lab, room, accounts[9])['me']['seatRequestStatus'] == 'approved'
    act(lab, room, accounts[2], 'leave_seat')
    expected = [accounts[0], accounts[1], *accounts[3:8], accounts[9]]
    result = state(lab, room, owner)
    assert [s['userID'] for s in result['seats']] == [a['user']['id'] for a in expected]
    assert state(lab, room, accounts[9])['me']['seatRequestStatus'] == 'seated'
    assert lab.rtc.permissions[(room['id'], accounts[3]['user']['id'])]['metadata']
    act(lab, room, accounts[1], 'leave_seat')
    assert state(lab, room, accounts[8])['me']['seatIndex'] == 8
    result = state(lab, room, accounts[10])
    assert result['me']['seatRequestStatus'] == 'pending' and result['me']['seatIndex'] is None


def test_rejected_application_is_visible_until_new_request_or_cancel(lab):
    room, (owner, member), _ = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'reject_request', targetUserID=member['user']['id'])
    result = state(lab, room, member)
    assert result['me']['seatRequestStatus'] == 'rejected' and not result['queue']
    assert act(lab, room, member, 'request_seat')['me']['seatRequestStatus'] == 'pending'
    assert act(lab, room, member, 'cancel_request')['me']['seatRequestStatus'] == 'none'


def test_temporary_offline_keeps_original_seat_and_generation_then_recovers(lab, monkeypatch):
    now = int(time.time())
    monkeypatch.setattr('app.main.time.time', lambda: now)
    room, (owner, first, second), tokens = setup_room(lab, 3)
    approve(lab, room, owner, first)
    approve(lab, room, owner, second)
    before = authorize(lab, tokens[1]).generation
    lab.rtc.rooms[room['id']].discard(first['user']['id'])
    since = backdate(lab, room, first, 59)
    result = state(lab, room, owner)
    member = next(m for m in result['members'] if m['userID'] == first['user']['id'])
    assert member['online'] is False and member['seatIndex'] == 2
    assert member['offlineSince'] == since and member['reconnectDeadline'] == since+60
    assert state(lab, room, second)['me']['seatIndex'] == 3
    fresh = token(lab, room, first)
    restored = state(lab, room, first)['me']
    assert restored['seatIndex'] == 2 and restored['online'] is True
    assert restored['offlineSince'] is None and restored['reconnectDeadline'] is None
    assert authorize(lab, fresh).generation == before


def test_long_offline_member_is_removed_and_later_speakers_move_forward(lab):
    room, (owner, first, second), tokens = setup_room(lab, 3)
    approve(lab, room, owner, first)
    approve(lab, room, owner, second)
    lab.rtc.rooms[room['id']].discard(first['user']['id'])
    backdate(lab, room, first, 61)
    result = state(lab, room, second)
    assert result['me']['seatIndex'] == 2
    assert all(m['userID'] != first['user']['id'] for m in result['members'])
    assert not lab.app.state.db.execute('SELECT 1 FROM seat_request_states WHERE user_id=?', (first['user']['id'],)).fetchone()
    with pytest.raises(HTTPException): authorize(lab, tokens[1])


def test_host_disconnect_grace_then_close_even_with_online_admin(lab, monkeypatch):
    now = int(time.time())
    monkeypatch.setattr('app.main.time.time', lambda: now)
    room, (owner, member), tokens = setup_room(lab)
    act(lab, room, owner, 'set_admin', targetUserID=member['user']['id'], enabled=True)
    lab.rtc.rooms[room['id']].discard(owner['user']['id'])
    since = backdate(lab, room, owner, 14)
    result = state(lab, room, member)
    host = next(m for m in result['members'] if m['userID'] == owner['user']['id'])
    assert host['role'] == 'owner' and host['seatIndex'] == 1 and host['online'] is False
    assert host['offlineSince'] == since and host['reconnectDeadline'] == since+15
    backdate(lab, room, owner, 16)
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 409
    assert room['id'] not in lab.rtc.rooms
    assert lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'closed'
    for raw in tokens:
        with pytest.raises(HTTPException): authorize(lab, raw)


def test_host_recovers_within_grace_without_losing_owner_or_first_seat(lab):
    room, (owner, member), tokens = setup_room(lab)
    lab.rtc.rooms[room['id']].discard(owner['user']['id'])
    backdate(lab, room, owner, 12)
    assert state(lab, room, member)['room']['hostID'] == owner['user']['id']
    fresh = token(lab, room, owner)
    result = state(lab, room, owner)
    assert result['me']['role'] == 'owner' and result['me']['seatIndex'] == 1
    assert result['me']['offlineSince'] is None and result['me']['online']
    assert authorize(lab, fresh).generation == authorize(lab, tokens[0]).generation


def test_owner_timeout_cleanup_survives_restart_and_sfu_delete_failure(lab):
    room, (owner, member), _ = setup_room(lab)
    lab.rtc.rooms[room['id']].discard(owner['user']['id'])
    backdate(lab, room, owner, 16)
    lab.rtc.delete_failure = True
    with TestClient(create_app(lab.settings, lab.rtc)) as restarted:
        assert restarted.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 409
        assert lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'closing'
        assert lab.app.state.db.execute('SELECT COUNT(*) FROM room_members WHERE room_id=? AND active=1', (room['id'],)).fetchone()[0] == 0
        lab.rtc.delete_failure = False
        assert restarted.get('/v1/rooms', headers=headers(member)).status_code == 200
        assert room['id'] not in lab.rtc.rooms
        assert lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'closed'


def test_background_maintenance_closes_expired_host_without_state_requests(lab):
    room, (owner, _), _ = setup_room(lab)
    lab.rtc.rooms[room['id']].discard(owner['user']['id'])
    backdate(lab, room, owner, 16)
    async def wait_for_maintenance():
        for _ in range(120):
            if lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'closed':
                return
            await asyncio.sleep(.05)
        raise AssertionError('Background maintenance did not close the room')
    lab.client.portal.call(wait_for_maintenance)
    assert room['id'] not in lab.rtc.rooms


def test_sfu_query_failure_does_not_guess_owner_disconnect(lab):
    room, (owner, member), _ = setup_room(lab)
    backdate(lab, room, owner, 16)
    original = lab.rtc.participants
    async def unavailable(_): raise ConnectionError()
    lab.rtc.participants = unavailable
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 503
    assert lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'active'
    lab.rtc.participants = original
    assert state(lab, room, owner)['me']['offlineSince'] is None


def test_stale_sfu_presence_and_old_disconnect_cannot_override_reconnect(lab):
    room, (owner, member), tokens = setup_room(lab)
    gateway = lab.app.state.signal
    verified = gateway.verify(tokens[0])
    first = lab.client.portal.call(lab.app.state.authorize_signal, verified, gateway._register(verified))
    first.upstream_settled.set()
    lab.client.portal.call(lab.app.state.signal_disconnected, first)
    result = state(lab, room, member)
    host = next(m for m in result['members'] if m['userID'] == owner['user']['id'])
    assert not host['online'] and host['offlineSince'] is not None  # SFU still lists the stale identity.
    replacement = lab.client.portal.call(lab.app.state.authorize_signal, verified, gateway._register(verified))
    replacement.upstream_settled.set()
    assert replacement is not first
    lab.client.portal.call(lab.app.state.signal_disconnected, first)
    pending = state(lab, room, member)
    assert next(m for m in pending['members'] if m['userID'] == owner['user']['id'])['online'] is False
    replacement.upstream_connected_at = time.time()
    replacement.upstream_connected = True
    assert state(lab, room, owner)['me']['online'] is True


def test_room_member_preview_uses_online_real_profiles_and_bilateral_blocks(lab):
    room, accounts, _ = setup_room(lab, 9)
    owner, viewer = accounts[:2]
    offline = accounts[2]
    lab.rtc.rooms[room['id']].discard(offline['user']['id'])
    blocked = accounts[3]
    assert lab.client.put('/v1/safety/blocks/'+viewer['user']['id'], headers=headers(blocked)).status_code == 200
    result = state(lab, room, viewer)
    preview = result['room']['memberPreview']
    assert len(preview) == 5 and len({p['userID'] for p in preview}) == 5
    assert {p['userID'] for p in preview}.isdisjoint({owner['user']['id'], offline['user']['id'], blocked['user']['id']})
    names = {a['user']['id']: a['user']['name'] for a in accounts}
    assert all(p['name'] == names[p['userID']] and p['avatarIndex'] == 0 and p['avatarURL'] is None for p in preview)
    card = next(r for r in lab.client.get('/v1/rooms', headers=headers(viewer)).json()['rooms'] if r['id'] == room['id'])
    assert card['memberPreview'] == preview and card['audience'] == 8


def test_confirmed_missing_sfu_room_clears_seats_queue_and_approval_state(lab):
    room, (owner, member), tokens = setup_room(lab)
    act(lab, room, member, 'request_seat')
    lab.rtc.rooms.pop(room['id'])
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 409
    for table in ('seat_requests', 'seat_request_states', 'seat_invitations', 'room_presence'):
        assert not lab.app.state.db.execute(f'SELECT 1 FROM {table} WHERE room_id=?', (room['id'],)).fetchone()
    assert not lab.app.state.db.execute('SELECT 1 FROM room_seats WHERE room_id=? AND user_id IS NOT NULL', (room['id'],)).fetchone()
    for raw in tokens:
        with pytest.raises(HTTPException): authorize(lab, raw)


def signal_connection(lab, raw):
    gateway = lab.app.state.signal
    verified = gateway.verify(raw)
    connection = lab.client.portal.call(lab.app.state.authorize_signal, verified, gateway._register(verified))
    # This focused test has no asynchronous upstream task to settle in finally.
    connection.upstream_settled.set()
    return connection


@pytest.mark.parametrize('actor_index,elapsed', [(0, 16), (1, 61)])
def test_expired_old_jwt_cannot_register_before_background_tick(lab, actor_index, elapsed):
    room, accounts, tokens = setup_room(lab)
    actor = accounts[actor_index]
    old = signal_connection(lab, tokens[actor_index])
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    backdate(lab, room, actor, elapsed)
    verified = lab.app.state.signal.verify(tokens[actor_index])
    registered = []
    def register(value):
        registered.append(value)
        return lab.app.state.signal._register(verified)(value)
    with pytest.raises(HTTPException) as error:
        lab.client.portal.call(lab.app.state.authorize_signal, verified, register)
    assert error.value.status_code == 403 and not registered
    if actor_index == 0:
        assert room['id'] not in lab.rtc.rooms
    else:
        assert room['id'] in lab.rtc.rooms
        assert lab.app.state.db.execute('SELECT active FROM room_members WHERE room_id=? AND user_id=?', (room['id'], actor['user']['id'])).fetchone()[0] == 0


def test_failed_reconnect_and_api_requests_never_extend_original_timer(lab, monkeypatch):
    now = int(time.time())
    monkeypatch.setattr('app.main.time.time', lambda: now)
    room, (owner, guest), tokens = setup_room(lab)
    old = signal_connection(lab, tokens[0])
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    since = backdate(lab, room, owner, 12)
    pending = signal_connection(lab, tokens[0])
    for _ in range(3):
        token(lab, room, owner)
        result = state(lab, room, guest)
        host = next(m for m in result['members'] if m['userID'] == owner['user']['id'])
        assert host['offlineSince'] == since and not host['online']
    lab.client.portal.call(lab.app.state.signal_disconnected, pending)
    assert lab.app.state.db.execute('SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?', (room['id'], owner['user']['id'])).fetchone()[0] == since


def test_late_upstream_handshake_does_not_resurrect_host(lab, monkeypatch):
    now = int(time.time())
    monkeypatch.setattr('app.main.time.time', lambda: now)
    room, (owner, guest), tokens = setup_room(lab)
    old = signal_connection(lab, tokens[0])
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    since = backdate(lab, room, owner, 12)
    pending = signal_connection(lab, tokens[0])
    pending.upstream_connected_at = since + 16
    pending.upstream_connected = True
    monkeypatch.setattr('app.main.time.time', lambda: now+4)
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(guest)).status_code == 409
    assert room['id'] not in lab.rtc.rooms


def test_signal_disconnect_flag_survives_restart_with_stale_sfu_identity(lab):
    room, (owner, guest), tokens = setup_room(lab)
    old = signal_connection(lab, tokens[0])
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    backdate(lab, room, owner, 12)
    assert owner['user']['id'] in lab.rtc.rooms[room['id']]
    with TestClient(create_app(lab.settings, lab.rtc)) as restarted:
        result = restarted.get(f'/v1/rooms/{room["id"]}/state', headers=headers(guest)).json()
        assert not next(m for m in result['members'] if m['userID'] == owner['user']['id'])['online']
        backdate(lab, room, owner, 16)
        assert restarted.get(f'/v1/rooms/{room["id"]}/state', headers=headers(guest)).status_code == 409
        assert room['id'] not in lab.rtc.rooms


def test_session_rotation_preserves_disconnect_clock_and_rejects_old_generation(lab):
    room, (owner, guest), tokens = setup_room(lab)
    old = signal_connection(lab, tokens[0])
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    since = backdate(lab, room, owner, 10)
    rotated = {**owner, 'token': secrets.token_urlsafe(32)}
    with lab.app.state.db:
        lab.app.state.db.execute('INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)',
            (hashlib.sha256(rotated['token'].encode()).hexdigest(), owner['user']['id'], int(time.time())+3600))
    fresh = token(lab, room, rotated)
    assert lab.app.state.db.execute('SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?', (room['id'], owner['user']['id'])).fetchone()[0] == since
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    with pytest.raises(HTTPException): authorize(lab, tokens[0])
    current = signal_connection(lab, fresh)
    current.upstream_connected_at = time.time()
    current.upstream_connected = True
    restored = state(lab, room, rotated)
    assert restored['me']['online'] and restored['me']['role'] == 'owner' and restored['me']['seatIndex'] == 1
    assert restored['me']['offlineSince'] is None


def test_timely_recovery_is_preserved_before_another_connection_attempt(lab, monkeypatch):
    now = int(time.time())
    monkeypatch.setattr('app.main.time.time', lambda: now)
    room, (owner, guest), tokens = setup_room(lab)
    old = signal_connection(lab, tokens[0])
    lab.client.portal.call(lab.app.state.signal_disconnected, old)
    since = backdate(lab, room, owner, 12)
    recovered = signal_connection(lab, tokens[0])
    recovered.upstream_connected_at = now
    recovered.upstream_connected = True
    # No intervening /state or background tick. A confirmed connection within
    # the previous deadline must start a fresh grace when it is replaced.
    monkeypatch.setattr('app.main.time.time', lambda: now+1)
    following = signal_connection(lab, tokens[0])
    assert following is not recovered
    new_since = lab.app.state.db.execute('SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?', (room['id'], owner['user']['id'])).fetchone()[0]
    assert new_since == now+1 and new_since != since
    pending = state(lab, room, guest)
    assert not next(m for m in pending['members'] if m['userID'] == owner['user']['id'])['online']
