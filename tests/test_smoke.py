"""Phase 0 冒煙測試：房間生命週期、唯一命名、訊息流、釘選、指派。"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def client(tmp_path):
    cfg = Config(db_path=str(tmp_path / "test.db"), api_token="")
    app = create_app(cfg)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        async with app.router.lifespan_context(app):
            yield c


async def _join(client, room_id, session_key, name=None, kind="claude"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_room_and_message_flow(client):
    r = await client.post("/api/rooms", json={"name": "測試房", "topic": "煙霧測試"})
    room_id = r.json()["id"]

    a = await _join(client, room_id, "sess-a", "Nova")
    b = await _join(client, room_id, "sess-b", "Nova")  # 重名 → 自動後綴
    assert a["display_name"] == "Nova"
    assert b["display_name"] == "Nova-2"

    # 發訊息 + ping
    r = await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": "哈囉 @Nova-2", "mentions": ["Nova-2"]},
        headers={"X-Participant-Id": a["participant_id"]},
    )
    assert r.status_code == 200
    seq = r.json()["seq"]

    # B 讀增量：應看到 join 系統訊息 x2 + 這則 chat
    r = await client.get(f"/api/rooms/{room_id}/messages", params={"after_seq": 0},
                         headers={"X-Participant-Id": b["participant_id"]})
    msgs = r.json()["messages"]
    assert [m["kind"] for m in msgs] == ["system", "system", "chat"]
    assert msgs[-1]["sender_name"] == "Nova"

    # B 的 long-poll 立即返回且標記被 ping
    r = await client.get(
        f"/api/rooms/{room_id}/updates",
        params={"after_seq": seq - 1, "timeout": 1},
        headers={"X-Participant-Id": b["participant_id"]},
    )
    data = r.json()
    assert data["you_were_mentioned"] is True
    assert data["last_seq"] == seq


async def test_rejoin_is_idempotent(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    a1 = await _join(client, room_id, "sess-x", "Echo")
    a2 = await _join(client, room_id, "sess-x", "Echo")
    assert a2["rejoined"] is True
    assert a2["participant_id"] == a1["participant_id"]


async def test_pin_and_delete(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    a = await _join(client, room_id, "sess-a")
    pid = a["participant_id"]
    r = await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": "重要決策"},
        headers={"X-Participant-Id": pid},
    )
    mid = r.json()["id"]

    r = await client.post(f"/api/messages/{mid}/pin", headers={"X-Participant-Id": pid})
    assert r.status_code == 200
    r = await client.get(
        f"/api/rooms/{room_id}/messages", params={"pinned_only": True},
        headers={"X-Participant-Id": pid},
    )
    assert [m["id"] for m in r.json()["messages"]] == [mid]

    # 軟刪除後內容清空但保留占位
    r = await client.delete(f"/api/messages/{mid}",
                            headers={"X-Participant-Id": pid})
    assert r.status_code == 200
    r = await client.get(f"/api/rooms/{room_id}/messages",
                         headers={"X-Participant-Id": pid})
    deleted = [m for m in r.json()["messages"] if m["id"] == mid][0]
    assert deleted["deleted"] is True and deleted["content"] == ""


async def test_assignment_flow(client):
    r = await client.post("/api/rooms", json={"name": "任務房", "topic": "T"})
    room_id = r.json()["id"]
    r = await client.post(
        f"/api/rooms/{room_id}/assignments",
        json={"target_session_key": "sess-codex", "note": "請來討論 API 設計"},
    )
    assert r.status_code == 200

    r = await client.get("/api/assignments", params={"session_key": "sess-codex"})
    assignments = r.json()["assignments"]
    assert len(assignments) == 1 and assignments[0]["room_name"] == "任務房"

    # 目標 session 加入後，指派自動變 accepted
    await _join(client, room_id, "sess-codex", kind="codex")
    r = await client.get("/api/assignments", params={"session_key": "sess-codex"})
    assert r.json()["assignments"] == []


async def test_leave_posts_system_message(client):
    r = await client.post("/api/rooms", json={"name": "房"})
    room_id = r.json()["id"]
    a = await _join(client, room_id, "sess-a", "Quill")
    r = await client.post(
        f"/api/rooms/{room_id}/leave",
        headers={"X-Participant-Id": a["participant_id"]},
    )
    assert r.status_code == 200
    # 離開之後仍讀得到歷史——離開不是銷毀自己的紀錄
    r = await client.get(f"/api/rooms/{room_id}/messages",
                         headers={"X-Participant-Id": a["participant_id"]})
    assert "Quill 離開了聊天室" in r.json()["messages"][-1]["content"]
