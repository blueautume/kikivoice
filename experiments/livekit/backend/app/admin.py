"""Independent, read-only voice-lab management API and bounded host sampling.

No ordinary application bearer, user name, identity, message, IP, private key or
quality sample is exposed or stored by this module. Account services are absent.
"""
import asyncio
from contextlib import suppress
from datetime import datetime, timedelta, timezone
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import time
from zoneinfo import ZoneInfo

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

SERVICE_ID = "voice-lab"
SESSION_SECONDS = 8 * 3600
HASH_ITERATIONS = 600_000
HASH_PATTERN = re.compile(r"pbkdf2_sha256\$600000\$([a-f0-9]{32})\$([a-f0-9]{64})")
SERVICE_UNITS = (("api", "语聊管理/API", "livekit-lab-api.service"),
                 ("livekit", "LiveKit SFU", "livekit-lab.service"),
                 ("nginx", "Nginx", "nginx.service"),
                 ("haproxy", "TLS/TURN 入口", "haproxy.service"))
METRIC_KEYS = ("cpuPercent", "cpuCores", "memoryUsedBytes", "memoryTotalBytes",
               "memoryPercent", "diskUsedBytes", "diskTotalBytes", "diskPercent",
               "networkReceiveBytesPerSecond", "networkTransmitBytesPerSecond",
               "uptimeSeconds", "certificateExpiresAt", "certificateDaysRemaining")


def iso(at=None):
    return datetime.fromtimestamp(time.time() if at is None else at, timezone.utc).isoformat()


def backup_snapshot(now):
    """Read only the fixed local maintenance receipt; never expose backup paths."""
    result = {"lastSuccessAt":None,"verifiedAt":None,"backupAgeSeconds":None,
              "healthy":None,"lastError":None,"retentionDays":7}
    try:
        path = Path("/var/lib/kiki-livekit-lab/backup-status.json")
        if path.stat().st_size > 4096:
            raise ValueError("Oversized status")
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("service") != "voice":
            raise ValueError("Wrong service")
        for key in ("lastSuccessAt","verifiedAt"):
            at = data.get(key)
            if at is not None and (type(at) not in (int,float) or not 0 < at <= now+60):
                raise ValueError("Invalid timestamp")
            result[key] = at
        if result["lastSuccessAt"] is not None:
            result["backupAgeSeconds"] = max(0,int(now-result["lastSuccessAt"]))
        failed = bool(data.get("lastError"))
        result["healthy"] = bool(result["verifiedAt"] and result["backupAgeSeconds"] is not None
            and result["verifiedAt"] >= result["lastSuccessAt"]
            and result["backupAgeSeconds"] <= 36*3600 and not failed)
        if failed:
            result["lastError"] = "最近一次备份或恢复校验失败，请检查服务器维护日志。"
    except FileNotFoundError:
        pass
    except (OSError,ValueError,TypeError,AttributeError):
        result.update(healthy=False,lastError="无法读取有效的备份状态，请检查服务器维护日志。")
    return result


def hash_passphrase(passphrase, *, salt=None):
    salt = secrets.token_hex(16) if salt is None else salt
    if not re.fullmatch(r"[a-f0-9]{32}", salt):
        raise ValueError("Invalid management credential salt")
    if not 16 <= len(passphrase.encode("utf-8")) <= 256:
        raise ValueError("Management passphrase must contain 16..256 UTF-8 bytes")
    digest = hashlib.pbkdf2_hmac("sha256", passphrase.encode("utf-8"), bytes.fromhex(salt), HASH_ITERATIONS)
    return f"pbkdf2_sha256${HASH_ITERATIONS}${salt}${digest.hex()}"


def verify_passphrase(passphrase, configured):
    match = HASH_PATTERN.fullmatch(configured)
    if match is None:
        return False
    digest = hashlib.pbkdf2_hmac("sha256", passphrase.encode("utf-8"), bytes.fromhex(match[1]), HASH_ITERATIONS)
    return hmac.compare_digest(digest.hex(), match[2])


def validate_admin_settings(settings):
    configured = settings.admin_passphrase_hash
    if configured and HASH_PATTERN.fullmatch(configured) is None:
        raise RuntimeError("Configure a valid independent management credential hash")
    if configured and verify_passphrase(settings.access_code, configured):
        raise RuntimeError("Management credential must differ from the laboratory invite code")
    if not Path(settings.admin_tls_cert_path).is_absolute():
        raise RuntimeError("Management certificate path must be absolute")


