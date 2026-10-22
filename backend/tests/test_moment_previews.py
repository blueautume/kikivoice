"""Authenticated feed previews use the same visible comments as moment detail.

All accounts, moderation cases and files here belong to temporary local fixtures.
"""
import hashlib

import pytest

from app.main import database
from test_api import authorization
from test_ops_auth import ops
from test_social_boundaries import (
    BASE, MOD, internal_id, moment, mutation, operator, person, report, social_env,
)


def comment(env, actor, post, text):
    response = env.c.post(BASE + "/moments/" + post["id"] + "/comments",
                          headers=authorization(actor), json=mutation(text=text))
    assert response.status_code == 200, response.text
    return response.json()["comment"]


def detail(env, actor, post):
    response = env.c.get(BASE + "/moments/" + post["id"], headers=authorization(actor))
    assert response.status_code == 200, response.text
    return response.json()["moment"]


def feed(env, actor, post, **params):
    response = env.c.get(BASE + "/moments", headers=authorization(actor), params=params)
    assert response.status_code == 200, response.text
    return next(item for item in response.json()["moments"] if item["id"] == post["id"])


def visible_comments(env, actor, post):
    response = env.c.get(BASE + "/moments/" + post["id"] + "/comments",
                         headers=authorization(actor), params={"limit": 50})
    assert response.status_code == 200, response.text
    return response.json()["comments"]


def assert_preview(env, actor, post, count, ids=None):
    expected = visible_comments(env, actor, post)
    assert len(expected) == count
    for item in (feed(env, actor, post), detail(env, actor, post)):
        assert item["commentCount"] == count
        assert item["commentPreview"] == expected[:3]
        if ids is not None:
            assert [entry["id"] for entry in item["commentPreview"]] == ids
    return expected


def test_publish_and_idempotent_publish_response_include_current_preview(social_env):
    e = social_env
    owner, reader = person(e, "发布预览甲"), person(e, "发布预览乙")
    request = mutation(text="可浏览的动态", mediaIDs=[])
    path = BASE + "/moments"
    created = e.c.post(path, headers=authorization(owner), json=request)
    assert created.status_code == 200, created.text
    post = created.json()["moment"]
    assert post["commentPreview"] == [] and post["commentCount"] == 0
    assert_preview(e, reader, post, 0)
    entry = comment(e, reader, post, "发布后添加的评论")
    replay = e.c.post(path, headers=authorization(owner), json=request)
    assert replay.status_code == 200, replay.text
    assert replay.json()["moment"]["id"] == post["id"]
    expected = visible_comments(e, owner, post)
    assert replay.json()["moment"]["commentPreview"] == expected
    assert expected[0]["id"] == entry["id"]


def test_feed_detail_like_unlike_preview_is_bounded_and_matches_detail_order(social_env):
    e = social_env
    owner, reader = person(e, "三条预览甲"), person(e, "三条预览乙")
    post = moment(e, owner)
    entries = [comment(e, reader if index % 2 else owner, post, "评论" + str(index))
               for index in range(6)]
    expected_ids = [entry["id"] for entry in reversed(entries[-3:])]
    expected = assert_preview(e, reader, post, 6, expected_ids)
    assert expected[0]["canDelete"] is True
    assert expected[1]["canDelete"] is False
    assert set(expected[0]) == {"id", "momentID", "author", "text", "createdAt", "canDelete"}
    path = BASE + "/moments/" + post["id"] + "/like"
    for method, liked in (("PUT", True), ("DELETE", False)):
        request = mutation()
        response = e.c.request(method, path, headers=authorization(reader), json=request)
        assert response.status_code == 200, response.text
        result = response.json()["moment"]
        assert result["liked"] is liked
        assert result["commentCount"] == 6 and result["commentPreview"] == expected[:3]
        assert e.c.request(method, path, headers=authorization(reader), json=request).json() == response.json()


def test_same_timestamp_comment_preview_uses_detail_id_tiebreaker(social_env):
    e = social_env
    owner = person(e, "同秒预览")
    post = moment(e, owner)
    entries = [comment(e, owner, post, "相同时刻" + str(index)) for index in range(5)]
    with database(e.c.settings) as db:
        db.execute("UPDATE social_comments SET created_at=? WHERE moment_id=?",
                   (1_700_000_000_000_000_000, post["id"]))
    expected_ids = sorted((entry["id"] for entry in entries), reverse=True)[:3]
    assert_preview(e, owner, post, 5, expected_ids)


@pytest.mark.parametrize("reverse_block", [False, True])
def test_blocked_newest_comments_do_not_displace_or_leak_visible_preview(social_env, reverse_block):
    e = social_env
    owner, viewer, hidden = (person(e, name) for name in ("屏蔽预览甲", "屏蔽预览乙", "屏蔽预览丙"))
    post = moment(e, owner)
    visible = [comment(e, owner, post, "可见评论" + str(index)) for index in range(4)]
    hidden_entries = [comment(e, hidden, post, "屏蔽后不可见" + str(index)) for index in range(4)]
    pair = (viewer["user"]["id"], hidden["user"]["id"])
    e.blocks.add(tuple(reversed(pair)) if reverse_block else pair)
    expected_ids = [entry["id"] for entry in reversed(visible[-3:])]
    assert_preview(e, viewer, post, 4, expected_ids)
    # Filtering belongs to this viewer: an unrelated reader still sees all eight.
    assert_preview(e, owner, post, 8, [entry["id"] for entry in reversed(hidden_entries[-3:])])
    for item in (feed(e, viewer, post), detail(e, viewer, post)):
        assert hidden["user"]["id"] not in str(item)
        assert "屏蔽后不可见" not in str(item)


