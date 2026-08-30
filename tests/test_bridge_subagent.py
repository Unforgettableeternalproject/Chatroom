"""bridge 側的 subagent 身分：自報、派生 key、以及認不得時絕不退回父層。

這裡守的是 `docs/SUBAGENT-IDENTITY.md` §3 的那條線——bridge 是唯一知道
「這次呼叫是誰」的地方（Hub 分辨不出來），所以判錯的後果全都是靜默的。
"""

import pytest

from chatroom_mcp import server
from chatroom_mcp.hub import HubError
from chatroom_mcp.state import BridgeState
from chatroom_mcp.subagents import derive_key

ROOM = "room-1"
PARENT_KEY = "claude-parent-session"


class FakeHub:
    """只記下請求並回罐頭答案。這裡要驗的是 bridge 怎麼組請求、怎麼記身分。"""

    def __init__(self):
        self.calls = []
        self.next_participant = "sub-participant-1"

    def request(self, method, path, *, participant_id=None, **kwargs):
        self.calls.append({"method": method, "path": path,
                           "participant_id": participant_id, **kwargs})
        if path.endswith("/join"):
            return {
                "participant_id": self.next_participant,
                "display_name": kwargs["json"].get("preferred_name") or "無名",
                "session_key": kwargs["json"]["session_key"],
                "parent_name": "Novia",
                "identity_scope": "subagent",
            }
        if path.endswith("/messages"):
            return {"id": "m1", "seq": 7, "mentions": []}
        if path.endswith("/leave"):
            return {"ok": True}
        return {}


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "SESSION_KEY", PARENT_KEY)
    st = BridgeState(tmp_path / "state.json")
    st.set_identity(ROOM, participant_id="parent-p", display_name="Novia",
                    session_key=PARENT_KEY)
    fake = FakeHub()
    server.configure(bridge_state=st, hub_client=fake)
    server._subagents = type(server._subagents)()
    yield fake
    server.configure(bridge_state=None, hub_client=None)


def test_derived_key_carries_a_random_segment(bridge):
    """同名平行派遣必須算出不同的 key，否則第二個根本進不了房。"""
    a = derive_key(PARENT_KEY, "tester")
    b = derive_key(PARENT_KEY, "tester")
    assert a != b
    assert a.startswith(f"{PARENT_KEY}#tester-")
    assert b.startswith(f"{PARENT_KEY}#tester-")


def test_spawn_declares_parentage_and_returns_a_handle(bridge):
    out = server.chatroom_spawn_subagent(ROOM, "米勒")
    assert out["ok"] is True
    assert out["handle"].startswith("sub-")

    sent = bridge.calls[-1]["json"]
    assert sent["parent_participant_id"] == "parent-p"
    assert sent["session_key"].startswith(f"{PARENT_KEY}#")


def test_spawn_before_joining_refuses(bridge, tmp_path):
    """父層自己不在房裡就沒有可依附的對象——這裡擋掉比讓 Hub 404 清楚。"""
    empty = BridgeState(tmp_path / "empty.json")
    server.configure(bridge_state=empty)
    out = server.chatroom_spawn_subagent(ROOM, "米勒")
    assert out["ok"] is False
    assert "chatroom_join" in out["reason"]


def test_post_as_subagent_uses_the_subagent_identity(bridge):
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_post(ROOM, "我是子代理", subagent=handle)

    assert out["identity_scope"] == "subagent"
    assert out["subagent_name"] == "米勒"
    assert bridge.calls[-1]["participant_id"] == "sub-participant-1"


def test_post_without_handle_stays_parent_and_says_so(bridge):
    """未自報＝以父層身分執行，而且**說出來**。

    沉默的話，「漏帶 handle」與「舊版沒這功能」在結果上完全同形。
    """
    out = server.chatroom_post(ROOM, "一般發言")
    assert out["identity_scope"] == "parent"
    assert "subagent_name" not in out
    assert bridge.calls[-1]["participant_id"] == "parent-p"


def test_unknown_handle_errors_and_sends_nothing(bridge):
    """認不得的 handle 絕不退回父層——那會讓子代理以為自己說了話。"""
    before = len(bridge.calls)
    out = server.chatroom_post(ROOM, "誰在說話", subagent="sub-does-not-exist")

    assert out["ok"] is False
    assert "chatroom_spawn_subagent" in out["reason"]
    # 錨點：真的沒有發出去，不是悄悄以父層名義發了
    assert len(bridge.calls) == before


def test_handle_from_another_room_is_refused(bridge):
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_post("room-2", "跨房發言", subagent=handle)
    assert out["ok"] is False
    assert "另一個房間" in out["reason"]


def test_ending_a_subagent_drops_the_handle(bridge):
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]
    out = server.chatroom_end_subagent(ROOM, handle)
    assert out["ended"] == "米勒"
    assert bridge.calls[-1]["participant_id"] == "sub-participant-1"

    # 收掉之後就不該再認得它
    again = server.chatroom_post(ROOM, "還在嗎", subagent=handle)
    assert again["ok"] is False


def test_subagent_failure_does_not_clear_the_parent_identity(bridge):
    """一個 subagent 的身分失效，不該連累整個 session。"""
    handle = server.chatroom_spawn_subagent(ROOM, "米勒")["handle"]

    def boom(method, path, *, participant_id=None, **kwargs):
        raise HubError("身分已失效", identity_invalid=True)

    bridge.request = boom
    out = server.chatroom_post(ROOM, "掛了", subagent=handle)
    assert out["ok"] is False
    # 父層在 state 檔裡的身分必須原封不動
    assert server.state().participant_id(ROOM) == "parent-p"
