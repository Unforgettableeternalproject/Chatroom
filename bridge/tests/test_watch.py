"""watch.py（常駐通知 watcher）單元測試。

Watcher 直接注入 FakeHub 的 HubClient；事件輸出用 capsys 收——
一行一個 JSON 是它與 Monitor 的契約，格式壞掉通知就啞了。
"""

import json

import pytest

from chatroom_mcp import watch
from chatroom_mcp.hub import HubClient

from conftest import FakeHub

ROOM = "room-1"


def make_watcher(fake_hub, tmp_path, monkeypatch, *argv, state=None):
    """建好 Watcher：假 Hub、state 檔導到 tmp，游標/身分可預先塞。"""
    state_path = tmp_path / "watch-state.json"
    if state is not None:
        state_path.write_text(
            json.dumps({"version": 1, "rooms": state}), encoding="utf-8"
        )
    monkeypatch.setenv("CHATROOM_STATE_PATH", str(state_path))
    # 家目錄也要導開：_state_candidates 會掃 ~/.chatroom，不隔離的話測試會
    # 讀到**這台機器上真實的** state 檔，結果隨開發者的機器狀態而變
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("HOME", str(tmp_path))
    args = watch.build_parser().parse_args(list(argv))
    w = watch.Watcher(args)
    w.hub = HubClient(base_url="http://hub.test", token="", transport=fake_hub.transport)
    return w


def events_from(capsys) -> list[dict]:
    return [json.loads(line) for line in capsys.readouterr().out.splitlines() if line]


def test_emits_message_events_and_advances_cursor(fake_hub, tmp_path, monkeypatch, capsys):
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM, "--all-messages")
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            {"seq": 5, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
             "content": "哈囉  諾薇亞", "mentions": [], "pinned": False, "deleted": False},
        ], "you_were_mentioned": False, "last_seq": 5},
    )
    w.poll_room()
    ev = events_from(capsys)
    assert len(ev) == 1
    assert ev[0]["event"] == "message"
    assert ev[0]["sender"] == "Bernie"
    assert ev[0]["preview"] == "哈囉 諾薇亞"  # 空白收斂成單一空格
    assert w.after_seq == 5  # 游標推進（僅進程內，不寫回 bridge state）


def test_skips_own_and_system_messages(fake_hub, tmp_path, monkeypatch, capsys):
    """自己發的與 system 訊息不喚醒 agent——每個事件都是一次打擾。"""
    w = make_watcher(
        fake_hub, tmp_path, monkeypatch, "--room", ROOM, "--all-messages",
        state={ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 0}},
    )
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            {"seq": 1, "kind": "system", "sender_id": None, "sender_name": None,
             "content": "Bernie 加入了聊天室", "mentions": []},
            {"seq": 2, "kind": "chat", "sender_id": "me", "sender_name": "Novia",
             "content": "我自己說的話", "mentions": []},
            {"seq": 3, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
             "content": "這句才要通知", "mentions": []},
        ], "you_were_mentioned": False, "last_seq": 3},
    )
    w.poll_room()
    ev = events_from(capsys)
    assert [e["preview"] for e in ev] == ["這句才要通知"]
    assert w.after_seq == 3  # 被略過的訊息仍推進游標，不會下輪重看


def test_default_emits_only_mentions(fake_hub, tmp_path, monkeypatch, capsys):
    """預設只有被 @mention 的訊息喚醒；其餘留給 chatroom_read 自己撈。"""
    w = make_watcher(
        fake_hub, tmp_path, monkeypatch, "--room", ROOM,
        state={ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 0}},
    )
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            {"seq": 1, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
             "content": "閒聊", "mentions": []},
            {"seq": 2, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
             "content": "@Novia 來一下", "mentions": ["Novia"]},
        ], "you_were_mentioned": True, "last_seq": 2},
    )
    w.poll_room()
    ev = events_from(capsys)
    assert len(ev) == 1
    assert ev[0]["mentioned"] is True
    assert ev[0]["seq"] == 2
    assert w.after_seq == 2  # 被過濾的訊息仍推進游標


