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
])
def test_run_403_codes_are_not_identity_failures(code):
    """撞到這幾條的 agent 沒有掉出房間——叫它重新 join 是一條死路。"""
    err = _err(403, code)
    assert err.identity_invalid is False, f"{code} 被當成身分失效了"
    assert not err.reason.startswith("Hub 拒絕了這個動作（403）"), code


@pytest.mark.parametrize("code", [
    "room_not_ops", "run_ref_already_active", "project_not_served",
    "run_already_finished", "run_bad_transition",
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
