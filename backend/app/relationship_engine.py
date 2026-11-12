"""Deterministic, server-only relationship calculations.

Birth details and chart evidence are private. Only the explicitly constructed
summaries from ``room_pair`` may enter a room response. Calendar dependency:
lunar-python 1.4.9 (MIT). True-solar convention follows the read-only reference
project: physical solar terms, apparent-solar day/hour, sect 2 midnight boundary.
"""
from datetime import datetime, timedelta, timezone, date
from functools import lru_cache
import json
import math
from pathlib import Path
import threading
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from lunar_python import Solar, Lunar, LunarYear

RULE_VERSION = "kiki-relations-1.1.0"
CHART_VERSION = "true-solar-1.1.0-lunar-python-1.4.9"
ZODIACS = ("白羊座", "金牛座", "双子座", "巨蟹座", "狮子座", "处女座", "天秤座", "天蝎座", "射手座", "摩羯座", "水瓶座", "双鱼座")
MBTIS = {a+b+c+d for a in "IE" for b in "NS" for c in "FT" for d in "JP"}
ZONES = {"CN": "Asia/Shanghai", "HK": "Asia/Hong_Kong", "MO": "Asia/Macau", "TW": "Asia/Taipei"}
DEFAULT_PROFILE = dict(mbtiType=None, zodiacSign=None, birthCalendar="gregorian", birthDate=None,
                       birthLeapMonth=False, birthTime=None, birthPlaceCode=None, birthFold=None,
                       baziEnabled=True, mbtiEnabled=True, zodiacEnabled=True)
CALENDAR_LOCK = threading.RLock()


class ProfileError(ValueError):
    """Safe user-facing error; never include the raw request or private chart."""


@lru_cache(maxsize=1)
def district_catalog():
    raw = json.loads(Path(__file__).with_name("relationship_places.json").read_text())["districts"]
    by_id = {row["id"]: dict(row) for row in raw}
    parents = {row.get("parent") for row in raw}
    for row in by_id.values():
        path, current = [], row
        while current:
            path.append(current["name"])
            if current.get("country"):
                row["country"] = current["country"]
            current = by_id.get(current.get("parent"))
        row["fullName"] = "".join(reversed(path))
        row["timeZone"] = ZONES[row["country"]]
        row["hasChildren"] = row["id"] in parents
    return by_id


def places(parent=None):
    catalog = district_catalog()
    if parent is not None and parent not in catalog:
        raise ProfileError("所选地区不存在，请重新选择")
    return [{"id": p["id"], "name": p["name"], "fullName": p["fullName"],
             "hasChildren": p["hasChildren"], "hasCoordinates": valid_point(p), "timeZone": p["timeZone"]}
            for p in catalog.values() if p.get("parent") == parent]


def valid_point(point):
    lat, lon = point.get("latitude"), point.get("longitude")
    return (isinstance(lat, (float, int)) and isinstance(lon, (float, int))
            and math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180)


def date_details(profile):
    """Return both calendar representations without inventing a birth time."""
    if not profile.get("birthDate"):
        return None
    try:
        year, month, day = (int(v) for v in profile["birthDate"].split("-"))
        if not 1900 <= year <= 2100:
            raise ValueError()
        if profile["birthCalendar"] == "lunar":
            lunar_month = -month if profile["birthLeapMonth"] else month
            item = LunarYear.fromYear(year).getMonth(lunar_month)
            if item is None or not 1 <= day <= item.getDayCount():
                raise ValueError()
            solar = Lunar.fromYmd(year, lunar_month, day).getSolar()
            civil = date(solar.getYear(), solar.getMonth(), solar.getDay())
        else:
            civil = date(year, month, day)
        if not 1900 <= civil.year <= 2100:
            raise ValueError()
        lunar = Solar.fromYmd(civil.year, civil.month, civil.day).getLunar()
        return dict(gregorianBirthDate=civil.isoformat(),
                    lunarBirthDate=f"{lunar.getYear():04d}-{abs(lunar.getMonth()):02d}-{lunar.getDay():02d}",
                    lunarBirthLeapMonth=lunar.getMonth() < 0)
    except (ValueError, TypeError, AttributeError, IndexError):
        raise ProfileError("出生日期无效，请核对日期、历法及是否为闰月") from None


