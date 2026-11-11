"""通知中心（統一收件匣，艾斯維爾 2026-11-11）。

收件人規則是這份檔案的核心，每一條都要「收得到」與「不該收到」兩半一起驗：
少了後一半，「通知所有人」的實作也會通過。

- (a) 追蹤任務：追蹤者（含 agent）收到完成／取消／重開
- (b) 他人（人類）改你建立的任務板物件、在你的階段動素材與派工
- (c) 他人在你建立的想法板留言或切換狀態
- (d) 主持人操作你的東西 → `host_*`，見 `test_host_override_*.py`
- (e) 派工房 run 終局 → 所有涉及該階段的人類
- 一律排除觸發者本人與 agent；agent／派工 run 的修改不算「他人動到你的內容」
"""

import json
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.testclient import TestClient

from chatroom_server import db as dbmod
from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN_TOKEN = "human-token"
HOST = {"X-Host-View": "1", "X-Session-Key": "host-device"}


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 **cfg_kw)
    app = create_app(cfg)
    app.hub_path = cfg.db_path
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, key, name, role="human"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _inbox(client, key, **params):
    r = await client.get("/api/notifications", params=params,
                         headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text
    return r.json()


async def _kinds(client, key, **params):
    return [x["kind"] for x in (await _inbox(client, key, **params))[
        "notifications"] if not x["for_host"]]


async def _tree(client, creator_key="h-a", creator_name="甲"):
    """甲（人類）建週期並成為板 owner；乙（人類成員）建階段與卡；機器人同房。

    改別人建的卡要有資格（板 owner／supervisor／建立者），所以「他人改你建立
    的東西」在這裡的形狀是：甲（owner）改乙建的階段與卡 → 乙收到通知。
    """
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": creator_key})).json()["id"]
    a = await _join(client, rid, creator_key, creator_name)
    b = await _join(client, rid, "h-b", "乙")
    bot = await _join(client, rid, "agent-1", "機器人", role="agent")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"}, headers=a)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段"}, headers=b)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "任務"}, headers=b)).json()["id"]
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=a)).json()["board_id"]
    return rid, bid, oid, cid, tid, a, b, bot


# ── (b) 他人改你建立的物件 ────────────────────────────────────────────

async def test_b_others_edits_reach_the_creator_but_not_self_nor_agents(tmp_path):
    app, client = await _client(tmp_path, "b")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)

        # 自己改自己的：沒有通知
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "自改"},
                           headers=b)
        assert await _kinds(client, "h-b") == []

        # 甲（人類、板 owner）改乙建立的卡與階段
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "甲改"},
                           headers=a)
        await client.patch(f"/api/board/checklists/{cid}",
                           json={"title": "甲改階段"}, headers=a)
        got = (await _inbox(client, "h-b"))["notifications"]
        by_item = {x["item_kind"]: x for x in got}
        assert set(by_item) == {"task", "checklist"}
        t = by_item["task"]
        assert t["kind"] == "item_updated"
        assert t["actor_name"] == "甲" and t["actor_kind"] == "human"
        # 來源房／板（id 與當下名稱）一律要帶
        assert t["room_id"] == rid and t["room_name"] == "房"
        assert t["board_id"] == bid and t["board_name"]
        assert t["item_title"] == "甲改"
        assert t["for_host"] is False
        assert "甲" in t["summary"] and "任務" in t["summary"]
        # 甲自己不收
        assert await _kinds(client, "h-a") == []

        # 狀態變更、指派、刪除各自成一類
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "in_progress"}, headers=a)
        r = await client.post(f"/api/board/tasks/{tid}/assign",
                              json={"target_session_key": "agent-1"},
                              headers=a)
        assert r.status_code == 200 and r.json()["assigned"] is True, r.text
        await client.delete(f"/api/board/tasks/{tid}", headers=a)
        kinds = set(await _kinds(client, "h-b"))
        assert {"item_updated", "item_status", "item_assigned",
                "item_deleted"} <= kinds
        st = [x for x in (await _inbox(client, "h-b"))["notifications"]
              if x["kind"] == "item_status"][0]
        assert "進行中" in st["summary"]
        assert await _kinds(client, "h-a") == []


