"""Revocable, loopback-only LiveKit signalling boundary for the laboratory.

The authorizer MUST check the authoritative database and call ``register`` while
holding the same lock as logout, membership and permission mutations. JWT grants
are evidence of identity only: it supplies a freshly signed upstream token from
current database permissions. Never expose another public route to port 7880.

LiveKit 1.13.10 serves /rtc, /rtc/v1 and their /validate counterparts. Swift 2.18
uses Authorization: Bearer and can carry a WrappedJoinRequest in the query. We
forward that query unchanged except credentials, without inspecting/logging SDP.
"""
from __future__ import annotations

import asyncio
import base64
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass, field
import hmac
import json
import re
import time
import uuid
import zlib

import aiohttp
from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response
from google.protobuf.json_format import MessageToJson, Parse, ParseError
from google.protobuf.message import DecodeError
import jwt
from livekit.protocol import models, rtc as rtc_protocol

from .observability import SignalEvent


UPSTREAM = "http://127.0.0.1:7880"
SIGNAL_PATHS = ("/rtc", "/rtc/v1")
VALIDATE_PATHS = ("/rtc/validate", "/rtc/v1/validate")
MAX_FRAME_BYTES = 1024 * 1024
MAX_QUERY_BYTES = 128 * 1024
MAX_TOKEN_BYTES = 32 * 1024
CONNECT_SECONDS = 20
WRITE_SECONDS = 15
IDLE_SECONDS = 90
TERMINAL_WRITE_SECONDS = 1


@dataclass(frozen=True)
class VerifiedSignalClaims:
    room: str
    user_id: str
    identity: str
    session_hash: str
    generation: int
    claims: dict


@dataclass(frozen=True)
class SignalAuthorization:
    room: str
    user_id: str
    session_hash: str
    generation: int
    upstream_token: str = field(repr=False)


@dataclass(eq=False)
class SignalConnection:
    authorization: SignalAuthorization
    connection_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    is_validation: bool = False
    upstream_connected: bool = False
    upstream_connected_at: float | None = None
    revoked: asyncio.Event = field(default_factory=asyncio.Event, repr=False)
    upstream_settled: asyncio.Event = field(default_factory=asyncio.Event, repr=False)
    previous: SignalConnection | None = field(default=None, repr=False)
    close_reason: str = ""
    signal_format: str = "binary"
    terminal_leave_forwarded: bool = False

    @property
    def room(self):
        return self.authorization.room

    @property
    def user_id(self):
        return self.authorization.user_id

    @property
    def session_hash(self):
        return self.authorization.session_hash

    @property
    def generation(self):
        return self.authorization.generation


Register = Callable[[SignalAuthorization], SignalConnection]
Authorizer = Callable[[VerifiedSignalClaims, Register], Awaitable[SignalConnection]]
Disconnected = Callable[[SignalConnection], Awaitable[None]]


