#!/usr/bin/env python3
"""Opt-in, disposable-account capacity probe for the isolated furby.top lab.

Requires livekit==1.1.21 and httpx==0.28.1. Uses the public business API,
approved seats, the signalling gateway, real Opus tracks and decoded audio.
It does not use LiveKit administrator credentials or a physical microphone.

Example (fixtures contain normal /v1/auth/lab responses, mode 0600):
  python capacity_probe.py --accounts-file /private/fixtures.json \
      --rooms 4 --participants 64 --publishers-per-room 8 --duration 120 \
      --output /private/capacity-64.json --keep-accounts

Without fixtures, lab logins are spaced >=6.2 seconds apart. Reuse fixtures
between stages with --keep-accounts; omit it on the final stage to delete ALL
provided disposable accounts. Never supply real user accounts. Native SDK
stdout/stderr are redirected to a separate private log; JSON results contain
no tokens, account/room IDs, SDP, candidate addresses or message bodies.
"""

from __future__ import annotations

import argparse
import array
import asyncio
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
import importlib.metadata
import json
import logging
import math
import os
from pathlib import Path
import random
import re
import resource
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import uuid

import certifi
import httpx
from livekit import rtc


BASE = Path(__file__).resolve().parents[1]
SERVER = "https://furby.top"
SAMPLE_RATE = 16000
FRAME_SAMPLES = 320  # 20 ms of real, continuously published synthetic audio.
JOIN_WAIT_SECONDS = 120
JOIN_SETTLE_SECONDS = 120


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))], 3)


def private_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".capacity-", suffix=".tmp", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        # Workers use file existence as a barrier. Never expose a partially
        # written plan/marker; atomic replacement also avoids following links.
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


class ApiFailure(Exception):
    def __init__(self, status):
        self.status = status
        super().__init__(f"HTTP {status}")


class ConnectWaitBudgetExceeded(TimeoutError):
    """The generator stopped waiting; the native SDK join is still alive."""


class UnsettledGeneratorJoin(RuntimeError):
    """A stage cannot be measured while an SDK join has no terminal outcome."""


class CoordinatorStopRequested(RuntimeError):
    pass


async def await_native_join(task, budget=JOIN_WAIT_SECONDS):
    """Limit caller wait without cancelling LiveKit's FFI handshake.

    Python RTC 1.1.21's Room.connect is not cancellation safe; upstream #784 /
    unmerged PR #813 describe the ReadyForRoomEventRequest panic. The task must
    remain strongly referenced and settle before disconnect / event-loop exit.
    """
    try:
        return await asyncio.wait_for(asyncio.shield(task), budget)
    except asyncio.TimeoutError:
        if task.done():
            # Preserve a genuine SDK TimeoutError/ConnectError (including the
            # exact exception class) instead of relabelling it as our budget.
            return await task
        raise ConnectWaitBudgetExceeded("generator join wait budget exceeded") from None


def safe_failure(error):
    """Return only known enums/status numbers, never the exception's raw text."""
    diagnostic = {"type": type(error).__name__}
    if isinstance(error, ApiFailure):
        diagnostic["httpStatus"] = error.status
        return diagnostic
    # SDK error strings can embed URLs/JWT/SDP. Read them only in memory to
    # recognize a small fixed vocabulary; do not persist any other substring.
    detail = str(error).lower()
    categories = []
    for pattern, label in ((r"timed?\s*out|timeout", "timeout"),
            (r"readyforroomevent", "native-ready-event-timeout"),
            (r"websocket|web socket|signal", "signalling"),
            (r"\bice\b|peer connection", "ice-or-peer-connection"),
            (r"resource temporarily unavailable|failed to spawn|too many open files|cannot allocate memory|no buffer space", "local-resource-exhaustion"),
            (r"unauthorized|not authorized|permission denied|forbidden", "authorization-denied"),
            (r"connection refused", "connection-refused"),
            (r"certificate|ssl|tls", "tls")):
        if re.search(pattern, detail):
            categories.append(label)
    statuses = sorted({int(value) for value in re.findall(r"(?:status(?:\s+code)?[\s:=]+|http[\s/]+)([45]\d\d)\b", detail)})
    if categories:
        diagnostic["categories"] = categories
    if statuses:
        diagnostic["httpStatuses"] = statuses
    return diagnostic


def process_runtime_usage():
    """Bounded local-only diagnostic; invoked via to_thread during ramp."""
    usage = resource.getrusage(resource.RUSAGE_SELF)
    snapshot = {"peakRSSMiB": round(usage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024), 2),
                "nativeAndPythonThreads": None, "openFileDescriptors": None,
                "hostLoad1m": round(os.getloadavg()[0], 2)}
    fd_path = "/dev/fd" if sys.platform == "darwin" else "/proc/self/fd"
    try:
        snapshot["openFileDescriptors"] = len(os.listdir(fd_path))
    except OSError:
        pass
    try:
        if sys.platform == "darwin":
            result = subprocess.run(["/bin/ps", "-M", "-p", str(os.getpid())],
                capture_output=True, text=True, timeout=1, check=False)
            if result.returncode == 0:
                snapshot["nativeAndPythonThreads"] = max(0, len(result.stdout.splitlines()) - 1)
        else:
            snapshot["nativeAndPythonThreads"] = len(os.listdir("/proc/self/task"))
    except (OSError, subprocess.TimeoutExpired):
        pass
    return snapshot


def make_assignments(clients, owners, worker_size):
    """Connect every pre-created room's owner before the remaining population.

    Room creation starts the normal 120-second pending-admission grace. Give
    each owner a one-client shard at the front, so a slow full-room ramp cannot
    let later rooms expire before their owner ever reaches the real SDK.
    Existing global client indices and seat/publisher roles are preserved.
    """
    by_index = {client["index"]: client for client in clients}
    if len(by_index) != len(clients) or any(owner not in by_index for owner in owners):
        raise ValueError("invalid capacity owner assignment")
    owner_set = set(owners)
    assignments = [[by_index[owner]] for owner in owners]
    remaining = [client for client in clients if client["index"] not in owner_set]
    assignments.extend(remaining[start:start + worker_size]
                       for start in range(0, len(remaining), worker_size))
    return assignments


