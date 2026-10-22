from dataclasses import replace
import hashlib
import hmac
import json
import uuid

import httpx
import pytest

from app.social import Policy, POLICY_PATH
from app.main import database
from test_api import client, login, authorization


def rid():return str(uuid.uuid4())


def setup(client):
    service=client.app.state.social
    service.policy=lambda user,target_ids=():Policy(schemaVersion=1,accountID=user['login_id'],blockedUserIDs=[],currentRooms=[],roomsStale=True)
    return service


def test_people_follow_literal_search_cursor_binding_and_notification_ack(client):
    setup(client)
    alice,bob,charlie=[login(client,name) for name in ('alice','bob','charlie')]
    path='/v1/social/people'
    assert client.get(path).status_code==401
    page=client.get(path,headers=authorization(alice),params={'limit':1}).json()
    assert page['nextCursor'] and len(page['people'])==1
    other=client.get(path,headers=authorization(alice),params={'limit':1,'cursor':page['nextCursor']}).json()
    assert other['people'][0]['id']!=page['people'][0]['id']
    assert client.get(path,headers=authorization(bob),params={'cursor':page['nextCursor']}).status_code==422
    assert client.get(path,headers=authorization(alice),params={'query':'%'}).json()['people']==[]
    assert client.get(path,headers=authorization(alice),params={'query':'_'}).json()['people']
    request_id=rid()
    target='/v1/social/follows/'+bob['user']['id']
    assert client.put(target,headers=authorization(alice),json={'requestID':request_id}).json()['person']['following']
    assert client.put(target,headers=authorization(alice),json={'requestID':request_id}).status_code==200
    assert client.request('DELETE',target,headers=authorization(alice),json={'requestID':request_id}).status_code==409
    notifications='/v1/social/notifications'
    notice=client.get(notifications,headers=authorization(bob)).json()
    assert notice['unreadCount']==1 and len(notice['notifications'])==1
    assert client.post(notifications+'/read',headers=authorization(alice),json={'ids':[notice['notifications'][0]['id']]}).status_code==200
    assert client.get(notifications,headers=authorization(bob)).json()['unreadCount']==1
    assert client.post(notifications+'/read',headers=authorization(bob),json={'all':True}).json()=={'unreadCount':0}
    assert client.post(notifications+'/read',headers=authorization(bob),json={'all':True,'ids':[rid()]}).status_code==422


def test_social_fail_closed_preserves_account_login_and_deletion(client):
    alice=login(client)
    for path in ('/v1/social/people','/v1/social/relationships/ids','/v1/social/notifications','/v1/social/moments','/v1/social/conversations'):
        assert client.get(path,headers=authorization(alice)).status_code==503
    assert client.get('/v1/me',headers=authorization(alice)).status_code==200
    assert client.delete('/v1/account',headers=authorization(alice)).status_code==200


def test_policy_hmac_exact_path_bounded_shape_and_final_session_recheck(client):
    alice,bob=[login(client,name) for name in ('alice','bob')]
    service=client.app.state.social
    secret='Qp9Dm2Lx4Nv7Hr3Jk8Wa6Te1Yc5Su0Bg9Fz2Pe7Ri4Om8Ad5'
    service.settings=replace(client.settings,voice_bridge_enabled=True,voice_bridge_secret=secret)
    requests=[]
    revoke=False
    def send(request):
        requests.append(request)
        payload=json.loads(request.content)
        assert str(request.url)=='https://furby.top'+POLICY_PATH and request.method=='POST'
        message='\n'.join(('account-voice-v1','POST',POLICY_PATH,request.headers['X-Kiki-Timestamp'],request.headers['X-Kiki-Nonce'],hashlib.sha256(request.content).hexdigest())).encode()
        assert hmac.compare_digest(request.headers['X-Kiki-Signature'],hmac.new(secret.encode(),message,hashlib.sha256).hexdigest())
        assert set(payload)=={'accountID','targetIDs'}
        if revoke:
            with database(client.settings) as db:db.execute('DELETE FROM sessions WHERE token_hash=?',(hashlib.sha256(alice['token'].encode()).hexdigest(),))
        return httpx.Response(200,json={'schemaVersion':1,'accountID':payload['accountID'],'blockedUserIDs':[],'currentRooms':[],'roomsStale':True})
    service.bridge.http.close();service.bridge.http=httpx.Client(transport=httpx.MockTransport(send))
    assert client.get('/v1/social/people',headers=authorization(alice)).status_code==200
    assert len(requests)==1
    revoke=True
    response=client.get('/v1/social/people',headers=authorization(alice))
    assert response.status_code==401 and bob['user']['id'] not in response.text


