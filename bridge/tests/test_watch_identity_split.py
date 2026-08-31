"""身分分裂要發成**事件**，以及孤兒 state 檔的清理（G2 方向 3 + GC）。

分裂的自檢邏輯本來就有，但它只走 ``_log``——那是 stderr，而 Monitor 只把
**stdout** 當事件流。於是最該被叫醒的那個人（正在等指派、而指派永遠不會到
的那個 agent）看不到它：他的終端機上什麼都沒有，房內也什麼都沒有。

**診斷訊息送到沒有人在看的地方，等於沒有診斷。**

GC 那半是另一個症狀的收尾：每個死掉的 session 都留下一個 state 檔，這台開發
機累積了九個。它們不壞事，但它們讓 ``_sibling_states`` 這種「同機還有誰」的
判斷愈來愈慢、也愈來愈難讀。
"""

import json
import os
import time

import pytest

from chatroom_mcp import identity, watch

from test_watch import events_from, make_watcher, ROOM


def _write_state(tmp_path, session_key, room_id=None, participant="p1",
                 name="別人", age_days=0.0):
    """在 state 目錄放一個 state 檔；``age_days`` 讓它看起來很舊。"""
    path = tmp_path / identity.state_filename(session_key)
    body = {"version": 1, "session_key": session_key, "rooms": {}}
    if room_id:
        body["rooms"][room_id] = {
            "participant_id": participant, "display_name": name, "last_seq": 0,
        }
    path.write_text(json.dumps(body), encoding="utf-8")
    if age_days:
        old = time.time() - age_days * 86400
        os.utime(path, (old, old))
    return path


class TestSplitIsAnEvent:
    """分裂要進事件流，不能只進 log。"""

    def test_split_emits_an_event(self, fake_hub, tmp_path, monkeypatch, capsys):
        """房內身分掛在別把 key 底下時，發一個事件把人叫起來。"""
        _write_state(tmp_path, "claude-old-session", room_id=ROOM,
                     name="諾薇亞")
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.preflight()
        events = events_from(capsys)
        assert [e["event"] for e in events] == ["identity_split"]
        ev = events[0]
        # 事件要自己講得出「我是誰、身分在哪」——讀的人不必回去翻 log
        assert ev["room_id"] == ROOM
        assert ev["session_key"] == w.session_key
        assert any("claude-old-session" in k for k in ev["found_in"])

    def test_no_split_no_event(self, fake_hub, tmp_path, monkeypatch, capsys):
        """還沒 join 只是還沒 join——那是正常狀態，不該發事件。

        分不出這兩者的話，每個剛啟動的 watcher 都會叫一次，而真正的分裂
        警告會淹沒在裡面。
        """
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.preflight()
        assert events_from(capsys) == []

    def test_having_my_own_identity_is_quiet(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """自己就有身分時當然不發——這是最常見的正常路徑。"""
        w = make_watcher(
            fake_hub, tmp_path, monkeypatch, "--room", ROOM,
            state={ROOM: {"participant_id": "me", "display_name": "Novia",
                          "last_seq": 0}},
        )
        w.preflight()
        assert events_from(capsys) == []


class TestOrphanStateGC:
    """孤兒 state 檔的清理。

    保守到近乎膽小是刻意的：**誤刪一個還活著的 session 的 state 檔，等於把
    那個 agent 的房內身分與讀取游標一起抹掉**，而它下一次醒來會以為自己從沒
    進過房。所以只清「久到不可能還活著」的，而且門檻可調。
    """

    def test_stale_orphans_are_removed(self, fake_hub, tmp_path, monkeypatch):
        old = _write_state(tmp_path, "claude-ancient", age_days=90)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.gc_state_files()
        assert not old.exists()

    def test_recent_orphans_are_kept(self, fake_hub, tmp_path, monkeypatch):
        """最近動過的不碰——那多半是另一個正開著的 session。"""
        fresh = _write_state(tmp_path, "claude-recent", age_days=1)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.gc_state_files()
        assert fresh.exists()

    def test_my_own_state_is_never_touched(
            self, fake_hub, tmp_path, monkeypatch):
        """**自己的絕不刪**，即使它看起來很舊。

        resume 一個放了很久的 session 是完全正常的用法，而那正是最需要
        身分延續的時刻。
        """
        w = make_watcher(
            fake_hub, tmp_path, monkeypatch, "--room", ROOM,
            state={ROOM: {"participant_id": "me", "display_name": "Novia",
                          "last_seq": 0}},
        )
        mine = identity.state_path(w.session_key)
        old = time.time() - 90 * 86400
        os.utime(mine, (old, old))
        w.gc_state_files()
        assert mine.exists()

    def test_gc_can_be_switched_off(self, fake_hub, tmp_path, monkeypatch):
        """設 0 停用。清理別人的檔案這種事一定要有關掉的方法。"""
        monkeypatch.setenv("CHATROOM_STATE_TTL_DAYS", "0")
        old = _write_state(tmp_path, "claude-ancient", age_days=90)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.gc_state_files()
        assert old.exists()

    def test_gc_survives_an_unreadable_file(
            self, fake_hub, tmp_path, monkeypatch):
        """壞掉的檔案不能讓整個 watcher 起不來。

        GC 是啟動時的附帶動作，它失敗的後果不該大於它的價值。
        """
        bad = tmp_path / identity.state_filename("claude-broken")
        bad.write_text("{ 這不是 JSON", encoding="utf-8")
        old = time.time() - 90 * 86400
        os.utime(bad, (old, old))
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.gc_state_files()   # 不可拋例外
