"""Removed feed cannot be used or leak legacy interactions into current inboxes."""
import uuid

from app import social
from app.main import database
from deploy.retire_legacy_notifications import retire_legacy_notifications
from test_api import authorization, client, jpeg_bytes, login
from test_inbox_actions import account_id, mutation, notice, notifications
from test_push import env, register, rows
from test_social_boundaries import social_env, person, report, operator, MOD
from test_ops_auth import ops


BASE = "/v1/social"


def test_feed_routes_and_schema_are_removed_while_avatar_and_private_messages_work(env):
    e=env;owner,peer=login(e.c,"retired-owner"),login(e.c,"retired-peer")
    identifier=str(uuid.uuid4())
    paths=[("GET","/moments"),("POST","/moments"),("GET","/moments/"+identifier),
           ("DELETE","/moments/"+identifier),("PUT","/moments/"+identifier+"/like"),
           ("DELETE","/moments/"+identifier+"/like"),("GET","/moments/"+identifier+"/comments"),
           ("POST","/moments/"+identifier+"/comments"),("DELETE","/comments/"+identifier),
           ("POST","/media"),("GET","/media/"+identifier+".jpg")]
    routes={route.path for route in e.c.app.routes}
    assert not any("/moments" in path or "/comments" in path or "/social/media" in path for path in routes)
    for method,path in paths:
        for headers in ({},authorization(owner)):
            assert e.c.request(method,BASE+path,headers=headers,json=mutation()).status_code==404
    assert e.c.get("/admin/v2/services/account/social/media/"+identifier+".jpg",headers=authorization(owner)).status_code==404
    with database(e.c.settings) as db:
        tables={row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert not {"social_moments","social_comments","social_likes","social_media","social_moment_media"}&tables
    avatar=e.c.post("/v1/me/avatar",headers={**authorization(owner),"Content-Type":"image/jpeg"},content=jpeg_bytes())
    assert avatar.status_code==200,avatar.text
    sent=e.c.post(BASE+"/conversations/"+peer["user"]["id"]+"/messages",headers=authorization(owner),json=mutation(text="保留的私信"))
    assert sent.status_code==200,sent.text


def test_legacy_rows_are_preserved_but_retired_notices_never_appear_or_push(env):
    e=env;owner,peer=login(e.c,"legacy-owner"),login(e.c,"legacy-peer")
    register(e,owner)
    current=notice(e,owner)
    retired=notice(e,owner,"旧互动提醒")
    with database(e.c.settings) as db:
        db.execute("ALTER TABLE social_notifications ADD COLUMN moment_id TEXT")
        db.execute("UPDATE social_notifications SET moment_id=? WHERE id=?",(str(uuid.uuid4()),retired))
        db.execute("CREATE TABLE social_moments(id TEXT PRIMARY KEY,text TEXT)")
        db.execute("INSERT INTO social_moments VALUES('legacy-record','private rollback body')")
        original=dict(db.execute("SELECT * FROM social_notifications WHERE id=?",(retired,)).fetchone())
        retire_legacy_notifications(db)
        retire_legacy_notifications(db)
        marked=dict(db.execute("SELECT * FROM social_notifications WHERE id=?",(retired,)).fetchone())
        assert {**original,"is_retired":1}==marked
        assert db.execute("SELECT text FROM social_moments").fetchone()[0]=="private rollback body"
        assert db.execute("PRAGMA foreign_key_check").fetchall()==[]
    page=notifications(e,owner)
    assert [item["id"] for item in page["notifications"]]==[current]
    assert page["unreadCount"]==1
    assert "momentID" not in page["notifications"][0]
    inbox=e.c.get(BASE+"/inbox",headers=authorization(owner)).json()
    assert [entry["notification"]["id"] for entry in inbox["entries"]]==[current]
    assert inbox["unreadNotificationCount"]==1
    assert e.c.get(BASE+"/notifications/"+retired+"/destination",headers=authorization(owner)).status_code==404
    assert e.c.get("/v1/push/status",headers=authorization(owner)).json()["badgeCount"]==1
    e.s.dispatch()
    assert len(e.requests)==1
    assert {row["state"] for row in rows(e) if row["source_id"]==retired}=={"cancelled"}


def test_reports_reject_feed_targets_and_hide_legacy_cases_without_erasing_them(social_env):
    e=social_env;a,b=person(e,"举报甲"),person(e,"举报乙")
    for target_type in ("moment","comment"):
        response=e.c.post(BASE+"/reports",headers=authorization(b),json=mutation(targetType=target_type,targetID=str(uuid.uuid4()),reason="other"))
        assert response.status_code==422
    current=report(e,b,"profile",a["user"]["id"])
    retired=report(e,b,"profile",a["user"]["id"])
    with database(e.c.settings) as db:
        db.execute("UPDATE social_reports SET target_type='moment' WHERE id=?",(retired["id"],))
    op=operator(e)
    mine=e.c.get(BASE+"/reports/mine",headers=authorization(b)).json()["reports"]
    assert [item["id"] for item in mine]==[current["id"]]
    cases=e.c.post(MOD+"/moderation/query",headers=authorization(op),json={"status":"all"}).json()["reports"]
    assert [item["id"] for item in cases]==[current["id"]]
    action=e.c.post(MOD+"/moderation/action",headers=authorization(op),json=mutation(reportID=retired["id"],action="remove_content",note="removed feature"))
    assert action.status_code==404
    with database(e.c.settings) as db:
        assert db.execute("SELECT status FROM social_reports WHERE id=?",(retired["id"],)).fetchone()[0]=="pending"
        metrics=social.metrics(db)
    assert metrics["pendingReports"]==1
    assert not {"moments","comments","privateMedia"}&metrics.keys()
