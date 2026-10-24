"""Safety is enforced by the service, including old media credentials and retries."""
from dataclasses import replace
from datetime import datetime, timedelta
import json
from pathlib import Path
import time
import uuid
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest
import jwt

from app.main import create_app
from app import admin
from app.ops_gateway import DASHBOARD_PATH, MODERATION_ACTION_PATH, MODERATION_QUERY_PATH
from app.safety import AUDIT_SECONDS, REPORT_SECONDS, SafetyStore
from conftest import FakeLiveKit, create_room, headers, login
from test_ops_gateway import ops, signed
from test_room_actions import act, authorize, setup_room, state, token
from test_account_bridge import account_service, exchange, payload as bridge_payload, profile, signed as bridge_signed

ACTOR = "ops_" + "a" * 32


@pytest.fixture
def community(ops, lab):
    ops.consent = lab.consent
    return ops


def report(lab, room, reporter, target, *, target_type="user", status=200, **changes):
    payload = {"clientRequestID":str(uuid.uuid4()),"targetType":target_type,"roomID":room["id"],
        "reason":"harassment","details":"请核实房内骚扰。"}
    if target_type == "user":
        payload["targetUserID"] = target["user"]["id"]
    payload.update(changes)
    response = lab.client.post("/v1/safety/reports",headers=headers(reporter),json=payload)
    assert response.status_code == status,response.text
    return response.json()


def moderate(lab, entry, action, *, status=200, **changes):
    payload = {"requestID":str(uuid.uuid4()),"reportID":entry["id"],"action":action,
        "note":"请遵守社区规则。","opsActorID":ACTOR}
    if action in {"mute_chat","mute_audio","ban_user"}:
        payload["durationSeconds"] = 300
    payload.update(changes)
    body = json.dumps(payload,ensure_ascii=False,separators=(",",":")).encode()
    response = lab.client.post(MODERATION_ACTION_PATH,content=body,headers=signed(path=MODERATION_ACTION_PATH,body=body))
    assert response.status_code == status,response.text
    return response.json()


def safety(lab, account):
    response = lab.client.get("/v1/safety",headers=headers(account))
    assert response.status_code == 200,response.text
    return response.json()


def test_block_filters_authoritative_messages_and_announcement_without_stalling_cursor(lab):
    room,(owner,guest,other),_ = setup_room(lab,3)
    with lab.app.state.db:
        lab.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?", ("kiki_000001", owner["user"]["id"]))
    for sender,text in ((owner,"公告作者的消息"),(other,"其他人的消息")):
        response = lab.client.post(f'/v1/rooms/{room["id"]}/messages',headers=headers(sender),
            json={"clientMessageID":str(uuid.uuid4()),"text":text})
        assert response.status_code == 200
    lab.client.put(f'/v1/rooms/{room["id"]}/announcement',headers=headers(owner),json={"text":"新的房间公告"})
    response = lab.client.put('/v1/safety/blocks/'+owner['user']['id'],headers=headers(guest))
    assert response.status_code == 200
    assert response.json()["blockedUsers"][0]["name"] == owner["user"]["name"]
    assert response.json()["blockedUsers"][0]["displayID"] == "kiki_000001"
    assert response.json()["blockedUsers"][0]["userID"] == owner["user"]["id"]
    assert safety(lab, guest)["blockedUsers"][0]["displayID"] == "kiki_000001"
    data = lab.client.get(f'/v1/rooms/{room["id"]}/messages',headers=headers(guest)).json()
    assert [m["text"] for m in data["messages"]] == ["其他人的消息"]
    assert data["latestSeq"] == data["nextAfterSeq"] == 2
    assert data["announcement"]["text"] == "" and data["announcement"]["updatedByUserID"] is None
    assert len(state(lab,room,guest)["members"]) == 3  # Public presence is not a privacy promise.
    assert len(lab.client.get(f'/v1/rooms/{room["id"]}/messages',headers=headers(other)).json()["messages"]) == 2
    assert lab.client.delete('/v1/safety/blocks/'+owner['user']['id'],headers=headers(guest)).json()["blockedUsers"] == []
    assert lab.client.put('/v1/safety/blocks/'+guest['user']['id'],headers=headers(guest)).status_code == 422


