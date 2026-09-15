"""bridge 對外報的身分，必須是 Hub 認的那把 key。

``SESSION_KEY`` 是進程啟動當下算出來的，但身分可以在那之後被改寫——用
``assignment_id`` 加入時，Hub 以指派綁定的 key（例如 Codex thread id）為準，
回傳 canonical session_key。從那一刻起「別人要指派給我時該用哪把 key」
的答案就變了。

報錯 key 的後果全是靜默的：
- ``your_session_key`` 報舊的 → 對方照著指派 → 沒有 watcher 在輪詢那把 key
  → 指派永遠不會被領走，兩邊都不會看到錯誤
- 自報名錄用舊的 → **指派 UI 的掃描清單上會出現一把沒人在聽的 key**，
  而它看起來跟能用的完全一樣
"""

import pytest

from chatroom_mcp import server
from chatroom_mcp.state import BridgeState

CANONICAL = "codex-thread-abc123"
ROOM = "room-1"


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    """裝一個乾淨的 BridgeState，並固定 SESSION_KEY 便於對照。"""
    monkeypatch.setattr(server, "SESSION_KEY", "claude-process-startup")
    st = BridgeState(tmp_path / "state.json")
    server.configure(bridge_state=st)
    yield st
    server.configure(bridge_state=None)


def test_falls_back_to_process_key_before_any_join(bridge):
    """還沒加入任何房間時，進程自己的 key 就是唯一的身分。"""
    assert server._my_session_key() == "claude-process-startup"


def test_uses_canonical_key_after_hub_rebinds_identity(bridge):
    bridge.set_identity(ROOM, participant_id="p1", display_name="Novia",
                        session_key=CANONICAL)

    assert server._my_session_key() == CANONICAL


def test_presence_registers_under_the_canonical_key(bridge):
    """名錄是指派 UI 的掃描來源。登記錯＝在清單上掛一把沒人在聽的 key。"""
    bridge.set_identity(ROOM, participant_id="p1", display_name="Novia",
                        session_key=CANONICAL)

    assert server._presence_params()["session_key"] == CANONICAL


def test_presence_before_join_still_registers_something(bridge):
    """還沒 join 也要出現在名錄上，否則第一次指派就無從指起。"""
    assert server._presence_params()["session_key"] == "claude-process-startup"
