"""帶著**舊 session key** 重掛 watcher 時要大聲失敗，不能安靜 exit 0。

crash 復原專屬的失敗，而且原本長得像正常收工：

1. 舊 key 的 state 檔裡**有** participant_id（只是那個 participant 已經被
   presence sweeper 移除了）
2. ⇒ `preflight` 的「有身分就放行」直接通過，什麼都沒驗
3. ⇒ 第一次 heartbeat 拿到 `participant_not_active` ⇒ 發一個
   `departure(reason=idle)` ⇒ **exit 0**

於是 Monitor 上看到的是「這個房結束了」，而真相是「你帶著一把死掉的 key
進來」。兩台 agent 在 2026-09-03 各自撞到，兩位都誤判成別的原因——一個說是
舊游標撞到同名的離場訊息，一個說是名字比對不唯一。都不是。

⚠️ **「別把 key 寫死」解不了這件事**：crash 重開之後，Monitor 那個 shell 拿到
的 `CLAUDE_CODE_SESSION_ID` 仍是舊 session 的，而 MCP bridge 進程拿到的是
新的（三台實測一致）。照 `${CLAUDE_CODE_SESSION_ID}` 寫一樣會拿到舊 key，
變數展開成功了，只是值是舊的。**驗證是唯一可靠的解。**
"""

import json

import pytest

from test_watch import events_from, make_watcher, ROOM


def _room_with(participants):
    return {"id": ROOM, "name": "房", "participants": participants}


class TestStaleKeyFailsLoudly:
    def test_a_dead_participant_stops_the_watcher_with_an_event(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """state 裡的身分在房裡是 removed ⇒ 發事件並以非 0 結束。"""
        fake_hub.json("GET", f"/api/rooms/{ROOM}", _room_with([
            {"id": "dead-pid", "display_name": "諾薇亞", "status": "removed"},
            {"id": "live-pid", "display_name": "諾薇亞", "status": "active"},
        ]))
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state={ROOM: {"participant_id": "dead-pid",
                                       "display_name": "諾薇亞",
                                       "last_seq": 0}})
        with pytest.raises(SystemExit) as exc:
            w.preflight()
        assert exc.value.code != 0, "安靜地 exit 0 與「這個房結束了」分不出來"

        (ev,) = events_from(capsys)
        assert ev["event"] == "stale_identity"
        assert ev["session_key"] == w.session_key
        assert ev["participant_id"] == "dead-pid"
        assert ev["participant_status"] == "removed"
        # 🔑 **最有用的一行**：他在房內看得到自己同名的新身分還活著，
        # 於是立刻知道「我掛的是舊的那個」
        assert ev["active_names"] == ["諾薇亞"]

    def test_a_participant_that_is_gone_entirely_also_counts(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """房間名冊裡查不到那個 id（房被清過）也是同一件事。"""
        fake_hub.json("GET", f"/api/rooms/{ROOM}", _room_with([
            {"id": "someone-else", "display_name": "別人", "status": "active"},
        ]))
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state={ROOM: {"participant_id": "vanished",
                                       "display_name": "諾薇亞",
                                       "last_seq": 0}})
        with pytest.raises(SystemExit):
            w.preflight()
        (ev,) = events_from(capsys)
        assert ev["participant_status"] == "not_found"

    def test_a_live_identity_passes_quietly(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """身分還活著＝正常啟動，一個事件都不該發。

        ⚠️ 這半不能省：只驗「該擋的擋了」的話，**一律擋下**也會通過，
        而那會讓每個 watcher 都掛不起來。
        """
        fake_hub.json("GET", f"/api/rooms/{ROOM}", _room_with([
            {"id": "live-pid", "display_name": "諾薇亞", "status": "active"},
        ]))
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state={ROOM: {"participant_id": "live-pid",
                                       "display_name": "諾薇亞",
                                       "last_seq": 0}})
        w.preflight()
        assert events_from(capsys) == []

    def test_a_hub_that_cannot_be_read_does_not_accuse_anyone(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """讀不到房間時**不下判斷**。

        Hub 可能只是剛好在重啟，而把暫時性失敗說成「你的身分死了」會把人
        送去查完全錯的方向——而且會讓 watcher 在 Hub 重啟期間全部自殺。
        """
        fake_hub.error("GET", f"/api/rooms/{ROOM}", 503,
                       {"code": "hub_restarting", "message": "Hub 正在重啟"})
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state={ROOM: {"participant_id": "whoever",
                                       "display_name": "諾薇亞",
                                       "last_seq": 0}})
        w.preflight()          # 不該拋
        assert events_from(capsys) == []