def test_report_requires_real_observed_participation_and_server_owned_message_evidence(lab):
    room,(owner,guest),_ = setup_room(lab)
    outsider = login(lab,"未参与者")
    token(lab,room,outsider,online=False)
    report(lab,room,outsider,owner,status=403)
    report(lab,room,guest,owner,targetUserID=outsider["user"]["id"])
    message = lab.client.post(f'/v1/rooms/{room["id"]}/messages',headers=headers(owner),
        json={"clientMessageID":str(uuid.uuid4()),"text":"需要核实的真实文字"}).json()
    identifier = str(uuid.uuid4())
    first = report(lab,room,guest,owner,target_type="message",messageID=message["id"],clientRequestID=identifier)
    second = report(lab,room,guest,owner,target_type="message",messageID=message["id"],clientRequestID=identifier)
    assert first == second and first["targetUserID"] == owner["user"]["id"]
    report(lab,room,guest,owner,target_type="message",messageID=message["id"],targetUserID=outsider["user"]["id"],status=422)
    report(lab,room,guest,owner,target_type="message",messageID="invented",status=409)
    report(lab,room,guest,owner,target_type="message",messageID=message["id"],clientRequestID=identifier,details="改写重试",status=409)
    row = lab.app.state.db.execute("SELECT * FROM safety_reports WHERE id=?",(first["id"],)).fetchone()
    assert json.loads(row["evidence_json"])["message"]["text"] == "需要核实的真实文字"
    assert row["evidence_expires_at"]-row["created_at"] == REPORT_SECONDS
    assert len(lab.client.get("/v1/safety/reports/mine",headers=headers(guest)).json()["reports"]) == 2


def test_signed_query_exposes_bounded_evidence_and_rejects_replay_across_paths(community):
    room,(owner,guest),_ = setup_room(community)
    entry = report(community,room,guest,owner)
    with community.app.state.db:
        community.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?", ("kiki_000001", owner["user"]["id"]))
        community.app.state.db.execute("UPDATE users SET display_id=? WHERE id=?", ("kiki_000002", guest["user"]["id"]))
    payload = {"status":"pending","limit":50,"opsActorID":ACTOR}
    body = json.dumps(payload).encode()
    auth = signed(path=MODERATION_QUERY_PATH,body=body)
    result = community.client.post(MODERATION_QUERY_PATH,content=body,headers=auth)
    assert result.status_code == 200 and result.json()["reports"][0]["id"] == entry["id"]
    assert result.json()["reports"][0]["reporterName"] == guest["user"]["name"]
    assert result.json()["reports"][0]["reporterDisplayID"] == "kiki_000002"
    assert result.json()["reports"][0]["targetDisplayID"] == "kiki_000001"
    assert result.json()["reports"][0]["targetUserID"] == owner["user"]["id"]
    assert community.client.post(MODERATION_QUERY_PATH,content=body,headers=auth).status_code == 401
    # Re-signing a used nonce for a different fixed path still fails.
    assert community.client.post(DASHBOARD_PATH,content=b"{}",headers=signed(nonce=auth["X-Kiki-Ops-Nonce"])).status_code == 401
    assert community.client.post(MODERATION_QUERY_PATH,content=body+b" ",headers=signed(path=MODERATION_QUERY_PATH,body=body)).status_code == 401
    assert community.client.post(MODERATION_QUERY_PATH+"?limit=1",content=body,headers=signed(path=MODERATION_QUERY_PATH,body=body)).status_code == 401


