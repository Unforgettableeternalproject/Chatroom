"""chatroom_react：對人類訊息按表情（選擇性，不喚醒任何人）。"""

import urllib.parse

from chatroom_mcp import server as srv

ROOM = "room-1"
EYES = "\U0001F440"
ALLOWED = ["\U0001F44D", "\u2764\ufe0f", "\U0001F440", "\u2705"]


def _join(fake_hub):
    fake_hub.json("POST", f"/api/rooms/{ROOM}/join",
                  {"participant_id": "pid-1", "display_name": "Aster",
                   "rejoined": False})
    srv.chatroom_join(ROOM)


def _path(mid, emoji):
    # httpx 的 url.path 是解碼後的
    return f"/api/messages/{mid}/reactions/{emoji}"


def test_react_puts_encoded_emoji_with_identity(fake_hub):
    _join(fake_hub)
    fake_hub.json("PUT", _path("m1", EYES),
                  {"ok": True, "changed": True, "reactions": []})
    r = srv.chatroom_react(ROOM, "m1", EYES)
    assert r["ok"] is True and r["identity_scope"] == "parent"
    call = fake_hub.calls[-1]
    assert call.method == "PUT"
    assert urllib.parse.quote(EYES, safe="") in str(call.url)
    assert call.headers["X-Participant-Id"] == "pid-1"


def test_react_remove_uses_delete(fake_hub):
    _join(fake_hub)
    fake_hub.json("DELETE", _path("m1", EYES),
                  {"ok": True, "changed": True, "reactions": []})
    assert srv.chatroom_react(ROOM, "m1", EYES, remove=True)["ok"] is True
    assert fake_hub.calls[-1].method == "DELETE"


def test_react_outside_whitelist_lists_allowed(fake_hub):
    _join(fake_hub)
    fake_hub.error("PUT", _path("m1", "\U0001F4A9"), 400,
                   {"code": "invalid_reaction", "message": "不支援",
                    "allowed": ALLOWED})
    r = srv.chatroom_react(ROOM, "m1", "\U0001F4A9")
    assert r["ok"] is False and r["code"] == "invalid_reaction"
    assert r["allowed"] == ALLOWED
    assert all(e in r["reason"] for e in ALLOWED)


def test_react_to_agent_message_is_refused_clearly(fake_hub):
    _join(fake_hub)
    fake_hub.error("PUT", _path("m2", EYES), 403,
                   {"code": "reaction_human_message_only",
                    "message": "agent 只能對人類發的訊息按表情"})
    r = srv.chatroom_react(ROOM, "m2", EYES)
    assert r["ok"] is False and r["code"] == "reaction_human_message_only"


def test_react_with_unknown_subagent_never_falls_back_to_parent(fake_hub):
    _join(fake_hub)
    before = len(fake_hub.calls)
    r = srv.chatroom_react(ROOM, "m1", EYES, subagent="nope")
    assert r["ok"] is False
    assert len(fake_hub.calls) == before, "認不得的 handle 不能退回父層打到 Hub"


def test_read_does_not_ask_for_reactions(fake_hub):
    """chatroom_read 不請求表情彙總：agent 不需要知道別人的表情。"""
    _join(fake_hub)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/messages",
                  {"messages": [], "has_more": False})
    srv.chatroom_read(ROOM)
    assert "include_reactions" not in str(fake_hub.calls[-1].url)
