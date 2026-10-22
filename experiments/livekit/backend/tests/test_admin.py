"""Independent management scope, accurate unknowns, migration and bounded sampling."""
from collections import deque
from contextlib import contextmanager
from dataclasses import replace
from datetime import datetime, timezone
import hashlib
import json
import threading
import time
from types import SimpleNamespace

from fastapi.testclient import TestClient
import pytest

from app.admin import AdminService, HostCollector, empty_host_snapshot, hash_passphrase, initialize_admin_database, verify_passphrase
from app.main import create_app, Limiter
from conftest import FakeLiveKit, create_room, headers, login
from test_room_actions import token

PASSPHRASE = "independent-admin-test-passphrase"
HASH = hash_passphrase(PASSPHRASE, salt="a"*32)


@contextmanager
def management_lab(lab, monkeypatch, **changes):
    monkeypatch.setattr(AdminService, "start", lambda self: None)
    settings = replace(lab.settings, db_path=lab.settings.db_path+".admin", admin_passphrase_hash=HASH, **changes)
    rtc = FakeLiveKit(settings)
    app = create_app(settings, rtc)
    with TestClient(app) as client:
        yield SimpleNamespace(client=client, app=app, rtc=rtc, settings=settings, consent=lab.consent, legal_path=lab.legal_path)


@pytest.fixture
def admin(lab, monkeypatch):
    with management_lab(lab, monkeypatch) as instance:
        yield instance


def admin_login(admin, passphrase=PASSPHRASE):
    response = admin.client.post("/admin/v1/auth/session", json={"passphrase":passphrase})
    assert response.status_code == 200, response.text
    return response.json()


def dashboard(admin, account=None):
    account = account or admin_login(admin)
    response = admin.client.get("/admin/v1/dashboard", headers=headers(account))
    assert response.status_code == 200, response.text
    assert response.headers["cache-control"] == "no-store"
    return response.json()


def sample_sfu(admin):
    admin.client.portal.call(admin.app.state.admin.sample_sfu)


def test_unconfigured_admin_is_disabled_without_affecting_user_api(lab):
    assert lab.client.post("/admin/v1/auth/session", json={"passphrase":PASSPHRASE}).status_code == 503
    assert lab.client.get("/admin/v1/dashboard").status_code == 503
    assert lab.client.get("/v1/me", headers=headers(login(lab))).status_code == 200


def test_passphrase_hash_is_salted_strict_and_config_is_validated(admin):
    assert verify_passphrase(PASSPHRASE, HASH)
    assert not verify_passphrase(PASSPHRASE+" ", HASH)
    assert not verify_passphrase(PASSPHRASE, "malformed")
    assert hash_passphrase(PASSPHRASE) != hash_passphrase(PASSPHRASE)
    for value in ("short", "a"*257):
        with pytest.raises(ValueError): hash_passphrase(value)
    for changes in ({"admin_passphrase_hash":"pbkdf2_sha256$1$bad"},
                    {"admin_passphrase_hash":hash_passphrase(admin.settings.access_code)},
                    {"admin_tls_cert_path":"relative/cert.pem"}):
        with pytest.raises(RuntimeError): replace(admin.settings,**changes).validate()


def test_management_token_is_separate_hashed_scoped_and_revocable(admin):
    account = admin_login(admin)
    assert account["serviceID"] == "voice-lab" and account["role"] == "viewer"
    assert 28795 <= account["expiresAt"]-time.time() <= 28800
    digest = hashlib.sha256(account["token"].encode()).hexdigest()
    row = admin.app.state.db.execute("SELECT * FROM admin_sessions").fetchone()
    assert row["token_hash"] == digest and account["token"] not in tuple(row)
    assert not admin.app.state.db.execute("SELECT 1 FROM sessions WHERE token_hash=?",(digest,)).fetchone()
    assert admin.client.get("/v1/me",headers=headers(account)).status_code == 401
    user = login(admin)
    assert admin.client.get("/admin/v1/dashboard",headers=headers(user)).status_code == 401
    assert admin.client.delete("/admin/v1/auth/session",headers=headers(user)).status_code == 401
    assert admin.client.post("/admin/v1/auth/session",json={"passphrase":admin.settings.access_code}).status_code == 401
    assert admin.client.delete("/admin/v1/auth/session",headers=headers(account)).json() == {"revoked":True}
    assert admin.client.get("/admin/v1/dashboard",headers=headers(account)).status_code == 401
    assert admin.client.get("/v1/me",headers=headers(user)).status_code == 200


