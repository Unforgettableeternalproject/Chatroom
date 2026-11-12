"""主持人 override 所有管理操作（艾斯維爾 2026-11-11）：任務板與想法板。

主持人（X-Host-View）在任務板上的每一類操作都放行：週期的 patch／送審／確認／
完成／重開／取消、軟刪除、卡的指派、directive、階段素材、想法板的註解與段落。
每一類都附對照組（同一個動作、沒帶主持人標頭的路人被擋），並確認主持人的
`reason` 進了建立者的通知。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HOST = {"X-Host-View": "1", "X-Session-Key": "host-device"}
OWNER = "owner-key"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _settle_directly(app, bid, outcome="completed"):
    """直接寫結局。板沒有封存了，「唯讀」由結局承接；這裡要的是一塊已收尾的板，
    不是宣告結局的前置條件（那在 test_board_outcome）。"""
    await app.state.db.execute(
        "UPDATE board SET outcome=? WHERE id=?", (outcome, bid))
    await app.state.db.commit()


async def _join(client, rid, key, name, role="human"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _tree(client):
    """房主建一整棵樹；另有一個一般成員 member 當對照組。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": OWNER})).json()["id"]
    owner = await _join(client, rid, OWNER, "房主")
    member = await _join(client, rid, "member-key", "成員")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"},
                             headers=owner)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段"},
                             headers=owner)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "任務"},
                             headers=owner)).json()["id"]
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=owner)).json()["board_id"]
    return rid, bid, oid, cid, tid, owner, member


async def _mine(client, key=OWNER, kind_prefix=""):
    r = await client.get("/api/notifications", headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text
    return [x for x in r.json()["notifications"]
            if x["kind"].startswith(kind_prefix)]


async def test_host_patches_and_deletes_items_with_reason(tmp_path):
    app, client = await _client(tmp_path, "patch")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        for url in (f"/api/board/objectives/{oid}",
                    f"/api/board/checklists/{cid}",
                    f"/api/board/tasks/{tid}"):
            # 對照組：一般成員（非 owner／supervisor／建立者）改不動週期與階段
            # （卡的標題本來就開放給房內人類，不列對照）
            if "tasks" not in url:
                r = await client.patch(url, json={"title": "路人改"},
                                       headers=member)
                assert r.status_code == 403, (url, r.text)
            r = await client.patch(
                url, json={"title": "主持人改", "reason": "標題不當"},
                headers=HOST)
            assert r.status_code == 200, (url, r.text)
        n = await _mine(client, kind_prefix="host_item_updated")
        assert len(n) == 3 or (len(n) >= 1 and sum(x["count"] for x in n) == 3)
        assert {x["reason"] for x in n} == {"標題不當"}
        assert all(x["actor_kind"] == "host" for x in n)
        assert {x["item_kind"] for x in n} == {"objective", "checklist",
                                               "task"}

        # 軟刪除（卡 → 階段 → 週期）
        for url in (f"/api/board/tasks/{tid}", f"/api/board/checklists/{cid}"):
            # （房內人類本來就刪得動卡與階段，所以這裡沒有對照組）
            r = await client.delete(url, headers=HOST,
                                    params={"reason": "清掉"})
            assert r.status_code == 200, (url, r.text)
        deleted = await _mine(client, kind_prefix="host_item_deleted")
        assert {x["item_kind"] for x in deleted} == {"task", "checklist"}
        assert {x["reason"] for x in deleted} == {"清掉"}


async def test_host_drives_task_status_assign_and_checklist_status(tmp_path):
    app, client = await _client(tmp_path, "status")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=HOST)
        assert r.status_code == 200, r.text
        # 指派：主持人直接指派，一般成員只能請求
        r = await client.post(f"/api/board/tasks/{tid}/assign",
                              json={"target_session_key": "member-key",
                                    "reason": "請你接"}, headers=HOST)
        assert r.status_code == 200 and r.json()["assigned"] is True, r.text
        r = await client.post(f"/api/board/tasks/{tid}/assign",
                              json={"target_session_key": OWNER},
                              headers=member)
        assert r.json()["assigned"] is False
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"}, headers=HOST)
        assert r.status_code == 200, r.text
        kinds = {x["kind"] for x in await _mine(client, kind_prefix="host_")}
        assert {"host_item_status", "host_item_assigned"} <= kinds


async def test_host_runs_the_whole_objective_lifecycle(tmp_path):
    app, client = await _client(tmp_path, "life")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=HOST)
        await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=HOST)
        for step in ("review", "verify", "complete"):
            r = await client.post(f"/api/board/objectives/{oid}/{step}",
                                  json={"reason": f"主持人{step}"}
                                  if step != "verify" else None,
                                  headers=HOST)
            assert r.status_code == 200, (step, r.text)
        # 第二個週期：送審 → 打回 → 取消
        oid2 = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                  json={"title": "週期2"},
                                  headers=owner)).json()["id"]
        cid2 = (await client.post(f"/api/board/objectives/{oid2}/checklists",
                                  json={"title": "階段2"},
                                  headers=owner)).json()["id"]
        tid2 = (await client.post(f"/api/board/checklists/{cid2}/tasks",
                                  json={"title": "任務2"},
                                  headers=owner)).json()["id"]
        await client.post(f"/api/board/tasks/{tid2}/status",
                          json={"status": "done"}, headers=HOST)
        await client.post(f"/api/board/checklists/{cid2}/status",
                          json={"status": "done"}, headers=HOST)
        r = await client.post(f"/api/board/objectives/{oid2}/review",
                              headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/objectives/{oid2}/reopen",
                              json={"reason": "重來"}, headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/objectives/{oid2}/cancel",
                              json={"reason": "不做了"}, headers=HOST)
        assert r.status_code == 200, r.text
        n = await _mine(client, kind_prefix="host_item_status")
        assert n and all(x["actor_kind"] == "host" for x in n)
        assert any(x["reason"] == "不做了" for x in n)