def test_pin_update_does_not_wake(fake_hub, tmp_path, monkeypatch, capsys):
    """既有訊息的釘選/刪除變更（seq 落在游標之前）不發事件——
    即使那則舊訊息當初有 @mention 自己。釘選牆是主動撈的東西。"""
    w = make_watcher(
        fake_hub, tmp_path, monkeypatch, "--room", ROOM, "--all-messages",
        state={ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 5}},
    )
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            # 舊訊息 seq=3 被釘選，領了 update_seq=6 重新入流
            {"seq": 3, "update_seq": 6, "kind": "chat", "sender_id": "p9",
             "sender_name": "Bernie", "content": "老訊息被釘選",
             "mentions": ["Novia"], "pinned": True},
            {"seq": 7, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
             "content": "新訊息", "mentions": []},
        ], "you_were_mentioned": True, "last_seq": 7},
    )
    w.poll_room()
    ev = events_from(capsys)
    assert [e["preview"] for e in ev] == ["新訊息"]
    assert w.after_seq == 7


def test_identity_reloaded_after_late_join(fake_hub, tmp_path, monkeypatch, capsys):
    """watcher 先啟動、bridge 後 join：下一輪 poll 補讀 state 取得
    display_name，mention 過濾隨即生效（否則永遠收不到 tag）。"""
    state_path = tmp_path / "watch-state.json"
    monkeypatch.setenv("CHATROOM_STATE_PATH", str(state_path))
    args = watch.build_parser().parse_args(["--room", ROOM])
    w = watch.Watcher(args)
    w.hub = HubClient(base_url="http://hub.test", token="",
                      transport=fake_hub.transport)
    assert w.display_name is None
    # bridge 事後 join，寫入 state
    state_path.write_text(
        json.dumps({"version": 1, "rooms": {
            ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 0}
        }}),
        encoding="utf-8",
    )
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            {"seq": 1, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
             "content": "@Novia 在嗎", "mentions": ["Novia"]},
        ], "you_were_mentioned": True, "last_seq": 1},
    )
    w.poll_room()
    ev = events_from(capsys)
    assert len(ev) == 1
    assert ev[0]["mentioned"] is True


def test_cursor_starts_from_bridge_state(fake_hub, tmp_path, monkeypatch):
    """起始游標沿用 bridge 已讀位置——agent 讀過的不需要再被通知一次。"""
    w = make_watcher(
        fake_hub, tmp_path, monkeypatch, "--room", ROOM,
        state={ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 42}},
    )
    assert w.after_seq == 42
    assert w.participant_id == "me"


def test_assignment_events_dedupe(fake_hub, tmp_path, monkeypatch, capsys):
    w = make_watcher(fake_hub, tmp_path, monkeypatch)
    fake_hub.json(
        "GET", "/api/assignments",
        {"assignments": [{"id": "a1", "room_id": ROOM, "room_name": "設計討論",
                          "note": "來看架構"}]},
    )
    w.poll_assignments()
    w.poll_assignments()  # 同一筆指派只通知一次
    ev = events_from(capsys)
    assert len(ev) == 1
    assert ev[0]["event"] == "assignment"
    assert ev[0]["room_name"] == "設計討論"


def test_run_ends_cleanly_when_room_gone(fake_hub, tmp_path, monkeypatch, capsys):
    """房間不存在＝監看標的消失：發 watch_ended 後以 0 退出，不無限重試。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM, "--no-assignments")
    fake_hub.error("GET", f"/api/rooms/{ROOM}/updates", 404,
                   {"code": "room_not_found", "message": "找不到這個聊天室"})
    assert w.run() == 0
    ev = events_from(capsys)
    assert ev[-1]["event"] == "watch_ended"


def test_max_events_stops_process(fake_hub, tmp_path, monkeypatch, capsys):
    """--max-events 1 = Codex 的同步等待模式：收到第一個事件就返回。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     "--no-assignments", "--max-events", "1", "--all-messages")
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 1, "kind": "chat", "sender_id": "p9",
                       "sender_name": "Bernie", "content": "hi", "mentions": []}],
         "you_were_mentioned": False, "last_seq": 1},
    )
    assert w.run() == 0
    ev = events_from(capsys)
    assert [e["event"] for e in ev] == ["message", "watch_ended"]