def test_expiry_and_credential_rotation_invalidate_admin_sessions(admin):
    account = admin_login(admin)
    with admin.app.state.db: admin.app.state.db.execute("UPDATE admin_sessions SET expires_at=0")
    assert admin.client.get("/admin/v1/dashboard",headers=headers(account)).status_code == 401
    second = admin_login(admin)
    admin.app.state.admin.credential_fingerprint = "b"*64
    assert admin.client.get("/admin/v1/dashboard",headers=headers(second)).status_code == 401


def test_management_bearer_is_strict_and_no_write_routes_exist(admin):
    for bearer in ("","Basic hello","Bearer short","Bearer "+"!"*43):
        assert admin.client.get("/admin/v1/dashboard",headers={"Authorization":bearer}).status_code == 401
    auth = headers(admin_login(admin))
    for method,path in (("POST","/admin/v1/rooms/x/end"),("DELETE","/admin/v1/rooms/x"),("POST","/admin/v1/dashboard"),("POST","/admin/v1/users/x/ban")):
        assert admin.client.request(method,path,headers=auth).status_code in {404,405}


def test_login_rate_limit_cannot_be_bypassed_by_fake_bearers(admin):
    for index in range(5):
        response = admin.client.post("/admin/v1/auth/session",json={"passphrase":"wrong-but-long-enough"},headers={"Authorization":"Bearer "+str(index)*43})
        assert response.status_code == 401 and "wrong-but-long-enough" not in response.text
    response = admin.client.post("/admin/v1/auth/session",json={"passphrase":PASSPHRASE})
    assert response.status_code == 429 and response.headers["retry-after"] == "300"


def test_invalid_login_body_does_not_echo_passphrase(admin):
    for body in ({"passphrase":"short"},{"passphrase":123},{"passphrase":"😀"*100},{"passphrase":PASSPHRASE,"role":"owner"}):
        response = admin.client.post("/admin/v1/auth/session",json=body)
        assert response.status_code == 422 and PASSPHRASE not in response.text


def test_dashboard_fences_account_service_and_does_not_fabricate_samples(admin):
    data = dashboard(admin)
    assert data["service"] == {"id":"voice-lab","name":"LiveKit 语聊实验服务","host":"furby.top","mode":"single-host-laboratory","readOnly":True}
    assert data["accountService"]["connected"] is False and "账号 DAU" in data["accountService"]["message"]
    assert data["capacity"]["activeParticipants"] is None and data["capacity"]["sfuStale"] is True
    assert data["connections"]["successPercent"] is None
    assert data["quality"]["samples"] == 0 and data["quality"]["rttMsP50"] is None
    assert data["infrastructure"]["cpuPercent"] is None and data["infrastructure"]["networkReceiveBytesPerSecond"] is None
    assert data["infrastructure"]["sampledAt"] is None and data["health"]["sfu"] == "unknown"
    assert data["rooms"] == []