def test_platform_mutes_change_real_media_grants_survive_room_unmute_and_restore(community):
    room,(owner,guest),tokens = setup_room(community)
    act(community,room,guest,"request_seat")
    act(community,room,owner,"approve_request",targetUserID=guest["user"]["id"])
    entry = report(community,room,owner,guest)
    moderate(community,entry,"mute_audio")
    assert community.rtc.permissions[(room["id"],guest["user"]["id"])]["audio"] is False
    assert (room["id"],guest["user"]["id"]) in community.rtc.muted
    assert state(community,room,guest)["me"]["audioMuted"] is True
    upstream = authorize(community,tokens[1]).authorization.upstream_token
    assert jwt.decode(upstream,community.settings.api_secret,algorithms=['HS256'])['video']['canPublish'] is False
    act(community,room,owner,"mute_audio",targetUserID=guest["user"]["id"],enabled=False)
    assert not state(community,room,guest)["me"]["canPublishAudio"]
    moderate(community,entry,"mute_chat")
    denied = community.client.post(f'/v1/rooms/{room["id"]}/messages',headers=headers(guest),json={"clientMessageID":str(uuid.uuid4()),"text":"不能绕过"})
    assert denied.status_code == 403 and denied.json()["code"] == "chat_muted"
    assert state(community,room,guest)["me"]["canPublishData"] is False
    moderate(community,entry,"restore_user")
    assert state(community,room,guest)["me"]["canPublishAudio"]
    assert state(community,room,guest)["me"]["canPublishData"]
    assert len(safety(community,guest)["notices"]) == 3


def test_mute_expiry_restores_platform_permissions_but_keeps_room_mute(community):
    room,(owner,guest),_ = setup_room(community)
    act(community,room,guest,"request_seat")
    act(community,room,owner,"approve_request",targetUserID=guest["user"]["id"])
    entry = report(community,room,owner,guest)
    moderate(community,entry,"mute_audio")
    act(community,room,owner,"mute_chat",targetUserID=guest["user"]["id"],enabled=True)
    with community.app.state.db:
        community.app.state.db.execute("UPDATE safety_restrictions SET voice_muted_until=?",(int(time.time())-1,))
    current = state(community,room,guest)["me"]
    assert current["canPublishAudio"] and not current["canPublishData"]
    assert safety(community,guest)["restrictions"]["voiceMutedUntil"] is None


def test_ban_ejects_existing_identity_blocks_old_grants_and_preserves_safety_access(community):
    room,(owner,guest),tokens = setup_room(community)
    entry = report(community,room,owner,guest)
    request_id = str(uuid.uuid4())
    first = moderate(community,entry,"ban_user",requestID=request_id)
    second = moderate(community,entry,"ban_user",requestID=request_id)
    assert first == second
    assert guest["user"]["id"] not in community.rtc.rooms[room["id"]]
    with pytest.raises(HTTPException):
        authorize(community,tokens[1])
    denied = community.client.post(f'/v1/rooms/{room["id"]}/token',headers=headers(guest))
    assert denied.status_code == 403 and denied.json()["code"] == "voice_banned"
    assert community.client.post('/v1/rooms',headers=headers(guest),json={"title":"绕过","category":"闲聊","theme":0,"isLive":False}).status_code == 403
    assert community.client.get('/v1/me',headers=headers(guest)).status_code == 200
    assert safety(community,guest)["restrictions"]["bannedUntil"] > time.time()
    assert community.client.get('/v1/safety/reports/mine',headers=headers(guest)).status_code == 200
    assert community.client.post('/v1/auth/logout',headers=headers(guest)).status_code == 200
    assert community.app.state.db.execute("SELECT COUNT(*) FROM safety_actions").fetchone()[0] == 1


def test_moderated_message_removed_but_bounded_report_evidence_remains(community):
    room,(owner,guest),_ = setup_room(community)
    message = community.client.post(f'/v1/rooms/{room["id"]}/messages',headers=headers(guest),json={"clientMessageID":str(uuid.uuid4()),"text":"违规待处理内容"}).json()
    entry = report(community,room,owner,guest,target_type="message",messageID=message["id"])
    moderate(community,entry,"warn")
    data = community.client.get(f'/v1/rooms/{room["id"]}/messages',headers=headers(owner)).json()
    assert data["messages"] == [] and data["historyRevision"] > 0
    assert community.app.state.db.execute("SELECT evidence_json FROM safety_reports WHERE id=?",(entry["id"],)).fetchone()


