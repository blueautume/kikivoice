"""Security and transport regressions for the public signalling boundary."""
import asyncio
from contextlib import suppress
import json
import socket as native_socket
import time
from types import SimpleNamespace
from urllib.parse import urlencode

import aiohttp
from aiohttp import web
from fastapi import HTTPException
from fastapi import FastAPI
import jwt
from google.protobuf.json_format import MessageToJson, Parse
from livekit.protocol import models, rtc as rtc_protocol
import pytest
from starlette.requests import Request
from starlette.websockets import WebSocket

from app.signal_gateway import (MAX_FRAME_BYTES, SignalAuthorization, SignalGateway,
                                UPSTREAM)


KEY = "isolated-lab-test"
SECRET = "s" * 48
SESSION = "a" * 64


def token(*, publish=True, generation=1, session=SESSION, **changes):
    claims = {"iss": KEY, "sub": "alice", "exp": int(time.time()) + 300,
              "nbf": int(time.time()) - 1,
              "video": {"roomJoin": True, "room": "room1", "canPublish": publish,
                        "canSubscribe": True, "canPublishData": False},
              "metadata": json.dumps({"server": {"sessionHash": session,
                                                   "userID": "alice", "generation": generation}})}
    claims.update(changes)
    return jwt.encode(claims, SECRET, algorithm="HS256")


class Upstream:
    protocol = None

    def __init__(self):
        self.incoming = asyncio.Queue()
        self.sent = []
        self.closed = asyncio.Event()

    async def send_bytes(self, data):
        self.sent.append(("bytes", data))

    async def send_str(self, data):
        self.sent.append(("text", data))

    async def close(self):
        self.closed.set()

    def __aiter__(self):
        return self

    async def __anext__(self):
        return await self.incoming.get()


class Client:
    def __init__(self, **kwargs):
        self.options = kwargs
        self.requests = []
        self.upstreams = []
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.release.set()
        self.closed = False
        self.status = 200

    async def ws_connect(self, url, **kwargs):
        self.requests.append((url, kwargs))
        self.started.set()
        await self.release.wait()
        upstream = Upstream()
        self.upstreams.append(upstream)
        return upstream

    def get(self, url, **kwargs):
        self.requests.append((url, kwargs))
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    @property
    def content(self):
        return self

    async def read(self, count):
        return b"success"

    async def close(self):
        self.closed = True


class Socket:
    def __init__(self, credential=None, path="/rtc/v1", *, query=None, header=True):
        self.incoming = asyncio.Queue()
        self.incoming.put_nowait({"type": "websocket.connect"})
        self.messages = []
        self.accepted = asyncio.Event()
        params = dict(query or {})
        headers = []
        if credential is not None:
            if header:
                headers.append((b"authorization", ("Bearer " + credential).encode()))
            else:
                params["access_token"] = credential
        self.socket = WebSocket({"type": "websocket", "scheme": "wss", "path": path,
            "raw_path": path.encode(), "query_string": urlencode(params).encode(),
            "headers": headers, "server": ("furby.top", 443), "client": ("127.0.0.1", 1),
            "subprotocols": [], "extensions": {"websocket.http.response": {}}},
            self.incoming.get, self.send)

    async def send(self, message):
        self.messages.append(message)
        if message["type"] == "websocket.accept":
            self.accepted.set()


class Authority:
    def __init__(self):
        self.lock = asyncio.Lock()
        self.allowed = True
        self.publish = False
        self.connections = []
        self.generation = 1

    async def authorize(self, claims, register):
        async with self.lock:
            if not self.allowed or claims.generation != self.generation:
                raise HTTPException(403, "Access revoked")
            connection = register(SignalAuthorization(claims.room, claims.user_id,
                claims.session_hash, claims.generation,
                token(publish=self.publish, generation=claims.generation)))
            self.connections.append(connection)
            return connection


def setup(disconnected=None):
    client = Client()
    authority = Authority()
    gateway = SignalGateway(KEY, SECRET, authority.authorize, disconnected,
                            session_factory=lambda **kwargs: client)
    return gateway, authority, client


