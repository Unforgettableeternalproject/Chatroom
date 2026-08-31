"""身分分裂要發成**事件**，以及久沒動的身分檔只報告不刪除（G2 方向 3 / F10）。

分裂的自檢邏輯本來就有，但它只走 ``_log``——那是 stderr，而 Monitor 只把
**stdout** 當事件流。於是最該被叫醒的那個人（正在等指派、而指派永遠不會到
的那個 agent）看不到它：他的終端機上什麼都沒有，房內也什麼都沒有。

**診斷訊息送到沒有人在看的地方，等於沒有診斷。**

另一半是墓地：每個死掉的 session 都留下一個 state 檔，這台開發機累積了九個。
第一版會自動清掉超過 30 天沒動的——**那個授權是錯的**，見下面
`TestStaleStatesAreReportedNotDeleted` 的理由。現在只報告數字。
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


class TestStaleStatesAreReportedNotDeleted:
    """久沒動的身分檔**只報告，不刪除**（審核用Codex-2 的 F10）。

    原本這裡會自動 unlink。那個授權是錯的：

    - **mtime 不構成 orphan 的證據**——「30 天沒啟動」與「已經死了」是兩回
      事，而 resume 一個放很久的 session 正是最需要身分延續的時刻
    - 排除「自己的」時用檔名比對會失守：assignment 兌換之後檔名仍是舊的
      fallback、內容才是 canonical

    收益是美觀，代價是可能永久刪掉一個活著的身分。**不對等。**
    """

    def test_stale_files_are_never_deleted(
            self, fake_hub, tmp_path, monkeypatch):
        """就算舊到 90 天也不刪——那是別人的檔案，也可能是別人的身分。"""
        old = _write_state(tmp_path, "claude-ancient", age_days=90)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.report_stale_states()
        assert old.exists()

    def test_it_still_reports_the_count(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """量測的價值保留——人看到數字自己決定要不要清。"""
        _write_state(tmp_path, "claude-ancient", age_days=90)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.report_stale_states()
        err = capsys.readouterr().err
        assert "1 個" in err and "不會自動清除" in err

    def test_recent_files_are_not_even_mentioned(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """最近動過的連提都不提——多開 session 是常態，那不是異常。"""
        _write_state(tmp_path, "claude-recent", age_days=1)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.report_stale_states()
        assert capsys.readouterr().err == ""

    def test_my_own_state_is_identified_by_content_not_filename(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """**自己的那份不算進去，而且要依內容認**。

        canonical 化之後檔名仍是舊 fallback、內容才是新 key——用
        `state_path`（依 key 算檔名）比對的話，自己的檔案會被算成別人的。
        """
        canonical = "01a05774-2650-7e53"
        path = tmp_path / identity.state_filename("codex-oldfallback")
        path.write_text(
            json.dumps({"version": 1, "session_key": canonical, "rooms": {}}),
            encoding="utf-8")
        old = time.time() - 90 * 86400
        os.utime(path, (old, old))

        monkeypatch.setenv("CHATROOM_SESSION_KEY", canonical)
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        monkeypatch.delenv("CHATROOM_STATE_PATH", raising=False)
        w.report_stale_states()
        # 那份就是自己的，不該被算成「別人留下的舊檔」
        assert "1 個" not in capsys.readouterr().err

    def test_reporting_can_be_switched_off(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        _write_state(tmp_path, "claude-ancient", age_days=90)
        monkeypatch.setenv("CHATROOM_STATE_TTL_DAYS", "0")
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.report_stale_states()
        assert capsys.readouterr().err == ""

    def test_an_unreadable_file_does_not_break_startup(
            self, fake_hub, tmp_path, monkeypatch):
        """壞掉的檔案不能讓 watcher 起不來——這是啟動時的附帶動作。"""
        bad = tmp_path / identity.state_filename("claude-broken")
        bad.write_text("{ 這不是 JSON", encoding="utf-8")
        old = time.time() - 90 * 86400
        os.utime(bad, (old, old))
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
        w.report_stale_states()
