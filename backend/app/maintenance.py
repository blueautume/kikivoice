"""Read only public backup status from one local regular file, never archives."""
import json
import os
from pathlib import Path
import stat
import time

STATUS_PATH = Path("/var/lib/kikitalk/backup-status.json")
MAX_AGE_SECONDS = 36 * 3600


def backup_status(at=None):
    now = time.time() if at is None else at
    unknown = {"lastSuccessAt": None, "verifiedAt": None, "backupAgeSeconds": None,
               "healthy": None, "lastError": None, "retentionDays": 7}
    try:
        descriptor = os.open(STATUS_PATH, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("Not a regular backup status file")
            body = stream.read(8193)
        if len(body) > 8192:
            raise ValueError("Backup status too large")
        value = json.loads(body)
        if (not isinstance(value, dict) or value.get("schemaVersion") != 1
                or value.get("service") != "account" or value.get("retentionDays") != 7):
            raise ValueError("Invalid backup status")
        stamps = [value.get(key) for key in ("lastSuccessAt", "verifiedAt")]
        if any(stamp is not None and (type(stamp) not in {int, float} or not 0 < stamp <= now+300)
               for stamp in stamps):
            raise ValueError("Invalid backup time")
        success, verified = stamps
        age = max(0, int(now-success)) if success is not None else None
        failed = bool(value.get("lastError"))
        healthy = (not failed and success is not None and verified is not None
                   and age <= MAX_AGE_SECONDS and now-verified <= MAX_AGE_SECONDS
                   and verified >= success)
        return {"lastSuccessAt": success, "verifiedAt": verified, "backupAgeSeconds": age,
                "healthy": healthy, "retentionDays": 7,
                "lastError": "最近一次备份或恢复校验未成功，请检查维护任务" if failed else None}
    except FileNotFoundError:
        return unknown
    except (OSError, ValueError, TypeError):
        return {**unknown, "lastError": "备份状态暂时无法读取，请检查维护任务"}
