"""手冊要教「你是一個 run 的時候怎麼做」。

一個 run 是**單次任務**：它沒有上一輪的記憶、沒有人在旁邊看著、撐不住的時候
只有一次把話留下來的機會。這幾件事猜錯都不會報錯——它會把交接寫在自己的
終端機裡然後被殺掉，而下一棒讀到的是一張空卡。
"""

from chatroom_mcp.guide import GUIDE


def test_the_run_section_exists_and_sits_before_the_conventions():
    assert "## 9.8" in GUIDE, "沒有「你是一個 run」的段落"
    assert GUIDE.index("## 9.8") < GUIDE.index("## 10.")


def test_the_run_section_covers_the_opening_moves():
    """開場三件事：join、讀卡、讀想法板。少讀一樣就少一半的上下文。"""
    section = GUIDE[GUIDE.index("## 9.8"):GUIDE.index("## 10.")]
    for topic in ("chatroom_join", "chatroom_board", "想法板"):
        assert topic in section, f"run 段落沒有涵蓋：{topic}"


def test_the_run_section_states_the_contract():
    """§6.3 的契約：不 push、卡住問人要設 timeout、收工摘要四段。"""
    section = GUIDE[GUIDE.index("## 9.8"):GUIDE.index("## 10.")]
    for topic in ("不 push", "chatroom_ask_human", "timeout", "收工摘要",
                  "沒驗證什麼"):
        assert topic in section, f"run 段落沒有涵蓋：{topic}"


def test_the_run_section_tells_it_to_stop_retrying_a_blocked_tool():
    """`PreToolUse` 擋下來時實測會換一個工具再試一次。

    Windows 上換 Bash 為 PowerShell 一樣被擋，而那一輪的回合就這樣燒掉了。
    手冊要在它讀到「這是系統限制」的當下就把它送去替代路徑。
    """
    section = GUIDE[GUIDE.index("## 9.8"):GUIDE.index("## 10.")]
    assert "PreToolUse" in section
    assert "這是系統限制" in section
    assert "不要再試" in section


def test_the_run_section_names_the_handoff_tool_and_what_it_does_not_do():
    """交接的三個事實：附加不覆蓋、狀態不動、**不代你回報 Hub**。"""
    section = GUIDE[GUIDE.index("## 9.8"):GUIDE.index("## 10.")]
    assert "chatroom_run_handoff" in section
    assert "context" in section or "上限" in section
    assert "in_progress" in section, "卡的狀態不動這件事要寫出來"
    assert "task_id" in section, "stage 派工要另外指定卡"
    assert "結束你的回合" in section


def test_the_run_section_warns_that_the_tools_are_deferred():
    """headless 實測：chatroom 工具是 deferred，直接呼叫是參數驗證錯誤。

    那個錯誤長得像「你參數寫錯」，而正確的動作是先把 schema 載進來。
    """
    section = GUIDE[GUIDE.index("## 9.8"):GUIDE.index("## 10.")]
    assert "deferred" in section
    assert "ToolSearch" in section


def test_the_run_section_says_request_and_cancel_are_human_only():
    """agent 撞到那兩支的 403 時不該去重新 join。"""
    section = GUIDE[GUIDE.index("## 9.8"):GUIDE.index("## 10.")]
    assert "chatroom_run_request" in section
    assert "chatroom_run_cancel" in section
    assert "403" in section
