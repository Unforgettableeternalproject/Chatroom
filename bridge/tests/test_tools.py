"""P2-01 ~ P2-03：MCP 工具層的行為（全部以 MockTransport 模擬 Hub）。"""

import httpx

from chatroom_mcp import server as srv
from chatroom_mcp.state import BridgeState

ROOM = "room-1"


def _join(fake_hub, pid="pid-1", name="Aster"):
    fake_hub.json(
        "POST",
        f"/api/rooms/{ROOM}/join",
        {"participant_id": pid, "display_name": name, "rejoined": False},
    )
    return srv.chatroom_join(ROOM)


# ---------- 成功路徑與結構化回傳 ----------


def test_join_stores_identity(fake_hub):
    result = _join(fake_hub)
    assert result["ok"] is True
    assert result["display_name"] == "Aster"
    assert srv.state().participant_id(ROOM) == "pid-1"


def test_join_sends_session_key_and_kind(fake_hub):
    _join(fake_hub)
    body = fake_hub.calls[-1].read().decode()
    assert srv.SESSION_KEY in body
    assert '"role": "agent"' in body or '"role":"agent"' in body


def test_join_with_assignment_uses_hub_canonical_codex_thread(fake_hub):
    """bridge 不必知道 thread id；assignment_id 由 Hub 兌換並回傳正式身分。"""
    import json as _json

    thread_id = "019d0000-0000-7000-8000-000000000001"
    fake_hub.json(
        "POST",
        f"/api/rooms/{ROOM}/join",
        {
            "participant_id": "pid-thread",
            "display_name": "Codex-Sol",
            "rejoined": False,
            "session_key": thread_id,
        },
    )
    result = srv.chatroom_join(ROOM, assignment_id="assignment-1")
    assert result["ok"] is True
    body = _json.loads(fake_hub.calls[-1].content)
    assert body["assignment_id"] == "assignment-1"
    assert body["session_key"] == srv.SESSION_KEY
    assert srv.state().session_key(ROOM) == thread_id

    # 同一 bridge 後續重加不必再帶 assignment_id，也會沿用 canonical thread。
    srv.chatroom_join(ROOM)
    body = _json.loads(fake_hub.calls[-1].content)
    assert body["session_key"] == thread_id


