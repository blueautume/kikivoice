"""Bounded, process-local laboratory diagnostics; never stores media or identities.

Connection counters have one-second resolution over the last five minutes.
Latency/quality percentiles use at most the latest 1,000 samples in that window.
Only the quality throttle retains a pseudonymous session digest, for ten seconds.
Everything is discarded on process restart and nothing is written to the database.
"""
from collections import Counter, OrderedDict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
import math
import re
import statistics
import time
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


WINDOW_SECONDS = 300
MAX_SAMPLES = 1000
MAX_SESSION_KEYS = 1000
QUALITY_INTERVAL_SECONDS = 10
QUALITY_VALUES = ("excellent", "good", "poor", "lost", "unknown")
CAPACITY_KEYS = ("activeRooms", "activeParticipants", "admittedParticipants",
                 "maxRooms", "maxParticipantsPerRoom", "maxParticipantsTotal")
REJECTION_STATUSES = (400, 401, 403, 404, 413, 422, 429, 499, 500, 502, 503)


class SignalEvent(str, Enum):
    ATTEMPT = "attempt"
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    RECONNECT = "reconnect"
    CLOSED = "closed"


class QualityReport(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    quality: Literal["unknown", "excellent", "good", "poor", "lost"]
    rtt_ms: float | None = Field(default=None, alias="rttMs", strict=True, ge=0, le=60_000)
    jitter_ms: float | None = Field(default=None, alias="jitterMs", strict=True, ge=0, le=10_000)
    packet_loss_percent: float | None = Field(default=None, alias="packetLossPercent",
                                             strict=True, ge=0, le=100)


@dataclass(frozen=True)
class _QualitySample:
    at: float
    quality: str
    rtt_ms: float | None
    jitter_ms: float | None
    packet_loss_percent: float | None


def _median(values):
    items = [value for value in values if value is not None]
    return round(statistics.median(items), 2) if items else None


class LabObservability:
    """Synchronous hooks for the application's single event loop / worker."""

    def __init__(self, *, clock=time.monotonic, wall_clock=time.time):
        self._clock = clock
        self._wall_clock = wall_clock
        self._signal_buckets = deque(maxlen=WINDOW_SECONDS)
        self._handshakes = deque(maxlen=MAX_SAMPLES)
        self._quality = deque(maxlen=MAX_SAMPLES)
        self._quality_sessions = OrderedDict()
        self._active_signals = 0

    def _prune(self, now):
        second = int(now)
        while self._signal_buckets and self._signal_buckets[0][0] <= second - WINDOW_SECONDS:
            self._signal_buckets.popleft()
        cutoff = now - WINDOW_SECONDS
        while self._handshakes and self._handshakes[0][0] <= cutoff:
            self._handshakes.popleft()
        while self._quality and self._quality[0].at <= cutoff:
            self._quality.popleft()
        while self._quality_sessions:
            key, at = next(iter(self._quality_sessions.items()))
            if at > now - QUALITY_INTERVAL_SECONDS:
                break
            self._quality_sessions.pop(key)

    def prune(self):
        """Expire idle samples without recording an event or reading a snapshot.

        The current active-signal gauge is deliberately independent of the
        rolling historical window and must survive expiration.
        """
        self._prune(self._clock())

    def record_signal(self, event: SignalEvent, value=None):
        """Accept only an event enum and an optional numeric duration/status."""
        event = SignalEvent(event)
        now = self._clock()
        self._prune(now)
        second = int(now)
        if not self._signal_buckets or self._signal_buckets[-1][0] != second:
            self._signal_buckets.append((second, Counter()))
        counts = self._signal_buckets[-1][1]
        if event == SignalEvent.CLOSED:
            self._active_signals = max(0, self._active_signals - 1)
        else:
            counts[event.value] += 1
        if event == SignalEvent.ACCEPTED:
            self._active_signals += 1
            if (isinstance(value, (float, int)) and not isinstance(value, bool)
                    and math.isfinite(value) and 0 <= value <= 120_000):
                self._handshakes.append((now, float(value)))
        elif event == SignalEvent.REJECTED:
            status = value if type(value) is int and value in REJECTION_STATUSES else 500
            counts[status] += 1

    def record_quality(self, session_hash, quality, *, rtt_ms=None, jitter_ms=None,
                       packet_loss_percent=None):
        # Validate even for a direct internal caller, before touching the throttle.
        if not isinstance(session_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", session_hash):
            raise ValueError("A pseudonymous session digest is required")
        payload = QualityReport(quality=quality, rttMs=rtt_ms, jitterMs=jitter_ms,
                                packetLossPercent=packet_loss_percent)
        now = self._clock()
        self._prune(now)
        if session_hash in self._quality_sessions:
            return False
        # Do not evict a recent key and accidentally let it bypass the interval.
        if len(self._quality_sessions) >= MAX_SESSION_KEYS:
            return False
        self._quality_sessions[session_hash] = now
        self._quality.append(_QualitySample(now, payload.quality, payload.rtt_ms,
                                            payload.jitter_ms, payload.packet_loss_percent))
        return True

    def snapshot(self, capacity=None):
        now = self._clock()
        self._prune(now)
        counts = Counter()
        for _, bucket in self._signal_buckets:
            counts.update(bucket)
        quality_counts = Counter(sample.quality for sample in self._quality)
        sample_count = len(self._quality)
        quality = {"samples": sample_count, **{key: quality_counts[key] for key in QUALITY_VALUES},
            "poorPercent": round(100 * (quality_counts["poor"] + quality_counts["lost"]) / sample_count, 2) if sample_count else None,
            "rttMsP50": _median(sample.rtt_ms for sample in self._quality),
            "jitterMsP50": _median(sample.jitter_ms for sample in self._quality),
            "packetLossPercentP50": _median(sample.packet_loss_percent for sample in self._quality)}
        connections = {"attempts": counts["attempt"], "accepted": counts["accepted"],
            "rejected": counts["rejected"], "reconnects": counts["reconnect"],
            "activeSignals": self._active_signals,
            "handshakeMsP50": _median(duration for _, duration in self._handshakes),
            "rejectedByStatus": {str(status): counts[status] for status in REJECTION_STATUSES}}
        source = capacity or {}
        capacity = {key: source.get(key) if type(source.get(key)) is int and source[key] >= 0 else None
                    for key in CAPACITY_KEYS}
        alerts = self._alerts(connections, quality, capacity)
        return {"serverTime": datetime.fromtimestamp(self._wall_clock(), timezone.utc).isoformat(),
                "windowSeconds": WINDOW_SECONDS, "capacity": capacity,
                "connections": connections, "quality": quality, "alerts": alerts}

    @staticmethod
    def _alerts(connections, quality, capacity):
        alerts = []
        def warn(code, message):
            alerts.append({"code": code, "level": "warning", "message": message})
        if connections["attempts"] >= 10 and connections["rejected"] / connections["attempts"] >= .2:
            warn("signal_rejections", "最近连接拒绝比例达到20%，请检查连接入口和入场权限。")
        if connections["accepted"] >= 5 and (connections["handshakeMsP50"] or 0) >= 3000:
            warn("slow_signal_handshake", "信令握手中位耗时达到3秒，请检查网络和服务器负载。")
        if quality["samples"] >= 5:
            if (quality["poorPercent"] or 0) >= 20:
                warn("poor_audio_quality", "最近较差或失联质量样本达到20%。")
            if (quality["rttMsP50"] or 0) >= 300:
                warn("high_audio_rtt", "最近往返时延中位数达到300毫秒。")
            if (quality["packetLossPercentP50"] or 0) >= 5:
                warn("audio_packet_loss", "最近丢包率中位数达到5%。")
        for count_key, limit_key, code, message in (
            ("activeRooms", "maxRooms", "room_capacity", "实验房间数量已达到配置上限的80%。"),
            ("admittedParticipants", "maxParticipantsTotal", "participant_capacity", "实验入场人数已达到配置上限的80%。")):
            count, limit = capacity[count_key], capacity[limit_key]
            if count is not None and limit and count / limit >= .8:
                warn(code, message)
        return alerts
