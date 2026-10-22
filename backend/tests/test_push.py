"""APNs regression with synthetic credentials and no Apple network requests."""
from dataclasses import replace
import hashlib
import json
import logging
import sqlite3
from types import SimpleNamespace
import uuid
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
import httpx
import jwt
import pytest
from fastapi.testclient import TestClient
from app.main import SCHEMA,Settings,create_app,database
from app import push
from app.social import Policy
from test_api import client,login,authorization
from test_social_api import setup,rid
from conftest import apple_settings

MESSAGE_TEXT = '私聊预览测试正文'

@pytest.fixture
def env(client,monkeypatch,tmp_path):
    social=setup(client);s=client.app.state.push
    key=ec.generate_private_key(ec.SECP256R1());path=tmp_path/'synthetic-apns.p8'
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    s.settings=replace(client.settings,apns_enabled=True,apns_team_id='A82X46N3WS',apns_sandbox_key_id='SYNTHKEY01',apns_sandbox_private_key_path=str(path),apns_production_key_id='SYNTHKEY02',apns_production_private_key_path=str(path))
    requests=[];responses=[]
    def transport(request):
        requests.append(request)
        value=responses.pop(0) if responses else httpx.Response(200)
        if isinstance(value,Exception):raise value
        return value
    s.http=httpx.Client(http2=True,transport=httpx.MockTransport(transport))
    return SimpleNamespace(c=client,s=s,social=social,requests=requests,responses=responses,key=key)

def register(e,a,installation=None,token=None,revision=1,environment='sandbox',permission='authorized'):
    installation=installation or str(uuid.uuid4());token=token or hashlib.sha256(installation.encode()).hexdigest()
    body=dict(token=token,environment=environment,revision=revision,permission=permission)
    return installation,body,e.c.put('/v1/push/devices/'+installation,headers=authorization(a),json=body)

def follow(e,a,b,on=True):
    r=e.c.request('PUT' if on else 'DELETE','/v1/social/follows/'+b['user']['id'],headers=authorization(a),json={'requestID':rid()})
    assert r.status_code==200,r.text

def friends(e,a,b):follow(e,a,b);follow(e,b,a)
def send(e,a,b,request_id=None,text=MESSAGE_TEXT):
    r=e.c.post('/v1/social/conversations/'+b['user']['id']+'/messages',headers=authorization(a),json={'requestID':request_id or rid(),'text':text})
    assert r.status_code==200,r.text
    return r.json()
def rows(e,table='push_outbox'):
    with database(e.c.settings) as db:return [dict(r) for r in db.execute('SELECT * FROM '+table)]
def clear(e):
    with database(e.c.settings) as db:db.execute('DELETE FROM push_outbox')


def test_preview_preference_roundtrips_privately_and_survives_logout_and_withdrawal(env):
    e=env;a,b=login(e.c,'preview-owner'),login(e.c,'preview-other')
    assert a['user']['hideNotificationContent'] is False
    assert e.c.get('/v1/push/status',headers=authorization(a)).json()['hideNotificationContent'] is False
    changed=e.c.patch('/v1/me',headers=authorization(a),json={'hideNotificationContent':True})
    assert changed.status_code==200 and changed.json()['hideNotificationContent'] is True
    assert changed.json()['notificationsEnabled'] is True
    renamed=e.c.patch('/v1/me',headers=authorization(a),json={'name':'新的昵称'})
    assert renamed.json()['hideNotificationContent'] is True, 'An unrelated profile edit cannot reset the preference'
    assert e.c.patch('/v1/me',headers=authorization(a),json={'notificationsEnabled':False}).json()['hideNotificationContent'] is True
    assert e.c.patch('/v1/me',headers=authorization(a),json={'notificationsEnabled':True}).json()['hideNotificationContent'] is True
    assert e.c.get('/v1/push/status',headers=authorization(a)).json()['hideNotificationContent'] is True
    assert e.c.get('/v1/me',headers=authorization(b)).json()['hideNotificationContent'] is False
    public=e.c.get('/v1/social/people/'+a['user']['id'],headers=authorization(b))
    assert public.status_code==200 and 'hideNotificationContent' not in public.json()['person']
    assert e.c.post('/v1/auth/refresh',headers=authorization(a)).json()['user']['hideNotificationContent'] is True
    assert e.c.post('/v1/auth/logout',headers=authorization(a)).status_code==200
    again=login(e.c,'preview-owner')
    assert again['user']['hideNotificationContent'] is True
    assert e.c.delete('/v1/me/legal-consent',headers=authorization(again)).status_code==200
    renewed=login(e.c,'preview-owner')
    assert renewed['user']['hideNotificationContent'] is True
    assert e.c.delete('/v1/account',headers=authorization(renewed)).status_code==200
    replacement=login(e.c,'preview-owner')
    assert replacement['user']['id']!=a['user']['id'] and replacement['user']['hideNotificationContent'] is False