def test_post_uses_stored_participant_header(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", f"/api/rooms/{ROOM}/messages", {"id": "m1", "seq": 3})
    result = srv.chatroom_post(ROOM, "你好")
    # 不用精確相等：`identity_scope` 之類的觀測欄位是刻意一律附上的
    # （見 `_identity_for`），而精確相等會讓每次新增這種欄位都變成假性失敗
    assert result["ok"] is True
    assert (result["id"], result["seq"]) == ("m1", 3)
    assert result["identity_scope"] == "parent"
    assert fake_hub.calls[-1].headers["X-Participant-Id"] == "pid-1"


def test_leave_clears_identity(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", f"/api/rooms/{ROOM}/leave", {"ok": True})
    assert srv.chatroom_leave(ROOM)["ok"] is True
    assert srv.state().participant_id(ROOM) is None


def test_heartbeat_requires_identity_first(fake_hub):
    result = srv.chatroom_heartbeat(ROOM)
    assert result["ok"] is False
    assert result["need_rejoin"] is True
    assert "chatroom_join" in result["reason"]
    # 沒有身分時根本不該打 Hub
    assert fake_hub.calls == []


def test_heartbeat_success(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", f"/api/rooms/{ROOM}/heartbeat", {"ok": True})
    assert srv.chatroom_heartbeat(ROOM)["ok"] is True


def test_pin_and_unpin(fake_hub):
    _join(fake_hub)
    fake_hub.json("POST", "/api/messages/m1/pin", {"ok": True})
    fake_hub.json("DELETE", "/api/messages/m1/pin", {"ok": True})
    assert srv.chatroom_pin(ROOM, "m1")["ok"] is True
    assert srv.chatroom_unpin(ROOM, "m1")["ok"] is True


# ---------- P2-01 指派工具 ----------


def test_assignments_lists_pending(fake_hub):
    fake_hub.json(
        "GET",
        "/api/assignments",
        {"assignments": [{"id": "a1", "room_id": ROOM, "room_name": "設計討論",
                          "note": "來看一下架構"}]},
    )
    result = srv.chatroom_assignments()
    assert result["ok"] is True
    assert result["assignments"][0]["room_name"] == "設計討論"
    assert fake_hub.calls[-1].url.params["session_key"] == srv.SESSION_KEY
    # key 是動態的，agent 得能告訴使用者「指派給哪一把 key」
    assert result["your_session_key"] == srv.SESSION_KEY


def test_resolve_assignment_accept_and_decline(fake_hub):
    seen = []

    def handler(request):
        seen.append(request.read().decode())
        return httpx.Response(200, json={"ok": True})

    fake_hub.on("POST", "/api/assignments/a1/resolve", handler)
    assert srv.chatroom_resolve_assignment("a1", True)["ok"] is True
    assert srv.chatroom_resolve_assignment("a1", False)["ok"] is True
    assert "accepted" in seen[0]
    assert "declined" in seen[1]


def test_resolve_assignment_already_handled(fake_hub):
    fake_hub.error(
        "POST", "/api/assignments/a1/resolve", 404,
        "assignment not found or already resolved",
    )
    result = srv.chatroom_resolve_assignment("a1", True)
    assert result["ok"] is False
    assert "找不到這筆指派" in result["reason"]


def test_list_rooms_enriches_pending_assignments(fake_hub):
    fake_hub.json(
        "GET", "/api/rooms",
        {"rooms": [{"id": ROOM, "name": "設計討論"}],
         "pending_assignments": [{"id": "a1", "room_id": ROOM}]},
    )
    fake_hub.json(
        "GET", "/api/assignments",
        {"assignments": [{"id": "a1", "room_id": ROOM, "room_name": "設計討論",
                          "room_topic": "架構", "note": "來看一下"}]},
    )
    _join(fake_hub)
    result = srv.chatroom_list_rooms()
    pending = result["pending_assignments"][0]
    # /api/rooms 的精簡版沒有房名，改用 /api/assignments 的完整版
    assert pending["room_name"] == "設計討論"
    assert pending["note"] == "來看一下"
    assert result["rooms"][0]["you_joined_as"] == "Aster"


def test_list_rooms_survives_assignment_endpoint_failure(fake_hub):
    fake_hub.json(
        "GET", "/api/rooms",
        {"rooms": [], "pending_assignments": [{"id": "a1", "room_id": ROOM}]},
    )
    fake_hub.error("GET", "/api/assignments", 500, "boom")
    result = srv.chatroom_list_rooms()
    assert result["ok"] is True
    assert result["pending_assignments"][0]["id"] == "a1"


# ---------- P2-02 錯誤情境 ----------


def test_post_to_archived_room(fake_hub):
    _join(fake_hub)
    fake_hub.error("POST", f"/api/rooms/{ROOM}/messages", 409, "room is archived")
    result = srv.chatroom_post(ROOM, "還在嗎")
    assert result["ok"] is False
    assert "封存" in result["reason"]
    assert "need_rejoin" not in result
    # 封存不代表身分失效，不該被清掉
    assert srv.state().participant_id(ROOM) == "pid-1"


def test_bad_token_message(fake_hub):
    fake_hub.error("GET", "/api/rooms", 401, "invalid token")
    result = srv.chatroom_list_rooms()
    assert result["ok"] is False
    assert "CHATROOM_TOKEN" in result["reason"]


def test_hub_offline_message(fake_hub):
    def boom(request):
        raise httpx.ConnectError("refused", request=request)

    fake_hub.on("GET", "/api/rooms", boom)
    result = srv.chatroom_list_rooms()
    assert result["ok"] is False
    assert "無法連線到 Chatroom Hub" in result["reason"]


# ---------- P2-03 身分續存與游標 ----------


def test_identity_survives_bridge_restart(tmp_path, fake_hub):
    """重啟 bridge（換一個 BridgeState 實例讀同一個檔）後仍能直接發言。"""
    path = tmp_path / "persist.json"
    srv.configure(bridge_state=BridgeState(path))
    _join(fake_hub)

    srv.configure(bridge_state=BridgeState(path))  # 模擬重啟
    fake_hub.json("POST", f"/api/rooms/{ROOM}/messages", {"id": "m1", "seq": 1})
    result = srv.chatroom_post(ROOM, "重啟後直接發言")
    assert result["ok"] is True
    assert fake_hub.calls[-1].headers["X-Participant-Id"] == "pid-1"


def test_stale_identity_is_detected_and_cleared(fake_hub):
    _join(fake_hub)
    fake_hub.error("POST", f"/api/rooms/{ROOM}/messages", 403, "participant not active")
    result = srv.chatroom_post(ROOM, "我還在")
    assert result["ok"] is False
    assert result["need_rejoin"] is True
    assert "chatroom_join" in result["reason"]
    assert srv.state().participant_id(ROOM) is None


def test_read_without_after_seq_advances_cursor(fake_hub):
    pages = [
        {"messages": [{"seq": 1, "content": "a"}, {"seq": 2, "content": "b"}]},
        {"messages": [{"seq": 3, "content": "c"}]},
        {"messages": []},
    ]
    seen_after = []

    def handler(request):
        seen_after.append(int(request.url.params["after_seq"]))
        return httpx.Response(200, json=pages[len(seen_after) - 1])

    fake_hub.on("GET", f"/api/rooms/{ROOM}/messages", handler)

    first = srv.chatroom_read(ROOM)
    second = srv.chatroom_read(ROOM)
    third = srv.chatroom_read(ROOM)

    assert seen_after == [0, 2, 3]  # 不重複也不遺漏
    assert first["next_after_seq"] == 2
    assert second["next_after_seq"] == 3
    assert third["messages"] == []
    assert srv.state().last_seq(ROOM) == 3


def test_explicit_after_seq_can_reread_without_rewinding_cursor(fake_hub):
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/messages",
        {"messages": [{"seq": 1}, {"seq": 2}, {"seq": 3}]},
    )
    srv.chatroom_read(ROOM)
    assert srv.state().last_seq(ROOM) == 3
    again = srv.chatroom_read(ROOM, after_seq=0)
    assert len(again["messages"]) == 3
    assert srv.state().last_seq(ROOM) == 3  # 重讀歷史不把游標倒退


def test_pinned_only_does_not_advance_cursor(fake_hub):
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/messages", {"messages": [{"seq": 9, "pinned": True}]}
    )
    result = srv.chatroom_read(ROOM, pinned_only=True)
    assert result["ok"] is True
    # 只讀釘選就推進游標會讓中間未釘選的訊息永遠讀不到
    assert srv.state().last_seq(ROOM) == 0


def test_session_key_ephemeral_per_process_and_env_override(monkeypatch):
    """未顯式設定時每次生成都不同——多開 session 不得共用身分（join 冪等會合併）。"""
    monkeypatch.delenv("CHATROOM_SESSION_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    k1, k2 = srv._session_key(), srv._session_key()
    assert k1 != k2
    assert k1.startswith(srv.AGENT_KIND + "-")
    monkeypatch.setenv("CHATROOM_SESSION_KEY", "codex-main")
    assert srv._session_key() == "codex-main"


def test_session_key_prefers_claude_session_id(monkeypatch):
    """kind=claude 時採用 Claude Code 的 session id——resume 延續、新 session 新身分。"""
    monkeypatch.delenv("CHATROOM_SESSION_KEY", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "abc-123")
    monkeypatch.setattr(srv, "AGENT_KIND", "claude")
    assert srv._session_key() == "claude-abc-123"
    # 同一 session 內重算必須穩定（不是每次呼叫換一把）
    assert srv._session_key() == srv._session_key()
    # 顯式 CHATROOM_SESSION_KEY 仍優先於平台 session id
    monkeypatch.setenv("CHATROOM_SESSION_KEY", "novia-fixed")
    assert srv._session_key() == "novia-fixed"


def test_session_key_ignores_claude_session_id_for_other_kinds(monkeypatch):
    """Codex 從 Claude session 的 shell 拉起會繼承 CLAUDE_CODE_SESSION_ID，
    採用它會與母 session 的 bridge 撞 key——非 claude kind 一律忽略。"""
    monkeypatch.delenv("CHATROOM_SESSION_KEY", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "abc-123")
    monkeypatch.setattr(srv, "AGENT_KIND", "codex")
    key = srv._session_key()
    assert "abc-123" not in key
    assert key.startswith("codex-")


def test_join_uses_default_name_when_no_preference(fake_hub, monkeypatch):
    """CHATROOM_DEFAULT_NAME 讓每個 session 以同一代稱進房，由 Hub 自動編號。"""
    import json as _json

    monkeypatch.setattr(srv, "DEFAULT_NAME", "Novia")
    fake_hub.json(
        "POST", f"/api/rooms/{ROOM}/join",
        {"participant_id": "p1", "display_name": "Novia-2", "rejoined": False},
    )
    result = srv.chatroom_join(ROOM)
    assert result["ok"] is True and result["display_name"] == "Novia-2"
    body = _json.loads(fake_hub.calls[-1].content)
    assert body["preferred_name"] == "Novia"
    # 明確給 preferred_name 時優先於預設代稱
    srv.chatroom_join(ROOM, preferred_name="Echo")
    body = _json.loads(fake_hub.calls[-1].content)
    assert body["preferred_name"] == "Echo"


def test_pinned_only_reads_whole_room_not_from_cursor(fake_hub):
    """P2-05 實測抓到的 bug：游標推進後，比游標舊的釘選要仍然看得到。"""
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/messages", {"messages": [{"seq": 2, "pinned": True}]}
    )
    srv.state().set_last_seq(ROOM, 9)  # 游標已在釘選訊息之後
    result = srv.chatroom_read(ROOM, pinned_only=True)
    assert result["ok"] is True
    assert result["after_seq"] == 0  # 釘選牆從頭掃整個房間
    assert srv.state().last_seq(ROOM) == 9  # 且不動游標


def test_wait_advances_cursor_from_last_seq(fake_hub):
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [{"seq": 5, "content": "hi"}], "you_were_mentioned": True,
         "last_seq": 5},
    )
    result = srv.chatroom_wait(ROOM)
    assert result["you_were_mentioned"] is True
    assert srv.state().last_seq(ROOM) == 5
    assert result["next_after_seq"] == 5


def test_wait_timeout_returns_empty_without_error(fake_hub):
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": [], "you_were_mentioned": False, "last_seq": 0},
    )
    result = srv.chatroom_wait(ROOM, timeout=1.0)
    assert result["ok"] is True
    assert result["messages"] == []


def test_read_works_without_identity(fake_hub):
    """讀取不需要身分——未 join 的房間也該讀得到（Hub 端亦如此）。"""
    fake_hub.json("GET", f"/api/rooms/{ROOM}/messages", {"messages": []})
    assert srv.chatroom_read(ROOM)["ok"] is True


# ---------- 工具註冊 ----------


def test_all_tools_registered_with_chinese_docstrings():
    expected = {
        "chatroom_list_rooms", "chatroom_join", "chatroom_leave", "chatroom_read",
        "chatroom_post", "chatroom_wait", "chatroom_pin", "chatroom_unpin",
        "chatroom_heartbeat", "chatroom_assignments", "chatroom_resolve_assignment",
    }
    for name in expected:
        fn = getattr(srv, name)
        assert fn.__doc__, f"{name} 缺少 docstring"
        assert any("一" <= ch <= "鿿" for ch in fn.__doc__), (
            f"{name} 的 docstring 不是繁體中文"
        )