def test_codex_dispatch_queues_event_without_shell(fake_hub, tmp_path, monkeypatch, capsys):
    """--codex-thread：事件以 argv 直接傳給 codex queue，不經 shell（注入面）。"""
    monkeypatch.setattr(watch, "_resolve_codex_argv", lambda: ["codex-bin"])
    calls = []

    class Done:
        returncode = 0
        stdout = "Queued message x"
        stderr = ""

    monkeypatch.setattr(watch.subprocess, "run",
                        lambda argv, **kw: calls.append(argv) or Done())
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     "--codex-thread", "thread-uuid", "--all-messages")
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 1, "kind": "chat", "sender_id": "p9",
                       "sender_name": "Bernie", "content": 'a"b & c', "mentions": []}],
         "you_were_mentioned": False, "last_seq": 1},
    )
    w.poll_room()
    assert len(calls) == 1
    argv = calls[0]
    assert argv[:2] == ["codex-bin", "queue"]
    assert argv[argv.index("--thread") + 1] == "thread-uuid"
    message = argv[argv.index("--message") + 1]
    assert message.startswith("[chatroom 通知] ")
    assert json.loads(message.removeprefix("[chatroom 通知] "))["preview"] == 'a"b & c'


def test_codex_dispatch_failure_does_not_kill_watcher(fake_hub, tmp_path, monkeypatch, capsys):
    """queue 失敗（Codex 沒開等）只記 stderr，事件照樣輸出、watcher 續命。"""
    monkeypatch.setattr(watch, "_resolve_codex_argv", lambda: ["codex-bin"])
    monkeypatch.setattr(watch.subprocess, "run",
                        lambda argv, **kw: (_ for _ in ()).throw(OSError("gone")))
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     "--codex-thread", "thread-uuid", "--all-messages")
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 1, "kind": "chat", "sender_id": "p9",
                       "sender_name": "Bernie", "content": "hi", "mentions": []}],
         "you_were_mentioned": False, "last_seq": 1},
    )
    w.poll_room()
    assert len(events_from(capsys)) == 1  # stdout 事件流不受影響


def test_watcher_never_writes_bridge_state(fake_hub, tmp_path, monkeypatch, capsys):
    """watcher 是唯讀觀察者：state 檔推進游標是 chatroom_read 的職責。"""
    state_before = {ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 1}}
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     "--all-messages", state=state_before)
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 9, "kind": "chat", "sender_id": "p9",
                       "sender_name": "Bernie", "content": "x", "mentions": []}],
         "you_were_mentioned": False, "last_seq": 9},
    )
    w.poll_room()
    on_disk = json.loads((tmp_path / "watch-state.json").read_text(encoding="utf-8"))
    assert on_disk["rooms"][ROOM]["last_seq"] == 1  # 檔案原封不動


# ---------- 指派模式的自檢 ----------
#
# 2026-08-30（測試端）：`_sibling_states` 的分裂警告只掛在 --room 迴圈上，
# 而指派正是分裂的第一個受害者——bridge 用一把 key、watcher 用另一把，
# 指派送到 bridge 那把上，watcher 永遠不會醒，全程沒有任何警示。


def _foreign_state(tmp_path, key: str) -> None:
    """在同一個資料夾放一份別把 key 的 state 檔。"""
    (tmp_path / f"state-{key}.json").write_text(
        json.dumps({"version": 1, "session_key": key,
                    "rooms": {ROOM: {"participant_id": "p-other"}}}),
        encoding="utf-8",
    )


def test_assignment_only_mode_hints_when_other_keys_exist(
    fake_hub, tmp_path, monkeypatch, capsys
):
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--kind", "claude")
    _foreign_state(tmp_path, "claude-somebody-else")
    w.preflight()
    out = capsys.readouterr().err  # 日誌走 stderr，stdout 只能有事件 JSON
    assert "your_session_key" in out, "要講出怎麼比對兩把 key"
    # 措辭必須說明多開是正常的——喊成分裂會讓真正的警告變雜訊
    assert "正常" in out
    assert "⚠️" not in out, "這是提示不是警告"


