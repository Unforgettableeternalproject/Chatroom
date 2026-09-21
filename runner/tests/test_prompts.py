"""契約 prompt 的釘子測試（艾斯維爾裁決 09/21）。

私人房 join 403、chatroom 工具叫不到——這條路上沒有卡、沒有房、也沒有人在
看，agent 自己判斷「稍後重試」或「改走別的工具盲做」是實測發生過的事故
（run 401a66ab）。runner 端的 MCP 開場檢查只擋得住「MCP 連線本身沒連上」，
擋不住「MCP 連上了、但呼叫 `chatroom_join` 被 Hub 拒絕」——那是 agent 自己
的 turn 裡才會發生的事，只有契約文字能在事前立規矩。這裡釘住那段文字存在、
在最前面，而且講清楚「什麼都不做」。
"""

from __future__ import annotations

from chatroom_runner import prompts

_JOIN_FAILURE_MARKERS = ("chatroom_join", "room_is_private", "不要讀任何檔案",
                         "不要跑任何指令")


def _build_contract() -> str:
    fields = {
        "run_id": "run-test", "room_id": "room-test", "kind": "ticket",
        "project": "proj", "cwd": "/tmp/repo", "branch": "main",
        "allowed_branches": "main", "repo_names": "repo",
    }
    return prompts.build_contract(fields)


def test_join_failure_rule_is_present():
    contract = _build_contract()
    for marker in _JOIN_FAILURE_MARKERS:
        assert marker in contract, f"契約裡少了 {marker!r}，開工規則不完整"


def test_join_failure_rule_is_the_first_thing_the_agent_reads():
    """規則要在最前面：那條路上沒有卡、沒有房，越晚讀到越可能已經先動手了。"""
    contract = _build_contract()
    # 開場那句「你是一次性的派工執行者」之後、進「身分與溝通」那節之前，
    # 就要看到 join 失敗的規則——不是埋在契約中後段某處
    identity_section = contract.index("## 身分與溝通")
    join_rule = contract.index("chatroom_join")
    assert join_rule < identity_section, (
        "join 失敗規則要排在『身分與溝通』之前，不能讓 agent 先讀到別的再讀到它")


def test_join_failure_rule_says_do_nothing_else():
    contract = _build_contract()
    assert "什麼都不做" in contract or "不要讀任何檔案" in contract
