"""任務板的「封存」狀態移除，只留結局（艾斯維爾 2026-11-12）。

- DATA_VERSION 11 把既有已封存的板遷移：有結局 → 只留結局（已收尾）；
  無結局 → 回到進行中。
- 封存／解除封存 API 對舊 client 回 410 `board_archive_removed`。
- 已收尾（有結局）的板唯讀，清掉結局才能再寫。
- 永久刪除只給已收尾的板，owner 或主持人。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import DATA_VERSION, open_db

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = {"X-Session-Key": "human-1"}
OTHER = {"X-Session-Key": "stranger"}

_INSERT = ("INSERT INTO board (id, name, status, outcome, owner_actor_key,"
           " created_at, updated_at) VALUES (?,?,?,?,?,?,?)")


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def test_migration_clears_archive_and_keeps_outcome(tmp_path):
    """已封存＋有結局 → 只留結局；已封存＋無結局 → 回到進行中。"""
    path = str(tmp_path / "mig.db")
    db = await open_db(path)
    for bid, status, outcome in (
            ("arch-done", "archived", "completed"),
            ("arch-aband", "archived", "abandoned"),
            ("arch-open", "archived", ""),
            ("live", "active", ""),
            ("live-done", "active", "completed")):
        await db.execute(_INSERT, (bid, bid, status, outcome, "human-1",
                                   "2026-01-01", "2026-01-01"))
    # 還原成版次 10 的樣子
    await db.execute("PRAGMA user_version=10")
    await db.commit()
    await db.close()

    db = await open_db(path)
    rows = {r["id"]: (r["status"], r["outcome"]) for r in await (
        await db.execute("SELECT id, status, outcome FROM board")).fetchall()}
    assert rows == {
        "arch-done": ("active", "completed"),
        "arch-aband": ("active", "abandoned"),
        "arch-open": ("active", ""),
        "live": ("active", ""),
        "live-done": ("active", "completed"),
    }
    assert (await (await db.execute("PRAGMA user_version")).fetchone())[0] \
        == DATA_VERSION
    await db.close()


async def test_migration_runs_once_only(tmp_path):
    """版次只前進：版次已是最新時，不會再動資料。"""
    path = str(tmp_path / "mig-once.db")
    db = await open_db(path)
    await db.execute(_INSERT, ("x", "x", "archived", "", "human-1",
                               "2026-01-01", "2026-01-01"))
    await db.commit()
    await db.close()
    db = await open_db(path)
    assert (await (await db.execute(
        "SELECT status FROM board WHERE id='x'")).fetchone())[0] == "archived"
    await db.close()


async def test_archive_endpoints_answer_410(tmp_path):
    """舊 client 打封存／解除封存：清楚的錯誤，板不動。"""
    app, client = await _client(tmp_path, "gone")
    async with app.router.lifespan_context(app), client:
        bid = (await client.post("/api/boards", headers=OWNER,
                                 json={"name": "板"})).json()["id"]
        for verb in ("archive", "unarchive"):
            r = await client.post(f"/api/boards/{bid}/{verb}", headers=OWNER)
            assert r.status_code == 410, r.text
            assert r.json()["detail"]["code"] == "board_archive_removed"
        r = await client.get(f"/api/boards/{bid}", headers=OWNER)
        assert r.json()["status"] == "active"


async def test_delete_needs_a_settled_board_and_an_owner(tmp_path):
    app, client = await _client(tmp_path, "del")
    async with app.router.lifespan_context(app), client:
        bid = (await client.post("/api/boards", headers=OWNER,
                                 json={"name": "板"})).json()["id"]
        # 未收尾：擋下
        r = await client.delete(f"/api/boards/{bid}", headers=OWNER)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "board_not_settled"
        await app.state.db.execute(
            "UPDATE board SET outcome='abandoned' WHERE id=?", (bid,))
        await app.state.db.commit()
        # 已收尾但不是 owner：擋下
        r = await client.delete(f"/api/boards/{bid}", headers=OTHER)
        assert r.status_code in (403, 404), r.text
        # owner：刪得掉
        r = await client.delete(f"/api/boards/{bid}", headers=OWNER)
        assert r.status_code == 200, r.text
        assert (await client.get(f"/api/boards/{bid}",
                                 headers=OWNER)).status_code == 404
