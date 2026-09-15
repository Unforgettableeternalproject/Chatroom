"""T-03：三層 CRUD 與批次排序。

驗收的三個重點都不在「能不能建起來」：

1. 建／改／軟刪**各自**推進 `board_seq`（不推的話增量 client 收不到）
2. 批次排序**整批只領一個號**（每列各領一個，拖十張卡就變成十次變更）
3. 級聯軟刪除時，**子孫每一列也要領到那個號**——只更新被點的那一列的話，
   底下的 tombstone 永遠撈不出來，board 上會留著一批不存在的卡
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _room(client):
    return (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]


async def _tree(client, rid, hdr):
    """建一棵最小的 Objective → Checklist → Task。"""
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "接端點"}, headers=hdr)).json()["id"]
    return oid, cid, tid


async def _board(client, rid, hdr, after=0):
    return (await client.get(f"/api/rooms/{rid}/board?after_board_seq={after}",
                             headers=hdr)).json()


async def test_each_write_advances_board_seq(tmp_path):
    app, client = await _client(tmp_path, "seq")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        seqs = []
        r = await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": "週期一"}, headers=hdr)
        assert r.status_code == 200, r.text
        oid = r.json()["id"]
        seqs.append(r.json()["board_seq"])
        r = await client.patch(f"/api/board/objectives/{oid}",
                               json={"title": "週期一（改）"}, headers=hdr)
        seqs.append(r.json()["board_seq"])
        r = await client.delete(f"/api/board/objectives/{oid}", headers=hdr)
        seqs.append(r.json()["board_seq"])
        assert seqs == sorted(set(seqs)), f"水位沒有嚴格遞增：{seqs}"


async def test_patch_only_touches_given_fields(tmp_path):
    """少傳一個欄位不等於清空它——description 本來就允許空字串。"""
    app, client = await _client(tmp_path, "patch")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives", json={
            "title": "週期一", "description": "原本的描述"},
            headers=hdr)).json()["id"]
        await client.patch(f"/api/board/objectives/{oid}",
                           json={"title": "改過的標題"}, headers=hdr)
        board = await _board(client, rid, hdr)
        obj = next(o for o in board["objectives"] if o["id"] == oid)
        assert obj["title"] == "改過的標題"
        assert obj["description"] == "原本的描述"


async def test_cascade_delete_stamps_every_descendant(tmp_path):
    """🔴 只更新被點的那一列，底下的 tombstone 就永遠撈不出來。"""
    app, client = await _client(tmp_path, "cascade")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid, cid, tid = await _tree(client, rid, hdr)
        before = (await _board(client, rid, hdr))["board_seq"]
        r = await client.delete(f"/api/board/objectives/{oid}", headers=hdr)
        assert r.status_code == 200, r.text

        # 用刪除前的水位當游標——增量 client 就是這樣看世界的
        delta = await _board(client, rid, hdr, after=before)
        assert [o["id"] for o in delta["objectives"]] == [oid]
        assert [c["id"] for c in delta["checklists"]] == [cid]
        assert [t["id"] for t in delta["tasks"]] == [tid]
        assert all(x["deleted"] for x in
                   delta["objectives"] + delta["checklists"] + delta["tasks"])


async def test_cascade_delete_of_checklist_takes_its_tasks(tmp_path):
    app, client = await _client(tmp_path, "cascade2")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid, cid, tid = await _tree(client, rid, hdr)
        before = (await _board(client, rid, hdr))["board_seq"]
        await client.delete(f"/api/board/checklists/{cid}", headers=hdr)
        delta = await _board(client, rid, hdr, after=before)
        assert [t["id"] for t in delta["tasks"]] == [tid]
        assert delta["tasks"][0]["deleted"] is True
        # Objective 沒被碰到，不該出現在這次的增量裡
        assert delta["objectives"] == []


async def test_reorder_takes_exactly_one_seq(tmp_path):
    app, client = await _client(tmp_path, "reorder")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        ids = [(await client.post(f"/api/rooms/{rid}/board/objectives",
                                  json={"title": f"週期{i}"},
                                  headers=hdr)).json()["id"] for i in range(3)]
        before = (await _board(client, rid, hdr))["board_seq"]
        r = await client.post(f"/api/rooms/{rid}/board/reorder", json={
            "kind": "objective",
            "items": [{"id": i, "order_index": n}
                      for n, i in enumerate(reversed(ids))]}, headers=hdr)
        assert r.status_code == 200, r.text
        assert r.json()["board_seq"] == before + 1, "整批應該只領一個號"
        delta = await _board(client, rid, hdr, after=before)
        assert len(delta["objectives"]) == 3
        assert {o["board_seq"] for o in delta["objectives"]} == {before + 1}


async def test_reorder_is_all_or_nothing(tmp_path):
    """部分成功會讓 client 拿到一個它無法解讀的順序。"""
    app, client = await _client(tmp_path, "reorder-partial")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=hdr)).json()["id"]
        before = (await _board(client, rid, hdr))["board_seq"]
        r = await client.post(f"/api/rooms/{rid}/board/reorder", json={
            "kind": "objective",
            "items": [{"id": oid, "order_index": 5},
                      {"id": "不存在", "order_index": 6}]}, headers=hdr)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "board_item_not_found"
        assert (await _board(client, rid, hdr))["board_seq"] == before, "整批未套用"


async def test_deleted_card_cannot_be_patched_back_to_life(tmp_path):
    app, client = await _client(tmp_path, "zombie")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid, cid, tid = await _tree(client, rid, hdr)
        await client.delete(f"/api/board/tasks/{tid}", headers=hdr)
        r = await client.patch(f"/api/board/tasks/{tid}",
                               json={"title": "復活"}, headers=hdr)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "board_item_not_found"


async def test_only_creator_or_human_can_delete(tmp_path):
    app, client = await _client(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        mine = await _join(client, rid, "agent-1", "Novia")
        other = await _join(client, rid, "agent-2", "Miller")
        human = await _join(client, rid, "human-1", "Bernie", role="human")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=mine)).json()["id"]
        r = await client.delete(f"/api/board/objectives/{oid}", headers=other)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "human_only"
        # 人類可以刪別人建的
        assert (await client.delete(f"/api/board/objectives/{oid}",
                                    headers=human)).status_code == 200


async def test_writes_are_blocked_in_archived_room(tmp_path):
    """封存房唯讀——讀 board 可以，寫不行。"""
    app, client = await _client(tmp_path, "archived")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        await app.state.db.execute(
            "UPDATE room SET status='archived' WHERE id=?", (rid,))
        await app.state.db.commit()
        r = await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": "還想寫"}, headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "room_archived"


async def test_task_carries_source_seq_and_assignee(tmp_path):
    """Task 可以連回某則訊息，指派只是建議欄位。"""
    app, client = await _client(tmp_path, "link")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        other = await _join(client, rid, "agent-2", "Miller")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=hdr)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "Hub 端"},
                                 headers=hdr)).json()["id"]
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks", json={
            "title": "接端點", "source_seq": 7, "priority": "high",
            "assignee_participant_id": other["X-Participant-Id"]},
            headers=hdr)).json()["id"]
        task = next(t for t in (await _board(client, rid, hdr))["tasks"]
                    if t["id"] == tid)
        assert task["source_seq"] == 7
        assert task["priority"] == "high"
        assert task["assignee_participant_id"] == other["X-Participant-Id"]
        # 指派不鎖卡：認領狀態仍是「沒人領」
        assert task["claim_state"] == ""


# ---------- F2／F3（測試 Novia 第一輪回報）----------

async def test_a_loose_task_gets_the_uncategorised_layers(tmp_path):
    """Q2：三層強制，但「隨手記一件事」不該逼人先蓋兩層。

    要 agent 為了記一件事先自己蓋 Objective 再蓋 Checklist，實務上的結果
    是它乾脆不記。
    """
    app, client = await _client(tmp_path, "loose")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        r = await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "順手記一件事"}, headers=hdr)
        assert r.status_code == 200, r.text
        board = await _board(client, rid, hdr)
        assert [o["title"] for o in board["objectives"]] == ["未分類"]
        assert [c["title"] for c in board["checklists"]] == ["未分類"]
        assert board["tasks"][0]["checklist_id"] == board["checklists"][0]["id"]


async def test_uncategorised_layers_are_reused_not_duplicated(tmp_path):
    """固定名字才找得回同一個——每次新建的話板上會長出一排空殼。"""
    app, client = await _client(tmp_path, "loose-reuse")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        for i in range(3):
            await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": f"第 {i} 件"}, headers=hdr)
        board = await _board(client, rid, hdr)
        assert len(board["objectives"]) == 1
        assert len(board["checklists"]) == 1
        assert len(board["tasks"]) == 3


async def test_wrong_layer_says_so_instead_of_not_found(tmp_path):
    """「不存在」與「是別的層」壓成同一句的話，對方會去重讀 board 再撞一次。"""
    app, client = await _client(tmp_path, "wrong-kind")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid, cid, tid = await _tree(client, rid, hdr)

        # 把 Objective 的 id 當成 Checklist 用
        r = await client.post(f"/api/board/checklists/{oid}/tasks",
                              json={"title": "掛錯層"}, headers=hdr)
        assert r.status_code == 422
        detail = r.json()["detail"]
        assert detail["code"] == "board_item_wrong_kind"
        assert detail["actual"] == "objective"
        assert detail["expected"] == "checklist"
        assert detail["title"] == "週期一"

        # 真的不存在的 id 仍然是 404
        r = await client.post("/api/board/checklists/0000/tasks",
                              json={"title": "沒這張"}, headers=hdr)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "board_item_not_found"


async def test_deleted_card_is_not_reported_as_wrong_kind(tmp_path):
    """已刪除的卡在自己那層仍是 404，不能因為查不到就去別層亂猜。"""
    app, client = await _client(tmp_path, "deleted-kind")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid, cid, tid = await _tree(client, rid, hdr)
        await client.delete(f"/api/board/checklists/{cid}", headers=hdr)
        r = await client.post(f"/api/board/checklists/{cid}/tasks",
                              json={"title": "掛到刪掉的"}, headers=hdr)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "board_item_not_found"