class SignalGateway:
    def __init__(self, api_key: str, api_secret: str, authorize: Authorizer,
                 disconnected: Disconnected | None = None, *, session_factory=None,
                 observer=None, max_connections=256, max_identity_connections=4):
        if (type(max_connections) is not int or max_connections < 1
                or type(max_identity_connections) is not int or max_identity_connections < 1):
            raise ValueError("Signalling connection limits must be positive integers")
        self.api_key = api_key
        self.api_secret = api_secret
        self.authorize = authorize
        self.disconnected = disconnected
        self._observer = observer
        self._max_connections = max_connections
        self._max_identity_connections = max_identity_connections
        self._session_factory = session_factory or aiohttp.ClientSession
        self._session = None
        self._connections: dict[str, SignalConnection] = {}
        self._current: dict[tuple[str, str], SignalConnection] = {}
        self._callbacks: set[asyncio.Task] = set()
        self._closed = False
        self.router = APIRouter()
        for path in SIGNAL_PATHS:
            self.router.add_api_websocket_route(path, self.websocket)
            self.router.add_api_route(path, self.not_found, methods=["GET"], include_in_schema=False)
        for path in VALIDATE_PATHS:
            self.router.add_api_route(path, self.validate, methods=["GET"], include_in_schema=False)

    async def not_found(self):
        return Response(status_code=404)

    def _observe(self, event, value=None):
        # Diagnostics must never change admission, forwarding or revocation.
        if self._observer is not None:
            with suppress(Exception):
                self._observer(event, value)

    @staticmethod
    def _is_reconnect(websocket):
        """Read only the official resume flag, without retaining/logging a query.

        A full reconnect is indistinguishable from a new join on the wire. This
        metric therefore counts quick/resume attempts, including protocol v1.
        Parsing is optional, bounded and has no effect on admission/forwarding.
        """
        if websocket.query_params.get("reconnect") == "1":
            return True
        encoded = websocket.query_params.get("join_request", "")
        if not encoded or len(encoded) > MAX_QUERY_BYTES:
            return False
        try:
            data = base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
            wrapped = rtc_protocol.WrappedJoinRequest.FromString(data)
            data = wrapped.join_request
            if wrapped.compression == rtc_protocol.WrappedJoinRequest.GZIP:
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                data = decoder.decompress(data, MAX_FRAME_BYTES + 1)
                if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                    return False
            elif wrapped.compression != rtc_protocol.WrappedJoinRequest.NONE:
                return False
            if len(data) > MAX_FRAME_BYTES:
                return False
            return rtc_protocol.JoinRequest.FromString(data).reconnect
        except (ValueError, TypeError, DecodeError, zlib.error):
            return False

    def verify(self, token: str) -> VerifiedSignalClaims:
        """Accept only signed, unexpired, session-bound participant grants."""
        try:
            if not token or len(token.encode()) > MAX_TOKEN_BYTES:
                raise ValueError()
            claims = jwt.decode(token, self.api_secret, algorithms=["HS256"],
                                issuer=self.api_key, options={
                                    "require": ["iss", "sub", "exp", "nbf"],
                                    "verify_aud": False})
            identity = claims["sub"]
            grants = claims.get("video")
            metadata = json.loads(claims.get("metadata", ""))
            server = metadata["server"]
            room = grants["room"]
            user_id = server["userID"]
            session_hash = server["sessionHash"]
            generation = server["generation"]
            if (not isinstance(identity, str) or not identity or len(identity) > 128
                    or not isinstance(grants, dict) or grants.get("roomJoin") is not True
                    or not isinstance(room, str) or not room or len(room) > 128
                    or not isinstance(user_id, str) or not hmac.compare_digest(identity, user_id)
                    or not isinstance(session_hash, str)
                    or not re.fullmatch(r"[a-f0-9]{64}", session_hash)
                    or type(generation) is not int or generation < 0):
                raise ValueError()
            return VerifiedSignalClaims(room, user_id, identity, session_hash, generation, claims)
        except (jwt.InvalidTokenError, KeyError, ValueError, TypeError, AttributeError):
            raise HTTPException(401, "Invalid laboratory room credentials") from None

    def _credentials(self, request: Request | WebSocket):
        if len(request.scope.get("query_string", b"")) > MAX_QUERY_BYTES:
            raise HTTPException(413, "Signalling query too large")
        # LiveKit's legacy publisher-only parameter rewrites signed identity to
        # "identity#publish". Such a participant would escape this application's
        # seat, permission and RemoveParticipant identity checks. Laboratory voice
        # rooms use one unchanged identity, including on the v1/validate routes.
        if any(request.query_params.getlist("publish")):
            raise HTTPException(403, "Publisher-only identities are not permitted")
        tokens = request.query_params.getlist("access_token")
        headers = request.headers.getlist("authorization")
        if len(tokens) > 1 or len(headers) > 1:
            raise HTTPException(401, "Ambiguous room credentials")
        token = tokens[0] if tokens else ""
        if headers:
            scheme, _, bearer = headers[0].partition(" ")
            if scheme.lower() != "bearer" or not bearer or " " in bearer:
                raise HTTPException(401, "Invalid room authorization")
            if token and not hmac.compare_digest(token, bearer):
                raise HTTPException(401, "Ambiguous room credentials")
            token = bearer
        return self.verify(token)

    def _register(self, claims: VerifiedSignalClaims, *, validation=False) -> Register:
        def register(authorization: SignalAuthorization):
            if self._closed:
                raise HTTPException(503, "Signalling is shutting down")
            if (authorization.room, authorization.user_id, authorization.session_hash,
                    authorization.generation) != (claims.room, claims.user_id,
                    claims.session_hash, claims.generation):
                raise HTTPException(403, "Room authorization changed")
            # The replacement token must remain bound to the checked membership.
            upstream = self.verify(authorization.upstream_token)
            if (upstream.room, upstream.user_id, upstream.session_hash, upstream.generation) != (
                    claims.room, claims.user_id, claims.session_hash, claims.generation):
                raise HTTPException(403, "Invalid upstream authorization")
            connection = SignalConnection(authorization, is_validation=validation)
            if validation:
                return connection
            key = (connection.room, connection.user_id)
            # The authorizer calls register while holding the same admission
            # lock as mutations. Count the authoritative registry, including
            # pending/revoked handshakes until their finally blocks settle.
            # Reject before superseding a healthy connection; an overload must
            # not become a way to evict an admitted participant.
            if (len(self._connections) >= self._max_connections
                    or sum((candidate.room, candidate.user_id) == key
                           for candidate in self._connections.values()) >= self._max_identity_connections):
                raise HTTPException(429, "Signalling connection capacity reached; retry shortly")
            previous = self._current.get(key)
            if previous is None:
                # A cancelled replacement can disappear before its predecessor's
                # handshake settles. Keep the next join behind that predecessor.
                previous = next((candidate for candidate in reversed(self._connections.values())
                                 if (candidate.room, candidate.user_id) == key), None)
            if previous is not None:
                previous.close_reason = "replaced"
                previous.revoked.set()
                connection.previous = previous
            self._current[key] = connection
            self._connections[connection.connection_id] = connection
            return connection
        return register

    def is_current(self, connection: SignalConnection):
        """Identity comparison; safe inside the application's authoritative lock."""
        return self._current.get((connection.room, connection.user_id)) is connection

    def _params(self, request):
        # Credentials never enter the upstream URL or any generated error text.
        return [(key, value) for key, value in request.query_params.multi_items()
                if key != "access_token"]

    def _client(self):
        if self._session is None:
            self._session = self._session_factory(
                timeout=aiohttp.ClientTimeout(total=None, connect=CONNECT_SECONDS,
                                              sock_read=CONNECT_SECONDS),
                trust_env=False)
        return self._session

    async def validate(self, request: Request):
        connection = None
        try:
            if request.url.path not in VALIDATE_PATHS:
                raise HTTPException(404, "Signalling endpoint not found")
            claims = self._credentials(request)
            connection = await self.authorize(claims, self._register(claims, validation=True))
            if not connection.is_validation:
                raise HTTPException(503, "Invalid validation registration")
            async with self._client().get(UPSTREAM + request.url.path,
                    params=self._params(request), allow_redirects=False,
                    headers={"Authorization": "Bearer " + connection.authorization.upstream_token},
                    timeout=aiohttp.ClientTimeout(total=CONNECT_SECONDS)) as upstream:
                # LiveKit validation is a small plain response. Never proxy upstream errors.
                body = await upstream.content.read(4097)
                if len(body) > 4096:
                    return Response("Invalid signalling response", status_code=502)
                if upstream.status == 200:
                    return Response("success", media_type="text/plain")
                status = upstream.status if upstream.status in (400, 401, 403, 404, 429) else 502
                return Response("Room connection validation failed", status_code=status)
        except HTTPException:
            raise
        except (aiohttp.ClientError, asyncio.TimeoutError):
            raise HTTPException(502, "Room signalling unavailable") from None
        finally:
            if connection is not None:
                connection.upstream_settled.set()

    async def _deny(self, websocket, status, message):
        if "websocket.http.response" in websocket.scope.get("extensions", {}):
            await websocket.send_denial_response(JSONResponse({"detail": message}, status_code=status))
        else:
            await websocket.close(code=1008)

    async def websocket(self, websocket: WebSocket):
        connection = None
        upstream = None
        accepted = False
        rejected_status = 500
        started_at = time.monotonic()
        self._observe(SignalEvent.ATTEMPT)
        if self._observer is not None and self._is_reconnect(websocket):
            self._observe(SignalEvent.RECONNECT)
        try:
            if websocket.url.path not in SIGNAL_PATHS:
                raise HTTPException(404, "Signalling endpoint not found")
            claims = self._credentials(websocket)
            connection = await self.authorize(claims, self._register(claims))
            if connection.is_validation or self._connections.get(connection.connection_id) is not connection:
                raise HTTPException(503, "Invalid signalling registration")
            # A new same-identity join cannot overtake an older in-flight handshake.
            previous = connection.previous
            while previous is not None:
                await previous.upstream_settled.wait()
                # A cancelled intermediate replacement may itself have been
                # waiting for an earlier handshake; never skip that ancestor.
                previous = previous.previous
            connection.previous = None
            if connection.revoked.is_set():
                raise HTTPException(403, "Room access revoked")
            # Do not cancel an in-flight upstream handshake on revocation: LiveKit
            # might still finish joining after a local HTTP cancellation. close_*
            # waits for its completion, then the caller can safely RemoveParticipant.
            async def connect():
                return await self._client().ws_connect(
                    UPSTREAM + websocket.url.path, params=self._params(websocket),
                    headers={"Authorization": "Bearer " + connection.authorization.upstream_token},
                    protocols=websocket.scope.get("subprotocols", []),
                    max_msg_size=MAX_FRAME_BYTES, heartbeat=20,
                    timeout=aiohttp.ClientWSTimeout(ws_receive=IDLE_SECONDS, ws_close=3))

            handshake = asyncio.create_task(connect())
            try:
                upstream = await asyncio.shield(handshake)
            except asyncio.CancelledError:
                connection.close_reason = "cancelled"
                connection.revoked.set()
                # Request cancellation is not proof that LiveKit abandoned join.
                # Keep ownership of the bounded handshake until it has settled.
                with suppress(Exception):
                    upstream = await asyncio.shield(handshake)
                raise
            connection.upstream_connected_at = time.time()
            connection.upstream_connected = True
            if connection.revoked.is_set() or not self.is_current(connection):
                raise HTTPException(403, "Room access revoked")
            await websocket.accept(subprotocol=upstream.protocol)
            accepted = True
            self._observe(SignalEvent.ACCEPTED, (time.monotonic() - started_at) * 1000)
            await self._bridge(websocket, upstream, connection)
        except HTTPException as error:
            rejected_status = error.status_code
            if not accepted:
                await self._deny(websocket, error.status_code, error.detail)
        except (aiohttp.ClientError, asyncio.TimeoutError):
            rejected_status = 502
            if not accepted:
                await self._deny(websocket, 502, "Room signalling unavailable")
        except WebSocketDisconnect:
            rejected_status = 499
            pass
        except asyncio.CancelledError:
            rejected_status = 499
            raise
        finally:
            if upstream is not None:
                with suppress(Exception):
                    await asyncio.wait_for(upstream.close(), timeout=4)
            if connection is not None:
                connection.upstream_settled.set()
                self._connections.pop(connection.connection_id, None)
                # A stale proxy must never clear a replacement connection.
                if self.is_current(connection):
                    self._current.pop((connection.room, connection.user_id), None)
                if self.disconnected is not None:
                    task = asyncio.create_task(self._notify_disconnected(connection))
                    self._callbacks.add(task)
                    task.add_done_callback(self._callbacks.discard)
            if accepted:
                with suppress(Exception):
                    await websocket.close(code=1008 if connection.revoked.is_set() else 1000)
                self._observe(SignalEvent.CLOSED)
            else:
                self._observe(SignalEvent.REJECTED, rejected_status)

    async def _notify_disconnected(self, connection):
        # DB/API failures are handled by the caller's durable reconciliation;
        # they must not produce a traceback containing URLs or JWTs here.
        with suppress(Exception):
            await self.disconnected(connection)

    async def _bridge(self, websocket, upstream, connection):
        async def client_to_server():
            while True:
                message = await asyncio.wait_for(websocket.receive(), IDLE_SECONDS)
                if connection.revoked.is_set() or message["type"] == "websocket.disconnect":
                    return
                data = message.get("bytes")
                if data is not None:
                    if len(data) > MAX_FRAME_BYTES:
                        await websocket.close(code=1009)
                        return
                    await asyncio.wait_for(upstream.send_bytes(data), WRITE_SECONDS)
                elif message.get("text") is not None:
                    data = message["text"]
                    if len(data.encode()) > MAX_FRAME_BYTES:
                        await websocket.close(code=1009)
                        return
                    await asyncio.wait_for(upstream.send_str(data), WRITE_SECONDS)

        async def server_to_client():
            async for message in upstream:
                if connection.revoked.is_set():
                    return
                if message.type == aiohttp.WSMsgType.BINARY:
                    await asyncio.wait_for(websocket.send_bytes(message.data), WRITE_SECONDS)
                    self._forwarded_response(connection, message.data, "binary")
                elif message.type == aiohttp.WSMsgType.TEXT:
                    await asyncio.wait_for(websocket.send_text(message.data), WRITE_SECONDS)
                    self._forwarded_response(connection, message.data, "json")
                elif message.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED,
                                      aiohttp.WSMsgType.ERROR):
                    return

        tasks = [asyncio.create_task(client_to_server()),
                 asyncio.create_task(server_to_client()),
                 asyncio.create_task(connection.revoked.wait())]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            # Retrieving every outcome also prevents unhandled exception logs
            # containing SDP, JWTs or internal signalling addresses.
            await asyncio.gather(*tasks, return_exceptions=True)
            if connection.revoked.is_set():
                await self._terminal_leave(websocket, connection)

    @staticmethod
    def _forwarded_response(connection, data, format):
        connection.signal_format = format
        try:
            response = (Parse(data, rtc_protocol.SignalResponse()) if format == "json"
                        else rtc_protocol.SignalResponse.FromString(data))
            if (response.WhichOneof("message") == "leave"
                    and response.leave.action == rtc_protocol.LeaveRequest.DISCONNECT):
                connection.terminal_leave_forwarded = True
        except (DecodeError, ParseError, TypeError, ValueError):
            # Transparent forwarding remains compatible with future signalling
            # envelopes. Never log a decode error containing signalling content.
            pass

    async def _terminal_leave(self, websocket, connection):
        """Tell SDKs a revocation is final before closing their signal socket.

        The SFU's RemoveParticipant happens after the upstream handshake barrier,
        so its leave packet otherwise arrives after this proxy has closed. A bare
        socket close triggers SDK auto-reconnect. Emit the official server packet
        from the gateway's already-authoritative revocation, without delaying SFU
        removal for an acknowledgement or allowing client signalling to resume.
        """
        if connection.terminal_leave_forwarded:
            return
        if connection.close_reason == "room_closed":
            reason = models.ROOM_DELETED
        elif connection.close_reason in ("identity_revoked", "session_revoked"):
            reason = models.PARTICIPANT_REMOVED
        else:
            # Replaced sockets, network loss, permission handshakes and process
            # shutdown retain the SDK's ordinary reconnect behavior.
            return
        response = rtc_protocol.SignalResponse(leave=rtc_protocol.LeaveRequest(
            can_reconnect=False, action=rtc_protocol.LeaveRequest.DISCONNECT, reason=reason))
        with suppress(Exception):
            if connection.signal_format == "json":
                await asyncio.wait_for(websocket.send_text(MessageToJson(response, indent=None)),
                                       TERMINAL_WRITE_SECONDS)
            else:
                await asyncio.wait_for(websocket.send_bytes(response.SerializeToString()),
                                       TERMINAL_WRITE_SECONDS)

    async def _close_matching(self, predicate, reason):
        connections = [connection for connection in self._connections.values() if predicate(connection)]
        # No awaits until every old connection has become incapable of forwarding.
        for connection in connections:
            connection.close_reason = reason
            connection.revoked.set()
        if connections:
            await asyncio.gather(*(connection.upstream_settled.wait() for connection in connections))
        return connections

    async def close_identity(self, room: str, user_id: str):
        return await self._close_matching(lambda connection: connection.room == room
                                          and connection.user_id == user_id, "identity_revoked")

    async def close_pending_identity(self, room: str, user_id: str):
        """Settle old-grant handshakes before applying an SFU permission change.

        Call under the authorizer's DB lock after persisting the new grants and
        before UpdateParticipant. Established sockets can remain connected; a
        pending old-grant socket is denied and its completed participant receives
        the authoritative permission update before another join can be authorized.
        """
        return await self._close_matching(lambda connection: connection.room == room
            and connection.user_id == user_id and not connection.upstream_connected,
            "permissions_changed")

    async def close_session(self, session_hash: str):
        return await self._close_matching(lambda connection: connection.session_hash == session_hash,
                                          "session_revoked")

    async def close_room(self, room: str):
        return await self._close_matching(lambda connection: connection.room == room, "room_closed")

    async def close(self):
        self._closed = True
        await self._close_matching(lambda connection: True, "shutdown")
        if self._callbacks:
            await asyncio.gather(*self._callbacks, return_exceptions=True)
        if self._session is not None:
            await self._session.close()