def test_room_operations_seats_and_real_sfu_snapshot_are_separate(admin):
    owner,guest = login(admin,"SecretOwnerName"),login(admin,"SecretGuestName")
    room = create_room(admin,owner,title="运营房间")
    token(admin,room,owner)
    token(admin,room,guest,online=False)
    sample_sfu(admin)
    data = dashboard(admin)
    assert data["operations"]["roomsCreatedToday"] == 1 and data["operations"]["totalRooms"] == 1
    assert data["operations"]["participatingIdentitiesToday"] == 2 and data["operations"]["totalParticipatingIdentities"] == 2
    assert data["capacity"]["activeParticipants"] == 1 and data["capacity"]["admittedParticipants"] == 2
    item = data["rooms"][0]
    assert item["onlineParticipants"] == 1 and item["admittedParticipants"] == 2
    assert item["occupiedSeats"] == 1 and item["totalSeats"] == 8
    assert item["owners"] == 1 and item["admins"] == 0 and item["listeners"] == 1
    output = json.dumps(data)
    for private in ("SecretOwnerName","SecretGuestName",owner["user"]["id"],guest["user"]["id"],owner["token"]): assert private not in output
    for key in ("sessionHash","token_hash","userID","senderName","text","ip","LAB_ACCESS_CODE"): assert '"'+key+'"' not in output
    path = f'/v1/rooms/{room["id"]}'
    assert admin.client.patch(path,headers=headers(owner),json={"status":"closed"}).status_code == 200
    after = dashboard(admin)
    assert after["operations"]["roomsEndedToday"] == 1 and after["operations"]["activeRooms"] == 0
    assert after["rooms"] == [] and after["operations"]["totalRooms"] == 1
    assert admin.client.patch(path,headers=headers(owner),json={"status":"closed"}).status_code == 200
    assert dashboard(admin)["operations"]["roomsEndedToday"] == 1


def test_sfu_snapshot_stale_or_failed_is_unknown_not_zero(admin):
    owner = login(admin)
    room = create_room(admin,owner)
    token(admin,room,owner)
    sample_sfu(admin)
    assert dashboard(admin)["rooms"][0]["onlineParticipants"] == 1
    admin.app.state.admin.sfu_at -= 11
    old = dashboard(admin)
    assert old["rooms"][0]["onlineParticipants"] is None and old["capacity"]["activeParticipants"] is None
    admin.rtc.unavailable = True
    sample_sfu(admin)
    failed = dashboard(admin)
    assert failed["health"]["sfu"] == "unavailable" and "sfu_unavailable" in {a["code"] for a in failed["alerts"]}


def test_quality_and_signal_rates_are_rolling_not_end_to_end_claims(admin):
    service = admin.app.state.admin
    for event,value in (("attempt",None),("accepted",123),("attempt",None),("rejected",403)):
        service.observability.record_signal(event,value)
    for i in range(5):
        service.observability.record_quality(hashlib.sha256(str(i).encode()).hexdigest(),"poor",rtt_ms=450.,packet_loss_percent=7.)
    data = dashboard(admin)
    assert data["connections"]["successPercent"] == 50 and data["connections"]["handshakeMsP50"] == 123
    assert data["quality"]["samples"] == 5 and data["quality"]["poorPercent"] == 100
    assert data["quality"]["windowSeconds"] == 300 and "端到端" in data["connections"]["sampleNote"]
    assert not any("quality" in row[0] for row in admin.app.state.db.execute("SELECT name FROM sqlite_master WHERE type='table'"))


def test_host_thresholds_and_staleness_are_visible(admin):
    service = admin.app.state.admin
    service.host = {**empty_host_snapshot(),"sampledAt":"2026-10-19T00:00:00+00:00","stale":False,"cpuPercent":90,"memoryPercent":86,"diskPercent":88,"certificateDaysRemaining":-1,"certificateExpiresAt":"2026-10-18T00:00:00+00:00","services":[{"id":"livekit","name":"LiveKit SFU","state":"failed"}]}
    service.host_at = time.monotonic()
    assert {"cpu_high","memory_high","disk_high","certificate_expiring","service_livekit"} <= {a["code"] for a in dashboard(admin)["alerts"]}
    service.host_at -= 31
    data = dashboard(admin)
    assert data["infrastructure"]["stale"] is True and "host_metrics_stale" in {a["code"] for a in data["alerts"]}
    assert "cpu_high" not in {a["code"] for a in data["alerts"]}


def test_historical_end_dates_are_not_fabricated_and_migration_preserves_user_tables(lab):
    owner = login(lab)
    room = create_room(lab,owner)
    lab.client.patch(f'/v1/rooms/{room["id"]}',headers=headers(owner),json={"status":"closed"})
    db = lab.app.state.db
    with db:
        db.execute("DROP TRIGGER admin_room_started")
        db.execute("DROP TRIGGER admin_room_ended")
        db.execute("DROP TABLE admin_room_lifecycle")
        db.execute("DROP TABLE admin_metadata")
    initialize_admin_database(db)
    row = db.execute("SELECT * FROM admin_room_lifecycle").fetchone()
    assert row["room_id"] == room["id"] and row["ended_at"] is None and row["historical_end_unknown"] == 1
    assert lab.client.get("/v1/me",headers=headers(owner)).status_code == 200
    assert [row["name"] for row in db.execute("PRAGMA table_info(rooms)")] == ["id","owner_id","title","category","theme","status","created_at"]


