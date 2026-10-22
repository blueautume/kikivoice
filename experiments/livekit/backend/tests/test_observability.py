"""Privacy, memory bounds and real signalling lifecycle diagnostics."""
import asyncio
import base64
import gzip
import json
import threading

import aiohttp
from livekit.protocol import rtc as rtc_protocol
from pydantic import ValidationError
import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.observability import (LabObservability, MAX_SAMPLES, MAX_SESSION_KEYS,
                               QualityReport, SignalEvent)
from test_signal_gateway import Socket, setup, token
from conftest import headers, login
from conftest import FakeLiveKit
from app.main import create_app
from test_room_actions import act, setup_room, state


class Clock:
    at = 0.0

    def __call__(self):
        return self.at


def test_lifespan_timer_expires_idle_samples_without_reporting_or_querying(lab, monkeypatch):
    clock = Clock()
    metrics = LabObservability(clock=clock)
    metrics.record_signal(SignalEvent.ATTEMPT)
    metrics.record_signal(SignalEvent.ACCEPTED, 50)
    metrics.record_quality("a"*64, "good", rtt_ms=25)
    assert metrics._quality and metrics._quality_sessions and metrics._handshakes
    expired = threading.Event()
    public_prune = metrics.prune

    def observed_prune():
        public_prune()
        if clock.at >= 300:
            expired.set()

    monkeypatch.setattr(metrics, "prune", observed_prune)
    monkeypatch.setattr("app.main.LabObservability", lambda: metrics)
    app = create_app(lab.settings, FakeLiveKit(lab.settings))
    with TestClient(app):
        # No HTTP snapshot, signal event or quality report follows this advance.
        # The real one-second lifespan task must reclaim expired data itself.
        clock.at = 300
        assert expired.wait(3), "idle diagnostic retention timer did not run"
        assert not metrics._quality and not metrics._quality_sessions
        assert not metrics._handshakes and not metrics._signal_buckets
        assert metrics._active_signals == 1


def test_rolling_window_does_not_expire_current_signal_gauge():
    clock = Clock()
    metrics = LabObservability(clock=clock, wall_clock=lambda: 0)
    metrics.record_signal(SignalEvent.ATTEMPT)
    metrics.record_signal(SignalEvent.ACCEPTED, 20)
    metrics.record_signal(SignalEvent.RECONNECT)
    metrics.record_signal(SignalEvent.ATTEMPT)
    metrics.record_signal(SignalEvent.REJECTED, 403)
    result = metrics.snapshot()["connections"]
    assert result["attempts"] == 2 and result["accepted"] == 1
    assert result["rejected"] == 1 and result["rejectedByStatus"]["403"] == 1
    assert result["reconnects"] == 1 and result["activeSignals"] == 1
    assert result["handshakeMsP50"] == 20
    clock.at = 300
    result = metrics.snapshot()["connections"]
    assert result["attempts"] == 0 and result["handshakeMsP50"] is None
    assert result["activeSignals"] == 1
    metrics.record_signal(SignalEvent.CLOSED)
    assert metrics.snapshot()["connections"]["activeSignals"] == 0


def test_connection_counters_and_latency_storage_are_bounded():
    clock = Clock()
    metrics = LabObservability(clock=clock)
    for second in range(600):
        clock.at = second
        for _ in range(10):
            metrics.record_signal(SignalEvent.ATTEMPT)
            metrics.record_signal(SignalEvent.ACCEPTED, 100)
            metrics.record_signal(SignalEvent.CLOSED)
    assert len(metrics._signal_buckets) == 300
    assert len(metrics._handshakes) == MAX_SAMPLES
    assert metrics.snapshot()["connections"]["attempts"] == 3000
    assert all(len(bucket) <= 2 for _, bucket in metrics._signal_buckets)


@pytest.mark.parametrize("field,value", [
    ("rttMs", True), ("rttMs", "42"), ("rttMs", -1), ("rttMs", 60_001),
    ("rttMs", float("nan")), ("jitterMs", float("inf")), ("jitterMs", 10_001),
    ("packetLossPercent", -1), ("packetLossPercent", 101),
    ("quality", "secret-identity"), ("sessionHash", "a" * 64),
])
def test_quality_dto_rejects_unbounded_invalid_and_extra_values(field, value):
    with pytest.raises(ValidationError):
        QualityReport.model_validate({"quality": "good", field: value})


