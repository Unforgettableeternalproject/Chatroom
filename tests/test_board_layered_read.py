"""任務板的分層讀取：週期清單 → 週期綱要 → 單一項目詳細。

起因：新進 agent 一讀整塊板就被炸滿。分層端點是**新增**的，釘四件事：

1. 週期清單：最近修改的在前，「未分類」頁看得出來（kind='inbox'、page_no）
2. 綱要只有精簡欄位（沒有 description）；不指定週期＝最近修改的那個
3. 項目詳細才有描述／素材／事件
4. 既有的 `GET /api/boards/{id}` 預設回應**沒變**（App 是它的客戶端）
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = {"X-Session-Key": "human-1"}
STRANGER = {"X-Session-Key": "stranger-9"}


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _setup(client):
    """一塊板：週期 A（較早建、較早動）、週期 B（後建）、一頁「未分類」。

    之後對 A 的卡再改一次，A 就成為「最近修改」——只看建立順序的話會選到
    B 或未分類頁。
    """
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    pid = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})).json()["participant_id"]
    me = {**OWNER, "X-Participant-Id": pid}
    bid = (await client.post("/api/boards", headers=OWNER,
                             json={"name": "板"})).json()["id"]
    await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)

    ids = {}
    ids["a"] = (await client.post(f"/api/boards/{bid}/objectives",
                                  headers=OWNER,
                                  json={"title": "週期 A"})).json()["id"]
    ids["a_stage"] = (await client.post(
        f"/api/board/objectives/{ids['a']}/checklists", headers=OWNER,
        json={"title": "A 階段"})).json()["id"]
    ids["a_task"] = (await client.post(
        f"/api/board/checklists/{ids['a_stage']}/tasks", headers=OWNER,
        json={"title": "A 的卡", "description": "很長的描述" * 20})).json()["id"]
    ids["b"] = (await client.post(f"/api/boards/{bid}/objectives",
                                  headers=OWNER,
                                  json={"title": "週期 B"})).json()["id"]
    ids["b_stage"] = (await client.post(
        f"/api/board/objectives/{ids['b']}/checklists", headers=OWNER,
        json={"title": "B 階段"})).json()["id"]
    await client.post(f"/api/board/checklists/{ids['b_stage']}/tasks",
                      headers=OWNER, json={"title": "B 的卡"})
    # 隨手記一張 → 長出「未分類」頁
    await client.post(f"/api/boards/{bid}/tasks", headers=OWNER,
                      json={"title": "隨手記"})
    # 最後動 A 的卡：A 成為最近修改
    r = await client.post(f"/api/board/tasks/{ids['a_task']}/status",
                          headers=OWNER, json={"status": "in_progress"})
    assert r.status_code == 200, r.text
    return bid, rid, me, ids


async def test_cycles_are_listed_most_recently_modified_first(tmp_path):
    app, client = await _client(tmp_path, "cycles")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        r = await client.get(f"/api/boards/{bid}/cycles", headers=OWNER)
        assert r.status_code == 200, r.text
        body = r.json()
        cycles = body["cycles"]
        assert body["cycles_total"] == 3
        assert cycles[0]["id"] == ids["a"], "最後被動過的週期要排第一"
        seqs = [c["last_modified_seq"] for c in cycles]
        assert seqs == sorted(seqs, reverse=True)
        inbox = [c for c in cycles if c["is_inbox"]]
        assert len(inbox) == 1
        assert inbox[0]["kind"] == "inbox" and inbox[0]["page_no"] >= 1
        a = cycles[0]
        assert a["task_counts"]["in_progress"] == 1
        assert a["task_counts"]["total"] == 1
        assert a["stage_count"] == 1
        # 清單不帶子項
        assert "tasks" not in a and "checklists" not in a


async def test_cycles_limit_reports_truncation(tmp_path):
    app, client = await _client(tmp_path, "cycles-limit")
    async with app.router.lifespan_context(app), client:
        bid, _, _, _ = await _setup(client)
        body = (await client.get(f"/api/boards/{bid}/cycles?limit=1",
                                 headers=OWNER)).json()
        assert len(body["cycles"]) == 1
        assert body["truncated"] is True and body["cycles_total"] == 3


async def test_outline_defaults_to_the_latest_cycle_without_descriptions(
        tmp_path):
    app, client = await _client(tmp_path, "outline")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        body = (await client.get(f"/api/boards/{bid}/outline",
                                 headers=OWNER)).json()
        assert body["view"] == "outline" and body["is_latest"] is True
        assert body["cycle"]["id"] == ids["a"]
        assert [c["id"] for c in body["checklists"]] == [ids["a_stage"]]
        assert [t["id"] for t in body["tasks"]] == [ids["a_task"]]
        task = body["tasks"][0]
        assert task["status"] == "in_progress"
        # 精簡：沒有描述本文，只有長度（讓讀的人知道值不值得展開）
        assert "description" not in task
        assert task["description_chars"] > 0
        assert body["board_seq"] > 0 and body["board_id"] == bid
        # 別的週期的東西不在裡面
        assert ids["b"] not in repr(body["cycle"]) + repr(body["checklists"])


async def test_outline_for_a_chosen_cycle(tmp_path):
    app, client = await _client(tmp_path, "outline-pick")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        body = (await client.get(
            f"/api/boards/{bid}/outline?objective_id={ids['b']}",
            headers=OWNER)).json()
        assert body["cycle"]["id"] == ids["b"]
        assert body["is_latest"] is False
        assert [c["id"] for c in body["checklists"]] == [ids["b_stage"]]


async def test_outline_wrong_id_and_wrong_layer(tmp_path):
    app, client = await _client(tmp_path, "outline-bad")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        r = await client.get(f"/api/boards/{bid}/outline?objective_id=nope",
                             headers=OWNER)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "objective_not_found"
        r = await client.get(
            f"/api/boards/{bid}/outline?objective_id={ids['a_stage']}",
            headers=OWNER)
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "board_item_wrong_kind"


async def test_item_detail_has_description_files_and_events(tmp_path):
    app, client = await _client(tmp_path, "item")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        r = await client.get(f"/api/boards/{bid}/items/{ids['a_task']}",
                             headers=OWNER)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["kind"] == "task"
        assert body["item"]["description"].startswith("很長的描述")
        assert body["stage"]["id"] == ids["a_stage"]
        assert body["objective"]["id"] == ids["a"]
        assert body["files"] == []
        types = [e["event_type"] for e in body["events"]]
        assert types, "這張卡動過，應該有事件"
        assert all(e["board_seq"] for e in body["events"])

        stage = (await client.get(f"/api/boards/{bid}/items/{ids['a_stage']}",
                                  headers=OWNER)).json()
        assert stage["kind"] == "checklist"
        assert [t["id"] for t in stage["tasks"]] == [ids["a_task"]]
        assert "description" not in stage["tasks"][0]

        cycle = (await client.get(f"/api/boards/{bid}/items/{ids['a']}",
                                  headers=OWNER)).json()
        assert cycle["kind"] == "objective"


async def test_item_from_another_board_is_not_reachable(tmp_path):
    app, client = await _client(tmp_path, "item-cross")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        other = (await client.post("/api/boards", headers=OWNER,
                                   json={"name": "另一塊"})).json()["id"]
        r = await client.get(f"/api/boards/{other}/items/{ids['a_task']}",
                             headers=OWNER)
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "item_not_found"


async def test_a_non_member_is_refused(tmp_path):
    """分層端點的門檻與完整讀取相同：不是成員就是 403。"""
    app, client = await _client(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        # 板是公開的，但陌生人不在任何掛接房裡 → 沒有成員資格
        for path in (f"/api/boards/{bid}/cycles", f"/api/boards/{bid}/outline",
                     f"/api/boards/{bid}/items/{ids['a_task']}"):
            r = await client.get(path, headers=STRANGER)
            assert r.status_code == 403, (path, r.text)
            assert r.json()["detail"]["code"] == "not_board_member"


async def test_room_axis_serves_the_same_layers(tmp_path):
    app, client = await _client(tmp_path, "room-axis")
    async with app.router.lifespan_context(app), client:
        bid, rid, me, ids = await _setup(client)
        cycles = (await client.get(f"/api/rooms/{rid}/board/cycles",
                                   headers=me)).json()
        assert cycles["board_id"] == bid
        assert cycles["cycles"][0]["id"] == ids["a"]
        out = (await client.get(f"/api/rooms/{rid}/board/outline",
                                headers=me)).json()
        assert out["cycle"]["id"] == ids["a"]
        assert out["board_id"] == bid and out["board_seq"] > 0
        assert "attached_rooms" in out and "reclaimable_tasks" in out
        item = (await client.get(
            f"/api/rooms/{rid}/board/items/{ids['a_task']}",
            headers=me)).json()
        assert item["item"]["description"].startswith("很長的描述")


async def test_the_existing_read_default_is_untouched(tmp_path):
    """⚠️ App 讀的是這兩支：預設回應仍是完整內容（描述在、不分層）。"""
    app, client = await _client(tmp_path, "unchanged")
    async with app.router.lifespan_context(app), client:
        bid, rid, me, ids = await _setup(client)
        v2 = (await client.get(f"/api/boards/{bid}", headers=OWNER)).json()
        task = next(t for t in v2["tasks"] if t["id"] == ids["a_task"])
        assert task["description"].startswith("很長的描述")
        assert "view" not in v2
        v1 = (await client.get(f"/api/rooms/{rid}/board", headers=me)).json()
        task = next(t for t in v1["tasks"] if t["id"] == ids["a_task"])
        assert task["description"].startswith("很長的描述")
        assert "view" not in v1


async def test_moved_destination_is_stored_and_can_be_filled_in_later(tmp_path):
    """agent 推 moved 要能設去向；先沒給、之後補也行（不必人類打回重推）。"""
    app, client = await _client(tmp_path, "moved-to")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        dest = (await client.post(
            f"/api/board/checklists/{ids['b_stage']}/tasks", headers=OWNER,
            json={"title": "新卡"})).json()["id"]
        url = f"/api/board/tasks/{ids['a_task']}/status"
        r = await client.post(url, headers=OWNER, json={"status": "moved"})
        assert r.status_code == 200, r.text
        item = (await client.get(f"/api/boards/{bid}/items/{ids['a_task']}",
                                 headers=OWNER)).json()["item"]
        assert item["status"] == "moved" and item["moved_to"] == ""
        r = await client.post(url, headers=OWNER,
                              json={"status": "moved", "moved_to": dest})
        assert r.status_code == 200 and not r.json().get("unchanged"), r.text
        item = (await client.get(f"/api/boards/{bid}/items/{ids['a_task']}",
                                 headers=OWNER)).json()["item"]
        assert item["moved_to"] == dest
        r = await client.post(url, headers=OWNER, json={
            "status": "moved", "moved_to": "nope"})
        assert r.status_code == 404


async def _send_directive(client, bid, text, target=""):
    r = await client.post(f"/api/boards/{bid}/directives", headers=OWNER,
                          json={"target_actor_key": target, "text": text})
    assert r.status_code == 200, r.text


async def test_outline_carries_existing_directives_on_both_axes(tmp_path):
    """首讀回綱要並把水位推到 board_seq——板上既有的 Supervisor 指示若不在
    綱要裡，之後的增量讀取（只回水位之後）就永遠漏掉它們。"""
    app, client = await _client(tmp_path, "outline_directives")
    async with app.router.lifespan_context(app), client:
        bid, rid, me, _ = await _setup(client)
        await _send_directive(client, bid, "先修漏掉的查詢")
        await _send_directive(client, bid, "再補測試")

        for path, headers in ((f"/api/boards/{bid}/outline", OWNER),
                              (f"/api/rooms/{rid}/board/outline", me)):
            r = await client.get(path, headers=headers)
            assert r.status_code == 200, r.text
            body = r.json()
            assert [d["text"] for d in body["directives"]] == [
                "先修漏掉的查詢", "再補測試"], path
            assert body["directives_has_more"] is False


async def test_directives_in_outline_are_not_repeated_incrementally(tmp_path):
    app, client = await _client(tmp_path, "outline_directives_inc")
    async with app.router.lifespan_context(app), client:
        bid, _, _, _ = await _setup(client)
        await _send_directive(client, bid, "舊指示")
        outline = (await client.get(f"/api/boards/{bid}/outline",
                                    headers=OWNER)).json()
        seq = outline["board_seq"]
        assert [d["text"] for d in outline["directives"]] == ["舊指示"]

        inc = (await client.get(f"/api/boards/{bid}", headers=OWNER,
                                params={"after_board_seq": seq})).json()
        assert inc["directives"] == []

        await _send_directive(client, bid, "新指示")
        inc = (await client.get(f"/api/boards/{bid}", headers=OWNER,
                                params={"after_board_seq": seq})).json()
        assert [d["text"] for d in inc["directives"]] == ["新指示"]


async def test_outline_directives_follow_the_full_read_cap(tmp_path):
    """上限與全量讀取同一條：最近 50 筆、由舊到新，`directives_has_more`。"""
    app, client = await _client(tmp_path, "outline_directives_cap")
    async with app.router.lifespan_context(app), client:
        bid, _, _, _ = await _setup(client)
        for i in range(51):
            await _send_directive(client, bid, f"指示 {i}")
        body = (await client.get(f"/api/boards/{bid}/outline",
                                 headers=OWNER)).json()
        full = (await client.get(f"/api/boards/{bid}", headers=OWNER)).json()
        assert len(body["directives"]) == 50
        assert body["directives_has_more"] is True
        assert body["directives"][0]["text"] == "指示 1"
        assert body["directives"] == full["directives"]


async def test_room_axis_full_read_carries_directives_by_watermark(tmp_path):
    """房軸完整讀取原本完全不回 directives：首讀之後新增的指示，增量讀取
    也拿不到。規則與板軸一致（水位之後、最近 50 筆）。"""
    app, client = await _client(tmp_path, "room_axis_directives")
    async with app.router.lifespan_context(app), client:
        bid, rid, me, _ = await _setup(client)
        await _send_directive(client, bid, "舊指示")
        full = (await client.get(f"/api/rooms/{rid}/board", headers=me)).json()
        assert [d["text"] for d in full["directives"]] == ["舊指示"]
        assert full["directives_has_more"] is False
        seq = full["board_seq"]

        inc = (await client.get(f"/api/rooms/{rid}/board", headers=me,
                                params={"after_board_seq": seq})).json()
        assert inc["directives"] == []

        await _send_directive(client, bid, "新指示")
        inc = (await client.get(f"/api/rooms/{rid}/board", headers=me,
                                params={"after_board_seq": seq})).json()
        assert [d["text"] for d in inc["directives"]] == ["新指示"]


async def test_room_without_board_has_no_directives(tmp_path):
    app, client = await _client(tmp_path, "room_axis_no_board")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "空房", "session_key": "human-1"})).json()["id"]
        pid = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "Bernie"})).json()["participant_id"]
        body = (await client.get(f"/api/rooms/{rid}/board", headers={
            **OWNER, "X-Participant-Id": pid})).json()
        assert body["directives"] == [] and body["directives_has_more"] is False