def test_assignment_only_mode_is_quiet_when_alone(
    fake_hub, tmp_path, monkeypatch, capsys
):
    """只有自己一把 key 時不要出聲——沒有東西可疑。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--kind", "claude")
    w.preflight()
    assert capsys.readouterr().err.strip() == ""


def test_watcher_leaves_when_the_room_is_deleted(
    fake_hub, tmp_path, monkeypatch, capsys
):
    """房間被永久刪除時 watcher 要自己結束，而不是無限重試。

    這是 403 那條保命契約的鏡像（2026-08-30 測試端提出）：房不在了，重試
    只會生出一隻永遠打 Hub 的殭屍。而它與封存的處置不同——封存房還讀得到
    歷史、人可以解封；被刪的房不會回來。
    """
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     "--kind", "claude", state={ROOM: {"participant_id": "p1"}})
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [], "you_were_mentioned": False, "last_seq": 0,
         "room_status": "deleted"},
    )
    w.poll_room()
    events = events_from(capsys)
    departures = [e for e in events if e.get("event") == "departure"]
    assert departures, "房間消失要發 departure 事件，不然沒有人知道它為什麼停了"
    assert departures[-1]["reason"] == "deleted"
    assert "刪除" in departures[-1]["message"]


def test_system_message_that_mentions_me_wakes_me_up(
    fake_hub, tmp_path, monkeypatch, capsys
):
    """點名到我的系統訊息要喚醒我——問答收據與釘選通知都是這種。

    2026-08-30 實際發生：`chatroom_ask_human` 逾時後我放棄等待，人回答了，
    Hub 照設計發出 mention 我的收據（kind=system），而 watcher 在
    `include_system` 關閉時把所有系統訊息一律跳過——mention 判斷寫在那個
    continue 之後，永遠走不到。於是「放棄等待之後才被回答」這個收據唯一
    要服務的情境，剛好就是它失效的情境。
    """
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state={ROOM: {"participant_id": "p1",
                                   "display_name": "開發Novia"}})
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            {"seq": 7, "kind": "system", "system_event": "question_answered",
             "sender_id": None, "sender_name": None,
             "content": "開發Novia 的提問「…」—— Bernie 回答：好",
             "mentions": ["開發Novia"], "pinned": False, "deleted": False},
        ], "you_were_mentioned": True, "last_seq": 7},
    )
    w.poll_room()
    ev = [e for e in events_from(capsys) if e.get("event") == "message"]
    assert ev, "收據 mention 了我卻沒有喚醒——那個 mention 就白加了"
    assert ev[0]["mentioned"] is True


def test_system_message_without_a_mention_still_stays_quiet(
    fake_hub, tmp_path, monkeypatch, capsys
):
    """沒點名的系統訊息照舊不吵人——放行的是 mention，不是所有 system。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state={ROOM: {"participant_id": "p1",
                                   "display_name": "開發Novia"}})
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [
            {"seq": 8, "kind": "system", "system_event": "visibility",
             "sender_id": None, "sender_name": None,
             "content": "這個對話已鎖定為私人",
             "mentions": [], "pinned": False, "deleted": False},
        ], "you_were_mentioned": False, "last_seq": 8},
    )
    w.poll_room()
    assert [e for e in events_from(capsys) if e.get("event") == "message"] == []


def test_deleted_room_is_not_rejoinable(fake_hub, tmp_path, monkeypatch, capsys):
    """被刪的房回不去了。漏登記的話會拿到 rejoinable: true——又一條死路。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     "--kind", "claude", state={ROOM: {"participant_id": "p1"}})
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [], "you_were_mentioned": False, "last_seq": 0,
         "room_status": "deleted"},
    )
    w.poll_room()
    dep = [e for e in events_from(capsys) if e.get("event") == "departure"][-1]
    assert dep["reason"] == "deleted"
    assert dep["rejoinable"] is False


def test_every_departure_reason_is_registered_as_rejoinable_or_not():
    """新增離場理由時別忘了登記——漏掉會靜靜地拿到預設值 True。"""
    from chatroom_mcp.watch import DEPARTURE_EVENTS, REJOINABLE
    for reason in DEPARTURE_EVENTS.values():
        assert reason in REJOINABLE or reason == "idle_removed", (
            f"離場理由 {reason} 沒有登記在 REJOINABLE 裡"
        )
    for reason in ("archived", "deleted", "kicked"):
        assert reason in REJOINABLE
