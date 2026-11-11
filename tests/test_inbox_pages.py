"""「未分類」分頁（艾斯維爾 2026-11-11 裁決）。

「未分類」永遠存在，以分頁運作：每一頁是一個 objective（kind='inbox'、
page_no 遞增、標題固定「未分類」），同一塊板任何時候只有一個使用中的頁。
頁完成的同一交易開下一頁；頁不可取消；可用 split_inbox 拆成獨立週期。
"""

import asyncio
import sqlite3

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "creator"})).json()["id"]
    human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
    return rid, human


async def _loose(client, rid, hdr, title="隨手記一件"):
    r = await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": title}, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()


async def _pages(app, rid=None):
    rows = await (await app.state.db.execute(
        "SELECT * FROM board_objective WHERE kind='inbox' AND deleted=0"
        " ORDER BY page_no")).fetchall()
    return [dict(r) for r in rows]


async def _finish_page(client, app, hdr, task):
    """把這張隨手記推到底：卡 done → 階段 done → 送審 → 確認 → 完成。"""
    tid, cid = task["id"], task["checklist_id"]
    for target in ("in_progress", "done"):
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": target}, headers=hdr)
    r = await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=hdr)
    assert r.status_code == 200, r.text
    oid = (await (await app.state.db.execute(
        "SELECT objective_id FROM board_checklist WHERE id=?",
        (cid,))).fetchone())["objective_id"]
    for step in ("review", "verify", "complete"):
        r = await client.post(f"/api/board/objectives/{oid}/{step}",
                              headers=hdr)
        assert r.status_code == 200, (step, r.text)
    return oid


# ── 唯一使用中頁（DB 約束）────────────────────────────────────────────

_INS = ("INSERT INTO board_objective (id, room_id, board_id, title, status,"
        " created_at, kind, page_no) VALUES (?,?,?,?,?,?,'inbox',?)")


async def test_only_one_active_page_per_board(tmp_path):
    db = await open_db(str(tmp_path / "idx.db"))
    await db.execute(_INS, ("a", "", "B1", "未分類", "active", "t", 1))
    with pytest.raises(sqlite3.IntegrityError):
        await db.execute(_INS, ("b", "", "B1", "未分類", "review", "t", 2))
    # 別塊板不受影響
    await db.execute(_INS, ("c", "", "B2", "未分類", "active", "t", 1))
    # 收尾之後才能再開下一頁
    await db.execute("UPDATE board_objective SET status='done' WHERE id='a'")
    await db.execute(_INS, ("d", "", "B1", "未分類", "active", "t", 2))
    await db.close()


async def test_only_one_active_page_per_room_in_v1(tmp_path):
    """v1 房軸（board_id 空）以 room_id 為軸。"""
    db = await open_db(str(tmp_path / "idx_room.db"))
    await db.execute(_INS, ("a", "R1", "", "未分類", "active", "t", 1))
    with pytest.raises(sqlite3.IntegrityError):
        await db.execute(_INS, ("b", "R1", "", "未分類", "active", "t", 2))
    await db.execute(_INS, ("c", "R2", "", "未分類", "active", "t", 1))
    await db.execute("UPDATE board_objective SET status='cancelled'"
                     " WHERE id='a'")
    await db.execute(_INS, ("d", "R1", "", "未分類", "active", "t", 2))
    await db.close()


async def test_concurrent_loose_tasks_share_one_page(tmp_path):
    app, client = await _client(tmp_path, "concurrent")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        rs = await asyncio.gather(*[
            client.post(f"/api/rooms/{rid}/board/tasks",
                        json={"title": f"並行 {i}"}, headers=hdr)
            for i in range(8)])
        assert all(r.status_code == 200 for r in rs), [r.text for r in rs]
        assert len({r.json()["checklist_id"] for r in rs}) == 1
        pages = await _pages(app)
        assert len(pages) == 1 and pages[0]["page_no"] == 1


# ── 完成後自動開新頁 ─────────────────────────────────────────────────