@pytest.mark.parametrize('invalid',[None,0,1,'true','false',[],{}])
def test_preview_preference_requires_boolean_and_never_resets_on_invalid_input(env,invalid):
    e=env;a=login(e.c)
    assert e.c.patch('/v1/me',headers=authorization(a),json={'hideNotificationContent':True}).status_code==200
    response=e.c.patch('/v1/me',headers=authorization(a),json={'hideNotificationContent':invalid})
    assert response.status_code==422
    assert e.c.get('/v1/me',headers=authorization(a)).json()['hideNotificationContent'] is True


def test_existing_accounts_migrate_to_visible_previews_once_without_resetting_a_saved_choice(tmp_path):
    settings=apple_settings(Settings(str(tmp_path/'previous.sqlite3'),1234567890,'a'*64,False))
    column='  hide_notification_content INTEGER NOT NULL DEFAULT 0 CHECK(hide_notification_content IN (0,1)),\n'
    with sqlite3.connect(settings.db_path) as db:
        db.executescript(SCHEMA.replace(column,''))
        for index in range(2):
            db.execute('INSERT INTO accounts(account_id,login_id,sdk_user_id,name,notifications,created_at) VALUES(?,?,?,?,?,1)',
                       (str(index),'legacy_'+str(index),'sdk_'+str(index),'旧昵称',index))
    for restart in range(2):
        with TestClient(create_app(settings)):
            with database(settings) as db:
                saved=db.execute('SELECT hide_notification_content FROM accounts ORDER BY account_id').fetchall()
                assert [row[0] for row in saved]==([0,0] if restart==0 else [1,0])
                assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
                if restart==0:db.execute("UPDATE accounts SET hide_notification_content=1 WHERE account_id='0'")


def test_default_preview_resolves_current_name_and_body_without_persisting_them_in_outbox(env,caplog):
    e=env;a,b=login(e.c,'preview-sender'),login(e.c,'preview-recipient');register(e,b)
    follow(e,a,b)
    with caplog.at_level(logging.INFO):e.s.dispatch()
    assert json.loads(e.requests[0].content)['aps']['alert']=={'title':a['user']['name'],'body':'关注了你'}
    clear(e);e.requests.clear()
    request_id=rid();send(e,a,b,request_id);send(e,a,b,request_id)
    assert len(rows(e))==1
    assert e.c.patch('/v1/me',headers=authorization(a),json={'name':'最新昵称'}).status_code==200
    with caplog.at_level(logging.INFO):e.s.dispatch()
    assert len(e.requests)==1
    payload=json.loads(e.requests[0].content)
    assert payload['aps']['alert']=={'title':'最新昵称','body':MESSAGE_TEXT}
    assert set(payload)=={'aps','deliveryID','accountTag'} and a['user']['id'] not in e.requests[0].content.decode()
    persisted=json.dumps(rows(e),ensure_ascii=False)
    for private in ('最新昵称',MESSAGE_TEXT):
        assert private not in persisted and private not in caplog.text


def test_default_interaction_preview_contains_comment_text_and_specific_system_notice(env):
    e=env;a,b=login(e.c,'commenter'),login(e.c,'moment-owner');register(e,b)
    post=e.c.post('/v1/social/moments',headers=authorization(b),json={'requestID':rid(),'text':'动态','mediaIDs':[]}).json()['moment']
    assert e.c.put('/v1/social/moments/'+post['id']+'/like',headers=authorization(a),json={'requestID':rid()}).status_code==200
    comment=e.c.post('/v1/social/moments/'+post['id']+'/comments',headers=authorization(a),json={'requestID':rid(),'text':'这条动态很有意思'})
    assert comment.status_code==200
    e.s.dispatch()
    alerts=[json.loads(request.content)['aps']['alert'] for request in e.requests]
    assert {'title':a['user']['name'],'body':'赞了你的动态'} in alerts
    assert {'title':a['user']['name'],'body':'评论了你的动态：这条动态很有意思'} in alerts
    with database(e.c.settings) as db:
        owner=db.execute('SELECT account_id FROM accounts WHERE login_id=?',(b['user']['id'],)).fetchone()[0]
        e.social.notice(db,owner,'safety','你的社交发布限制已解除。')
    e.s.dispatch()
    assert json.loads(e.requests[-1].content)['aps']['alert']=={'title':'Kiki语聊','body':'你的社交发布限制已解除。'}


