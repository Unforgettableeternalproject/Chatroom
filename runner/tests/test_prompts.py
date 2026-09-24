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


# ── 要問人時問誰（2026-09-24）────────────────────────────────────────
# Hub 領單時給 `run["ask_human"]`：依序的人類候選。契約要把它講出來，
# agent 才知道 `chatroom_ask_human` 的 `target_name` 該填誰。

def _contract_with(ask) -> str:
    fields = {
        "run_id": "run-test", "room_id": "room-test", "kind": "stage",
        "project": "proj", "cwd": "/tmp/repo", "branch": "main",
        "allowed_branches": "main", "repo_names": "repo",
        "ask_human_block": prompts.ask_human_block(ask),
    }
    return prompts.build_contract(fields)


def test_contract_names_the_stage_creator_first():
    contract = _contract_with({
        "stage_creator": {"name": "戴爾", "kind": "human",
                          "stage_title": "App 端"},
        "targets": [
            {"name": "戴爾", "source": "stage_creator", "in_room": True},
            {"name": "艾斯維爾", "source": "board_owner", "in_room": False},
        ]})
    assert "{{ask_human_block}}" not in contract
    first = contract.index("`戴爾`（階段創建者）")
    second = contract.index("`艾斯維爾`（任務板 owner，派工當下不在房裡）")
    assert first < second


def test_an_agent_creator_is_named_but_not_asked():
    contract = _contract_with({
        "stage_creator": {"name": "諾薇亞", "kind": "claude",
                          "stage_title": "Hub 端"},
        "targets": [{"name": "艾斯維爾", "source": "board_owner",
                     "in_room": True}]})
    assert "agent `諾薇亞` 建的" in contract
    assert "1. `艾斯維爾`（任務板 owner）" in contract
    assert "`諾薇亞`（" not in contract


def test_an_agent_creator_points_to_the_dispatcher_first():
    """創建者是 agent 時先問派工者（09-24 裁決），開頭那句要講出這件事。"""
    contract = _contract_with({
        "stage_creator": {"name": "諾薇亞", "kind": "claude",
                          "stage_title": "Hub 端"},
        "targets": [
            {"name": "米勒", "source": "requester", "in_room": True},
            {"name": "艾斯維爾", "source": "board_owner", "in_room": True}]})
    assert "先問派工者" in contract
    first = contract.index("1. `米勒`（派工者）")
    assert first < contract.index("2. `艾斯維爾`（任務板 owner）")


def test_old_hub_without_ask_human_leaves_no_placeholder():
    contract = _contract_with(None)
    assert "{{ask_human_block}}" not in contract
    assert "要問人時問誰" not in contract
