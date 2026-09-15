"""離場事件必須跟進場成對推給房內其他 agent。

只推進場的話，每個 agent 心裡的成員名單只增不減，越待越失真——然後就會
@ 到一個已經不在的人，而那個 mention 不會有任何人收到。

2026-08-29 實測：同一個房間發生兩次離場（一次被踢、一次閒置移出），
旁觀的 agent 一次都沒被告知，直到有人手動去撈訊息才發現。
"""

import argparse

import pytest

from chatroom_mcp.watch import Watcher, _who_left


def _args(**kw):
    base = dict(
        room="room-1", after_seq=None, all_messages=False, include_system=False,
        assignments=False, codex_thread=None, max_events=0, poll_timeout=1.0,
        idle_interval=1.0, heartbeat=0.0, kind="claude", label=None,
        join_events=True,
    )
    base.update(kw)
    return argparse.Namespace(**base)


def _system(seq, event, content):
    """Hub 的離場 system 訊息：三種都以 sender_id=None 發出。"""
    return {
        "seq": seq, "kind": "system", "system_event": event,
        "sender_id": None, "sender_name": None, "content": content,
        "mentions": [],
    }


def _run(monkeypatch, messages, first_poll=False, **argkw):
    """跑一輪 poll_room，收集發出的事件。

    ``first_poll=False`` 是預設，因為多數案例要驗的是「進出事件長什麼樣」，
    而掛上後的第一輪刻意不發進出（那些是歷史）。要驗第一輪的抑制行為時
    傳 True。
    """
    monkeypatch.setenv("CHATROOM_AGENT_KIND", "claude")
    monkeypatch.setenv("CHATROOM_SESSION_KEY", "claude-test")
    w = Watcher(_args(**argkw))
    w.participant_id, w.display_name = "me", "我"
    w.first_poll = first_poll
    emitted = []
    monkeypatch.setattr(w, "emit", emitted.append)
    monkeypatch.setattr(
        w.hub, "request",
        lambda *a, **k: {"messages": messages, "last_seq": 99,
                         "room_status": "active"},
    )
    w.poll_room()
    return emitted


@pytest.mark.parametrize("event,reason,content", [
    ("leave", "left", "戴爾 離開了聊天室"),
    ("kick", "kicked", "guest 已被管理員移出聊天室"),
    ("idle_removed", "idle_removed", "除錯Novia 因閒置逾時被移出聊天室"),
])
def test_every_kind_of_departure_is_pushed(monkeypatch, event, reason, content):
    """三種離場都要推。少推任何一種，名單就會在那個情境下悄悄過期。"""
    events = _run(monkeypatch, [_system(1, event, content)])

    left = [e for e in events if e["event"] == "member_left"]
    assert len(left) == 1
    assert left[0]["reason"] == reason
    assert left[0]["who"] == content.split(" ")[0]


def test_join_and_leave_are_symmetric(monkeypatch):
    """進出成對——這正是名單不會過期的條件。"""
    events = _run(monkeypatch, [
        {"seq": 1, "kind": "system", "system_event": "join",
         "sender_id": "x", "sender_name": "米勒", "content": "米勒 加入了聊天室",
         "mentions": []},
        _system(2, "kick", "米勒 已被管理員移出聊天室"),
    ])

    assert [(e["event"], e["who"]) for e in events] == [
        ("member_joined", "米勒"),
        ("member_left", "米勒"),
    ]


def test_unrelated_system_events_are_not_departures(monkeypatch):
    """封存不是離場。把它算進去會讓 agent 以為有人走了。"""
    events = _run(monkeypatch, [
        _system(1, "archive", "聊天室已封存"),
        _system(2, "archive_pending", "聊天室即將封存"),
    ])

    assert [e for e in events if e["event"] == "member_left"] == []


def test_no_join_events_silences_both_directions(monkeypatch):
    """只關掉一邊會留下比完全不通知更糟的狀態——名單看起來在維護，
    實際上只增不減。"""
    events = _run(monkeypatch, [
        {"seq": 1, "kind": "system", "system_event": "join",
         "sender_id": "x", "sender_name": "米勒", "content": "米勒 加入了聊天室",
         "mentions": []},
        _system(2, "leave", "米勒 離開了聊天室"),
    ], join_events=False)

    assert events == []


