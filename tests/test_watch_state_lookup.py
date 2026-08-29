"""watcher 找 state 檔要依內容認，不能依檔名認。

檔名由 bridge 進程啟動當下的 session_key 決定，但房內身分可以在那之後被
改寫——用 ``assignment_id`` 加入時 Hub 會回一把 canonical session_key，
bridge 把它寫進檔案**內容**，檔名卻還是舊的（2026-08-29 實測）。

照檔名找的人於是撲空，讀不到 display_name 就判不出訊息有沒有 @ 到自己，
**一則 mention 事件都不會發，而且不報錯**——這正是靜默失效的形狀。
"""

import json

import pytest

from chatroom_mcp import identity
from chatroom_mcp.watch import _read_bridge_state, _sibling_states

ROOM = "room-abc"
MY_KEY = "claude-canonical"


def _write(folder, filename, session_key, rooms):
    (folder / filename).write_text(
        json.dumps({"session_key": session_key, "rooms": rooms}),
        encoding="utf-8",
    )


@pytest.fixture
def home(tmp_path, monkeypatch):
    """把 ~/.chatroom 導到 tmp，避免讀到開發機上的真實 state 檔。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.delenv("CHATROOM_STATE_PATH", raising=False)
    folder = tmp_path / ".chatroom"
    folder.mkdir()
    return folder


def test_finds_identity_when_filename_does_not_match_key(home):
    """核心情境：內容是我的 key，檔名卻是 bridge 啟動時的舊 key。"""
    _write(home, "state-claude-oldprocess-deadbeef.json", MY_KEY,
           {ROOM: {"participant_id": "p1", "display_name": "開發Novia",
                   "last_seq": 18}})

    assert _read_bridge_state(MY_KEY, ROOM) == ("p1", "開發Novia", 18)


def test_prefers_the_file_named_after_the_key(home):
    """依 key 算出來的檔名仍是第一順位——多個檔都自報同一把 key 時，
    以正規位置的那個為準，否則 glob 的順序會決定身分。"""
    canonical = identity.state_path(MY_KEY)
    _write(canonical.parent, canonical.name, MY_KEY,
           {ROOM: {"participant_id": "correct", "display_name": "正版",
                   "last_seq": 9}})
    _write(home, "state-claude-stale-00000000.json", MY_KEY,
           {ROOM: {"participant_id": "stale", "display_name": "舊的",
                   "last_seq": 3}})

    assert _read_bridge_state(MY_KEY, ROOM)[0] == "correct"


def test_never_picks_up_another_sessions_identity(home):
    """撿別把 key 的身分＝冒用別人發言。寧可沒有身分，也不能認錯人。"""
    _write(home, "state-claude-other-11111111.json", "claude-someone-else",
           {ROOM: {"participant_id": "not-mine", "display_name": "別人",
                   "last_seq": 5}})

    assert _read_bridge_state(MY_KEY, ROOM) == (None, None, 0)


def test_ignores_files_without_this_room(home):
    _write(home, "state-claude-x-22222222.json", MY_KEY,
           {"另一個房": {"participant_id": "p9", "display_name": "我",
                        "last_seq": 4}})

    assert _read_bridge_state(MY_KEY, ROOM) == (None, None, 0)


def test_corrupt_files_do_not_block_the_good_one(home):
    """壞掉的 state 檔不該讓整個查找失敗——它只是目錄裡的一個檔案。"""
    (home / "state-claude-broken-33333333.json").write_text(
        "{ 這不是 json", encoding="utf-8")
    _write(home, "state-claude-good-44444444.json", MY_KEY,
           {ROOM: {"participant_id": "p2", "display_name": "我", "last_seq": 1}})

    assert _read_bridge_state(MY_KEY, ROOM)[0] == "p2"


def test_same_key_in_another_file_is_not_an_identity_split(home):
    """診斷訊息不可以說謊。

    自報 key 與我相同的檔案只是「同一個身分寫在另一個檔名底下」，
    _read_bridge_state 已經會撿它。把它列成身分分裂會導出完全錯誤的處置
    （重啟 MCP、固定 CHATROOM_SESSION_KEY），而那對檔案位置對不上毫無用處。
    """
    _write(home, "state-claude-oldprocess-deadbeef.json", MY_KEY,
           {ROOM: {"participant_id": "p1", "display_name": "開發Novia",
                   "last_seq": 18}})

    assert _sibling_states(MY_KEY, ROOM) == []


def test_real_split_is_still_reported(home):
    """真的分裂時仍要報——修掉誤報不能順手把真陽性也關掉。"""
    _write(home, "state-claude-other-55555555.json", "claude-another-session",
           {ROOM: {"participant_id": "p3", "display_name": "另一個我",
                   "last_seq": 7}})

    assert _sibling_states(MY_KEY, ROOM) == [
        ("claude-another-session", "另一個我")
    ]
