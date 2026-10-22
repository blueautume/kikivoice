"""Admission protection, shared-network polling and reconnect reservations."""
from contextlib import contextmanager
import concurrent.futures
from dataclasses import replace
from types import SimpleNamespace
import time

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from app.main import create_app
from conftest import FakeLiveKit, create_room, headers, login
from test_room_actions import act, authorize, setup_room, state, token


@contextmanager
def limited_lab(lab, **changes):
    settings = replace(lab.settings, db_path=lab.settings.db_path+'.limited', **changes)
    rtc = FakeLiveKit(settings)
    app = create_app(settings, rtc)
    with TestClient(app) as client:
        yield SimpleNamespace(client=client, app=app, rtc=rtc, settings=settings,
                              consent=lab.consent, legal_path=lab.legal_path)


def test_capacity_defaults_are_small_single_server_protection(lab):
    assert (lab.settings.max_active_rooms, lab.settings.max_room_participants, lab.settings.max_total_participants) == (4, 32, 64)
    for changes in ({'max_active_rooms': 0}, {'max_room_participants': 7}, {'max_total_participants': 31}):
        with pytest.raises(RuntimeError):
            replace(lab.settings, **changes).validate()


def test_pending_admissions_count_toward_room_limit_and_duplicate_tokens_are_free(lab):
    with limited_lab(lab, max_room_participants=8, max_total_participants=16) as small:
        accounts = [login(small, f'User{i}') for i in range(9)]
        room = create_room(small, accounts[0])
        for account in accounts[:8]:
            token(small, room, account, online=False)
        assert not small.rtc.rooms[room['id']]
        for _ in range(3):
            token(small, room, accounts[1], online=False)
        response = small.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(accounts[-1]))
        assert response.status_code == 409
        assert small.app.state.db.execute('SELECT COUNT(*) FROM room_members WHERE active=1').fetchone()[0] == 8
        assert small.client.post(f'/v1/rooms/{room["id"]}/leave', headers=headers(accounts[1])).status_code == 200
        token(small, room, accounts[-1], online=False)


def test_concurrent_token_requests_cannot_overbook_reserved_admissions(lab):
    with limited_lab(lab, max_room_participants=8, max_total_participants=16) as small:
        accounts = [login(small, f'User{i}') for i in range(10)]
        room = create_room(small, accounts[0])
        def admit(account):
            return small.client.post(f'/v1/rooms/{room["id"]}/token', headers=headers(account)).status_code
        with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
            results = list(pool.map(admit, accounts[1:]))
        assert results.count(200) == 7 and results.count(409) == 2
        assert small.app.state.db.execute('SELECT COUNT(*) FROM room_members WHERE active=1').fetchone()[0] == 8


def test_total_admissions_protect_room_creation_and_new_tokens(lab):
    with limited_lab(lab, max_room_participants=8, max_total_participants=8) as small:
        owner, second, *listeners = [login(small, f'User{i}') for i in range(9)]
        first_room = create_room(small, owner)
        second_room = create_room(small, second)
        for account in listeners[:6]:
            token(small, first_room, account, online=False)
        denied = small.client.post(f'/v1/rooms/{second_room["id"]}/token', headers=headers(listeners[-1]))
        assert denied.status_code == 429 and denied.headers['Retry-After'] == '30'
        denied = small.client.post('/v1/rooms', headers=headers(listeners[-1]), json={'title': 'Excess', 'category': '闲聊', 'theme': 0, 'isLive': False})
        assert denied.status_code == 429
        assert small.client.post(f'/v1/rooms/{first_room["id"]}/leave', headers=headers(listeners[0])).status_code == 200
        token(small, second_room, listeners[-1], online=False)
        diagnostic = small.client.get('/v1/diagnostics', headers=headers(owner)).json()
        assert diagnostic['capacity']['admittedParticipants'] == 8
        assert diagnostic['capacity']['activeParticipants'] == 0
        assert diagnostic['capacity']['maxParticipantsTotal'] == 8


def test_concurrent_creates_obey_room_limit_and_closing_releases_admissions(lab):
    with limited_lab(lab, max_active_rooms=2, max_room_participants=8, max_total_participants=16) as small:
        accounts = [login(small, f'User{i}') for i in range(3)]
        def create(account):
            return small.client.post('/v1/rooms', headers=headers(account), json={'title': 'Room', 'category': '闲聊', 'theme': 0, 'isLive': False})
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            responses = list(pool.map(create, accounts))
        assert sorted(response.status_code for response in responses) == [200, 200, 429]
        index = next(i for i, response in enumerate(responses) if response.status_code == 200)
        room = responses[index].json()
        assert small.client.patch(f'/v1/rooms/{room["id"]}', headers=headers(accounts[index]), json={'status': 'closed'}).status_code == 200
        denied_index = next(i for i, response in enumerate(responses) if response.status_code == 429)
        assert create(accounts[denied_index]).status_code == 200


