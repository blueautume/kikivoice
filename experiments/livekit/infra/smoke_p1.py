#!/usr/bin/env python3
"""Opt-in P1 acceptance with four RTC clients and five disposable lab users.

Requires livekit==1.1.21 and httpx==0.28.1; uses no physical microphone.
--restart-api also tests API process recovery, never restarts the media service.
No invite codes, JWTs, signalling payloads or personal data are printed.
"""
import argparse
import asyncio
import base64
import json
import logging
import os
from pathlib import Path
import ssl
import subprocess
import uuid

import httpx
from livekit import rtc

BASE = Path(__file__).resolve().parents[1]
URL = "https://furby.top"


def claims(token):
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


async def wait_for(predicate, seconds=30):
    async with asyncio.timeout(seconds):
        while not predicate():
            await asyncio.sleep(.1)


async def main(restart_api=False):
    logging.getLogger("livekit").setLevel(logging.CRITICAL)
    code = (Path.home()/".config/kikitalk-livekit-lab/lab-access-code").read_text().strip()
    legal = json.loads((BASE/"shared/legal_documents.json").read_text())
    consent = {key: legal[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    consent.update(accepted=True, adultConfirmed=True)
    context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE"))
    accounts, clients, rooms, grants = [], [], [], []
    deleted = set()
    refreshed = [False]*4
    reconnected = [0]*4
    hints = [0]*4
    results = {"server": URL, "participants": 4, "mediaRooms": 2, "relayOnly": True}

    async with httpx.AsyncClient(base_url=URL, verify=context, trust_env=False, timeout=35) as http:
        async def call(method, path, actor=None, expect=200, **kwargs):
            headers = {"Authorization": "Bearer "+accounts[actor]["token"]} if actor is not None else {}
            response = await http.request(method, path, headers=headers, **kwargs)
            if response.status_code != expect:
                raise AssertionError(f"{method} {path.rsplit('/',1)[-1]} expected {expect}, received {response.status_code}")
            return response.json()

        async def action(actor, kind, target=None, **values):
            body = {"action": kind, **values}
            if target is not None: body["targetUserID"] = accounts[target]["user"]["id"]
            return await call("POST", f"/v1/rooms/{rooms[actor//2]}/actions", actor, json=body)

        async def post(actor, text, nonce=None, expect=200):
            return await call("POST", f"/v1/rooms/{rooms[actor//2]}/messages", actor, expect,
                              json={"clientMessageID": nonce or str(uuid.uuid4()), "text": text})

        async def connect(index, grant=None):
            room = rtc.Room()
            @room.on("token_refreshed")
            def on_token(): refreshed[index] = True
            @room.on("reconnected")
            def on_resume(): reconnected[index] += 1
            @room.on("data_received")
            def on_hint(packet):
                if packet.topic == "kiki.chat.sync": hints[index] += 1
            config = rtc.RtcConfiguration(ice_transport_type=rtc.IceTransportType.TRANSPORT_RELAY)
            grant = grant or grants[index]
            clients.append(room)
            await asyncio.wait_for(room.connect(grant["serverURL"], grant["participantToken"],
                rtc.RoomOptions(single_peer_connection=False, rtc_config=config)), 30)
            return room

        try:
            # Four RTC clients plus one account that owns no room, used to test
            # the global room limit independently of the one-room-per-owner rule.
            for index in range(5):
                accounts.append(await call("POST", "/v1/auth/lab", json={
                    "name": "P1验收"+uuid.uuid4().hex[:5], "accessCode": code, "legalConsent": consent}))
            for index in (0, 2):
                room = await call("POST", "/v1/rooms", index, json={
                    "title": "P1并行房间验收", "category": "闲聊", "isLive": False, "theme": 0})
                rooms.append(room["id"])
            rtc_rooms = []
            for index in range(4):
                grants.append(await call("POST", f"/v1/rooms/{rooms[index//2]}/token", index))
                rtc_rooms.append(await connect(index))
            await wait_for(lambda: all(len(room.remote_participants)==1 for room in rtc_rooms))
            results["twoIsolatedRooms"] = True
            await call("GET", f"/v1/rooms/{rooms[0]}/messages", 2, 403)

            nonce = str(uuid.uuid4())
            first = await post(0, "HTTP确认消息", nonce)
            duplicate = await post(0, "HTTP确认消息", nonce)
            assert first["id"] == duplicate["id"] and first["seq"] == duplicate["seq"]
            await post(0, "改变正文不能复用ID", nonce, 409)
            assert first["senderUserID"] == accounts[0]["user"]["id"]
            history = await call("GET", f"/v1/rooms/{rooms[0]}/messages?afterSeq=0", 1)
            assert [message["id"] for message in history["messages"]] == [first["id"]]
            await wait_for(lambda: hints[1]>0)
            results["serverAcknowledgementIdempotencyAndHistory"] = True
            results["crossRoomHistoryDenied"] = True

            await call("PUT", f"/v1/rooms/{rooms[0]}/announcement", 0, json={"text": "实验房公告"})
            await call("PUT", f"/v1/rooms/{rooms[0]}/announcement", 1, 403, json={"text": "越权公告"})
            history = await call("GET", f"/v1/rooms/{rooms[0]}/messages", 1)
            assert history["announcement"]["text"] == "实验房公告"
            await action(0, "mute_chat", 1, enabled=True)
            await post(1, "禁言不能发送", expect=403)
            await call("GET", f"/v1/rooms/{rooms[0]}/messages", 1)
            await action(0, "mute_chat", 1, enabled=False)
            results["announcementAndChatModeration"] = True

            report = {"quality": "good", "rttMs": 123, "jitterMs": 4, "packetLossPercent": 0.5}
            one = await call("POST", f"/v1/rooms/{rooms[0]}/quality", 0, 202, json=report)
            two = await call("POST", f"/v1/rooms/{rooms[0]}/quality", 0, 202, json=report)
            assert one["accepted"] and not two["accepted"]
            await call("POST", f"/v1/rooms/{rooms[0]}/quality", 0, 422,
                       json={"quality": "good", "rttMs": -1})
            diagnostics = await call("GET", "/v1/diagnostics", 0)
            assert diagnostics["quality"]["samples"] >= 1
            assert diagnostics["capacity"]["activeRooms"] == 2
            assert diagnostics["capacity"]["maxRooms"] == 4
            results["boundedQualityDiagnosticsAndThrottling"] = True
            results["syntheticQualitySamples"] = True

            extra_rooms = []
            for actor in (1, 3):
                extra_rooms.append((actor, (await call("POST", "/v1/rooms", actor, json={
                    "title": "P1容量保护临时房", "category": "闲聊", "isLive": False, "theme": 0}))["id"]))
            await call("POST", "/v1/rooms", 4, 429, json={
                "title": "不可超出实验容量", "category": "闲聊", "isLive": False, "theme": 0})
            for actor, room_id in extra_rooms:
                await call("PATCH", f"/v1/rooms/{room_id}", actor, json={"status": "ended"})
            results["roomCapacityGuardPreservesExistingRooms"] = True

            await action(1, "request_seat")
            await action(0, "approve_request", 1)
            await wait_for(lambda: rtc_rooms[1].local_participant.permissions.can_publish)
            old_speaker = await call("POST", f"/v1/rooms/{rooms[0]}/token", 1)
            cursor = history["nextAfterSeq"]
            await rtc_rooms[1].disconnect()
            await post(0, "离线期间消息一")
            await post(0, "离线期间消息二")
            await action(0, "mute_audio", 1, enabled=True)
            print(json.dumps({"phase": "offline-grace-test", "seconds": 21}), flush=True)
            await asyncio.sleep(21)
            state = await call("GET", f"/v1/rooms/{rooms[0]}/state", 1)
            assert state["me"]["seatIndex"] is not None and not state["me"]["canPublishAudio"]
            rtc_rooms[1] = await connect(1, old_speaker)
            assert not rtc_rooms[1].local_participant.permissions.can_publish
            recovered = await call("GET", f"/v1/rooms/{rooms[0]}/messages?afterSeq={cursor}", 1)
            assert [message["text"] for message in recovered["messages"]] == ["离线期间消息一", "离线期间消息二"]
            results["offlineBeyondFormerGraceKeepsSeatAndRestoresMessages"] = True
            results["offlineMuteSurvivesOldSpeakerTokenReconnect"] = True

            await wait_for(lambda: all(refreshed), 30)
            for index, room in enumerate(rtc_rooms):
                refreshed_claims = claims(room._token)
                original_claims = claims(grants[index]["participantToken"])
                assert json.loads(refreshed_claims["metadata"])["server"] == json.loads(original_claims["metadata"])["server"]
                assert refreshed_claims["exp"] > original_claims["exp"]
            results["serverRefreshedTokenPreservesSessionBinding"] = True

            if restart_api:
                before = reconnected.copy()
                # Exact pinned experiment alias, never the existing production alias.
                process = await asyncio.create_subprocess_exec("ssh", "-F", str(BASE/"infra/ssh_config"),
                    "furby-livekit-lab", "systemctl restart livekit-lab-api",
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                assert await asyncio.wait_for(process.wait(), 45) == 0
                await wait_for(lambda: all(room.isconnected() for room in rtc_rooms)
                               and all(reconnected[i]>before[i] for i in range(4)), 60)
                for index in range(4):
                    await call("GET", f"/v1/rooms/{rooms[index//2]}/state", index)
                assert not rtc_rooms[1].local_participant.permissions.can_publish
                results["apiRestartRestoresFourSDKConnectionsWithoutMediaRestart"] = True

            erased = await post(3, "注销后删除的测试正文")
            prior = await call("GET", f"/v1/rooms/{rooms[1]}/messages", 2)
            await call("DELETE", "/v1/account", 3)
            deleted.add(3)
            after = await call("GET", f"/v1/rooms/{rooms[1]}/messages", 2)
            assert erased["id"] not in {message["id"] for message in after["messages"]}
            assert after["historyRevision"] > prior["historyRevision"]
            results["authorDeletionRemovesBodyAndInvalidatesHistoryWindow"] = True
            for index in (0,2):
                await call("PATCH", f"/v1/rooms/{rooms[index//2]}", index, json={"status": "ended"})
            await wait_for(lambda: all(not room.isconnected() for room in rtc_rooms))
            print(json.dumps(results, ensure_ascii=False), flush=True)
        finally:
            for room in clients:
                try: await asyncio.wait_for(room.disconnect(), 10)
                except Exception: pass
            for index in range(len(accounts)):
                if index not in deleted:
                    try: await call("DELETE", "/v1/account", index)
                    except Exception: pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restart-api", action="store_true")
    asyncio.run(main(parser.parse_args().restart_api))