@pytest.mark.parametrize("changes", [
    {"exp": int(time.time()) - 10}, {"nbf": int(time.time()) + 1000},
    {"iss": "other-project"}, {"sub": "bob"}, {"video": {"roomJoin": False, "room": "room1"}},
    {"video": {"roomJoin": True}}, {"metadata": "{}"},
    {"metadata": json.dumps({"server": {"sessionHash": SESSION, "userID": "alice", "generation": True}})},
])
def test_invalid_or_unbound_tokens_fail_closed(changes):
    gateway, _, _ = setup()
    with pytest.raises(HTTPException) as error:
        gateway.verify(token(**changes))
    assert error.value.status_code == 401


def test_tampered_and_unsigned_tokens_rejected():
    gateway, _, _ = setup()
    valid = token()
    payload = jwt.decode(valid, options={"verify_signature": False})
    for invalid in (valid[:-12] + "a" * 12,
                    jwt.encode(payload, "different-secret" * 4, algorithm="HS256"),
                    jwt.encode(payload, "", algorithm="none")):
        with pytest.raises(HTTPException):
            gateway.verify(invalid)


@pytest.mark.parametrize("reason", ["revoked_session", "banned", "closed_room", "old_generation"])
def test_authoritative_denial_never_opens_upstream(reason):
    async def exercise():
        gateway, authority, client = setup()
        if reason == "old_generation":
            authority.generation += 1
        else:
            authority.allowed = False
        socket = Socket(token())
        await gateway.websocket(socket.socket)
        assert not client.requests
        assert not socket.accepted.is_set()
        assert socket.messages[0]["status"] == 403
        await gateway.close()
    asyncio.run(exercise())


def test_old_speaker_jwt_uses_current_observer_permissions_and_preserves_resume():
    async def exercise():
        gateway, authority, client = setup()
        socket = Socket(token(publish=True), path="/rtc", header=False,
            query={"reconnect": "1", "sid": "PA_original", "protocol": "16", "attributes": "encoded"})
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        url, options = client.requests[0]
        assert url == UPSTREAM + "/rtc"
        assert "access_token" not in dict(options["params"])
        assert dict(options["params"])["sid"] == "PA_original"
        assert dict(options["params"])["attributes"] == "encoded"
        forwarded = options["headers"]["Authorization"].removeprefix("Bearer ")
        assert gateway.verify(forwarded).claims["video"]["canPublish"] is False
        assert gateway.verify(token()).claims["video"]["canPublish"] is True
        await gateway.close_identity("room1", "alice")
        await task
        assert client.upstreams[0].closed.is_set()
        assert not gateway._connections
        await gateway.close()
    asyncio.run(exercise())


def test_bidirectional_binary_and_text_frames():
    async def exercise():
        gateway, _, client = setup()
        socket = Socket(token(), query={"join_request": "opaque-protobuf-and-sdp"})
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        upstream = client.upstreams[0]
        await socket.incoming.put({"type": "websocket.receive", "bytes": b"client-binary"})
        await socket.incoming.put({"type": "websocket.receive", "text": "client-text"})
        await upstream.incoming.put(SimpleNamespace(type=aiohttp.WSMsgType.BINARY, data=b"server-binary"))
        await upstream.incoming.put(SimpleNamespace(type=aiohttp.WSMsgType.TEXT, data="server-text"))
        async def delivered():
            while len(upstream.sent) < 2 or len([m for m in socket.messages if m["type"] == "websocket.send"]) < 2:
                await asyncio.sleep(0)
        await asyncio.wait_for(delivered(), 1)
        assert upstream.sent == [("bytes", b"client-binary"), ("text", "client-text")]
        assert {m.get("bytes") for m in socket.messages} >= {b"server-binary"}
        assert {m.get("text") for m in socket.messages} >= {"server-text"}
        assert dict(client.requests[0][1]["params"])["join_request"] == "opaque-protobuf-and-sdp"
        await socket.incoming.put({"type": "websocket.disconnect", "code": 1000})
        await task
        await gateway.close()
    asyncio.run(exercise())