def test_quality_sampling_interval_and_no_identity_in_samples_or_output():
    clock = Clock()
    metrics = LabObservability(clock=clock)
    digest = "a" * 64
    assert metrics.record_quality(digest, "poor", rtt_ms=350, jitter_ms=12, packet_loss_percent=8)
    assert not metrics.record_quality(digest, "good")
    clock.at = 9.99
    assert not metrics.record_quality(digest, "good")
    clock.at = 10
    assert metrics.record_quality(digest, "good", rtt_ms=100, packet_loss_percent=2)
    result = metrics.snapshot({"activeRooms": 1, "secret": digest})
    assert result["quality"]["samples"] == 2
    assert result["quality"]["rttMsP50"] == 225
    assert result["quality"]["packetLossPercentP50"] == 5
    assert result["quality"]["poorPercent"] == 50
    assert digest not in json.dumps(result) and "secret" not in result["capacity"]
    assert all(digest not in repr(sample) for sample in metrics._quality)
    clock.at = 310
    assert metrics.snapshot()["quality"]["samples"] == 0
    assert not metrics._quality_sessions


def test_quality_session_limit_cannot_evict_recent_key_to_bypass_throttle():
    clock = Clock()
    metrics = LabObservability(clock=clock)
    for index in range(MAX_SESSION_KEYS):
        assert metrics.record_quality(f"{index:064x}", "unknown")
    assert not metrics.record_quality(f"{MAX_SESSION_KEYS:064x}", "poor")
    assert not metrics.record_quality(f"{0:064x}", "poor")
    assert len(metrics._quality_sessions) == MAX_SESSION_KEYS
    assert len(metrics._quality) == MAX_SAMPLES
    clock.at = 10
    assert metrics.record_quality(f"{MAX_SESSION_KEYS:064x}", "good")
    assert len(metrics._quality_sessions) == 1
    assert len(metrics._quality) == MAX_SAMPLES


def test_quality_internal_call_validation_and_capacity_alerts():
    clock = Clock()
    metrics = LabObservability(clock=clock)
    with pytest.raises(ValueError):
        metrics.record_quality("raw-business-token", "poor")
    with pytest.raises(ValidationError):
        metrics.record_quality("a" * 64, "good", rtt_ms=True)
    for index in range(5):
        metrics.record_quality(f"{index:064x}", "lost", rtt_ms=500, packet_loss_percent=10)
        metrics.record_signal(SignalEvent.ACCEPTED, 4000)
    for _ in range(10):
        metrics.record_signal(SignalEvent.ATTEMPT)
        metrics.record_signal(SignalEvent.REJECTED, 502)
    result = metrics.snapshot({"activeRooms": 4, "maxRooms": 4,
        "activeParticipants": None, "admittedParticipants": 60, "maxParticipantsTotal": 64})
    codes = {item["code"] for item in result["alerts"]}
    assert codes == {"signal_rejections", "slow_signal_handshake", "poor_audio_quality",
                     "high_audio_rtt", "audio_packet_loss", "room_capacity", "participant_capacity"}
    assert result["capacity"]["activeParticipants"] is None


@pytest.mark.parametrize("compression", [rtc_protocol.WrappedJoinRequest.NONE,
                                           rtc_protocol.WrappedJoinRequest.GZIP])
def test_real_gateway_metrics_record_v1_resume_only_after_accept(compression):
    async def exercise():
        gateway, authority, client = setup()
        metrics = LabObservability()
        gateway._observer = metrics.record_signal
        request = rtc_protocol.JoinRequest(reconnect=True).SerializeToString()
        if compression == rtc_protocol.WrappedJoinRequest.GZIP:
            request = gzip.compress(request)
        wrapped = rtc_protocol.WrappedJoinRequest(compression=compression, join_request=request)
        encoded = base64.urlsafe_b64encode(wrapped.SerializeToString()).decode()
        socket = Socket(token(), query={"join_request": encoded})
        client.release.clear()
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await client.started.wait()
        pending = metrics.snapshot()["connections"]
        assert pending["attempts"] == 1 and pending["accepted"] == 0
        assert pending["activeSignals"] == 0 and pending["reconnects"] == 1
        client.release.set()
        await socket.accepted.wait()
        accepted = metrics.snapshot()["connections"]
        assert accepted["accepted"] == 1 and accepted["activeSignals"] == 1
        await gateway.close_identity("room1", "alice")
        await task
        result = metrics.snapshot()["connections"]
        assert result["activeSignals"] == 0 and result["rejected"] == 0
        await gateway.close()
    asyncio.run(exercise())


def test_rejected_gateway_and_validate_have_distinct_metrics():
    async def exercise():
        gateway, authority, _ = setup()
        metrics = LabObservability()
        gateway._observer = metrics.record_signal
        request = Request({"type": "http", "method": "GET", "scheme": "https",
            "path": "/rtc/v1/validate", "query_string": b"",
            "headers": [(b"authorization", ("Bearer " + token()).encode())]})
        assert (await gateway.validate(request)).status_code == 200
        assert metrics.snapshot()["connections"]["attempts"] == 0
        authority.allowed = False
        await gateway.websocket(Socket(token(), query={"reconnect": "1"}).socket)
        result = metrics.snapshot()["connections"]
        assert result["attempts"] == 1 and result["rejectedByStatus"]["403"] == 1
        assert result["accepted"] == 0 and result["activeSignals"] == 0
        await gateway.close()
    asyncio.run(exercise())