async def test_b_agent_edits_do_not_count_and_agent_creators_are_not_recipients(tmp_path):
    app, client = await _client(tmp_path, "b-agent")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        # agent 認領並推進乙的卡：不是「他人（人類）動到你的內容」
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=bot)
        assert r.status_code == 200, r.text
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "in_progress"}, headers=bot)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=bot)
        assert await _kinds(client, "h-b") == [], (
            "agent 的修改被當成通知了——派工完成通知才是它的出口")

        # agent 建的卡，人類去改：agent 不是通知收件人
        atid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                  json={"title": "機器人的卡"},
                                  headers=bot)).json()["id"]
        r = await client.patch(f"/api/board/tasks/{atid}",
                               json={"title": "人類改了"}, headers=a)
        assert r.status_code == 200, r.text
        assert await _kinds(client, "agent-1") == []


async def test_b_stage_material_and_dispatch_notify_the_stage_creator(tmp_path):
    app, client = await _client(tmp_path, "b-stage")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        aid = (await client.post(
            f"/api/rooms/{rid}/attachments",
            files={"file": ("a.png", b"img", "image/png")},
            headers={"X-Participant-Id": a["X-Participant-Id"]})).json()["id"]
        url = f"/api/boards/{bid}/checklists/{cid}/files"
        fid = (await client.post(url, json={"attachment_id": aid, "note": "圖"},
                                 headers=a)).json()["file"]["id"]
        await client.patch(f"{url}/{fid}", json={"note": "新"}, headers=a)
        await client.delete(f"{url}/{fid}", headers=a)
        # 階段是乙建的 → 乙收到；動手的甲自己不收
        assert await _kinds(client, "h-a") == []
        kinds = await _kinds(client, "h-b")
        assert {"stage_file_added", "stage_file_noted",
                "stage_file_removed"} <= set(kinds)
        # 素材操作也留了 canonical event（補上之前沒有）
        events = await (await app.state.db.execute(
            "SELECT event_type FROM board_event WHERE event_type LIKE"
            " 'stage_file_%' ORDER BY board_seq")).fetchall()
        assert [e["event_type"] for e in events] == [
            "stage_file_added", "stage_file_noted", "stage_file_removed"]


# ── (c) 想法板 ────────────────────────────────────────────────────────

async def test_c_scratchpad_activity_reaches_the_pad_creator(tmp_path):
    app, client = await _client(tmp_path, "c")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        body = (await client.post(f"/api/boards/{bid}/scratchpads", json={
            "title": "想法", "content": "第一段"}, headers=b)).json()
        pid, bkid = body["id"], body["first_block_id"]
        base = f"/api/boards/{bid}/scratchpads/{pid}"

        # 自己在自己的想法板留言：沒有通知
        await client.post(f"{base}/blocks/{bkid}/notes",
                          json={"content": "自言自語"}, headers=b)
        assert await _kinds(client, "h-b") == []
        # agent 留言：不算
        await client.post(f"{base}/blocks/{bkid}/notes",
                          json={"content": "bot 的意見"}, headers=bot)
        assert await _kinds(client, "h-b") == []

        # 甲留言、新增段落、切換狀態
        await client.post(f"{base}/blocks/{bkid}/notes",
                          json={"content": "甲的意見"}, headers=a)
        await client.post(f"{base}/blocks", json={"content": "新段"},
                          headers=a)
        r = await client.put(f"{base}/blocks/{bkid}", headers=a,
                             json={"content": "第一段", "rev": 1,
                                   "state": "implemented"})
        assert r.status_code == 200, r.text
        got = (await _inbox(client, "h-b"))["notifications"]
        kinds = {x["kind"] for x in got}
        assert {"scratchpad_note", "scratchpad_block",
                "scratchpad_state"} <= kinds
        n = [x for x in got if x["kind"] == "scratchpad_note"][0]
        assert n["item_kind"] == "scratchpad" and n["item_title"] == "想法"
        assert n["board_id"] == bid and n["actor_name"] == "甲"
        assert "想法" in n["summary"]
        assert await _kinds(client, "h-a") == []


# ── (a) 追蹤 ──────────────────────────────────────────────────────────