def test_logout_during_handshake_waits_until_join_can_be_removed():
    async def exercise():
        gateway, authority, client = setup()
        client.release.clear()
        socket = Socket(token())
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await client.started.wait()
        # Same lock as the authorizer; disconnected callback must not be awaited here.
        async with authority.lock:
            authority.allowed = False
            close = asyncio.create_task(gateway.close_session(SESSION))
            await asyncio.sleep(0)
            assert authority.connections[0].revoked.is_set()
            assert not close.done()
            client.release.set()
            await asyncio.wait_for(close, 1)
        await task
        assert not socket.accepted.is_set()
        assert client.upstreams[0].closed.is_set()
        assert authority.connections[0].upstream_settled.is_set()
        await gateway.close()
    asyncio.run(exercise())


def test_old_proxy_cleanup_cannot_clear_new_connection_or_overtake_handshake():
    async def exercise():
        callbacks = []
        gateway, authority, client = setup(lambda connection: record(connection))
        async def record(connection):
            async with authority.lock:
                callbacks.append(connection.connection_id)
        client.release.clear()
        old_socket = Socket(token())
        old_task = asyncio.create_task(gateway.websocket(old_socket.socket))
        await client.started.wait()
        old = authority.connections[0]
        new_socket = Socket(token())
        new_task = asyncio.create_task(gateway.websocket(new_socket.socket))
        while len(authority.connections) < 2:
            await asyncio.sleep(0)
        new = authority.connections[1]
        assert old.revoked.is_set() and old.close_reason == "replaced"
        assert len(client.requests) == 1  # New handshake cannot overtake pending old join.
        client.release.set()
        await new_socket.accepted.wait()
        await old_task
        assert gateway.is_current(new) and not gateway.is_current(old)
        assert gateway._connections == {new.connection_id: new}
        async with authority.lock:
            await asyncio.wait_for(gateway.close_identity("room1", "alice"), 1)
        await new_task
        await gateway.close()
        assert set(callbacks) == {old.connection_id, new.connection_id}
    asyncio.run(exercise())


def test_request_cancellation_during_handshake_still_settles_upstream():
    async def exercise():
        gateway, authority, client = setup()
        client.release.clear()
        socket = Socket(token())
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await client.started.wait()
        task.cancel()
        await asyncio.sleep(0)
        assert not authority.connections[0].upstream_settled.is_set()
        client.release.set()
        with suppress(asyncio.CancelledError):
            await task
        assert client.upstreams[0].closed.is_set()
        assert authority.connections[0].upstream_settled.is_set()
        assert not gateway._connections
        await gateway.close()
    asyncio.run(exercise())


def test_validation_rechecks_db_without_replacing_active_websocket():
    async def exercise():
        gateway, authority, client = setup()
        socket = Socket(token())
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        active = authority.connections[0]
        request = Request({"type": "http", "method": "GET", "path": "/rtc/v1/validate",
            "scheme": "https", "query_string": b"join_request=opaque", "server": ("furby.top", 443),
            "headers": [(b"authorization", ("Bearer " + token()).encode())]})
        response = await gateway.validate(request)
        assert response.status_code == 200
        assert gateway.is_current(active) and not active.revoked.is_set()
        assert authority.connections[1].is_validation
        assert client.requests[-1][0] == UPSTREAM + "/rtc/v1/validate"
        authority.allowed = False
        with pytest.raises(HTTPException) as error:
            await gateway.validate(request)
        assert error.value.status_code == 403
        await gateway.close_room("room1")
        await task
        await gateway.close()
    asyncio.run(exercise())


def test_identity_capacity_rejection_does_not_replace_healthy_connection():
    async def exercise():
        client = Client()
        authority = Authority()
        gateway = SignalGateway(KEY, SECRET, authority.authorize,
            session_factory=lambda **kwargs: client, max_identity_connections=1)
        active_socket = Socket(token())
        active_task = asyncio.create_task(gateway.websocket(active_socket.socket))
        await active_socket.accepted.wait()
        active = authority.connections[0]
        rejected = Socket(token(), query={"reconnect": "1"})
        await gateway.websocket(rejected.socket)
        assert rejected.messages[0]["status"] == 429
        assert gateway.is_current(active) and not active.revoked.is_set()
        assert len(gateway._connections) == 1 and len(client.requests) == 1
        await active_socket.incoming.put({"type": "websocket.disconnect", "code": 1000})
        await active_task
        replacement = Socket(token(), query={"reconnect": "1"})
        replacement_task = asyncio.create_task(gateway.websocket(replacement.socket))
        await replacement.accepted.wait()
        await gateway.close_room("room1")
        await replacement_task
        assert not gateway._connections
        await gateway.close()
    asyncio.run(exercise())