async def test_completing_a_page_opens_the_next_one(tmp_path):
    app, client = await _client(tmp_path, "next_page")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        t1 = await _loose(client, rid, hdr)
        old = await _finish_page(client, app, hdr, t1)

        pages = await _pages(app)
        assert [(p["page_no"], p["status"]) for p in pages] == [
            (1, "done"), (2, "active")]
        assert pages[0]["id"] == old and pages[0]["completed_at"]
        assert pages[1]["title"] == "未分類"
        # 新頁自帶「未分類」階段
        n = await (await app.state.db.execute(
            "SELECT COUNT(*) AS n FROM board_checklist WHERE objective_id=?"
            " AND title='未分類' AND deleted=0", (pages[1]["id"],))).fetchone()
        assert n["n"] == 1

        # 舊頁 done 之後的隨手記不再 409，落在新頁
        t2 = await _loose(client, rid, hdr, "之後又想到")
        row = await (await app.state.db.execute(
            "SELECT objective_id FROM board_checklist WHERE id=?",
            (t2["checklist_id"],))).fetchone()
        assert row["objective_id"] == pages[1]["id"]

        # 板讀取 API 的 objective 帶 kind／page_no／completed_at
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  params={"include_settled": "true"},
                                  headers=hdr)).json()
        by_id = {o["id"]: o for o in board["objectives"]}
        assert by_id[old]["kind"] == "inbox" and by_id[old]["page_no"] == 1
        assert by_id[old]["completed_at"]
        assert by_id[pages[1]["id"]]["page_no"] == 2