def test_failed_room_creation_is_not_counted_as_an_active_business_room(admin):
    owner = login(admin)
    admin.rtc.create_failure = True
    response = admin.client.post("/v1/rooms",headers=headers(owner),json={"title":"Failure","category":"闲聊","theme":0,"isLive":False})
    assert response.status_code == 503
    data = dashboard(admin)
    assert data["operations"]["roomsCreatedToday"] == 0 and data["operations"]["roomsEndedToday"] == 0 and data["operations"]["totalRooms"] == 0
    # A process restart/migration must not later count failed creating->closed rows.
    initialize_admin_database(admin.app.state.db)
    assert dashboard(admin)["operations"]["totalRooms"] == 0


def test_daily_room_counts_use_shanghai_midnight(admin):
    service = admin.app.state.admin
    service.wall_clock = lambda: datetime(2026,10,19,0,1,tzinfo=timezone.utc).timestamp()
    owner = login(admin)
    create_room(admin,owner)
    with admin.app.state.db: admin.app.state.db.execute("UPDATE admin_room_lifecycle SET created_at=?",(int(datetime(2026,10,18,16,1,tzinfo=timezone.utc).timestamp()),))
    assert dashboard(admin)["operations"]["roomsCreatedToday"] == 1
    with admin.app.state.db: admin.app.state.db.execute("UPDATE admin_room_lifecycle SET created_at=?",(int(datetime(2026,10,18,15,59,tzinfo=timezone.utc).timestamp()),))
    assert dashboard(admin)["operations"]["roomsCreatedToday"] == 0


def test_host_collector_first_rate_unknown_second_delta_and_counter_reset(tmp_path,monkeypatch):
    proc = tmp_path/"proc"
    (proc/"net").mkdir(parents=True)
    (proc/"stat").write_text("cpu 10 0 10 80 0 0 0 0\n")
    (proc/"meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 400 kB\n")
    (proc/"net/dev").write_text("eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0\nlo: 99999 0 0 0 0 0 0 0 99999 0 0 0 0 0 0 0\n")
    (proc/"uptime").write_text("123.5 300\n")
    clock = [1.]
    collector = HostCollector(str(tmp_path/"missing-cert.pem"),proc_root=str(proc),clock=lambda:clock[0])
    monkeypatch.setattr(collector,"services",lambda:[])
    first = collector.collect()
    assert first["cpuPercent"] is None and first["networkReceiveBytesPerSecond"] is None
    assert first["memoryPercent"] == 60 and first["memoryUsedBytes"] == 600*1024
    assert first["uptimeSeconds"] == 123 and first["certificateExpiresAt"] is None
    clock[0] = 11.
    (proc/"stat").write_text("cpu 20 0 30 150 0 0 0 0\n")
    (proc/"net/dev").write_text("eth0: 300 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0\n")
    second = collector.collect()
    assert second["cpuPercent"] == 30 and second["networkReceiveBytesPerSecond"] == 20 and second["networkTransmitBytesPerSecond"] == 30
    clock[0] = 21.
    (proc/"stat").write_text("cpu 1 0 1 1 0 0 0 0\n")
    (proc/"net/dev").write_text("eth0: 1 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0\n")
    third = collector.collect()
    assert third["cpuPercent"] is None and third["networkReceiveBytesPerSecond"] is None


def test_host_sampling_does_not_block_event_loop(admin):
    started,release = threading.Event(),threading.Event()
    def blocking_sample():
        started.set()
        release.wait(2)
        return empty_host_snapshot()
    admin.app.state.admin.collector.collect = blocking_sample
    future = admin.client.portal.start_task_soon(admin.app.state.admin.sample_host)
    try:
        assert started.wait(1)
        before = time.monotonic()
        assert admin.client.get("/health").status_code == 200 and time.monotonic()-before < .5
    finally:
        release.set()
        future.result(timeout=2)


