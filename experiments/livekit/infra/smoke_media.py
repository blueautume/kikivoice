#!/usr/bin/env python3
"""Opt-in public end-to-end check using two disposable lab identities.

Uses livekit==1.1.21 and httpx==0.28.1. Publishes generated test tones, never
records a physical microphone. No invitation code, bearer or JWT is printed.
"""
import array
import argparse
import asyncio
import json
import logging
import math
import os
from pathlib import Path
import ssl
import uuid

import httpx
from livekit import rtc

BASE = Path(__file__).resolve().parents[1]
URL = "https://furby.top"


async def main(relay_only=False):
    logging.getLogger("livekit").setLevel(logging.ERROR)
    invitation = (Path.home() / ".config/kikitalk-livekit-lab/lab-access-code").read_text().strip()
    manifest = json.loads((BASE / "shared/legal_documents.json").read_text())
    consent = {key: manifest[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
    consent.update(accepted=True, adultConfirmed=True)
    context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE"))
    accounts, rooms, audio_sources, collectors = [], [], [], []
    room_id = None
    stats = {"audioFrames": [0, 0], "nonzeroFrames": [0, 0], "chatReceived": [False, False], "chatSyncHints": [0, 0]}

    async with httpx.AsyncClient(base_url=URL, verify=context, timeout=15, trust_env=False) as http:
        async def call(method, path, account=None, **kwargs):
            headers = {"Authorization": "Bearer " + account["token"]} if account else {}
            response = await http.request(method, path, headers=headers, **kwargs)
            if not response.is_success:
                raise RuntimeError(f"{method} {path} failed with HTTP {response.status_code}")
            return response.json()

        try:
            health = await call("GET", "/health")
            assert health["rtcConfigured"] is True
            for name in ("传输验证甲", "传输验证乙"):
                accounts.append(await call("POST", "/v1/auth/lab", json={
                    "name": name, "accessCode": invitation, "legalConsent": consent}))
            metadata = await call("POST", "/v1/rooms", accounts[0], json={
                "title": "自动验证语聊房", "category": "闲聊", "isLive": False, "theme": 0})
            room_id = metadata["id"]
            grants = [await call("POST", f"/v1/rooms/{room_id}/token", account) for account in accounts]
            for path in ("/rtc/validate", "/rtc/v1/validate"):
                denied_publish = await http.get(path, params={"publish": "untracked-identity"},
                    headers={"Authorization": "Bearer " + grants[0]["participantToken"]})
                assert denied_publish.status_code == 403
            stats["alternatePublisherIdentityBlocked"] = True
            disconnected = [asyncio.Event(), asyncio.Event()]
            enough_audio = [asyncio.Event(), asyncio.Event()]
            subscribed = [asyncio.Event(), asyncio.Event()]

            async def receive_audio(track, index):
                stream = rtc.AudioStream(track, sample_rate=48000, num_channels=1)
                try:
                    async for event in stream:
                        stats["audioFrames"][index] += 1
                        data = event.frame.data
                        rms = math.sqrt(sum(int(value) ** 2 for value in data) / max(1, len(data)))
                        if rms > 100:
                            stats["nonzeroFrames"][index] += 1
                        if stats["nonzeroFrames"][index] >= 50:
                            enough_audio[index].set()
                finally:
                    await stream.aclose()

            def attach(room, index):
                @room.on("track_subscribed")
                def on_track(track, _publication, participant):
                    if track.kind == rtc.TrackKind.KIND_AUDIO:
                        assert participant.identity == accounts[1-index]["user"]["sdkUserID"]
                        collectors.append(asyncio.create_task(receive_audio(track, index)))
                        subscribed[index].set()

                @room.on("data_received")
                def on_data(packet):
                    if packet.topic == "kiki.chat.sync":
                        # The packet is only an invalidation hint. Content and
                        # authenticated sender always come from the business API.
                        stats["chatSyncHints"][index] += 1

                @room.on("disconnected")
                def on_disconnect(_reason):
                    disconnected[index].set()

            for index, grant in enumerate(grants):
                room = rtc.Room()
                attach(room, index)
                rooms.append(room)
                config = rtc.RtcConfiguration(ice_transport_type=rtc.IceTransportType.TRANSPORT_RELAY) if relay_only else None
                await asyncio.wait_for(room.connect(grant["serverURL"], grant["participantToken"],
                    rtc.RoomOptions(single_peer_connection=False, rtc_config=config)), 25)
            for _ in range(50):
                if all(len(room.remote_participants) == 1 for room in rooms):
                    break
                await asyncio.sleep(0.1)
            assert all(len(room.remote_participants) == 1 for room in rooms)
            # New entrants are listeners. Acquire a server-approved seat first.
            await call("POST", f"/v1/rooms/{room_id}/actions", accounts[1],
                       json={"action": "request_seat"})
            state = await call("POST", f"/v1/rooms/{room_id}/actions", accounts[0],
                               json={"action": "approve_request", "targetUserID": accounts[1]["user"]["id"]})
            assert next(member for member in state["members"] if member["userID"] == accounts[1]["user"]["id"])["canPublishAudio"]
            # Wait for the RTC permission update to arrive before publishing.
            for _ in range(100):
                if rooms[1].local_participant.permissions.can_publish:
                    break
                await asyncio.sleep(.1)
            assert rooms[1].local_participant.permissions.can_publish

            async def publish_track(index):
                source = rtc.AudioSource(48000, 1)
                audio_sources.append(source)
                track = rtc.LocalAudioTrack.create_audio_track("generated-validation-tone", source)
                options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
                await rooms[index].local_participant.publish_track(track, options)
                return source

            sources = await asyncio.wait_for(asyncio.gather(publish_track(0), publish_track(1)), 20)
            await asyncio.wait_for(asyncio.gather(*(event.wait() for event in subscribed)), 15)

            async def publish_tone(index):
                source = sources[index]
                frequency = 440 if index == 0 else 660
                # A former listener may negotiate its publisher ICE connection
                # only now. Keep feeding until actual remote audio is observed.
                for frame_number in range(600):
                    samples = array.array("h", (int(8000 * math.sin(2*math.pi*frequency*(frame_number*960+n)/48000)) for n in range(960)))
                    await source.capture_frame(rtc.AudioFrame(samples.tobytes(), 48000, 1, 960))
                    if enough_audio[1-index].is_set():
                        break
                await source.wait_for_playout()

            await asyncio.wait_for(asyncio.gather(publish_tone(0), publish_tone(1)), 20)
            await asyncio.wait_for(asyncio.gather(*(event.wait() for event in enough_audio)), 15)
            for index, room in enumerate(rooms):
                message = await call("POST", f"/v1/rooms/{room_id}/messages", accounts[index], json={
                    "clientMessageID": str(uuid.uuid4()), "text": f"message-from-{index}"})
                assert message["senderUserID"] == accounts[index]["user"]["id"]
            for index in range(2):
                history = await call("GET", f"/v1/rooms/{room_id}/messages", accounts[index])
                stats["chatReceived"][index] = any(message["text"] == f"message-from-{1-index}"
                    and message["senderUserID"] == accounts[1-index]["user"]["id"] for message in history["messages"])
            assert all(stats["chatReceived"])
            stats["serverAcknowledgedChat"] = True
            listing = await call("GET", "/v1/rooms", accounts[1])
            assert next(room for room in listing["rooms"] if room["id"] == room_id)["audience"] == 2
            # Record only transport enums, never candidate IPs, credentials or SDP.
            selected = []
            for room in rooms:
                report = await room.get_rtc_stats()
                records = list(report.publisher_stats) + list(report.subscriber_stats)
                candidates = {record.local_candidate.rtc.id: record.local_candidate.candidate
                              for record in records if record.HasField("local_candidate")}
                transports = []
                for record in records:
                    if not record.HasField("candidate_pair"):
                        continue
                    pair = record.candidate_pair.candidate_pair
                    if not pair.nominated or not pair.bytes_received:
                        continue
                    candidate = candidates.get(pair.local_candidate_id)
                    if candidate is not None:
                        def enum_name(field):
                            desc = candidate.DESCRIPTOR.fields_by_name[field]
                            return desc.enum_type.values_by_number[getattr(candidate, field)].name
                        transports.append({"candidateType": enum_name("candidate_type"),
                                           "relayProtocol": enum_name("relay_protocol"),
                                           "protocol": candidate.protocol})
                selected.append(transports)
            stats["selectedTransports"] = selected
            stats["relayOnly"] = relay_only
            if relay_only:
                assert all(transports and all("RELAY" in item["candidateType"] for item in transports)
                           for transports in selected)
            await call("POST", f"/v1/rooms/{room_id}/actions", accounts[0], json={
                "action": "mute_audio", "targetUserID": accounts[1]["user"]["id"], "enabled": True})
            for _ in range(100):
                remote = rooms[0].remote_participants.get(accounts[1]["user"]["sdkUserID"])
                publications = list(remote.track_publications.values()) if remote else []
                if (not rooms[1].local_participant.permissions.can_publish
                        and all(publication.muted or publication.track is None for publication in publications)):
                    break
                await asyncio.sleep(.1)
            else:
                raise AssertionError("Forced mute did not revoke the real published audio track")
            stats["forcedMuteRevokesPublishedAudioTrack"] = True
            denied = await http.patch(f"/v1/rooms/{room_id}", headers={"Authorization": "Bearer " + accounts[1]["token"]}, json={"status": "ended"})
            assert denied.status_code == 403
            await call("PATCH", f"/v1/rooms/{room_id}", accounts[0], json={"status": "ended"})
            await asyncio.wait_for(asyncio.gather(*(event.wait() for event in disconnected)), 15)
            rejected = await http.post(f"/v1/rooms/{room_id}/token", headers={"Authorization": "Bearer " + accounts[1]["token"]})
            assert rejected.status_code == 409
            stats.update(participants=2, hostEndDisconnectsBoth=True, guestCannotEnd=True,
                         endedRoomRejectsNewTokens=True, server=URL, syntheticAudio=True)
            print(json.dumps(stats, ensure_ascii=False))
        except BaseException:
            print(json.dumps({"failedMediaStats": stats}, ensure_ascii=False), flush=True)
            raise
        finally:
            for room in rooms:
                await room.disconnect()
            for task in collectors:
                task.cancel()
            await asyncio.gather(*collectors, return_exceptions=True)
            for source in audio_sources:
                await source.aclose()
            for account in accounts:
                await call("DELETE", "/v1/account", account)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relay-only", action="store_true", help="Require relay ICE candidates to verify the TURN fallback")
    asyncio.run(main(parser.parse_args().relay_only))