def test_three_pending_reconnects_fit_default_identity_limit_without_overtaking():
    async def exercise():
        gateway, authority, client = setup()
        active_socket = Socket(token())
        tasks = [asyncio.create_task(gateway.websocket(active_socket.socket))]
        await active_socket.accepted.wait()
        release_old_close = asyncio.Event()
        original_close = client.upstreams[0].close
        async def held_close():
            await release_old_close.wait()
            await original_close()
        client.upstreams[0].close = held_close
        sockets = []
        for index in range(3):
            socket = Socket(token(), query={"reconnect": "1"})
            sockets.append(socket)
            tasks.append(asyncio.create_task(gateway.websocket(socket.socket)))
            async def registered():
                while len(authority.connections) < index + 2:
                    await asyncio.sleep(0)
            await asyncio.wait_for(registered(), 1)
        assert len(gateway._connections) == 4
        assert len(client.requests) == 1
        current = authority.connections[-1]
        rejected = Socket(token(), query={"reconnect": "1"})
        await gateway.websocket(rejected.socket)
        assert rejected.messages[0]["status"] == 429
        assert gateway.is_current(current) and not current.revoked.is_set()
        release_old_close.set()
        await asyncio.wait_for(sockets[-1].accepted.wait(), 1)
        await asyncio.gather(*tasks[:-1])
        assert len(gateway._connections) == 1
        assert len(client.requests) == 2
        await gateway.close_room("room1")
        await tasks[-1]
        await gateway.close()
    asyncio.run(exercise())


def test_total_connection_capacity_covers_different_identities_and_excludes_validate():
    async def exercise():
        client = Client()
        lock = asyncio.Lock()
        async def authorize(claims, register):
            async with lock:
                return register(SignalAuthorization(claims.room, claims.user_id,
                    claims.session_hash, claims.generation,
                    jwt.encode(claims.claims, SECRET, algorithm="HS256")))
        def credential(name):
            return token(sub=name, metadata=json.dumps({"server": {
                "sessionHash": SESSION, "userID": name, "generation": 1}}))
        gateway = SignalGateway(KEY, SECRET, authorize,
            session_factory=lambda **kwargs: client, max_connections=2)
        sockets = [Socket(credential(name)) for name in ("alice", "bob")]
        tasks = [asyncio.create_task(gateway.websocket(socket.socket)) for socket in sockets]
        for socket in sockets:
            await socket.accepted.wait()
        rejected = Socket(credential("charlie"))
        await gateway.websocket(rejected.socket)
        assert rejected.messages[0]["status"] == 429
        assert len(gateway._connections) == 2
        assert all(not connection.revoked.is_set() for connection in gateway._connections.values())
        request = Request({"type": "http", "method": "GET", "path": "/rtc/v1/validate",
            "scheme": "https", "query_string": b"",
            "headers": [(b"authorization", ("Bearer " + credential("charlie")).encode())]})
        assert (await gateway.validate(request)).status_code == 200
        assert len(gateway._connections) == 2
        await sockets[0].incoming.put({"type": "websocket.disconnect", "code": 1000})
        await tasks[0]
        new_socket = Socket(credential("charlie"))
        new_task = asyncio.create_task(gateway.websocket(new_socket.socket))
        await new_socket.accepted.wait()
        assert len(gateway._connections) == 2
        await gateway.close_room("room1")
        await asyncio.gather(tasks[1], new_task)
        assert not gateway._connections
        await gateway.close()
    asyncio.run(exercise())