def test_sfu_failure_does_not_remove_last_sample_timestamp(admin):
    sample_sfu(admin)
    first = dashboard(admin)["capacity"]["sfuSampledAt"]
    admin.rtc.unavailable = True
    sample_sfu(admin)
    after = dashboard(admin)
    assert after["capacity"]["sfuSampledAt"] == first and after["capacity"]["activeParticipants"] is None


def test_management_sessions_are_bounded(admin):
    with admin.app.state.db:
        for index in range(32): admin.app.state.db.execute("INSERT INTO admin_sessions VALUES(?,?,NULL,?)",(hashlib.sha256(str(index).encode()).hexdigest(),int(time.time())+1000,admin.app.state.admin.credential_fingerprint))
    response = admin.client.post("/admin/v1/auth/session",json={"passphrase":PASSPHRASE})
    assert response.status_code == 429 and admin.app.state.db.execute("SELECT COUNT(*) FROM admin_sessions").fetchone()[0] == 32


def test_authentication_buckets_allow_valid_shared_wifi_without_loosening_anonymous(lab,monkeypatch):
    with management_lab(lab,monkeypatch,rate_limit_enabled=True) as network:
        user,second_user = login(network,"First"),login(network,"Second")
        admin_account = admin_login(network)
        original,observed = Limiter.check,[]
        def seeded(self,key,limit,period):
            observed.append((key,limit))
            if key[0]=="http-authenticated-ip" and key not in self.events: self.events[key] = deque([time.monotonic()]*10000)
            if key[0]=="http-total" and len(self.events[key]) < 6000: self.events[key] = deque([time.monotonic()]*6000)
            return original(self,key,limit,period)
        monkeypatch.setattr(Limiter,"check",seeded)
        assert network.client.get("/v1/me",headers=headers(user)).status_code == 200
        assert network.client.get("/v1/me",headers=headers(second_user)).status_code == 200
        assert network.client.get("/admin/v1/dashboard",headers=headers(admin_account)).status_code == 200
        assert network.client.get("/v1/me",headers={"Authorization":"Bearer "+"x"*43}).status_code == 429
        for prefix,limit in (("http-authenticated-ip",18000),("http-session",180),("http-admin-session",60),("http-total",6000)):
            assert any(key[0]==prefix and count==limit for key,count in observed)


def test_signal_completed_outcome_ratio_remains_bounded_across_window_boundary(admin):
    metrics = admin.app.state.admin.observability
    fake_clock = [0.]
    metrics._clock = lambda: fake_clock[0]
    metrics.record_signal("attempt")
    fake_clock[0] = 1.
    metrics.record_signal("accepted",1000)
    fake_clock[0] = 300.5
    data = dashboard(admin)
    assert data["connections"]["attempts"] == 0 and data["connections"]["accepted"] == 1
    assert data["connections"]["successPercent"] == 100
    metrics.record_signal("rejected",403)
    assert dashboard(admin)["connections"]["successPercent"] == 50


def test_management_session_survives_process_restart_but_not_hash_rotation(admin):
    account = admin_login(admin)
    with TestClient(create_app(admin.settings,FakeLiveKit(admin.settings))) as restarted:
        assert restarted.get("/admin/v1/dashboard",headers=headers(account)).status_code == 200
    rotated = replace(admin.settings,admin_passphrase_hash=hash_passphrase(PASSPHRASE+"-rotated"))
    with TestClient(create_app(rotated,FakeLiveKit(rotated))) as restarted:
        assert restarted.get("/admin/v1/dashboard",headers=headers(account)).status_code == 401


def test_management_global_login_guard_remains_separate_from_user_login(admin):
    service = admin.app.state.admin
    service.limiter.events[("admin-login-total",)] = deque([time.monotonic()]*30)
    response = admin.client.post("/admin/v1/auth/session",json={"passphrase":PASSPHRASE})
    assert response.status_code == 429 and response.headers["retry-after"] == "300"
    assert admin.client.get("/v1/me",headers=headers(login(admin))).status_code == 200
