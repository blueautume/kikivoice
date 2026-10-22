"""Behavioral checks of authoritative seats, roles and per-user revocation."""
import concurrent.futures
import hashlib
import json
import time

from fastapi import HTTPException
from fastapi.testclient import TestClient
import jwt
import pytest

from app.main import create_app
from app.signal_gateway import SignalConnection
from conftest import create_room, headers, login


def token(lab, room, account, online=True):
    response = lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(account))
    assert response.status_code == 200, response.text
    if online:
        lab.rtc.rooms[room['id']].add(account['user']['id'])
    return response.json()['participantToken']


def state(lab, room, account):
    response = lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(account))
    assert response.status_code == 200, response.text
    return response.json()


def act(lab, room, account, action, status=200, **fields):
    response = lab.client.post(f'/v1/rooms/{room["id"]}/actions', headers=headers(account), json={'action': action, **fields})
    assert response.status_code == status, response.text
    return response.json()


def setup_room(lab, count=2):
    accounts = [login(lab, f'User{i}') for i in range(count)]
    room = create_room(lab, accounts[0])
    tokens = [token(lab, room, account) for account in accounts]
    return room, accounts, tokens


def authorize(lab, raw):
    gateway = lab.app.state.signal
    claims = gateway.verify(raw)
    return lab.client.portal.call(lab.app.state.authorize_signal, claims, gateway._register(claims, validation=True))


def claims(lab, raw):
    return jwt.decode(raw, lab.settings.api_secret, algorithms=['HS256'])


def test_eight_seats_and_ninth_listener_are_distinct(lab):
    room, accounts, tokens = setup_room(lab, 9)
    initial = state(lab, room, accounts[0])
    assert len(initial['seats']) == 8 and len(initial['members']) == 9
    assert initial['seats'][0]['userID'] == accounts[0]['user']['id']
    assert initial['me']['role'] == 'owner' and initial['me']['canPublishAudio']
    for index, account in enumerate(accounts[1:8], 2):
        act(lab, room, account, 'request_seat')
        act(lab, room, accounts[0], 'approve_request', targetUserID=account['user']['id'], seatIndex=index)
    final = state(lab, room, accounts[-1])
    assert sum(seat['userID'] is not None for seat in final['seats']) == 8
    assert final['me']['seatIndex'] is None and not final['me']['canPublishAudio']
    assert final['me']['canPublishData'] and final['room']['audience'] == 9
    assert all(not claims(lab, raw)['video']['canPublish'] for raw in tokens[1:])
    assert final['revision'] > initial['revision']
    act(lab, room, accounts[-1], 'request_seat')
    result = act(lab, room, accounts[0], 'approve_request', targetUserID=accounts[-1]['user']['id'])
    assert result['queue'][0]['status'] == 'approved'


def test_queue_cancel_reject_and_approval_require_live_request(lab):
    room, (owner, member, other), _ = setup_room(lab, 3)
    first = act(lab, room, member, 'request_seat')
    duplicate = act(lab, room, member, 'request_seat')
    assert len(first['queue']) == len(duplicate['queue']) == 1
    act(lab, room, other, 'request_seat')
    queue = state(lab, room, owner)['queue']
    assert [entry['userID'] for entry in queue] == [member['user']['id'], other['user']['id']]
    assert [entry['position'] for entry in queue] == [1, 2]
    act(lab, room, member, 'cancel_request')
    act(lab, room, owner, 'approve_request', status=409, targetUserID=member['user']['id'])
    act(lab, room, owner, 'reject_request', targetUserID=other['user']['id'])
    assert not state(lab, room, owner)['queue']


def test_two_approvals_ignore_requested_index_and_take_next_ordered_seats(lab):
    room, (owner, one, two), _ = setup_room(lab, 3)
    for account in (one, two):
        act(lab, room, account, 'request_seat')
    def approve(account):
        return lab.client.post(f'/v1/rooms/{room["id"]}/actions', headers=headers(owner), json={
            'action': 'approve_request', 'targetUserID': account['user']['id'], 'seatIndex': 2}).status_code
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(approve, (one, two)))
    assert sorted(statuses) == [200, 200]
    final = state(lab, room, owner)
    assert sum(seat['userID'] is not None for seat in final['seats']) == 3
    assert not final['queue']
    assert {m['seatIndex'] for m in final['members']} == {1, 2, 3}