def test_close_room_is_durable_during_sfu_outage_and_cleanup_retries(community):
    room,(owner,guest),tokens = setup_room(community)
    entry = report(community,room,guest,owner,target_type="room")
    community.rtc.delete_failure = True
    response = moderate(community,entry,"close_room")
    assert response["mediaCleanupPending"]
    assert community.app.state.db.execute("SELECT status FROM rooms WHERE id=?",(room["id"],)).fetchone()[0] == "closing"
    with pytest.raises(HTTPException):
        authorize(community,tokens[0])
    community.rtc.delete_failure = False
    community.client.get('/v1/rooms',headers=headers(guest))
    assert room["id"] not in community.rtc.rooms


def test_content_filter_covers_title_category_chat_and_announcement_and_is_configurable(lab,tmp_path):
    owner = login(lab)
    bad = {"title":"加 微 信 刷 单","category":"闲聊","theme":0,"isLive":False}
    assert lab.client.post('/v1/rooms',headers=headers(owner),json=bad).status_code == 422
    room = create_room(lab,owner)
    token(lab,room,owner)
    for path,payload in ((f'/v1/rooms/{room["id"]}/messages',{"clientMessageID":str(uuid.uuid4()),"text":"加\u200b微信刷单"}),
                         (f'/v1/rooms/{room["id"]}/announcement',{"text":"代开赌博"})):
        response = lab.client.request("PUT" if path.endswith("announcement") else "POST",path,headers=headers(owner),json=payload)
        assert response.status_code == 422 and response.json()["code"] == "content_filtered"
    path = tmp_path/'terms.json'
    path.write_text(json.dumps({"blockedTerms":["ExamplePhrase"]}))
    store = SafetyStore.configured(lab.app.state.db,lab.app.state.safety.limiter,str(path))
    with pytest.raises(HTTPException):
        store.check_text("ｅｘａｍｐｌｅＰｈｒａｓｅ")
    path.write_text('{"blockedTerms":[""]}')
    with pytest.raises(RuntimeError):
        SafetyStore.configured(lab.app.state.db,store.limiter,str(path))


def test_safety_retention_erasure_and_audit_minimization(community):
    room,(owner,guest),_ = setup_room(community)
    entry = report(community,room,owner,guest)
    moderate(community,entry,"warn")
    community.client.put('/v1/safety/blocks/'+guest['user']['id'],headers=headers(owner))
    with community.app.state.db:
        community.app.state.safety.clear_user(guest['user']['id'])
    assert community.app.state.db.execute("SELECT COUNT(*) FROM safety_reports").fetchone()[0] == 0
    assert community.app.state.db.execute("SELECT COUNT(*) FROM safety_blocks").fetchone()[0] == 0
    audit = community.app.state.db.execute("SELECT * FROM safety_actions").fetchone()
    assert audit["target_user_id"] == audit["note"] == ""
    assert guest['user']['id'] not in audit["response_json"]
    with community.app.state.db:
        community.app.state.safety.prune(int(time.time())+AUDIT_SECONDS+1)
    assert community.app.state.db.execute("SELECT COUNT(*) FROM safety_actions").fetchone()[0] == 0


def test_activity_counts_observed_people_and_bounded_stay_not_admission_or_outage(lab):
    room,(owner,guest),_ = setup_room(lab)
    now = int(time.time())
    store = lab.app.state.safety
    with lab.app.state.db:
        store.forget_room(room['id'])
        store.observe(room['id'],{owner['user']['id']},now=now)
        store.observe(room['id'],{owner['user']['id']},now=now+5)
        store.observe(room['id'],{owner['user']['id']},now=now+100)
    data = store.metrics(now+100)
    assert data['onlineUsersNow'] == 1
    assert data['activeUsersToday'] == 2
    assert data['roomStaySecondsToday'] == 5
    assert data['micSeatJoinsToday'] == 1
    assert store.metrics(now+120)['onlineUsersNow'] is None


def test_reports_and_ban_persist_across_service_restart(community):
    room,(owner,guest),_ = setup_room(community)
    entry = report(community,room,owner,guest)
    moderate(community,entry,'ban_user')
    rtc = FakeLiveKit(community.settings)
    with TestClient(create_app(community.settings,rtc)) as client:
        assert client.get('/v1/safety',headers=headers(guest)).json()['restrictions']['bannedUntil'] > time.time()
        assert client.get('/v1/safety/reports/mine',headers=headers(owner)).json()['reports'][0]['id'] == entry['id']