@dataclass
class StreamSample:
    frames: int = 0
    samples: int = 0
    nonzero_frames: int = 0
    max_gap: float = 0.0
    gaps_over_250ms: int = 0
    last_at: float | None = None
    ever_received: bool = False

    def observe(self, frame, now, measuring):
        self.ever_received = True
        if not measuring:
            return
        self.frames += 1
        self.samples += frame.samples_per_channel
        # Sampling the decoded frame avoids Python summing millions of PCM
        # samples per second. This only tests audible synthetic-tone presence.
        data = frame.data
        if any(abs(int(data[index])) > 150 for index in range(0, len(data), max(1, len(data) // 24))):
            self.nonzero_frames += 1
        if self.last_at is not None:
            gap = now - self.last_at
            self.max_gap = max(self.max_gap, gap)
            self.gaps_over_250ms += gap > .250
        self.last_at = now


@dataclass
class ClientSample:
    index: int
    room_index: int
    publisher: bool
    room: object | None = None
    connected: bool = False
    connect_ms: float | None = None
    failure: str | None = None
    failure_stage: str | None = None
    failure_diagnostic: dict | None = None
    join_task: asyncio.Task | None = None
    join_settlement: str | None = None
    late_join_failure: dict | None = None
    streams: dict[str, StreamSample] = field(default_factory=dict)
    source: object | None = None
    published: bool = False
    capture_frames: int = 0
    publish_stalls: int = 0
    max_capture_ms: float = 0.0
    unexpected_disconnects: int = 0
    reconnecting: int = 0
    reconnected: int = 0
    subscription_failures: int = 0
    chat_hints: int = 0
    message_cursor: int = 0
    http: Counter = field(default_factory=Counter)
    rtc_baseline: dict = field(default_factory=dict)
    rtc_final: dict = field(default_factory=dict)
    transport: list = field(default_factory=list)


class Probe:
    def __init__(self, args, emit):
        self.args = args
        self.emit = emit
        self.run_label = uuid.uuid4().hex[:8]
        self.accounts = []
        self.room_ids = []
        self.owners = []
        self.clients = []
        self.tasks = []
        self.measuring = False
        self.cleaning = False
        self.started_at = None
        self.measured_seconds = 0.0
        self.http_counts = Counter()
        self.http_latency = {}
        self.generator = []
        self.cleanup_failures = []
        self.failure = None
        self.warmup_complete = False
        self.connect_gate = asyncio.Semaphore(args.connect_concurrency)
        self.http_gate = asyncio.Semaphore(args.http_concurrency)
        self.http = None

    def spawn(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.append(task)
        return task

    async def call(self, method, path, account=None, label="setup", client=None, **kwargs):
        headers = {"Authorization": "Bearer " + account["token"]} if account else {}
        started = time.monotonic()
        status = "transport-error"
        try:
            async with self.http_gate:
                response = await self.http.request(method, path, headers=headers, **kwargs)
            status = str(response.status_code)
            if not response.is_success:
                raise ApiFailure(response.status_code)
            return response.json() if response.content else {}
        finally:
            if self.measuring:
                key = label + ":" + status
                self.http_counts[key] += 1
                self.http_latency.setdefault(label, []).append((time.monotonic() - started) * 1000)
                if client is not None:
                    client.http[key] += 1

    async def make_accounts(self):
        if self.args.accounts_file:
            path = Path(self.args.accounts_file)
            if stat.S_IMODE(path.stat().st_mode) & 0o077:
                raise ValueError("accounts-file must have mode 0600 or stricter")
            loaded = json.loads(path.read_text())
            accounts = loaded["accounts"] if isinstance(loaded, dict) else loaded
            if len(accounts) < self.args.participants:
                raise ValueError("accounts-file contains too few disposable accounts")
            for account in accounts:
                if not account.get("token") or not all(account.get("user", {}).get(key) for key in ("id", "sdkUserID")):
                    raise ValueError("accounts-file must contain normal lab login responses")
            if len({account["user"]["id"] for account in accounts}) != len(accounts):
                raise ValueError("accounts-file contains duplicate identities")
            self.accounts = accounts
            return
        code_path = Path.home() / ".config/kikitalk-livekit-lab/lab-access-code"
        code = code_path.read_text().strip()
        legal = json.loads((BASE / "shared/legal_documents.json").read_text())
        consent = {key: legal[key] for key in ("privacyVersion", "termsVersion", "documentHash")}
        consent.update(accepted=True, adultConfirmed=True)
        last_login = 0.0
        for index in range(self.args.participants):
            await asyncio.sleep(max(0, last_login + 6.2 - time.monotonic()))
            last_login = time.monotonic()
            account = await self.call("POST", "/v1/auth/lab", json={
                "name": f"承载验收{self.run_label}{index}", "accessCode": code, "legalConsent": consent})
            self.accounts.append(account)
            if (index + 1) % 8 == 0:
                self.emit({"phase": "accounts", "created": index + 1})

    async def receive(self, sample, track, stream_key):
        stream = rtc.AudioStream(track, sample_rate=SAMPLE_RATE, num_channels=1,
                                 frame_size_ms=self.args.audio_frame_ms, capacity=10)
        observation = sample.streams.setdefault(stream_key, StreamSample())
        try:
            async for event in stream:
                observation.observe(event.frame, time.monotonic(), self.measuring)
        finally:
            await stream.aclose()

    def attach(self, sample):
        room = sample.room

        @room.on("track_subscribed")
        def on_subscribed(track, publication, _participant):
            if track.kind == rtc.TrackKind.KIND_AUDIO:
                self.spawn(self.receive(sample, track, publication.sid))

        @room.on("track_subscription_failed")
        def on_subscription_failed(*_args):
            sample.subscription_failures += 1

        @room.on("disconnected")
        def on_disconnected(*_args):
            if not self.cleaning:
                sample.unexpected_disconnects += 1

        @room.on("reconnecting")
        def on_reconnecting(*_args):
            sample.reconnecting += 1

        @room.on("reconnected")
        def on_reconnected(*_args):
            sample.reconnected += 1

        @room.on("data_received")
        def on_data(packet):
            if packet.topic == "kiki.chat.sync" and self.measuring:
                sample.chat_hints += 1

    async def connect(self, sample):
        account = self.accounts[sample.index]
        room_id = self.room_ids[sample.room_index]
        async with self.connect_gate:
            started = time.monotonic()
            stage = "business-grant"
            try:
                grant = await self.call("POST", f"/v1/rooms/{room_id}/token", account)
                # Public HTTPS signalling gateway only, never a direct SFU URL.
                if grant["serverURL"].rstrip("/") != "wss://furby.top":
                    raise ValueError("unexpected signalling server")
                sample.room = rtc.Room()
                self.attach(sample)
                stage = "rtc-connect"
                config = rtc.RtcConfiguration(ice_transport_type=rtc.IceTransportType.TRANSPORT_RELAY) if self.args.relay_only else None
                # This task is deliberately NOT in self.tasks: normal media
                # cancellation must never cancel an in-flight native join.
                sample.join_task = asyncio.create_task(sample.room.connect(grant["serverURL"], grant["participantToken"],
                    rtc.RoomOptions(auto_subscribe=True, single_peer_connection=False, rtc_config=config)))
                await await_native_join(sample.join_task)
                sample.join_settlement = "completed"
                sample.connected = True
                sample.connect_ms = (time.monotonic() - started) * 1000
                if sample.publisher and sample.index != self.owners[sample.room_index]:
                    stage = "seat-request"
                    await self.call("POST", f"/v1/rooms/{room_id}/actions", account, json={"action": "request_seat"})
                    owner = self.accounts[self.owners[sample.room_index]]
                    stage = "seat-approve"
                    await self.call("POST", f"/v1/rooms/{room_id}/actions", owner,
                        json={"action": "approve_request", "targetUserID": account["user"]["id"]})
                if sample.publisher:
                    stage = "permission-update"
                    async with asyncio.timeout(15):
                        while not sample.room.local_participant.permissions.can_publish:
                            await asyncio.sleep(.1)
                    sample.source = rtc.AudioSource(SAMPLE_RATE, 1, queue_size_ms=200)
                    stage = "audio-publish"
                    track = rtc.LocalAudioTrack.create_audio_track("synthetic-capacity-tone", sample.source)
                    options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE,
                                                      dtx=False, red=True)
                    # AudioEncoding is nested in the protobuf but not exported
                    # as rtc.AudioEncoding by Python SDK 1.1.21.
                    options.audio_encoding.max_bitrate = self.args.audio_bitrate
                    await asyncio.wait_for(sample.room.local_participant.publish_track(track, options), 25)
                    sample.published = True
                    self.spawn(self.publish(sample))
            except Exception as error:
                sample.failure = f"HTTP {error.status}" if isinstance(error, ApiFailure) else type(error).__name__
                sample.failure_stage = "rtc-connect-wait-budget" if isinstance(error, ConnectWaitBudgetExceeded) else stage
                sample.failure_diagnostic = safe_failure(error)
                if sample.join_task is not None:
                    sample.join_settlement = "pending" if not sample.join_task.done() else "failed" if sample.join_task.exception() else "completed"

    async def publish(self, sample):
        frequency = 440 + (sample.index % 8) * 37
        # A reusable 1-second periodic waveform avoids per-frame Python DSP work.
        tone = array.array("h", (int(5000 * math.sin(2 * math.pi * frequency * n / SAMPLE_RATE))
                                for n in range(SAMPLE_RATE)))
        frames = [tone[start:start + FRAME_SAMPLES].tobytes()
                  for start in range(0, SAMPLE_RATE, FRAME_SAMPLES)]
        index = 0
        while True:
            started = time.monotonic()
            await sample.source.capture_frame(rtc.AudioFrame(frames[index % len(frames)], SAMPLE_RATE, 1, FRAME_SAMPLES))
            elapsed = (time.monotonic() - started) * 1000
            if self.measuring:
                sample.capture_frames += 1
                sample.max_capture_ms = max(sample.max_capture_ms, elapsed)
                sample.publish_stalls += elapsed > 100
            index += 1

    async def poll(self, sample):
        account = self.accounts[sample.index]
        room_id = self.room_ids[sample.room_index]
        deadlines = {"state": time.monotonic() + random.uniform(0, self.args.state_interval),
                     "chat": time.monotonic() + random.uniform(0, self.args.chat_interval),
                     "send": time.monotonic() + random.uniform(1, 45),
                     "quality": time.monotonic() + random.uniform(1, 12)}
        while True:
            now = time.monotonic()
            for kind in deadlines:
                if deadlines[kind] > now:
                    continue
                interval = {"state": self.args.state_interval, "chat": self.args.chat_interval,
                            "send": 35, "quality": 11}[kind]
                deadlines[kind] = now + interval * random.uniform(.91, 1.09)
                try:
                    if kind == "state":
                        await self.call("GET", f"/v1/rooms/{room_id}/state", account, label="state", client=sample)
                    elif kind == "chat":
                        page = await self.call("GET", f"/v1/rooms/{room_id}/messages", account,
                            label="chat", client=sample, params={"afterSeq": sample.message_cursor})
                        sample.message_cursor = page["nextAfterSeq"]
                    elif kind == "send":
                        await self.call("POST", f"/v1/rooms/{room_id}/messages", account,
                            label="send", client=sample,
                            json={"clientMessageID": str(uuid.uuid4()), "text": "合成承载验收消息"})
                    else:
                        # Unknown is intentional: do not invent client measurements.
                        await self.call("POST", f"/v1/rooms/{room_id}/quality", account,
                            label="quality", client=sample, json={"quality": "unknown"})
                except Exception:
                    # Counts already retain the exact HTTP status. Do not print
                    # errors that may embed an authenticated URL or response body.
                    pass
            await asyncio.sleep(.05)

    async def monitor_generator(self):
        previous_wall = time.monotonic()
        usage = resource.getrusage(resource.RUSAGE_SELF)
        previous_cpu = usage.ru_utime + usage.ru_stime
        while True:
            await asyncio.sleep(1)
            now = time.monotonic()
            usage = resource.getrusage(resource.RUSAGE_SELF)
            cpu = usage.ru_utime + usage.ru_stime
            lag_ms = max(0, now - previous_wall - 1) * 1000
            peak_rss_mb = usage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024)
            self.generator.append({"seconds": round(now - self.started_at, 2),
                "processCPUPercentOneCore": round(100 * (cpu - previous_cpu) / (now - previous_wall), 2),
                "eventLoopLagMs": round(lag_ms, 3), "peakRSSMiB": round(peak_rss_mb, 2)})
            previous_wall, previous_cpu = now, cpu

    async def rtc_snapshot(self, sample):
        snapshot = {"packetsReceived": 0, "packetsLost": 0, "bytesReceived": 0, "bytesSent": 0, "jitterMsMax": 0.0}
        if sample.room is None or not sample.connected:
            return snapshot
        try:
            async with self.connect_gate:
                report = await asyncio.wait_for(sample.room.get_rtc_stats(), 10)
            records = list(report.subscriber_stats) + list(report.publisher_stats)
            candidates = {record.local_candidate.rtc.id: record.local_candidate.candidate
                          for record in records if record.HasField("local_candidate")}
            transports = []
            for record in records:
                if record.HasField("inbound_rtp") and record.inbound_rtp.stream.kind == "audio":
                    received = record.inbound_rtp.received
                    snapshot["packetsReceived"] += received.packets_received
                    snapshot["packetsLost"] += max(0, received.packets_lost)
                    snapshot["jitterMsMax"] = max(snapshot["jitterMsMax"], received.jitter * 1000)
                if record.HasField("transport"):
                    snapshot["bytesReceived"] += record.transport.transport.bytes_received
                    snapshot["bytesSent"] += record.transport.transport.bytes_sent
                if record.HasField("candidate_pair"):
                    pair = record.candidate_pair.candidate_pair
                    if pair.nominated and pair.bytes_received:
                        candidate = candidates.get(pair.local_candidate_id)
                        if candidate is not None:
                            descriptor = candidate.DESCRIPTOR.fields_by_name["candidate_type"].enum_type
                            relay_protocol = "UNKNOWN"
                            relay_field = candidate.DESCRIPTOR.fields_by_name.get("relay_protocol")
                            if relay_field is not None and candidate.HasField("relay_protocol"):
                                relay_value = relay_field.enum_type.values_by_number.get(candidate.relay_protocol)
                                if relay_value is not None:
                                    relay_protocol = relay_value.name
                            transports.append({"candidateType": descriptor.values_by_number[candidate.candidate_type].name,
                                               "protocol": candidate.protocol, "relayProtocol": relay_protocol})
            sample.transport = transports
        except Exception:
            snapshot["unavailable"] = True
        return snapshot

    async def cleanup(self):
        self.cleaning = True
        self.measuring = False
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        # No timeout/cancel here: cancelling connect can strand the native
        # ready handshake and kill this process. An isolated worker's parent
        # owns the final OS process deadline if the SDK never returns.
        for sample in self.clients:
            if sample.join_task is None:
                continue
            try:
                await asyncio.shield(sample.join_task)
                sample.join_settlement = "completed"
            except Exception as error:
                sample.join_settlement = "failed"
                sample.late_join_failure = safe_failure(error)
        for index, room_id in enumerate(self.room_ids):
            try:
                await self.call("PATCH", f"/v1/rooms/{room_id}", self.accounts[self.owners[index]], json={"status": "ended"})
            except Exception:
                self.cleanup_failures.append({"kind": "room", "id": room_id})
        for sample in self.clients:
            if sample.room is not None:
                try:
                    await asyncio.wait_for(sample.room.disconnect(), 10)
                except Exception:
                    pass
            if sample.source is not None:
                try:
                    await sample.source.aclose()
                except Exception:
                    pass
        if not self.args.keep_accounts:
            for account in self.accounts:
                try:
                    await self.call("DELETE", "/v1/account", account)
                except ApiFailure as error:
                    if error.status != 401:
                        self.cleanup_failures.append({"kind": "account", "id": account["user"]["id"]})
                except Exception:
                    self.cleanup_failures.append({"kind": "account", "id": account["user"]["id"]})
        if self.cleanup_failures:
            private_json(str(self.args.output) + ".cleanup.json", {"pending": self.cleanup_failures})

    async def run(self):
        self.started_at = time.monotonic()
        context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or certifi.where())
        limits = httpx.Limits(max_connections=self.args.http_concurrency, max_keepalive_connections=self.args.http_concurrency)
        async with httpx.AsyncClient(base_url=SERVER, verify=context, timeout=25, trust_env=False, limits=limits) as self.http:
            try:
                health = await self.call("GET", "/health")
                if not health.get("rtcConfigured"):
                    raise ValueError("RTC health is unavailable")
                await self.make_accounts()
                cursor = 0
                for room_index in range(self.args.rooms):
                    count = self.args.participants // self.args.rooms + (room_index < self.args.participants % self.args.rooms)
                    self.owners.append(cursor)
                    room = await self.call("POST", "/v1/rooms", self.accounts[cursor], json={
                        "title": f"容量验收{self.run_label}-{room_index + 1}", "category": "闲聊", "isLive": False, "theme": 0})
                    self.room_ids.append(room["id"])
                    for offset in range(count):
                        self.clients.append(ClientSample(cursor + offset, room_index, offset < self.args.publishers_per_room))
                    cursor += count
                self.emit({"phase": "connecting", "participants": self.args.participants, "rooms": self.args.rooms})
                await asyncio.gather(*(self.connect(sample) for sample in self.clients))
                expected_publishers = sum(sample.publisher for sample in self.clients)
                self.emit({"phase": "warming", "connected": sum(sample.connected for sample in self.clients),
                           "publishers": sum(sample.published for sample in self.clients), "expectedPublishers": expected_publishers})
                deadline = time.monotonic() + self.args.warmup
                while time.monotonic() < deadline:
                    if all(len(sample.streams) == self.expected_streams(sample) and
                           all(stream.ever_received for stream in sample.streams.values())
                           for sample in self.clients) and all(sample.failure is None for sample in self.clients):
                        self.warmup_complete = True
                        break
                    await asyncio.sleep(.25)
                baselines = await asyncio.gather(*(self.rtc_snapshot(sample) for sample in self.clients))
                for sample, baseline in zip(self.clients, baselines):
                    sample.rtc_baseline = baseline
                measure_started = time.monotonic()
                self.measuring = True
                self.spawn(self.monitor_generator())
                for sample in self.clients:
                    if sample.connected:
                        self.spawn(self.poll(sample))
                self.emit({"phase": "measuring", "durationSeconds": self.args.duration,
                           "allSubscriptionsReceivedAudio": self.warmup_complete})
                await asyncio.sleep(self.args.duration)
                self.measured_seconds = time.monotonic() - measure_started
                self.measuring = False
                snapshots = await asyncio.gather(*(self.rtc_snapshot(sample) for sample in self.clients))
                for sample, snapshot in zip(self.clients, snapshots):
                    sample.rtc_final = snapshot
            except BaseException as error:
                self.failure = f"HTTP {error.status}" if isinstance(error, ApiFailure) else type(error).__name__
            finally:
                await self.cleanup()
        result = self.result()
        private_json(self.args.output, result)
        self.emit({"phase": "complete", "acceptancePassed": result["acceptancePassed"],
                   "generatorSaturated": result["generator"]["saturated"],
                   "connected": result["connections"]["connected"], "attempted": self.args.participants,
                   "cleanupPending": len(self.cleanup_failures), "resultFile": str(Path(self.args.output).resolve())})
        return 0 if result["acceptancePassed"] else 2

    def expected_streams(self, sample):
        if hasattr(self, "room_publisher_counts"):
            return self.room_publisher_counts[sample.room_index] - int(sample.publisher)
        return sum(other.publisher for other in self.clients if other.room_index == sample.room_index) - int(sample.publisher)

    def result(self):
        clients = []
        for sample in self.clients:
            seconds = [stream.samples / SAMPLE_RATE for stream in sample.streams.values()]
            coverage = min(seconds, default=self.measured_seconds if self.expected_streams(sample) == 0 else 0) / max(1, self.measured_seconds)
            nonzero = [stream.nonzero_frames / max(1, stream.frames) for stream in sample.streams.values()]
            delta = {key: max(0, sample.rtc_final.get(key, 0) - sample.rtc_baseline.get(key, 0))
                     for key in ("packetsReceived", "packetsLost", "bytesReceived", "bytesSent")}
            delta["jitterMsMaxAtEnd"] = round(sample.rtc_final.get("jitterMsMax", 0), 3)
            delta["statsAvailable"] = bool(sample.rtc_final and sample.rtc_baseline and
                not sample.rtc_final.get("unavailable") and not sample.rtc_baseline.get("unavailable"))
            delta["packetLossPercent"] = round(100 * delta["packetsLost"] /
                max(1, delta["packetsReceived"] + delta["packetsLost"]), 4)
            clients.append({"client": sample.index + 1, "room": sample.room_index + 1,
                "publisher": sample.publisher, "connected": sample.connected, "failure": sample.failure,
                "failureStage": sample.failure_stage, "failureDiagnostic": sample.failure_diagnostic,
                "joinSettlement": sample.join_settlement, "lateJoinFailure": sample.late_join_failure,
                "connectMs": round(sample.connect_ms, 2) if sample.connect_ms is not None else None,
                "published": sample.published, "expectedSubscriptions": self.expected_streams(sample),
                "subscriptions": len(sample.streams), "decodedFrames": sum(stream.frames for stream in sample.streams.values()),
                "nonzeroFrames": sum(stream.nonzero_frames for stream in sample.streams.values()),
                "minimumStreamCoveragePercent": round(100 * coverage, 2),
                "minimumStreamNonzeroFramePercent": round(100 * min(nonzero, default=1 if self.expected_streams(sample) == 0 else 0), 2),
                "maximumFrameGapMs": round(1000 * max((stream.max_gap for stream in sample.streams.values()), default=0), 3),
                "frameGapsOver250ms": sum(stream.gaps_over_250ms for stream in sample.streams.values()),
                "captureFrames": sample.capture_frames, "captureStallsOver100ms": sample.publish_stalls,
                "maxCaptureMs": round(sample.max_capture_ms, 3), "unexpectedDisconnects": sample.unexpected_disconnects,
                "reconnecting": sample.reconnecting, "reconnected": sample.reconnected,
                "subscriptionFailures": sample.subscription_failures, "chatSyncHints": sample.chat_hints,
                "http": dict(sample.http), "rtc": delta, "selectedTransports": sample.transport})
        lags = [sample["eventLoopLagMs"] for sample in self.generator]
        cpus = [sample["processCPUPercentOneCore"] for sample in self.generator]
        saturated = (percentile(lags, .95) or 0) > 100 or (percentile(cpus, .95) or 0) > 80 * (os.cpu_count() or 1)
        http_total = sum(self.http_counts.values())
        http_errors = sum(count for key, count in self.http_counts.items() if not key.rsplit(":", 1)[-1].startswith("2"))
        checks = {
            "setupCompleted": self.failure is None and len(clients) == self.args.participants,
            "allClientsConnected": len(clients) == self.args.participants and all(item["connected"] for item in clients),
            "allPublishersActuallyPublished": bool(clients) and all(item["published"] for item in clients if item["publisher"]),
            "allSubscriptionsReceivedAudio": self.warmup_complete,
            "everyStreamAtLeast95PercentDecodedDuration": bool(clients) and all(item["minimumStreamCoveragePercent"] >= 95 for item in clients),
            "everyStreamAtLeast95PercentNonzeroFrames": bool(clients) and all(item["minimumStreamNonzeroFramePercent"] >= 95 for item in clients),
            "noAudioGapOver500ms": bool(clients) and all(item["maximumFrameGapMs"] <= 500 for item in clients),
            "noUnexpectedDisconnects": all(item["unexpectedDisconnects"] == 0 and item["subscriptionFailures"] == 0 for item in clients),
            "httpSuccessAtLeast99Percent": http_total > 0 and http_errors / http_total <= .01,
            "noHTTP429": not any(key.endswith(":429") for key in self.http_counts),
            "generatorNotSaturated": not saturated,
            "cleanupSucceeded": not self.cleanup_failures,
        }
        if self.args.relay_only:
            checks["allSelectedCandidatesRelay"] = bool(clients) and all(item["selectedTransports"] and all(
                "RELAY" in transport["candidateType"] for transport in item["selectedTransports"]) for item in clients)
        rooms = []
        for room_index in range(self.args.rooms):
            group = [item for item in clients if item["room"] == room_index + 1]
            rooms.append({"room": room_index + 1, "participants": len(group),
                "connected": sum(item["connected"] for item in group), "publishers": sum(item["published"] for item in group),
                "subscriptions": sum(item["subscriptions"] for item in group),
                "decodedFrames": sum(item["decodedFrames"] for item in group),
                "minimumStreamCoveragePercent": min((item["minimumStreamCoveragePercent"] for item in group), default=0)})
        return {"schemaVersion": 1, "recordedAt": datetime.now(timezone.utc).isoformat(), "server": SERVER,
            "scope": "single-host laboratory acceptance; not a production capacity or SLA guarantee",
            "sdkVersion": importlib.metadata.version("livekit"), "syntheticAudio": True,
            "requested": {"participants": self.args.participants, "rooms": self.args.rooms,
                "publishersPerRoom": self.args.publishers_per_room, "durationSeconds": self.args.duration,
                "audioTargetBitrate": self.args.audio_bitrate, "audioSampleRate": SAMPLE_RATE,
                "decodedAudioFrameMilliseconds": self.args.audio_frame_ms,
                "continuousPublish": True, "dtx": False, "red": True, "relayOnly": self.args.relay_only,
                "statePollSeconds": self.args.state_interval, "chatPollSeconds": self.args.chat_interval,
                "qualityPollSeconds": "10-12, unknown rather than fabricated measurements",
                "messageSendSeconds": "about 35 per user, independently jittered"},
            "measuredSeconds": round(self.measured_seconds, 3), "failure": self.failure,
            "connections": {"attempted": self.args.participants, "connected": sum(item["connected"] for item in clients),
                "failed": sum(not item["connected"] for item in clients),
                "connectMsP50": percentile([item["connectMs"] for item in clients if item["connectMs"] is not None], .5),
                "connectMsP95": percentile([item["connectMs"] for item in clients if item["connectMs"] is not None], .95)},
            "http": {"counts": dict(self.http_counts), "successPercent": round(100 * (http_total - http_errors) / max(1, http_total), 3),
                "latencyMs": {key: {"p50": percentile(values, .5), "p95": percentile(values, .95), "max": round(max(values), 3)}
                              for key, values in self.http_latency.items()}},
            "rooms": rooms, "clients": clients,
            "generator": {"logicalCPUs": os.cpu_count(), "processCPUPercentUsesOneCore100": True,
                "cpuPercentP95": percentile(cpus, .95), "loopLagMsP95": percentile(lags, .95),
                "loopLagMsMax": max(lags, default=None), "peakRSSMiB": max((item["peakRSSMiB"] for item in self.generator), default=None),
                "saturated": saturated, "saturationThreshold": "loop lag p95 >100ms or process CPU p95 >80% of all logical CPUs",
                "samples": self.generator},
            "checks": checks, "acceptancePassed": all(checks.values()),
            "thresholds": {"minimumPerStreamDecodedDurationPercent": 95, "minimumPerStreamNonzeroFramePercent": 95,
                "maximumGapMs": 500, "minimumHTTPSuccessPercent": 99, "HTTP429Allowed": False},
            "accountsRetainedForNextStage": self.args.keep_accounts, "cleanupPendingCount": len(self.cleanup_failures)}


class WorkerProbe(Probe):
    """One native FFI runtime, at most --worker-size normal RTC clients.

    The coordinator owns all room/account cleanup. Workers share the real room
    plan, including the global publisher count; a shard must never mistake only
    its own publishers for the tracks that every listener should receive.
    """

    async def cleanup(self):
        room_ids = self.room_ids
        retained = self.args.keep_accounts
        self.room_ids = []
        self.args.keep_accounts = True
        if hasattr(self, "worker_control"):
            private_json(self.worker_control / f"worker-{self.args.worker_index}.cleanup.json",
                {"pendingJoinCount": sum(sample.join_task is not None and not sample.join_task.done()
                                         for sample in self.clients)})
        try:
            await super().cleanup()
        finally:
            self.room_ids = room_ids
            self.args.keep_accounts = retained

    def result(self):
        total = self.args.participants
        self.args.participants = len(self.clients)
        try:
            result = super().result()
        finally:
            self.args.participants = total
        result["workerIndex"] = self.args.worker_index
        # Sanitized samples allow the coordinator to compute exact aggregate
        # percentiles, rather than incorrectly averaging shard percentiles.
        result["_httpLatencySamplesMs"] = self.http_latency
        return result

    async def run(self):
        plan_path = self.args.worker_plan
        if stat.S_IMODE(plan_path.stat().st_mode) & 0o077:
            raise ValueError("private worker plan must have mode 0600")
        plan = json.loads(plan_path.read_text())
        if plan.get("schemaVersion") != 1 or plan.get("server") != SERVER:
            raise ValueError("unexpected worker plan")
        for key, value in plan["options"].items():
            setattr(self.args, key, value)
        self.accounts, self.room_ids, self.owners = plan["accounts"], plan["roomIDs"], plan["owners"]
        self.room_publisher_counts = plan["roomPublisherCounts"]
        self.clients = [ClientSample(**item) for item in plan["assignments"][self.args.worker_index]]
        self.connect_gate = asyncio.Semaphore(1)
        control = plan_path.parent
        self.worker_control = control
        ready_path = control / f"worker-{self.args.worker_index}.connected.json"
        audio_path = control / f"worker-{self.args.worker_index}.audio-ready.json"
        measure_path = control / "measure.json"
        stop_path = control / "stop.json"
        context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or certifi.where())
        limits = httpx.Limits(max_connections=self.args.http_concurrency,
                             max_keepalive_connections=self.args.http_concurrency)
        self.started_at = time.monotonic()
        async with httpx.AsyncClient(base_url=SERVER, verify=context, timeout=25, trust_env=False, limits=limits) as self.http:
            try:
                # Deliberately sequential, including grant/seat/publish setup.
                for sample in self.clients:
                    if stop_path.exists():
                        raise CoordinatorStopRequested()
                    await self.connect(sample)
                    if sample.join_task is not None and not sample.join_task.done():
                        # Keep one native join in flight. Do not create another
                        # one in the same runtime after its wait budget expires.
                        for skipped in self.clients:
                            if not skipped.connected and skipped.failure is None:
                                skipped.failure = "NotAttemptedAfterUnsettledJoin"
                                skipped.failure_stage = "generator-join-pending"
                                skipped.failure_diagnostic = {"type": "NotAttemptedAfterUnsettledJoin"}
                        break
                private_json(ready_path, {"connected": sum(item.connected for item in self.clients),
                    "requested": len(self.clients), "failed": sum(item.failure is not None for item in self.clients),
                    "unsettledJoins": sum(item.join_task is not None and not item.join_task.done() for item in self.clients),
                    "failures": [{"client": item.index + 1, "stage": item.failure_stage,
                                  "error": item.failure, "diagnostic": item.failure_diagnostic}
                                 for item in self.clients if item.failure is not None],
                    "generatorAtJoin": await asyncio.to_thread(process_runtime_usage)})
                while not measure_path.exists():
                    if stop_path.exists():
                        raise CoordinatorStopRequested()
                    audio_ready = all(len(sample.streams) == self.expected_streams(sample) and
                        all(stream.ever_received for stream in sample.streams.values())
                        for sample in self.clients) and all(sample.failure is None for sample in self.clients)
                    if audio_ready and not audio_path.exists():
                        private_json(audio_path, {"ready": True})
                    await asyncio.sleep(.1)
                instruction = json.loads(measure_path.read_text())
                self.warmup_complete = audio_path.exists()
                baselines = await asyncio.gather(*(self.rtc_snapshot(sample) for sample in self.clients))
                for sample, baseline in zip(self.clients, baselines):
                    sample.rtc_baseline = baseline
                planned_start = instruction["startsAt"]
                await asyncio.sleep(max(0, planned_start - time.time()))
                if stop_path.exists():
                    raise CoordinatorStopRequested()
                self.measure_start_wall = time.time()
                measure_started = time.monotonic()
                self.started_at = measure_started
                self.measuring = True
                self.spawn(self.monitor_generator())
                for sample in self.clients:
                    if sample.connected:
                        self.spawn(self.poll(sample))
                until = planned_start + instruction["durationSeconds"]
                while time.time() < until:
                    if stop_path.exists():
                        raise CoordinatorStopRequested()
                    await asyncio.sleep(min(1, max(0, until - time.time())))
                self.measure_end_wall = time.time()
                self.measured_seconds = time.monotonic() - measure_started
                self.measuring = False
                snapshots = await asyncio.gather(*(self.rtc_snapshot(sample) for sample in self.clients))
                for sample, snapshot in zip(self.clients, snapshots):
                    sample.rtc_final = snapshot
            except BaseException as error:
                self.failure = f"HTTP {error.status}" if isinstance(error, ApiFailure) else type(error).__name__
            finally:
                await self.cleanup()
        result = self.result()
        result["measurement"] = {"plannedStart": instruction["startsAt"] if "instruction" in locals() else None,
            "actualStart": getattr(self, "measure_start_wall", None),
            "actualEnd": getattr(self, "measure_end_wall", None)}
        private_json(self.args.output, result)
        return 0 if result["acceptancePassed"] else 2


