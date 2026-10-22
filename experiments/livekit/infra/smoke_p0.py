#!/usr/bin/env python3
"""Opt-in nine-client P0 acceptance against the isolated furby.top lab.

Uses livekit==1.1.21, aiohttp and httpx==0.28.1. No physical microphone,
private credentials, participant tokens, SDP or IP candidates are printed.
Creates temporary accounts, closes its room and deletes usable accounts.
The logged-out fixture requires operator cleanup from the ID-only manifest
/tmp/kiki-p0-created-accounts.json because revoked credentials cannot delete.
"""
import asyncio
import json
import logging
import os
from pathlib import Path
import ssl
import uuid

import aiohttp
import httpx
from livekit import rtc

BASE = Path(__file__).resolve().parents[1]
URL = "https://furby.top"


async def until(predicate, timeout=12):
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.1)


async def main():
    logging.getLogger("livekit").setLevel(logging.CRITICAL)
    invitation = (Path.home() / ".config/kikitalk-livekit-lab/lab-access-code").read_text().strip()
    manifest = json.loads((BASE / "shared/legal_documents.json").read_text())
    consent = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    consent.update(accepted=True, adultConfirmed=True)
    context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE"))
    accounts, clients, grants = [], [], []
    removed_accounts = set()
    logged_out = set()
    room_id = None
    results = {}
    run_id = uuid.uuid4().hex[:6]
    cleanup_path = Path("/tmp/kiki-p0-created-accounts.json")

    async with httpx.AsyncClient(base_url=URL, verify=context, timeout=35, trust_env=False) as http:
        async def request(method, path, actor=None, expect=200, **kwargs):
            headers = {"Authorization": "Bearer " + accounts[actor]["token"]} if actor is not None else {}
            response = await http.request(method, path, headers=headers, **kwargs)
            if response.status_code != expect:
                raise AssertionError(f"{method} {path.rsplit('/', 1)[-1]}: expected {expect}, received {response.status_code}")
            return response.json() if response.content else None

        async def state(actor=0):
            return await request("GET", f"/v1/rooms/{room_id}/state", actor)

        async def action(actor, kind, expect=200, **values):
            return await request("POST", f"/v1/rooms/{room_id}/actions", actor,
                                 expect, json={"action": kind, **values})

        def user(index):
            return accounts[index]["user"]["id"]

        async def connect(index, grant=None):
            room = rtc.Room()
            clients.append(room)
            grant = grant or grants[index]
            config = rtc.RtcConfiguration(ice_transport_type=rtc.IceTransportType.TRANSPORT_RELAY)
            await asyncio.wait_for(room.connect(grant["serverURL"], grant["participantToken"],
                rtc.RoomOptions(single_peer_connection=False, rtc_config=config)), 30)
            return room

        async def denied(token):
            # Both legacy and v1 SDK validation and WebSocket entry points must
            # reject old credentials before any LiveKit handshake.
            async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
                for path in ("/rtc/validate", "/rtc/v1/validate"):
                    async with session.get(URL+path, headers={"Authorization": "Bearer "+token}) as response:
                        assert response.status in (401, 403, 409), f"old credential accepted at {path}"
                for path in ("/rtc", "/rtc/v1"):
                    try:
                        websocket = await session.ws_connect(URL+path,
                            headers={"Authorization": "Bearer "+token}, timeout=aiohttp.ClientWSTimeout(ws_close=2))
                    except aiohttp.WSServerHandshakeError as error:
                        assert error.status in (401, 403, 409)
                    else:
                        await websocket.close()
                        raise AssertionError(f"old credential accepted at {path}")

        try:
            assert (await request("GET", "/health"))["rtcConfigured"]
            for index in range(9):
                accounts.append(await request("POST", "/v1/auth/lab", json={
                    "name": f"P0验收{run_id}-{index+1}", "accessCode": invitation, "legalConsent": consent}))
                cleanup_path.write_text(json.dumps([account["user"]["id"] for account in accounts]))
                cleanup_path.chmod(0o600)
            metadata = await request("POST", "/v1/rooms", 0, json={
                "title": "P0九端八麦验收", "category": "闲聊", "isLive": False, "theme": 0})
            room_id = metadata["id"]
            rooms = []
            for index in range(9):
                grants.append(await request("POST", f"/v1/rooms/{room_id}/token", index))
                rooms.append(await connect(index))
                print(json.dumps({"phase": "connected", "participants": index+1}), flush=True)
            await until(lambda: all(len(room.remote_participants) == 8 for room in rooms))
            current = await state()
            assert len(current["seats"]) == 8 and current["room"]["audience"] == 9
            assert sum(member["canPublishAudio"] for member in current["members"]) == 1
            assert all(not room.local_participant.permissions.can_publish for room in rooms[1:])
            results["nineRealParticipantsWithEightSeats"] = True
            results["listenersCannotPublishAudio"] = True

            for index in range(1, 9):
                await action(index, "request_seat")
            current = await state()
            assert [row["userID"] for row in current["queue"]] == [user(index) for index in range(1, 9)]
            for index in range(1, 8):
                await action(0, "approve_request", targetUserID=user(index))
            await action(0, "approve_request", targetUserID=user(8), expect=409)
            current = await state()
            assert sum(member["canPublishAudio"] for member in current["members"]) == 8
            results["orderedQueueAndEightSpeakerLimit"] = True

            await action(7, "leave_seat")
            await action(7, "request_seat")
            # Two simultaneous approvals contend for precisely one empty seat.
            responses = await asyncio.gather(*(
                http.post(f"/v1/rooms/{room_id}/actions", headers={"Authorization": "Bearer "+accounts[0]["token"]},
                          json={"action": "approve_request", "targetUserID": user(index)}) for index in (7, 8)))
            assert sorted(response.status_code for response in responses) == [200, 409]
            current = await state()
            occupied = [seat["userID"] for seat in current["seats"] if seat["userID"]]
            assert len(occupied) == len(set(occupied)) == 8
            results["concurrentApprovalHasOneWinner"] = True
            print(json.dumps({"phase": "eight-seats-and-concurrency-passed"}), flush=True)

            await action(0, "set_admin", targetUserID=user(1), enabled=True)
            await action(1, "mute_audio", targetUserID=user(0), enabled=True, expect=403)
            await action(1, "set_admin", targetUserID=user(2), enabled=True, expect=403)
            await request("PATCH", f"/v1/rooms/{room_id}", 1, 403, json={"status": "ended"})
            results["administratorHierarchyEnforced"] = True

            # Keep a token carrying real speaker grants, then revoke its rights.
            speaker_grant = await request("POST", f"/v1/rooms/{room_id}/token", 2)
            await action(1, "mute_audio", targetUserID=user(2), enabled=True)
            await action(1, "mute_chat", targetUserID=user(2), enabled=True)
            await until(lambda: not rooms[2].local_participant.permissions.can_publish
                        and not rooms[2].local_participant.permissions.can_publish_data)
            await rooms[2].disconnect()
            rooms[2] = await connect(2, speaker_grant)
            assert not rooms[2].local_participant.permissions.can_publish
            assert not rooms[2].local_participant.permissions.can_publish_data
            forbidden_data = asyncio.Event()
            @rooms[1].on("data_received")
            def forbidden_packet(packet):
                if packet.topic == "kiki.p0.denied" and packet.participant.identity == user(2):
                    forbidden_data.set()
            try:
                await asyncio.wait_for(rooms[2].local_participant.publish_data(
                    b"server-must-drop-muted-chat", reliable=True, topic="kiki.p0.denied"), 4)
            except Exception:
                pass
            await asyncio.sleep(1)
            assert not forbidden_data.is_set()
            results["audioAndChatRevocationRewritesOldSpeakerToken"] = True
            print(json.dumps({"phase": "old-speaker-token-downgraded"}), flush=True)
            await action(1, "mute_audio", targetUserID=user(2), enabled=False)
            await action(1, "mute_chat", targetUserID=user(2), enabled=False)
            await until(lambda: rooms[2].local_participant.permissions.can_publish
                        and rooms[2].local_participant.permissions.can_publish_data)
            assert not rooms[2].local_participant.track_publications
            results["unmuteDoesNotStartMicrophone"] = True

            await action(2, "leave_seat")
            await action(0, "lock_seat", seatIndex=3, enabled=True)
            await action(0, "invite_seat", targetUserID=user(2), seatIndex=3, expect=409)
            await action(0, "lock_seat", seatIndex=3, enabled=False)
            await action(1, "invite_seat", targetUserID=user(2), seatIndex=3)
            await action(2, "accept_invite")
            await action(0, "lock_audio", seatIndex=3, enabled=True)
            await until(lambda: not rooms[2].local_participant.permissions.can_publish)
            await action(0, "lock_audio", seatIndex=3, enabled=False)
            await until(lambda: rooms[2].local_participant.permissions.can_publish)
            results["seatLocksAudioLocksAndAcceptedInvitation"] = True

            await action(1, "kick", targetUserID=user(3))
            await until(lambda: not rooms[3].isconnected())
            await denied(grants[3]["participantToken"])
            await request("POST", f"/v1/rooms/{room_id}/token", 3, 403)
            assert all(room.isconnected() for index, room in enumerate(rooms) if index != 3)
            await action(1, "unban", targetUserID=user(3))
            grants[3] = await request("POST", f"/v1/rooms/{room_id}/token", 3)
            rooms[3] = await connect(3)
            assert not rooms[3].local_participant.permissions.can_publish
            results["kickRevokesOldTokensAndUnbanAllowsFreshAdmission"] = True
            print(json.dumps({"phase": "kick-and-unban-passed"}), flush=True)

            await request("POST", "/v1/auth/logout", 4)
            logged_out.add(4)
            await until(lambda: not rooms[4].isconnected())
            await denied(grants[4]["participantToken"])
            assert all(room.isconnected() for index, room in enumerate(rooms) if index != 4)
            current = await state()
            assert current["room"]["audience"] == 8
            results["oneUserLogoutPreservesOtherEightConnections"] = True
            print(json.dumps({"phase": "single-user-logout-passed"}), flush=True)

            await request("DELETE", "/v1/account", 0)
            removed_accounts.add(0)
            await until(lambda: not rooms[0].isconnected())
            await denied(grants[0]["participantToken"])
            current = await state(1)
            assert current["room"]["hostID"] == user(1) and current["me"]["role"] == "owner"
            assert all(room.isconnected() for index, room in enumerate(rooms) if index not in (0, 4))
            results["ownerDeletionTransfersToOnlineAdministrator"] = True
            await request("PATCH", f"/v1/rooms/{room_id}", 1, json={"status": "ended"})
            await until(lambda: all(not room.isconnected() for room in rooms))
            results["explicitNewOwnerEndDisconnectsRemainingMembers"] = True
            results.update(participants=9, speakingSeats=8, relayOnly=True, server=URL)
            print(json.dumps(results, ensure_ascii=False))
        finally:
            for room in clients:
                await room.disconnect()
            # A revoked logout credential can only retry logout, so deleting that
            # test identity is done in a separate authorized server cleanup step.
            for index in range(len(accounts)):
                if index in removed_accounts or index in logged_out:
                    continue
                try:
                    await request("DELETE", "/v1/account", index)
                except Exception:
                    pass


if __name__ == "__main__":
    asyncio.run(main())