@pytest.mark.parametrize("hidden_state", ["nickname", "withdrawn", "outdated_legal"])
def test_hidden_comment_authors_are_excluded_from_preview_and_total(social_env, hidden_state):
    e = social_env
    owner, hidden = person(e, "隐藏预览甲"), person(e, "隐藏预览乙")
    post = moment(e, owner)
    visible = comment(e, owner, post, "仍然可见")
    comment(e, hidden, post, "不可公开的作者评论")
    uid = internal_id(e, hidden)
    with database(e.c.settings) as db:
        if hidden_state == "nickname":
            db.execute("UPDATE accounts SET needs_nickname=1 WHERE account_id=?", (uid,))
        else:
            column, value = ("accepted", 0) if hidden_state == "withdrawn" else ("document_hash", "obsolete")
            db.execute("UPDATE legal_consent_events SET " + column + "=? WHERE account_id=?", (value, uid))
    assert_preview(e, owner, post, 1, [visible["id"]])
    assert "不可公开的作者评论" not in str(detail(e, owner, post))


def test_deleted_comment_and_deleted_account_are_not_returned_in_preview(social_env):
    e = social_env
    owner, removed = person(e, "删除预览甲"), person(e, "删除预览乙")
    post = moment(e, owner)
    kept = comment(e, owner, post, "保留")
    deleted = comment(e, removed, post, "先删除评论")
    assert e.c.delete(BASE + "/comments/" + deleted["id"], headers=authorization(removed)).status_code == 200
    assert_preview(e, owner, post, 1, [kept["id"]])
    comment(e, removed, post, "注销时一并移除")
    assert e.c.delete("/v1/account", headers=authorization(removed)).status_code == 200
    assert_preview(e, owner, post, 1, [kept["id"]])


def test_moderation_removed_comment_is_not_replayed_by_like_receipt(social_env):
    e = social_env
    owner, commenter = person(e, "审核预览甲"), person(e, "审核预览乙")
    post = moment(e, owner)
    kept = comment(e, owner, post, "保留的评论")
    removed = comment(e, commenter, post, "审核移除的评论")
    like_request = mutation()
    like_path = BASE + "/moments/" + post["id"] + "/like"
    liked = e.c.put(like_path, headers=authorization(owner), json=like_request)
    assert liked.status_code == 200 and liked.json()["moment"]["commentCount"] == 2
    case = report(e, owner, "comment", removed["id"])
    op = operator(e)
    action = e.c.post(MOD + "/moderation/action", headers=authorization(op),
                      json=mutation(reportID=case["id"], action="remove_content", note="删除违规评论"))
    assert action.status_code == 200, action.text
    assert_preview(e, owner, post, 1, [kept["id"]])
    replay = e.c.put(like_path, headers=authorization(owner), json=like_request)
    assert replay.status_code == 200, replay.text
    assert replay.json()["moment"]["commentCount"] == 1
    assert [entry["id"] for entry in replay.json()["moment"]["commentPreview"]] == [kept["id"]]


def test_preview_does_not_bypass_blocked_moment_author_or_authentication(social_env):
    e = social_env
    owner, viewer = person(e, "权限预览甲"), person(e, "权限预览乙")
    post = moment(e, owner)
    comment(e, viewer, post, "动态本身不可见时也不能读取")
    path = BASE + "/moments/" + post["id"]
    assert e.c.get(BASE + "/moments").status_code == 401
    assert e.c.get(path).status_code == 401
    e.blocks.add((owner["user"]["id"], viewer["user"]["id"]))
    assert e.c.get(BASE + "/moments", headers=authorization(viewer)).json()["moments"] == []
    assert e.c.get(path, headers=authorization(viewer)).status_code == 404
    assert e.c.get(path + "/comments", headers=authorization(viewer)).status_code == 404
    assert e.c.put(path + "/like", headers=authorization(viewer), json=mutation()).status_code == 404


def test_session_revoked_during_policy_lookup_cannot_leak_preview(social_env, monkeypatch):
    e = social_env
    owner, viewer = person(e, "竞态预览甲"), person(e, "竞态预览乙")
    post = moment(e, owner)
    comment(e, owner, post, "会话失效后的敏感评论")
    original = e.service.policy
    def revoke(user, target_ids=()):
        result = original(user, target_ids)
        with database(e.c.settings) as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?",
                       (hashlib.sha256(viewer["token"].encode()).hexdigest(),))
        return result
    monkeypatch.setattr(e.service, "policy", revoke)
    response = e.c.get(BASE + "/moments", headers=authorization(viewer))
    assert response.status_code == 401
    assert "会话失效后的敏感评论" not in response.text


def test_empty_visible_comments_have_zero_count_with_a_large_block_list(social_env, monkeypatch):
    e = social_env
    owner, viewer, hidden = (person(e, name) for name in ("空预览甲", "空预览乙", "空预览丙"))
    post = moment(e, owner)
    comment(e, hidden, post, "所有评论均被隐藏")
    original = e.service.policy
    from app.social import Policy
    def large_policy(user, target_ids=()):
        result = original(user, target_ids).model_dump()
        if user["login_id"] == viewer["user"]["id"]:
            result["blockedUserIDs"] = [hidden["user"]["id"]] + ["kiki_" + str(index).zfill(16) for index in range(9999)]
        return Policy.model_validate(result)
    monkeypatch.setattr(e.service, "policy", large_policy)
    assert_preview(e, viewer, post, 0)
