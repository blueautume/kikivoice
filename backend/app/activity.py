"""Explicit foreground activity, with daily deduplication and bounded retention.

Session refresh, dashboards, health probes and background leases never call this
module. No device ID, IP address, exact click stream or Apple subject is stored.
"""
from datetime import datetime, timedelta
import time
from zoneinfo import ZoneInfo

RETENTION_DAYS = 35
ZONE = ZoneInfo("Asia/Shanghai")
SCHEMA = """
CREATE TABLE IF NOT EXISTS account_activity_daily(
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 day TEXT NOT NULL, PRIMARY KEY(account_id,day));
CREATE INDEX IF NOT EXISTS account_activity_day ON account_activity_daily(day);
CREATE TABLE IF NOT EXISTS account_activity_metadata(
 id INTEGER PRIMARY KEY CHECK(id=1), started_at INTEGER NOT NULL);
"""


def today(at=None):
    return datetime.fromtimestamp(time.time() if at is None else at, ZONE).date()


def initialize(db):
    db.executescript(SCHEMA)
    db.execute("INSERT OR IGNORE INTO account_activity_metadata VALUES(1,?)", (int(time.time()),))
    purge(db)


def purge(db, at=None):
    cutoff = today(at) - timedelta(days=RETENTION_DAYS - 1)
    db.execute("DELETE FROM account_activity_daily WHERE day<?", (cutoff.isoformat(),))


def record(db, account_id, at=None):
    day = today(at).isoformat()
    purge(db, at)
    db.execute("INSERT OR IGNORE INTO account_activity_daily VALUES(?,?)", (account_id, day))
    return {"recorded": True, "day": day, "retentionDays": RETENTION_DAYS}


def aggregate(db, at=None):
    current = today(at)
    day = current.isoformat()
    yesterday = (current - timedelta(days=1)).isoformat()
    week_start = (current - timedelta(days=6)).isoformat()
    month_start = (current - timedelta(days=29)).isoformat()
    scalar = lambda sql, args=(): db.execute(sql, args).fetchone()[0]
    started = scalar("SELECT started_at FROM account_activity_metadata WHERE id=1")
    series = {row[0]:row[1] for row in db.execute("""SELECT day,COUNT(*) FROM account_activity_daily
        WHERE day>=? AND day<=? GROUP BY day ORDER BY day""", (week_start, day))}
    yesterday_cohort = scalar("SELECT COUNT(*) FROM account_activity_daily WHERE day=?", (yesterday,))
    returned = scalar("""SELECT COUNT(*) FROM account_activity_daily a
        WHERE a.day=? AND EXISTS(SELECT 1 FROM account_activity_daily b
        WHERE b.account_id=a.account_id AND b.day=?)""", (day, yesterday))
    return {"day": day, "timeZone": "Asia/Shanghai", "retentionDays": RETENTION_DAYS,
            "trackingSince": started, "activeAccountsToday": series.get(day, 0),
            "activeAccountsLast7Days": scalar("""SELECT COUNT(DISTINCT account_id) FROM account_activity_daily
                WHERE day>=? AND day<=?""", (week_start, day)),
            "activeAccountsLast30Days": scalar("""SELECT COUNT(DISTINCT account_id) FROM account_activity_daily
                WHERE day>=? AND day<=?""", (month_start, day)),
            "returningAccountsToday": scalar("""SELECT COUNT(*) FROM account_activity_daily a
                WHERE a.day=? AND EXISTS(SELECT 1 FROM account_activity_daily b
                WHERE b.account_id=a.account_id AND b.day<? AND b.day>=?)""",
                (day, day, (current-timedelta(days=RETENTION_DAYS-1)).isoformat())),
            "previousDayCohortAccounts": yesterday_cohort, "previousDayReturnedAccounts": returned,
            "previousDayReturnPercent": round(returned*100/yesterday_cohort, 2) if yesterday_cohort else None,
            "dailySeries": [{"day": (current-timedelta(days=index)).isoformat(),
                              "activeAccounts": series.get((current-timedelta(days=index)).isoformat(), 0)}
                             for index in range(6, -1, -1)],
            "note": "仅统计已接入前台活跃上报的新版客户端：已同意条款的普通账号在 App 进入前台时按上海自然日去重；后台续租、有效登录凭证及运维账号不计入。今日回访指前34天活跃且今日再次活跃；昨日回访率另按昨日活跃队列计算。更早数据与未升级客户端不补算，撤回同意或注销后清除对应记录。"}