async def test_a_watch_notices_live_in_the_new_inbox_and_the_legacy_endpoint(tmp_path):
    app, client = await _client(tmp_path, "a")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        await client.post(f"/api/boards/{bid}/members", headers=a, json={
            "actor_key": "agent-1", "role": "editor", "display_name": "機器人",
            "actor_kind": "claude"})
        r = await client.post(f"/api/boards/{bid}/watches", headers=bot,
                              json={"item_kind": "task", "item_id": tid})
        assert r.status_code == 200, r.text
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=a)

        # 新 API：追蹤者（agent 也算）收到，kind 是原本的 event_type
        got = (await _inbox(client, "agent-1"))["notifications"]
        assert [x["kind"] for x in got] == ["task_done"]
        assert got[0]["actor_name"] == "甲" and got[0]["item_title"] == "任務"
        assert got[0]["room_id"] == rid and got[0]["board_id"] == bid
        assert "追蹤" in got[0]["summary"]
        # 相容端點：同一筆，欄位維持舊形狀
        old = (await client.get("/api/board/notices",
                                headers={"X-Session-Key": "agent-1"})).json()
        assert old["unread_count"] == 1
        n = old["notices"][0]
        assert n["event_type"] == "task_done" and n["board_seq"] > 0
        assert n["board_name"]
        # 相容端點標已讀 ⇒ 新 API 的未讀數同步歸零
        r = await client.post("/api/board/notices/read?all_notices=true",
                              headers={"X-Session-Key": "agent-1"})
        assert r.json()["marked"] == 1
        assert (await _inbox(client, "agent-1"))["unread_count"] == 0
        # 完成者自己不收
        assert "task_done" not in await _kinds(client, "h-a")


# ── (e) 派工房 run 終局 ───────────────────────────────────────────────

async def _runner(client):
    r = await client.post("/api/runners/register", json={
        "host": "pc", "label": "ex1", "projects": ["ai-website"],
        "max_parallel": 3, "version": "0.1"})
    body = r.json()
    return body["runner"]["id"], {"X-Runner-Token": body["runner_token"]}


