"""App backgrounding is not a disconnect or a REST heartbeat obligation."""
import asyncio
import hashlib
import time

import pytest

from conftest import create_room
from test_account_bridge import account_service, exchange, profile
from test_ordered_rooms import approve, signal_connection
from test_room_actions import setup_room, state, token


def observe_next_maintenance(lab, settled=lambda: True):
    """Observe a real maintenance tick without making any client API request."""
    observed = asyncio.Event()
    original = lab.rtc.participants

    async def participants(room_id):
        result = await original(room_id)
        observed.set()
        return result

    lab.rtc.participants = participants

    async def wait():
        await asyncio.wait_for(observed.wait(), timeout=7)
        # Reconciliation follows the SFU snapshot on the same event loop. Allow
        # it to finish before inspecting its durable result from the test.
        await asyncio.sleep(0)
        for _ in range(100):
            if settled():
                return
            await asyncio.sleep(.01)
        raise AssertionError('Maintenance did not finish the expected cleanup')

    return wait


def test_connected_background_owner_and_speaker_need_no_rest_heartbeat(lab, monkeypatch):
    clock = [int(time.time())]
    monkeypatch.setattr('app.main.time.time', lambda: clock[0])
    room, (owner, speaker), tokens = setup_room(lab)
    approve(lab, room, owner, speaker)
    for raw in tokens:
        connection = signal_connection(lab, raw)
        connection.upstream_connected_at = clock[0]
        connection.upstream_connected = True
    before = state(lab, room, owner)
    generations = dict(lab.app.state.db.execute(
        'SELECT user_id,generation FROM room_members WHERE room_id=?', (room['id'],)))
    assert all(member['online'] and member['canPublishAudio'] for member in before['members'])

    wait = observe_next_maintenance(lab)
    # Both clients stop REST entirely for ten simulated minutes, exceeding both
    # disconnect grace periods. Their actual SFU and signal connections remain.
    clock[0] += 600
    lab.client.portal.call(wait)

    assert lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'active'
    members = lab.app.state.db.execute('''SELECT m.user_id,m.active,m.generation,m.signal_disconnected,p.offline_since
        FROM room_members m JOIN room_presence p USING(room_id,user_id) WHERE m.room_id=?''', (room['id'],)).fetchall()
    assert len(members) == 2
    assert all(member['active'] and member['generation'] == generations[member['user_id']]
               and not member['signal_disconnected'] and member['offline_since'] is None for member in members)
    assert not lab.rtc.removed
    assert lab.rtc.permissions[(room['id'], speaker['user']['id'])]['audio']
    after = state(lab, room, speaker)
    assert all(member['online'] and member['canPublishAudio'] and member['reconnectDeadline'] is None
               for member in after['members'])
    assert [seat['userID'] for seat in after['seats'][:2]] == [owner['user']['id'], speaker['user']['id']]


def test_bridge_lease_renewal_keeps_existing_connections_past_initial_expiry(account_service, monkeypatch):
    service = account_service
    clock = [int(time.time())]
    monkeypatch.setattr('app.main.time.time', lambda: clock[0])
    owner_auth = hashlib.sha256(b'source-session-1').hexdigest()
    speaker_auth = hashlib.sha256(b'source-session-speaker').hexdigest()
    owner_profile = profile()
    speaker_profile = profile('发言成员', 'kiki_abcdef0123456789')
    owner = exchange(service, auth=owner_auth, user=owner_profile).json()
    speaker = exchange(service, auth=speaker_auth, user=speaker_profile).json()
    room = create_room(service, owner)
    tokens = [token(service, room, account) for account in (owner, speaker)]
    approve(service, room, owner, speaker)
    connections = []
    for raw in tokens:
        connection = signal_connection(service, raw)
        connection.upstream_connected_at = clock[0]
        connection.upstream_connected = True
        connections.append(connection)
    state(service, room, owner)
    initial_expiry = min(owner['expiresAt'], speaker['expiresAt'])
    original_members = {row['user_id']: (row['session_hash'], row['generation'])
        for row in service.app.state.db.execute('SELECT * FROM room_members WHERE room_id=?', (room['id'],))}

    # Exercise the signed account-service exchange, rather than manually
    # changing expiry in SQLite. Renewing the same source grant extends its
    # existing voice session and needs no websocket replacement or room rejoin.
    clock[0] += 600
    renewed = []
    for authorization, user_profile, account in (
            (owner_auth, owner_profile, owner), (speaker_auth, speaker_profile, speaker)):
        response = exchange(service, auth=authorization, user=user_profile)
        assert response.status_code == 200, response.text
        value = response.json()
        assert value['token'] == account['token'] and value['expiresAt'] > account['expiresAt']
        renewed.append(value)

    wait = observe_next_maintenance(service)
    clock[0] = initial_expiry + 1
    assert clock[0] < min(account['expiresAt'] for account in renewed)
    service.client.portal.call(wait)

    assert not service.rtc.removed
    for connection in connections:
        assert service.app.state.signal._current[(room['id'], connection.user_id)] is connection
        assert connection.upstream_connected and not connection.revoked.is_set()
    current_members = {row['user_id']: (row['session_hash'], row['generation'])
        for row in service.app.state.db.execute('SELECT * FROM room_members WHERE room_id=? AND active=1', (room['id'],))}
    assert current_members == original_members
    after = state(service, room, speaker)
    assert all(member['online'] and member['canPublishAudio'] and member['reconnectDeadline'] is None
               for member in after['members'])
    assert [seat['userID'] for seat in after['seats'][:2]] == [owner['user']['id'], speaker['user']['id']]


@pytest.mark.parametrize('actor_index,grace', [(0, 15), (1, 60)])
def test_real_signal_disconnect_still_expires_without_rest_requests(lab, monkeypatch, actor_index, grace):
    clock = [int(time.time())]
    monkeypatch.setattr('app.main.time.time', lambda: clock[0])
    room, accounts, tokens = setup_room(lab)
    approve(lab, room, accounts[0], accounts[1])
    connections = []
    for raw in tokens:
        connection = signal_connection(lab, raw)
        connection.upstream_connected_at = clock[0]
        connection.upstream_connected = True
        connections.append(connection)
    state(lab, room, accounts[0])
    actor = accounts[actor_index]['user']['id']
    lab.client.portal.call(lab.app.state.signal_disconnected, connections[actor_index])
    # The SFU may briefly retain the old identity. It must not override actual
    # signal disconnect, even when no foreground client polls for state.
    assert actor in lab.rtc.rooms[room['id']]
    def cleanup_finished():
        if actor_index == 0:
            return lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'closed'
        return actor not in lab.rtc.rooms[room['id']]

    wait = observe_next_maintenance(lab, cleanup_finished)
    clock[0] += grace + 1
    lab.client.portal.call(wait)

    assert lab.app.state.db.execute('SELECT active FROM room_members WHERE room_id=? AND user_id=?',
                                   (room['id'], actor)).fetchone()[0] == 0
    status = lab.app.state.db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0]
    if actor_index == 0:
        assert status == 'closed' and room['id'] not in lab.rtc.rooms
    else:
        assert status == 'active' and actor not in lab.rtc.rooms[room['id']]
        assert lab.app.state.db.execute('SELECT user_id FROM room_seats WHERE room_id=? AND seat_index=2',
                                       (room['id'],)).fetchone()[0] is None
