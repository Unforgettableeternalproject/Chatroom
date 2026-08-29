"""state 檔要依內容認，不能只依檔名認——bridge 這一半。

檔名由建檔當下的 session_key 決定，但那把 key 會變：用 ``assignment_id``
加入房間時 Hub 會回一把 canonical session_key，bridge 把它寫進檔案**內容**；
之後行程重啟拿到新的平台 session id，算出來的檔名就與實際存放位置對不上。

2026-08-29 實測：MCP 重連之後 `chatroom_get_file`、`chatroom_post` 全部回
「你還沒有這個房間的身分」，而狀態檔裡明明有——**檔案內容自報的 key 與
當下這個行程的 key 完全相同，只有檔名還停在建檔時的舊 key。**

watcher 那一半已經修過（`_read_bridge_state` 依內容認檔）。這裡補齊 bridge
自己那一半：同一個磁碟檔、同一個誤判，兩個讀取端必須用同一套判準。
"""

import json

import pytest

from chatroom_mcp import identity

KEY = "claude-current"
OTHER = "claude-someone-else"


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.delenv("CHATROOM_STATE_PATH", raising=False)
    folder = tmp_path / ".chatroom"
    folder.mkdir()
    return folder


def _write(folder, filename, session_key, rooms=None):
    (folder / filename).write_text(
        json.dumps({"session_key": session_key, "rooms": rooms or {}}),
        encoding="utf-8",
    )


def test_prefers_the_file_named_after_the_key(home):
    """依 key 算出的名字仍是第一順位——它存在時就不必再猜。"""
    canonical = identity.state_path(KEY)
    _write(canonical.parent, canonical.name, KEY)
    _write(home, "state-claude-old-11111111.json", KEY)

    assert identity.resolve_state_path(KEY) == canonical


def test_finds_the_file_whose_content_claims_this_key(home):
    """核心情境：檔名是舊 key，內容是現在這把。"""
    _write(home, "state-claude-oldprocess-deadbeef.json", KEY,
           {"r1": {"participant_id": "p1", "display_name": "我", "last_seq": 3}})

    resolved = identity.resolve_state_path(KEY)
    assert resolved.name == "state-claude-oldprocess-deadbeef.json"


def test_never_adopts_another_sessions_file(home):
    """撿別把 key 的身分等於冒用他發言。找不到就回自己的路徑（空狀態）。"""
    _write(home, "state-claude-other-22222222.json", OTHER,
           {"r1": {"participant_id": "not-mine", "display_name": "別人"}})

    assert identity.resolve_state_path(KEY) == identity.state_path(KEY)


def test_corrupt_files_do_not_block_the_good_one(home):
    (home / "state-claude-broken-33333333.json").write_text(
        "{ 這不是 json", encoding="utf-8")
    _write(home, "state-claude-good-44444444.json", KEY)

    assert identity.resolve_state_path(KEY).name == \
        "state-claude-good-44444444.json"


def test_explicit_override_always_wins(home, monkeypatch):
    """顯式指定的路徑不容許被「聰明地」改掉——測試與特殊部署靠它。"""
    explicit = home / "somewhere-else.json"
    monkeypatch.setenv("CHATROOM_STATE_PATH", str(explicit))
    _write(home, "state-claude-old-55555555.json", KEY)

    assert identity.resolve_state_path(KEY) == explicit


def test_no_files_at_all_returns_the_key_derived_path(home):
    """全新的 session：回自己的路徑，之後由 save() 建檔。"""
    assert identity.resolve_state_path(KEY) == identity.state_path(KEY)
