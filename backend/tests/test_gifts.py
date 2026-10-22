"""Money-like state requires real transaction, replay and lifecycle checks."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import secrets
import sqlite3
import time
import uuid

from fastapi.testclient import TestClient
import pytest

from app import gifts
from app.gifts import GIFT_EVENT_SECONDS, INITIAL_DIAMONDS, NOTICE_VERSION
from app.main import create_app, Settings
from conftest import apple_settings
from test_api import client, login, authorization, create_room, current_legal_consent


def live_room(client, host):
    room = create_room(client, authorization(host))
    result = client.patch('/v1/rooms/' + room['id'], headers=authorization(host), json={'status': 'live'})
    assert result.status_code == 200
    return room


def payload(gift='heart', quantity=1, request_id=None):
    return {'giftID': gift, 'quantity': quantity, 'requestID': request_id or str(uuid.uuid4()),
            'noticeVersion': NOTICE_VERSION}


def send(client, sender, room, body=None):
    return client.post('/v1/rooms/' + room['id'] + '/gifts', headers=authorization(sender),
                       json=payload() if body is None else body)


def balance(client, account):
    result = client.get('/v1/me/wallet', headers=authorization(account))
    assert result.status_code == 200
    return result.json()['balance']


def batch_payload(recipients, gift='heart', quantity=1, request_id=None):
    return {**payload(gift, quantity, request_id), 'recipientIDs': [r['user']['sdkUserID'] for r in recipients]}


def send_batch(client, sender, room, body):
    return client.post('/v1/rooms/' + room['id'] + '/gifts/batch', headers=authorization(sender), json=body)


def visit_room(client, account, room):
    assert client.post('/v1/history/' + room['id'], headers=authorization(account)).status_code == 200


def test_batch_one_debit_multiple_deliveries_and_existing_event_contract(client):
    host, sender, listener = login(client, 'host'), login(client, 'sender'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, listener, room)
    result = send_batch(client, sender, room, batch_payload([listener, host], 'flower_rain', 10))
    assert result.status_code == 200
    sent = result.json()
    assert sent['recipientCount'] == 2 and sent['quantityPerRecipient'] == 10 and sent['totalCost'] == 1980
    assert sent['wallet']['balance'] == INITIAL_DIAMONDS - 1980
    assert {e['recipientID'] for e in sent['events']} == {r['user']['sdkUserID'] for r in (host, listener)}
    assert len({e['id'] for e in sent['events']}) == 2
    assert len({e['batchID'] for e in sent['events']}) == 1
    assert uuid.UUID(sent['events'][0]['batchID']).version == 4
    assert all(e['batchRecipientCount'] == 2 for e in sent['events'])
    assert all(e['quantity'] == 10 and e['unitPrice'] == 99 and e['totalCost'] == 990 for e in sent['events'])
    assert all(e['senderID'] == sender['user']['sdkUserID'] for e in sent['events'])
    polled = client.get('/v1/rooms/' + room['id'] + '/gifts', headers=authorization(listener), params={'after': 0})
    assert polled.json()['events'] == sent['events']
    assert balance(client, host) == balance(client, listener) == INITIAL_DIAMONDS
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] == 1
        assert db.execute('SELECT COUNT(*) FROM gift_batch_recipients').fetchone()[0] == 2


def test_batch_self_gifts_for_host_and_associated_listener(client):
    host, listener = login(client, 'host'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, listener, room)
    assert send_batch(client, host, room, batch_payload([host], quantity=99)).status_code == 200
    assert send_batch(client, listener, room, batch_payload([listener], quantity=10)).status_code == 200
    assert balance(client, host) == INITIAL_DIAMONDS - 99
    assert balance(client, listener) == INITIAL_DIAMONDS - 10


@pytest.mark.parametrize('recipients', [[], [''], [' '], ['a b'], ['a/b'], ['你好'], ['x', 'x'],
                                      [False], [123], ['x' * 129], 'somebody', ['x'] * 51])
def test_batch_rejects_empty_duplicate_or_illegal_recipient_ids(client, recipients):
    host = login(client)
    room = live_room(client, host)
    assert send_batch(client, host, room, {**payload(), 'recipientIDs': recipients}).status_code == 422
    assert balance(client, host) == INITIAL_DIAMONDS


@pytest.mark.parametrize('change', [{'quantity': 2}, {'quantity': True}, {'quantity': '10'}, {'quantity': 100},
                                    {'unitPrice': 1}, {'totalCost': 1}, {'recipientID': 'x'}, {'balance': 1}])
def test_batch_rejects_client_supplied_economics_and_invalid_quantity(client, change):
    host = login(client)
    room = live_room(client, host)
    assert send_batch(client, host, room, {**batch_payload([host]), **change}).status_code == 422
    assert balance(client, host) == INITIAL_DIAMONDS


def test_batch_accepts_exactly_fifty_and_rejects_fifty_one_unique_recipients(client):
    host = login(client)
    room = live_room(client, host)
    ids = ['kiki_recipient_' + str(index) for index in range(51)]
    with sqlite3.connect(client.settings.db_path) as db:
        db.executemany('INSERT INTO accounts(account_id,login_id,sdk_user_id,name,needs_nickname,created_at) VALUES(?,?,?,?,0,?)',
                       [(sdk_id, sdk_id, sdk_id, '收礼人', int(time.time())) for sdk_id in ids])
        db.executemany('INSERT INTO history VALUES(?,?,?)', [(sdk_id, room['id'], int(time.time())) for sdk_id in ids])
    too_many = send_batch(client, host, room, {**payload(), 'recipientIDs': ids})
    assert too_many.status_code == 422 and balance(client, host) == INITIAL_DIAMONDS
    accepted = send_batch(client, host, room, {**payload(), 'recipientIDs': ids[:50]})
    assert accepted.status_code == 200
    assert accepted.json()['recipientCount'] == len(accepted.json()['events']) == 50
    assert accepted.json()['totalCost'] == 50 and balance(client, host) == INITIAL_DIAMONDS - 50


def test_batch_requires_existing_nickname_complete_room_associated_recipients(client):
    host, outside, newbie = login(client, 'host'), login(client, 'outside'), login(client, 'newbie', complete_nickname=False)
    room = live_room(client, host)
    for bad_id in ('kiki_missing', outside['user']['sdkUserID'], newbie['user']['sdkUserID']):
        invalid = {**batch_payload([host]), 'recipientIDs': [host['user']['sdkUserID'], bad_id]}
        assert send_batch(client, host, room, invalid).status_code == 409
    # An old visit is sufficient association, not an assertion of presence.
    visit_room(client, outside, room)
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('UPDATE history SET visited_at=1')
        db.execute('INSERT INTO history VALUES((SELECT account_id FROM accounts WHERE sdk_user_id=?),?,1)',
                   (newbie['user']['sdkUserID'], room['id']))
    assert send_batch(client, host, room, batch_payload([newbie])).status_code == 409
    assert balance(client, host) == INITIAL_DIAMONDS
    assert send_batch(client, host, room, batch_payload([outside])).status_code == 200


def test_batch_replay_is_set_based_and_durable_after_room_end_or_event_deletion(client):
    host, listener = login(client, 'host'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, listener, room)
    body = batch_payload([host, listener], 'galaxy_rocket', 99)
    first = send_batch(client, host, room, body)
    assert first.status_code == 200
    assert send_batch(client, host, room, {**body, 'recipientIDs': list(reversed(body['recipientIDs']))}).json() == first.json()
    for change in ({'quantity': 10}, {'giftID': 'heart'}, {'recipientIDs': [host['user']['sdkUserID']]}):
        assert send_batch(client, host, room, {**body, **change}).status_code == 409
    assert send_batch(client, host, {'id': 'other-room'}, body).status_code == 409
    client.patch('/v1/rooms/' + room['id'], headers=authorization(host), json={'status': 'ended'})
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('DELETE FROM room_gift_events')
        db.execute('DELETE FROM history')
    assert send_batch(client, host, room, body).json() == first.json()
    assert balance(client, host) == INITIAL_DIAMONDS - 4999 * 99 * 2


def test_batch_metadata_survives_event_pagination_and_deleted_recipient(client):
    host, sender, listener = login(client, 'host'), login(client, 'sender'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, sender, room)
    visit_room(client, listener, room)
    legacy = send(client, host, room).json()['event']
    assert 'batchID' not in legacy and 'batchRecipientCount' not in legacy
    body = batch_payload([host, sender, listener], quantity=99)
    first = send_batch(client, sender, room, body).json()
    batch_id = first['events'][0]['batchID']
    path = '/v1/rooms/' + room['id'] + '/gifts'
    cursor, events, pages = 0, [], 0
    while True:
        page = client.get(path, headers=authorization(sender), params={'after': cursor, 'limit': 1}).json()
        events.extend(page['events'])
        pages += 1
        cursor = page['nextCursor']
        if not page['hasMore']:
            break
    assert pages == 4 and events[0] == legacy and events[1:] == first['events']
    assert all(event['batchID'] == batch_id and event['batchRecipientCount'] == 3 for event in events[1:])
    assert client.delete('/v1/account', headers=authorization(listener)).status_code == 200
    remaining = client.get(path, headers=authorization(sender), params={'after': legacy['sequence']}).json()['events']
    assert len(remaining) == 2
    assert all(event['batchID'] == batch_id and event['batchRecipientCount'] == 3 for event in remaining)
    replay = send_batch(client, sender, room, body).json()
    assert len(replay['events']) == 3
    assert all(event['batchID'] == batch_id and event['batchRecipientCount'] == 3 for event in replay['events'])
    assert [event['recipientName'] for event in replay['events']].count('已注销用户') == 1
    assert replay['wallet'] == first['wallet'] and replay['totalCost'] == first['totalCost']


def test_batch_and_legacy_request_ids_cannot_cross_delivery_modes(client):
    host = login(client)
    room = live_room(client, host)
    body = payload()
    first = send(client, host, room, body)
    assert first.status_code == 200 and set(first.json()) == {'event', 'wallet'}
    assert send_batch(client, host, room, {**body, 'recipientIDs': [host['user']['sdkUserID']]}).status_code == 409
    batch = batch_payload([host])
    assert send_batch(client, host, room, batch).status_code == 200
    legacy = {key: value for key, value in batch.items() if key != 'recipientIDs'}
    assert send(client, host, room, legacy).status_code == 409
    assert balance(client, host) == INITIAL_DIAMONDS - 2


def test_batch_insufficient_balance_and_mid_transaction_error_roll_back_all(client):
    host, listener = login(client, 'host'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, listener, room)
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('UPDATE gift_wallets SET balance=100 WHERE account_id=(SELECT account_id FROM accounts WHERE sdk_user_id=?)',
                   (host['user']['sdkUserID'],))
    assert send_batch(client, host, room, batch_payload([host, listener], 'flower_rain')).status_code == 402
    assert balance(client, host) == 100
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute("""CREATE TRIGGER fail_second_batch_delivery BEFORE INSERT ON gift_batch_recipients
                   WHEN NEW.position=1 BEGIN SELECT RAISE(ABORT,'forced rollback'); END""")
    # The app's exception middleware converts storage failures to a safe 500;
    # the transaction must still roll back every debit, entry and delivery.
    assert send_batch(client, host, room, batch_payload([host, listener])).status_code == 500
    assert balance(client, host) == 100
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM gift_batch_recipients').fetchone()[0] == 0


def test_batch_concurrency_duplicate_and_competing_batches_never_overdraw(client):
    host, listener = login(client, 'host'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, listener, room)
    body = batch_payload([host, listener], 'flower_rain')
    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda _: send_batch(client, host, room, body), range(12)))
    assert all(result.status_code == 200 for result in responses)
    assert len({tuple(e['id'] for e in result.json()['events']) for result in responses}) == 1
    assert balance(client, host) == INITIAL_DIAMONDS - 198
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('UPDATE gift_wallets SET balance=250')
    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda _: send_batch(client, host, room, batch_payload([host, listener], 'flower_rain')), range(12)))
    assert sum(result.status_code == 200 for result in responses) == 1
    assert sum(result.status_code == 402 for result in responses) == 11
    assert balance(client, host) == 52
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] == 2
        assert db.execute('SELECT COUNT(*) FROM gift_batch_recipients').fetchone()[0] == 4


def test_batch_profile_changes_deletion_and_sender_deletion_preserve_privacy_and_idempotency(client):
    host, sender, listener = login(client, 'host'), login(client, 'sender'), login(client, 'listener')
    room = live_room(client, host)
    visit_room(client, listener, room)
    body = batch_payload([host, listener], quantity=10)
    first = send_batch(client, sender, room, body).json()
    client.patch('/v1/me', headers=authorization(sender), json={'name': '新发送者', 'avatarIndex': 4})
    client.patch('/v1/me', headers=authorization(listener), json={'name': '新收礼人'})
    replay = send_batch(client, sender, room, body).json()
    assert all(event['senderName'] == '新发送者' and event['senderAvatarIndex'] == 4 for event in replay['events'])
    assert any(event['recipientName'] == '新收礼人' for event in replay['events'])
    assert client.delete('/v1/account', headers=authorization(listener)).status_code == 200
    replay = send_batch(client, sender, room, body).json()
    deleted = [event for event in replay['events'] if event['recipientID'] == '']
    assert len(deleted) == 1 and deleted[0]['recipientName'] == '已注销用户'
    assert replay['recipientCount'] == 2 and replay['totalCost'] == first['totalCost'] == 20
    assert replay['wallet']['balance'] == first['wallet']['balance']
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 1
        assert db.execute('SELECT COUNT(*) FROM gift_batch_recipients WHERE recipient_account_id IS NULL').fetchone()[0] == 1
        columns = {row[1] for row in db.execute('PRAGMA table_info(gift_batch_recipients)')}
        assert columns == {'entry_id', 'position', 'recipient_account_id', 'event_id', 'event_sequence'}
    assert client.delete('/v1/account', headers=authorization(sender)).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM gift_batch_recipients').fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] == 0


def test_batch_access_requires_session_nickname_consent_notice_and_live_room(client):
    host, newbie = login(client, 'host'), login(client, 'newbie', complete_nickname=False)
    room = create_room(client, authorization(host))
    body = batch_payload([host])
    assert client.post('/v1/rooms/' + room['id'] + '/gifts/batch', json=body).status_code == 401
    assert send_batch(client, newbie, room, body).status_code == 409
    assert send_batch(client, host, room, {**body, 'noticeVersion': 'old'}).status_code == 412
    assert send_batch(client, host, room, {**body, 'giftID': 'missing'}).status_code == 404
    assert send_batch(client, host, room, body).status_code == 409
    assert send_batch(client, host, {'id': 'missing'}, body).status_code == 404
    assert balance(client, host) == INITIAL_DIAMONDS
    client.delete('/v1/me/legal-consent', headers=authorization(host))
    assert send_batch(client, host, room, body).status_code == 401


def test_batch_schema_migration_is_repeatable_and_never_refills_existing_balance():
    db = sqlite3.connect(':memory:')
    db.row_factory = sqlite3.Row
    db.execute('CREATE TABLE accounts(account_id TEXT PRIMARY KEY)')
    db.execute('CREATE TABLE rooms(id TEXT PRIMARY KEY)')
    db.execute("INSERT INTO accounts VALUES('existing')")
    # This is the actual previous schema: the two new ledger columns are absent.
    previous_schema = gifts.SCHEMA.replace("  delivery_mode TEXT NOT NULL DEFAULT 'single',\n", '').replace('  recipient_set_hash TEXT,\n', '')
    db.executescript(previous_schema)
    gifts.initialize_wallet(db, 'existing', now=1)
    db.execute('UPDATE gift_wallets SET balance=1234')
    gifts.migrate_wallets(db)
    gifts.migrate_wallets(db)
    assert db.execute('SELECT balance FROM gift_wallets').fetchone()[0] == 1234
    assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='initial_grant'").fetchone()[0] == 1
    assert db.execute('SELECT delivery_mode,recipient_set_hash FROM gift_wallet_entries').fetchone()[:] == ('single', None)
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    db.close()


def test_gift_catalog_and_one_time_wallet_existing_and_new_account(client):
    alice = login(client)
    headers = authorization(alice)
    response = client.get('/v1/gifts/catalog', headers=headers)
    assert response.status_code == 200
    catalog = response.json()
    assert [(g['id'], g['price']) for g in catalog['gifts']] == [
        ('heart', 1), ('flower_rain', 99), ('aurora_car', 999), ('galaxy_rocket', 4999), ('cosmic_heart', 10000)]
    assert all(g['animationAsset'].endswith('.gif') for g in catalog['gifts'])
    assert catalog['notice']['version'] == NOTICE_VERSION
    assert balance(client, alice) == INITIAL_DIAMONDS
    room = live_room(client, alice)
    assert send(client, alice, room).status_code == 200
    again = login(client)
    assert balance(client, again) == INITIAL_DIAMONDS - 1
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='initial_grant'").fetchone()[0] == 1
    # Simulate upgrading an existing account with no wallet yet.
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('DELETE FROM gift_wallet_entries')
        db.execute('DELETE FROM gift_wallets')
    with TestClient(create_app(client.settings)) as restarted:
        assert restarted.get('/v1/me/wallet', headers=authorization(again)).json()['balance'] == INITIAL_DIAMONDS
    with TestClient(create_app(client.settings)) as restarted:
        assert restarted.get('/v1/me/wallet', headers=authorization(again)).json()['balance'] == INITIAL_DIAMONDS
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='initial_grant'").fetchone()[0] == 1


def test_gift_send_prices_host_target_and_no_recipient_earnings(client):
    host, sender = login(client, 'host'), login(client, 'sender')
    room = live_room(client, host)
    result = send(client, sender, room, payload('cosmic_heart', 99))
    assert result.status_code == 200
    event = result.json()['event']
    assert event['quantity'] == 99 and event['unitPrice'] == 10000 and event['totalCost'] == 990000
    assert event['recipientID'] == host['user']['sdkUserID']
    assert event['senderID'] == sender['user']['sdkUserID']
    assert event['createdAt'] <= int(time.time())
    assert result.json()['wallet']['balance'] == INITIAL_DIAMONDS - 990000
    assert balance(client, host) == INITIAL_DIAMONDS
    # Self-gifts are intentionally available with free test diamonds, but debit.
    assert send(client, host, room, payload('flower_rain', 10)).status_code == 200
    assert balance(client, host) == INITIAL_DIAMONDS - 990


@pytest.mark.parametrize('change', [
    {'quantity': 2}, {'quantity': 0}, {'quantity': 100}, {'quantity': True}, {'quantity': '1'},
    {'quantity': 1.0}, {'unitPrice': 0}, {'recipientID': 'someone-else'}, {'requestID': 'bad'},
    {'balance': INITIAL_DIAMONDS}, {'totalCost': 0}])
def test_gift_rejects_untrusted_client_economics(client, change):
    host = login(client)
    room = live_room(client, host)
    assert send(client, host, room, {**payload(), **change}).status_code == 422
    assert balance(client, host) == INITIAL_DIAMONDS


def test_gift_unknown_notice_and_no_active_room_are_not_charged(client):
    host = login(client)
    room = create_room(client, authorization(host))
    assert send(client, host, room).status_code == 409
    assert send(client, host, room, payload('not-real')).status_code == 404
    body = {**payload(), 'noticeVersion': 'old'}
    assert send(client, host, room, body).status_code == 412
    assert send(client, host, {'id': 'absent'}).status_code == 404
    assert balance(client, host) == INITIAL_DIAMONDS


def test_idempotent_retries_keep_one_charge_even_after_room_end_and_event_expiry(client):
    host = login(client)
    room = live_room(client, host)
    body = payload('galaxy_rocket', 10)
    first = send(client, host, room, body)
    assert first.status_code == 200
    duplicate = send(client, host, room, body)
    assert duplicate.json() == first.json()
    assert send(client, host, room, {**body, 'quantity': 99}).status_code == 409
    assert send(client, host, {'id': 'different-room'}, body).status_code == 409
    client.patch('/v1/rooms/' + room['id'], headers=authorization(host), json={'status': 'ended'})
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('DELETE FROM room_gift_events')
    assert send(client, host, room, body).json() == first.json()
    assert balance(client, host) == INITIAL_DIAMONDS - 49990


def test_concurrent_duplicate_and_independent_requests_cannot_overspend(client):
    host = login(client)
    room = live_room(client, host)
    body = payload('flower_rain', 10)
    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda _: send(client, host, room, body), range(16)))
    assert all(r.status_code == 200 for r in responses)
    assert len({r.json()['event']['id'] for r in responses}) == 1
    assert balance(client, host) == INITIAL_DIAMONDS - 990
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('UPDATE gift_wallets SET balance=150')
    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda _: send(client, host, room, payload('flower_rain')), range(16)))
    assert sum(r.status_code == 200 for r in responses) == 1
    assert sum(r.status_code == 402 for r in responses) == 15
    assert balance(client, host) == 51
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] == 2
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 2


def test_event_cursor_no_history_replay_pagination_and_room_isolation(client):
    host, bob = login(client, 'host'), login(client, 'bob')
    room, other = live_room(client, host), live_room(client, bob)
    path = '/v1/rooms/' + room['id'] + '/gifts'
    assert client.get(path, headers=authorization(bob)).json() == {'events': [], 'nextCursor': 0, 'hasMore': False}
    assert send(client, host, room).status_code == 200
    initial = client.get(path, headers=authorization(bob)).json()
    assert initial['events'] == [] and initial['nextCursor'] == 1
    assert send(client, bob, other).status_code == 200
    expected = [send(client, host, room).json()['event']['id'] for _ in range(3)]
    first = client.get(path, headers=authorization(bob), params={'after': initial['nextCursor'], 'limit': 2}).json()
    assert [e['id'] for e in first['events']] == expected[:2] and first['hasMore']
    second = client.get(path, headers=authorization(bob), params={'after': first['nextCursor'], 'limit': 2}).json()
    assert [e['id'] for e in second['events']] == expected[2:] and not second['hasMore']
    assert client.get(path, headers=authorization(bob), params={'after': second['nextCursor']}).json()['events'] == []
    for query in ({'after': -1}, {'after': 2**63}, {'limit': 999}):
        assert client.get(path, headers=authorization(bob), params=query).status_code == 422


def test_event_expiry_keeps_wallet_ledger_and_monotonic_cursor(client):
    host = login(client)
    room = live_room(client, host)
    first = send(client, host, room).json()
    with sqlite3.connect(client.settings.db_path) as db:
        db.execute('UPDATE room_gift_events SET created_at=?', (int(time.time()) - GIFT_EVENT_SECONDS - 1,))
    path = '/v1/rooms/' + room['id'] + '/gifts'
    assert client.get(path, headers=authorization(host), params={'after': 0}).json()['events'] == []
    with TestClient(create_app(client.settings)) as restarted:
        current = restarted.get(path, headers=authorization(host)).json()
        assert current['nextCursor'] == first['event']['sequence']
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM gift_wallet_entries').fetchone()[0] == 2


def test_profiles_resolve_dynamically_and_account_deletion_erases_personal_events(client):
    host, sender = login(client, 'host'), login(client, 'sender')
    room = live_room(client, host)
    body = payload()
    sent = send(client, sender, room, body).json()
    client.patch('/v1/me', headers=authorization(sender), json={'name': '换了名字', 'avatarIndex': 7})
    retry = send(client, sender, room, body).json()['event']
    assert retry['senderName'] == '换了名字' and retry['senderAvatarIndex'] == 7
    assert client.delete('/v1/account', headers=authorization(host)).status_code == 200
    assert send(client, sender, room, body).json()['event']['recipientName'] == '已注销用户'
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM gift_wallets').fetchone()[0] == 1
        assert db.execute("SELECT recipient_account_id FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] is None
    assert client.delete('/v1/account', headers=authorization(sender)).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute('SELECT COUNT(*) FROM gift_wallet_entries').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM gift_wallets').fetchone()[0] == 0


def test_gifts_require_live_session_nickname_and_current_consent(client):
    host, newbie = login(client), login(client, 'newbie', complete_nickname=False)
    room = live_room(client, host)
    assert send(client, newbie, room).status_code == 409
    path = '/v1/rooms/' + room['id'] + '/gifts'
    assert client.get(path).status_code == 401
    assert client.get('/v1/me/wallet').status_code == 401
    assert client.get('/v1/gifts/catalog').status_code == 401
    client.delete('/v1/me/legal-consent', headers=authorization(host))
    assert send(client, host, room).status_code == 401
    assert client.get('/v1/me/wallet', headers=authorization(host)).status_code == 401


def qa_settings(tmp_path):
    base = apple_settings(Settings(str(tmp_path / 'qa-gifts-tests.sqlite3'), 1234567890, 'a' * 64, False))
    return replace(base, qa_gifts_enabled=True, qa_gifts_token=secrets.token_urlsafe(40),
                   qa_gifts_expires_at=int(time.time()) + 600)


def qa_body(user='gift_host'):
    return {'userID': user, 'name': '礼物测试', 'legalConsent': current_legal_consent()}


def test_qa_disabled_default_loopback_and_auth_isolation(client, tmp_path):
    assert client.post('/v1/internal/qa/login', json={}).status_code == 404
    settings = qa_settings(tmp_path)
    header = {'Authorization': 'Bearer ' + settings.qa_gifts_token}
    with TestClient(create_app(settings), client=('127.0.0.1', 12345)) as qa:
        assert qa.post('/v1/internal/qa/login', json=qa_body()).status_code == 404
        assert qa.post('/v1/auth/apple/challenge').status_code == 404
        result = qa.post('/v1/internal/qa/login', json=qa_body(), headers=header)
        assert result.status_code == 200
        account = result.json()
        assert account['user']['sdkUserID'].startswith('qa_')
        assert qa.get('/v1/me/wallet', headers=authorization(account)).json()['balance'] == INITIAL_DIAMONDS
        assert qa.post('/v1/auth/refresh', headers=authorization(account)).status_code == 200
        assert qa.post('/v1/internal/qa/login', json={**qa_body(), 'legalConsent': None}, headers=header).status_code == 428
    # Merely keeping a QA database/token can never bypass production Apple auth.
    with TestClient(create_app(replace(settings, qa_gifts_enabled=False))) as normal:
        assert normal.get('/v1/me', headers=authorization(account)).status_code == 401
    with TestClient(create_app(settings), client=('192.0.2.3', 12345)) as public:
        assert public.post('/v1/internal/qa/login', json=qa_body(), headers=header).status_code == 404
        assert public.get('/health').status_code == 404


def test_qa_requires_isolated_database_high_entropy_and_short_lifetime(tmp_path):
    settings = qa_settings(tmp_path)
    for invalid in (
        replace(settings, db_path=str(tmp_path / 'kikitalk.sqlite3')),
        replace(settings, qa_gifts_token='a' * 64),
        replace(settings, qa_gifts_token='short'),
        replace(settings, qa_gifts_expires_at=int(time.time()) - 1),
        replace(settings, qa_gifts_expires_at=int(time.time()) + 90000),
    ):
        with pytest.raises(RuntimeError):
            create_app(invalid)


def test_qa_expires_and_is_rate_limited(tmp_path, monkeypatch):
    settings = qa_settings(tmp_path)
    header = {'Authorization': 'Bearer ' + settings.qa_gifts_token}
    with TestClient(create_app(settings), client=('127.0.0.1', 12345)) as qa:
        account = qa.post('/v1/internal/qa/login', json=qa_body(), headers=header).json()
        for _ in range(19):
            assert qa.post('/v1/internal/qa/login', json=qa_body(), headers=header).status_code == 200
        assert qa.post('/v1/internal/qa/login', json=qa_body(), headers=header).status_code == 429
        monkeypatch.setattr('app.main.time.time', lambda: settings.qa_gifts_expires_at + 1)
        assert qa.get('/v1/me', headers=authorization(account)).status_code == 404


def test_gift_event_storage_ceiling_does_not_remove_debit_idempotency(client, monkeypatch):
    monkeypatch.setattr('app.gifts.MAX_GIFT_EVENTS', 3)
    host = login(client)
    room = live_room(client, host)
    first_body = payload()
    first = send(client, host, room, first_body).json()
    for _ in range(5):
        assert send(client, host, room).status_code == 200
    with sqlite3.connect(client.settings.db_path) as db:
        assert db.execute('SELECT COUNT(*) FROM room_gift_events').fetchone()[0] == 3
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift'").fetchone()[0] == 6
        assert db.execute("SELECT COUNT(*) FROM gift_wallet_entries WHERE kind='gift' AND notice_version=?", (NOTICE_VERSION,)).fetchone()[0] == 6
        assert db.execute('SELECT SUM(amount) FROM gift_wallet_entries').fetchone()[0] == INITIAL_DIAMONDS - 6
    replay = send(client, host, room, first_body).json()
    assert replay['event']['id'] == first['event']['id']
    assert replay['wallet']['balance'] == INITIAL_DIAMONDS - 6


def test_qa_will_not_open_database_containing_real_accounts(client, tmp_path):
    login(client)
    settings = qa_settings(tmp_path)
    # Even a renamed copy of the production database cannot be used for QA.
    with sqlite3.connect(client.settings.db_path) as source, sqlite3.connect(settings.db_path) as target:
        source.backup(target)
    with pytest.raises(RuntimeError, match='正式账号'):
        with TestClient(create_app(settings), client=('127.0.0.1', 12345)):
            pass


def test_qa_room_ids_are_invisible_to_production_sdk_directory(tmp_path):
    settings = qa_settings(tmp_path)
    header = {'Authorization': 'Bearer ' + settings.qa_gifts_token}
    with TestClient(create_app(settings), client=('127.0.0.1', 12345)) as qa:
        account = qa.post('/v1/internal/qa/login', json=qa_body(), headers=header).json()
        for is_live, prefix in ((False, 'qa_voice_'), (True, 'qa_live_')):
            result = qa.post('/v1/rooms', headers=authorization(account),
                             json={'title': '隔离测试房间', 'category': '随心聊', 'isLive': is_live, 'theme': 1})
            assert result.status_code == 200
            room_id = result.json()['id']
            assert room_id.startswith(prefix)
            assert not room_id.startswith(('voice_kiki_', 'live_kiki_'))
            assert len(room_id.encode('ascii')) <= 48