def initialize_admin_database(db):
    # Never ALTER rooms: existing clients and migrations rely on its column shape.
    db.executescript("""
    CREATE TABLE IF NOT EXISTS admin_sessions (
        token_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL,
        revoked_at INTEGER, credential_fingerprint TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS admin_metadata (
        key TEXT PRIMARY KEY, value INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS admin_room_lifecycle (
        room_id TEXT PRIMARY KEY REFERENCES rooms(id), created_at INTEGER NOT NULL,
        ended_at INTEGER, historical_end_unknown INTEGER NOT NULL DEFAULT 0);
    INSERT OR IGNORE INTO admin_metadata VALUES('room_end_tracking_since',CAST(strftime('%s','now') AS INTEGER));
    INSERT OR IGNORE INTO admin_room_lifecycle(room_id,created_at,historical_end_unknown)
        SELECT id,created_at,CASE WHEN status IN ('closed','closing') THEN 1 ELSE 0 END
        FROM rooms WHERE status IN ('active','closed','closing')
        AND NOT EXISTS(SELECT 1 FROM admin_metadata WHERE key='lifecycle_seed_completed');
    INSERT OR IGNORE INTO admin_metadata VALUES('lifecycle_seed_completed',1);
    CREATE TRIGGER IF NOT EXISTS admin_room_started AFTER UPDATE OF status ON rooms
    WHEN NEW.status='active' AND OLD.status!='active'
    BEGIN
        INSERT OR IGNORE INTO admin_room_lifecycle(room_id,created_at) VALUES(NEW.id,NEW.created_at);
    END;
    CREATE TRIGGER IF NOT EXISTS admin_room_ended AFTER UPDATE OF status ON rooms
    WHEN NEW.status IN ('closing','closed') AND OLD.status='active'
    BEGIN
        UPDATE admin_room_lifecycle SET ended_at=CAST(strftime('%s','now') AS INTEGER)
        WHERE room_id=NEW.id AND ended_at IS NULL AND historical_end_unknown=0;
    END;
    """)
    db.commit()


class AdminLogin(BaseModel):
    model_config = ConfigDict(extra="forbid")
    passphrase: str = Field(min_length=1, max_length=256, strict=True)

    @field_validator("passphrase")
    @classmethod
    def valid_passphrase(cls, value):
        if not 16 <= len(value.encode("utf-8")) <= 256:
            raise ValueError("Invalid management passphrase length")
        return value


def empty_host_snapshot():
    return {"sampledAt": None, "stale": True, **dict.fromkeys(METRIC_KEYS),
            "services": [{"id": key, "name": name, "state": "unknown"}
                         for key, name, _unit in SERVICE_UNITS]}


