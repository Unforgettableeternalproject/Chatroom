"""Board v2 schema：四張新表、掛接唯一性、舊庫升級。

**既有 DB**：使用者手上是一個一直在跑的 `chatroom.db`（v1 一房一板）。
v2 的四張表要能長在那上面，而且不能碰壞既有資料——這正是 09/01
`board_supervisor_*` 那次踩過的形狀（`CREATE TABLE IF NOT EXISTS`
對已存在的表不會加新欄），所以這裡連舊庫路徑一起測。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

V2_TABLES = {"board", "board_room", "board_member", "board_event"}


async def _tables(db):
    rows = await (await db.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")).fetchall()
    return {r["name"] for r in rows}


async def test_v2_tables_created(tmp_path):
    db = await open_db(str(tmp_path / "new.db"))
    assert V2_TABLES <= await _tables(db)
    await db.close()


async def test_open_db_is_idempotent(tmp_path):
    """開兩次不會炸——升級路徑會反覆走到這裡。"""
    p = str(tmp_path / "twice.db")
    db = await open_db(p)
    await db.close()
    db = await open_db(p)
    assert V2_TABLES <= await _tables(db)
    await db.close()


async def test_one_active_board_per_room(tmp_path):
    """一間房最多掛一塊 active Board——**由資料庫擋，不靠呼叫端自律**。

    解除掛接（detached_at 有值）之後才能再掛下一塊；partial unique index
    只約束 detached_at IS NULL 的那些列，掛接歷史照樣留著。
    """
    db = await open_db(str(tmp_path / "attach.db"))
    now = "2026-09-02T00:00:00+00:00"
    for bid in ("b1", "b2"):
        await db.execute(
            "INSERT INTO board (id, name, owner_actor_key, created_at, updated_at)"
            " VALUES (?, ?, 'actor-x', ?, ?)", (bid, bid, now, now))
    await db.execute(
        "INSERT INTO board_room (id, board_id, room_id, attached_by_actor_key,"
        " attached_at) VALUES ('br1', 'b1', 'roomA', 'actor-x', ?)", (now,))

    import aiosqlite
    with pytest.raises(aiosqlite.IntegrityError):
        await db.execute(
            "INSERT INTO board_room (id, board_id, room_id,"
            " attached_by_actor_key, attached_at)"
            " VALUES ('br2', 'b2', 'roomA', 'actor-x', ?)", (now,))

    # 解除之後才掛得上第二塊，而第一筆掛接歷史仍在
    await db.execute(
        "UPDATE board_room SET detached_at = ? WHERE id = 'br1'", (now,))
    await db.execute(
        "INSERT INTO board_room (id, board_id, room_id, attached_by_actor_key,"
        " attached_at) VALUES ('br2', 'b2', 'roomA', 'actor-x', ?)", (now,))
    rows = await (await db.execute(
        "SELECT id FROM board_room WHERE room_id = 'roomA'")).fetchall()
    assert len(rows) == 2
    await db.close()


async def test_upgrade_from_v1_database(tmp_path):
    """v1 的舊庫升上來：新表要長出來，舊資料一列都不能少。"""
    p = str(tmp_path / "legacy.db")
    db = await open_db(p)
    now = "2026-09-01T00:00:00+00:00"
    await db.execute(
        "INSERT INTO room (id, name, topic, status, created_at, next_seq)"
        " VALUES ('r1', '舊房', '', 'active', ?, 1)", (now,))
    await db.execute("DROP TABLE board")
    await db.execute("DROP TABLE board_room")
    await db.execute("DROP TABLE board_member")
    await db.execute("DROP TABLE board_event")
    await db.commit()
    await db.close()

    db = await open_db(p)
    assert V2_TABLES <= await _tables(db)
    row = await (await db.execute(
        "SELECT name FROM room WHERE id = 'r1'")).fetchone()
    assert row["name"] == "舊房"
    await db.close()


async def test_board_event_carries_directive_target(tmp_path):
    """directive 要送給誰，得有地方存。

    `actor_key` 是送出者，目標另存 `target_actor_key`——少了它，
    Supervisor 的判斷寫得進稽核串卻投遞不出去。
    """
    db = await open_db(str(tmp_path / "ev.db"))
    now = "2026-09-02T00:00:00+00:00"
    await db.execute(
        "INSERT INTO board (id, name, owner_actor_key, created_at, updated_at)"
        " VALUES ('b1', 'B', 'sup', ?, ?)", (now, now))
    await db.execute(
        "INSERT INTO board_event (board_id, board_seq, event_type, actor_key,"
        " target_actor_key, payload_json, created_at)"
        " VALUES ('b1', 1, 'directive', 'sup', 'worker-1', '{}', ?)", (now,))
    row = await (await db.execute(
        "SELECT target_actor_key FROM board_event WHERE board_id = 'b1'"
    )).fetchone()
    assert row["target_actor_key"] == "worker-1"
    await db.close()


async def test_deleting_a_room_detaches_the_board_but_keeps_it(tmp_path):
    """刪房只解除掛接，Board 與掛接歷史都留著（BOARD_DESIGN §3.2、驗收 3）。

    ⚠️ 這條同時守住一個反向的錯誤：把 `board_room` 加進
    `_ROOM_OWNED_TABLES` 也能讓 schema 對帳過關、刪除照樣成功，
    但那會把 provenance 一起刪掉——**房沒了之後，那正是唯一還講得出
    「這張卡從哪來」的東西**。所以這裡驗的是「列還在且被標記」，
    不是「刪得掉」。
    """
    cfg = Config(db_path=str(tmp_path / "detach.db"), api_token="")
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.post(
                "/api/rooms", json={"name": "要被刪的房", "session_key": "admin"})
            room_id = r.json()["id"]

            db = app.state.db
            now = "2026-09-02T00:00:00+00:00"
            await db.execute(
                "INSERT INTO board (id, name, owner_actor_key, created_at,"
                " updated_at) VALUES ('b1', '板', 'admin', ?, ?)", (now, now))
            await db.execute(
                "INSERT INTO board_room (id, board_id, room_id, room_name,"
                " attached_by_actor_key, attached_at)"
                " VALUES ('br1', 'b1', ?, '要被刪的房', 'admin', ?)",
                (room_id, now))
            await db.commit()

            r = await client.delete(
                f"/api/rooms/{room_id}", headers={"X-Session-Key": "admin"})
            assert r.status_code == 200, r.text

            row = await (await db.execute(
                "SELECT board_id, room_name, detached_at FROM board_room"
                " WHERE id = 'br1'")).fetchone()
            assert row is not None, "掛接列被刪掉了——provenance 沒了"
            assert row["detached_at"], "掛接還開著，房卻已經不在"
            assert row["room_name"] == "要被刪的房"

            board = await (await db.execute(
                "SELECT status FROM board WHERE id = 'b1'")).fetchone()
            assert board["status"] == "active", "Board 不該隨房消失"


async def test_every_board_owned_table_is_in_the_delete_list(tmp_path):
    """**帶 `board_id` 的表都要在刪板清單裡。**

    漏掉的話刪板會撞外鍵而拋 IntegrityError（500），或者更糟——沒有外鍵的
    那些會留下永遠沒有人讀得到的孤兒列，而 API 回 200
    （審核用Codex-2 2026-09-03 用非空 pad + watch 重現）。

    這條拿 schema 對帳，讓「忘了加」變成一個查得到的事實，而不是等到有人
    真的去刪一塊有東西的板。
    """
    from chatroom_server.app import create_app
    from chatroom_server.config import Config

    app = create_app(Config(db_path=str(tmp_path / "owned.db"),
                            api_token="root-token"))
    async with app.router.lifespan_context(app):
        rows = await (await app.state.db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
            " AND name LIKE 'board%'")).fetchall()
        have = set()
        for r in rows:
            cols = await (await app.state.db.execute(
                f"PRAGMA table_info({r['name']})")).fetchall()
            if any(c["name"] == "board_id" for c in cols):
                have.add(r["name"])
        have.discard("board")
        listed = set(_owned_tables(app))
        missing = have - listed
        assert not missing, (
            f"這些表帶著 board_id 卻不在刪板清單裡：{sorted(missing)}。"
            "刪一塊有東西的板時，它們會撞外鍵或留下孤兒列")


def _owned_tables(app):
    """從原始碼把清單撈出來——它是模組內的區域常數，沒有別的入口。"""
    import inspect
    import re

    from chatroom_server import app as mod
    src = inspect.getsource(mod.create_app)
    body = re.search(r"_BOARD_OWNED_TABLES = \(([^)]*)\)", src).group(1)
    return re.findall(r'"([^"]+)"', body)
