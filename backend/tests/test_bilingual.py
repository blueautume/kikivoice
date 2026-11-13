"""English display renderings and per-installation push language contracts."""
import hashlib
import json
import sqlite3

import pytest
from app import push
from app.legal_translation import load_english
from app.main import LEGAL_ENGLISH_PATH, LEGAL_DOCUMENTS_PATH, SCHEMA, database
from test_api import client, login, authorization, current_legal_consent
from test_push import env, register, follow, send, clear, rows
from test_room_started import live, seed


def test_english_legal_rendering_is_public_complete_and_does_not_change_consent(client):
    canonical = client.get('/v1/legal/documents').json()
    response = client.get('/v1/legal/documents/en')
    assert response.status_code == 200
    assert response.headers['content-language'] == 'en'
    assert response.headers['cache-control'] == 'no-store'
    assert not client.cookies and 'set-cookie' not in response.headers
    english = response.json()
    assert english['locale'] == 'en' and english['sourceDocumentHash'] == canonical['documentHash']
    assert 'documentHash' not in english
    assert english == load_english(LEGAL_ENGLISH_PATH, canonical)
    for translated, original in zip(english['documents'], canonical['documents']):
        assert translated['id'] == original['id'] and translated['version'] == original['version']
        assert len(translated['sections']) == len(original['sections'])
        assert [len(s['paragraphs']) for s in translated['sections']] == [len(s['paragraphs']) for s in original['sections']]
    privacy = json.dumps(english['documents'][0], ensure_ascii=False)
    for boundary in ['not sent to other users', 'not account deletion or automatic deletion', 'historical backups', 'no default birth time', 'AI services']:
        assert boundary in privacy
    assert current_legal_consent()['documentHash'] == canonical['documentHash']
    account = login(client, 'english-consent')
    status = client.get('/v1/me/legal-consent', headers=authorization(account)).json()
    assert status['requiredVersions']['documentHash'] == canonical['documentHash']
    assert status['requiresAcceptance'] is False


