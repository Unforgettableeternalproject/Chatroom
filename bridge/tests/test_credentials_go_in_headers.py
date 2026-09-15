"""憑證的正典位置是 `X-Session-Key` 標頭——bridge 的送出面。

87ec8297：`session_key` 在這個專案裡曾經同時活在四個地方（header／query／
body／env）。Hub 側 `f2f9c1e` 之後四支端點都收標頭且**標頭優先**。

⚠️ **這一輪 bridge 是「兩者都送」，不是「只送標頭」**（決策 seq 169）。
那個差別不是保守，是它讓 **kit 與 Hub 版本解耦**：

- 新 Hub（≥ `f2f9c1e`）：標頭優先，舊位置被忽略
- 舊 Hub（正式站換版前跑的那些）：只讀得到舊位置

只送標頭的話，裝了新 kit 又還沒換 Hub 的人會當場 422 `session_key_required`
——而症狀看起來像憑證或身分壞掉，不像版本錯配。真正的拔收斂到下一個 kit
週期（那時所有 Hub 都齊了，與其他舊名一次拔乾淨）。

所以這組測試釘的是兩件事：**標頭一定要在**（那是新契約，漏送不會有症狀，
因為舊位置會頂上），以及**舊位置這一輪刻意還在**（下一輪要拔的時候，是這
幾條測試轉紅來提醒「該回來看這裡了」）。

三個**不在**管轄範圍的例外（各有理由，別順手「修正」）：

1. `/ws` 的 `?token=` —— WebSocket 握手送不了自訂標頭，協定層限制，決策裁
   為**永久例外**，不是技術債
2. `board/supervisor` body 的 `session_key` —— 那是**指派目標**不是憑證
3. `_presence_params` 的 `kind` / `label` / `host` —— 向 session 名錄自報的
   資訊，不是憑證
"""

from __future__ import annotations

import json as jsonlib

import httpx

from chatroom_mcp import server as srv

KEY = "test-session"


def _sent(fake_hub, method: str, path: str) -> httpx.Request:
    for req in fake_hub.calls:
        if req.method == method and req.url.path == path:
            return req
    raise AssertionError(
        f"沒有送出 {method} {path}；實際送出："
        f"{[(c.method, c.url.path) for c in fake_hub.calls]}"
    )


def _body(req: httpx.Request) -> dict:
    if not req.content:
        return {}
    try:
        return jsonlib.loads(req.content)
    except ValueError:
        return {}


def _assert_header_is_canonical(req: httpx.Request, key: str = KEY) -> None:
    assert req.headers.get("X-Session-Key") == key, (
        f"{req.method} {req.url.path} 沒有把 session_key 放進標頭——"
        "漏送不會有症狀，舊位置會頂上")


def test_list_rooms_puts_the_key_in_the_header(fake_hub):
    fake_hub.json("GET", "/api/rooms", {"rooms": []})
    srv.chatroom_list_rooms()
    _assert_header_is_canonical(_sent(fake_hub, "GET", "/api/rooms"))


def test_self_reported_presence_fields_stay_in_the_query(fake_hub):
    """名錄用的 kind／host 不是憑證，不跟著搬。

    一起拔掉的話 session 名錄會少掉這個 session 的種類與主機，而指派 UI
    的掃描清單就是靠它們認人——那是另一個功能，不是這張卡的範圍。
    """
    fake_hub.json("GET", "/api/rooms", {"rooms": []})
    srv.chatroom_list_rooms()
    params = _sent(fake_hub, "GET", "/api/rooms").url.params
    assert params.get("kind") == "claude"
    assert "host" in params


def test_assignments_puts_the_key_in_the_header(fake_hub):
    fake_hub.json("GET", "/api/assignments", {"assignments": []})
    srv.chatroom_assignments()
    _assert_header_is_canonical(_sent(fake_hub, "GET", "/api/assignments"))


def test_join_puts_the_key_in_the_header(fake_hub):
    fake_hub.json("POST", "/api/rooms/r1/join",
                  {"participant_id": "p1", "display_name": "N", "rejoined": False})
    srv.chatroom_join("r1")
    req = _sent(fake_hub, "POST", "/api/rooms/r1/join")
    _assert_header_is_canonical(req)
    assert _body(req)["role"] == "agent"


def test_spawn_subagent_sends_the_derived_key_in_the_header(fake_hub):
    """子代理送的是**它自己**那把 derived key，不是父層的。

    這處最容易在搬家時搬錯：標頭順手填成 `_my_session_key()` ⇒ 子代理以
    父層身分登記，而回應看起來完全正常。兩個位置送的必須是同一把。
    """
    fake_hub.json("POST", "/api/rooms/r1/join",
                  {"participant_id": "p1", "display_name": "N", "rejoined": False})
    srv.chatroom_join("r1")
    fake_hub.json("POST", "/api/rooms/r1/join",
                  {"participant_id": "p2", "display_name": "Sub", "rejoined": False})
    srv.chatroom_spawn_subagent("r1", "Sub")
    req = fake_hub.calls[-1]
    sent = req.headers.get("X-Session-Key")
    assert sent and sent != KEY, "子代理應該送自己那把 derived key"
    assert _body(req)["session_key"] == sent, "兩個位置送的不是同一把"


def test_the_old_positions_are_still_there_on_purpose(fake_hub):
    """相容退路仍在——**這一輪刻意的**。

    下一個 kit 週期要拔舊位置時，這條會轉紅。那是它存在的目的：提醒拔的
    人「這裡是刻意留的，不是漏改的」，順便標出所有要一起拔的地方。
    """
    fake_hub.json("GET", "/api/rooms", {"rooms": []})
    srv.chatroom_list_rooms()
    assert _sent(fake_hub, "GET", "/api/rooms").url.params.get("session_key") == KEY

    fake_hub.json("POST", "/api/rooms/r1/join",
                  {"participant_id": "p1", "display_name": "N", "rejoined": False})
    srv.chatroom_join("r1")
    assert _body(_sent(fake_hub, "POST", "/api/rooms/r1/join"))["session_key"] == KEY