def test_broken_observer_cannot_change_revocation_or_admission():
    async def exercise():
        gateway, _, _ = setup()
        def broken(event, value):
            raise RuntimeError("diagnostics unavailable")
        gateway._observer = broken
        socket = Socket(token(), query={"join_request": "invalid-base64!"})
        task = asyncio.create_task(gateway.websocket(socket.socket))
        await socket.accepted.wait()
        await gateway.close_identity("room1", "alice")
        await task
        assert not gateway._connections
        await gateway.close()
    asyncio.run(exercise())


def test_transport_rejection_emits_only_enum_and_numeric_status():
    async def exercise():
        gateway, _, client = setup()
        events = []
        gateway._observer = lambda event, value: events.append((event, value))
        async def failed(*args, **kwargs):
            raise aiohttp.ClientConnectionError("private upstream error body")
        client.ws_connect = failed
        await gateway.websocket(Socket(token()).socket)
        assert events == [(SignalEvent.ATTEMPT, None), (SignalEvent.REJECTED, 502)]
        assert all(isinstance(event, SignalEvent) and (value is None or type(value) in (int, float))
                   for event, value in events)
        await gateway.close()
    asyncio.run(exercise())


def test_optional_resume_metric_parser_has_bounded_decompression():
    gateway, _, _ = setup()
    compressed = gzip.compress(b"a" * (2 * 1024 * 1024))
    wrapped = rtc_protocol.WrappedJoinRequest(compression=rtc_protocol.WrappedJoinRequest.GZIP,
                                             join_request=compressed)
    query = base64.urlsafe_b64encode(wrapped.SerializeToString()).decode()
    assert gateway._is_reconnect(Socket(token(), query={"join_request": query}).socket) is False


def test_diagnostics_require_session_and_return_only_aggregates(lab):
    assert lab.client.get("/v1/diagnostics").status_code == 401
    room, accounts, tokens = setup_room(lab)
    owner, member = accounts
    state(lab, room, owner)  # Complete the SFU presence snapshot.
    response = lab.client.get("/v1/diagnostics", headers=headers(owner))
    assert response.status_code == 200
    result = response.json()
    assert result["windowSeconds"] == 300
    assert result["capacity"] == {"activeRooms": 1, "activeParticipants": 2,
        "admittedParticipants": 2, "maxRooms": 4, "maxParticipantsPerRoom": 32,
        "maxParticipantsTotal": 64}
    assert result["connections"]["attempts"] == 0
    assert result["quality"]["samples"] == 0
    serialized = json.dumps(result)
    for account in accounts:
        assert account["token"] not in serialized
        assert account["user"]["id"] not in serialized
    assert all(raw not in serialized for raw in tokens)
    assert lab.client.post("/v1/auth/logout", headers=headers(member)).status_code == 200
    assert lab.client.get("/v1/diagnostics", headers=headers(member)).status_code == 401


def test_quality_route_authorizes_current_members_and_samples_per_session(lab):
    room, (owner, member), _ = setup_room(lab)
    outsider = login(lab)
    route = f'/v1/rooms/{room["id"]}/quality'
    payload = {"quality": "good", "rttMs": 50, "jitterMs": 8, "packetLossPercent": 1}
    assert lab.client.post(route, json=payload).status_code == 401
    assert lab.client.post(route, json=payload, headers=headers(outsider)).status_code == 403
    first = lab.client.post(route, json=payload, headers=headers(member))
    duplicate = lab.client.post(route, json=payload, headers=headers(member))
    assert first.status_code == duplicate.status_code == 202
    assert first.json() == {"accepted": True} and duplicate.json() == {"accepted": False}
    assert lab.client.post(route, json={"quality": "unknown"}, headers=headers(owner)).json() == {"accepted": True}
    result = lab.client.get("/v1/diagnostics", headers=headers(owner)).json()["quality"]
    assert result["samples"] == 2 and result["good"] == result["unknown"] == 1
    assert result["rttMsP50"] == 50
    assert not any("quality" in row[0] for row in lab.app.state.db.execute("SELECT name FROM sqlite_master WHERE type='table'"))
    act(lab, room, owner, "kick", targetUserID=member["user"]["id"])
    assert lab.client.post(route, json=payload, headers=headers(member)).status_code == 403


@pytest.mark.parametrize("changes", [{"rttMs": True}, {"rttMs": "50"},
    {"jitterMs": 10_001}, {"packetLossPercent": 101}, {"userID": "injected-identity"}])
def test_quality_route_rejects_untrusted_fields_and_values(lab, changes):
    room, (owner, _), _ = setup_room(lab)
    response = lab.client.post(f'/v1/rooms/{room["id"]}/quality', headers=headers(owner),
                               json={"quality": "good", **changes})
    assert response.status_code == 422
    assert lab.client.get("/v1/diagnostics", headers=headers(owner)).json()["quality"]["samples"] == 0