def test_invitation_requires_acceptance_is_private_and_expirable(lab):
    room, (owner, one, two), _ = setup_room(lab, 3)
    act(lab, room, owner, 'invite_seat', targetUserID=one['user']['id'], seatIndex=2)
    assert state(lab, room, one)['me']['seatIndex'] is None
    assert len(state(lab, room, one)['invitations']) == 1
    assert not state(lab, room, two)['invitations']
    act(lab, room, two, 'accept_invite', status=409)
    act(lab, room, one, 'decline_invite')
    act(lab, room, one, 'accept_invite', status=409)
    act(lab, room, owner, 'invite_seat', targetUserID=one['user']['id'], seatIndex=2)
    lab.app.state.db.execute('UPDATE seat_invitations SET expires_at=0')
    lab.app.state.db.commit()
    act(lab, room, one, 'accept_invite', status=409)
    act(lab, room, owner, 'invite_seat', targetUserID=one['user']['id'], seatIndex=2)
    act(lab, room, owner, 'invite_seat', targetUserID=two['user']['id'], seatIndex=2)
    act(lab, room, one, 'accept_invite')
    act(lab, room, two, 'accept_invite')
    assert state(lab, room, two)['me']['seatIndex'] == 3


def test_moderator_can_leave_and_rejoin_seat_without_losing_role(lab):
    room, (owner, member), _ = setup_room(lab)
    act(lab, room, owner, 'leave_seat', status=409)
    result = state(lab, room, owner)
    assert result['me']['role'] == 'owner' and result['me']['seatIndex'] == 1
    assert state(lab, room, owner)['me']['seatIndex'] == 1
    act(lab, room, owner, 'set_admin', targetUserID=member['user']['id'], enabled=True)
    result = act(lab, room, member, 'request_seat')
    assert result['me']['seatRequestStatus'] == 'pending'
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    result = state(lab, room, member)
    assert result['me']['role'] == 'admin' and result['me']['seatIndex'] == 2
    assert not result['queue']
    act(lab, room, member, 'leave_seat')
    assert state(lab, room, member)['me']['role'] == 'admin'


def test_seat_move_and_locks_are_authoritative(lab):
    room, (owner, member), _ = setup_room(lab)
    act(lab, room, member, 'move_seat', status=409, seatIndex=2)
    act(lab, room, owner, 'lock_seat', seatIndex=2, enabled=True)
    act(lab, room, member, 'request_seat')
    result = act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    assert next(m for m in result['members'] if m['userID'] == member['user']['id'])['seatIndex'] == 3
    act(lab, room, member, 'move_seat', status=409, seatIndex=2)
    act(lab, room, member, 'move_seat', status=409, seatIndex=4)
    result = act(lab, room, owner, 'lock_audio', seatIndex=3, enabled=True)
    muted = next(m for m in result['members'] if m['userID'] == member['user']['id'])
    assert muted['seatIndex'] == 3 and not muted['canPublishAudio']
    assert lab.rtc.permissions[(room['id'], member['user']['id'])]['audio'] is False
    assert (room['id'], member['user']['id']) in lab.rtc.muted
    act(lab, room, member, 'move_seat', status=409, seatIndex=5)
    act(lab, room, owner, 'lock_audio', seatIndex=3, enabled=False)
    assert state(lab, room, member)['me']['canPublishAudio']
    act(lab, room, owner, 'lock_seat', seatIndex=3, enabled=True)
    assert state(lab, room, member)['me']['seatIndex'] is None


@pytest.mark.parametrize('action,fields', [
    ('approve_request', {'targetUserID': 'target'}), ('reject_request', {'targetUserID': 'target'}),
    ('invite_seat', {'targetUserID': 'target', 'seatIndex': 2}), ('remove_seat', {'targetUserID': 'target'}),
    ('lock_seat', {'seatIndex': 2, 'enabled': True}), ('lock_audio', {'seatIndex': 2, 'enabled': True}),
    ('mute_audio', {'targetUserID': 'target', 'enabled': True}), ('mute_chat', {'targetUserID': 'target', 'enabled': True}),
    ('set_admin', {'targetUserID': 'target', 'enabled': True}), ('kick', {'targetUserID': 'target'}),
    ('unban', {'targetUserID': 'target'})])
def test_listener_cannot_use_moderation_actions(lab, action, fields):
    room, (owner, member), _ = setup_room(lab)
    if 'targetUserID' in fields:
        fields = {**fields, 'targetUserID': owner['user']['id']}
    act(lab, room, member, action, status=403, **fields)