def civil_instant(civil, zone_id, fold=None):
    """Resolve historical civil time automatically; repeated clocks use the first.

    ``fold`` remains accepted only for old internal callers. It cannot override
    this rule. Nonexistent wall-clock records are rejected, never normalized.
    """
    try:
        zone = ZoneInfo(zone_id)
    except ZoneInfoNotFoundError:
        raise ProfileError("出生地时区无法确认，请重新选择出生地") from None
    candidates = {}
    for candidate_fold in (0, 1):
        aware = civil.replace(tzinfo=zone, fold=candidate_fold)
        instant = aware.astimezone(timezone.utc)
        if instant.astimezone(zone).replace(tzinfo=None) == civil:
            candidates[candidate_fold] = instant
    unique = set(candidates.values())
    if not unique:
        raise ProfileError("这个出生钟表时间在当地时区中不存在，请核对夏令时记录")
    return candidates.get(0, next(iter(candidates.values())))


def equation_of_time(instant):
    """NOAA/Meeus Julian-century equation, apparent minus mean solar minutes."""
    jd = instant.timestamp() / 86400 + 2440587.5
    t = (jd - 2451545) / 36525
    rad = math.pi / 180
    longitude = (280.46646 + t * (36000.76983 + t * .0003032)) % 360 * rad
    anomaly = (357.52911 + t * (35999.05029 - .0001537 * t)) * rad
    eccentricity = .016708634 - t * (.000042037 + .0000001267 * t)
    seconds = 21.448 - t * (46.815 + t * (.00059 - t * .001813))
    mean_obliquity = 23 + (26 + seconds / 60) / 60
    omega = (125.04 - 1934.136 * t) * rad
    obliquity = (mean_obliquity + .00256 * math.cos(omega)) * rad
    y = math.tan(obliquity / 2) ** 2
    value = (y * math.sin(2 * longitude) - 2 * eccentricity * math.sin(anomaly)
             + 4 * eccentricity * y * math.sin(anomaly) * math.cos(2 * longitude)
             - .5 * y * y * math.sin(4 * longitude)
             - 1.25 * eccentricity * eccentricity * math.sin(2 * anomaly))
    return 4 * value / rad


def apparent_clock(instant, longitude):
    # UTC components of this value represent a clock face, not a physical instant.
    return instant.astimezone(timezone.utc) + timedelta(seconds=longitude * 240 + equation_of_time(instant) * 60)


def four_pillars(instant, longitude):
    def chart(clock):
        solar = Solar.fromYmdHms(clock.year, clock.month, clock.day, clock.hour, clock.minute, clock.second)
        result = solar.getLunar().getEightChar()
        result.setSect(2)
        return result
    physical = chart(instant.astimezone(timezone(timedelta(hours=8))))
    apparent = chart(apparent_clock(instant, longitude))
    return [physical.getYear(), physical.getMonth(), apparent.getDay(), apparent.getTime()]


def own_profile(profile, revision=0):
    # The upstream calendar has process-global year caches. Match the reference
    # actor's serialized calendar access across FastAPI worker threads.
    with CALENDAR_LOCK:
        return _own_profile(profile, revision)


def _own_profile(profile, revision=0):
    # Callers must first establish current agreement consent. New agreement
    # participation replaces legacy per-profile opt-out fields; no bulk rewrite
    # or unauthenticated migration of old private records is performed.
    result = {**DEFAULT_PROFILE, **profile, "revision": revision}
    result.update(baziEnabled=True, mbtiEnabled=True, zodiacEnabled=True,
                  birthFold=None, zodiacSign=None)
    if result["birthCalendar"] == "gregorian":
        result["birthLeapMonth"] = False
    details = date_details(result)
    result.update(details or dict(gregorianBirthDate=None, lunarBirthDate=None, lunarBirthLeapMonth=None))
    point = district_catalog().get(result.get("birthPlaceCode"))
    if result.get("birthPlaceCode") and point is None:
        raise ProfileError("所选出生地不存在，请重新选择")
    result["birthPlaceName"] = point["fullName"] if point else None
    result["birthTimeZone"] = point["timeZone"] if point else None
    if details:
        result["zodiacSign"] = zodiac_from_date(details["gregorianBirthDate"])
    missing = "请填写出生日期" if not details else "请填写出生时刻" if not result["birthTime"] else "请选择出生地" if not point else "出生地坐标待确认" if not valid_point(point) else None
    if missing:
        result["chart"] = {"status": "incomplete", "message": missing, "ruleVersion": CHART_VERSION}
        return result
    civil = datetime.fromisoformat(details["gregorianBirthDate"] + "T" + result["birthTime"])
    instant = civil_instant(civil, point["timeZone"])
    apparent = apparent_clock(instant, point["longitude"])
    result["chart"] = {"status": "ready", "pillars": four_pillars(instant, point["longitude"]),
                       "trueSolarTime": apparent.strftime("%Y-%m-%d %H:%M:%S"),
                       "civilTime": civil.strftime("%Y-%m-%d %H:%M") + " · " + point["timeZone"],
                       "ruleVersion": CHART_VERSION,
                       "message": "真太阳时定日时柱，实际交节定年月柱，零点换日；历史时制自动判断，重复钟点采用第一次；地区坐标为代表点"}
    return result


