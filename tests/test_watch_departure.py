"""watcher 收到離場訊號時，必須真的發出 departure 事件並結束。

Hub 回對的錯誤碼不等於 agent 收得到——中間任何一層吞掉都是靜默失效，
而「沒有事件」和「一切正常」在 Monitor 上看起來一模一樣。
"""

import argparse
import json

import pytest

from chatroom_mcp.hub import HubError
from chatroom_mcp.watch import Watcher


def _args(**kw):
    base = dict(
        room="room-1", after_seq=None, all_messages=False, include_system=False,
        assignments=False, codex_thread=None, max_events=0, poll_timeout=1.0,
        idle_interval=1.0, heartbeat=0.0, kind="claude", label=None,
    )
    base.update(kw)
    return argparse.Namespace(**base)


def _watcher(monkeypatch, responses):
    """建一個 watcher，其 hub.request 依序回傳／拋出 responses 的內容。"""
    monkeypatch.setenv("CHATROOM_AGENT_KIND", "claude")
    monkeypatch.setenv("CHATROOM_SESSION_KEY", "claude-test")
    w = Watcher(_args())
    w.participant_id = "pid-1"
    w.display_name = "測試者"
    calls = iter(responses)

    def fake_request(*a, **kw):
        item = next(calls)
        if isinstance(item, Exception):
            raise item
        return item

    monkeypatch.setattr(w.hub, "request", fake_request)
    return w


def _events(capsys):
    out = capsys.readouterr().out.strip().splitlines()
    return [json.loads(line) for line in out if line.startswith("{")]


def test_archived_room_emits_departure(monkeypatch, capsys):
    """封存不會讓身分失效，只能靠 room_status 認出來。"""
    w = _watcher(monkeypatch, [
        {"messages": [], "last_seq": 0, "room_status": "archived"},
    ])
    assert w._loop() == 0
    events = _events(capsys)
    assert len(events) == 1
    assert events[0]["event"] == "departure"
    assert events[0]["reason"] == "archived"
    assert events[0]["rejoinable"] is False
    assert events[0]["room_id"] == "room-1"


def test_kicked_emits_departure_marked_not_rejoinable(monkeypatch, capsys):
    w = _watcher(monkeypatch, [
        HubError("你已被管理員移出這個聊天室。", status=403,
                 identity_invalid=True, departure="kicked"),
    ])
    assert w._loop() == 0
    events = _events(capsys)
    assert events[0]["event"] == "departure"
    assert events[0]["reason"] == "kicked"
    assert events[0]["rejoinable"] is False


def test_idle_removal_is_rejoinable(monkeypatch, capsys):
    """閒置移除是自動清理，agent 想回來就該回得來——與被踢的處置相反。"""
    w = _watcher(monkeypatch, [
        HubError("你因閒置逾時被移出聊天室。", status=403,
                 identity_invalid=True, departure="idle"),
    ])
    assert w._loop() == 0
    events = _events(capsys)
    assert events[0]["event"] == "departure"
    assert events[0]["reason"] == "idle"
    assert events[0]["rejoinable"] is True


def test_active_room_does_not_emit_departure(monkeypatch, capsys):
    """房間正常時絕不能誤發離場——誤報會讓 agent 自己收掉還在用的監看。"""
    w = _watcher(monkeypatch, [
        {"messages": [], "last_seq": 0, "room_status": "active"},
        HubError("你已被管理員移出。", status=403,
                 identity_invalid=True, departure="kicked"),
    ])
    assert w._loop() == 0
    events = _events(capsys)
    assert len(events) == 1, "第一輪不該發任何事件"
    assert events[0]["reason"] == "kicked"


def test_transient_error_does_not_emit_departure(monkeypatch, capsys):
    """Hub 重啟／斷網不是離場。把它當離場會讓 agent 在 Hub 恢復後再也不回來。"""
    w = _watcher(monkeypatch, [
        HubError("無法連線到 Chatroom Hub"),
        {"messages": [], "last_seq": 0, "room_status": "archived"},
    ])
    monkeypatch.setattr("chatroom_mcp.watch.TRANSIENT_RETRY_SECS", 0.0)
    assert w._loop() == 0
    events = _events(capsys)
    assert len(events) == 1
    assert events[0]["reason"] == "archived"


def test_heartbeat_failure_reports_departure(monkeypatch, capsys):
    """heartbeat 週期通常比 long-poll 一輪短，常是最早看到離場的地方。"""
    w = _watcher(monkeypatch, [])
    w.args.heartbeat = 1.0
    w.last_heartbeat = -999.0

    def boom(*a, **kw):
        raise HubError("你已被管理員移出這個聊天室。", status=403,
                       identity_invalid=True, departure="kicked")

    monkeypatch.setattr(w.hub, "request", boom)
    w.maybe_heartbeat()
    events = _events(capsys)
    assert events[0]["event"] == "departure"
    assert events[0]["reason"] == "kicked"
    assert w.departed is True


@pytest.mark.parametrize("reason,rejoinable", [
    ("idle", True), ("left", True), ("kicked", False), ("archived", False),
])
def test_rejoinable_mapping(monkeypatch, capsys, reason, rejoinable):
    w = _watcher(monkeypatch, [])
    w.depart(reason, "說明")
    assert _events(capsys)[0]["rejoinable"] is rejoinable