@pytest.mark.parametrize('change',[{'accountID':'kiki_wrongidentity'},{'roomsStale':False,'currentRooms':[{'userID':'kiki_unrequested','roomID':'lk_'+'a'*32}]},{'blockedUserIDs':['bad url://secret']},{'schemaVersion':True}])
def test_malformed_policy_is_not_downgraded_to_empty_blocks(client,change):
    alice=login(client)
    service=client.app.state.social
    service.settings=replace(client.settings,voice_bridge_enabled=True,voice_bridge_secret='z'*64)
    result={'schemaVersion':1,'accountID':alice['user']['id'],'blockedUserIDs':[],'currentRooms':[],'roomsStale':True,**change}
    service.bridge.http.close();service.bridge.http=httpx.Client(transport=httpx.MockTransport(lambda request:httpx.Response(200,json=result)))
    assert client.get('/v1/social/people',headers=authorization(alice)).status_code==503


def test_block_request_retry_cannot_reapply_after_newer_unblock(client):
    service=setup(client)
    alice,bob=[login(client,name) for name in ('alice','bob')]
    calls=[]
    state=False
    fail_once=True
    from fastapi import HTTPException
    def privacy(path,payload):
        nonlocal state,fail_once
        calls.append(payload)
        state=payload['blocked']
        if fail_once:
            fail_once=False
            raise HTTPException(503,'隐私设置暂时不可用')
        return {'schemaVersion':1,'accountID':payload['accountID'],'targetID':payload['targetID'],'blocked':payload['blocked']}
    service.privacy_post=privacy
    route='/v1/social/blocks/'+bob['user']['id']
    block_id=rid()
    assert client.put(route,headers=authorization(alice),json={'requestID':block_id}).status_code==503
    assert state is True
    assert client.request('DELETE',route,headers=authorization(alice),json={'requestID':rid()}).status_code==200
    assert state is False
    before=len(calls)
    assert client.put(route,headers=authorization(alice),json={'requestID':block_id}).json()=={'ok':True,'blocked':False}
    assert len(calls)==before and state is False
    assert client.request('DELETE',route,headers=authorization(alice),json={'requestID':block_id}).status_code==409


def test_interaction_notice_links_to_auth_single_moment(client):
    setup(client)
    alice,bob=[login(client,name) for name in ('alice','bob')]
    created=client.post('/v1/social/moments',headers=authorization(alice),json={'requestID':rid(),'text':'晚饭后的闲聊','mediaIDs':[]})
    assert created.status_code==200,created.text
    moment=created.json()['moment']
    assert client.put('/v1/social/moments/'+moment['id']+'/like',headers=authorization(bob),json={'requestID':rid()}).status_code==200
    notice=client.get('/v1/social/notifications',headers=authorization(alice)).json()['notifications'][0]
    assert notice['momentID']==moment['id']
    assert client.get('/v1/social/moments/'+moment['id']).status_code==401
    assert client.get('/v1/social/moments/'+moment['id'],headers=authorization(alice)).json()['moment']['id']==moment['id']
    assert client.delete('/v1/social/moments/'+moment['id'],headers=authorization(alice)).status_code==200
    assert client.get('/v1/social/moments/'+moment['id'],headers=authorization(alice)).status_code==404


from test_voice_bridge import bridge_client


def test_periodic_privacy_cleanup_keeps_incident_purge_inside_open_transaction(bridge_client):
    # The minute maintenance path includes both old diagnostic queues and new
    # social retention; invoking it directly also detects a closed-DB regression.
    bridge_client.app.state.purge_privacy_metadata()
    actor=login(bridge_client)
    assert bridge_client.get('/v1/me',headers=authorization(actor)).status_code==200