def test_failed_auth_and_failed_handshake_do_not_hold_connection_capacity():
    async def exercise():
        client = Client()
        authority = Authority()
        gateway = SignalGateway(KEY, SECRET, authority.authorize,
            session_factory=lambda **kwargs: client, max_connections=1, max_identity_connections=1)
        authority.allowed = False
        denied = Socket(token())
        await gateway.websocket(denied.socket)
        assert denied.messages[0]["status"] == 403
        assert not gateway._connections and not client.requests
        authority.allowed = True
        original_connect = client.ws_connect
        async def failed_connect(*args, **kwargs):
            raise aiohttp.ClientConnectionError()
        client.ws_connect = failed_connect
        failed = Socket(token())
        await gateway.websocket(failed.socket)
        assert failed.messages[0]["status"] == 502
        assert not gateway._connections
        client.ws_connect = original_connect
        healthy = Socket(token())
        task = asyncio.create_task(gateway.websocket(healthy.socket))
        await healthy.accepted.wait()
        await gateway.close_room("room1")
        await task
        await gateway.close()
    asyncio.run(exercise())


def test_cancelled_handshake_releases_capacity_only_after_upstream_settles():
    async def exercise():
        client = Client()
        authority = Authority()
        gateway = SignalGateway(KEY, SECRET, authority.authorize,
            session_factory=lambda **kwargs: client, max_connections=1, max_identity_connections=1)
        client.release.clear()
        task = asyncio.create_task(gateway.websocket(Socket(token()).socket))
        await client.started.wait()
        task.cancel()
        await asyncio.sleep(0)
        rejected = Socket(token())
        await gateway.websocket(rejected.socket)
        assert rejected.messages[0]["status"] == 429
        assert len(gateway._connections) == 1
        client.release.set()
        with suppress(asyncio.CancelledError):
            await task
        assert not gateway._connections
        healthy = Socket(token())
        healthy_task = asyncio.create_task(gateway.websocket(healthy.socket))
        await healthy.accepted.wait()
        await gateway.close_room("room1")
        await healthy_task
        await gateway.close()
    asyncio.run(exercise())


@pytest.mark.parametrize("limits", [{"max_connections": 0}, {"max_connections": True},
    {"max_identity_connections": -1}, {"max_identity_connections": 1.5}])
def test_connection_limits_must_be_positive_integers(limits):
    with pytest.raises(ValueError):
        SignalGateway(KEY, SECRET, Authority().authorize, **limits)


def test_oversized_client_frame_is_not_forwarded():
    async def exercise():
        gateway, _, client = setup()
        socket = Socket(token())
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        await socket.incoming.put({"type": "websocket.receive", "bytes": b"x" * (MAX_FRAME_BYTES + 1)})
        await asyncio.wait_for(task, 1)
        assert not client.upstreams[0].sent
        assert any(message.get("code") == 1009 for message in socket.messages)
        await gateway.close()
    asyncio.run(exercise())


def test_cancelled_intermediate_reconnect_cannot_bypass_original_handshake():
    async def exercise():
        gateway, authority, client = setup()
        client.release.clear()
        first_task = asyncio.create_task(gateway.websocket(Socket(token()).socket))
        await client.started.wait()
        middle_task = asyncio.create_task(gateway.websocket(Socket(token()).socket))
        while len(authority.connections) < 2:
            await asyncio.sleep(0)
        middle_task.cancel()
        with suppress(asyncio.CancelledError):
            await middle_task
        last_socket = Socket(token())
        last_task = asyncio.create_task(gateway.websocket(last_socket.socket))
        while len(authority.connections) < 3:
            await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert len(client.requests) == 1
        client.release.set()
        await last_socket.accepted.wait()
        await first_task
        assert gateway.is_current(authority.connections[-1])
        await gateway.close_room("room1")
        await last_task
        await gateway.close()
    asyncio.run(exercise())


