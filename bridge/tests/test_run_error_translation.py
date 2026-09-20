"""遠端派工的錯誤碼翻譯：403 不是身分失效，配額是 429 不是 409。

`tests/test_403_contract.py` 會掃 Hub 原始碼的每一個 `_err(403, …)` 去打
bridge，所以「漏掉一個 403」那邊就會紅。**429 沒有那道掃描**——Hub 只有兩個
配額碼，而它們原本會落進最底下那句「Hub 回傳未預期的狀態」。那句話不會讓
任何人知道該等，只會讓 client 立刻重試，而重試永遠不會成功。
"""

import pytest

from chatroom_mcp.hub import translate_status

_UNEXPECTED = "未預期的狀態"


def _err(status, code, message="（Hub 的說明）"):
    return translate_status(status, {"code": code, "message": message}, "u")


@pytest.mark.parametrize("code", [
    "human_token_required_for_run",
    "human_token_required_for_ops_room",
    "human_token_required_for_runner_command",
    "human_actor_required_for_run",
    "human_actor_required_for_run_cancel",
    "human_actor_required_for_runner_command",
    "not_your_run",
    "runner_token_required",
    "runner_token_invalid",
    # Supervisor 自派工（Hub 2026-09-19）：它確實是監督者，只是這個 kind
    # 不開放——讀成身分失效的話，watcher 的處置是結束自己
    "kind_not_allowed_for_supervisor",
])
def test_run_403_codes_are_not_identity_failures(code):
    """撞到這幾條的 agent 沒有掉出房間——叫它重新 join 是一條死路。"""
    err = _err(403, code)
    assert err.identity_invalid is False, f"{code} 被當成身分失效了"
    assert not err.reason.startswith("Hub 拒絕了這個動作（403）"), code


@pytest.mark.parametrize("code", [
    "room_not_ops", "run_ref_already_active", "project_not_served",
    "run_already_finished", "run_bad_transition",
    "workspace_not_bound", "workspace_project_mismatch",
])
def test_run_409_codes_have_their_own_wording(code):
    err = _err(409, code)
    assert err.status == 409
    assert "操作與 Hub 目前狀態衝突" not in err.reason, f"{code} 落進 409 的 fallback"


def test_daily_quota_is_translated_as_wait_not_as_a_bad_request():
    err = _err(429, "run_daily_quota_exceeded",
               "今天已經派了 20 筆，達到每日上限（20）。")
    assert err.status == 429
    assert _UNEXPECTED not in err.reason
    assert "20" in err.reason


def test_queue_cap_points_at_the_two_ways_out():
    """Hub 的原話要原樣交出去——它已經算好了「排了幾筆、上限多少」。"""
    err = _err(429, "run_queue_cap_exceeded",
               "這間房已經有 5 筆在排隊，達到上限（5）。等前面的做完，"
               "或先取消幾筆。")
    assert err.status == 429
    assert _UNEXPECTED not in err.reason
    # 兩條路都要講：等前面做完，或先取消幾筆
    assert "取消" in err.reason and "5" in err.reason


def test_an_unknown_429_still_says_wait():
    """Hub 之後加的 429 碼也不該被讀成「請求有問題」。

    落進最底下那句的話，訊息是「Hub 回傳未預期的狀態 HTTP 429」——對一個
    速率限制來說，那句話唯一會引發的行為是立刻再打一次。
    """
    err = _err(429, "something_new", "稍後再試。")
    assert _UNEXPECTED not in err.reason
    assert "等" in err.reason and err.identity_invalid is False


def test_429_never_claims_the_identity_is_gone():
    """反向守衛：429 是速率限制，watcher 不該因為它結束自己。"""
    for code in ("run_daily_quota_exceeded", "run_queue_cap_exceeded", "x"):
        assert _err(429, code).identity_invalid is False


def test_a_supervisor_blocked_on_push_is_told_to_change_the_kind():
    """它是監督者，缺的不是身分而是那個 kind。

    壓成「只有人類做得到」的話，它會去重新確認身分（重新 join、請人再指定
    一次），而正確的動作是換一個 kind 或把 push 留給人類。
    """
    err = translate_status(403, {"code": "kind_not_allowed_for_supervisor"},
                           "u")
    assert err.identity_invalid is False
    assert not err.reason.startswith("Hub 拒絕了這個動作（403）")
    # Hub 有話要說時原樣交出去——它已經把 kind 寫進訊息了
    spoken = _err(403, "kind_not_allowed_for_supervisor",
                  "監督者派不了 push。")
    assert "push" in spoken.reason


def test_a_run_cannot_be_appointed_supervisor_says_why():
    """409 而不是 403：那是狀態問題（那個成員是 run），不是權限問題。"""
    err = _err(409, "supervisor_cannot_be_run")
    assert err.status == 409
    assert "操作與 Hub 目前狀態衝突" not in err.reason
    assert err.identity_invalid is False


def test_workspace_not_bound_points_at_the_human_owner():
    """agent 自己綁不了工作區——講成「再試一次」它只會重打同一支。"""
    err = _err(409, "workspace_not_bound",
               "這間房還沒綁定工作區。")
    assert err.status == 409
    assert err.identity_invalid is False
    assert "綁" in err.reason


def test_workspace_mismatch_tells_you_the_key_to_use():
    """Hub 回應帶 workspace_key 時要直接講出該填什麼，不要讓人去猜。"""
    err = translate_status(
        409,
        {"code": "workspace_project_mismatch",
         "message": "project 與房間綁定的工作區不一致。",
         "workspace_key": "chatroom"},
        "u",
    )
    assert err.status == 409
    assert "chatroom" in err.reason
    assert "project" in err.reason
