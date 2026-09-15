"""watcher 對 subagent 的兩條通道：進出事件、以及 @ 到旗下子代理的轉投遞。

兩條都是「只有父層收得到」的定向通知，而定向通知失效一向是靜默的——
沒收到與沒發生在觀測上完全同形。
"""

import argparse

import pytest

from chatroom_mcp.watch import Watcher


def _args(**kw):
    base = dict(
        room="room-1", after_seq=None, all_messages=False, include_system=False,
        assignments=False, codex_thread=None, max_events=0, poll_timeout=1.0,
        idle_interval=1.0, heartbeat=0.0, kind="claude", label=None,
        join_events=True,
    )
    base.update(kw)
    return argparse.Namespace(**base)


def _run(monkeypatch, payload, first_poll=False, **argkw):
    monkeypatch.setenv("CHATROOM_AGENT_KIND", "claude")
    monkeypatch.setenv("CHATROOM_SESSION_KEY", "claude-test")
    w = Watcher(_args(**argkw))
    w.participant_id, w.display_name = "me", "Novia"
    w.first_poll = first_poll
    emitted = []
    seen_params = {}

    def fake_request(*a, **k):
        seen_params.update(k.get("params") or {})
        return {"messages": [], "last_seq": 99, "room_status": "active",
                **payload}

    monkeypatch.setattr(w, "emit", emitted.append)
    monkeypatch.setattr(w.hub, "request", fake_request)
    w.poll_room()
    return w, emitted, seen_params


def test_subagent_join_and_leave_reach_the_parent(monkeypatch):
    _, events, _ = _run(monkeypatch, {"subagent_events": [
        {"event": "subagent_joined", "name": "米勒", "participant_id": "s1"},
        {"event": "subagent_left", "name": "米勒", "participant_id": "s1"},
    ]})

    kinds = [e["event"] for e in events]
    assert kinds == ["subagent_joined", "subagent_left"]
    assert all(e["who"] == "米勒" for e in events)
    # 父層要知道這是掛在自己底下的，不是房裡隨便誰
    assert all(e["parent"] == "Novia" for e in events)


def test_subagent_events_ignore_the_join_events_switch(monkeypatch):
    """``--no-join-events`` 管的是房內成員的進出，不是你自己派出去的東西。

    你就是那些事件唯一的收件人，跟著關掉等於沒有人會知道。
    """
    _, events, _ = _run(
        monkeypatch,
        {"subagent_events": [
            {"event": "subagent_joined", "name": "米勒", "participant_id": "s1"},
        ]},
        join_events=False,
    )
    assert [e["event"] for e in events] == ["subagent_joined"]


def test_cursor_is_echoed_back_never_invented(monkeypatch):
    """游標由 Hub 發、我們原封送回——自己造值會讓時鐘偏差變成漏事件。"""
    w, _, params = _run(monkeypatch, {"subagents_cursor": "2026-08-31T00:00:00+00:00"})
    # 第一輪：還沒有游標可帶
    assert params["subagents_since"] == ""
    assert w.subagents_since == "2026-08-31T00:00:00+00:00"

    # 第二輪要把剛拿到的原封帶回去
    seen = {}
    w.hub.request = lambda *a, **k: (seen.update(k.get("params") or {})
                                     or {"messages": [], "last_seq": 99,
                                         "room_status": "active"})
    w.emit = lambda e: None
    w.poll_room()
    assert seen["subagents_since"] == "2026-08-31T00:00:00+00:00"


def test_mentioning_my_subagent_wakes_me_and_says_who_for(monkeypatch):
    _, events, _ = _run(monkeypatch, {"messages": [{
        "seq": 5, "kind": "chat", "sender_id": "other", "sender_name": "米絲媞",
        "content": "@米勒 這條給你", "mentions": ["米勒"],
        "relayed_mentions": ["米勒"],
    }]})

    msgs = [e for e in events if e["event"] == "message"]
    assert len(msgs) == 1
    assert msgs[0]["mentioned"] is True
    # 只知道「有人叫我」不夠——不知道是給旗下哪一個的，就無從決定要不要轉手
    assert msgs[0]["for_subagent"] == ["米勒"]


def test_unrelated_message_still_does_not_wake_me(monkeypatch):
    """錨點：轉投遞不能寬到把每則訊息都變成 mention。"""
    _, events, _ = _run(monkeypatch, {"messages": [{
        "seq": 5, "kind": "chat", "sender_id": "other", "sender_name": "米絲媞",
        "content": "隨口說說", "mentions": [], "relayed_mentions": [],
    }]})
    assert [e for e in events if e["event"] == "message"] == []
