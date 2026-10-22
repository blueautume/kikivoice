"""Independent read-only account administration and bounded host sampling.

No ordinary application bearer, user name, identity, message, IP, private key or
quality sample is exposed or stored by this module. Only aggregate account statistics are returned.
"""
import asyncio
from contextlib import suppress
from datetime import datetime, timedelta, timezone
import getpass
import hashlib
import hmac
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import time
from zoneinfo import ZoneInfo

from . import push

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator
from . import activity, maintenance, social

SERVICE_ID = "account"
SESSION_SECONDS = 8 * 3600
HASH_ITERATIONS = 600_000
HASH_PATTERN = re.compile(r"pbkdf2_sha256\$600000\$([a-f0-9]{32})\$([a-f0-9]{64})")
SERVICE_UNITS = (("api", "账号 API", "kikitalk.service"),
                 ("nginx", "Nginx", "nginx.service"))
METRIC_KEYS = ("cpuPercent", "cpuCores", "memoryUsedBytes", "memoryTotalBytes",
               "memoryPercent", "diskUsedBytes", "diskTotalBytes", "diskPercent",
               "networkReceiveBytesPerSecond", "networkTransmitBytesPerSecond",
               "uptimeSeconds", "certificateExpiresAt", "certificateDaysRemaining")


def iso(at=None):
    return datetime.fromtimestamp(time.time() if at is None else at, timezone.utc).isoformat()


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
    if not Path(settings.admin_tls_cert_path).is_absolute():
        raise RuntimeError("Management certificate path must be absolute")
    if not re.fullmatch(r"[a-zA-Z0-9_.@-]+\.service", settings.admin_api_systemd_unit):
        raise RuntimeError("Management API systemd unit must be a fixed service name")