def test_real_aiohttp_loopback_handshake_and_validation():
    async def exercise():
        authority = Authority()
        gateway = SignalGateway(KEY, SECRET, authority.authorize)
        received = []
        async def signal(request):
            received.append((request.path, dict(request.query), request.headers["Authorization"]))
            peer = web.WebSocketResponse()
            await peer.prepare(request)
            async for message in peer:
                if message.type == aiohttp.WSMsgType.BINARY:
                    await peer.send_bytes(message.data)
                elif message.type == aiohttp.WSMsgType.TEXT:
                    await peer.send_str(message.data)
            return peer
        async def validate(request):
            received.append((request.path, dict(request.query), request.headers["Authorization"]))
            return web.Response(text="success")
        app = web.Application()
        app.router.add_get("/rtc/v1", signal)
        app.router.add_get("/rtc/v1/validate", validate)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        try:
            await web.TCPSite(runner, "127.0.0.1", 7880).start()
        except OSError:
            await runner.cleanup()
            pytest.skip("A different local LiveKit instance already owns the fixed loopback port")
        try:
            socket = Socket(token(), query={"join_request": "wrapped+request/=="})
            task = asyncio.create_task(gateway.websocket(socket.socket))
            await asyncio.wait_for(socket.accepted.wait(), 2)
            await socket.incoming.put({"type": "websocket.receive", "bytes": b"real-binary"})
            async def delivered():
                while not any(message.get("bytes") == b"real-binary" for message in socket.messages):
                    await asyncio.sleep(0)
            await asyncio.wait_for(delivered(), 2)
            assert received[0][1]["join_request"] == "wrapped+request/=="
            forwarded = received[0][2].removeprefix("Bearer ")
            assert gateway.verify(forwarded).claims["video"]["canPublish"] is False
            request = Request({"type": "http", "method": "GET", "path": "/rtc/v1/validate",
                "scheme": "https", "query_string": b"join_request=wrapped", "server": ("furby.top", 443),
                "headers": [(b"authorization", ("Bearer " + token()).encode())]})
            assert (await gateway.validate(request)).status_code == 200
            await gateway.close_session(SESSION)
            await task
        finally:
            await gateway.close()
            await runner.cleanup()
    asyncio.run(exercise())


def test_permission_change_settles_pending_grants_but_keeps_established_socket():
    async def exercise():
        gateway, authority, client = setup()
        active_socket = Socket(token())
        active_task = asyncio.create_task(gateway.websocket(active_socket.socket))
        await active_socket.accepted.wait()
        assert await gateway.close_pending_identity("room1", "alice") == []
        assert not authority.connections[0].revoked.is_set()
        # Replacement has captured the old grants and is still handshaking.
        client.release.clear()
        client.started.clear()
        pending_socket = Socket(token(publish=True))
        pending_task = asyncio.create_task(gateway.websocket(pending_socket.socket))
        await client.started.wait()
        async with authority.lock:
            authority.publish = False
            change = asyncio.create_task(gateway.close_pending_identity("room1", "alice"))
            await asyncio.sleep(0)
            assert authority.connections[-1].revoked.is_set()
            assert not change.done()
            client.release.set()
            pending = await asyncio.wait_for(change, 1)
            assert len(pending) == 1 and pending[0].upstream_connected
            # The real backend performs UpdateParticipant here, after join settled.
        await active_task
        await pending_task
        assert not pending_socket.accepted.is_set()
        assert all(upstream.closed.is_set() for upstream in client.upstreams)
        await gateway.close()
    asyncio.run(exercise())