async def test_inbox_page_cannot_be_cancelled(tmp_path):
    app, client = await _client(tmp_path, "no_cancel")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        t = await _loose(client, rid, hdr)
        oid = (await _pages(app))[0]["id"]
        r = await client.post(f"/api/board/objectives/{oid}/cancel",
                              headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "inbox_page_not_cancellable"
        assert t["id"]


async def test_page_complete_still_needs_the_normal_gates(tmp_path):
    """完成閘照舊：沒走到 verified 不能完成，也就不會開新頁。"""
    app, client = await _client(tmp_path, "gates")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        await _loose(client, rid, hdr)
        oid = (await _pages(app))[0]["id"]
        r = await client.post(f"/api/board/objectives/{oid}/complete",
                              headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "objective_not_verified"
        assert len(await _pages(app)) == 1


# ── 改名保護 ─────────────────────────────────────────────────────────

async def test_rename_protection(tmp_path):
    app, client = await _client(tmp_path, "rename")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        await _loose(client, rid, hdr)
        page = (await _pages(app))[0]["id"]
        r = await client.patch(f"/api/board/objectives/{page}",
                               json={"title": "改個名"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "inbox_rename_forbidden"

        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期"},
                                 headers=hdr)).json()["id"]
        r = await client.patch(f"/api/board/objectives/{oid}",
                               json={"title": "未分類"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "inbox_title_reserved"
        # 直接建一個叫「未分類」的一般週期也不行
        r = await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": "未分類"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "inbox_title_reserved"


# ── split_inbox ──────────────────────────────────────────────────────

async def test_split_active_page_becomes_a_normal_cycle_and_opens_new(tmp_path):
    app, client = await _client(tmp_path, "split_active")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        t = await _loose(client, rid, hdr)
        page = (await _pages(app))[0]["id"]
        r = await client.post(f"/api/board/objectives/{page}/split_inbox",
                              json={"title": "雜項整理", "reason": "測試"},
                              headers=hdr)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["id"] == page and body["kind"] == ""
        assert body["title"] == "雜項整理" and body["status"] == "active"
        new = body["new_inbox_objective"]
        assert new["kind"] == "inbox" and new["status"] == "active"
        assert new["title"] == "未分類" and new["page_no"] == 2

        # 唯一使用中頁仍成立；原階段改名「一般」、卡原樣在
        pages = await _pages(app)
        assert [p["id"] for p in pages] == [new["id"]]
        c = await (await app.state.db.execute(
            "SELECT title, objective_id FROM board_checklist WHERE id=?",
            (t["checklist_id"],))).fetchone()
        assert c["title"] == "一般" and c["objective_id"] == page
        # 新的隨手記落在新頁
        t2 = await _loose(client, rid, hdr, "拆完之後")
        assert t2["checklist_id"] != t["checklist_id"]

        # 拆出來的已是一般週期：階段可以搬、不能再被當成未分類頁拆
        r = await client.post(f"/api/board/objectives/{page}/split_inbox",
                              json={"title": "又拆"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "not_inbox_page"
        # 稽核事件
        ev = await (await app.state.db.execute(
            "SELECT 1 FROM board_event WHERE event_type="
            "'objective_split_from_inbox' AND item_id=?", (page,))).fetchone()
        assert ev is not None


async def test_split_done_page_stays_done_and_opens_nothing(tmp_path):
    app, client = await _client(tmp_path, "split_done")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        t = await _loose(client, rid, hdr)
        old = await _finish_page(client, app, hdr, t)
        before = await _pages(app)
        r = await client.post(f"/api/board/objectives/{old}/split_inbox",
                              json={"title": "已完成的整理"}, headers=hdr)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["status"] == "done" and body["kind"] == ""
        assert body["completed_at"]
        assert "new_inbox_objective" not in body
        after = await _pages(app)
        assert [p["id"] for p in after] == [
            p["id"] for p in before if p["id"] != old]


async def test_split_validation_and_permission(tmp_path):
    app, client = await _client(tmp_path, "split_perm")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _setup(client)
        stranger = await _join(client, rid, "stranger", "路人")
        await _loose(client, rid, hdr)
        page = (await _pages(app))[0]["id"]
        url = f"/api/board/objectives/{page}/split_inbox"

        r = await client.post(url, json={"title": "  "}, headers=hdr)
        assert r.status_code == 400
        assert r.json()["detail"]["code"] == "title_required"
        r = await client.post(url, json={"title": "未分類"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "inbox_title_reserved"
        r = await client.post(url, json={"title": "路人想拆"},
                              headers=stranger)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_board_editor"
        # 以上全擋下，頁沒被動到
        assert [p["id"] for p in await _pages(app)] == [page]

        normal = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                    json={"title": "一般週期"},
                                    headers=hdr)).json()["id"]
        r = await client.post(
            f"/api/board/objectives/{normal}/split_inbox",
            json={"title": "x"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "not_inbox_page"


# ── 資料遷移（版次 10）────────────────────────────────────────────────

_LEGACY_OBJ = ("INSERT INTO board_objective (id, room_id, board_id, title,"
               " status, created_at) VALUES (?,?,?,'未分類',?,'t')")
_LEGACY_CL = ("INSERT INTO board_checklist (id, room_id, board_id,"
              " objective_id, title, created_at) VALUES (?,?,?,?,'未分類','t')")


async def test_migration_adds_page_two_and_is_idempotent(tmp_path):
    path = str(tmp_path / "mig.db")
    db = await open_db(path)
    # 還原成版次 9 的樣子：標題是唯一的識別，kind／page_no 還沒回填
    for oid, room, board, status in (
            ("done-b", "", "BOARD-A", "done"),
            ("done-b2", "", "BOARD-B", "done"),
            ("cancel-b", "", "BOARD-C", "cancelled"),
            ("active-b", "", "BOARD-D", "active"),
            ("done-room", "ROOM-1", "", "done")):
        await db.execute(_LEGACY_OBJ, (oid, room, board, status))
        await db.execute(_LEGACY_CL, ("cl-" + oid, room, board, oid))
    await db.execute("PRAGMA user_version=9")
    await db.commit()
    await db.close()

    db = await open_db(path)
    rows = [dict(r) for r in await (await db.execute(
        "SELECT id, board_id, room_id, status, kind, page_no"
        " FROM board_objective ORDER BY board_id, room_id, page_no")
    ).fetchall()]
    by_axis: dict[str, list] = {}
    for r in rows:
        by_axis.setdefault(r["board_id"] or r["room_id"], []).append(r)
    for axis in ("BOARD-A", "BOARD-B", "BOARD-C", "ROOM-1"):
        pages = by_axis[axis]
        assert [(p["page_no"], p["status"], p["kind"]) for p in pages] == [
            (1, pages[0]["status"], "inbox"), (2, "active", "inbox")], axis
        n = await (await db.execute(
            "SELECT COUNT(*) AS n FROM board_checklist WHERE objective_id=?"
            " AND title='未分類'", (pages[1]["id"],))).fetchone()
        assert n["n"] == 1
    # 本來就有使用中頁的板不補
    assert [(p["page_no"], p["status"]) for p in by_axis["BOARD-D"]] == [
        (1, "active")]
    total = len(rows)
    await db.close()

    # 冪等：再開一次不會多長頁
    db = await open_db(path)
    n = await (await db.execute(
        "SELECT COUNT(*) AS n FROM board_objective")).fetchone()
    assert n["n"] == total
    await db.close()

    # 就算版次被倒回去重跑，也不會多長頁（只在沒有使用中頁時補）
    db = await open_db(path)
    await db.execute("PRAGMA user_version=9")
    await db.commit()
    await db.close()
    db = await open_db(path)
    n = await (await db.execute(
        "SELECT COUNT(*) AS n FROM board_objective")).fetchone()
    assert n["n"] == total
    await db.close()
