"""Small official LiveKit server SDK boundary, replaced by a fake in tests."""
from datetime import timedelta
import json

from aiohttp import ClientTimeout
from livekit import api


class LiveKitGateway:
    def __init__(self, settings):
        self.settings = settings
        self.client = api.LiveKitAPI(settings.livekit_url, settings.api_key, settings.api_secret,
                                     timeout=ClientTimeout(total=8))

    async def close(self):
        await self.client.aclose()

    async def list_rooms(self):
        result = await self.client.room.list_rooms(api.ListRoomsRequest())
        return {room.name: room.num_participants for room in result.rooms}

    async def create_room(self, room_id):
        await self.client.room.create_room(api.CreateRoomRequest(
            name=room_id, max_participants=self.settings.max_room_participants,
            empty_timeout=600, departure_timeout=180))

    async def broadcast_chat_sync(self, room_id, hint):
        await self.client.room.send_data(api.SendDataRequest(room=room_id,
            data=json.dumps(hint, separators=(",", ":")).encode(),
            kind=api.DataPacket.RELIABLE, topic="kiki.chat.sync"))

    async def delete_room(self, room_id):
        try:
            await self.client.room.delete_room(api.DeleteRoomRequest(room=room_id))
        except api.TwirpError as error:
            if error.code != "not_found":
                raise

    async def participants(self, room_id):
        return set(await self.get_participants(room_id))

    async def get_participants(self, room_id):
        try:
            result = await self.client.room.list_participants(api.ListParticipantsRequest(room=room_id))
        except api.TwirpError as error:
            if error.code == "not_found":
                return {}
            raise
        return {participant.identity: participant for participant in result.participants}

    async def remove_participant(self, room_id, user_id):
        try:
            await self.client.room.remove_participant(api.RoomParticipantIdentity(room=room_id, identity=user_id))
        except api.TwirpError as error:
            if error.code != "not_found":
                raise

    async def update_permissions(self, room_id, user_id, *, audio, data, metadata):
        try:
            await self.client.room.update_participant(api.UpdateParticipantRequest(
                room=room_id, identity=user_id, metadata=metadata,
                permission=api.ParticipantPermission(can_subscribe=True, can_publish=audio,
                    can_publish_data=data, can_publish_sources=[api.TrackSource.MICROPHONE],
                    can_update_metadata=False)))
        except api.TwirpError as error:
            if error.code != "not_found":
                raise

    async def mute_audio_tracks(self, room_id, user_id):
        participant = (await self.get_participants(room_id)).get(user_id)
        for track in getattr(participant, "tracks", ()):
            if track.source == api.TrackSource.MICROPHONE:
                try:
                    await self.client.room.mute_published_track(api.MuteRoomTrackRequest(
                        room=room_id, identity=user_id, track_sid=track.sid, muted=True))
                except api.TwirpError as error:
                    if error.code != "not_found":
                        raise

    @staticmethod
    def metadata(user, member):
        return json.dumps({"name": user["name"], "avatarIndex": user["avatarIndex"],
            "host": member["role"] == "owner", "role": member["role"],
            "seatIndex": member["seatIndex"], "server": {
                "sessionHash": member["sessionHash"], "userID": user["sdkUserID"],
                "generation": member["generation"]}}, ensure_ascii=False, separators=(",", ":"))

    def participant_token(self, room_id, user, member):
        metadata = LiveKitGateway.metadata(user, member)
        return (api.AccessToken(self.settings.api_key, self.settings.api_secret)
                .with_identity(user["sdkUserID"]).with_name(user["name"])
                .with_metadata(metadata).with_ttl(timedelta(minutes=5))
                .with_grants(api.VideoGrants(room_join=True, room=room_id,
                    can_publish=member["canPublishAudio"], can_publish_data=member["canPublishData"], can_subscribe=True,
                    can_publish_sources=["microphone"], can_update_own_metadata=False))
                .to_jwt())