def test_admin_cannot_punish_owner_or_another_admin(lab):
    room, (owner, admin, peer, member), _ = setup_room(lab, 4)
    for account in (admin, peer):
        act(lab, room, owner, 'set_admin', targetUserID=account['user']['id'], enabled=True)
    for target in (owner, peer):
        for action in ('mute_audio', 'mute_chat', 'set_admin', 'remove_seat', 'kick'):
            fields = {'targetUserID': target['user']['id']}
            if action in ('mute_audio', 'mute_chat', 'set_admin'):
                fields['enabled'] = True
            act(lab, room, admin, action, status=403, **fields)
    act(lab, room, admin, 'lock_audio', status=403, seatIndex=1, enabled=True)
    act(lab, room, admin, 'mute_chat', targetUserID=member['user']['id'], enabled=True)
    assert state(lab, room, member)['me']['chatMuted']


def test_force_mute_and_chat_mute_also_replace_stale_jwt_permissions(lab):
    room, (owner, member), _ = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    speaker = token(lab, room, member)
    assert claims(lab, speaker)['video']['canPublish']
    act(lab, room, owner, 'mute_audio', targetUserID=member['user']['id'], enabled=True)
    act(lab, room, owner, 'mute_chat', targetUserID=member['user']['id'], enabled=True)
    permissions = lab.rtc.permissions[(room['id'], member['user']['id'])]
    assert not permissions['audio'] and not permissions['data']
    metadata = json.loads(permissions['metadata'])
    assert metadata['server']['userID'] == member['user']['id']
    assert metadata['server']['sessionHash'] == hashlib.sha256(member['token'].encode()).hexdigest()
    replacement = authorize(lab, speaker).authorization.upstream_token
    assert not claims(lab, replacement)['video']['canPublish']
    assert not claims(lab, replacement)['video']['canPublishData']
    act(lab, room, member, 'mute_audio', status=403, targetUserID=member['user']['id'], enabled=False)
    act(lab, room, owner, 'remove_seat', targetUserID=member['user']['id'])
    replacement = authorize(lab, speaker).authorization.upstream_token
    assert not claims(lab, replacement)['video']['canPublish']


def test_kick_ban_and_unban_require_new_admission(lab):
    room, (owner, member, other), tokens = setup_room(lab, 3)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'invite_seat', targetUserID=member['user']['id'], seatIndex=2)
    result = act(lab, room, owner, 'kick', targetUserID=member['user']['id'])
    assert result['bans'][0]['userID'] == member['user']['id']
    assert not result['queue'] and not result['invitations']
    assert not state(lab, room, other)['bans']
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(member)).status_code == 403
    removed = lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member))
    assert removed.status_code == 403 and '已被移出房间' in removed.json()['detail']
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])
    act(lab, room, owner, 'unban', targetUserID=member['user']['id'])
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])
    token(lab, room, member)
    assert state(lab, room, member)['me']['seatIndex'] is None


def test_permission_failure_disconnects_instead_of_claiming_unsafe_success(lab):
    room, (owner, member), _ = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    lab.rtc.permission_failure = True
    result = act(lab, room, owner, 'mute_audio', targetUserID=member['user']['id'], enabled=True)
    assert not next(m for m in result['members'] if m['userID'] == member['user']['id'])['canPublishAudio']
    assert member['user']['id'] not in lab.rtc.rooms[room['id']]
    # If both update and removal fail, durable denial is retained and 503 returned.
    lab.rtc.remove_failure = True
    act(lab, room, owner, 'mute_chat', status=503, targetUserID=member['user']['id'], enabled=True)
    assert lab.app.state.db.execute('SELECT COUNT(*) FROM media_cleanup').fetchone()[0] == 1
    lab.rtc.permission_failure = lab.rtc.remove_failure = False
    state(lab, room, owner)
    assert lab.app.state.db.execute('SELECT COUNT(*) FROM media_cleanup').fetchone()[0] == 0


@pytest.mark.parametrize('route,method', [('/v1/auth/logout','post'),('/v1/account','delete'),('/v1/me/legal-consent','delete')])
def test_member_termination_preserves_other_rooms_and_members(lab, route, method):
    room, (owner, member, other), tokens = setup_room(lab, 3)
    unrelated = create_room(lab, other)
    token(lab, unrelated, other)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    assert getattr(lab.client, method)(route, headers=headers(member)).status_code == 200
    assert room['id'] in lab.rtc.rooms and unrelated['id'] in lab.rtc.rooms
    assert lab.rtc.rooms[room['id']] == {owner['user']['id'], other['user']['id']}
    assert next(s for s in state(lab, room, owner)['seats'] if s['index'] == 2)['userID'] is None
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])
    assert authorize(lab, tokens[0]).user_id == owner['user']['id']