def initialize_admin_database(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS account_admin_sessions (
        token_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL,
        credential_fingerprint TEXT NOT NULL);
    """)


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
    def __init__(self, certificate_path, *, api_unit="kikitalk.service", proc_root="/proc", clock=time.monotonic, wall_clock=time.time):
        self.certificate_path = certificate_path
        self.api_unit = api_unit
        self.proc = Path(proc_root)
        self.clock = clock
        self.wall_clock = wall_clock
        self.previous = None

    def read(self, filename):
        with (self.proc / filename).open("r", encoding="ascii") as stream:
            return stream.read(128 * 1024)

    def services(self):
        result = []
        for key, name, unit in SERVICE_UNITS:
            if key == "api":
                unit = self.api_unit
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



def collect_storage(settings):
    storage = {"databaseBytes": None, "avatarFiles": None, "avatarBytes": None, "avatarScanLimited": False,
               "sampleNote": "数据库含主文件及当前 WAL/SHM；头像仅统计本服务器头像目录的普通 JPEG 文件，不跟随符号链接。"}
    try:
        storage["databaseBytes"] = sum(path.stat().st_size for path in
            (Path(settings.db_path), Path(settings.db_path + "-wal"), Path(settings.db_path + "-shm")) if path.is_file())
    except OSError:
        pass
    try:
        count = size = scanned = 0
        with os.scandir(settings.avatar_path) as entries:
            for entry in entries:
                scanned += 1
                if scanned > 100_000:
                    storage["avatarScanLimited"] = True
                    break
                if re.fullmatch(r"[a-f0-9]{64}\.jpg", entry.name) and entry.is_file(follow_symlinks=False):
                    count += 1
                    size += entry.stat(follow_symlinks=False).st_size
        if not storage["avatarScanLimited"]:
            storage.update(avatarFiles=count, avatarBytes=size)
    except OSError:
        pass
    return storage

class AdminService:
    """Independent credential namespace; no ordinary account token is accepted."""
    def __init__(self, settings, database, client_ip=None, *, collector=None,
                 clock=time.monotonic, wall_clock=time.time):
        self.settings, self.database = settings, database
        self.client_ip = client_ip or (lambda request: request.client.host if request.client else "unknown")
        self.clock, self.wall_clock = clock, wall_clock
        self.fingerprint = hashlib.sha256(settings.admin_passphrase_hash.encode()).hexdigest()
        self.collector = collector or HostCollector(settings.admin_tls_cert_path, api_unit=settings.admin_api_systemd_unit)
        self.host, self.host_at = empty_host_snapshot(), None
        self.storage = {"databaseBytes":None, "avatarFiles":None, "avatarBytes":None, "avatarScanLimited":False,
                        "sampleNote":"账号服务器存储指标尚未采样。"}
        self.task = None
        self.login_slots = asyncio.Semaphore(2)
        self.lock = asyncio.Lock()
        self.login_events = {}

    @property
    def enabled(self):
        return bool(self.settings.admin_passphrase_hash) or getattr(self.settings,"admin_auth_mode","legacy") == "passkey"

    def start(self):
        if self.enabled:
            self.task = asyncio.create_task(self.maintain())

    async def close(self):
        if self.task:
            self.task.cancel()
            with suppress(asyncio.CancelledError):
                await self.task

    async def sample_host(self):
        try:
            def collect():
                return self.collector.collect(), collect_storage(self.settings)
            self.host, self.storage = await asyncio.wait_for(asyncio.to_thread(collect), timeout=5)
            self.host_at = self.clock()
        except (Exception, asyncio.TimeoutError):
            pass

    async def maintain(self):
        while True:
            next_sample = self.clock() + 10
            await self.sample_host()
            async with self.lock:
                with self.database(self.settings) as db:
                    db.execute("DELETE FROM account_admin_sessions WHERE expires_at<=? OR credential_fingerprint!=?",
                               (int(self.wall_clock()), self.fingerprint))
            await asyncio.sleep(max(0, next_sample - self.clock()))

    def check_request(self, request):
        if getattr(self.settings,"admin_auth_mode","legacy") != "legacy":
            raise HTTPException(404, "原口令管理入口已停用")
        origin = request.headers.get("origin")
        if origin is not None and origin != "https://kiki.group":
            raise HTTPException(403, "管理请求来源不符合配置")
        if request.headers.get("sec-fetch-site") in {"cross-site", "same-site"}:
            raise HTTPException(403, "管理请求来源不符合配置")
        if not self.enabled:
            raise HTTPException(503, "管理登录尚未配置")

    def rate_limit_login(self, request):
        now = self.clock()
        self.login_events = {key: [at for at in values if at > now - 300]
                             for key, values in self.login_events.items() if values and values[-1] > now - 300}
        for key, maximum in (("total", 30), ("ip:" + self.client_ip(request), 5)):
            events = self.login_events.setdefault(key, [])
            if len(events) >= maximum:
                raise HTTPException(429, "管理登录过于频繁，请稍后重试", headers={"Retry-After": "300"})
            events.append(now)

    def authenticate(self, request, db):
        self.check_request(request)
        value = request.headers.get("authorization", "")
        if not value.startswith("Bearer ") or not re.fullmatch(r"[A-Za-z0-9_-]{43}", value[7:]):
            raise HTTPException(401, "管理登录已过期，请重新登录")
        digest = hashlib.sha256(value[7:].encode()).hexdigest()
        found = db.execute("SELECT 1 FROM account_admin_sessions WHERE token_hash=? AND expires_at>? AND credential_fingerprint=?",
                           (digest, int(self.wall_clock()), self.fingerprint)).fetchone()
        if found is None:
            raise HTTPException(401, "管理登录已过期，请重新登录")
        return digest

    async def login(self, payload, request):
        self.check_request(request)
        self.rate_limit_login(request)  # Always enabled, including tests that disable user rate limits.
        if self.login_slots.locked():
            raise HTTPException(429, "管理登录繁忙，请稍后重试", headers={"Retry-After": "5"})
        async with self.login_slots:
            valid = await asyncio.to_thread(verify_passphrase, payload.passphrase, self.settings.admin_passphrase_hash)
        if not valid:
            raise HTTPException(401, "管理口令不正确")
        raw = secrets.token_urlsafe(32)
        expires = int(self.wall_clock()) + SESSION_SECONDS
        async with self.lock:
            with self.database(self.settings) as db:
                db.execute("DELETE FROM account_admin_sessions WHERE expires_at<=? OR credential_fingerprint!=?",
                           (int(self.wall_clock()), self.fingerprint))
                if db.execute("SELECT COUNT(*) FROM account_admin_sessions").fetchone()[0] >= 32:
                    raise HTTPException(429, "管理设备数量已达上限，请先退出其他设备", headers={"Retry-After": "300"})
                db.execute("INSERT INTO account_admin_sessions VALUES(?,?,?)",
                           (hashlib.sha256(raw.encode()).hexdigest(), expires, self.fingerprint))
        return {"token": raw, "expiresAt": expires, "serviceID": SERVICE_ID, "role": "viewer"}

    def dashboard(self, db):
        now = self.wall_clock()
        day = datetime.fromtimestamp(now, ZoneInfo("Asia/Shanghai")).replace(hour=0, minute=0, second=0, microsecond=0)
        start, end = int(day.timestamp()), int((day + timedelta(days=1)).timestamp())
        scalar = lambda query, args=(): db.execute(query, args).fetchone()[0]
        operations = {
            "day": day.date().isoformat(), "timeZone": "Asia/Shanghai",
            "totalAccounts": scalar("SELECT COUNT(*) FROM accounts"),
            "accountsCreatedToday": scalar("SELECT COUNT(*) FROM accounts WHERE created_at>=? AND created_at<?", (start,end)),
            "validBusinessSessions": scalar("SELECT COUNT(*) FROM sessions WHERE expires_at>?", (now,)),
            "accountsWithValidSessions": scalar("SELECT COUNT(DISTINCT account_id) FROM sessions WHERE expires_at>?", (now,)),
            "accountsWithSessionsCreatedToday": scalar("SELECT COUNT(DISTINCT account_id) FROM sessions WHERE created_at>=? AND created_at<? AND expires_at>?", (start,end,now)),
            "sessionMetricNote": "有效业务会话指尚未过期且未被删除的登录凭证，可能包含离线设备；今日新建会话账号仅统计当前仍有效的会话，不代表在线人数、实际 API 活跃或 DAU。",
            "appleAuthorizedAccounts": scalar("SELECT COUNT(*) FROM apple_credentials"),
            "pendingAppleRevocations": scalar("SELECT COUNT(*) FROM apple_revocations"),
            "dueAppleRevocations": scalar("SELECT COUNT(*) FROM apple_revocations WHERE next_attempt_at<=?", (now,)),
            "appleMetricNote": "已保存加密 Apple 授权凭据的账号数；待撤销队列为账号注销或授权撤回后等待 Apple 确认的授权，不包含账号明细。",
            "accountsWithCustomAvatar": scalar("SELECT COUNT(*) FROM accounts WHERE avatar_filename IS NOT NULL")}
        operations["activity"] = activity.aggregate(db, now)
        operations["social"] = social.metrics(db, now)
        backup = maintenance.backup_status(now)
        storage = dict(self.storage)
        infrastructure = dict(self.host)
        infrastructure["stale"] = self.host_at is None or self.clock() - self.host_at > 30
        alerts = []
        if infrastructure["stale"]:
            alerts.append({"code":"host_metrics_stale", "level":"info", "message":"账号主机指标未就绪或已过期。"})
        else:
            for key, code, message in (("cpuPercent","cpu_high","账号服务器 CPU 达到 85%。"),
                                      ("memoryPercent","memory_high","账号服务器内存达到 85%。"),
                                      ("diskPercent","disk_high","账号服务器磁盘达到 85%。")):
                if infrastructure[key] is not None and infrastructure[key] >= 85:
                    alerts.append({"code":code,"level":"warning","message":message})
            days = infrastructure["certificateDaysRemaining"]
            if days is not None and days <= 30:
                alerts.append({"code":"certificate_expiring","level":"critical" if days < 0 else "warning",
                               "message":"账号服务 HTTPS 证书已过期。" if days < 0 else "账号服务 HTTPS 证书将在 30 天内到期。"})
            for service in infrastructure["services"]:
                if service["state"] in {"failed", "inactive"}:
                    alerts.append({"code":"service_"+service["id"],"level":"critical","message":service["name"]+" 服务未运行。"})
        if operations["pendingAppleRevocations"]:
            alerts.append({"code":"apple_revocations_pending","level":"warning","message":"存在等待 Apple 确认的授权撤销任务。"})
        if backup["healthy"] is False or backup["lastError"]:
            alerts.append({"code":"backup_attention","level":"warning",
                           "message":backup["lastError"] or "账号服务备份或恢复校验已超过36小时，请检查维护任务。"})
        return {"schemaVersion":1,"serverTime":iso(now),
                "service":{"id":SERVICE_ID,"name":"Kiki 账号服务","host":"kiki.group","mode":"account","readOnly":True},
                "voiceService":{"included":False,"message":"语音房间、在线人数与音频质量请切换至 furby.top 语聊服务查看。"},
                "operations":operations,"storage":storage,"infrastructure":infrastructure,
                "push":push.metrics(db,self.settings,now),
                "maintenance":{"backup":backup},
                "health":{"api":"healthy"},"alerts":alerts}


def build_admin_router(app):
    router = APIRouter(prefix="/admin/v1")

    @router.post("/auth/session")
    async def login(payload: AdminLogin, request: Request):
        return await app.state.admin.login(payload, request)

    @router.delete("/auth/session")
    async def logout(request: Request):
        service = app.state.admin
        async with service.lock:
            with service.database(service.settings) as db:
                digest = service.authenticate(request, db)
                db.execute("DELETE FROM account_admin_sessions WHERE token_hash=?", (digest,))
        return {"revoked":True}

    @router.get("/dashboard")
    async def dashboard(request: Request):
        service = app.state.admin
        async with service.lock:
            with service.database(service.settings) as db:
                service.authenticate(request, db)
                return service.dashboard(db)

    return router


if __name__ == "__main__":
    import sys
    if sys.argv[1:] != ["hash-password"]:
        raise SystemExit("Usage: python -m app.admin hash-password")
    first = getpass.getpass("Independent account management passphrase: ")
    if not hmac.compare_digest(first.encode(), getpass.getpass("Confirm passphrase: ").encode()):
        raise SystemExit("Passphrases differ")
    print(hash_passphrase(first))