@pytest.mark.parametrize('phase',['policy','provider'])
@pytest.mark.parametrize('hidden',[False,True],ids=['show','hide'])
def test_dispatch_reads_preference_after_policy_and_provider_preparation(env,monkeypatch,phase,hidden):
    e=env;a,b=login(e.c,'sender'),login(e.c,'recipient');register(e,b)
    assert e.c.patch('/v1/me',headers=authorization(b),json={'hideNotificationContent':not hidden}).status_code==200
    send(e,a,b)
    target=e.social if phase=='policy' else e.s
    method='policy' if phase=='policy' else 'provider_token'
    original=getattr(target,method)
    def changed_before_final_validation(*args,**kwargs):
        result=original(*args,**kwargs)
        assert e.c.patch('/v1/me',headers=authorization(b),json={'hideNotificationContent':hidden}).status_code==200
        assert e.c.patch('/v1/me',headers=authorization(a),json={'name':'发送前昵称'}).status_code==200
        return result
    monkeypatch.setattr(target,method,changed_before_final_validation)
    e.s.dispatch()
    alert=json.loads(e.requests[0].content)['aps']['alert']
    assert alert==(push.GENERIC_ALERT if hidden else {'title':'发送前昵称','body':MESSAGE_TEXT})


@pytest.mark.parametrize('first_hidden',[False,True])
def test_ambiguous_retry_rechecks_preference_without_changing_delivery_id(env,first_hidden,caplog):
    e=env;a,b=login(e.c,'retry-sender'),login(e.c,'retry-recipient');register(e,b)
    assert e.c.patch('/v1/me',headers=authorization(b),json={'hideNotificationContent':first_hidden}).status_code==200
    send(e,a,b)
    e.responses.append(httpx.ReadTimeout(MESSAGE_TEXT))
    with caplog.at_level(logging.INFO):e.s.dispatch()
    assert rows(e)[0]['state']=='pending'
    assert e.c.patch('/v1/me',headers=authorization(b),json={'hideNotificationContent':not first_hidden}).status_code==200
    with database(e.c.settings) as db:db.execute('UPDATE push_outbox SET next_attempt_at=0')
    with caplog.at_level(logging.INFO):e.s.dispatch()
    assert len(e.requests)==2 and e.requests[0].headers['apns-id']==e.requests[1].headers['apns-id']
    expected={'title':a['user']['name'],'body':MESSAGE_TEXT}
    assert json.loads(e.requests[0].content)['aps']['alert']==(push.GENERIC_ALERT if first_hidden else expected)
    assert json.loads(e.requests[1].content)['aps']['alert']==(expected if first_hidden else push.GENERIC_ALERT)
    assert MESSAGE_TEXT not in json.dumps(rows(e)) and MESSAGE_TEXT not in caplog.text


def test_deleted_comment_during_provider_preparation_never_leaks_preview(env,monkeypatch):
    e=env;a,b=login(e.c,'late-commenter'),login(e.c,'late-recipient');register(e,b)
    post=e.c.post('/v1/social/moments',headers=authorization(b),json={'requestID':rid(),'text':'动态','mediaIDs':[]}).json()['moment']
    comment=e.c.post('/v1/social/moments/'+post['id']+'/comments',headers=authorization(a),json={'requestID':rid(),'text':'发送前已经删除的评论'}).json()['comment']
    original=e.s.provider_token
    def deleted_before_final_validation(environment):
        result=original(environment)
        assert e.c.delete('/v1/social/comments/'+comment['id'],headers=authorization(a)).status_code==200
        return result
    monkeypatch.setattr(e.s,'provider_token',deleted_before_final_validation)
    e.s.dispatch()
    assert e.requests==[] and rows(e)[0]['state']=='cancelled'