@pytest.mark.parametrize('route,method', [('/v1/auth/logout','post'),('/v1/account','delete'),('/v1/me/legal-consent','delete')])
def test_owner_termination_closes_room_even_with_online_admin(lab, route, method):
    room, (owner, member, admin), tokens = setup_room(lab, 3)
    act(lab, room, owner, 'set_admin', targetUserID=admin['user']['id'], enabled=True)
    assert getattr(lab.client, method)(route, headers=headers(owner)).status_code == 200
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(admin)).status_code == 409
    assert room['id'] not in lab.rtc.rooms
    assert lab.app.state.db.execute('SELECT owner_id FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == owner['user']['id']
    for raw in tokens:
        with pytest.raises(HTTPException): authorize(lab, raw)


def test_owner_explicit_leave_closes_room_and_cannot_restore_it(lab):
    room, (owner, member, admin), _ = setup_room(lab, 3)
    act(lab, room, owner, 'set_admin', targetUserID=admin['user']['id'], enabled=True)
    lab.rtc.rooms[room['id']].discard(admin['user']['id'])
    assert lab.client.post(f'/v1/rooms/{room["id"]}/leave', headers=headers(owner)).status_code == 200
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 409
    assert lab.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(owner)).status_code == 409
    assert room['id'] not in lab.rtc.rooms


def test_member_logout_cleanup_failure_is_durable_and_does_not_close_room(lab):
    room, (owner, member), tokens = setup_room(lab)
    lab.rtc.remove_failure = True
    assert lab.client.post('/v1/auth/logout', headers=headers(member)).status_code == 503
    assert room['id'] in lab.rtc.rooms and owner['user']['id'] in lab.rtc.rooms[room['id']]
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])
    lab.rtc.remove_failure = False
    # No revoked bearer is needed for recovery.
    state(lab, room, owner)
    assert member['user']['id'] not in lab.rtc.rooms[room['id']]
    assert lab.app.state.db.execute('SELECT COUNT(*) FROM media_cleanup').fetchone()[0] == 0


def test_leave_releases_queue_invite_and_invalidates_prior_token(lab):
    room, (owner, member), tokens = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'invite_seat', targetUserID=member['user']['id'], seatIndex=2)
    assert lab.client.post(f'/v1/rooms/{room["id"]}/leave', headers=headers(member)).status_code == 200
    result = state(lab, room, owner)
    assert not result['queue'] and not result['invitations']
    assert lab.client.get('/v1/me', headers=headers(member)).status_code == 200
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])
    fresh = token(lab, room, member)
    assert authorize(lab, fresh).user_id == member['user']['id']
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])


def test_restarted_backend_recovers_offline_seats_after_persisted_grace(lab):
    room, (owner, member), tokens = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    lab.rtc.rooms[room['id']].discard(member['user']['id'])
    # New process must discover offline participants even without a disconnect callback.
    with TestClient(create_app(lab.settings, lab.rtc)) as restarted:
        response = restarted.get(f'/v1/rooms/{room["id"]}/state', headers=headers(owner))
        assert response.status_code == 200
        assert any(m['userID'] == member['user']['id'] for m in response.json()['members'])
        lab.app.state.db.execute('UPDATE room_presence SET offline_since=? WHERE room_id=? AND user_id=?', (int(time.time())-61, room['id'], member['user']['id']))
        lab.app.state.db.commit()
        response = restarted.get(f'/v1/rooms/{room["id"]}/state', headers=headers(owner))
        assert response.status_code == 200
        assert not any(m['userID'] == member['user']['id'] for m in response.json()['members'])
        assert room['id'] in lab.rtc.rooms


def test_just_issued_token_and_short_disconnect_keep_reserved_seat(lab):
    room, (owner, member), _ = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    lab.rtc.rooms[room['id']].discard(member['user']['id'])
    result = state(lab, room, owner)
    assert next(m for m in result['members'] if m['userID'] == member['user']['id'])['seatIndex'] == 2
    lab.rtc.rooms[room['id']].add(member['user']['id'])
    state(lab, room, owner)
    since = lab.app.state.db.execute('SELECT offline_since FROM room_presence WHERE room_id=? AND user_id=?', (room['id'], member['user']['id'])).fetchone()[0]
    assert since is None
    fresh = login(lab)
    token(lab, room, fresh, online=False)
    assert state(lab, room, fresh)['me']['online'] is False


