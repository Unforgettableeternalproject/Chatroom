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
    args = watch.build_parser().parse_args(list(argv))
    w = watch.Watcher(args)
    w.hub = HubClient(base_url="http://hub.test", token="", transport=fake_hub.transport)
    return w


def events_from(capsys) -> list[dict]:
    return [json.loads(line) for line in capsys.readouterr().out.splitlines() if line]


def test_emits_message_events_and_advances_cursor(fake_hub, tmp_path, monkeypatch, capsys):
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM)
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
        fake_hub, tmp_path, monkeypatch, "--room", ROOM,
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


def test_mentions_only_filter(fake_hub, tmp_path, monkeypatch, capsys):
    w = make_watcher(
        fake_hub, tmp_path, monkeypatch, "--room", ROOM, "--mentions-only",
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
                     "--no-assignments", "--max-events", "1")
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 1, "kind": "chat", "sender_id": "p9",
                       "sender_name": "Bernie", "content": "hi", "mentions": []}],
         "you_were_mentioned": False, "last_seq": 1},
    )
    assert w.run() == 0
    ev = events_from(capsys)
    assert [e["event"] for e in ev] == ["message", "watch_ended"]


def test_watcher_never_writes_bridge_state(fake_hub, tmp_path, monkeypatch, capsys):
    """watcher 是唯讀觀察者：state 檔推進游標是 chatroom_read 的職責。"""
    state_before = {ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 1}}
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM, state=state_before)
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 9, "kind": "chat", "sender_id": "p9",
                       "sender_name": "Bernie", "content": "x", "mentions": []}],
         "you_were_mentioned": False, "last_seq": 9},
    )
    w.poll_room()
    on_disk = json.loads((tmp_path / "watch-state.json").read_text(encoding="utf-8"))
    assert on_disk["rooms"][ROOM]["last_seq"] == 1  # 檔案原封不動
