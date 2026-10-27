"""watcher 重掛不重推：游標必須記得「上次推到哪」。

事故：Monitor 到期重掛，新 watcher 從 bridge 的讀取游標（chatroom_read 才會
推進）起算，於是上一個 watcher 已推過、但 agent 還沒 read 的 mention 每次
重掛都再推一次。
"""

import json

import httpx

from chatroom_mcp import watch
from chatroom_mcp.hub import HubClient

ROOM = "room-1"
ME = {ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 0}}


def _msg(seq: int, text: str, mentions=None, kind="chat") -> dict:
    return {"seq": seq, "kind": kind, "sender_id": "p9", "sender_name": "Bernie",
            "content": text, "mentions": mentions or []}


class Log:
    """會依 after_seq 過濾的假房間訊息流。"""

    def __init__(self) -> None:
        self.messages: list[dict] = []
        self.after_seqs: list[int] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        after = int(request.url.params.get("after_seq", 0))
        self.after_seqs.append(after)
        msgs = [m for m in self.messages if m["seq"] > after]
        last = max([after] + [m["seq"] for m in msgs])
        return httpx.Response(200, json={"messages": msgs, "last_seq": last})


def _boot(fake_hub, log, tmp_path, monkeypatch):
    """模擬一次 Monitor 啟動：全新的 Watcher 進程，state 檔沿用同一份。"""
    state_path = tmp_path / "watch-state.json"
    if not state_path.exists():
        state_path.write_text(json.dumps({"version": 1, "rooms": ME}),
                              encoding="utf-8")
    monkeypatch.setenv("CHATROOM_STATE_PATH", str(state_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("HOME", str(tmp_path))
    fake_hub.on("GET", f"/api/rooms/{ROOM}/updates", log.handler)
    args = watch.build_parser().parse_args(["--room", ROOM])
    w = watch.Watcher(args)
    w.hub = HubClient(base_url="http://hub.test", token="",
                      transport=fake_hub.transport)
    return w


def _events(capsys) -> list[dict]:
    return [json.loads(x) for x in capsys.readouterr().out.splitlines() if x]


def test_remount_does_not_repush_already_pushed(fake_hub, tmp_path, monkeypatch, capsys):
    log = Log()
    log.messages = [_msg(10, "@Novia 請看", ["Novia"])]

    w1 = _boot(fake_hub, log, tmp_path, monkeypatch)
    w1.poll_room()
    assert [e["seq"] for e in _events(capsys)] == [10]

    # agent 沒有 chatroom_read（bridge 游標仍是 0），watcher 被 Monitor 到期重掛
    w2 = _boot(fake_hub, log, tmp_path, monkeypatch)
    w2.poll_room()
    assert _events(capsys) == []


def test_remount_backfills_mention_during_gap(fake_hub, tmp_path, monkeypatch, capsys):
    log = Log()
    log.messages = [_msg(10, "@Novia 第一則", ["Novia"])]

    w1 = _boot(fake_hub, log, tmp_path, monkeypatch)
    w1.poll_room()
    assert [e["seq"] for e in _events(capsys)] == [10]

    # 斷線期間（沒有 watcher 在跑）來了新的 mention 與閒聊
    log.messages += [_msg(11, "閒聊"), _msg(12, "@Novia 斷線期間", ["Novia"])]

    w2 = _boot(fake_hub, log, tmp_path, monkeypatch)
    w2.poll_room()
    ev = _events(capsys)
    assert [e["seq"] for e in ev] == [12]


def test_explicit_after_seq_beats_saved_cursor(fake_hub, tmp_path, monkeypatch, capsys):
    log = Log()
    log.messages = [_msg(10, "@Novia 請看", ["Novia"])]
    w1 = _boot(fake_hub, log, tmp_path, monkeypatch)
    w1.poll_room()
    _events(capsys)

    fake_hub.on("GET", f"/api/rooms/{ROOM}/updates", log.handler)
    args = watch.build_parser().parse_args(["--room", ROOM, "--after-seq", "0"])
    w2 = watch.Watcher(args)
    w2.hub = HubClient(base_url="http://hub.test", token="",
                       transport=fake_hub.transport)
    w2.poll_room()
    assert [e["seq"] for e in _events(capsys)] == [10]


def test_cursor_file_never_touches_bridge_state(fake_hub, tmp_path, monkeypatch, capsys):
    log = Log()
    log.messages = [_msg(10, "@Novia 請看", ["Novia"])]
    w = _boot(fake_hub, log, tmp_path, monkeypatch)
    before = (tmp_path / "watch-state.json").read_text(encoding="utf-8")
    w.poll_room()
    assert (tmp_path / "watch-state.json").read_text(encoding="utf-8") == before
