"""Server authority, bounded recovery and retry behavior for laboratory text."""
import concurrent.futures
import json
import time
import uuid

from fastapi.testclient import TestClient
import pytest

from app.chat import CHAT_RETENTION_SECONDS, CHAT_WINDOW_SIZE
from app.main import create_app
from conftest import headers, login
from test_room_actions import act, setup_room, token


def send(lab, room, account, text='Hello', client_id=None, status=200, **fields):
    response = lab.client.post(f'/v1/rooms/{room["id"]}/messages', headers=headers(account),
        json={'text': text, 'clientMessageID': client_id or str(uuid.uuid4()), **fields})
    assert response.status_code == status, response.text
    return response.json()


def read(lab, room, account, **params):
    response = lab.client.get(f'/v1/rooms/{room["id"]}/messages', headers=headers(account), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def test_messages_are_server_ordered_and_sender_is_authenticated(lab):
    room, (owner, member), _ = setup_room(lab)
    empty = read(lab, room, owner)
    assert empty == {'messages': [], 'nextAfterSeq': 0, 'latestSeq': 0, 'oldestSeq': 1,
        'truncated': False, 'hasMore': False, 'historyRevision': 0,
        'announcement': {'text': '', 'revision': 0, 'updatedAt': 0, 'updatedByUserID': None}}
    first = send(lab, room, member, '  中文👋  ')
    second = send(lab, room, owner, 'Next')
    assert first['seq'] == 1 and second['seq'] == 2
    assert first['text'] == '中文👋'
    assert first['senderUserID'] == member['user']['id']
    assert first['senderName'] == member['user']['name']
    assert first['senderAvatarIndex'] == 0
    assert isinstance(uuid.UUID(first['id']), uuid.UUID)
    assert first['createdAt'] == pytest.approx(time.time(), abs=2)
    assert [message['seq'] for message in read(lab, room, member)['messages']] == [1, 2]
    assert read(lab, room, member, afterSeq=1)['messages'] == [second]
    send(lab, room, member, senderUserID=owner['user']['id'], status=422)
    assert lab.rtc.chat_hints[-1][1] == {'version': 1, 'latestSeq': 2, 'historyRevision': 0, 'announcementRevision': 0}
    assert 'Hello' not in json.dumps(lab.rtc.chat_hints)


def test_idempotent_retry_same_id_different_content_conflicts_and_concurrency(lab):
    room, (_, member), _ = setup_room(lab)
    identifier = str(uuid.uuid4()).upper()
    def post(_):
        return send(lab, room, member, 'One', identifier)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        messages = list(pool.map(post, range(8)))
    assert all(message == messages[0] for message in messages)
    assert messages[0]['clientMessageID'] == identifier.lower()
    assert read(lab, room, member)['latestSeq'] == 1
    assert len(lab.rtc.chat_hints) == 1
    send(lab, room, member, 'Other', identifier.lower(), status=409)


@pytest.mark.parametrize('text', ['', '   ', 'bad\x00text', 'bad\rtext', 'a'*2001, '中'*667, '👋'*501])
def test_message_validation_is_by_utf8_bytes_and_rejects_control_text(lab, text):
    room, (owner, _), _ = setup_room(lab)
    send(lab, room, owner, text, status=422)
    assert read(lab, room, owner)['latestSeq'] == 0


def test_exact_two_thousand_utf8_bytes_and_invalid_nonce(lab):
    room, (owner, _), _ = setup_room(lab)
    assert len(send(lab, room, owner, '👋'*500)['text'].encode()) == 2000
    send(lab, room, owner, client_id='x'*36, status=422)
    for params in ({'afterSeq': -1}, {'afterSeq': 9223372036854775808}, {'limit': 201}, {'limit': 0}):
        assert lab.client.get(f'/v1/rooms/{room["id"]}/messages', headers=headers(owner), params=params).status_code == 422


def test_burst_limit_is_per_sender_idempotent_retries_do_not_consume(lab):
    room, (owner, member), _ = setup_room(lab)
    first = send(lab, room, member)
    for _ in range(20):
        send(lab, room, member, client_id=first['clientMessageID'])
    for _ in range(4):
        send(lab, room, member)
    response = lab.client.post(f'/v1/rooms/{room["id"]}/messages', headers=headers(member), json={'text': 'Excess', 'clientMessageID': str(uuid.uuid4())})
    assert response.status_code == 429 and response.headers['Retry-After'] == '5'
    send(lab, room, owner)
    assert read(lab, room, member)['latestSeq'] == 6


def test_mute_kick_leave_revoked_session_and_outsider_cannot_send_or_fetch(lab):
    room, (owner, member), _ = setup_room(lab)
    outsider = login(lab)
    endpoint = f'/v1/rooms/{room["id"]}/messages'
    assert lab.client.get(endpoint, headers=headers(outsider)).status_code == 403
    send(lab, room, outsider, status=403)
    act(lab, room, owner, 'mute_chat', targetUserID=member['user']['id'], enabled=True)
    send(lab, room, member, status=403)
    assert read(lab, room, member)['messages'] == []
    act(lab, room, owner, 'mute_chat', targetUserID=member['user']['id'], enabled=False)
    send(lab, room, member)
    assert lab.client.post(f'/v1/rooms/{room["id"]}/leave', headers=headers(member)).status_code == 200
    assert lab.client.get(endpoint, headers=headers(member)).status_code == 403
    send(lab, room, member, status=403)
    token(lab, room, member)
    assert len(read(lab, room, member)['messages']) == 1
    act(lab, room, owner, 'kick', targetUserID=member['user']['id'])
    assert lab.client.get(endpoint, headers=headers(member)).status_code == 403
    send(lab, room, member, status=403)
    assert lab.client.post('/v1/auth/logout', headers=headers(member)).status_code == 200
    assert lab.client.get(endpoint, headers=headers(member)).status_code == 401


def test_message_committed_even_when_realtime_notification_fails(lab):
    room, (owner, _), _ = setup_room(lab)
    lab.rtc.broadcast_failure = True
    message = send(lab, room, owner)
    assert send(lab, room, owner, client_id=message['clientMessageID']) == message
    assert read(lab, room, owner)['messages'] == [message]


def test_pagination_expiry_and_cursor_reset_keep_sequence_monotonic(lab):
    room, (owner, _), _ = setup_room(lab)
    one = send(lab, room, owner, 'One')
    two = send(lab, room, owner, 'Two')
    three = send(lab, room, owner, 'Three')
    page = read(lab, room, owner, limit=2)
    assert page['messages'] == [one, two] and page['hasMore'] and page['nextAfterSeq'] == 2
    assert read(lab, room, owner, afterSeq=page['nextAfterSeq'])['messages'] == [three]
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE room_messages SET created_at=? WHERE seq<=2', (int(time.time())-CHAT_RETENTION_SECONDS-1,))
    page = read(lab, room, owner, afterSeq=1)
    assert page['messages'] == [three] and page['truncated'] and page['oldestSeq'] == 3
    assert page['historyRevision'] == 1
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE room_messages SET created_at=0')
    assert read(lab, room, owner)['latestSeq'] == 3
    assert read(lab, room, owner)['historyRevision'] == 2
    four = send(lab, room, owner)
    assert four['seq'] == 4
    reset = read(lab, room, owner, afterSeq=999)
    assert reset['truncated'] and reset['messages'] == [four] and reset['nextAfterSeq'] == 4


def test_rolling_window_prunes_oldest_and_reports_history_revision(lab):
    room, (owner, _), _ = setup_room(lab)
    chat = lab.app.state.chat
    with lab.app.state.db:
        chat.ensure(room['id'])
        for index in range(1, CHAT_WINDOW_SIZE+2):
            lab.app.state.db.execute('INSERT INTO room_messages VALUES(?,?,?,?,?,?,?,?,?)',
                (str(uuid.uuid4()), room['id'], index, str(uuid.uuid4()), owner['user']['id'], 'Owner', 0, str(index), int(time.time())))
        lab.app.state.db.execute('UPDATE room_chat_heads SET latest_seq=? WHERE room_id=?', (CHAT_WINDOW_SIZE+1, room['id']))
    page = read(lab, room, owner)
    assert len(page['messages']) == CHAT_WINDOW_SIZE and page['oldestSeq'] == 2
    assert page['historyRevision'] == 1 and page['latestSeq'] == CHAT_WINDOW_SIZE+1
    assert read(lab, room, owner)['historyRevision'] == 1


@pytest.mark.parametrize('ending', ['closed', 'withdrawal', 'deleted', 'disappeared'])
def test_close_or_account_privacy_operation_clears_text(lab, ending):
    room, (owner, member), _ = setup_room(lab)
    send(lab, room, owner, 'Owner text')
    send(lab, room, member, 'Member text')
    if ending == 'closed':
        assert lab.client.patch(f'/v1/rooms/{room["id"]}', headers=headers(owner), json={'status': 'closed'}).status_code == 200
    elif ending == 'disappeared':
        lab.rtc.rooms.pop(room['id'])
        assert lab.client.get('/v1/rooms', headers=headers(owner)).status_code == 200
    else:
        method, url = ('delete', '/v1/me/legal-consent') if ending == 'withdrawal' else ('delete', '/v1/account')
        response = getattr(lab.client, method)(url, headers=headers(member))
        assert response.status_code == 200, response.text
    rows = lab.app.state.db.execute('SELECT sender_user_id,text FROM room_messages').fetchall()
    if ending in {'closed', 'disappeared'}:
        assert not rows
        assert lab.client.get(f'/v1/rooms/{room["id"]}/messages', headers=headers(member)).status_code == 409
    else:
        assert [row['text'] for row in rows] == ['Owner text']
        assert read(lab, room, owner)['historyRevision'] == 1


def test_restart_preserves_window_and_sequence(lab):
    room, (owner, _), _ = setup_room(lab)
    first = send(lab, room, owner)
    with TestClient(create_app(lab.settings, lab.rtc)) as client:
        response = client.get(f'/v1/rooms/{room["id"]}/messages', headers=headers(owner))
        assert response.status_code == 200 and response.json()['messages'] == [first]
        result = client.post(f'/v1/rooms/{room["id"]}/messages', headers=headers(owner), json={'text': 'Second', 'clientMessageID': str(uuid.uuid4())})
        assert result.status_code == 200 and result.json()['seq'] == 2


def test_announcement_moderator_write_clear_and_revision(lab):
    room, (owner, member, admin), _ = setup_room(lab, 3)
    url = f'/v1/rooms/{room["id"]}/announcement'
    def put(account, text, expected=200):
        response = lab.client.put(url, headers=headers(account), json={'text': text})
        assert response.status_code == expected, response.text
        return response.json()
    put(member, 'Spoofed', 403)
    announcement = put(owner, '  Welcome  ')
    assert announcement['text'] == 'Welcome' and announcement['revision'] == 1
    assert announcement['updatedByUserID'] == owner['user']['id']
    assert put(owner, 'Welcome') == announcement
    act(lab, room, owner, 'set_admin', targetUserID=admin['user']['id'], enabled=True)
    assert put(admin, '')['revision'] == 2
    assert not read(lab, room, member)['announcement']['text']
    put(admin, '中'*667, 422)
    put(admin, 'Admin')
    assert lab.rtc.chat_hints[-1][1]['announcementRevision'] == 3
    assert lab.client.delete('/v1/account', headers=headers(admin)).status_code == 200
    assert read(lab, room, member)['announcement']['text'] == ''
    assert read(lab, room, member)['announcement']['revision'] == 4


def test_repeated_unchanged_message_polls_are_read_only_and_keep_cursor_and_announcement(lab):
    room,(owner,member),_ = setup_room(lab)
    message = send(lab,room,member)
    announcement = lab.client.put(f'/v1/rooms/{room["id"]}/announcement',headers=headers(owner),json={"text":"Current announcement"}).json()
    read(lab,room,owner)
    db,statements = lab.app.state.db,[]
    before = db.total_changes
    db.set_trace_callback(statements.append)
    try:
        for _ in range(5):
            result = read(lab,room,owner,afterSeq=message["seq"])
            assert result["messages"] == [] and result["nextAfterSeq"] == message["seq"]
            assert result["announcement"] == announcement and result["historyRevision"] == 0
    finally:
        db.set_trace_callback(None)
    assert db.total_changes == before and not db.in_transaction
    assert not any(sql.lstrip().upper().startswith(("INSERT ","UPDATE ","DELETE ","BEGIN","COMMIT")) for sql in statements)


def test_read_cleans_actual_expiry_at_exact_boundary_without_delaying_history_revision(lab,monkeypatch):
    from types import SimpleNamespace
    from app import chat as chat_module
    now = [int(time.time())]
    monkeypatch.setattr(chat_module,"time",SimpleNamespace(time=lambda:now[0]))
    room,(owner,_),_ = setup_room(lab)
    first = send(lab,room,owner)
    now[0] += CHAT_RETENTION_SECONDS-1
    before = read(lab,room,owner)
    assert before["messages"] == [first] and before["historyRevision"] == 0
    now[0] += 1
    expired = read(lab,room,owner,afterSeq=first["seq"])
    assert expired["messages"] == [] and expired["historyRevision"] == 1
    assert expired["latestSeq"] == first["seq"] and expired["oldestSeq"] == first["seq"]+1
    assert not lab.app.state.db.execute("SELECT 1 FROM room_messages").fetchone()
    assert read(lab,room,owner)["historyRevision"] == 1
    second = send(lab,room,owner)
    assert second["seq"] == first["seq"]+1
    assert send(lab,room,owner,client_id=second["clientMessageID"]) == second


def test_read_repairs_missing_announcement_without_resetting_existing_message_head(lab):
    room,(owner,_),_ = setup_room(lab)
    message = send(lab,room,owner)
    with lab.app.state.db:
        lab.app.state.db.execute("DELETE FROM room_announcements WHERE room_id=?",(room["id"],))
    result = read(lab,room,owner)
    assert result["messages"] == [message] and result["latestSeq"] == message["seq"]
    assert result["announcement"] == {"text":"","revision":0,"updatedAt":0,"updatedByUserID":None}
    changes = lab.app.state.db.total_changes
    assert read(lab,room,owner) == result
    assert lab.app.state.db.total_changes == changes


def test_global_prune_does_not_touch_empty_history_heads_or_scale_queries_with_them(lab,monkeypatch):
    from types import SimpleNamespace
    from app import chat as chat_module
    now = int(time.time())
    monkeypatch.setattr(chat_module,"time",SimpleNamespace(time=lambda:now))
    room,(owner,_),_ = setup_room(lab)
    chat,db = lab.app.state.chat,lab.app.state.db
    read(lab,room,owner)
    def measured_prune():
        statements = []
        changes = db.total_changes
        db.set_trace_callback(statements.append)
        try:
            with db:
                assert chat.prune() == []
        finally:
            db.set_trace_callback(None)
        assert db.total_changes == changes and not db.in_transaction
        assert not any(sql.lstrip().upper().startswith(("INSERT ","UPDATE ","DELETE ","BEGIN","COMMIT")) for sql in statements)
        return statements
    small = measured_prune()
    with db:
        for index in range(500):
            identifier = f'empty-history-{index}'
            db.execute("INSERT INTO rooms VALUES(?,?,?,?,?,'closed',?)",(identifier,owner["user"]["id"],"Historical","闲聊",0,int(time.time())))
            chat.ensure(identifier)
            db.execute("UPDATE room_chat_heads SET latest_seq=?,history_revision=? WHERE room_id=?",(index+1,index+2,identifier))
    large = measured_prune()
    assert large == small
    assert len(large) == 1 and "room_chat_heads" not in large[0]
    assert db.execute("SELECT latest_seq,history_revision FROM room_chat_heads WHERE room_id='empty-history-499'").fetchone()[:] == (500,501)


def test_global_prune_selects_only_real_expiry_or_overfull_windows_and_bumps_once(lab):
    room,(owner,_),_ = setup_room(lab)
    fresh = send(lab,room,owner,"Fresh")
    chat,db = lab.app.state.chat,lab.app.state.db
    current_time = int(time.time())
    expired_room,full_room = "expired-history","overfull-history"
    with db:
        for identifier in (expired_room,full_room):
            db.execute("INSERT INTO rooms VALUES(?,?,?,?,?,'active',?)",(identifier,owner["user"]["id"],"Recovery","闲聊",0,current_time))
            chat.ensure(identifier)
        db.execute("INSERT INTO room_messages VALUES(?,?,?,?,?,?,?,?,?)",(str(uuid.uuid4()),expired_room,1,str(uuid.uuid4()),owner["user"]["id"],"Owner",0,"Expired",current_time-CHAT_RETENTION_SECONDS))
        db.execute("UPDATE room_chat_heads SET latest_seq=1 WHERE room_id=?",(expired_room,))
        for index in range(1,CHAT_WINDOW_SIZE+2):
            db.execute("INSERT INTO room_messages VALUES(?,?,?,?,?,?,?,?,?)",(str(uuid.uuid4()),full_room,index,str(uuid.uuid4()),owner["user"]["id"],"Owner",0,str(index),current_time))
        db.execute("UPDATE room_chat_heads SET latest_seq=? WHERE room_id=?",(CHAT_WINDOW_SIZE+1,full_room))
        assert set(chat.prune()) == {expired_room,full_room}
    assert not db.execute("SELECT 1 FROM room_messages WHERE room_id=?",(expired_room,)).fetchone()
    assert db.execute("SELECT COUNT(*),MIN(seq) FROM room_messages WHERE room_id=?",(full_room,)).fetchone()[:] == (CHAT_WINDOW_SIZE,2)
    assert db.execute("SELECT latest_seq,history_revision FROM room_chat_heads WHERE room_id=?",(expired_room,)).fetchone()[:] == (1,1)
    assert db.execute("SELECT latest_seq,history_revision FROM room_chat_heads WHERE room_id=?",(full_room,)).fetchone()[:] == (CHAT_WINDOW_SIZE+1,1)
    assert read(lab,room,owner)["messages"] == [fresh]
    assert read(lab,room,owner)["historyRevision"] == 0
    changes = db.total_changes
    with db:
        assert chat.prune() == []
    assert db.total_changes == changes


def test_explicit_prune_keeps_initialization_semantics_even_without_messages(lab):
    room,(owner,_),_ = setup_room(lab)
    db,chat = lab.app.state.db,lab.app.state.chat
    assert not db.execute("SELECT 1 FROM room_chat_heads WHERE room_id=?",(room["id"],)).fetchone()
    with db:
        assert chat.prune(room["id"]) == []
    assert db.execute("SELECT latest_seq,history_revision FROM room_chat_heads WHERE room_id=?",(room["id"],)).fetchone()[:] == (0,0)
    assert db.execute("SELECT text,revision FROM room_announcements WHERE room_id=?",(room["id"],)).fetchone()[:] == ("",0)
