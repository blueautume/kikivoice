"""Private owner intake and room-scoped, result-only relationship API."""
import hashlib
import itertools
import json
import re
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import relationship_engine as engine

SCHEMA = """
CREATE TABLE IF NOT EXISTS relationship_profiles(
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 payload TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0));
"""


def initialize(db):
    db.executescript(SCHEMA)


class ProfileUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    mbtiType: str | None = None
    zodiacSign: str | None = None
    birthCalendar: Literal["gregorian", "lunar"] = "gregorian"
    birthDate: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    birthLeapMonth: bool = False
    birthTime: str | None = Field(default=None, pattern=r"^(?:[01]\d|2[0-3]):[0-5]\d$")
    birthPlaceCode: str | None = Field(default=None, min_length=1, max_length=40)
    birthFold: int | None = Field(default=None, ge=0, le=1)
    # Legacy clients may send these fields. Current agreement consent governs
    # participation; user-editable labels, opt-outs and fold choices are ignored.
    baziEnabled: bool = True
    mbtiEnabled: bool = True
    zodiacEnabled: bool = True

    @field_validator("mbtiType")
    @classmethod
    def mbti(cls, value):
        if value is not None and value not in engine.MBTIS:
            raise ValueError("请选择有效MBTI类型")
        return value

    @field_validator("zodiacSign")
    @classmethod
    def zodiac(cls, value):
        if value is not None and value not in engine.ZODIACS:
            raise ValueError("请选择有效星座")
        return value


def read_profile(db, account_id):
    row = db.execute("SELECT payload,revision FROM relationship_profiles WHERE account_id=?", (account_id,)).fetchone()
    return (json.loads(row["payload"]), row["revision"]) if row else (dict(engine.DEFAULT_PROFILE), 0)


def no_store(response):
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Pragma"] = "no-cache"


def merge_profile(old, payload):
    legacy = {"zodiacSign", "birthFold", "baziEnabled", "mbtiEnabled", "zodiacEnabled"}
    return {**old, **payload.model_dump(exclude_unset=True, exclude=legacy)}