def test_new_business_leases_inherit_ban_without_preventing_login_and_settings(account_service):
    first = exchange(account_service).json()
    now = int(time.time())
    with account_service.app.state.db:
        account_service.app.state.db.execute("INSERT INTO safety_restrictions(user_id,banned_until,reason) VALUES(?,?,?)",(first['user']['id'],now+300,'违规语聊'))
    # Same source lease renewal and a fresh source login remain available.
    assert exchange(account_service).status_code == 200
    fresh = exchange(account_service,auth='b'*64).json()
    assert account_service.client.get('/v1/me',headers=headers(fresh)).status_code == 200
    assert account_service.client.get('/v1/safety',headers=headers(fresh)).json()['restrictions']['bannedUntil'] == now+300
    denied = account_service.client.post('/v1/rooms',headers=headers(fresh),json={'title':'新房间','category':'闲聊','theme':0,'isLive':False})
    assert denied.status_code == 403 and denied.json()['code'] == 'voice_banned'


def test_account_bridge_withdrawal_erases_safety_but_logout_preserves_it(account_service):
    one = exchange(account_service).json()
    two = exchange(account_service,auth='b'*64,user=profile('其他用户','kiki_abcdef0123456789')).json()
    account_service.client.put('/v1/safety/blocks/'+two['user']['id'],headers=headers(one))
    assert bridge_signed(account_service,'revoke',{'authorizationID':bridge_payload(account_service)['authorizationID']}).status_code == 200
    assert account_service.app.state.db.execute('SELECT COUNT(*) FROM safety_blocks').fetchone()[0] == 1
    fresh = exchange(account_service,auth='c'*64).json()
    assert bridge_signed(account_service,'revoke',{'authorizationID':'c'*64,'reason':'withdrawal'}).status_code == 200
    assert account_service.app.state.db.execute('SELECT COUNT(*) FROM safety_blocks').fetchone()[0] == 0
    assert not account_service.app.state.db.execute('SELECT 1 FROM safety_activity_daily WHERE user_id=?',(one['user']['id'],)).fetchone()
    assert account_service.client.get('/v1/me',headers=headers(fresh)).status_code == 401


def test_platform_mute_does_not_disappear_when_media_update_fails(community):
    room,(owner,guest),tokens = setup_room(community)
    act(community,room,guest,'request_seat')
    act(community,room,owner,'approve_request',targetUserID=guest['user']['id'])
    entry = report(community,room,owner,guest)
    community.rtc.permission_failure = community.rtc.remove_failure = True
    result = moderate(community,entry,'mute_audio')
    assert result['mediaCleanupPending']
    assert community.app.state.db.execute('SELECT 1 FROM media_cleanup WHERE user_id=?',(guest['user']['id'],)).fetchone()
    connection = authorize(community,tokens[1])
    grants = jwt.decode(connection.authorization.upstream_token,community.settings.api_secret,algorithms=['HS256'])
    assert not grants['video']['canPublish']
    community.rtc.permission_failure = community.rtc.remove_failure = False
    state(community,room,owner)
    assert not community.app.state.db.execute('SELECT 1 FROM media_cleanup WHERE user_id=?',(guest['user']['id'],)).fetchone()
    assert community.rtc.permissions[(room['id'],guest['user']['id'])]['audio'] is False


def test_expired_report_evidence_is_removed_even_without_client_requests(lab):
    room,(owner,guest),_ = setup_room(lab)
    entry = report(lab,room,owner,guest)
    with lab.app.state.db:
        lab.app.state.safety.prune(int(time.time())+REPORT_SECONDS+1)
    assert not lab.app.state.db.execute('SELECT 1 FROM safety_reports WHERE id=?',(entry['id'],)).fetchone()