async def _ops_stage(client, app):
    """甲建週期、乙建階段、丙在階段裡加卡、機器人也加一張卡。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "kind": "ops", "session_key": "h-a"})).json()["id"]
    await app.state.db.execute(
        "UPDATE room SET workspace_key='ai-website' WHERE id=?", (rid,))
    await app.state.db.commit()
    a = await _join(client, rid, "h-a", "甲")
    b = await _join(client, rid, "h-b", "乙")
    c = await _join(client, rid, "h-c", "丙")
    d = await _join(client, rid, "h-d", "丁（無關）")
    bot = await _join(client, rid, "agent-1", "機器人", role="agent")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"}, headers=a)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段"}, headers=b)).json()["id"]
    await client.post(f"/api/board/checklists/{cid}/tasks",
                      json={"title": "丙的卡"}, headers=c)
    await client.post(f"/api/board/checklists/{cid}/tasks",
                      json={"title": "機器人的卡"}, headers=bot)
    return rid, cid, a, b, c, d, bot


async def _finish(client, rid, cid, a, runner, status, reason=""):
    run_id = (await client.post(f"/api/rooms/{rid}/runs", json={
        "kind": "stage", "project": "ai-website", "ref": cid,
        "brief": "做"}, headers=a)).json()["run"]["id"]
    rid_, hdr = runner
    await client.post(f"/api/runners/{rid_}/claim", headers=hdr)
    await client.post(f"/api/runs/{run_id}/report", headers=hdr,
                      json={"status": "running", "runner_id": rid_})
    body = {"status": status, "runner_id": rid_}
    if reason:
        body["reason"] = reason
    r = await client.post(f"/api/runs/{run_id}/report", headers=hdr, json=body)
    assert r.status_code == 200, r.text
    return run_id


async def test_e_run_done_notifies_everyone_involved_in_the_stage(tmp_path):
    app, client = await _client(tmp_path, "e")
    async with app.router.lifespan_context(app), client:
        rid, cid, a, b, c, d, bot = await _ops_stage(client, app)
        runner = await _runner(client)
        # 甲在乙的階段派工 → 乙（階段建立者）收到 stage_dispatch
        await _finish(client, rid, cid, a, runner, "done")

        # 涉及的人類：階段建立者乙、加卡的丙、派工的甲
        for key in ("h-a", "h-b", "h-c"):
            ks = await _kinds(client, key)
            assert "run_done" in ks, (key, ks)
        # 不該收到：無關的丁、agent
        assert await _kinds(client, "h-d") == []
        assert await _kinds(client, "agent-1") == []
        n = [x for x in (await _inbox(client, "h-b"))["notifications"]
             if x["kind"] == "run_done"][0]
        assert n["item_kind"] == "checklist" and n["item_title"] == "階段"
        assert n["room_id"] == rid and n["board_id"]
        assert n["actor_kind"] == "system"
        assert "完成" in n["summary"]
        # 派工本身（情境 b）：乙是階段建立者，甲派工 → stage_dispatch
        assert "stage_dispatch" in await _kinds(client, "h-b")
        assert "stage_dispatch" not in await _kinds(client, "h-a")


async def test_e_failed_and_cancelled_runs_are_told_apart(tmp_path):
    app, client = await _client(tmp_path, "e-fail")
    async with app.router.lifespan_context(app), client:
        rid, cid, a, b, c, d, bot = await _ops_stage(client, app)
        runner = await _runner(client)
        await _finish(client, rid, cid, a, runner, "failed", "壞了")
        assert "run_failed" in await _kinds(client, "h-c")
        # 取消：排隊中的 run 由人取消
        run_id = (await client.post(f"/api/rooms/{rid}/runs", json={
            "kind": "stage", "project": "ai-website", "ref": cid,
            "brief": "再做"}, headers=a)).json()["run"]["id"]
        r = await client.post(f"/api/runs/{run_id}/cancel", headers=a)
        assert r.status_code == 200, r.text
        ks = await _kinds(client, "h-c")
        assert "run_cancelled" in ks and "run_failed" in ks


async def test_e_chat_rooms_and_non_stage_runs_do_not_notify(tmp_path):
    app, client = await _client(tmp_path, "e-skip")
    async with app.router.lifespan_context(app), client:
        rid, cid, a, b, c, d, bot = await _ops_stage(client, app)
        runner = await _runner(client)
        # push 不涉及階段：略過
        run_id = (await client.post(f"/api/rooms/{rid}/runs", json={
            "kind": "push", "project": "ai-website", "ref": "repo-x",
            "brief": ""}, headers=a)).json().get("run", {}).get("id")
        if run_id:
            rid_, hdr = runner
            await client.post(f"/api/runners/{rid_}/claim", headers=hdr)
            await client.post(f"/api/runs/{run_id}/report", headers=hdr,
                              json={"status": "running", "runner_id": rid_})
            await client.post(f"/api/runs/{run_id}/report", headers=hdr,
                              json={"status": "done", "runner_id": rid_})
        for key in ("h-a", "h-b", "h-c"):
            assert "run_done" not in await _kinds(client, key)


# ── 合併 ──────────────────────────────────────────────────────────────

async def test_same_item_within_five_minutes_merges_into_one_row(tmp_path):
    app, client = await _client(tmp_path, "merge")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        for i in range(3):
            await client.patch(f"/api/board/tasks/{tid}",
                               json={"title": f"甲第{i}次"}, headers=a)
        got = (await _inbox(client, "h-b"))["notifications"]
        assert len(got) == 1
        assert got[0]["count"] == 3
        assert got[0]["item_title"] == "甲第2次"      # 標題換成最新的
        assert "共 3 次" in got[0]["summary"]
        assert (await _inbox(client, "h-b"))["unread_count"] == 1

        # actor 與標題換成最新的：同一個人改別的物件是另一筆，改同一個才合併
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "最新"},
                           headers=a)
        got = (await _inbox(client, "h-b"))["notifications"]
        assert len(got) == 1 and got[0]["count"] == 4
        assert got[0]["item_title"] == "最新"
        await client.patch(f"/api/board/checklists/{cid}",
                           json={"title": "階段改"}, headers=a)
        assert len((await _inbox(client, "h-b"))["notifications"]) == 2

        # 已讀之後不再合併：下一次是新的一筆
        r = await client.post("/api/notifications/read", json={"all": True},
                              headers={"X-Session-Key": "h-b"})
        assert r.json()["unread_count"] == 0
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "又改"},
                           headers=a)
        got = (await _inbox(client, "h-b"))["notifications"]
        assert len(got) == 3

        # 超過五分鐘也不合併
        await app.state.db.execute(
            "UPDATE notification SET updated_at=? WHERE read_at IS NULL",
            ((datetime.now(timezone.utc) - timedelta(minutes=6)).isoformat(),))
        await app.state.db.commit()
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "再改"},
                           headers=a)
        unread = (await _inbox(client, "h-b", unread_only=True))
        assert len(unread["notifications"]) == 2


# ── 保留 ──────────────────────────────────────────────────────────────

async def _insert(db, key, n, read_at=None, created="2026-01-01T00:00:00+00:00"):
    for i in range(n):
        await db.execute(
            "INSERT INTO notification (recipient_key, kind, item_kind, item_id,"
            " created_at, updated_at, read_at) VALUES (?,?,?,?,?,?,?)",
            (key, "item_updated", "task", f"x{i}-{read_at}", created, created,
             read_at))
    await db.commit()


async def test_retention_caps_each_recipient_and_drops_old_read_rows(tmp_path):
    app, client = await _client(tmp_path, "retain")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        db = app.state.db
        now = datetime.now(timezone.utc)
        recent = now.isoformat()
        old = (now - timedelta(days=31)).isoformat()
        await _insert(db, "h-b", 100, read_at=old)       # 已讀超過 30 天
        await _insert(db, "h-b", 450, read_at=recent)    # 已讀、未過期
        await _insert(db, "h-b", 105, read_at=None)      # 未讀
        await _insert(db, "other", 50, read_at=old)      # 別人的不能動
        # 一則真的通知觸發清理
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "觸發"},
                           headers=a)
        rows = await (await db.execute(
            "SELECT read_at IS NULL AS unread, COUNT(*) AS n FROM notification"
            " WHERE recipient_key='h-b' GROUP BY 1")).fetchall()
        counts = {r["unread"]: r["n"] for r in rows}
        total = sum(counts.values())
        assert total <= 500
        # 過期的已讀先被刪光
        assert (await (await db.execute(
            "SELECT COUNT(*) AS n FROM notification WHERE recipient_key='h-b'"
            " AND read_at=?", (old,))).fetchone())["n"] == 0
        # 上限先刪已讀：未讀 105+1 筆全部保留，已讀補到剛好 500
        assert counts[1] == 106
        assert counts[0] == 500 - 106
        # 別人的過期已讀這一輪沒被碰（只清寫入對象），啟動時才清
        assert (await (await db.execute(
            "SELECT COUNT(*) AS n FROM notification WHERE recipient_key="
            "'other'")).fetchone())["n"] == 50


async def test_startup_sweeps_old_read_notifications(tmp_path):
    app, client = await _client(tmp_path, "startup")
    async with app.router.lifespan_context(app), client:
        await _insert(app.state.db, "k", 3,
                      read_at=(datetime.now(timezone.utc)
                               - timedelta(days=40)).isoformat())
        await _insert(app.state.db, "k", 2, read_at=None)
    app2 = create_app(Config(db_path=app.hub_path, api_token=ROOT))
    async with app2.router.lifespan_context(app2):
        n = (await (await app2.state.db.execute(
            "SELECT COUNT(*) AS n FROM notification WHERE recipient_key='k'"
        )).fetchone())["n"]
        assert n == 2


# ── API ───────────────────────────────────────────────────────────────

async def test_list_filters_paginates_and_marks_read(tmp_path):
    app, client = await _client(tmp_path, "api")
    async with app.router.lifespan_context(app), client:
        rid, bid, oid, cid, tid, a, b, bot = await _tree(client)
        # 三種不同的 kind 才不會被合併成一筆
        await client.patch(f"/api/board/tasks/{tid}", json={"title": "x"},
                           headers=a)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "in_progress"}, headers=a)
        await client.patch(f"/api/board/checklists/{cid}",
                           json={"title": "y"}, headers=a)
        full = await _inbox(client, "h-b")
        assert full["unread_count"] == 3
        ids = [n["id"] for n in full["notifications"]]
        assert ids == sorted(ids, reverse=True)
        for key in ("id", "kind", "room_id", "room_name", "board_id",
                    "board_name", "item_kind", "item_id", "item_title",
                    "actor_name", "actor_kind", "reason", "summary", "count",
                    "created_at", "read_at", "for_host"):
            assert key in full["notifications"][0], key

        # limit + before_id 翻頁
        p1 = await _inbox(client, "h-b", limit=2)
        assert [n["id"] for n in p1["notifications"]] == ids[:2]
        p2 = await _inbox(client, "h-b", limit=2, before_id=ids[1])
        assert [n["id"] for n in p2["notifications"]] == ids[2:]
        assert p2["unread_count"] == 3     # 未讀數不受分頁影響

        # 標已讀：只動自己的
        r = await client.post("/api/notifications/read", json={"ids": [ids[0]]},
                              headers={"X-Session-Key": "h-b"})
        assert r.json() == {"ok": True, "marked": 1, "unread_count": 2}
        r = await client.post("/api/notifications/read", json={"ids": ids},
                              headers={"X-Session-Key": "h-a"})
        assert r.json()["marked"] == 0, "別人的通知被標已讀了"
        assert (await _inbox(client, "h-b"))["unread_count"] == 2
        only = await _inbox(client, "h-b", unread_only=True)
        assert ids[0] not in [n["id"] for n in only["notifications"]]
        assert (await client.post("/api/notifications/read", json={},
                                  headers={"X-Session-Key": "h-b"})
                ).status_code == 400
        r = await client.post("/api/notifications/read", json={"all": True},
                              headers={"X-Session-Key": "h-b"})
        assert r.json()["unread_count"] == 0


async def test_host_inbox_is_merged_only_for_human_credentials(tmp_path):
    app, client = await _client(tmp_path, "hostinbox",
                                human_api_token=HUMAN_TOKEN)
    human = {"Authorization": f"Bearer {HUMAN_TOKEN}"}
    async with app.router.lifespan_context(app), client:
        # 房由人類憑證建（role=human 需要人類憑證）
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "h-a"}, headers=human)).json()["id"]
        await client.post(f"/api/rooms/{rid}/join", headers=human, json={
            "kind": "human", "role": "human", "session_key": "h-a",
            "preferred_name": "甲"})
        r = await client.post(f"/api/rooms/{rid}/archive",
                              headers={**human, **HOST},
                              json={"reason": "停"})
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/rooms/{rid}/unarchive", headers={
            **human, "X-Session-Key": "h-a"}, json={"reason": "好了"})
        assert r.status_code == 200, r.text

        # 任何持人類憑證的連線都讀得到，不論有沒有開主持人模式
        mine = await client.get("/api/notifications", headers={
            **human, "X-Session-Key": "other-device"})
        assert mine.status_code == 200, mine.text
        hit = [n for n in mine.json()["notifications"] if n["for_host"]]
        assert len(hit) == 1 and hit[0]["kind"] == "room_unarchived_by_creator"
        assert mine.json()["unread_count"] == 1
        # 只持 agent 憑證（ROOT 在分離期降級為 agent）：看不到
        agent = await client.get("/api/notifications", headers={
            "X-Session-Key": "other-device"})
        assert [n for n in agent.json()["notifications"]
                if n["for_host"]] == []
        # 已讀也對 host 收件匣生效
        r = await client.post("/api/notifications/read", json={"all": True},
                              headers={**human, "X-Session-Key": "other-device"})
        assert r.json()["marked"] == 1
        assert (await client.get("/api/notifications", headers={
            **human, "X-Session-Key": "other-device"})).json()[
                "unread_count"] == 0


# ── WS ────────────────────────────────────────────────────────────────

def _next_inbox(ws, tries=6):
    for _ in range(tries):
        msg = json.loads(ws.receive_text())
        if msg.get("type") == "inbox":
            return msg
    return None


def test_ws_inbox_pushes_on_new_notification_and_on_read(tmp_path):
    cfg = Config(db_path=str(tmp_path / "ws.db"), api_token=ROOT)
    app = create_app(cfg)
    auth = {"Authorization": f"Bearer {ROOT}"}
    with TestClient(app) as tc:
        rid = tc.post("/api/rooms", json={"name": "房", "session_key": "h-a"},
                      headers=auth).json()["id"]
        def join(key, name):
            r = tc.post(f"/api/rooms/{rid}/join", headers=auth, json={
                "kind": "human", "role": "human", "session_key": key,
                "preferred_name": name})
            return {"X-Participant-Id": r.json()["participant_id"],
                    "X-Session-Key": key, **auth}
        a, b = join("h-a", "甲"), join("h-b", "乙")
        oid = tc.post(f"/api/rooms/{rid}/board/objectives", json={
            "title": "週期"}, headers=a).json()["id"]
        cid = tc.post(f"/api/board/objectives/{oid}/checklists", json={
            "title": "階段"}, headers=a).json()["id"]
        tid = tc.post(f"/api/board/checklists/{cid}/tasks", json={
            "title": "任務"}, headers=b).json()["id"]

        with tc.websocket_connect(
                f"/ws/inbox?token={ROOT}&session_key=h-b") as ws:
            first = _next_inbox(ws)
            assert first == {"type": "inbox", "unread_count": 0,
                             "latest_id": None}
            tc.patch(f"/api/board/tasks/{tid}", json={"title": "甲改"},
                     headers=a)
            msg = _next_inbox(ws)
            assert msg["type"] == "inbox" and msg["unread_count"] == 1
            assert msg["latest_id"] is not None
            # 已讀變動也推
            tc.post("/api/notifications/read", json={"all": True},
                    headers={"X-Session-Key": "h-b", **auth})
            msg2 = _next_inbox(ws)
            assert msg2["unread_count"] == 0
            ws.send_text(json.dumps({"type": "ping"}))
            assert json.loads(ws.receive_text()) == {"type": "pong"}

        # 別人的收件匣不會推給甲
        with tc.websocket_connect(
                f"/ws/inbox?token={ROOT}&session_key=h-a") as wsb:
            assert _next_inbox(wsb)["unread_count"] == 0


def test_ws_inbox_rejects_bad_token_and_missing_identity(tmp_path):
    cfg = Config(db_path=str(tmp_path / "ws2.db"), api_token=ROOT,
                 human_api_token=HUMAN_TOKEN)
    app = create_app(cfg)
    with TestClient(app) as tc:
        for query in ("token=wrong&session_key=x",
                      # 沒有 session_key、也沒有主持人資格（agent 憑證）
                      f"token={ROOT}"):
            with pytest.raises(Exception):
                with tc.websocket_connect(f"/ws/inbox?{query}") as ws:
                    ws.receive_text()
        # 人類憑證即使沒有 session_key 也能訂主持人收件匣
        with tc.websocket_connect(f"/ws/inbox?token={HUMAN_TOKEN}") as ws:
            assert _next_inbox(ws)["unread_count"] == 0


# ── 遷移 ──────────────────────────────────────────────────────────────

async def test_migration_moves_old_watch_notices_once(tmp_path):
    path = str(tmp_path / "mig.db")
    db = await dbmod.open_db(path)
    await db.execute("PRAGMA foreign_keys=OFF")
    await db.execute(
        "INSERT INTO board (id, name, owner_actor_key, created_at, updated_at)"
        " VALUES ('b1','板','o','2026-01-01','2026-01-01')")
    await db.execute(
        "INSERT INTO board_watch_notice (id, board_id, actor_key, item_kind,"
        " item_id, item_title, event_type, board_seq, actor_name, created_at,"
        " read_at) VALUES ('old1','b1','w','task','t1','卡','task_done',7,"
        "'甲','2026-01-02T00:00:00+00:00',NULL)")
    await db.execute("PRAGMA user_version=8")
    await db.commit()
    await dbmod._migrate_data(db)
    await db.commit()
    rows = await (await db.execute(
        "SELECT * FROM notification WHERE recipient_key='w'")).fetchall()
    assert len(rows) == 1
    r = rows[0]
    assert (r["kind"], r["item_title"], r["actor_name"], r["board_id"]) == (
        "task_done", "卡", "甲", "b1")
    assert json.loads(r["payload_json"])["board_seq"] == 7
    assert json.loads(r["payload_json"])["src"] == "watch"
    # 冪等：版次被拉回去再跑一次不會重複
    await db.execute("PRAGMA user_version=8")
    await dbmod._migrate_data(db)
    await db.commit()
    n = (await (await db.execute(
        "SELECT COUNT(*) AS n FROM notification")).fetchone())["n"]
    assert n == 1
    assert (await (await db.execute(
        "PRAGMA user_version")).fetchone())[0] == dbmod.DATA_VERSION
    await db.close()
    # 整個 open_db 流程重跑也不會多出東西
    db2 = await dbmod.open_db(path)
    assert (await (await db2.execute(
        "SELECT COUNT(*) AS n FROM notification")).fetchone())["n"] == 1
    cols = {c["name"] for c in await (await db2.execute(
        "PRAGMA table_info(room)")).fetchall()}
    assert {"archived_by_host", "archive_reason"} <= cols
    await db2.close()
