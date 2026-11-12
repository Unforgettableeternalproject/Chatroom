"""任務依賴／影響的 MCP 工具接線與說明。

釘的事：

1. `chatroom_board_add(kind="task", depends_on=…, affects=…)` 真的送到 Hub
2. `chatroom_board_update(depends_on=[])` 是「清空」不是「沒給」；單獨給依賴
   也算一次有效的修改
3. 非 Task 給 depends_on／affects 直接拒絕
4. 兩支工具的 docstring、GUIDE、docs/CHATROOM.md 都有同一段依賴／影響說明
"""

import json
import re
from pathlib import Path

from chatroom_mcp import server as srv
from chatroom_mcp.guide import GUIDE

ROOM = "room-1"
_DOC = Path(__file__).resolve().parents[2] / "docs" / "CHATROOM.md"


def _join(fake_hub):
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": "pid-1", "display_name": "Aster",
                   "rejoined": False})
    srv.chatroom_join(ROOM)


def _sent(fake_hub):
    return json.loads(fake_hub.calls[-1].read())


def test_add_sends_depends_on_and_affects(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/checklists/c-1/tasks",
                  {"ok": True, "id": "t-9"})
    srv.chatroom_board_add(ROOM, "task", "新卡", parent_id="c-1",
                           depends_on=["t-1"], affects=["t-2", "t-3"])
    body = _sent(fake_hub)
    assert body["depends_on"] == ["t-1"]
    assert body["affects"] == ["t-2", "t-3"]


def test_add_without_dependencies_sends_neither_field(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/board/checklists/c-1/tasks", {"ok": True})
    srv.chatroom_board_add(ROOM, "task", "新卡", parent_id="c-1")
    body = _sent(fake_hub)
    assert "depends_on" not in body and "affects" not in body


def test_update_empty_list_clears_dependencies(fake_hub):
    _join(fake_hub)
    fake_hub.json("PATCH", "/api/board/tasks/t-1", {"ok": True})
    out = srv.chatroom_board_update(ROOM, "t-1", depends_on=[])
    assert out.get("ok") is True
    assert fake_hub.calls[-1].method == "PATCH"
    assert _sent(fake_hub) == {"depends_on": []}


def test_update_affects_alone_is_a_valid_edit(fake_hub):
    _join(fake_hub)
    fake_hub.json("PATCH", "/api/board/tasks/t-1", {"ok": True})
    srv.chatroom_board_update(ROOM, "t-1", affects=["t-2"])
    assert _sent(fake_hub) == {"affects": ["t-2"]}


def test_dependencies_on_non_task_are_refused(fake_hub):
    _join(fake_hub)
    out = srv.chatroom_board_add(ROOM, "objective", "週期", depends_on=["t-1"])
    assert out["ok"] is False and "depends_on" in repr(out)
    out = srv.chatroom_board_update(ROOM, "o-1", kind="objective",
                                    affects=["t-1"])
    assert out["ok"] is False and "affects" in repr(out)


def _canon(text: str) -> str:
    return re.sub(r"\s+", "", text)


def test_dependency_section_is_identical_in_docstrings_guide_and_doc():
    """三處說明用同一段文字。以「依賴未滿足叫阻擋」那段為錨，缺一處就紅。"""
    start = GUIDE.index("任務依賴與影響：")
    end = GUIDE.index("\n\n", GUIDE.index("依賴何時算滿足："))
    section = _canon(GUIDE[start:end])
    # 要講到的重點
    for must in ("depends_on", "affects", "整份覆寫", "dependency_cycle",
                 "阻擋", "blocked_by_dependency", "dependencies_unmet",
                 "cancelled", "moved_to", "不能依賴自己"):
        assert must in section, f"依賴說明沒有涵蓋：{must}"
    assert section in _canon(_DOC.read_text(encoding="utf-8"))
    for fn in (srv.chatroom_board_add, srv.chatroom_board_update):
        assert section in _canon(fn.__doc__ or ""), fn.__name__