def zodiac_from_date(gregorian_date):
    civil = date.fromisoformat(gregorian_date)
    return Solar.fromYmd(civil.year, civil.month, civil.day).getXingZuo() + "座"


def public_tags(db, account_id):
    """Project an account already authorized by the caller's current-consent SQL.

    Derive the sign again rather than trusting legacy manually chosen labels.
    No chart or birth field can enter the public return value.
    """
    row = db.execute("SELECT payload FROM relationship_profiles WHERE account_id=?", (account_id,)).fetchone()
    profile = {**DEFAULT_PROFILE, **json.loads(row[0])} if row else DEFAULT_PROFILE
    with CALENDAR_LOCK:
        try:
            details = date_details(profile)
            zodiac = zodiac_from_date(details["gregorianBirthDate"]) if details else None
        except ProfileError:
            zodiac = None
    # Explicit public allowlist. Never return birth fields or chart material here.
    return {"mbtiType": profile.get("mbtiType") if profile.get("mbtiType") in MBTIS else None,
            "zodiacSign": zodiac}


def relation(code, label, description, harmony=None, conflict=None):
    return {"code": code, "label": label, "description": description,
            "harmonyIndex": harmony, "conflictIndex": conflict}


# Short, playful introductions; classification and indices remain independent
# of presentation copy. No private chart evidence belongs in these strings.
RELATION_DESCRIPTIONS = {
    "HARMONY_ONLY": "默契合拍。聊天有种接得上话的感觉，共同兴趣很适合开场。偶尔分享一点不同想法，让熟悉的节奏也有新鲜感。",
    "CONFLICT_ONLY": "火花碰撞。各有主见，聊天容易冒出火花，也可能忍不住较劲。不同意见先说清楚，把争输赢换成一起找有趣的答案。",
    "MIXED": "欢喜冤家。聊得来，也容易斗嘴，互动里常有一点小较劲。享受彼此懂的部分，较劲时缓一拍，把真心话直接说出来。",
    "NONE": "慢热探索。默契适合慢慢培养，先别急着判断合不合拍。从共同话题或小游戏开始，多聊几次，再发现你们独有的节奏。",
    "GOLDEN": "互补来电。不同的思路能给聊天添些新鲜感，适合互相接住新点子。多问问对方为什么这样想，让差异成为有趣的话题。",
    "SILVER": "同频共鸣。关注的话题有些相近，接话亲切，又能听到不同角度。先聊共同兴趣，也给对方的小习惯和独特想法留点空间。",
    "PEDAGOGUE": "灵感搭子。适合交换思路，轮流当彼此的小老师。少一点说教，多一点好奇，问问对方的理由，让聊天多出有趣的新发现。",
    "SAME_TYPE": "同款默契。偏好相近，聊天像遇到熟悉的脑回路，接话很有亲切感。也多聊聊各自不同的经历，让相似的组合有新故事。",
    "OTHER": "自由搭配。你们没有固定的相处剧本，合不合拍可以边聊边发现。从共同兴趣开始，试试不同话题，找到自己的聊天节奏。",
    "SAME_SIGN": "同频搭子。熟悉感是这组的聊天关键词，共同喜好很适合开场。别急着以为已经懂了对方，也听听那些不一样的小故事。",
    "ADJACENT": "好奇搭子。既有一点亲近感，也有值得好奇的不同之处。交换喜欢的小事和日常习惯，节奏不同时慢一点，给新鲜感留些空间。",
    "SEXTILE": "轻松接球。适合一来一回地接话，轻松互动就是这组的亮点。主动递个新话题或小游戏，也给对方接球的时间，聊天更有趣。",
    "SQUARE": "火花搭子。聊天有来有往，也容易因为不同想法斗嘴较劲。把想法说清楚，少让对方猜，一起完成个小挑战，让火花变成乐趣。",
    "TRINE": "舒服合拍。相处的关键词是自在，聊天不妨跟着舒服的节奏走。偶尔主动关心，或一起尝试点新鲜事，让轻松的互动多点温度。",
    "QUINCUNX": "新奇磨合。想法和习惯可能不在同一频道，好奇心能打开新话题。把期待说具体，给彼此一点调整的时间，慢慢找到共同节奏。",
    "OPPOSITION": "反差来电。不同的表达和习惯让互动有张力，也有互补的想象空间。先听懂另一边的想法，再一起找平衡，别急着把对话变成辩论。",
    "UNAVAILABLE": "稍后揭晓。当前还不能展示这组关系的介绍，先把注意力留给聊天。稍后刷新再看看，你们的相处也可以从一个有趣的话题开始。",
}


