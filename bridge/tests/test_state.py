"""P2-03：身分與游標持久化的行為。"""

import json

from chatroom_mcp.state import BridgeState


def test_identity_persists_across_instances(tmp_path):
    path = tmp_path / "state.json"
    first = BridgeState(path)
    first.set_identity("room-a", "pid-1", "Aster")

    # 模擬 bridge 重啟：換一個實例重新載入
    second = BridgeState(path)
    assert second.participant_id("room-a") == "pid-1"
    assert second.display_name("room-a") == "Aster"


def test_canonical_session_key_applies_to_future_rooms_and_persists(tmp_path):
    """Codex thread id 一旦由指派綁定，同一 MCP bridge 跨房仍是同一 session。"""
    path = tmp_path / "state.json"
    first = BridgeState(path)
    first.set_identity("room-a", "pid-1", "Sol", "codex-thread-id")
    assert first.session_key("room-b") == "codex-thread-id"

    second = BridgeState(path)
    assert second.session_key("room-b") == "codex-thread-id"


def test_cursor_only_moves_forward(tmp_path):
    st = BridgeState(tmp_path / "state.json")
    st.set_last_seq("room-a", 10)
    st.set_last_seq("room-a", 4)
    assert st.last_seq("room-a") == 10
    st.set_last_seq("room-a", 11)
    assert st.last_seq("room-a") == 11


def test_reset_cursor_can_go_backwards(tmp_path):
    st = BridgeState(tmp_path / "state.json")
    st.set_last_seq("room-a", 10)
    st.reset_cursor("room-a", 0)
    assert st.last_seq("room-a") == 0


def test_clear_identity_keeps_cursor(tmp_path):
    st = BridgeState(tmp_path / "state.json")
    st.set_identity("room-a", "pid-1", "Aster")
    st.set_last_seq("room-a", 7)
    st.clear_identity("room-a")
    assert st.participant_id("room-a") is None
    assert st.last_seq("room-a") == 7


def test_missing_file_starts_empty(tmp_path):
    st = BridgeState(tmp_path / "nope.json")
    assert st.rooms() == {}
    assert st.participant_id("room-a") is None


def test_corrupt_file_is_quarantined_and_rebuilt(tmp_path):
    path = tmp_path / "state.json"
    path.write_text("{ 這不是 JSON", encoding="utf-8")

    st = BridgeState(path)
    assert st.rooms() == {}
    assert (tmp_path / "state.json.corrupt").exists()

    # 重建後仍可正常寫入
    st.set_identity("room-a", "pid-1", "Aster")
    assert BridgeState(path).participant_id("room-a") == "pid-1"


def test_wrong_shape_is_rebuilt(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps(["not", "a", "dict"]), encoding="utf-8")
    assert BridgeState(path).rooms() == {}


def test_partial_garbage_entries_are_dropped(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "rooms": {
                    "good": {"participant_id": "p", "display_name": "N", "last_seq": 3},
                    "bad": "不是物件",
                    "half": {"participant_id": 123, "last_seq": "x"},
                },
            }
        ),
        encoding="utf-8",
    )
    st = BridgeState(path)
    assert st.participant_id("good") == "p"
    assert st.last_seq("good") == 3
    assert "bad" not in st.rooms()
    # 欄位型別不對的房間退回安全預設，而非整份狀態陪葬
    assert st.participant_id("half") is None
    assert st.last_seq("half") == 0


def test_save_is_atomic_and_leaves_no_tmp(tmp_path):
    path = tmp_path / "state.json"
    st = BridgeState(path)
    st.set_identity("room-a", "pid-1", "Aster")
    assert not (tmp_path / "state.json.tmp").exists()
    assert json.loads(path.read_text(encoding="utf-8"))["version"] == 1


# ---------- P3 審核修正：state 檔名的碰撞與非法字元 ----------


def test_state_filename_no_prefix_collision():
    """前 16 字元相同的兩把固定 key 不可共用同一個 state 檔。"""
    from chatroom_mcp.server import _state_filename

    a = _state_filename("codex-main-alpha-001")
    b = _state_filename("codex-main-alpha-002")
    assert a != b


def test_state_filename_is_deterministic():
    from chatroom_mcp.server import _state_filename

    assert _state_filename("codex-main") == _state_filename("codex-main")


def test_state_filename_strips_invalid_characters():
    """key 含路徑分隔符 / Windows 非法字元時，檔名仍然合法且不含分隔符。"""
    from chatroom_mcp.server import _state_filename

    name = _state_filename('a/b' + chr(92) + 'c:d*e?f"g<h>i|j')
    for ch in ['/', chr(92), ':', '*', '?', '"', '<', '>', '|']:
        assert ch not in name
    assert name.startswith("state-") and name.endswith(".json")


def test_state_filename_all_invalid_falls_back_to_digest():
    from chatroom_mcp.server import _state_filename

    name = _state_filename("///:::")
    assert name.startswith("state-") and name.endswith(".json")
    # 兩把不同的全非法 key 也不可撞名
    assert name != _state_filename(":::///x")