@pytest.mark.parametrize('text',['🙂'*1000,'转义"\\\n'*1200],ids=['utf8-dm','escaped-system'])
def test_preview_payload_is_utf8_bounded_and_outbox_remains_content_free(env,text):
    e=env;a,b=login(e.c,'byte-sender'),login(e.c,'byte-recipient');register(e,b)
    if text.startswith('🙂'):
        send(e,a,b,text=text)
    else:
        with database(e.c.settings) as db:
            owner=db.execute('SELECT account_id FROM accounts WHERE login_id=?',(b['user']['id'],)).fetchone()[0]
            e.social.notice(db,owner,'safety',text)
    e.s.dispatch()
    request=e.requests[0];body=json.loads(request.content)['aps']['alert']['body']
    assert body.endswith('…') and len(body.encode('utf-8'))<=push.MAX_ALERT_BODY_BYTES
    assert len(request.content)<=4096
    assert text[:12] not in json.dumps(rows(e),ensure_ascii=False)

def test_registration_revision_encryption_variable_token_and_strict_shape(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob')
    installation,body,r=register(e,a,token='a1');assert r.status_code==200 and r.json()['registered']
    assert e.c.put('/v1/push/devices/'+installation,headers=authorization(a),json=body).json()==r.json()
    assert e.c.put('/v1/push/devices/'+installation,headers=authorization(a),json={**body,'token':'b2'}).status_code==409
    assert register(e,a,token='abc')[2].status_code==422
    assert register(e,a,token='00'*256)[2].status_code==200
    assert register(e,a,token='00'*257)[2].status_code==422
    assert register(e,a,revision=True)[2].status_code==422
    assert register(e,a,permission='unknown')[2].status_code==422
    assert e.c.put('/v1/push/devices/notuuid',headers=authorization(a),json=body).status_code==422
    assert e.c.put('/v1/push/devices/'+installation,json=body).status_code==401
    saved=rows(e,'push_devices')[0]
    assert e.s.cipher.decrypt(saved['token_encrypted'].encode())==b'a1'
    assert saved['installation_hash']!=installation and saved['token_encrypted']!='a1'
    assert register(e,b,installation,token='a1',revision=2)[2].status_code==200
    assert e.c.put('/v1/push/devices/'+installation,headers=authorization(a),json=body).status_code==409
    e.c.request('DELETE','/v1/push/devices/'+installation,headers=authorization(a),json={'revision':3})
    e.c.post('/v1/auth/logout',headers=authorization(a))
    saved=rows(e,'push_devices');assert len(saved)==1 and saved[0]['session_hash']==hashlib.sha256(b['token'].encode()).hexdigest()

def test_unregister_and_denied_watermarks_block_late_register(env):
    e=env;a=login(e.c);installation,body,_=register(e,a)
    assert e.c.request('DELETE','/v1/push/devices/'+installation,headers=authorization(a),json={'revision':2}).json()=={'ok':True}
    assert rows(e,'push_devices')==[]
    assert e.c.put('/v1/push/devices/'+installation,headers=authorization(a),json=body).status_code==409
    assert register(e,a,installation,revision=3,permission='denied')[2].json()['registered'] is False
    assert rows(e,'push_devices')==[]

def test_multi_device_session_logout_only_removes_its_binding(env):
    e=env;a,b=login(e.c),login(e.c);assert a['user']['id']==b['user']['id']
    register(e,a);register(e,b);assert len(rows(e,'push_devices'))==2
    e.c.post('/v1/auth/logout',headers=authorization(a));saved=rows(e,'push_devices')
    assert len(saved)==1 and saved[0]['session_hash']==hashlib.sha256(b['token'].encode()).hexdigest()

def test_transactional_enqueue_idempotency_hidden_alert_and_opaque_route(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b)
    assert e.c.patch('/v1/me',headers=authorization(b),json={'hideNotificationContent':True}).status_code==200
    follow(e,a,b)
    assert len(rows(e))==1;e.s.dispatch();assert len(e.requests)==1
    request=e.requests[0];payload=json.loads(request.content)
    assert set(payload)=={'aps','deliveryID','accountTag'}
    assert 'alice' not in request.content.decode() and a['user']['id'] not in request.content.decode()
    assert request.headers['apns-topic']==push.TOPIC and request.headers['apns-push-type']=='alert'
    assert jwt.decode(request.headers['authorization'][7:],e.key.public_key(),algorithms=['ES256'],options={'verify_aud':False})['iss']=='A82X46N3WS'
    dest='/v1/push/destinations/'+payload['deliveryID']
    assert e.c.get(dest,headers=authorization(b)).json()['personID']==a['user']['id']
    assert e.c.get(dest,headers=authorization(a)).status_code==404
    notice=rows(e,'social_notifications')[0]
    e.c.post('/v1/social/notifications/read',headers=authorization(b),json={'ids':[notice['id']]})
    assert e.c.get(dest,headers=authorization(b)).status_code==404
    assert e.c.get('/v1/push/status',headers=authorization(b)).json()['badgeCount']==0
    friends(e,a,b);clear(e);request_id=rid();send(e,a,b,request_id);send(e,a,b,request_id)
    assert len(rows(e))==1
    with pytest.raises(RuntimeError):
        with database(e.c.settings) as db:
            target=db.execute('SELECT account_id FROM accounts WHERE login_id=?',(b['user']['id'],)).fetchone()[0]
            e.social.notice(db,target,'safety','事务回滚');raise RuntimeError('rollback')
    assert len(rows(e))==1

def test_like_comment_safety_queue_and_deleted_content(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b)
    post=e.c.post('/v1/social/moments',headers=authorization(b),json={'requestID':rid(),'text':'动态','mediaIDs':[]}).json()['moment']
    like=e.c.put('/v1/social/moments/'+post['id']+'/like',headers=authorization(a),json={'requestID':rid()})
    comment=e.c.post('/v1/social/moments/'+post['id']+'/comments',headers=authorization(a),json={'requestID':rid(),'text':'评论'})
    assert len(rows(e))==2,(like.text,comment.text)
    e.c.request('DELETE','/v1/social/moments/'+post['id'],headers=authorization(b),json={'requestID':rid()})
    e.s.dispatch();assert e.requests==[] and all(r['state']=='cancelled' for r in rows(e))
    assert e.c.patch('/v1/me',headers=authorization(b),json={'hideNotificationContent':True}).status_code==200
    with database(e.c.settings) as db:
        target=db.execute('SELECT account_id FROM accounts WHERE login_id=?',(b['user']['id'],)).fetchone()[0]
        e.social.notice(db,target,'safety','违规详情不能出现在锁屏')
    e.s.dispatch();assert len(e.requests)==1 and '违规' not in e.requests[0].content.decode()

def test_off_on_never_revives_queue_and_inapp_notice_survives(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    e.c.patch('/v1/me',headers=authorization(b),json={'notificationsEnabled':False})
    e.c.patch('/v1/me',headers=authorization(b),json={'notificationsEnabled':True})
    e.s.dispatch();assert e.requests==[] and rows(e)[0]['state']=='cancelled'
    assert e.c.get('/v1/social/notifications',headers=authorization(b)).json()['unreadCount']==1

def test_dm_unfollow_refollow_read_block_and_unavailable_failclosed(env,monkeypatch):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');friends(e,a,b);register(e,b);clear(e)
    send(e,a,b);follow(e,a,b,False);follow(e,a,b,True);e.s.dispatch();assert len(e.requests)==1
    e.requests.clear()
    message=send(e,a,b)
    r=e.c.post('/v1/social/conversations/'+a['user']['id']+'/read',headers=authorization(b),json={'throughMessageID':message['message']['id']})
    assert r.status_code==200,r.text
    e.s.dispatch();assert e.requests==[]
    send(e,a,b)
    e.social.policy=lambda user,target_ids=():Policy(schemaVersion=1,accountID=user['login_id'],blockedUserIDs=[a['user']['id']],currentRooms=[],roomsStale=True)
    e.s.dispatch();assert e.requests==[]
    setup(e.c);send(e,a,b)
    def unavailable(*args):raise HTTPException(503,'privacy unavailable')
    monkeypatch.setattr(e.social,'policy',unavailable);e.s.dispatch()
    assert e.requests==[] and rows(e)[-1]['state']=='pending' and rows(e)[-1]['error_code']=='privacy_unavailable'


def test_stranger_introductions_keep_push_routes_and_badges_after_follow_changes(env):
    e=env;a,b=login(e.c,'stranger-sender'),login(e.c,'stranger-recipient')
    assert register(e,b)[2].status_code==200
    sent=[send(e,a,b) for _ in range(5)]
    assert len(rows(e))==5
    denied=e.c.post('/v1/social/conversations/'+b['user']['id']+'/messages',headers=authorization(a),json={'requestID':rid(),'text':'第六条'})
    assert denied.status_code==403 and len(rows(e))==5
    follow(e,a,b);follow(e,a,b,False)
    direct=[item for item in rows(e) if item['event_kind']=='direct_message']
    assert len(direct)==5 and all(item['state']=='pending' for item in direct)
    assert e.c.get('/v1/push/status',headers=authorization(b)).json()['badgeCount']==6
    for item in direct:
        destination=e.c.get('/v1/push/destinations/'+item['id'],headers=authorization(b))
        assert destination.json()=={'type':'direct_message','personID':a['user']['id']}
        assert e.c.get('/v1/push/destinations/'+item['id'],headers=authorization(a)).status_code==404
    e.s.dispatch()
    assert len(e.requests)==5
    assert all(json.loads(request.content)['aps']['alert']=={'title':a['user']['name'],'body':MESSAGE_TEXT}
               and a['user']['id'] not in request.content.decode() and '第六条' not in request.content.decode()
               for request in e.requests)
    response=e.c.post('/v1/social/conversations/'+a['user']['id']+'/read',headers=authorization(b),json={'throughMessageID':sent[-1]['message']['id']})
    assert response.json()=={'unreadCount':0}
    assert e.c.get('/v1/push/status',headers=authorization(b)).json()['badgeCount']==1
    assert all(e.c.get('/v1/push/destinations/'+item['id'],headers=authorization(b)).status_code==404 for item in direct)


def test_dm_destination_does_not_accept_mismatched_outbox_actor(env):
    e=env;a,b,c=[login(e.c,name) for name in ('dm-source','dm-recipient','dm-wrong-actor')]
    register(e,b);send(e,a,b)
    entry=rows(e)[0]
    with database(e.c.settings) as db:
        wrong=db.execute('SELECT account_id FROM accounts WHERE login_id=?',(c['user']['id'],)).fetchone()[0]
        db.execute('UPDATE push_outbox SET actor_id=? WHERE id=?',(wrong,entry['id']))
    assert e.c.get('/v1/push/destinations/'+entry['id'],headers=authorization(b)).status_code==404
    e.s.dispatch();assert e.requests==[] and rows(e)[0]['state']=='cancelled'

@pytest.mark.parametrize('status,reason,expected',[(429,'TooManyRequests','pending'),(503,'Shutdown','pending'),(400,'PayloadTooLarge','failed'),(403,'InvalidProviderToken','failed'),(410,'Unregistered','failed')])
def test_retry_and_permanent_classification(env,status,reason,expected):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    e.responses.append(httpx.Response(status,json={'reason':reason},headers={'retry-after':'120'}));e.s.dispatch();saved=rows(e)[0]
    assert saved['state']==expected and saved['attempts']==1
    if expected=='pending':assert saved['next_attempt_at']>=int(e.s.clock())+119
    assert len(rows(e,'push_devices'))==(0 if status==410 else 1)

def test_lease_claim_and_timeout_expiry_are_durable(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    second=push.PushService(e.s.settings,database,e.social,e.s.limits)
    first=e.s.claim();assert first and second.claim() is None
    with database(e.c.settings) as db:db.execute('UPDATE push_outbox SET lease_until=0')
    retry=second.claim();assert retry and retry['lease_id']!=first['lease_id']
    e.s.finish(first,'accepted');assert rows(e)[0]['state']=='sending'
    second.finish(retry,'pending','transport_error')
    with database(e.c.settings) as db:db.execute('UPDATE push_outbox SET expires_at=0')
    assert second.claim() is None
    assert rows(e)[0]['state']=='failed' and rows(e)[0]['error_code']=='expired';second.close()

def test_late_410_cannot_remove_new_owner(env):
    e=env;a,b,c=[login(e.c,n) for n in ('alice','bob','charlie')];installation,body,_=register(e,a);follow(e,c,a)
    claimed=e.s.claim();register(e,b,installation,token=body['token'],revision=2)
    e.s.finish(claimed,'failed','unregistered',invalid=True);saved=rows(e,'push_devices')
    assert len(saved)==1 and saved[0]['session_hash']==hashlib.sha256(b['token'].encode()).hexdigest()
    assert e.c.get('/v1/push/destinations/'+claimed['id'],headers=authorization(b)).status_code==404

def test_preflight_session_revocation_prevents_send(env,monkeypatch):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b);original=e.social.policy
    def policy(user,target_ids=()):
        result=original(user,target_ids)
        with database(e.c.settings) as db:db.execute('DELETE FROM sessions WHERE token_hash=?',(hashlib.sha256(b['token'].encode()).hexdigest(),))
        return result
    monkeypatch.setattr(e.social,'policy',policy);e.s.dispatch();assert e.requests==[] and rows(e)[0]['state']=='cancelled'

@pytest.mark.parametrize('path',['/v1/me/legal-consent','/v1/account'])
def test_withdrawal_delete_remove_devices_and_event_refs(env,path):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    response=e.c.delete(path,headers=authorization(b));assert response.status_code==200,response.text
    assert rows(e,'push_devices')==[] and rows(e)==[]
    e.s.dispatch();assert e.requests==[]

def test_retention_summary_and_token_logging_redaction(env,caplog):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');_,body,_=register(e,b);follow(e,a,b);e.s.dispatch()
    with database(e.c.settings) as db:
        summary=push.metrics(db,e.s.settings,int(e.s.clock()));assert summary['accepted']==1 and summary['activeDevices']==1
        assert body['token'] not in json.dumps(summary) and 'installation' not in json.dumps(summary)
        for table,column in [('push_devices','last_seen'),('push_outbox','created_at'),('push_installations','updated_at')]:db.execute('UPDATE '+table+' SET '+column+'=0')
        push.purge(db)
    assert rows(e)==[] and rows(e,'push_devices')==[] and rows(e,'push_installations')==[]
    with caplog.at_level(logging.INFO,logger='httpx'):logging.getLogger('httpx').info('HTTP Request: POST https://api.push.apple.com/3/device/%s 200',body['token'])
    assert body['token'] not in caplog.text and '<redacted>' in caplog.text

def test_jwt_environment_cache_and_independent_key_configuration(env):
    e=env;sandbox=e.s.provider_token('sandbox');production=e.s.provider_token('production')
    assert jwt.get_unverified_header(sandbox)['kid']=='SYNTHKEY01' and jwt.get_unverified_header(production)['kid']=='SYNTHKEY02'
    assert e.s.provider_token('sandbox')==sandbox;push.validate_settings(e.s.settings)
    with pytest.raises(RuntimeError):push.validate_settings(replace(e.s.settings,apns_sandbox_key_id=e.c.settings.apple_key_id))
    with pytest.raises(RuntimeError):push.validate_settings(replace(e.s.settings,apns_sandbox_private_key_path=e.c.settings.apple_private_key_path))

def test_policy_latency_crossing_ttl_or_lease_cannot_send(env,monkeypatch):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    real=e.s.clock();original=e.social.policy;claimed=e.s.claim()
    with database(e.c.settings) as db:db.execute('UPDATE push_outbox SET expires_at=?',(int(real)+1,))
    claimed['expires_at']=int(real)+1
    def late(user,target_ids=()):
        result=original(user,target_ids);e.s.clock=lambda:real+2;return result
    monkeypatch.setattr(e.social,'policy',late);e.s.send_one(claimed)
    assert e.requests==[] and rows(e)[0]['state']=='failed' and rows(e)[0]['error_code']=='expired'

def test_network_timeout_retries_same_apns_id_and_no_read_receipt(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    e.responses.append(httpx.ReadTimeout('synthetic timeout'));e.s.dispatch();first=e.requests[0]
    assert rows(e)[0]['state']=='pending' and rows(e)[0]['error_code']=='transport_error'
    with database(e.c.settings) as db:db.execute('UPDATE push_outbox SET next_attempt_at=0')
    e.s.dispatch()
    assert len(e.requests)==2 and e.requests[1].headers['apns-id']==first.headers['apns-id']
    assert e.requests[1].headers['apns-collapse-id']==first.headers['apns-collapse-id']
    assert rows(e)[0]['state']=='accepted' and rows(e,'social_notifications')[0]['read_at'] is None

def test_same_token_isolated_by_apns_environment_and_token_rotation(env):
    e=env;a=login(e.c);token='ab'*40
    installation,_,_=register(e,a,token=token)
    register(e,a,token=token,environment='production');assert len(rows(e,'push_devices'))==2
    register(e,a,installation,token='cd'*20,revision=2)
    saved=rows(e,'push_devices');assert len(saved)==2
    assert {r['environment'] for r in saved}=={'sandbox','production'}

def test_provider_response_never_deletes_registration_newer_than_410_timestamp(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b)
    old=(int(e.s.clock())-60)*1000
    e.responses.append(httpx.Response(410,json={'reason':'Unregistered','timestamp':old}));e.s.dispatch()
    assert len(rows(e,'push_devices'))==1 and rows(e)[0]['state']=='failed'

def test_disable_preference_during_policy_preflight_cancels_claim(env,monkeypatch):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob');register(e,b);follow(e,a,b);original=e.social.policy
    def policy(user,target_ids=()):
        result=original(user,target_ids)
        assert e.c.patch('/v1/me',headers=authorization(b),json={'notificationsEnabled':False}).status_code==200
        assert e.c.patch('/v1/me',headers=authorization(b),json={'notificationsEnabled':True}).status_code==200
        return result
    monkeypatch.setattr(e.social,'policy',policy);e.s.dispatch()
    assert e.requests==[] and rows(e)[0]['state']=='cancelled'

from test_voice_bridge import bridge_client,real_voice_service

def test_real_hmac_policy_blocks_queued_push_and_reaccept_cannot_restore_old_bindings(real_voice_service,monkeypatch):
    pair=real_voice_service;c=pair.account;s=c.app.state.push
    s.settings=replace(c.settings,apns_enabled=True)
    # Transport and provider signing are synthetic here. The canonical block
    # policy, account sessions, consent and signed cross-service calls are real.
    captured=[]
    s.http=httpx.Client(transport=httpx.MockTransport(lambda request:captured.append(request) or httpx.Response(200)))
    monkeypatch.setattr(s,'provider_token',lambda environment:'synthetic-provider')
    e=SimpleNamespace(c=c,s=s,social=c.app.state.social)
    a,b=login(c,'alice'),login(c,'bob');friends(e,a,b);register(e,b)
    message=send(e,a,b)
    result=c.put('/v1/social/blocks/'+a['user']['id'],headers=authorization(b),json={'requestID':rid()})
    assert result.status_code==200,result.text
    s.dispatch();assert captured==[] and rows(e)[0]['state']=='cancelled'
    assert any('/internal/v1/account/social-policy' in str(request.url) for request in pair.captured)
    assert c.delete('/v1/me/legal-consent',headers=authorization(b)).status_code==200
    assert rows(e,'push_devices')==[] and rows(e)==[]
    # Apple login and fresh consent create a new session, never old bindings.
    again=login(c,'bob');assert again['user']['id']==b['user']['id']
    assert c.get('/v1/push/status',headers=authorization(again)).json()['registered'] is False

def test_registration_is_rechecked_for_current_consent_and_apns_disabled_has_no_queue(env):
    e=env;a,b=login(e.c,'alice'),login(e.c,'bob')
    e.s.settings=replace(e.s.settings,apns_enabled=False);register(e,b);follow(e,a,b)
    assert rows(e)==[]
    e.c.delete('/v1/me/legal-consent',headers=authorization(b))
    assert register(e,b,token='ab')[2].status_code==401


def test_account_preview_preference_does_not_expand_actual_voice_exchange_profile(real_voice_service):
    pair=real_voice_service;c=pair.account;a=login(c,'private-preview')
    assert c.patch('/v1/me',headers=authorization(a),json={'hideNotificationContent':True}).status_code==200
    exchanged=c.post('/v1/voice/session',headers=authorization(a))
    assert exchanged.status_code==200,exchanged.text
    request=next(request for request in reversed(pair.captured) if request.url.path=='/internal/v1/account/session')
    profile=json.loads(request.content)['user']
    assert set(profile)=={'id','sdkUserID','name','bio','avatarIndex','avatarURL','needsNickname','notificationsEnabled'}
    assert 'hideNotificationContent' not in exchanged.json()['user']
    assert pair.voice.get('/v1/me',headers=authorization(exchanged.json())).json()['id']==a['user']['id']
    assert c.get('/v1/me',headers=authorization(a)).json()['hideNotificationContent'] is True