def unavailable():
    # Never identify which private field is missing or which account lacks consent.
    return relation("UNAVAILABLE", "暂无法展示关系", RELATION_DESCRIPTIONS["UNAVAILABLE"])


HARMONIES = ("子丑", "寅亥", "卯戌", "辰酉", "巳申", "午未")
CONFLICTS = ("子午", "丑未", "寅申", "卯酉", "辰戌", "巳亥")


def bazi_relation(a, b):
    if not a or not b:
        return unavailable()
    pa, pb = a.get("chart", {}).get("pillars"), b.get("chart", {}).get("pillars")
    if not pa or not pb:
        return unavailable()
    weights = (1, 2, 4, 1)
    indexes = []
    for group in (HARMONIES, CONFLICTS):
        hits = {}
        for i, left in enumerate(pa):
            for j, right in enumerate(pb):
                key = frozenset((left[-1], right[-1]))
                for named in group:
                    if key == frozenset(named):
                        hits[named] = max(hits.get(named, 0), min(weights[i], weights[j]))
        indexes.append((100 * sum(hits.values()) + 4) // 8)
    harmony, conflict = indexes
    code, label = (("MIXED", "合冲并见") if harmony and conflict else ("HARMONY_ONLY", "相合") if harmony
                   else ("CONFLICT_ONLY", "相冲") if conflict else ("NONE", "未命中直接合冲"))
    return relation(code, label, RELATION_DESCRIPTIONS[code], harmony, conflict)


MBTI_PAIRS = {
    "GOLDEN": (("INFJ", "ENFP"), ("ENFJ", "INFP"), ("INTJ", "ENTP"), ("ENTJ", "INTP"), ("ESFP", "ISFJ"), ("ESTP", "ISTJ"), ("ISFP", "ESFJ"), ("ISTP", "ESTJ")),
    "SILVER": (("INFJ", "INFP"), ("ENFJ", "ENFP"), ("INTJ", "INTP"), ("ENTJ", "ENTP"), ("ISFP", "ISFJ"), ("ISTP", "ISTJ"), ("ESFP", "ESFJ"), ("ESTP", "ESTJ")),
    "PEDAGOGUE": (("INFJ", "ENTP"), ("ENFJ", "INTP"), ("INFP", "ENTJ"), ("ENFP", "INTJ"), ("ESFP", "ISTJ"), ("ISFP", "ESTJ"), ("ESTP", "ISFJ"), ("ISTP", "ESFJ"))}


def mbti_relation(a, b):
    if not a or not b or not a.get("mbtiType") or not b.get("mbtiType"):
        return unavailable()
    left, right = a["mbtiType"], b["mbtiType"]
    code = "SAME_TYPE" if left == right else next((name for name, pairs in MBTI_PAIRS.items() if any({left, right} == set(pair) for pair in pairs)), "OTHER")
    label = {"GOLDEN": "黄金配对", "SILVER": "白银配对", "PEDAGOGUE": "师生配对",
             "SAME_TYPE": "同类型", "OTHER": "其他组合"}[code]
    return relation(code, label, RELATION_DESCRIPTIONS[code])


def zodiac_relation(a, b):
    if not a or not b or a.get("zodiacSign") not in ZODIACS or b.get("zodiacSign") not in ZODIACS:
        return unavailable()
    delta = abs(ZODIACS.index(a["zodiacSign"]) - ZODIACS.index(b["zodiacSign"]))
    distance = min(delta, 12-delta)
    code, label = (("SAME_SIGN", "同星座"), ("ADJACENT", "相邻星座"), ("SEXTILE", "六分"), ("SQUARE", "刑"), ("TRINE", "拱"), ("QUINCUNX", "梅花"), ("OPPOSITION", "对宫"))[distance]
    return relation(code, label, RELATION_DESCRIPTIONS[code])


def room_pair(a_id, b_id, a, b):
    return {"aID": a_id, "bID": b_id, "bazi": bazi_relation(a, b),
            "mbti": mbti_relation(a, b), "zodiac": zodiac_relation(a, b)}