class CoordinatedProbe(Probe):
    """A non-media coordinator; native SDK failure cannot skip room cleanup."""

    def __init__(self, args, emit):
        super().__init__(args, emit)
        self.children = []
        self.child_indices = []
        self.worker_results = []
        self.control = None
        self.planned_start = None
        self.worker_failures = []
        self.coordinator_terminated = set()
        self.expected_worker_count = math.ceil(args.participants / args.worker_size)

    async def stop_children(self):
        living = [child for child in self.children if child.returncode is None]
        if living and self.control:
            # A file asks workers to enter their normal finally/cleanup path.
            # Keep their event loops alive while native joins answer ready.
            private_json(self.control / "stop.json", {"reason": "coordinator-cleanup"})
            waiters = [asyncio.create_task(child.wait()) for child in living]
            _done, pending = await asyncio.wait(waiters, timeout=JOIN_SETTLE_SECONDS)
            for waiter in pending:
                waiter.cancel()  # This only stops waiting in the parent process.
            await asyncio.gather(*waiters, return_exceptions=True)
        for index, child in zip(self.child_indices, self.children):
            if child.returncode is None:
                self.coordinator_terminated.add(index)
                child.terminate()
        for child in self.children:
            if child.returncode is None:
                try:
                    await asyncio.wait_for(child.wait(), 5)
                except asyncio.TimeoutError:
                    child.kill()
                    await child.wait()

    async def wait_marker(self, child, marker, timeout):
        deadline = time.monotonic() + timeout
        while not marker.exists():
            if child.returncode is not None or any(item.returncode is not None for item in self.children):
                raise RuntimeError("generator-worker-exited-during-connect")
            if time.monotonic() >= deadline:
                raise TimeoutError("generator-worker-connect-deadline")
            await asyncio.sleep(.2)

    async def run(self):
        context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or certifi.where())
        self.started_at = time.monotonic()
        self.control = Path(tempfile.mkdtemp(prefix="kiki-capacity-workers-", dir=self.args.output.parent))
        os.chmod(self.control, 0o700)
        plan_path = self.control / "private-plan.json"
        async with httpx.AsyncClient(base_url=SERVER, verify=context, timeout=25, trust_env=False) as self.http:
            try:
                health = await self.call("GET", "/health")
                if not health.get("rtcConfigured"):
                    raise ValueError("RTC health is unavailable")
                await self.make_accounts()
                cursor = 0
                clients = []
                publisher_counts = []
                for room_index in range(self.args.rooms):
                    count = self.args.participants // self.args.rooms + (room_index < self.args.participants % self.args.rooms)
                    self.owners.append(cursor)
                    room = await self.call("POST", "/v1/rooms", self.accounts[cursor], json={
                        "title": f"容量验收{self.run_label}-{room_index + 1}", "category": "闲聊", "isLive": False, "theme": 0})
                    self.room_ids.append(room["id"])
                    publisher_counts.append(min(count, self.args.publishers_per_room))
                    for offset in range(count):
                        clients.append({"index": cursor + offset, "room_index": room_index,
                                        "publisher": offset < self.args.publishers_per_room})
                    cursor += count
                assignments = make_assignments(clients, self.owners, self.args.worker_size)
                self.expected_worker_count = len(assignments)
                option_keys = ("rooms", "participants", "publishers_per_room", "duration", "relay_only",
                    "state_interval", "chat_interval", "http_concurrency", "warmup", "audio_bitrate", "audio_frame_ms")
                private_json(plan_path, {"schemaVersion": 1, "server": SERVER,
                    "accounts": self.accounts, "roomIDs": self.room_ids, "owners": self.owners,
                    "roomPublisherCounts": publisher_counts, "assignments": assignments,
                    "options": {key: getattr(self.args, key) for key in option_keys}})
                self.emit({"phase": "connecting", "participants": self.args.participants,
                    "rooms": self.args.rooms, "generatorProcesses": len(assignments),
                    "clientsPerProcessMaximum": self.args.worker_size,
                    "roomOwnersJoinFirst": True,
                    "joiningWorkersMaximum": self.args.join_workers,
                    "globalConnectConcurrency": self.args.join_workers})
                # Each isolated FFI runtime still joins one client at a time.
                # Limit concurrently joining shards without serializing all 100
                # real handshakes; completed shards keep publishing/receiving.
                joining = asyncio.Semaphore(self.args.join_workers)

                async def join_worker(index, assignment):
                    async with joining:
                        child = await asyncio.create_subprocess_exec(sys.executable, str(Path(__file__).resolve()),
                            "--worker-plan", str(plan_path), "--worker-index", str(index),
                            "--output", str(self.control / f"worker-{index}.json"),
                            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
                        self.children.append(child)
                        self.child_indices.append(index)
                        ready = self.control / f"worker-{index}.connected.json"
                        ready_budget = len(assignment) * (JOIN_WAIT_SECONDS + 120) + JOIN_SETTLE_SECONDS + 30
                        await self.wait_marker(child, ready, ready_budget)
                        current = json.loads(ready.read_text())
                        self.emit({"phase": "joined-shard", "shard": index + 1,
                            "connected": current["connected"], "requested": len(assignment),
                            "setupFailures": current["failed"],
                            "failureDiagnostics": current.get("failures", []),
                            "generatorAtJoin": current.get("generatorAtJoin")})
                        if current.get("unsettledJoins"):
                            raise UnsettledGeneratorJoin()

                # The owner barrier is deliberate: a fast non-owner shard must
                # not overtake the fourth owner while the first three join.
                for phase in (range(len(self.owners)), range(len(self.owners), len(assignments))):
                    joins = [asyncio.create_task(join_worker(index, assignments[index])) for index in phase]
                    try:
                        await asyncio.gather(*joins)
                    finally:
                        for task in joins:
                            task.cancel()
                        await asyncio.gather(*joins, return_exceptions=True)
                self.emit({"phase": "warming", "generatorProcesses": len(assignments)})
                deadline = time.monotonic() + self.args.warmup
                while time.monotonic() < deadline:
                    if any(child.returncode is not None for child in self.children):
                        raise RuntimeError("generator-worker-exited-before-measurement")
                    if all((self.control / f"worker-{index}.audio-ready.json").exists()
                           for index in range(len(assignments))):
                        self.warmup_complete = True
                        break
                    await asyncio.sleep(.2)
                self.planned_start = time.time() + 5
                private_json(self.control / "measure.json", {"startsAt": self.planned_start,
                                                            "durationSeconds": self.args.duration})
                self.emit({"phase": "measuring", "durationSeconds": self.args.duration,
                    "allSubscriptionsReceivedAudio": self.warmup_complete,
                    "generatorProcesses": len(self.children)})
                deadline = time.monotonic() + self.args.duration + JOIN_SETTLE_SECONDS + 90
                while any(child.returncode is None for child in self.children):
                    if any(child.returncode not in (None, 0, 2) for child in self.children):
                        raise RuntimeError("generator-worker-native-or-process-failure")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("generator-worker-measurement-deadline")
                    await asyncio.sleep(.5)
            except BaseException as error:
                self.failure = f"HTTP {error.status}" if isinstance(error, ApiFailure) else type(error).__name__
            finally:
                await self.stop_children()
                for index, child in zip(self.child_indices, self.children):
                    output = self.control / f"worker-{index}.json"
                    if output.exists():
                        self.worker_results.append(json.loads(output.read_text()))
                    else:
                        native_log = self.control / f"worker-{index}.json.sdk.log"
                        native_panic = False
                        native_ready_timeout = False
                        if native_log.exists():
                            with native_log.open("r", errors="replace") as stream:
                                private_text = stream.read(64 * 1024)
                            native_panic = "FFI Panic" in private_text
                            native_ready_timeout = native_panic and "ReadyForRoomEventRequest" in private_text
                        cleanup_marker = self.control / f"worker-{index}.cleanup.json"
                        pending_joins = json.loads(cleanup_marker.read_text()).get("pendingJoinCount", 0) if cleanup_marker.exists() else 0
                        classification = ("native-ffi-panic" if native_panic else
                            "generator-join-settlement-timeout" if pending_joins and index in self.coordinator_terminated else
                            "coordinator-cleanup-termination" if index in self.coordinator_terminated else
                            "generator-process-failure")
                        self.worker_failures.append({"worker": index + 1, "exitCode": child.returncode,
                            "classification": classification,
                            "pendingNativeJoinsAtCleanup": pending_joins,
                            "nativeReadyEventTimeout": native_ready_timeout})
                await self.cleanup()
                # Only this file contains room IDs/credentials. Keep private
                # per-worker metrics and native logs for generator diagnostics.
                plan_path.unlink(missing_ok=True)
        result = self.result()
        private_json(self.args.output, result)
        self.emit({"phase": "complete", "acceptancePassed": result["acceptancePassed"],
            "generatorSaturated": result["generator"]["saturated"], "connected": result["connections"]["connected"],
            "attempted": self.args.participants, "cleanupPending": len(self.cleanup_failures),
            "generatorProcessFailures": sum(item["classification"] != "coordinator-cleanup-termination" for item in self.worker_failures),
            "coordinatorTerminations": sum(item["classification"] == "coordinator-cleanup-termination" for item in self.worker_failures),
            "resultFile": str(Path(self.args.output).resolve())})
        return 0 if result["acceptancePassed"] else 2

    def result(self):
        # Reuse the canonical, non-sensitive result schema for the coordinator.
        base = super().result()
        clients = sorted((item for result in self.worker_results for item in result["clients"]),
                         key=lambda item: item["client"])
        counts = Counter()
        latencies = {}
        cpu_per_second = Counter()
        rss = 0
        max_lag_p95 = 0
        max_lag = 0
        actual_starts, actual_ends = [], []
        for result in self.worker_results:
            counts.update(result["http"]["counts"])
            for kind, values in result.get("_httpLatencySamplesMs", {}).items():
                latencies.setdefault(kind, []).extend(values)
            generator = result["generator"]
            for sample in generator["samples"]:
                cpu_per_second[int(sample["seconds"])] += sample["processCPUPercentOneCore"]
            rss += generator.get("peakRSSMiB") or 0
            max_lag_p95 = max(max_lag_p95, generator.get("loopLagMsP95") or 0)
            max_lag = max(max_lag, generator.get("loopLagMsMax") or 0)
            measurement = result.get("measurement", {})
            if measurement.get("actualStart") is not None:
                actual_starts.append(measurement["actualStart"])
                actual_ends.append(measurement["actualEnd"])
        cpu_p95 = percentile(list(cpu_per_second.values()), .95)
        saturated = bool(self.worker_failures) or max_lag_p95 > 100 or (cpu_p95 or 0) > 80 * (os.cpu_count() or 1)
        total = sum(counts.values())
        errors = sum(value for key, value in counts.items() if not key.rsplit(":", 1)[-1].startswith("2"))
        checks = {key: bool(self.worker_results) and all(result["checks"].get(key, False) for result in self.worker_results)
                  for key in base["checks"]}
        start_skew_ms = 1000 * (max(actual_starts) - min(actual_starts)) if actual_starts else None
        checks.update(setupCompleted=self.failure is None and len(clients) == self.args.participants,
            allClientsConnected=len(clients) == self.args.participants and all(item["connected"] for item in clients),
            allGeneratorWorkersCompleted=len(self.worker_results) == self.expected_worker_count and not self.worker_failures,
            generatorNotSaturated=not saturated,
            synchronizedMeasurementStart=start_skew_ms is not None and start_skew_ms <= 500,
            httpSuccessAtLeast99Percent=total > 0 and errors / total <= .01,
            noHTTP429=not any(key.endswith(":429") for key in counts), cleanupSucceeded=not self.cleanup_failures)
        rooms = []
        for index in range(self.args.rooms):
            group = [item for item in clients if item["room"] == index + 1]
            rooms.append({"room": index + 1, "participants": len(group),
                "connected": sum(item["connected"] for item in group), "publishers": sum(item["published"] for item in group),
                "subscriptions": sum(item["subscriptions"] for item in group),
                "decodedFrames": sum(item["decodedFrames"] for item in group),
                "minimumStreamCoveragePercent": min((item["minimumStreamCoveragePercent"] for item in group), default=0)})
        base.update(clients=clients, rooms=rooms, failure=self.failure,
            measuredSeconds=round(min(actual_ends) - max(actual_starts), 3) if actual_starts else 0,
            measurement={"plannedStart": self.planned_start, "workerStartSkewMs": round(start_skew_ms, 3) if start_skew_ms is not None else None,
                         "workers": [result.get("measurement") for result in self.worker_results]},
            connections={"attempted": self.args.participants, "connected": sum(item["connected"] for item in clients),
                "failed": self.args.participants - sum(item["connected"] for item in clients),
                "connectMsP50": percentile([item["connectMs"] for item in clients if item["connectMs"] is not None], .5),
                "connectMsP95": percentile([item["connectMs"] for item in clients if item["connectMs"] is not None], .95)},
            http={"counts": dict(counts), "successPercent": round(100 * (total-errors) / max(1, total), 3),
                "latencyMs": {key: {"p50": percentile(values, .5), "p95": percentile(values, .95), "max": round(max(values), 3)}
                              for key, values in latencies.items()}},
            generator={"mode": "isolated-process-shards", "logicalCPUs": os.cpu_count(),
                "clientsPerProcessMaximum": self.args.worker_size, "processCount": len(self.children),
                "roomOwnersJoinFirst": True,
                "joiningWorkersMaximum": self.args.join_workers,
                "globalConnectConcurrencyMaximum": self.args.join_workers,
                "nativeJoinWaitBudgetSeconds": JOIN_WAIT_SECONDS,
                "nativeJoinCleanupParentBudgetSeconds": JOIN_SETTLE_SECONDS,
                "processCPUPercentUsesOneCore100": True, "cpuPercentP95": cpu_p95,
                "loopLagMsP95": round(max_lag_p95, 3), "loopLagMsMax": round(max_lag, 3),
                "sumWorkerPeakRSSMiB": round(rss, 2), "saturated": saturated,
                "saturationThreshold": "any worker loop lag p95 >100ms, or aggregate CPU p95 >80% of logical CPUs, or a generator process failure",
                "processFailures": self.worker_failures,
                "workerMetricsDirectory": str(self.control.resolve()) if self.control else None,
                "samples": [{"seconds": second, "processCPUPercentOneCore": round(value, 2)}
                            for second, value in sorted(cpu_per_second.items())]},
            checks=checks, acceptancePassed=all(checks.values()))
        join_observations = []
        if self.control:
            for marker in sorted(self.control.glob("worker-*.connected.json"),
                                 key=lambda path: int(path.name.split("-")[1].split(".")[0])):
                item = json.loads(marker.read_text())
                join_observations.append({"worker": int(marker.name.split("-")[1].split(".")[0]) + 1, **item})
        base["setupDiagnostics"] = {"failures": [failure for item in join_observations for failure in item.get("failures", [])],
                                    "workersAtJoin": join_observations}
        base["measurementValid"] = (self.failure is None and not self.worker_failures
            and len(clients) == self.args.participants
            and len(actual_starts) == len(self.worker_results) and bool(actual_starts)
            and all(result.get("failure") is None for result in self.worker_results))
        if not base["measurementValid"]:
            # A killed native runtime loses its final observations. Missing
            # generator records are not failed server connection attempts.
            minimum_connected = 0
            if self.control:
                for marker in self.control.glob("worker-*.connected.json"):
                    minimum_connected += json.loads(marker.read_text()).get("connected", 0)
            base["connections"].update(requested=self.args.participants, attempted=None,
                failed=None, incompleteObservation=True,
                minimumConnectedFromJoinBarriers=minimum_connected)
        return base


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rooms", type=int, default=1)
    parser.add_argument("--participants", type=int, default=8)
    parser.add_argument("--publishers-per-room", type=int, default=8)
    parser.add_argument("--duration", type=float, default=120)
    parser.add_argument("--relay-only", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--accounts-file", type=Path)
    parser.add_argument("--keep-accounts", action="store_true")
    parser.add_argument("--state-interval", type=float, default=1.65)
    parser.add_argument("--chat-interval", type=float, default=1.65)
    parser.add_argument("--connect-concurrency", type=int, default=1)
    parser.add_argument("--http-concurrency", type=int, default=16)
    parser.add_argument("--warmup", type=float, default=30)
    parser.add_argument("--audio-bitrate", type=int, default=24000)
    parser.add_argument("--audio-frame-ms", type=int, choices=(100, 200), default=100,
                        help="Decoded PCM callback frame size; RTP publishing remains 20ms (default 100)")
    parser.add_argument("--worker-size", type=int, default=4,
                        help="Isolate at most this many RTC clients per native SDK process (default 4; 0 disables sharding)")
    parser.add_argument("--join-workers", type=int, default=3,
                        help="Concurrently joining shards, each with one sequential RTC handshake (1-4, default 3)")
    parser.add_argument("--worker-plan", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--worker-index", type=int, default=0, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not 1 <= args.rooms <= 4 or not args.rooms <= args.participants <= args.rooms * 32:
        parser.error("use 1-4 rooms and 1-32 participants per room (maximum 128)")
    if not 1 <= args.publishers_per_room <= min(8, args.participants // args.rooms):
        parser.error("publishers-per-room must be 1-8 and fit the smallest room")
    if min(args.duration, args.warmup, args.state_interval, args.chat_interval) <= 0:
        parser.error("duration, warmup and poll intervals must be positive")
    if not 1 <= args.connect_concurrency <= 8 or not 1 <= args.http_concurrency <= 64:
        parser.error("invalid concurrency")
    if not 6000 <= args.audio_bitrate <= 64000:
        parser.error("audio-bitrate must be 6000-64000")
    if not 0 <= args.worker_size <= 8:
        parser.error("worker-size must be 0-8; use <=8 clients per native SDK process")
    if not 1 <= args.join_workers <= 4:
        parser.error("join-workers must be 1-4")
    return args


def main():
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    logging.getLogger("livekit").setLevel(logging.CRITICAL)
    logging.getLogger("httpx").setLevel(logging.CRITICAL)
    # Native SDK logging can contain signalling payloads. Capture both OS-level
    # file descriptors even when the caller forgot to redirect its terminal.
    safe_stdout = os.dup(1)
    log_path = str(args.output) + ".sdk.log"
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)

    def emit(value):
        os.write(safe_stdout, (json.dumps(value, ensure_ascii=False) + "\n").encode())

    try:
        probe_class = WorkerProbe if args.worker_plan else (
            CoordinatedProbe if args.worker_size else Probe)
        return asyncio.run(probe_class(args, emit).run())
    except KeyboardInterrupt:
        emit({"phase": "interrupted", "privateSDKLog": log_path})
        return 130
    except Exception as error:
        emit({"phase": "failed", "errorType": type(error).__name__, "privateSDKLog": log_path})
        return 2
    finally:
        os.close(safe_stdout)


if __name__ == "__main__":
    raise SystemExit(main())