def test_signal_rechecks_capacity_even_with_already_signed_token(lab):
    room, (owner, member), tokens = setup_room(lab)
    # Model a runtime reduction below the number already reserved. The upstream
    # SFU must never be reached merely because a client has a previously valid JWT.
    for index in range(31):
        account = login(lab, f'User{index}')
        with lab.app.state.db:
            lab.app.state.db.execute('INSERT INTO room_members(room_id,user_id,session_hash,joined_at) VALUES(?,?,?,?)',
                (room['id'], account['user']['id'], 'x'*64, int(time.time())))
    with pytest.raises(HTTPException) as error:
        authorize(lab, tokens[1])
    assert error.value.status_code == 409


def test_network_recovery_preserves_seat_and_generation_at_59_seconds(lab):
    room, (owner, member), tokens = setup_room(lab)
    act(lab, room, member, 'request_seat')
    act(lab, room, owner, 'approve_request', targetUserID=member['user']['id'])
    generation = lab.app.state.db.execute('SELECT generation FROM room_members WHERE user_id=?', (member['user']['id'],)).fetchone()[0]
    lab.rtc.rooms[room['id']].discard(member['user']['id'])
    state(lab, room, owner)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE room_presence SET offline_since=? WHERE room_id=? AND user_id=?', (int(time.time())-59, room['id'], member['user']['id']))
    current = state(lab, room, owner)
    assert next(m for m in current['members'] if m['userID'] == member['user']['id'])['seatIndex'] == 2
    assert authorize(lab, tokens[1]).generation == generation
    # Repeated token fetch while recovering is also the same admission generation.
    fresh = token(lab, room, member, online=False)
    assert authorize(lab, fresh).generation == generation
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE room_presence SET offline_since=? WHERE room_id=? AND user_id=?', (int(time.time())-61, room['id'], member['user']['id']))
    current = state(lab, room, owner)
    assert all(m['userID'] != member['user']['id'] for m in current['members'])
    with pytest.raises(HTTPException):
        authorize(lab, tokens[1])


def test_seven_valid_sessions_on_one_ip_can_poll_and_manage_without_shared_240_limit(lab):
    with limited_lab(lab, rate_limit_enabled=True) as network:
        accounts = [login(network, f'User{i}') for i in range(7)]
        room = create_room(network, accounts[0])
        for account in accounts:
            token(network, room, account)
        # 7 x 40 = 280 room-state polls plus messages/diagnostics. Each session is
        # below its allowance and the shared address exceeds the old 240 limit.
        for _ in range(40):
            for account in accounts:
                response = network.client.get(f'/v1/rooms/{room["id"]}/state', headers=headers(account))
                assert response.status_code == 200, response.text
        act(network, room, accounts[1], 'request_seat')
        act(network, room, accounts[0], 'approve_request', targetUserID=accounts[1]['user']['id'])
        for account in accounts:
            assert network.client.get(f'/v1/rooms/{room["id"]}/messages', headers=headers(account)).status_code == 200
        # A single authenticated session still has a hard independent limit.
        response = None
        for _ in range(180):
            response = network.client.get('/v1/me', headers=headers(accounts[0]))
            if response.status_code == 429:
                break
        assert response.status_code == 429 and response.headers['Retry-After'] == '60'
        assert network.client.get('/v1/me', headers=headers(accounts[-1])).status_code == 200


def test_arbitrary_bearers_do_not_evade_anonymous_ip_limit(lab):
    with limited_lab(lab, rate_limit_enabled=True) as network:
        for index in range(240):
            # Every request has a distinct fake token, but they share one bucket.
            response = network.client.get('/v1/me', headers={'Authorization': 'Bearer '+format(index, '043x')})
            assert response.status_code == 401
        response = network.client.get('/v1/me', headers={'Authorization': 'Bearer '+'x'*43})
        assert response.status_code == 429


def test_api_restart_remains_available_when_separate_sfu_is_down(lab):
    room, (owner, member), _ = setup_room(lab)
    message = lab.client.post(f'/v1/rooms/{room["id"]}/messages', headers=headers(owner),
        json={'text': 'Expired private text', 'clientMessageID': '8b3a877c-b82b-4d83-805e-a0a43aec727c'})
    assert message.status_code == 200
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE room_messages SET created_at=0')
    class OfflineLiveKit(FakeLiveKit):
        async def participants(self, room_id):
            raise ConnectionError()
        async def remove_participant(self, room_id, user_id):
            raise ConnectionError()
    rtc = OfflineLiveKit(lab.settings)
    rtc.rooms = dict(lab.rtc.rooms)
    rtc.unavailable = True
    with TestClient(create_app(lab.settings, rtc)) as restarted:
        assert restarted.get('/health').status_code == 503
        # Text expiry is processed before the media await, so an SFU outage
        # cannot keep old content in the business query window.
        history = restarted.get(f'/v1/rooms/{room["id"]}/messages', headers=headers(owner))
        assert history.status_code == 200
        assert not history.json()['messages'] and history.json()['historyRevision'] == 1
        assert not lab.app.state.db.execute('SELECT 1 FROM room_messages').fetchone()
        assert restarted.get('/v1/me', headers=headers(member)).status_code == 200
        response = restarted.post('/v1/auth/logout', headers=headers(member))
        assert response.status_code == 503
        assert restarted.get('/v1/me', headers=headers(member)).status_code == 401
        # The failure keeps durable removal intent rather than falsely succeeding.
        assert lab.app.state.db.execute('SELECT 1 FROM media_cleanup WHERE user_id=?', (member['user']['id'],)).fetchone()
