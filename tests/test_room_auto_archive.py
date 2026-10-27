"""房間「自動封存」開關（room.auto_archive，預設開）。

守的是幾個安靜的失敗：

- 關掉之後 sweeper 還是倒數／封存：開關變成裝飾
- 關掉時沒清掉進行中的倒數：重新開啟的瞬間被當成「倒數已走完」立刻封存
- 舊庫升級後既有房被補成關閉：升級一次就停掉所有房的自動封存
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

TOKEN = "root-token"
OWNER = "owner-key"


async def _make(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=TOKEN, **cfg_kw)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {TOKEN}"})
    return app, client


async def _room(client, **extra):
    r = await client.post("/api/rooms", json={
        "name": "測試房", "session_key": OWNER, **extra})
    assert r.status_code == 200, r.text
    return r.json()


async def _agent_came_and_went(client, rid):
    """讓房間進入「曾有 agent、現在一個都不在」的可封存狀態。"""
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "claude", "session_key": f"agent-{rid}"})
    assert r.status_code == 200, r.text
    pid = r.json()["participant_id"]
    r = await client.post(f"/api/rooms/{rid}/leave",
                          headers={"X-Participant-Id": pid})
    assert r.status_code == 200, r.text


async def _row(app, rid):
    return await (await app.state.db.execute(
        "SELECT status, auto_archive, archive_pending_since FROM room"
        " WHERE id=?", (rid,))).fetchone()


async def _get_room(client, rid):
    r = await client.get(f"/api/rooms/{rid}", headers={"X-Session-Key": OWNER})
    assert r.status_code == 200, r.text
    return r.json()["room"]


async def _toggle(client, rid, enabled, key=OWNER):
    return await client.post(f"/api/rooms/{rid}/auto-archive",
                             json={"enabled": enabled},
                             headers={"X-Session-Key": key})


# ── API 讀寫與權限 ────────────────────────────────────────────────────

async def test_default_on_and_create_with_off(tmp_path):
    app, client = await _make(tmp_path, "default")
    async with client:
        async with app.router.lifespan_context(app):
            on = await _room(client)
            assert on["auto_archive"] is True
            assert (await _get_room(client, on["id"]))["auto_archive"] is True

            off = await _room(client, auto_archive=False)
            assert off["auto_archive"] is False
            assert (await _get_room(client, off["id"]))["auto_archive"] is False

            listed = (await client.get(
                "/api/rooms", params={"session_key": OWNER})).json()["rooms"]
            flags = {r["id"]: r["auto_archive"] for r in listed}
            assert flags == {on["id"]: True, off["id"]: False}


async def test_toggle_roundtrip_and_system_message(tmp_path):
    app, client = await _make(tmp_path, "toggle")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await _room(client))["id"]

            r = await _toggle(client, rid, False)
            assert r.status_code == 200, r.text
            assert r.json() == {"ok": True, "auto_archive": False,
                                "changed": True}
            assert (await _get_room(client, rid))["auto_archive"] is False

            # 同值不重複留痕
            r = await _toggle(client, rid, False)
            assert r.json()["changed"] is False

            r = await _toggle(client, rid, True)
            assert r.json() == {"ok": True, "auto_archive": True,
                                "changed": True}
            assert (await _get_room(client, rid))["auto_archive"] is True

            rows = await (await app.state.db.execute(
                "SELECT system_event FROM message WHERE room_id=?"
                " AND system_event='auto_archive'", (rid,))).fetchall()
            assert len(rows) == 2


async def test_toggle_requires_room_admin(tmp_path):
    app, client = await _make(tmp_path, "perm")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await _room(client))["id"]
            r = await _toggle(client, rid, False, key="someone-else")
            assert r.status_code == 403, r.text
            assert (await _get_room(client, rid))["auto_archive"] is True

            r = await client.post(f"/api/rooms/{rid}/auto-archive",
                                  json={"enabled": False})
            assert r.status_code in (401, 403), r.text
            assert (await _get_room(client, rid))["auto_archive"] is True


# ── sweeper ───────────────────────────────────────────────────────────

async def test_sweeper_archives_when_on(tmp_path):
    """對照組：開著的房照舊倒數後封存。沒有這條，下面的「不封存」等於沒驗。"""
    app, client = await _make(tmp_path, "on", archive_grace=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await _room(client))["id"]
            await _agent_came_and_went(client, rid)
            await app.state.sweep_once()   # 起算倒數
            await app.state.sweep_once()   # grace=0，這輪封存
            assert (await _row(app, rid))["status"] == "archived"


async def test_sweeper_skips_room_with_auto_archive_off(tmp_path):
    app, client = await _make(tmp_path, "off", archive_grace=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await _room(client, auto_archive=False))["id"]
            await _agent_came_and_went(client, rid)
            for _ in range(3):
                await app.state.sweep_once()
            row = await _row(app, rid)
            assert row["status"] == "active"
            assert row["archive_pending_since"] is None
            ann = await (await app.state.db.execute(
                "SELECT 1 FROM message WHERE room_id=?"
                " AND system_event='archive_pending'", (rid,))).fetchall()
            assert ann == [], "關閉的房不該宣告即將封存"


async def test_turning_off_cancels_pending_countdown(tmp_path):
    app, client = await _make(tmp_path, "cancel", archive_grace=3600.0)
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await _room(client))["id"]
            await _agent_came_and_went(client, rid)
            await app.state.sweep_once()
            assert (await _row(app, rid))["archive_pending_since"] is not None

            assert (await _toggle(client, rid, False)).status_code == 200
            row = await _row(app, rid)
            assert row["archive_pending_since"] is None
            await app.state.sweep_once()
            row = await _row(app, rid)
            assert row["status"] == "active"
            assert row["archive_pending_since"] is None


async def test_turning_back_on_restarts_countdown_from_scratch(tmp_path):
    """重新開啟後按現有邏輯重新判斷：重新起算，不是沿用舊倒數。"""
    app, client = await _make(tmp_path, "reopen", archive_grace=3600.0)
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await _room(client))["id"]
            await _agent_came_and_went(client, rid)
            await app.state.sweep_once()
            first = (await _row(app, rid))["archive_pending_since"]
            assert first is not None

            await _toggle(client, rid, False)
            await _toggle(client, rid, True)
            assert (await _row(app, rid))["archive_pending_since"] is None

            await app.state.sweep_once()
            row = await _row(app, rid)
            assert row["status"] == "active"
            assert row["archive_pending_since"] is not None
            assert row["archive_pending_since"] >= first


# ── migration ─────────────────────────────────────────────────────────

async def test_migration_backfills_existing_rooms_to_on(tmp_path):
    """舊庫（沒有 auto_archive 欄）升級後，既有房一律是開啟。"""
    path = str(tmp_path / "legacy.db")
    db = await open_db(path)
    await db.execute(
        "INSERT INTO room (id, name, created_at) VALUES ('old1', '舊房',"
        " '2026-01-01T00:00:00+00:00')")
    await db.commit()
    await db.execute("ALTER TABLE room DROP COLUMN auto_archive")
    await db.commit()
    cols = {r["name"] for r in await (
        await db.execute("PRAGMA table_info(room)")).fetchall()}
    assert "auto_archive" not in cols, "沒有造出舊庫，下面的 backfill 等於沒驗"
    await db.close()

    db = await open_db(path)
    try:
        row = await (await db.execute(
            "SELECT auto_archive FROM room WHERE id='old1'")).fetchone()
        assert row["auto_archive"] == 1
    finally:
        await db.close()