@pytest.mark.parametrize('change', ['hash', 'source', 'version', 'paragraph', 'extra'])
def test_english_rendering_rejects_tampering_and_incomplete_text(tmp_path, change):
    canonical = json.loads(LEGAL_DOCUMENTS_PATH.read_text())
    value = json.loads(LEGAL_ENGLISH_PATH.read_text())
    if change == 'hash': value['renderingHash'] = '0' * 64
    if change == 'source': value['sourceDocumentHash'] = '0' * 64
    if change == 'version': value['privacyVersion'] = '2020-01-01'
    if change == 'paragraph': value['documents'][0]['sections'][0]['paragraphs'].pop()
    if change == 'extra': value['documentHash'] = canonical['documentHash']
    if change != 'hash':
        value['renderingHash'] = hashlib.sha256(json.dumps({k:v for k,v in value.items() if k != 'renderingHash'}, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    path = tmp_path / 'rendering.json'
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError): load_english(path, canonical)


def test_push_language_is_per_installation_and_never_translates_user_messages(env):
    e = env
    sender, recipient = login(e.c, 'language-sender'), login(e.c, 'language-recipient')
    _, _, old = register(e, recipient)
    assert old.status_code == 200
    with database(e.c.settings) as db:
        # Simulate a device created by the previous service: no language row.
        db.execute('DELETE FROM push_device_languages')
    installation, body, _ = register(e, recipient)
    body.update(language='en', revision=2)
    assert e.c.put('/v1/push/devices/' + installation, headers=authorization(recipient), json=body).status_code == 200
    follow(e, sender, recipient)
    e.s.dispatch()
    alerts = [json.loads(r.content)['aps']['alert'] for r in e.requests]
    assert {a['body'] for a in alerts} == {'关注了你', 'Started following you'}
    assert all(a['title'] == sender['user']['name'] for a in alerts)
    clear(e); e.requests.clear()
    send(e, sender, recipient, text='你好，hello!')
    e.s.dispatch()
    assert [json.loads(r.content)['aps']['alert']['body'] for r in e.requests] == ['你好，hello!'] * 2
    assert e.c.patch('/v1/me', headers=authorization(recipient), json={'hideNotificationContent':True}).status_code == 200
    clear(e); e.requests.clear()
    send(e, sender, recipient, text='第二条消息')
    e.s.dispatch()
    alerts = [json.loads(r.content)['aps']['alert'] for r in e.requests]
    assert push.ENGLISH_GENERIC_ALERT in alerts and push.GENERIC_ALERT in alerts


def test_push_language_update_requires_a_new_revision_and_old_retries_still_work(env):
    e = env; account = login(e.c, 'language-revision')
    installation, body, response = register(e, account)
    assert response.status_code == 200
    path = '/v1/push/devices/' + installation
    assert e.c.put(path, headers=authorization(account), json=body).status_code == 200
    english = {**body, 'language':'en'}
    assert e.c.put(path, headers=authorization(account), json=english).status_code == 409
    english['revision'] += 1
    assert e.c.put(path, headers=authorization(account), json=english).status_code == 200
    assert rows(e, 'push_device_languages')[0]['language'] == 'en'
    assert e.c.put(path, headers=authorization(account), json=english).status_code == 200
    assert e.c.put(path, headers=authorization(account), json={**english,'language':'xx','revision':3}).status_code == 422
    assert rows(e, 'push_device_languages')[0]['language'] == 'en'


def test_push_existing_schema_migrates_once_with_chinese_default(tmp_path):
    db = sqlite3.connect(tmp_path / 'old-push.sqlite3')
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    old = push.SCHEMA.split('CREATE TABLE IF NOT EXISTS push_device_languages')[0]
    db.executescript(old)
    for _ in range(2):
        push.initialize(db)
        # An additive side table preserves the old positional device INSERT,
        # including when rolling back to the previous service version.
        assert len(list(db.execute('PRAGMA table_info(push_devices)'))) == 12
        columns = {r['name']:r for r in db.execute('PRAGMA table_info(push_device_languages)')}
        assert columns['language']['dflt_value'] == "'zh-Hans'"
    db.close()


@pytest.mark.parametrize('kind,expected', [('follow','Started following you'), ('mutual_follow','You now follow each other')])
def test_english_push_uses_notification_kind_even_for_legacy_actor_prefixed_text(env, kind, expected):
    e = env; sender, recipient = login(e.c,'prefixed-sender'), login(e.c,'prefixed-recipient')
    assert e.c.patch('/v1/me',headers=authorization(sender),json={'name':'小岛'}).status_code == 200
    installation, body, _ = register(e, recipient)
    body.update(language='en',revision=2)
    assert e.c.put('/v1/push/devices/'+installation,headers=authorization(recipient),json=body).status_code == 200
    # Exercise real follow creation, then emulate older stored display wording.
    follow(e, sender, recipient)
    with database(e.c.settings) as db:
        db.execute('UPDATE social_notifications SET kind=?,text=?',(kind,'小岛关注了你'))
    e.s.dispatch()
    assert len(e.requests) == 1
    assert json.loads(e.requests[0].content)['aps']['alert'] == {'title':'小岛','body':expected}


def test_real_room_start_push_uses_english_kind_with_current_actor_name(live):
    e = live; host, _, _ = seed(e)
    assert e.c.patch('/v1/me',headers=authorization(host),json={'name':'小岛'}).status_code == 200
    with database(e.c.settings) as db:
        db.execute("UPDATE push_device_languages SET language='en'")
        db.execute("UPDATE social_notifications SET text='小岛开始语聊了，点击进入房间' WHERE kind='room_started'")
    e.s.dispatch()
    assert len(e.requests) == 1
    assert json.loads(e.requests[0].content)['aps']['alert'] == {'title':'小岛','body':'Started a voice chat. Tap to join.'}