def test_real_uvicorn_wsproto_public_routes_and_revocation():
    pytest.importorskip("wsproto")
    import uvicorn

    async def exercise():
        authority = Authority()
        gateway = SignalGateway(KEY, SECRET, authority.authorize)
        upstream_app = web.Application()
        async def signal(request):
            assert request.headers["Authorization"].startswith("Bearer ")
            assert "access_token" not in request.query
            peer = web.WebSocketResponse()
            await peer.prepare(request)
            async for message in peer:
                if message.type == aiohttp.WSMsgType.BINARY:
                    await peer.send_bytes(message.data)
            return peer
        async def validate(request):
            return web.Response(text="success")
        for path in ("/rtc", "/rtc/v1"):
            upstream_app.router.add_get(path, signal)
            upstream_app.router.add_get(path + "/validate", validate)
        runner = web.AppRunner(upstream_app, access_log=None)
        await runner.setup()
        try:
            await web.TCPSite(runner, "127.0.0.1", 7880).start()
        except OSError:
            await runner.cleanup()
            pytest.skip("A different local LiveKit instance already owns the fixed loopback port")
        app = FastAPI()
        app.include_router(gateway.router)
        listener = native_socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(16)
        port = listener.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(app, ws="wsproto", lifespan="off",
            log_level="critical", access_log=False))
        serving = asyncio.create_task(server.serve(sockets=[listener]))
        try:
            async def started():
                while not server.started:
                    await asyncio.sleep(0)
            await asyncio.wait_for(started(), 2)
            async with aiohttp.ClientSession() as browser:
                for path in ("/rtc", "/rtc/v1"):
                    async with browser.ws_connect(f"http://127.0.0.1:{port}" + path,
                            headers={"Authorization": "Bearer " + token()},
                            params={"join_request": "wrapped"}) as peer:
                        await peer.send_bytes(b"actual-ASGI-frame")
                        response = await asyncio.wait_for(peer.receive(), 2)
                        assert response.type == aiohttp.WSMsgType.BINARY
                        assert response.data == b"actual-ASGI-frame"
                    async with browser.get(f"http://127.0.0.1:{port}" + path + "/validate",
                            headers={"Authorization": "Bearer " + token()}) as response:
                        assert response.status == 200
                async with browser.ws_connect(f"http://127.0.0.1:{port}/rtc/v1",
                        headers={"Authorization": "Bearer " + token()}) as peer:
                    authority.allowed = False
                    await gateway.close_session(SESSION)
                    terminal = await asyncio.wait_for(peer.receive(), 2)
                    assert terminal.type == aiohttp.WSMsgType.BINARY
                    notice = rtc_protocol.SignalResponse.FromString(terminal.data)
                    assert notice.leave.reason == models.PARTICIPANT_REMOVED
                    assert notice.leave.action == rtc_protocol.LeaveRequest.DISCONNECT
                    assert (await asyncio.wait_for(peer.receive(), 2)).type in (
                        aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED)
                with pytest.raises(aiohttp.WSServerHandshakeError) as error:
                    await browser.ws_connect(f"http://127.0.0.1:{port}/rtc/v1",
                        headers={"Authorization": "Bearer " + token()})
                assert error.value.status == 403
                with pytest.raises(aiohttp.WSServerHandshakeError) as error:
                    await browser.ws_connect(f"http://127.0.0.1:{port}/rtc",
                        headers={"Authorization": "Bearer " + token(exp=int(time.time()) - 1)})
                assert error.value.status == 401
                async with browser.get(f"http://127.0.0.1:{port}/twirp/livekit.RoomService/ListRooms") as response:
                    assert response.status == 404
        finally:
            server.should_exit = True
            await asyncio.wait_for(serving, 3)
            listener.close()
            await gateway.close()
            await runner.cleanup()
    asyncio.run(exercise())


@pytest.mark.parametrize("path", ["/rtc", "/rtc/v1", "/rtc/validate", "/rtc/v1/validate"])
@pytest.mark.parametrize("publish", [b"publish=shadow", b"publish=&publish=shadow",
                                     b"publish=shadow&publish=", b"publish=%20"])
def test_publisher_only_identity_rewriting_is_denied_on_every_entry_point(path, publish):
    async def exercise():
        gateway, authority, client = setup()
        if path.endswith("/validate"):
            request = Request({"type": "http", "method": "GET", "path": path,
                "scheme": "https", "query_string": publish, "server": ("furby.top", 443),
                "headers": [(b"authorization", ("Bearer " + token()).encode())]})
            with pytest.raises(HTTPException) as error:
                await gateway.validate(request)
            assert error.value.status_code == 403
        else:
            socket = Socket(token(), path=path)
            socket.socket.scope["query_string"] = publish
            await gateway.websocket(socket.socket)
            assert socket.messages[0]["status"] == 403
            assert not socket.accepted.is_set()
        assert not authority.connections
        assert not client.requests
        await gateway.close()
    asyncio.run(exercise())


@pytest.mark.parametrize("operation,reason", [("identity", models.PARTICIPANT_REMOVED),
    ("session", models.PARTICIPANT_REMOVED), ("room", models.ROOM_DELETED)])
