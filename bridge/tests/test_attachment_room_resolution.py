"""附件所在房間的推斷。

附件讀取要房內身分，而 agent 手上通常只有訊息裡的 attachment id。逼它自己
記住「那則訊息在哪個房」，是把 Hub 查得到的事推給呼叫端——所以 room_id
省略時 bridge 自己試。

這裡釘住三件事：給了就用（不多打）、沒給就試、全部失敗時錯誤訊息要說得出
「我試過哪些房」（不然「找不到附件」與「我不在那個房」長得一模一樣）。
"""

import pytest

from chatroom_mcp import server as srv
from chatroom_mcp.hub import HubError


class _FakeState:
    def __init__(self, rooms):
        self._rooms = rooms

    def rooms(self):
        return self._rooms

    def participant_id(self, room_id):
        return self._rooms.get(room_id, {}).get("participant_id")


@pytest.fixture
def calls(monkeypatch):
    """記下每次 _room_request 的 (room_id, path)。"""
    seen = []

    def fake(room_id, method, path, **kwargs):
        seen.append((room_id, path))
        if room_id == "room-b":
            return {"attachment": {"id": "att1", "filename": "a.png",
                                   "mime": "image/png", "is_image": True}}
        raise HubError("你不是這個聊天室的成員")

    monkeypatch.setattr(srv, "_room_request", fake)
    return seen


def _state(monkeypatch, rooms):
    monkeypatch.setattr(srv, "state", lambda: _FakeState(rooms))


def test_explicit_room_is_used_directly(calls, monkeypatch):
    _state(monkeypatch, {"room-a": {"participant_id": "pa"},
                         "room-b": {"participant_id": "pb"}})
    room_id, meta = srv._resolve_attachment_room("att1", "room-b")
    assert room_id == "room-b" and meta["filename"] == "a.png"
    # 指定了就只打一次——不該為了「確認」再掃一遍
    assert calls == [("room-b", "/api/attachments/att1/meta")]


def test_falls_back_to_trying_joined_rooms(calls, monkeypatch):
    _state(monkeypatch, {"room-a": {"participant_id": "pa"},
                         "room-b": {"participant_id": "pb"}})
    room_id, meta = srv._resolve_attachment_room("att1", "")
    assert room_id == "room-b" and meta["is_image"] is True
    # room-a 先被試、失敗，再試 room-b
    assert calls == [("room-a", "/api/attachments/att1/meta"),
                     ("room-b", "/api/attachments/att1/meta")]


def test_rooms_without_identity_are_skipped(calls, monkeypatch):
    """沒有身分的房本來就會被 Hub 擋，試了只是白打。"""
    _state(monkeypatch, {"room-a": {"participant_id": None},
                         "room-b": {"participant_id": "pb"}})
    room_id, _ = srv._resolve_attachment_room("att1", "")
    assert room_id == "room-b"
    assert calls == [("room-b", "/api/attachments/att1/meta")]


def test_no_identity_at_all_says_so(monkeypatch):
    _state(monkeypatch, {})
    with pytest.raises(HubError) as exc:
        srv._resolve_attachment_room("att1", "")
    assert exc.value.identity_invalid is True
    assert "chatroom_join" in str(exc.value)


def test_all_rooms_failing_reports_how_many_were_tried(calls, monkeypatch):
    """「找不到附件」與「我不在那個房」長得一模一樣——訊息要分得開。"""
    _state(monkeypatch, {"room-a": {"participant_id": "pa"},
                         "room-c": {"participant_id": "pc"}})
    with pytest.raises(HubError) as exc:
        srv._resolve_attachment_room("att1", "")
    assert "試過 2 個" in str(exc.value)
