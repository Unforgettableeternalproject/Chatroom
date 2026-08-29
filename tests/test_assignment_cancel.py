"""指派方收回一筆還沒被處理的指派。

與 resolve 是相反方向：resolve 是被指派方回應，cancel 是指派方反悔。
兩者都只對 pending 生效，而且狀態必須分得開——事後看紀錄時，「他不想做」
與「我不需要了」不是同一件事。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _room_with_assignment(client, target="claude-target"):
    r = await client.post("/api/rooms",
                          json={"name": "房", "topic": "", "session_key": "owner-key"})
    room_id = r.json()["id"]
    r = await client.post(
        f"/api/rooms/{room_id}/assignments",
        json={"target_session_key": target, "note": "來做事"},
    )
    assert r.status_code == 200, r.text
    return room_id, r.json()["id"]


@pytest.mark.asyncio
async def test_cancel_pending_removes_it_from_target_queue(tmp_path):
    app, client = await _make(tmp_path, "cancel")
    async with app.router.lifespan_context(app), client:
        room_id, aid = await _room_with_assignment(client)

        r = await client.get("/api/assignments", params={"session_key": "claude-target"})
        assert [a["id"] for a in r.json()["assignments"]] == [aid]

        r = await client.delete(f"/api/assignments/{aid}")
        assert r.status_code == 200

        # 收回後對方就不該再看到它——不然 watcher 還是會把人叫起來
        r = await client.get("/api/assignments", params={"session_key": "claude-target"})
        assert r.json()["assignments"] == []


@pytest.mark.asyncio
async def test_cancelled_status_is_distinct_from_declined(tmp_path):
    app, client = await _make(tmp_path, "distinct")
    async with app.router.lifespan_context(app), client:
        room_id, aid = await _room_with_assignment(client)
        await client.delete(f"/api/assignments/{aid}")

        r = await client.get(f"/api/rooms/{room_id}/assignments",
                             headers={"X-Session-Key": "owner-key"})
        row = next(a for a in r.json()["assignments"] if a["id"] == aid)
        assert row["status"] == "cancelled"
        assert row["resolved_at"] is not None


@pytest.mark.asyncio
async def test_cannot_cancel_an_already_accepted_assignment(tmp_path):
    """對方可能已經開工了，單方面撤掉只會讓兩邊認知不同。"""
    app, client = await _make(tmp_path, "accepted")
    async with app.router.lifespan_context(app), client:
        _, aid = await _room_with_assignment(client)
        await client.post(f"/api/assignments/{aid}/resolve", json={"status": "accepted"})

        r = await client.delete(f"/api/assignments/{aid}")
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "assignment_not_found"


@pytest.mark.asyncio
async def test_cancel_twice_is_not_silently_ok(tmp_path):
    """第二次應該報找不到，不然 UI 會以為又收回了一筆。"""
    app, client = await _make(tmp_path, "twice")
    async with app.router.lifespan_context(app), client:
        _, aid = await _room_with_assignment(client)
        assert (await client.delete(f"/api/assignments/{aid}")).status_code == 200
        assert (await client.delete(f"/api/assignments/{aid}")).status_code == 404


@pytest.mark.asyncio
async def test_cancel_unknown_assignment_is_404(tmp_path):
    app, client = await _make(tmp_path, "unknown")
    async with app.router.lifespan_context(app), client:
        r = await client.delete("/api/assignments/nope")
        assert r.status_code == 404