async def test_host_sends_a_directive_and_moves_a_stage(tmp_path):
    app, client = await _client(tmp_path, "directive")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        r = await client.post(f"/api/boards/{bid}/directives",
                              json={"text": "方向調整", "reason": "客戶要求"},
                              headers=HOST)
        assert r.status_code == 200, r.text
        oid2 = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                  json={"title": "週期2"},
                                  headers=owner)).json()["id"]
        r = await client.post(f"/api/board/checklists/{cid}/move",
                              json={"objective_id": oid2, "reason": "歸位"},
                              headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/checklists/{cid}/move",
                              json={"objective_id": oid}, headers=member)
        assert r.status_code == 403, r.text
        moved = await _mine(client, kind_prefix="host_item_moved")
        assert moved and moved[0]["reason"] == "歸位"


async def test_host_manages_stage_files_and_the_creator_hears_about_it(tmp_path):
    app, client = await _client(tmp_path, "files")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        up = await client.post(
            f"/api/rooms/{rid}/attachments",
            files={"file": ("a.png", b"img", "image/png")},
            headers={"X-Participant-Id": member["X-Participant-Id"]})
        aid = up.json()["id"]
        url = f"/api/boards/{bid}/checklists/{cid}/files"
        r = await client.post(url, json={"attachment_id": aid, "note": "圖"},
                              headers=HOST)
        assert r.status_code == 200, r.text
        fid = r.json()["file"]["id"]
        r = await client.patch(f"{url}/{fid}", json={"note": "新備註"},
                               headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.delete(f"{url}/{fid}", headers=HOST,
                                params={"reason": "不需要"})
        assert r.status_code == 200, r.text
        kinds = {x["kind"] for x in await _mine(client, kind_prefix="host_")}
        assert {"host_stage_file_added", "host_stage_file_noted",
                "host_stage_file_removed"} <= kinds


async def _pad(client, bid, hdr):
    r = await client.post(f"/api/boards/{bid}/scratchpads",
                          json={"title": "想法", "content": "第一段"},
                          headers=hdr)
    body = r.json()
    return body["id"], body["first_block_id"]


async def test_host_works_the_scratchpad(tmp_path):
    app, client = await _client(tmp_path, "pad")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        pid, bkid = await _pad(client, bid, owner)
        base = f"/api/boards/{bid}/scratchpads/{pid}"
        r = await client.post(f"{base}/blocks/{bkid}/notes",
                              json={"content": "註解"}, headers=HOST)
        assert r.status_code == 200, r.text
        nid = r.json()["id"]
        r = await client.post(f"{base}/notes/{nid}/resolve", headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.post(f"{base}/blocks", json={"content": "新段"},
                              headers=HOST)
        assert r.status_code == 200, r.text
        new_block = r.json()["id"]
        r = await client.put(f"{base}/blocks/{bkid}",
                             json={"content": "主持人改寫", "rev": 1},
                             headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.post(f"{base}/reorder",
                              json={"block_ids": [new_block, bkid], "rev": 1},
                              headers=HOST)
        assert r.status_code in (200, 409), r.text
        r = await client.delete(f"{base}/blocks/{new_block}", headers=HOST)
        assert r.status_code == 200, r.text
        r = await client.delete(base, headers=HOST,
                                params={"reason": "整理"})
        assert r.status_code == 200, r.text
        kinds = {x["kind"] for x in await _mine(client, kind_prefix="host_")}
        assert {"host_scratchpad_note", "host_scratchpad_block",
                "host_scratchpad_deleted"} <= kinds


async def test_host_changes_the_board_itself_and_deletes_it(tmp_path):
    app, client = await _client(tmp_path, "board")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, owner, member = await _tree(client)
        r = await client.patch(f"/api/boards/{bid}",
                               json={"name": "新板名", "reason": "改名"},
                               headers=member)
        assert r.status_code == 403
        r = await client.patch(f"/api/boards/{bid}",
                               json={"name": "新板名", "reason": "改名"},
                               headers=HOST)
        assert r.status_code == 200, r.text
        # 未收尾的板主持人也刪不掉；收尾（結局）後才行
        r = await client.delete(f"/api/boards/{bid}", headers=HOST)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "board_not_settled"
        await _settle_directly(app, bid)
        r = await client.delete(f"/api/boards/{bid}", headers=HOST,
                                params={"reason": "不需要的板"})
        assert r.status_code == 200, r.text
        # 板刪掉之後通知仍在，名稱用快照
        gone = await _mine(client, kind_prefix="host_board_deleted")
        assert len(gone) == 1
        assert gone[0]["board_name"] == "新板名"
        assert gone[0]["reason"] == "不需要的板"
        changed = await _mine(client, kind_prefix="host_board_updated")
        assert changed and changed[0]["reason"] == "改名"