class TestNameExtraction:
    """名字只靠「在最前面」這一個假設，不比對整句措辭。

    三句離場文案各不相同，逐句比對等於把中文文案變成契約——改一個字就
    無聲失效，而這種失效在 watcher 上完全看不出來（事件單純不再發出）。
    """

    def test_falls_back_to_leading_token(self):
        assert _who_left(None, "除錯Novia 因閒置逾時被移出聊天室") == "除錯Novia"

    def test_prefers_sender_name_when_hub_provides_one(self):
        """日後 Hub 若補上 sender_name，就不必再猜。"""
        assert _who_left("正式名稱", "別的 內容") == "正式名稱"

    def test_survives_reworded_messages(self):
        """措辭改了照樣取得到——這正是不比對整句的理由。"""
        assert _who_left(None, "米勒 已經走了喔") == "米勒"

    def test_content_without_space_is_returned_as_is(self):
        """取不出名字時回原字串，不回空的——空字串在事件裡看起來像 bug。"""
        assert _who_left(None, "無法解析") == "無法解析"


class TestFirstPollSuppression:
    """掛上後的第一輪不發進出事件——那些是歷史，不是現在發生的事。

    進出與 mention 的補發語意不同：
    - mention 是**待辦**，十分鐘前 @ 你的人現在還在等回覆，補發是對的
    - 進出是**狀態轉變**，補發等於宣告一件當下沒有發生的事，而且那些人
      可能早就回來了；名單非但沒變準，還被推向錯誤方向

    沒有本機游標時（全新掛載）after_seq 從 0 起算，整個房間的歷史都會被
    當成新事件（2026-08-29 外部測試端實測：重掛 watcher 立刻收到自己
    幾十秒前、已經結束的離場）。
    """

    def test_history_is_not_replayed_on_attach(self, monkeypatch):
        events = _run(monkeypatch, [
            {"seq": 1, "kind": "system", "system_event": "join",
             "sender_id": "x", "sender_name": "米勒",
             "content": "米勒 加入了聊天室", "mentions": []},
            _system(2, "leave", "米勒 離開了聊天室"),
        ], first_poll=True)

        assert events == []

    def test_mentions_still_arrive_on_the_first_poll(self, monkeypatch):
        """抑制只針對進出。把 mention 一起吞掉會讓補發語意整個消失——
        那是這次修正絕不能誤傷的東西。"""
        events = _run(monkeypatch, [
            {"seq": 1, "kind": "chat", "system_event": None,
             "sender_id": "someone", "sender_name": "米勒",
             "content": "@我 看一下", "mentions": ["我"]},
        ], first_poll=True)

        assert [e["event"] for e in events] == ["message"]
        assert events[0]["mentioned"] is True

    def test_suppression_count_is_reported(self, monkeypatch):
        """靜靜吞掉的話，「沒有人進出」與「有進出但被我丟了」
        在事件流上長得一模一樣。"""
        logged: list[str] = []
        monkeypatch.setattr("chatroom_mcp.watch._log", logged.append)

        _run(monkeypatch, [
            _system(1, "leave", "甲 離開了聊天室"),
            _system(2, "kick", "乙 已被管理員移出聊天室"),
        ], first_poll=True)

        assert any("2" in line and "進出" in line for line in logged)

    def test_second_poll_emits_normally(self, monkeypatch):
        """抑制只有第一輪。之後的進出是真的正在發生。"""
        monkeypatch.setenv("CHATROOM_AGENT_KIND", "claude")
        monkeypatch.setenv("CHATROOM_SESSION_KEY", "claude-test")
        w = Watcher(_args())
        w.participant_id, w.display_name = "me", "我"
        emitted: list[dict] = []
        monkeypatch.setattr(w, "emit", emitted.append)

        # 第二輪的 seq 必須大於第一輪推進後的游標，否則會被「既有訊息的
        # 狀態變更不喚醒」那條規則濾掉，測到的就不是抑制邏輯
        rounds = [
            [_system(98, "leave", "歷史 離開了聊天室")],
            [_system(100, "leave", "現在 離開了聊天室")],
        ]
        seqs = [99, 100]
        monkeypatch.setattr(
            w.hub, "request",
            lambda *a, **k: {"messages": rounds.pop(0), "last_seq": seqs.pop(0),
                             "room_status": "active"},
        )
        w.poll_room()   # 第一輪：抑制
        w.poll_room()   # 第二輪：正常發出

        assert [e["who"] for e in emitted] == ["現在"]