def test_report_daily_limit_survives_limiter_reset_and_retries_do_not_consume_it(lab):
    room,(owner,guest),_ = setup_room(lab)
    entry = report(lab,room,owner,guest)
    row = lab.app.state.db.execute('SELECT * FROM safety_reports WHERE id=?',(entry['id'],)).fetchone()
    with lab.app.state.db:
        for index in range(19):
            values = dict(row)
            values['id'] = 'report_'+str(index)
            values['client_request_id'] = str(uuid.uuid4())
            columns = ','.join(values)
            lab.app.state.db.execute('INSERT INTO safety_reports('+columns+') VALUES('+','.join('?' for _ in values)+')',tuple(values.values()))
    lab.app.state.safety.limiter.events.clear()
    report(lab,room,owner,guest,status=429)
    report(lab,room,owner,guest,clientRequestID=row['client_request_id'])
    assert lab.app.state.db.execute('SELECT COUNT(*) FROM safety_reports').fetchone()[0] == 20


def test_active_restriction_can_be_restored_after_source_evidence_expires(community):
    room,(owner,guest),_ = setup_room(community)
    entry = report(community,room,owner,guest)
    moderate(community,entry,'ban_user')
    with community.app.state.db:
        community.app.state.db.execute('UPDATE safety_reports SET evidence_expires_at=? WHERE id=?',(int(time.time())-1,entry['id']))
        community.app.state.safety.prune()
    payload = {'opsActorID':ACTOR,'status':'all','limit':50}
    body = json.dumps(payload).encode()
    result = community.client.post(MODERATION_QUERY_PATH,content=body,headers=signed(path=MODERATION_QUERY_PATH,body=body)).json()
    assert result['reports'] == []
    assert result['activeRestrictions'][0]['reportID'] == entry['id']
    assert set(result['activeRestrictions'][0]) == {'reportID','targetUserID','targetDisplayID','chatMutedUntil','voiceMutedUntil','bannedUntil'}
    moderate(community,entry,'restore_user')
    assert safety(community,guest)['restrictions']['bannedUntil'] is None


def test_activity_retention_is_exactly_35_shanghai_calendar_dates(lab):
    account = login(lab)
    now = int(time.time())
    today = datetime.fromtimestamp(now,ZoneInfo('Asia/Shanghai')).date()
    with lab.app.state.db:
        for ago in (34,35):
            lab.app.state.db.execute('INSERT INTO safety_activity_daily(day,user_id,first_seen) VALUES(?,?,?)',((today-timedelta(days=ago)).isoformat(),account['user']['id'],now-ago*86400))
        lab.app.state.safety.prune(now)
    days = {r[0] for r in lab.app.state.db.execute('SELECT day FROM safety_activity_daily')}
    assert (today-timedelta(days=34)).isoformat() in days
    assert (today-timedelta(days=35)).isoformat() not in days


def test_reconsent_beating_delayed_withdrawal_erases_old_data_and_preserves_new_epoch(account_service):
    service = account_service
    initial = bridge_payload(service)
    initial.update(consentEpoch=10,lastWithdrawalEpoch=0)
    old = bridge_signed(service,'session',initial).json()
    peer_body = bridge_payload(service,auth='b'*64,user=profile('朋友','kiki_abcdef0123456789'))
    peer_body.update(consentEpoch=11,lastWithdrawalEpoch=0)
    peer = bridge_signed(service,'session',peer_body).json()
    service.client.put('/v1/safety/blocks/'+peer['user']['id'],headers=headers(old))
    assert service.app.state.db.execute('SELECT COUNT(*) FROM safety_blocks').fetchone()[0] == 1
    # A fresh Apple session re-accepts before the queued old withdrawal arrives.
    fresh_body = bridge_payload(service,auth='c'*64)
    fresh_body.update(consentEpoch=13,lastWithdrawalEpoch=12)
    response = bridge_signed(service,'session',fresh_body)
    assert response.status_code == 200,response.text
    fresh = response.json()
    assert service.app.state.db.execute('SELECT COUNT(*) FROM safety_blocks').fetchone()[0] == 0
    assert service.client.get('/v1/me',headers=headers(old)).status_code == 401
    assert service.client.put('/v1/safety/blocks/'+peer['user']['id'],headers=headers(fresh)).status_code == 200
    delayed = {'authorizationID':initial['authorizationID'],'reason':'withdrawal','consentEpoch':12}
    assert bridge_signed(service,'revoke',delayed).status_code == 200
    assert service.client.get('/v1/me',headers=headers(fresh)).status_code == 200
    assert len(service.client.get('/v1/safety',headers=headers(fresh)).json()['blockedUsers']) == 1
    consent = service.app.state.db.execute('SELECT withdrawn_at FROM consents WHERE user_id=?',(fresh['user']['id'],)).fetchone()
    assert consent['withdrawn_at'] is None
    # A stale exchange cannot roll back the accepted privacy generation.
    assert bridge_signed(service,'session',initial).status_code == 409