class HostCollector:
    """Runs only in asyncio.to_thread; fixed commands, capped files and timeouts."""
    def __init__(self, certificate_path, *, proc_root="/proc", clock=time.monotonic, wall_clock=time.time):
        self.certificate_path = certificate_path
        self.proc = Path(proc_root)
        self.clock = clock
        self.wall_clock = wall_clock
        self.previous = None

    def read(self, filename):
        with (self.proc / filename).open("r", encoding="ascii") as stream:
            return stream.read(128 * 1024)

    @staticmethod
    def services():
        result = []
        for key, name, unit in SERVICE_UNITS:
            state = "unknown"
            try:
                output = subprocess.run(["systemctl", "is-active", unit], capture_output=True,
                                        text=True, timeout=.5, check=False).stdout[:64].strip()
                if output in {"active", "inactive", "failed", "activating", "deactivating", "reloading"}:
                    state = output
            except (OSError, subprocess.TimeoutExpired):
                pass
            result.append({"id": key, "name": name, "state": state})
        return result

    def collect(self):
        at, wall = self.clock(), self.wall_clock()
        snapshot = empty_host_snapshot()
        snapshot.update(sampledAt=iso(wall), stale=False)
        cpu = network = None
        if self.proc.is_dir():
            snapshot["cpuCores"] = os.cpu_count()
            try:
                fields = [int(value) for value in self.read("stat").splitlines()[0].split()[1:9]]
                if len(fields) == 8:
                    cpu = (sum(fields), fields[3] + fields[4])
            except (OSError, ValueError, IndexError):
                pass
            try:
                memory = {line.split(":")[0]: int(line.split()[1]) * 1024
                          for line in self.read("meminfo").splitlines() if ":" in line}
                total, available = memory["MemTotal"], memory["MemAvailable"]
                if total > 0 and 0 <= available <= total:
                    snapshot.update(memoryUsedBytes=total-available, memoryTotalBytes=total,
                                    memoryPercent=round(100*(total-available)/total, 2))
            except (OSError, ValueError, KeyError, IndexError):
                pass
            try:
                totals = [0, 0]
                interfaces = 0
                for line in self.read("net/dev").splitlines():
                    if ":" not in line:
                        continue
                    interface, fields = line.split(":", 1)
                    if interface.strip() == "lo":
                        continue
                    values = fields.split()
                    totals[0] += int(values[0])
                    totals[1] += int(values[8])
                    interfaces += 1
                network = tuple(totals) if interfaces else None
            except (OSError, ValueError, IndexError):
                pass
            try:
                uptime = float(self.read("uptime").split()[0])
                if 0 <= uptime < 100 * 366 * 86400:
                    snapshot["uptimeSeconds"] = int(uptime)
            except (OSError, ValueError, IndexError):
                pass
            if self.previous:
                previous_at, previous_cpu, previous_network = self.previous
                elapsed = at - previous_at
                if cpu is not None and previous_cpu is not None:
                    total, idle = cpu[0] - previous_cpu[0], cpu[1] - previous_cpu[1]
                    if total > 0 and 0 <= idle <= total:
                        snapshot["cpuPercent"] = round(100 * (total-idle) / total, 2)
                if network is not None and previous_network is not None and elapsed > 0:
                    delta = [network[index] - previous_network[index] for index in (0, 1)]
                    if min(delta) >= 0:
                        snapshot["networkReceiveBytesPerSecond"] = round(delta[0]/elapsed, 2)
                        snapshot["networkTransmitBytesPerSecond"] = round(delta[1]/elapsed, 2)
        self.previous = (at, cpu, network)
        try:
            disk = shutil.disk_usage("/")
            if disk.total > 0:
                snapshot.update(diskUsedBytes=disk.used, diskTotalBytes=disk.total,
                                diskPercent=round(100*disk.used/disk.total, 2))
        except OSError:
            pass
        try:
            # Decode public certificate locally. Never open its private key.
            certificate = ssl._ssl._test_decode_cert(self.certificate_path)
            expires = ssl.cert_time_to_seconds(certificate["notAfter"])
            snapshot["certificateExpiresAt"] = iso(expires)
            snapshot["certificateDaysRemaining"] = int((expires-wall)//86400)
        except (OSError, ValueError, KeyError, ssl.SSLError):
            pass
        snapshot["services"] = self.services()
        return snapshot


class AdminService:
    def __init__(self, settings, db, rtc, observability, capacity, lock, limiter, client_ip,
                 *, collector=None, clock=time.monotonic, wall_clock=time.time):
        self.settings, self.db, self.rtc = settings, db, rtc
        self.observability, self.capacity, self.lock = observability, capacity, lock
        self.limiter, self.client_ip = limiter, client_ip
        self.clock, self.wall_clock = clock, wall_clock
        self.credential_fingerprint = hashlib.sha256(settings.admin_passphrase_hash.encode()).hexdigest()
        self.collector = collector or HostCollector(settings.admin_tls_cert_path)
        self.host = empty_host_snapshot()
        self.host_at = None
        self.sfu_rooms, self.sfu_at, self.sfu_wall = {}, None, None
        self.sfu_failed = False
        self.login_slots = asyncio.Semaphore(2)
        self.task = None
        self.started_at = self.clock()

    @property
    def enabled(self):
        if getattr(self.settings, "admin_auth_mode", "legacy") == "passkey":
            return bool(self.settings.ops_bridge_secret)
        return self.legacy_enabled

    @property
    def legacy_enabled(self):
        return getattr(self.settings, "admin_auth_mode", "legacy") == "legacy" and bool(self.settings.admin_passphrase_hash)

    def start(self):
        if self.enabled:
            self.task = asyncio.create_task(self.maintain())

    async def close(self):
        if self.task:
            self.task.cancel()
            with suppress(asyncio.CancelledError):
                await self.task

    async def sample_sfu(self):
        try:
            rooms = await asyncio.wait_for(self.rtc.list_rooms(), timeout=2)
            # Accept a bounded map with true integer counts only.
            if (not isinstance(rooms, dict) or len(rooms) > 1000 or
                    any(not isinstance(key, str) or type(value) is not int or value < 0
                        for key, value in rooms.items())):
                raise ValueError("Invalid media snapshot")
            self.sfu_rooms = rooms
            self.sfu_at, self.sfu_wall = self.clock(), self.wall_clock()
            self.sfu_failed = False
        except (Exception, asyncio.TimeoutError):
            self.sfu_failed = True

    async def sample_host(self):
        try:
            # Collector has bounded local reads and <=4x0.5s subprocess timeouts.
            self.host = await asyncio.wait_for(asyncio.to_thread(self.collector.collect), timeout=5)
            self.host_at = self.clock()
        except (Exception, asyncio.TimeoutError):
            pass  # Keep timestamped last known sample; stale flag must expose age.

    async def maintain(self):
        while True:
            next_sample = self.clock() + 10
            await asyncio.gather(self.sample_host(), self.sample_sfu())
            # The same connection is used by media/business transactions. Their
            # lock can span awaits, so maintenance must not commit inside one.
            async with self.lock:
                with self.db:
                    self.db.execute("DELETE FROM admin_sessions WHERE expires_at<=? OR revoked_at IS NOT NULL OR credential_fingerprint!=?",
                                    (int(self.wall_clock()), self.credential_fingerprint))
            await asyncio.sleep(max(0, next_sample-self.clock()))

    def authenticate(self, request):
        if getattr(self.settings, "admin_auth_mode", "legacy") != "legacy":
            raise HTTPException(401, "管理认证已迁移")
        if not self.legacy_enabled:
            raise HTTPException(503, "管理登录尚未配置")
        value = request.headers.get("authorization", "")
        if not value.startswith("Bearer ") or not re.fullmatch(r"[A-Za-z0-9_-]{43}", value[7:]):
            raise HTTPException(401, "管理登录已过期，请重新登录")
        digest = hashlib.sha256(value[7:].encode()).hexdigest()
        row = self.db.execute("SELECT token_hash FROM admin_sessions WHERE token_hash=? AND expires_at>? AND revoked_at IS NULL AND credential_fingerprint=?",
                              (digest, int(self.wall_clock()), self.credential_fingerprint)).fetchone()
        if row is None:
            raise HTTPException(401, "管理登录已过期，请重新登录")
        return digest

    async def login(self, payload, request):
        if getattr(self.settings, "admin_auth_mode", "legacy") != "legacy":
            raise HTTPException(404, "接口不存在")
        # Independent admin buckets remain enabled even when user test limits are disabled.
        self.limiter.check(("admin-login", self.client_ip(request)), 5, 300)
        self.limiter.check(("admin-login-total",), 30, 300)
        if not self.enabled:
            raise HTTPException(503, "管理登录尚未配置")
        # Reject saturation without queuing unbounded expensive PBKDF2 jobs.
        if self.login_slots.locked():
            raise HTTPException(429, "管理登录繁忙，请稍后重试", headers={"Retry-After": "5"})
        async with self.login_slots:
            valid = await asyncio.to_thread(verify_passphrase, payload.passphrase, self.settings.admin_passphrase_hash)
        if not valid:
            raise HTTPException(401, "管理口令不正确")
        raw = secrets.token_urlsafe(32)
        digest = hashlib.sha256(raw.encode()).hexdigest()
        expires = int(self.wall_clock()) + SESSION_SECONDS
        async with self.lock:
            with self.db:
                self.db.execute("DELETE FROM admin_sessions WHERE expires_at<=? OR revoked_at IS NOT NULL OR credential_fingerprint!=?",
                                (int(self.wall_clock()), self.credential_fingerprint))
                # This first version has one shared viewer credential; keep storage bounded.
                count = self.db.execute("SELECT COUNT(*) FROM admin_sessions").fetchone()[0]
                if count >= 32:
                    raise HTTPException(429, "管理登录设备数量已达上限，请先退出其他设备", headers={"Retry-After": "300"})
                self.db.execute("INSERT INTO admin_sessions VALUES(?,?,NULL,?)",
                                (digest, expires, self.credential_fingerprint))
        return {"token": raw, "expiresAt": expires, "serviceID": SERVICE_ID, "role": "viewer"}

    def dashboard(self):
        now = self.wall_clock()
        production = getattr(self.settings, "auth_mode", "lab") == "account"
        day = datetime.fromtimestamp(now, ZoneInfo("Asia/Shanghai")).replace(hour=0, minute=0, second=0, microsecond=0)
        start, end = int(day.timestamp()), int((day+timedelta(days=1)).timestamp())
        tracking = self.db.execute("SELECT value FROM admin_metadata WHERE key='room_end_tracking_since'").fetchone()[0]
        scalar = lambda query, args=(): self.db.execute(query, args).fetchone()[0]
        operations = {"day": day.date().isoformat(), "timeZone": "Asia/Shanghai",
            "activeRooms": scalar("SELECT COUNT(*) FROM rooms WHERE status='active'"),
            "roomsCreatedToday": scalar("SELECT COUNT(*) FROM admin_room_lifecycle WHERE created_at>=? AND created_at<?", (start,end)),
            "roomsEndedToday": scalar("SELECT COUNT(*) FROM admin_room_lifecycle WHERE ended_at>=? AND ended_at<?", (start,end)),
            "totalRooms": scalar("SELECT COUNT(*) FROM admin_room_lifecycle"),
            "participatingIdentitiesToday": scalar("SELECT COUNT(DISTINCT user_id) FROM room_members WHERE joined_at>=? AND joined_at<?", (start,end)),
            "totalParticipatingIdentities": scalar("SELECT COUNT(DISTINCT user_id) FROM room_members"),
            "identityMetricNote": "按语聊入场记录去重，不代表账号 DAU 或实时在线人数；账号数据请切换账号服务查看。" if production else "按语聊入场记录去重；邀请码每次登录可生成新身份，不代表真实用户数或账号活跃。",
            "roomEndTrackingSince": iso(tracking)}
        if getattr(self, "safety", None) is not None:
            operations["activity"] = self.safety.metrics(now)
        fresh = self.sfu_at is not None and self.clock()-self.sfu_at <= 10 and not self.sfu_failed
        capacity = self.capacity()
        room_rows = self.db.execute("SELECT * FROM rooms WHERE status='active' ORDER BY created_at DESC,id LIMIT 1000").fetchall()
        capacity.update(activeParticipants=sum(self.sfu_rooms.get(row["id"], 0) for row in room_rows) if fresh else None,
                        sfuSampledAt=iso(self.sfu_wall) if self.sfu_wall is not None else None, sfuStale=not fresh)
        diagnostics = self.observability.snapshot(capacity)
        connection = diagnostics["connections"]
        connection.pop("rejectedByStatus", None)
        completed = connection["accepted"] + connection["rejected"]
        connection.update(windowSeconds=diagnostics["windowSeconds"],
            successPercent=round(100*connection["accepted"]/completed,2) if completed else None,
            sampleNote="窗口内已完成信令接入的成功占比；不是端到端入房成功率；进程重启后重新计数。")
        quality = {"windowSeconds": diagnostics["windowSeconds"], **diagnostics["quality"],
                   "sampleNote":"最近1000条、最长5分钟的设备上报样本；未知质量也计入样本总数，不代表已验证的音质。"}
        rooms = []
        for row in room_rows:
            room_id = row["id"]
            counts = self.db.execute("""SELECT COUNT(*) total,
                COALESCE(SUM(role='owner'),0) owners, COALESCE(SUM(role='admin'),0) admins,
                COALESCE(SUM(audio_muted),0) audio_muted, COALESCE(SUM(chat_muted),0) chat_muted
                FROM room_members WHERE room_id=? AND active=1""", (room_id,)).fetchone()
            seats = scalar("SELECT COUNT(*) FROM room_seats WHERE room_id=? AND user_id IS NOT NULL", (room_id,))
            rooms.append({"id": room_id, "title": row["title"], "category": row["category"], "createdAt": row["created_at"],
                "admittedParticipants": counts["total"], "onlineParticipants": self.sfu_rooms.get(room_id,0) if fresh else None,
                "sfuStale": not fresh, "occupiedSeats": seats, "totalSeats": 8, "owners": counts["owners"],
                "admins": counts["admins"], "listeners": max(0,counts["total"]-seats),
                "audioMutedMembers": counts["audio_muted"], "chatMutedMembers": counts["chat_muted"]})
        infrastructure = dict(self.host)
        infrastructure["stale"] = self.host_at is None or self.clock()-self.host_at > 30
        cleanup = scalar("SELECT COUNT(*) FROM media_cleanup")
        health = {"api": "healthy", "sfu": "healthy" if fresh else ("unavailable" if self.sfu_failed else "unknown"),
                  "pendingMediaCleanup": cleanup}
        alerts = list(diagnostics["alerts"])
        if not fresh:
            alerts.append({"code":"sfu_unavailable" if self.sfu_failed else "sfu_snapshot_stale", "level":"warning",
                           "message":"媒体服务采样失败或已过期，实际在线人数暂不可用。"})
        if infrastructure["stale"]:
            alerts.append({"code":"metrics_warming_up" if self.host_at is None else "host_metrics_stale", "level":"info" if self.host_at is None else "warning",
                           "message":"服务器采样尚未就绪。" if self.host_at is None else "服务器采样已过期。"})
        else:
            for key, threshold, code, message in (("cpuPercent",85,"cpu_high","CPU 使用率达到85%。"),
                    ("memoryPercent",85,"memory_high","内存使用率达到85%。"),
                    ("diskPercent",85,"disk_high","磁盘使用率达到85%。")):
                value = infrastructure[key]
                if value is not None and value >= threshold:
                    alerts.append({"code":code,"level":"warning","message":message})
            days = infrastructure["certificateDaysRemaining"]
            if days is not None and days <= 30:
                alerts.append({"code":"certificate_expiring","level":"critical" if days < 0 else "warning",
                               "message":"HTTPS 证书已过期。" if days < 0 else "HTTPS 证书将在30天内到期。"})
            if infrastructure["certificateExpiresAt"] is None:
                alerts.append({"code":"certificate_unknown","level":"info","message":"无法读取公共 HTTPS 证书到期时间。"})
            for service in infrastructure["services"]:
                if service["state"] in {"failed","inactive"}:
                    alerts.append({"code":"service_"+service["id"],"level":"critical","message":service["name"]+" 服务未运行。"})
        if cleanup:
            alerts.append({"code":"pending_media_cleanup","level":"warning","message":"存在待确认的媒体权限或退出清理任务。"})
        backup = backup_snapshot(now)
        if backup["healthy"] is False:
            alerts.append({"code":"backup_unhealthy","level":"warning","message":"备份已超过36小时、恢复校验失败或状态无效。"})
        elif backup["healthy"] is None:
            alerts.append({"code":"backup_unknown","level":"info","message":"尚无已验证的备份状态。"})
        return {"schemaVersion":1, "serverTime":iso(now),
            "service":{"id":SERVICE_ID,"name":"Kiki 自建语聊服务" if production else "LiveKit 语聊实验服务","host":"furby.top","mode":"single-host-production" if production else "single-host-laboratory","readOnly":True},
            "accountService":{"connected":False,"message":"本看板只包含语聊数据；账号运营数据请在运维 App 切换至账号服务。" if production else "账号服务尚未接入；下列身份是语聊实验参与身份，并非账号 DAU。"},
            "operations":operations,"capacity":capacity,"connections":connection,"quality":quality,
            "infrastructure":infrastructure,"health":health,"rooms":rooms,"alerts":alerts,
            "maintenance":{"backup":backup},
            "incidents":self.incidents.dashboard() if hasattr(self,"incidents") else None}


def build_admin_router(app, lock):
    router = APIRouter(prefix="/admin/v1")

    @router.post("/auth/session")
    async def login(payload: AdminLogin, request: Request):
        return await app.state.admin.login(payload, request)

    @router.delete("/auth/session")
    async def logout(request: Request):
        async with lock:
            digest = app.state.admin.authenticate(request)
            with app.state.db:
                app.state.db.execute("UPDATE admin_sessions SET revoked_at=? WHERE token_hash=?", (int(time.time()),digest))
            return {"revoked":True}

    @router.get("/dashboard")
    async def dashboard(request: Request):
        async with lock:
            app.state.admin.authenticate(request)
            return app.state.admin.dashboard()

    return router


if __name__ == "__main__":
    import sys
    if sys.argv[1:] != ["hash-password"]:
        raise SystemExit("Usage: python -m app.admin hash-password")
    first = getpass.getpass("Independent management passphrase: ")
    if not hmac.compare_digest(first.encode(), getpass.getpass("Confirm passphrase: ").encode()):
        raise SystemExit("Passphrases differ")
    print(hash_passphrase(first))
