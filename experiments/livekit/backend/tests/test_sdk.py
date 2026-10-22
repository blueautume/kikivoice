import asyncio
from types import SimpleNamespace

from aiohttp import ClientTimeout
from livekit import api
import pytest

from app.rtc import LiveKitGateway


def test_official_sdk_boundary_request_types_and_server_side_capacity(lab):
    async def exercise():
        gateway = LiveKitGateway(lab.settings)
        assert isinstance(gateway.client._session.timeout, ClientTimeout)
        assert gateway.client._session.timeout.total == 8
        calls = []

        class RoomService:
            async def create_room(self, request):
                assert isinstance(request, api.CreateRoomRequest)
                assert request.max_participants == 32
                assert request.empty_timeout == 600
                assert request.departure_timeout == 180
                calls.append(("create", request.name))

            async def delete_room(self, request):
                assert isinstance(request, api.DeleteRoomRequest)
                calls.append(("delete", request.room))
                raise api.TwirpError("not_found", "Not found", status=404)

            async def list_rooms(self, request):
                assert isinstance(request, api.ListRoomsRequest)
                return SimpleNamespace(rooms=[SimpleNamespace(name="room1", num_participants=2)])

            async def list_participants(self, request):
                assert isinstance(request, api.ListParticipantsRequest)
                return SimpleNamespace(participants=[SimpleNamespace(identity="alice")])

        gateway.client._room = RoomService()
        try:
            await gateway.create_room("room1")
            assert await gateway.list_rooms() == {"room1": 2}
            assert await gateway.participants("room1") == {"alice"}
            await gateway.delete_room("room1")
            assert calls == [("create", "room1"), ("delete", "room1")]
        finally:
            await gateway.close()

    asyncio.run(exercise())


def test_official_sdk_enforces_audio_data_metadata_and_track_permissions(lab):
    async def exercise():
        gateway = LiveKitGateway(lab.settings)
        seen = []
        class RoomService:
            async def update_participant(self, request):
                assert isinstance(request, api.UpdateParticipantRequest)
                assert request.room == 'room1' and request.identity == 'alice'
                assert request.metadata == '{"server":{"generation":3}}'
                permission = request.permission
                assert permission.can_subscribe
                assert not permission.can_publish and not permission.can_publish_data
                assert list(permission.can_publish_sources) == [api.TrackSource.MICROPHONE]
                assert not permission.can_update_metadata
                seen.append('permissions')

            async def list_participants(self, request):
                return SimpleNamespace(participants=[SimpleNamespace(identity='alice', tracks=[
                    SimpleNamespace(sid='mic_track', source=api.TrackSource.MICROPHONE),
                    SimpleNamespace(sid='camera_track', source=api.TrackSource.CAMERA)])])

            async def mute_published_track(self, request):
                assert isinstance(request, api.MuteRoomTrackRequest)
                assert request.room == 'room1' and request.identity == 'alice'
                assert request.track_sid == 'mic_track' and request.muted is True
                seen.append('mute')

            async def remove_participant(self, request):
                assert isinstance(request, api.RoomParticipantIdentity)
                assert request.room == 'room1' and request.identity == 'alice'
                seen.append('remove')
                raise api.TwirpError('not_found', 'Not found', status=404)

        gateway.client._room = RoomService()
        try:
            await gateway.update_permissions('room1', 'alice', audio=False, data=False,
                metadata='{"server":{"generation":3}}')
            await gateway.mute_audio_tracks('room1', 'alice')
            participants = await gateway.get_participants('room1')
            assert participants['alice'].tracks[0].sid == 'mic_track'
            await gateway.remove_participant('room1', 'alice')
            assert seen == ['permissions', 'mute', 'remove']
        finally:
            await gateway.close()
    asyncio.run(exercise())


def test_official_sdk_broadcasts_only_authoritative_chat_sync_hints(lab):
    async def exercise():
        gateway = LiveKitGateway(lab.settings)
        calls = []
        hint = {'version': 1, 'latestSeq': 12, 'historyRevision': 2, 'announcementRevision': 3}
        class RoomService:
            async def send_data(self, request):
                import json
                assert isinstance(request, api.SendDataRequest)
                assert request.room == 'room1' and request.topic == 'kiki.chat.sync'
                assert request.kind == api.DataPacket.RELIABLE
                assert json.loads(request.data) == hint
                assert not request.destination_identities
                calls.append(True)
        gateway.client._room = RoomService()
        try:
            await gateway.broadcast_chat_sync('room1', hint)
            assert calls == [True]
        finally:
            await gateway.close()
    asyncio.run(exercise())


@pytest.mark.parametrize('method', ['update_permissions', 'remove_participant'])
def test_sfu_permission_errors_are_not_hidden_except_confirmed_not_found(lab, method):
    async def exercise():
        gateway = LiveKitGateway(lab.settings)
        class RoomService:
            async def update_participant(self, request):
                raise api.TwirpError('unavailable', 'Offline', status=503)
            async def remove_participant(self, request):
                raise api.TwirpError('unavailable', 'Offline', status=503)
        gateway.client._room = RoomService()
        try:
            kwargs = dict(audio=False, data=False, metadata='{}') if method == 'update_permissions' else {}
            with pytest.raises(api.TwirpError):
                await getattr(gateway, method)('room1', 'alice', **kwargs)
        finally:
            await gateway.close()
    asyncio.run(exercise())