def build_router(app, *, database, consented_user, require_active_session):
    router = APIRouter(prefix="/v1")
    settings, bridge = app.state.settings, app.state.voice_bridge

    def guarded_user(user=Depends(consented_user)):
        if settings.rate_limit_enabled:
            app.state.social.limits.check(("relationships", user["account_id"]), 120, 60)
        return user

    def assemble(payload, user):
        with database(settings) as db:
            require_active_session(db, user)
            old, revision = read_profile(db, user["account_id"])
        merged = merge_profile(old, payload)
        try:
            result = engine.own_profile(merged, revision)
        except engine.ProfileError as error:
            raise HTTPException(422, str(error)) from None
        canonical = {key: result[key] for key in engine.DEFAULT_PROFILE}
        return canonical, result

    @router.get("/relationship-places")
    def list_places(response: Response, parent: str | None = Query(default=None, max_length=40), user=Depends(guarded_user)):
        no_store(response)
        try:
            return {"places": engine.places(parent)}
        except engine.ProfileError as error:
            raise HTTPException(422, str(error)) from None

    @router.get("/me/relationship-profile")
    def get_profile(response: Response, user=Depends(guarded_user)):
        no_store(response)
        with database(settings) as db:
            require_active_session(db, user)
            profile, revision = read_profile(db, user["account_id"])
            try:
                return engine.own_profile(profile, revision)
            except engine.ProfileError as error:
                raise HTTPException(422, str(error)) from None

    @router.post("/me/relationship-profile/preview")
    def preview(payload: ProfileUpdate, response: Response, user=Depends(guarded_user)):
        no_store(response)
        _, result = assemble(payload, user)
        return result

    @router.patch("/me/relationship-profile")
    def save(payload: ProfileUpdate, response: Response, user=Depends(guarded_user)):
        no_store(response)
        # Serialize the read/merge/write so disjoint partial PATCHes cannot lose data.
        with database(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            require_active_session(db, user)
            old, revision = read_profile(db, user["account_id"])
            merged = merge_profile(old, payload)
            try:
                result = engine.own_profile(merged, revision)
            except engine.ProfileError as error:
                raise HTTPException(422, str(error)) from None
            canonical = {key: result[key] for key in engine.DEFAULT_PROFILE}
            changed = canonical != old
            if changed:
                revision += 1
                db.execute("INSERT INTO relationship_profiles VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision",
                           (user["account_id"], json.dumps(canonical, ensure_ascii=False, sort_keys=True), revision))
            result["revision"] = revision
        if changed and settings.voice_bridge_enabled:
            try:
                bridge.post("/internal/v1/account/relationship-refresh", {"accountID": user["login_id"]})
            except HTTPException:
                # The saved profile remains authoritative. Room reads are uncached,
                # with periodic client refresh as recovery for a lost notification.
                pass
        return result

    @router.get("/voice/rooms/{room_id}/relations")
    def room_relations(room_id: str, response: Response, user=Depends(guarded_user)):
        no_store(response)
        if not re.fullmatch(r"lk_[a-f0-9]{32}", room_id):
            raise HTTPException(422, "房间编号无效")
        if not settings.voice_bridge_enabled:
            raise HTTPException(503, "房间关系暂时不可用")
        membership = bridge.post("/internal/v1/account/relationship-members", {"accountID": user["login_id"], "roomID": room_id})
        ids, revision = membership.get("memberIDs"), membership.get("roomRevision")
        if (membership.get("roomID") != room_id or not isinstance(ids, list) or len(ids) > 8
                or type(revision) is not int
                or any(not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_]{3,80}", identifier) for identifier in ids)
                or len(set(ids)) != len(ids)):
            raise HTTPException(503, "房间关系暂时不可用")
        # Reuse the authoritative social block snapshot; never bypass it simply
        # because another member remains in a public voice room.
        policy = app.state.social.policy(user, ids)
        blocked = set(policy.blockedUserIDs)
        ids = [identifier for identifier in ids if identifier not in blocked]
        prepared, versions, profiles, account_ids = {}, {}, [], {}
        with database(settings) as db:
            require_active_session(db, user)
            for identifier in ids:
                account = db.execute("SELECT a.* FROM accounts a WHERE a.login_id=? AND " + app.state.social.valid_account_sql(),
                                     (identifier, *app.state.social.legal_args)).fetchone()
                if account is None:
                    prepared[identifier], versions[identifier] = None, 0
                    account_ids[identifier] = None
                    continue
                account_ids[identifier] = account["account_id"]
                private, version = read_profile(db, account["account_id"])
                try:
                    prepared[identifier] = engine.own_profile(private, version)
                except engine.ProfileError:
                    # Historic invalid records never leak errors or become defaults.
                    prepared[identifier] = None
                versions[identifier] = version
                profiles.append({"userID": identifier, **engine.public_tags(db, account["account_id"])})
            require_active_session(db, user)
        pairs = [engine.room_pair(left, right, prepared[left], prepared[right]) for left, right in itertools.combinations(ids, 2)]
        # A save, withdrawal or deletion while the snapshot was being
        # calculated must not publish a stale private-data-derived result.
        with database(settings) as db:
            require_active_session(db, user)
            for identifier in ids:
                current = db.execute("SELECT a.account_id,COALESCE(r.revision,0) AS revision FROM accounts a LEFT JOIN relationship_profiles r ON r.account_id=a.account_id WHERE a.login_id=? AND " + app.state.social.valid_account_sql(),
                                     (identifier, *app.state.social.legal_args)).fetchone()
                current_id = current["account_id"] if current else None
                current_revision = current["revision"] if current else 0
                if current_id != account_ids[identifier] or current_revision != versions[identifier]:
                    raise HTTPException(409, "关系资料已更新，请刷新")
        fingerprint = json.dumps({"room": room_id, "roomRevision": revision, "profiles": versions, "rule": engine.RULE_VERSION}, sort_keys=True).encode()
        return {"roomID": room_id, "roomRevision": revision, "revision": hashlib.sha256(fingerprint).hexdigest(),
                "ruleVersion": engine.RULE_VERSION, "profiles": profiles, "pairs": pairs}

    return router
