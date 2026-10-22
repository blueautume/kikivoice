"""Server-priced free experience: retries, atomic debits and privacy boundaries."""
import concurrent.futures
import hashlib
import time
import uuid

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from app.experience import GiftSend, INITIAL_DIAMONDS, EVENT_RETENTION_SECONDS, STARTER_GIFT_PACK
from app.main import create_app
from conftest import headers, login
from test_room_actions import act, setup_room, token
from test_account_bridge import account_service, exchange, profile, signed


def snapshot(lab, account):
    response = lab.client.get('/v1/me/experience', headers=headers(account))
    assert response.status_code == 200, response.text
    return response.json()


def empty_gift_bag(lab, account):
    """Exercise diamond-only behavior without suppressing the one-time grant."""
    snapshot(lab, account)
    with lab.app.state.db:
        lab.app.state.db.execute('DELETE FROM experience_gift_inventory WHERE user_id=?', (account['user']['id'],))


def bag_quantities(value):
    return {item['giftID']: item['quantity'] for item in value['giftInventory']}


def gift_mutation_state(lab):
    """Read persisted gift state without accidentally claiming the starter pack."""
    db = lab.app.state.db
    tables = [row[0] for row in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'experience_%' ORDER BY name")]
    rows = {table: [tuple(row) for row in db.execute(f'SELECT * FROM {table} ORDER BY rowid')]
            for table in tables}
    allowance = {key: tuple(value) for key, value in lab.app.state.experience.limiter.events.items()
                 if key[0] in ('gift-burst', 'gift-minute')}
    return rows, allowance


def send(lab, room, sender, recipients, *, request_id=None, status=200, **changes):
    body = {'giftID': 'heart', 'quantity': 1, 'recipientIDs': [account['user']['id'] for account in recipients],
            'requestID': request_id or str(uuid.uuid4()), **changes}
    response = lab.client.post(f'/v1/rooms/{room["id"]}/gifts', headers=headers(sender), json=body)
    assert response.status_code == status, response.text
    return response.json()


def read(lab, room, account, **params):
    response = lab.client.get(f'/v1/rooms/{room["id"]}/gifts', headers=headers(account), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def purchase(lab, account, identifier='frame_violet', *, request_id=None, status=200, **changes):
    response = lab.client.post('/v1/me/decorations/purchase', headers=headers(account),
        json={'decorationID': identifier, 'requestID': request_id or str(uuid.uuid4()), **changes})
    assert response.status_code == status, response.text
    return response.json()


def equip(lab, account, kind='avatarFrame', identifier='frame_violet', status=200):
    response = lab.client.put('/v1/me/decorations/equipped', headers=headers(account),
                             json={'kind': kind, 'decorationID': identifier})
    assert response.status_code == status, response.text
    return response.json()


def test_catalog_has_only_bundled_assets_and_twelve_permanent_decorations(lab):
    account = login(lab)
    assert lab.client.get('/v1/gifts/catalog').status_code == 401
    response = lab.client.get('/v1/gifts/catalog', headers=headers(account))
    assert response.status_code == 200
    catalog = response.json()
    assert catalog['initialGrant'] == INITIAL_DIAMONDS
    assert [item['price'] for item in catalog['gifts']] == [1, 99, 999, 4999, 10000]
    assert all(item['animationAsset'] == item['id'] + '.gif' and item['posterAsset'] == item['id'] + '.png'
               for item in catalog['gifts'])
    assert len({item['id'] for item in catalog['decorations']}) == 12
    for kind in ('avatarFrame', 'micEffect', 'chatBubble', 'roomBackground'):
        items = [item for item in catalog['decorations'] if item['kind'] == kind]
        assert {item['style'] for item in items} == {'violet', 'aurora', 'gold'}
        assert [item['price'] for item in items] == [1999, 4999, 9999]


def test_initial_grant_is_exactly_once_under_concurrency_and_restart(lab):
    account = login(lab)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        snapshots = list(pool.map(lambda _: snapshot(lab, account), range(12)))
    assert all(item == snapshots[0] for item in snapshots)
    assert snapshots[0]['wallet'] == {'balance': INITIAL_DIAMONDS, 'initialGrant': INITIAL_DIAMONDS, 'currency': 'diamond'}
    assert bag_quantities(snapshots[0]) == STARTER_GIFT_PACK
    assert len(snapshots[0]['entries']) == 1
    entry = snapshots[0]['entries'][0]
    assert entry['kind'] == 'initial_grant' and entry['amount'] == INITIAL_DIAMONDS
    assert entry['balanceAfter'] == INITIAL_DIAMONDS
    with TestClient(create_app(lab.settings, lab.rtc)) as client:
        assert client.get('/v1/me/experience', headers=headers(account)).json() == snapshots[0]
        assert client.get('/v1/me/wallet', headers=headers(account)).json() == snapshots[0]['wallet']
    assert len(snapshot(lab, account)['entries']) == 1


def test_existing_wallet_receives_starter_pack_once_without_changing_balance(lab):
    account = login(lab)
    user_id = account['user']['id']
    with lab.app.state.db:
        # Simulate a wallet from the release before gift inventory existed.
        lab.app.state.db.execute('INSERT INTO experience_wallets VALUES(?,?,?)', (user_id, 12345, 1))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: snapshot(lab, account), range(12)))
    assert all(item == results[0] for item in results)
    assert results[0]['wallet']['balance'] == 12345
    assert results[0]['entries'] == []  # A gift pack is not a diamond credit.
    assert bag_quantities(results[0]) == STARTER_GIFT_PACK
    assert lab.app.state.db.execute('SELECT COUNT(*) FROM experience_gift_grants WHERE user_id=?',
                                    (user_id,)).fetchone()[0] == 1
    empty_gift_bag(lab, account)
    with TestClient(create_app(lab.settings, lab.rtc)) as client:
        after = client.get('/v1/me/experience', headers=headers(account)).json()
    assert after['giftInventory'] == [] and after['wallet']['balance'] == 12345