def test_action_shape_and_membership_prevent_identity_forgery(lab):
    room, (owner, member), _ = setup_room(lab)
    outsider = login(lab)
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(outsider)).status_code == 403
    act(lab, room, member, 'request_seat', status=422, targetUserID=owner['user']['id'])
    act(lab, room, owner, 'lock_seat', status=422, seatIndex=9, enabled=True)
    act(lab, room, owner, 'mute_audio', status=422, targetUserID=member['user']['id'])
    act(lab, room, owner, 'mute_audio', status=422, targetUserID=member['user']['id'], enabled='true')


def test_expired_owner_session_closes_live_room(lab):
    room, (owner, member), tokens = setup_room(lab)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE sessions SET expires_at=0 WHERE user_id=?', (owner['user']['id'],))
    assert lab.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 409
    assert room['id'] not in lab.rtc.rooms
    for raw in tokens:
        with pytest.raises(HTTPException): authorize(lab, raw)


def test_deletion_failure_recovers_without_bearer_and_preserves_other_members(lab):
    room, (owner, member), _ = setup_room(lab)
    lab.rtc.remove_failure = True
    assert lab.client.delete('/v1/account', headers=headers(member)).status_code == 503
    row = lab.app.state.db.execute('SELECT completed_at FROM deletion_requests WHERE user_id=?', (member['user']['id'],)).fetchone()
    assert row[0] is None
    lab.rtc.remove_failure = False
    state(lab, room, owner)
    user = lab.app.state.db.execute('SELECT * FROM users WHERE id=?', (member['user']['id'],)).fetchone()
    assert user['deleted'] and user['name'] == '已注销'
    assert lab.rtc.rooms[room['id']] == {owner['user']['id']}


def test_permission_change_waits_for_pending_signal_before_sfu_update(lab):
    room, (owner, member), _ = setup_room(lab)
    events = []
    original_barrier = lab.app.state.signal.close_pending_identity
    original_update = lab.rtc.update_permissions
    async def barrier(room_id, user_id):
        # DB authority is already committed before the handshake barrier.
        persisted = lab.app.state.db.execute('SELECT chat_muted FROM room_members WHERE room_id=? AND user_id=?', (room_id, user_id)).fetchone()[0]
        assert persisted == 1
        events.append('barrier')
        return await original_barrier(room_id, user_id)
    async def update(room_id, user_id, **kwargs):
        assert events == ['barrier']
        events.append('sfu')
        return await original_update(room_id, user_id, **kwargs)
    lab.app.state.signal.close_pending_identity = barrier
    lab.rtc.update_permissions = update
    act(lab, room, owner, 'mute_chat', targetUserID=member['user']['id'], enabled=True)
    assert events == ['barrier', 'sfu']


@pytest.mark.parametrize('online_successor', [True, False])
def test_restart_recovers_committed_owner_departure_by_closing(lab, online_successor):
    room, (owner, member), _ = setup_room(lab)
    db = lab.app.state.db
    # Fault injection: the owner departure transaction committed, then the process
    # stopped before the SFU call and follow-up close/transfer could execute.
    with db:
        db.execute("UPDATE room_members SET active=0,generation=generation+1,role='member' WHERE room_id=? AND user_id=?", (room['id'], owner['user']['id']))
        db.execute('UPDATE room_seats SET user_id=NULL WHERE room_id=? AND user_id=?', (room['id'], owner['user']['id']))
        db.execute("INSERT INTO media_cleanup VALUES(?,?,'remove')", (room['id'], owner['user']['id']))
    if not online_successor:
        lab.rtc.rooms[room['id']].discard(member['user']['id'])
    with TestClient(create_app(lab.settings, lab.rtc)) as restarted:
        assert restarted.get(f'/v1/rooms/{room["id"]}/state', headers=headers(member)).status_code == 409
        assert room['id'] not in lab.rtc.rooms
        assert db.execute('SELECT status FROM rooms WHERE id=?', (room['id'],)).fetchone()[0] == 'closed'
        assert db.execute('SELECT COUNT(*) FROM media_cleanup').fetchone()[0] == 0
