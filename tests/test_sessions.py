"""Session 名錄與指派命名：掃描列表、active/idle 判定、assigned_name 優先權。"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


def _make_client(tmp_path, **cfg_overrides):
    cfg = Config(db_path=str(tmp_path / "test.db"), api_token="", **cfg_overrides)
    app = create_app(cfg)
    transport = ASGITransport(app=app)
    return app, AsyncClient(transport=transport, base_url="http://test")


@pytest.fixture
async def client(tmp_path):
    app, c = _make_client(tmp_path)
    async with c:
        async with app.router.lifespan_context(app):
            yield c


async def _join(client, room_id, session_key, name=None, kind="claude"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


# ---------- session 名錄 ----------


async def test_assignment_poll_registers_session(client):
    """watcher 的指派輪詢是名錄心跳：帶 kind/label 就該入錄並顯示 active。"""
    r = await client.get(
        "/api/assignments",
        params={"session_key": "claude-abc", "kind": "claude", "label": "Novia"},
    )
    assert r.status_code == 200

    r = await client.get("/api/sessions")
    sessions = r.json()["sessions"]
    assert len(sessions) == 1
    s = sessions[0]
    assert s["session_key"] == "claude-abc"
    assert s["kind"] == "claude"
    assert s["label"] == "Novia"
    assert s["status"] == "active"
    assert s["rooms"] == []


async def test_touch_without_kind_keeps_existing(client):
    """舊版 bridge 不帶 kind/label 的輪詢，不得把已知資訊洗掉。"""
    await client.get(
        "/api/assignments",
        params={"session_key": "s1", "kind": "codex", "label": "Worker"},
    )
    await client.get("/api/assignments", params={"session_key": "s1"})

    r = await client.get("/api/sessions")
    s = r.json()["sessions"][0]
    assert s["kind"] == "codex"
    assert s["label"] == "Worker"


async def test_kind_inferred_from_key_prefix(client):
    """舊版 bridge 不自報 kind：identity.py 的 key 帶 kind 前綴，從前綴推斷。"""
    await client.get("/api/assignments", params={"session_key": "claude-abc123"})
    await client.get("/api/assignments", params={"session_key": "mystery-key"})

    r = await client.get("/api/sessions")
    kinds = {s["session_key"]: s["kind"] for s in r.json()["sessions"]}
    assert kinds["claude-abc123"] == "claude"
    assert kinds["mystery-key"] == "other"  # 前綴不認得就維持 other

    # 之後 caller 真的自報時照樣覆寫
    await client.get(
        "/api/assignments", params={"session_key": "mystery-key", "kind": "codex"}
    )
    r = await client.get("/api/sessions")
    kinds = {s["session_key"]: s["kind"] for s in r.json()["sessions"]}
    assert kinds["mystery-key"] == "codex"


async def test_join_registers_session_and_lists_room(client):
    r = await client.post("/api/rooms", json={"name": "作戰室"})
    room_id = r.json()["id"]
    await _join(client, room_id, "sess-a", "Nova")

    r = await client.get("/api/sessions")
    s = r.json()["sessions"][0]
    assert s["session_key"] == "sess-a"
    assert s["kind"] == "claude"
    assert s["rooms"] == [
        {"room_id": room_id, "room_name": "作戰室", "display_name": "Nova"}
    ]


async def test_left_session_shows_last_display_name(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    a = await _join(client, room_id, "sess-a", "Echo")
    await client.post(
        f"/api/rooms/{room_id}/leave",
        headers={"X-Participant-Id": a["participant_id"]},
    )

    r = await client.get("/api/sessions")
    s = r.json()["sessions"][0]
    assert s["rooms"] == []
    assert s["last_display_name"] == "Echo"


async def test_human_sessions_hidden_by_default(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human", "session_key": "device-1", "role": "human"},
    )
    await _join(client, room_id, "sess-a")

    r = await client.get("/api/sessions")
    keys = [s["session_key"] for s in r.json()["sessions"]]
    assert keys == ["sess-a"]

    r = await client.get("/api/sessions", params={"include_human": True})
    keys = {s["session_key"] for s in r.json()["sessions"]}
    assert keys == {"sess-a", "device-1"}


async def test_idle_and_ttl_windows(tmp_path):
    """active window 收到 0 → 一律 idle；ttl 收到 0 → 不再列出。"""
    app, c = _make_client(tmp_path, session_active_window=0.0)
    async with c:
        async with app.router.lifespan_context(app):
            await c.get("/api/assignments", params={"session_key": "s1"})
            r = await c.get("/api/sessions")
            assert r.json()["sessions"][0]["status"] == "idle"

    app, c = _make_client(tmp_path / "ttl", session_ttl=0.0)
    (tmp_path / "ttl").mkdir(exist_ok=True)
    async with c:
        async with app.router.lifespan_context(app):
            await c.get("/api/assignments", params={"session_key": "s1"})
            r = await c.get("/api/sessions")
            assert r.json()["sessions"] == []


# ---------- assigned_name 優先權 ----------


async def _assign(client, room_id, target, name="", note=""):
    r = await client.post(
        f"/api/rooms/{room_id}/assignments",
        json={"target_session_key": target, "note": note, "assigned_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def test_assigned_name_overrides_preferred(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    await _assign(client, room_id, "sess-a", name="鐵衛")

    # agent 自帶 preferred_name 也會被指派者的取名蓋掉
    joined = await _join(client, room_id, "sess-a", "SelfName")
    assert joined["display_name"] == "鐵衛"
    assert joined["name_from_assignment"] is True

    # 指派已在 join 時自動 accepted
    r = await client.get("/api/assignments", params={"session_key": "sess-a"})
    assert r.json()["assignments"] == []


async def test_assigned_name_absent_falls_back(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    await _assign(client, room_id, "sess-a")  # 沒取名

    joined = await _join(client, room_id, "sess-a", "SelfName")
    assert joined["display_name"] == "SelfName"
    assert "name_from_assignment" not in joined


async def test_assigned_name_conflict_gets_suffix(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    await _join(client, room_id, "sess-x", "鐵衛")
    await _assign(client, room_id, "sess-a", name="鐵衛")

    joined = await _join(client, room_id, "sess-a")
    assert joined["display_name"] == "鐵衛-2"


async def test_assigned_name_in_listings(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    await _assign(client, room_id, "sess-a", name="鐵衛", note="幫忙看測試")

    # session 視角（bridge / watcher 看到的）
    r = await client.get("/api/assignments", params={"session_key": "sess-a"})
    a = r.json()["assignments"][0]
    assert a["assigned_name"] == "鐵衛"

    # 房間視角（UI 列表）
    r = await client.get(f"/api/rooms/{room_id}/assignments")
    a = r.json()["assignments"][0]
    assert a["assigned_name"] == "鐵衛"


async def test_assignment_id_binds_bridge_join_to_codex_thread(client):
    """MCP 可帶臨時 key，但指派加入後 participant 必須使用 Codex thread id。"""
    r = await client.post("/api/rooms", json={"name": "多代理房"})
    room_id = r.json()["id"]
    thread_id = "019d0000-0000-7000-8000-000000000001"
    aid = await _assign(client, room_id, thread_id, name="鐵衛", note="請加入")

    joined = await client.post(
        f"/api/rooms/{room_id}/join",
        json={
            "kind": "codex",
            "session_key": "codex-ephemeral-bridge",
            "assignment_id": aid,
            "preferred_name": "BridgeName",
        },
    )
    assert joined.status_code == 200, joined.text
    body = joined.json()
    assert body["session_key"] == thread_id
    assert body["display_name"] == "鐵衛"
    assert body["name_from_assignment"] is True

    sessions = (await client.get("/api/sessions")).json()["sessions"]
    by_key = {s["session_key"]: s for s in sessions}
    assert thread_id in by_key
    assert "codex-ephemeral-bridge" not in by_key
    assert by_key[thread_id]["rooms"][0]["display_name"] == "鐵衛"


async def test_accepted_assignment_id_can_still_bind_join(client):
    """先 accept 再 join 是既有工具文件允許的流程，不能因 status 改變而斷線。"""
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    thread_id = "019d0000-0000-7000-8000-000000000002"
    aid = await _assign(client, room_id, thread_id)
    resolved = await client.post(
        f"/api/assignments/{aid}/resolve", json={"status": "accepted"}
    )
    assert resolved.status_code == 200

    joined = await client.post(
        f"/api/rooms/{room_id}/join",
        json={
            "kind": "codex",
            "session_key": "codex-temp",
            "assignment_id": aid,
        },
    )
    assert joined.status_code == 200, joined.text
    assert joined.json()["session_key"] == thread_id


async def test_assignment_id_cannot_be_used_for_another_room(client):
    first = (await client.post("/api/rooms", json={"name": "甲"})).json()["id"]
    second = (await client.post("/api/rooms", json={"name": "乙"})).json()["id"]
    aid = await _assign(client, first, "019d0000-0000-7000-8000-000000000003")

    joined = await client.post(
        f"/api/rooms/{second}/join",
        json={
            "kind": "codex",
            "session_key": "codex-temp",
            "assignment_id": aid,
        },
    )
    assert joined.status_code == 404
    assert joined.json()["detail"]["code"] == "assignment_not_joinable"


async def test_assignment_join_resolves_pending_when_session_already_in_room(client):
    """既有 participant 用指派 token 重加時，pending 不得留到 App 重啟後再通知。"""
    room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
    thread_id = "019d0000-0000-7000-8000-000000000004"
    await _join(client, room_id, thread_id, "Codex-Sol")
    aid = await _assign(client, room_id, thread_id)

    joined = await client.post(
        f"/api/rooms/{room_id}/join",
        json={
            "kind": "codex",
            "session_key": "codex-temp",
            "assignment_id": aid,
        },
    )
    assert joined.status_code == 200
    assert joined.json()["rejoined"] is True
    pending = (
        await client.get("/api/assignments", params={"session_key": thread_id})
    ).json()["assignments"]
    assert pending == []


async def test_session_records_source_ip_for_identification(client):
    """邀請 UI 靠來源位址認人——共用一把 token 時 Hub 眼中所有人長得一樣。"""
    await client.get(
        "/api/assignments",
        params={"session_key": "claude-a"},
        headers={"X-Forwarded-For": "192.168.1.42, 10.0.0.1"},
    )
    r = await client.get("/api/sessions")
    row = next(s for s in r.json()["sessions"] if s["session_key"] == "claude-a")
    # 取第一跳（最靠近使用者的那個），不是整串
    assert row["last_ip"] == "192.168.1.42"


async def test_cf_connecting_ip_wins_over_forwarded_for(client):
    """隧道後面 XFF 會被中間層一路接長，Cloudflare 自己那個標頭才是原始來源。"""
    await client.get(
        "/api/assignments",
        params={"session_key": "claude-b"},
        headers={
            "CF-Connecting-IP": "203.0.113.7",
            "X-Forwarded-For": "10.0.0.1",
        },
    )
    r = await client.get("/api/sessions")
    row = next(s for s in r.json()["sessions"] if s["session_key"] == "claude-b")
    assert row["last_ip"] == "203.0.113.7"


async def test_latest_source_wins(client):
    """同一個 session 換了網路（有線 → 無線、回家）時要跟著更新，
    顯示一個過期的位址比不顯示更糟——它看起來像是另一個人。"""
    for ip in ("192.168.1.9", "192.168.1.77"):
        await client.get(
            "/api/assignments",
            params={"session_key": "claude-c"},
            headers={"X-Forwarded-For": ip},
        )
    r = await client.get("/api/sessions")
    row = next(s for s in r.json()["sessions"] if s["session_key"] == "claude-c")
    assert row["last_ip"] == "192.168.1.77"