def test_epoch_withdrawal_revokes_all_old_sources_without_touching_later_reconsent(account_service):
    service = account_service
    first = bridge_payload(service)
    first.update(consentEpoch=10,lastWithdrawalEpoch=0)
    account = bridge_signed(service,'session',first).json()
    another_body = bridge_payload(service,auth='b'*64)
    another_body.update(consentEpoch=10,lastWithdrawalEpoch=0)
    another = bridge_signed(service,'session',another_body).json()
    event = {'authorizationID':first['authorizationID'],'reason':'withdrawal','consentEpoch':11}
    assert bridge_signed(service,'revoke',event).status_code == 200
    assert service.client.get('/v1/me',headers=headers(another)).status_code == 401
    fresh_body = bridge_payload(service,auth='c'*64)
    fresh_body.update(consentEpoch=12,lastWithdrawalEpoch=11)
    fresh = bridge_signed(service,'session',fresh_body).json()
    assert service.client.get('/v1/me',headers=headers(fresh)).status_code == 200
    assert bridge_signed(service,'revoke',event).status_code == 200
    assert service.client.get('/v1/me',headers=headers(fresh)).status_code == 200


def test_backup_receipt_requires_fresh_verified_voice_snapshot_and_redacts_errors(tmp_path,monkeypatch):
    receipt = tmp_path/'backup-status.json'
    monkeypatch.setattr(admin,'Path',lambda value: receipt if str(value)=='/var/lib/kiki-livekit-lab/backup-status.json' else Path(value))
    now = int(time.time())
    assert admin.backup_snapshot(now)['healthy'] is None
    valid = {'service':'voice','lastSuccessAt':now-60,'verifiedAt':now-60,'lastError':None}
    receipt.write_text(json.dumps(valid))
    assert admin.backup_snapshot(now)['healthy'] is True
    receipt.write_text(json.dumps({**valid,'verifiedAt':now-120}))
    assert admin.backup_snapshot(now)['healthy'] is False
    receipt.write_text(json.dumps({**valid,'lastSuccessAt':now-37*3600}))
    assert admin.backup_snapshot(now)['healthy'] is False
    receipt.write_text(json.dumps({**valid,'lastError':'secret/database/path-or-credential'}))
    failed = admin.backup_snapshot(now)
    assert failed['healthy'] is False and 'secret' not in failed['lastError']
    receipt.write_text(json.dumps({**valid,'service':'account'}))
    assert admin.backup_snapshot(now)['healthy'] is False


def test_pending_queue_returns_oldest_cases_first_so_new_reports_cannot_starve_them(lab):
    room,(owner,guest),_ = setup_room(lab)
    first = report(lab,room,owner,guest)
    second = report(lab,room,guest,owner)
    with lab.app.state.db:
        lab.app.state.db.execute('UPDATE safety_reports SET created_at=created_at-20 WHERE id=?',(first['id'],))
    from app.safety import ModerationQuery
    pending = lab.app.state.safety.query(ModerationQuery(status='pending',limit=1,opsActorID=ACTOR))
    latest = lab.app.state.safety.query(ModerationQuery(status='all',limit=1,opsActorID=ACTOR))
    assert pending['reports'][0]['id'] == first['id']
    assert latest['reports'][0]['id'] == second['id']
    assert pending['activeRestrictionsTruncated'] is False and pending['activeRestrictionsLimit'] == 5000