@pytest.mark.parametrize("format", ["binary", "json"])
def test_revocation_sends_official_terminal_leave_before_close_without_credentials(operation, reason, format):
    async def exercise():
        gateway, authority, client = setup()
        # Untrusted query hints never choose the downstream encoding.
        socket = Socket(token(), query={"format": "json" if format == "binary" else "binary"})
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        upstream = client.upstreams[0]
        if format == "json":
            await upstream.incoming.put(SimpleNamespace(type=aiohttp.WSMsgType.TEXT, data='{"pong":1}'))
        else:
            await upstream.incoming.put(SimpleNamespace(type=aiohttp.WSMsgType.BINARY,
                data=rtc_protocol.SignalResponse(pong=1).SerializeToString()))
        async def delivered():
            while not any(message["type"] == "websocket.send" for message in socket.messages):
                await asyncio.sleep(0)
            while authority.connections[0].signal_format != format:
                await asyncio.sleep(0)
        await asyncio.wait_for(delivered(), 1)
        async with authority.lock:
            # The real backend also holds this lock while awaiting the barrier.
            if operation == "identity":
                await asyncio.wait_for(gateway.close_identity("room1", "alice"), 1)
            elif operation == "session":
                await asyncio.wait_for(gateway.close_session(SESSION), 1)
            else:
                await asyncio.wait_for(gateway.close_room("room1"), 1)
            assert upstream.closed.is_set()
        await task
        sent = [(index, message) for index, message in enumerate(socket.messages)
                if message["type"] == "websocket.send"]
        assert len(sent) == 2
        terminal_index, terminal = sent[-1]
        if format == "json":
            assert "text" in terminal and "bytes" not in terminal
            notice = Parse(terminal["text"], rtc_protocol.SignalResponse())
        else:
            assert "bytes" in terminal and "text" not in terminal
            notice = rtc_protocol.SignalResponse.FromString(terminal["bytes"])
        assert notice.WhichOneof("message") == "leave"
        assert notice.leave.reason == reason
        assert notice.leave.action == rtc_protocol.LeaveRequest.DISCONNECT
        assert notice.leave.can_reconnect is False
        # Only the protocol enum is emitted; no identity/session/token/SDP payload.
        assert set(dict(notice.ListFields())) == {notice.DESCRIPTOR.fields_by_name["leave"]}
        assert all(field.name == "reason" for field, _ in notice.leave.ListFields())
        assert terminal_index < next(index for index, message in enumerate(socket.messages)
                                     if message["type"] == "websocket.close")
        await gateway.close()
    asyncio.run(exercise())


@pytest.mark.parametrize("ending", ["network", "shutdown", "replacement"])
def test_normal_disconnect_shutdown_and_replacement_do_not_send_terminal_leave(ending):
    async def exercise():
        gateway, _, _ = setup()
        socket = Socket(token())
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        if ending == "network":
            await socket.incoming.put({"type": "websocket.disconnect", "code": 1000})
        elif ending == "shutdown":
            await gateway.close()
        else:
            replacement = Socket(token())
            next_task = asyncio.create_task(gateway.websocket(replacement.socket))
            await replacement.accepted.wait()
            await replacement.incoming.put({"type": "websocket.disconnect", "code": 1000})
            await next_task
        await task
        assert not any(message["type"] == "websocket.send" for message in socket.messages)
        await gateway.close()
    asyncio.run(exercise())


@pytest.mark.parametrize("format", ["binary", "json"])
def test_existing_upstream_terminal_leave_is_not_duplicated(format):
    async def exercise():
        gateway, authority, client = setup()
        socket = Socket(token())
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        response = rtc_protocol.SignalResponse(leave=rtc_protocol.LeaveRequest(
            action=rtc_protocol.LeaveRequest.DISCONNECT, reason=models.PARTICIPANT_REMOVED))
        payload = MessageToJson(response, indent=None) if format == "json" else response.SerializeToString()
        kind = aiohttp.WSMsgType.TEXT if format == "json" else aiohttp.WSMsgType.BINARY
        await client.upstreams[0].incoming.put(SimpleNamespace(type=kind, data=payload))
        async def forwarded():
            while not authority.connections[0].terminal_leave_forwarded:
                await asyncio.sleep(0)
        await asyncio.wait_for(forwarded(), 1)
        await gateway.close_session(SESSION)
        await task
        sent = [message for message in socket.messages if message["type"] == "websocket.send"]
        assert len(sent) == 1
        await gateway.close()
    asyncio.run(exercise())