def test_starter_bag_is_private_and_recipient_does_not_receive_resendable_items(lab):
    room, (owner, sender), _ = setup_room(lab)
    before = snapshot(lab, owner)
    result = send(lab, room, sender, [owner])
    assert bag_quantities(result) == {**STARTER_GIFT_PACK, 'heart': 9}
    assert (result['inventoryUsed'], result['diamondQuantity'], result['totalQuantity'], result['totalCost']) == (1, 0, 1, 0)
    assert snapshot(lab, owner) == before
    for event in read(lab, room, owner, after=0)['events']:
        assert 'giftInventory' not in event and 'inventoryUsed' not in event
    public = lab.client.get('/v1/decorations/users', headers=headers(owner), params={'ids': sender['user']['id']}).json()
    assert set(public['users'][0]) == {'userID', 'equipped'}


def test_inventory_only_send_succeeds_with_zero_diamonds_and_records_zero_diamond_entry(lab):
    room, (owner, sender), _ = setup_room(lab)
    snapshot(lab, sender)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE experience_wallets SET balance=0 WHERE user_id=?', (sender['user']['id'],))
    result = send(lab, room, sender, [owner], giftID='aurora_car')
    assert result['totalCost'] == 0 and result['wallet']['balance'] == 0
    assert (result['inventoryUsed'], result['diamondQuantity'], result['totalQuantity']) == (1, 0, 1)
    assert 'aurora_car' not in bag_quantities(result)
    entry = snapshot(lab, sender)['entries'][0]
    assert entry['kind'] == 'gift' and entry['amount'] == 0 and entry['balanceAfter'] == 0
    assert '背包×1' in entry['title'] and '钻石购买×0' in entry['title']
    send(lab, room, sender, [owner], giftID='aurora_car', status=409)


