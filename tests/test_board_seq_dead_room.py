"""階段的 provenance room 已解除掛接且 room 列被刪後，領號仍要走板軸。

線上現場（開卡 500）：`POST /api/board/checklists/{id}/tasks` 把階段的
`room_id`（建立當時的房）帶進 `_next_board_seq`；那間房已解除掛接，
`_board_for_room` 回 None，退到 v1 的 `UPDATE room ... RETURNING`，但 room 列
早被刪 ⇒ row 是 None ⇒ `TypeError` ⇒ 500。有 board_id 就該走板軸。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 log_dir=str(tmp_path / "logs"))
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _setup(client, app):
    """房 A 建第一張卡（長出板與階段）、房 B 也掛上同一塊板，再把 A 解除掛接並刪列。"""
    rid = (await client.post("/api/rooms", json={
        "name": "舊房", "session_key": "claude-a"})).json()["id"]
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": "claude-a",
        "preferred_name": "A"})
    hdr_a = {"X-Participant-Id": r.json()["participant_id"],
             "X-Session-Key": "claude-a"}
    r = await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": "第一張卡"}, headers=hdr_a)
    assert r.status_code == 200, r.text
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr_a)).json()["board_id"]
    cid = (await client.get(f"/api/boards/{bid}",
                            headers=hdr_a)).json()["checklists"][0]["id"]

    # 另一間房掛上同一塊板，之後用它的身分在板上寫
    rid_b = (await client.post("/api/rooms", json={
        "name": "新房", "session_key": "claude-a"})).json()["id"]
    r = await client.post(f"/api/rooms/{rid_b}/join", json={
        "kind": "claude", "role": "agent", "session_key": "claude-a",
        "preferred_name": "A"})
    hdr_b = {"X-Participant-Id": r.json()["participant_id"],
             "X-Session-Key": "claude-a"}
    r = await client.post(f"/api/boards/{bid}/rooms/{rid_b}",
                          headers=hdr_a)
    assert r.status_code == 200, r.text

    r = await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=hdr_a)
    assert r.status_code == 200, r.text
    db = app.state.db
    await db.execute("PRAGMA foreign_keys=OFF")
    await db.execute("DELETE FROM room WHERE id=?", (rid,))
    await db.commit()
    return rid, bid, cid, hdr_b


async def _board_seq(app, bid):
    row = await (await app.state.db.execute(
        "SELECT board_seq FROM board WHERE id=?", (bid,))).fetchone()
    return row["board_seq"]


async def test_create_task_under_stage_whose_room_is_gone(tmp_path):
    app, client = await _client(tmp_path, "dead_room_task")
    async with client, app.router.lifespan_context(app):
        rid, bid, cid, hdr = await _setup(client, app)
        # 前提：階段的 provenance room 確實是那間已刪的房
        row = await (await app.state.db.execute(
            "SELECT room_id FROM board_checklist WHERE id=?", (cid,))).fetchone()
        assert row["room_id"] == rid

        before = await _board_seq(app, bid)
        r = await client.post(f"/api/board/checklists/{cid}/tasks",
                              json={"title": "死房後的新卡"}, headers=hdr)
        assert r.status_code == 200, r.text
        assert await _board_seq(app, bid) == before + 1
        assert r.json()["board_seq"] == before + 1

        r2 = await client.post(f"/api/board/checklists/{cid}/tasks",
                               json={"title": "再一張"}, headers=hdr)
        assert r2.status_code == 200, r2.text
        assert r2.json()["board_seq"] == before + 2


async def test_stage_file_writes_with_a_dead_room_do_not_500(tmp_path):
    """同族呼叫點（階段素材）：帶 board_id 領號，不吃死房。"""
    app, client = await _client(tmp_path, "dead_room_stage_file")
    async with client, app.router.lifespan_context(app):
        rid, bid, cid, hdr = await _setup(client, app)
        # 附件要屬於一間掛接房（B）
        rid_b = hdr["X-Participant-Id"] and (await (await app.state.db.execute(
            "SELECT room_id FROM participant WHERE id=?",
            (hdr["X-Participant-Id"],))).fetchone())["room_id"]
        up = await client.post(f"/api/rooms/{rid_b}/attachments",
                               files={"file": ("a.png", b"x", "image/png")},
                               headers={"X-Participant-Id":
                                        hdr["X-Participant-Id"]})
        assert up.status_code == 200, up.text
        before = await _board_seq(app, bid)
        r = await client.post(
            f"/api/boards/{bid}/checklists/{cid}/files",
            json={"attachment_id": up.json()["id"], "note": "n"}, headers=hdr)
        assert r.status_code == 200, r.text
        fid = r.json()["file"]["id"]
        r = await client.patch(
            f"/api/boards/{bid}/checklists/{cid}/files/{fid}",
            json={"note": "改"}, headers=hdr)
        assert r.status_code == 200, r.text
        r = await client.delete(
            f"/api/boards/{bid}/checklists/{cid}/files/{fid}", headers=hdr)
        assert r.status_code == 200, r.text
        assert await _board_seq(app, bid) == before + 3
