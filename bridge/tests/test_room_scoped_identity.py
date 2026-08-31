"""房間邊界有兩半，而測試只守住了一半。

`tests/test_read_boundary.py` 把 `/api/rooms/{id}/questions` 列進受測路徑，
確認了 **Hub 會要求成員身分**。但那些測試全部直接打 Hub——沒有一條走 bridge。
於是「Hub 有沒有要求身分」被守住了，「bridge 有沒有帶上身分」沒有人守。

`chatroom_questions` 就掉進這個縫裡：它用裸的 `hub().request`，從不帶
`X-Participant-Id`，所以這條路徑**從來沒有成功過**。而失敗訊息說的是
「請先 chatroom_join」——把呼叫端導向一個永遠無效的處置（實測：join 成功、
`chatroom_read` 成功、`chatroom_questions` 照樣失敗，2026-08-31）。

代價不只是一個工具壞掉。chatroom skill 明文要求「發問前先看一眼 questions」，
而那條規則因此 100% 執行失敗——沒有人會知道，因為它看起來只是「我還沒 join」。

所以這裡守兩件事：這個工具真的帶了身分，以及**沒有下一個工具再掉進同一個縫**。
"""

import ast
from pathlib import Path

from chatroom_mcp import server as srv

ROOM = "room-1"

# join 是取得身分的動作，本來就不可能先有身分。除此之外，房間層級的路徑
# 一律要帶——這個清單要保持極短，每多一項就是多一個沒人守的縫
_IDENTITY_EXEMPT_SUFFIXES = ("/join",)


def _identify(bridge_state, participant_id="p-me"):
    bridge_state.set_identity(
        ROOM, participant_id=participant_id,
        display_name="Novia", session_key="test-session",
    )


def test_questions_carries_room_identity(fake_hub, bridge_state):
    """Hub 對這條路徑跑 `_member_or_403`，不帶身分就是必然的 403。"""
    _identify(bridge_state)
    fake_hub.json("GET", f"/api/rooms/{ROOM}/questions", {"questions": []})

    out = srv.chatroom_questions(ROOM)

    assert out["ok"] is True, out
    assert fake_hub.calls, "沒有任何請求送到 Hub"
    assert fake_hub.calls[-1].headers.get("X-Participant-Id") == "p-me"


def test_questions_without_identity_reports_need_rejoin(fake_hub, bridge_state):
    """沒有身分時要說得出「你還沒加入」，而不是讓 Hub 回一個 401 才發現。"""
    out = srv.chatroom_questions(ROOM)

    assert out["ok"] is False
    assert out.get("need_rejoin") is True


def _literal_path(node: ast.AST) -> str | None:
    """把字面字串或 f-string 還原成路徑樣板（插值處寫成 `{}`）。"""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        parts = []
        for value in node.values:
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                parts.append(value.value)
            elif isinstance(value, ast.FormattedValue):
                parts.append("{}")
            else:
                return None
        return "".join(parts)
    return None


def _is_bare_hub_request(node: ast.Call) -> bool:
    """是不是 `hub().request(...)`——也就是繞過 `_room_request` 的那條路。"""
    func = node.func
    return (
        isinstance(func, ast.Attribute)
        and func.attr == "request"
        and isinstance(func.value, ast.Call)
        and isinstance(func.value.func, ast.Name)
        and func.value.func.id == "hub"
    )


def test_no_room_scoped_call_bypasses_room_request():
    """守門：房間層級的路徑一律走 `_room_request`，它才會帶上身分。

    這條測試是為了 `chatroom_questions` 那次缺口寫的。單看每個工具都像對的
    ——真正的判準是「這條路徑屬不屬於某個房間」，而那要掃過全部呼叫點才看得出來。
    """
    tree = ast.parse(Path(srv.__file__).read_text(encoding="utf-8"))
    offenders = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not _is_bare_hub_request(node):
            continue
        for arg in node.args:
            path = _literal_path(arg)
            if (
                path
                and path.startswith("/api/rooms/{")
                and not path.endswith(_IDENTITY_EXEMPT_SUFFIXES)
            ):
                offenders.append(f"server.py:{node.lineno} → {path}")

    assert not offenders, (
        "這些呼叫走的是房間層級路徑卻沒經過 _room_request，"
        "不會帶上 X-Participant-Id，Hub 一律回 403：\n  "
        + "\n  ".join(offenders)
    )