def test_multi_recipient_send_uses_total_inventory_before_charging_missing_items(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    result = send(lab, room, sender, [owner, other], giftID='flower_rain', quantity=2)
    assert (result['inventoryUsed'], result['diamondQuantity'], result['totalQuantity'], result['totalCost']) == (3, 1, 4, 99)
    assert result['wallet']['balance'] == INITIAL_DIAMONDS - 99
    assert 'flower_rain' not in bag_quantities(result)
    assert [event['quantity'] for event in result['events']] == [2, 2]
    assert all(event['unitPrice'] == 99 for event in result['events'])
    assert bag_quantities(snapshot(lab, owner)) == STARTER_GIFT_PACK
    assert bag_quantities(snapshot(lab, other)) == STARTER_GIFT_PACK


def test_insufficient_diamonds_roll_back_inventory_debit_ledger_and_events(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    before = snapshot(lab, sender)
    user_id = sender['user']['id']
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE experience_wallets SET balance=98 WHERE user_id=?', (user_id,))
    send(lab, room, sender, [owner, other], giftID='flower_rain', quantity=2, status=409)
    after = snapshot(lab, sender)
    assert after['wallet']['balance'] == 98
    assert after['giftInventory'] == before['giftInventory'] and after['entries'] == before['entries']
    for table in ('experience_requests', 'experience_gift_settlements'):
        assert not lab.app.state.db.execute(f'SELECT 1 FROM {table} WHERE user_id=?', (user_id,)).fetchone()
    assert read(lab, room, owner, after=0)['events'] == []


def test_concurrent_taps_cannot_overspend_shared_inventory_or_diamonds(lab):
    room, (owner, sender), _ = setup_room(lab)
    snapshot(lab, sender)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE experience_wallets SET balance=1 WHERE user_id=?', (sender['user']['id'],))
    def post(_):
        return lab.client.post(f'/v1/rooms/{room["id"]}/gifts', headers=headers(sender), json={
            'giftID': 'heart', 'quantity': 1, 'recipientIDs': [owner['user']['id']], 'requestID': str(uuid.uuid4())})
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(post, range(12)))
    assert sorted(result.status_code for result in results) == [200] * 11 + [409]
    successful = [result.json() for result in results if result.status_code == 200]
    assert sum(item['inventoryUsed'] for item in successful) == 10
    assert sum(item['diamondQuantity'] for item in successful) == 1
    current = snapshot(lab, sender)
    assert current['wallet']['balance'] == 0 and 'heart' not in bag_quantities(current)
    assert len(current['entries']) == 12
    assert len(read(lab, room, owner, after=0)['events']) == 11


def test_mixed_inventory_retry_preserves_original_settlement_with_current_private_snapshot(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    identifier = str(uuid.uuid4())
    first = send(lab, room, sender, [owner, other], giftID='flower_rain', quantity=2, request_id=identifier)
    second = send(lab, room, sender, [owner], giftID='flower_rain')
    assert second['totalCost'] == 99
    current = snapshot(lab, sender)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        retries = list(pool.map(lambda _: send(lab, room, sender, [other, owner], giftID='flower_rain',
                                               quantity=2, request_id=identifier), range(6)))
    for retry in retries:
        assert retry['events'] == first['events']
        assert (retry['inventoryUsed'], retry['diamondQuantity'], retry['totalQuantity'], retry['totalCost']) == (3, 1, 4, 99)
        assert retry['wallet'] == current['wallet'] and retry['giftInventory'] == current['giftInventory']
    assert snapshot(lab, sender) == current
    with TestClient(create_app(lab.settings, lab.rtc)) as client:
        retry = client.post(f'/v1/rooms/{room["id"]}/gifts', headers=headers(sender), json={
            'giftID': 'flower_rain', 'quantity': 2, 'recipientIDs': [owner['user']['id'], other['user']['id']],
            'requestID': identifier})
        assert retry.status_code == 200
        assert retry.json() == retries[0]
    # Delivery retention must not erase settlement or permit another charge.
    with lab.app.state.db:
        lab.app.state.db.execute('DELETE FROM experience_gift_events WHERE batch_id=?', (first['events'][0]['batchID'],))
    retry = send(lab, room, sender, [owner, other], giftID='flower_rain', quantity=2, request_id=identifier)
    assert retry['events'] == [] and retry['totalCost'] == 99 and retry['inventoryUsed'] == 3
    assert snapshot(lab, sender) == current


def test_old_paid_request_retry_uses_original_cost_and_does_not_spend_new_starter_pack(lab):
    room, (owner, sender), _ = setup_room(lab)
    empty_gift_bag(lab, sender)
    identifier = str(uuid.uuid4())
    original = send(lab, room, sender, [owner], giftID='flower_rain', quantity=2, request_id=identifier)
    with lab.app.state.db:
        # Old requests have no bag settlement, and their accounts have not yet
        # claimed the newly introduced, independently tracked gift pack.
        for table in ('experience_gift_settlements', 'experience_gift_grants'):
            lab.app.state.db.execute(f'DELETE FROM {table} WHERE user_id=?', (sender['user']['id'],))
    retry = send(lab, room, sender, [owner], giftID='flower_rain', quantity=2, request_id=identifier)
    assert retry['events'] == original['events'] and retry['wallet'] == original['wallet']
    assert (retry['inventoryUsed'], retry['diamondQuantity'], retry['totalQuantity'], retry['totalCost']) == (0, 2, 2, 198)
    assert bag_quantities(retry) == STARTER_GIFT_PACK
    assert len(snapshot(lab, sender)['entries']) == 2


@pytest.mark.parametrize('sender_index', [0, 1], ids=['owner', 'member'])
@pytest.mark.parametrize('claimed_pack', [False, True], ids=['no-wallet', 'existing-bag'])
@pytest.mark.parametrize('recipient_order', ['self', 'self-first', 'self-last'])
def test_self_recipient_rejects_entire_batch_without_spending_or_using_allowance(
        lab, sender_index, claimed_pack, recipient_order):
    room, accounts, _ = setup_room(lab)
    sender, other = accounts[sender_index], accounts[1 - sender_index]
    if claimed_pack:
        snapshot(lab, sender)
    recipients = {'self': [sender], 'self-first': [sender, other],
                  'self-last': [other, sender]}[recipient_order]
    before = gift_mutation_state(lab)
    identifier = str(uuid.uuid4())
    for request_id in (identifier, identifier.upper(), str(uuid.uuid4())):
        result = send(lab, room, sender, recipients, giftID='flower_rain', quantity=2,
                      request_id=request_id, status=422)
        assert result['detail'] == '礼物只能送给别人，不能送给自己'
        assert gift_mutation_state(lab) == before
    # Rejection creates no retry receipt: correcting the targets is a new,
    # valid gift even if the caller retains the rejected request identifier.
    result = send(lab, room, sender, [other], giftID='flower_rain', quantity=2,
                  request_id=identifier)
    assert (result['inventoryUsed'], result['diamondQuantity'], result['totalCost']) == (2, 0, 0)
    assert len(result['events']) == 1
    assert result['events'][0]['recipientUserID'] == other['user']['id']


def test_store_rejects_self_before_any_wallet_bag_or_limiter_mutation(lab):
    room, (owner, member), _ = setup_room(lab)
    before = gift_mutation_state(lab)
    with pytest.raises(HTTPException) as rejected:
        with lab.app.state.db:
            lab.app.state.experience.send(room['id'], member['user']['id'], GiftSend(
                giftID='flower_rain', quantity=2,
                recipientIDs=[owner['user']['id'], member['user']['id']], requestID=uuid.uuid4()))
    assert rejected.value.status_code == 422
    assert gift_mutation_state(lab) == before


def test_historical_self_gift_retry_only_acknowledges_committed_settlement(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    identifier = str(uuid.uuid4())
    original = send(lab, room, sender, [owner, other], giftID='flower_rain', quantity=2,
                    request_id=identifier)
    store, db = lab.app.state.experience, lab.app.state.db
    legacy_payload = GiftSend(giftID='flower_rain', quantity=2,
        recipientIDs=[owner['user']['id'], sender['user']['id']], requestID=identifier)
    with db:
        # Model a committed batch from the release that permitted self gifts.
        # Existing receipts remain immutable financial acknowledgements.
        db.execute('UPDATE experience_gift_events SET recipient_user_id=? WHERE batch_id=? AND recipient_user_id=?',
                   (sender['user']['id'], original['events'][0]['batchID'], other['user']['id']))
        db.execute('UPDATE experience_requests SET payload_hash=? WHERE user_id=? AND request_id=?',
                   (store.digest(store.gift_body(room['id'], legacy_payload)), sender['user']['id'], identifier))
    before = gift_mutation_state(lab)
    lab.rtc.rooms[room['id']].discard(owner['user']['id'])
    for _ in range(3):
        result = send(lab, room, sender, [sender, owner], giftID='flower_rain', quantity=2,
                      request_id=identifier)
        assert {event['recipientUserID'] for event in result['events']} == {
            owner['user']['id'], sender['user']['id']}
        assert {event['batchID'] for event in result['events']} == {original['events'][0]['batchID']}
        assert result['wallet'] == original['wallet'] and result['giftInventory'] == original['giftInventory']
        assert (result['inventoryUsed'], result['diamondQuantity'], result['totalQuantity'], result['totalCost']) == (3, 1, 4, 99)
        assert gift_mutation_state(lab) == before
    with db:
        assert store.send(room['id'], sender['user']['id'], legacy_payload) == result
    assert gift_mutation_state(lab) == before
    send(lab, room, sender, [owner], request_id=identifier, status=409)
    send(lab, room, sender, [sender, owner], giftID='flower_rain', quantity=2, status=422)
    assert gift_mutation_state(lab) == before
    with db:
        db.execute('DELETE FROM experience_gift_events WHERE batch_id=?', (original['events'][0]['batchID'],))
    pruned = gift_mutation_state(lab)
    retry = send(lab, room, sender, [owner, sender], giftID='flower_rain', quantity=2,
                 request_id=identifier)
    assert retry['events'] == [] and retry['totalCost'] == 99 and retry['inventoryUsed'] == 3
    assert gift_mutation_state(lab) == pruned


def test_gift_authentication_pricing_batch_debit_and_recipient_does_not_earn(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    empty_gift_bag(lab, sender)
    before = read(lab, room, owner)
    assert before == {'events': [], 'cursor': 0, 'hasMore': False}
    result = send(lab, room, sender, [owner, other], giftID='flower_rain', quantity=10)
    assert result['totalCost'] == 99 * 10 * 2
    assert (result['inventoryUsed'], result['diamondQuantity'], result['totalQuantity']) == (0, 20, 20)
    assert result['wallet']['balance'] == INITIAL_DIAMONDS - result['totalCost']
    events = result['events']
    assert len(events) == 2 and len({event['id'] for event in events}) == 2
    assert len({event['batchID'] for event in events}) == 1
    for event in events:
        assert event['senderUserID'] == sender['user']['id'] and event['senderName'] == sender['user']['name']
        assert event['giftName'] == '星光花雨' and event['unitPrice'] == 99
        assert event['quantity'] == 10 and event['batchRecipientCount'] == 2
        assert event['roomID'] == room['id']
    assert read(lab, room, owner, after=0)['events'] == events
    assert read(lab, room, owner)['events'] == []  # Opening a room never replays gifts.
    assert snapshot(lab, owner)['wallet']['balance'] == INITIAL_DIAMONDS
    current = snapshot(lab, sender)
    assert [entry['kind'] for entry in current['entries']] == ['gift', 'initial_grant']
    assert current['entries'][0]['amount'] == -result['totalCost']
    send(lab, room, sender, [owner], price=0, status=422)
    send(lab, room, sender, [owner], senderUserID=owner['user']['id'], status=422)


def test_gift_retry_is_atomic_deduplicated_and_payload_bound(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    empty_gift_bag(lab, sender)
    identifier = str(uuid.uuid4())
    def post(_):
        return send(lab, room, sender, [owner, other], request_id=identifier.upper(), quantity=10)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(post, range(8)))
    assert all(item == results[0] for item in results)
    assert len(snapshot(lab, sender)['entries']) == 2
    # Recipient order is a set, and an acknowledged delivery can be retried after disconnect.
    lab.rtc.rooms[room['id']].discard(owner['user']['id'])
    assert send(lab, room, sender, [other, owner], request_id=identifier, quantity=10) == results[0]
    send(lab, room, sender, [owner], request_id=identifier, status=409)
    purchase(lab, sender, request_id=identifier, status=409)
    assert len(read(lab, room, other, after=0)['events']) == 2


def test_concurrent_distinct_debits_cannot_overspend(lab):
    room, (owner, sender), _ = setup_room(lab)
    empty_gift_bag(lab, sender)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE experience_wallets SET balance=1 WHERE user_id=?', (sender['user']['id'],))
    def post(_):
        return lab.client.post(f'/v1/rooms/{room["id"]}/gifts', headers=headers(sender),
            json={'giftID': 'heart', 'quantity': 1, 'recipientIDs': [owner['user']['id']], 'requestID': str(uuid.uuid4())})
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(post, range(4)))
    assert sorted(response.status_code for response in responses) == [200, 409, 409, 409]
    assert snapshot(lab, sender)['wallet']['balance'] == 0
    assert len(read(lab, room, owner, after=0)['events']) == 1


def test_all_recipients_validated_before_any_debit_and_online_is_authoritative(lab):
    room, (owner, sender), _ = setup_room(lab)
    outsider = login(lab)
    send(lab, room, sender, [owner, outsider], status=409)
    assert snapshot(lab, sender)['wallet']['balance'] == INITIAL_DIAMONDS
    token(lab, room, outsider, online=False)
    send(lab, room, sender, [outsider], status=409)
    lab.rtc.rooms[room['id']].discard(sender['user']['id'])
    send(lab, room, sender, [owner], status=403)
    assert not read(lab, room, owner, after=0)['events']
    assert len(snapshot(lab, sender)['entries']) == 1


def test_gift_membership_chat_mute_revoked_consent_and_sessions(lab):
    room, (owner, sender), _ = setup_room(lab)
    outsider = login(lab)
    send(lab, room, outsider, [owner], status=403)
    assert lab.client.get(f'/v1/rooms/{room["id"]}/gifts', headers=headers(outsider)).status_code == 403
    act(lab, room, owner, 'mute_chat', targetUserID=sender['user']['id'], enabled=True)
    send(lab, room, sender, [owner], status=403)
    act(lab, room, owner, 'mute_chat', targetUserID=sender['user']['id'], enabled=False)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE sessions SET expires_at=0 WHERE user_id=?', (sender['user']['id'],))
    send(lab, room, owner, [sender], status=409)
    assert lab.client.get('/v1/me/experience', headers=headers(sender)).status_code == 401
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE sessions SET expires_at=? WHERE user_id=?', (int(time.time())+100, sender['user']['id']))
        lab.app.state.db.execute('UPDATE consents SET withdrawn_at=? WHERE user_id=?', (int(time.time()), sender['user']['id']))
    send(lab, room, sender, [owner], status=428)
    send(lab, room, owner, [sender], status=409)


@pytest.mark.parametrize('changes', [
    {'quantity': 0}, {'quantity': 100}, {'quantity': True}, {'requestID': 'invalid'},
    {'inventoryUsed': 0}, {'totalCost': 0}, {'giftInventory': [{'giftID': 'heart', 'quantity': 1000}]},
    {'recipientIDs': []}, {'recipientIDs': ['bad.id']}, {'recipientIDs': ['a']*2},
    {'recipientIDs': [f'user{i}' for i in range(51)]}])
def test_gift_payload_bounds(lab, changes):
    room, (owner, sender), _ = setup_room(lab)
    send(lab, room, sender, [owner], status=422, **changes)
    assert not read(lab, room, owner, after=0)['events']


def test_bilateral_block_prevents_send_and_filters_events_without_stalling_cursor(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    result = send(lab, room, sender, [owner])
    other_result = send(lab, room, other, [owner])
    assert lab.client.put('/v1/safety/blocks/'+sender['user']['id'], headers=headers(owner)).status_code == 200
    send(lab, room, sender, [owner], status=403)
    send(lab, room, owner, [sender], status=403)
    page = read(lab, room, owner, after=0)
    assert page['events'] == other_result['events']
    assert page['cursor'] == other_result['events'][-1]['seq'] and not page['hasMore']
    # Reverse-direction blocks hide either side of an event for any viewer.
    assert lab.client.put('/v1/safety/blocks/'+other['user']['id'], headers=headers(sender)).status_code == 200
    assert read(lab, room, other, after=0)['events'] == other_result['events']
    assert result['events'][0]['seq'] < page['cursor']


def test_rapid_retry_does_not_use_send_rate_allowance(lab):
    room, (owner, sender), _ = setup_room(lab)
    identifier = str(uuid.uuid4())
    first = send(lab, room, sender, [owner], request_id=identifier)
    for _ in range(12):
        assert send(lab, room, sender, [owner], request_id=identifier) == first
    for _ in range(19):
        send(lab, room, sender, [owner])
    send(lab, room, sender, [owner], status=429)
    assert len(read(lab, room, owner, after=0)['events']) == 20


def test_continuous_send_minute_limit_is_120_and_failure_does_not_consume_inventory(lab):
    room, (owner, sender), _ = setup_room(lab)
    lab.app.state.experience.limiter.events[('gift-minute', sender['user']['id'])].extend([time.monotonic()] * 119)
    first = send(lab, room, sender, [owner])
    send(lab, room, sender, [owner], status=429)
    assert snapshot(lab, sender)['giftInventory'] == first['giftInventory']
    assert len(snapshot(lab, sender)['entries']) == 2
    assert len(read(lab, room, owner, after=0)['events']) == 1


def test_decoration_ownership_categories_and_repeat_purchase_never_double_charge(lab):
    first, other = login(lab), login(lab)
    equip(lab, first, status=403)
    equip(lab, first, kind='micEffect', status=422)
    purchase(lab, first, identifier='unknown', status=404)
    purchase(lab, first, price=0, status=422)
    identifier = str(uuid.uuid4())
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda _: purchase(lab, first, request_id=identifier), range(6)))
    assert all(item == results[0] for item in results)
    assert results[0]['wallet']['balance'] == INITIAL_DIAMONDS-1999
    assert results[0]['inventory']['ownedIDs'] == ['frame_violet']
    assert purchase(lab, first)['wallet'] == results[0]['wallet']
    purchase(lab, first, identifier='mic_violet', request_id=identifier, status=409)
    assert equip(lab, first)['equipped']['avatarFrame'] == 'frame_violet'
    equip(lab, other, status=403)
    assert not snapshot(lab, other)['inventory']['ownedIDs']
    assert equip(lab, first, identifier=None)['equipped']['avatarFrame'] is None
    assert len(snapshot(lab, first)['entries']) == 2


def test_public_appearance_never_exposes_private_state_or_blocked_deleted_users(lab):
    first, other = login(lab), login(lab)
    purchase(lab, first)
    equip(lab, first)
    url = '/v1/decorations/users'
    result = lab.client.get(url, headers=headers(other), params={'ids': first['user']['id']+','+other['user']['id']})
    assert result.status_code == 200
    users = result.json()['users']
    assert set(users[0]) == {'userID', 'equipped'}
    assert users[0]['equipped']['avatarFrame'] == 'frame_violet'
    assert users[1]['equipped']['avatarFrame'] is None
    for ids in ('', 'a,a', 'bad.id', ','.join(f'user{i}' for i in range(101))):
        assert lab.client.get(url, headers=headers(other), params={'ids': ids}).status_code == 422
    assert lab.client.put('/v1/safety/blocks/'+other['user']['id'], headers=headers(first)).status_code == 200
    assert lab.client.get(url, headers=headers(other), params={'ids': first['user']['id']}).json() == {'users': []}
    assert lab.client.get('/v1/me/wallet/'+first['user']['id'], headers=headers(other)).status_code == 404


def test_restart_preserves_spending_permanent_inventory_and_equipped(lab):
    room, (owner, sender), _ = setup_room(lab)
    result = send(lab, room, sender, [owner], giftID='cosmic_heart', quantity=99)
    purchase(lab, sender, identifier='background_gold')
    equip(lab, sender, kind='roomBackground', identifier='background_gold')
    before = snapshot(lab, sender)
    with TestClient(create_app(lab.settings, lab.rtc)) as client:
        assert client.get('/v1/me/experience', headers=headers(sender)).json() == before
        assert client.get(f'/v1/rooms/{room["id"]}/gifts', headers=headers(owner), params={'after': 0}).json()['events'] == result['events']


def test_consent_withdrawal_hides_public_state_without_reminting_diamonds(lab):
    room, (owner, sender), _ = setup_room(lab)
    send(lab, room, sender, [owner])
    purchase(lab, sender)
    equip(lab, sender)
    before = snapshot(lab, sender)
    assert lab.client.delete('/v1/me/legal-consent', headers=headers(sender)).status_code == 200
    assert not read(lab, room, owner, after=0)['events']
    assert lab.app.state.experience.inventory(sender['user']['id'])['ownedIDs'] == ['frame_violet']
    assert lab.app.state.experience.equipped(sender['user']['id'])['avatarFrame'] is None
    assert lab.app.state.experience.wallet(sender['user']['id']) == before['wallet']
    assert lab.app.state.experience.gift_inventory(sender['user']['id']) == before['giftInventory']
    assert lab.app.state.db.execute('SELECT COUNT(*) FROM experience_gift_grants WHERE user_id=?',
                                    (sender['user']['id'],)).fetchone()[0] == 1
    assert lab.client.get('/v1/me/experience', headers=headers(sender)).status_code == 401


def test_account_delete_erases_private_wallet_and_public_gifts_even_as_recipient(lab):
    room, (owner, sender), _ = setup_room(lab)
    send(lab, room, owner, [sender])
    send(lab, room, sender, [owner])
    purchase(lab, sender)
    equip(lab, sender)
    assert lab.client.delete('/v1/account', headers=headers(sender)).status_code == 200
    db, user_id = lab.app.state.db, sender['user']['id']
    for table in ('experience_wallets', 'experience_entries', 'experience_inventory', 'experience_equipped', 'experience_requests',
                  'experience_gift_inventory', 'experience_gift_grants', 'experience_gift_settlements'):
        assert not db.execute(f'SELECT 1 FROM {table} WHERE user_id=?', (user_id,)).fetchone()
    assert not read(lab, room, owner, after=0)['events']
    result = lab.client.get('/v1/decorations/users', headers=headers(owner), params={'ids': user_id})
    assert result.json() == {'users': []}


def test_account_relogin_is_same_wallet_and_deletion_without_sessions_erases_it(account_service):
    service = account_service
    account = exchange(service).json()
    purchase(service, account)
    before = snapshot(service, account)
    renewed = exchange(service, auth=hashlib.sha256(b'source-two').hexdigest()).json()
    assert snapshot(service, renewed) == before
    db, user_id = service.app.state.db, account['user']['id']
    with db:
        db.execute('DELETE FROM account_authorization_privacy')
        db.execute('DELETE FROM account_authorizations')
    assert signed(service, 'delete', {'accountID': user_id}).status_code == 200
    assert not db.execute('SELECT 1 FROM experience_wallets WHERE user_id=?', (user_id,)).fetchone()
    assert not db.execute('SELECT 1 FROM experience_inventory WHERE user_id=?', (user_id,)).fetchone()
    assert not db.execute('SELECT 1 FROM experience_gift_inventory WHERE user_id=?', (user_id,)).fetchone()
    assert not db.execute('SELECT 1 FROM experience_gift_grants WHERE user_id=?', (user_id,)).fetchone()
    assert not db.execute('SELECT 1 FROM experience_gift_settlements WHERE user_id=?', (user_id,)).fetchone()


def test_pagination_filtering_and_expiry_preserve_cursor(lab):
    room, (owner, sender), _ = setup_room(lab)
    store, db = lab.app.state.experience, lab.app.state.db
    # Seed many valid transactions without triggering transport burst protection.
    with db:
        for _ in range(3):
            store.send(room['id'], sender['user']['id'], GiftSend(giftID='heart', quantity=1,
                recipientIDs=[owner['user']['id']], requestID=uuid.uuid4()))
        # Duplicate persisted deliveries to exercise the fixed 100-item page size.
        original = db.execute('SELECT * FROM experience_gift_events LIMIT 1').fetchone()
        for _ in range(102):
            db.execute('''INSERT INTO experience_gift_events(id,room_id,batch_id,sender_user_id,recipient_user_id,
                gift_id,quantity,unit_price,batch_recipient_count,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)''',
                (str(uuid.uuid4()), room['id'], original['batch_id'], sender['user']['id'], owner['user']['id'],
                 'heart', 1, 1, 1, int(time.time())))
        latest = db.execute('SELECT MAX(seq) FROM experience_gift_events').fetchone()[0]
        db.execute('UPDATE experience_room_heads SET latest_seq=?', (latest,))
    page = read(lab, room, owner, after=0)
    assert len(page['events']) == 100 and page['hasMore']
    second = read(lab, room, owner, after=page['cursor'])
    assert len(second['events']) == 5 and not second['hasMore'] and second['cursor'] == latest
    assert lab.client.put('/v1/safety/blocks/'+sender['user']['id'], headers=headers(owner)).status_code == 200
    hidden = read(lab, room, owner, after=0)
    assert hidden['events'] == [] and hidden['hasMore'] and hidden['cursor'] == page['cursor']
    with db:
        db.execute('UPDATE experience_gift_events SET created_at=?', (int(time.time())-EVENT_RETENTION_SECONDS-1,))
    assert read(lab, room, owner, after=0) == {'events': [], 'cursor': latest, 'hasMore': False}
    assert read(lab, room, owner, after=latest+100)['cursor'] == latest


def test_nickname_and_safety_restrictions_apply_to_experience_mutations(lab):
    room, (owner, sender), _ = setup_room(lab)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE users SET needs_nickname=1 WHERE id=?', (sender['user']['id'],))
    purchase(lab, sender, status=403)
    equip(lab, sender, identifier=None, status=403)
    send(lab, room, sender, [owner], status=403)
    send(lab, room, owner, [sender], status=409)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE users SET needs_nickname=0 WHERE id=?', (sender['user']['id'],))
        lab.app.state.db.execute('INSERT INTO safety_restrictions(user_id,banned_until,reason) VALUES(?,?,?)',
                                (sender['user']['id'], int(time.time())+300, 'test'))
    purchase(lab, sender, status=403)
    assert lab.client.get('/v1/me/experience', headers=headers(sender)).status_code == 403
    send(lab, room, sender, [owner], status=403)
    send(lab, room, owner, [sender], status=409)


def test_invalid_catalog_item_insufficient_balance_and_large_batch_never_partial_charge(lab):
    room, (owner, sender, other), _ = setup_room(lab, 3)
    before = snapshot(lab, sender)
    send(lab, room, sender, [owner], giftID='invented', status=404)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE experience_wallets SET balance=1998 WHERE user_id=?', (sender['user']['id'],))
    purchase(lab, sender, status=409)
    send(lab, room, sender, [owner, other], giftID='cosmic_heart', quantity=99, status=409)
    after = snapshot(lab, sender)
    assert after['wallet']['balance'] == 1998 and after['entries'] == before['entries']
    assert after['inventory']['ownedIDs'] == []
    assert read(lab, room, owner, after=0)['events'] == []


def test_profile_updates_resolve_current_names_without_rewriting_financial_ledger(lab):
    room, (owner, sender), _ = setup_room(lab)
    result = send(lab, room, sender, [owner])
    ledger = snapshot(lab, sender)['entries']
    assert lab.client.patch('/v1/me', headers=headers(sender), json={'name': '新昵称'}).status_code == 200
    event = read(lab, room, owner, after=0)['events'][0]
    assert event['senderName'] == '新昵称' and event['id'] == result['events'][0]['id']
    assert snapshot(lab, sender)['entries'] == ledger


def test_decorations_and_gifts_do_not_cross_user_idempotency_namespaces(lab):
    room, (owner, sender), _ = setup_room(lab)
    identifier = str(uuid.uuid4())
    first = purchase(lab, owner, request_id=identifier)
    second = purchase(lab, sender, request_id=identifier)
    assert first['wallet'] == second['wallet']
    send(lab, room, sender, [owner], request_id=identifier, status=409)
    assert len(snapshot(lab, sender)['entries']) == 2
