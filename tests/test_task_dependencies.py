"""任務卡的「依賴」與「影響」。

釘住的規則：

1. 依賴（需要哪些卡先完成才能開始）可在建立／編輯時整份覆寫；「影響」是反向
   查詢，寫入影響＝改寫對方卡的依賴。
2. 不得依賴自己；形成循環回 409 `dependency_cycle`。
3. 依賴未滿足＝「阻擋」（衍生狀態，不改 status）：todo 的卡不能認領、不能推到
   in_progress／done。與 blocked（卡住）不同。
4. 已開始（in_progress）的卡事後多出未滿足的依賴 → Hub 自動改成 blocked 並標
   `blocked_by_dependency`；依賴全滿足時只恢復這一種，人手動設的 blocked 不動。
   依賴造成的 blocked 不能手動推回 in_progress。
5. 依賴卡 done 即滿足；cancelled 也解除（標 cancelled）；moved 跟隨 moved_to。
6. 遷移：舊庫補上 task_dependency 表與 blocked_by_dependency 欄。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import DATA_VERSION, open_db

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = {"X-Session-Key": "human-1"}


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _setup(client):
    """一塊板、一個週期、一個階段；回 (board_id, stage_id)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})
    bid = (await client.post("/api/boards", headers=OWNER,
                             json={"name": "板"})).json()["id"]
    await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
    oid = (await client.post(f"/api/boards/{bid}/objectives", headers=OWNER,
                             json={"title": "週期"})).json()["id"]
    sid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             headers=OWNER,
                             json={"title": "階段"})).json()["id"]
    return bid, sid


async def _task(client, sid, title, **extra):
    r = await client.post(f"/api/board/checklists/{sid}/tasks",
                          headers=OWNER, json={"title": title, **extra})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _status(client, tid, status, **extra):
    return await client.post(f"/api/board/tasks/{tid}/status", headers=OWNER,
                             json={"status": status, **extra})


async def _card(client, bid, tid):
    r = await client.get(f"/api/boards/{bid}/items/{tid}", headers=OWNER)
    assert r.status_code == 200, r.text
    return r.json()["item"]


async def _patch(client, tid, **body):
    return await client.patch(f"/api/board/tasks/{tid}", headers=OWNER,
                              json=body)


def _ids(entries):
    return [e["id"] for e in entries]


async def test_set_dependency_on_create_and_edit_and_read_back(tmp_path):
    app, client = await _client(tmp_path, "set")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B", depends_on=[a])
        card = await _card(client, bid, b)
        assert _ids(card["depends_on"]) == [a]
        assert card["dependency_blocked"] is True
        assert _ids(card["unmet"]) == [a]
        # 「影響」自動推導
        assert _ids((await _card(client, bid, a))["affects"]) == [b]
        # 編輯整份覆寫：換成空清單 → 阻擋解除
        r = await _patch(client, b, depends_on=[])
        assert r.status_code == 200, r.text
        card = await _card(client, bid, b)
        assert card["depends_on"] == [] and card["dependency_blocked"] is False
        assert (await _card(client, bid, a))["affects"] == []
        # 完整讀取與分層綱要也帶
        await _patch(client, b, depends_on=[a])
        full = (await client.get(f"/api/boards/{bid}", headers=OWNER)).json()
        row = next(t for t in full["tasks"] if t["id"] == b)
        assert _ids(row["depends_on"]) == [a] and row["dependency_blocked"]
        out = (await client.get(f"/api/boards/{bid}/outline",
                                headers=OWNER)).json()
        orow = next(t for t in out["tasks"] if t["id"] == b)
        assert orow["depends_on_ids"] == [a]
        assert orow["unmet_ids"] == [a] and orow["dependency_blocked"] is True
        arow = next(t for t in out["tasks"] if t["id"] == a)
        assert arow["affects_ids"] == [b]


async def test_cycle_and_self_dependency_are_rejected(tmp_path):
    app, client = await _client(tmp_path, "cycle")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B", depends_on=[a])
        c = await _task(client, sid, "C", depends_on=[b])
        r = await _patch(client, a, depends_on=[a])
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependency_self"
        r = await _patch(client, a, depends_on=[b])
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependency_cycle"
        # 間接循環 A → C → B → A
        r = await _patch(client, a, depends_on=[c])
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependency_cycle"
        # 用「影響」反向寫也一樣：讓 C 影響 A ＝ A 依賴 C
        r = await _patch(client, c, affects=[a])
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependency_cycle"
        # 被拒的寫入什麼都沒留下
        assert (await _card(client, bid, a))["depends_on"] == []


async def test_dependency_target_must_exist_on_same_board(tmp_path):
    app, client = await _client(tmp_path, "scope")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        bid2, sid2 = await _setup(client)
        a = await _task(client, sid, "A")
        other = await _task(client, sid2, "別板的卡")
        r = await _patch(client, a, depends_on=[other])
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependency_other_board"
        r = await _patch(client, a, depends_on=["no-such-task"])
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "dependency_not_found"


async def test_todo_with_unmet_dependency_cannot_claim_or_start(tmp_path):
    app, client = await _client(tmp_path, "gate")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B", depends_on=[a])
        r = await client.post(f"/api/board/tasks/{b}/claim", headers=OWNER)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependencies_unmet"
        assert _ids(r.json()["detail"]["unmet"]) == [a]
        for target in ("in_progress", "done"):
            r = await _status(client, b, target)
            assert r.status_code == 409, target
            assert r.json()["detail"]["code"] == "dependencies_unmet"
        # status 欄位沒被改寫（阻擋是衍生狀態）
        assert (await _card(client, bid, b))["status"] == "todo"
        # 依賴完成 → 解除阻擋
        assert (await _status(client, a, "done")).status_code == 200
        assert (await _card(client, bid, b))["dependency_blocked"] is False
        r = await client.post(f"/api/board/tasks/{b}/claim", headers=OWNER)
        assert r.status_code == 200, r.text
        assert (await _status(client, b, "in_progress")).status_code == 200


async def test_dependency_added_after_start_auto_blocks_and_auto_resumes(
        tmp_path):
    app, client = await _client(tmp_path, "auto")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B")
        assert (await _status(client, b, "in_progress")).status_code == 200
        seq0 = (await client.get(f"/api/boards/{bid}",
                                 headers=OWNER)).json()["board_seq"]
        r = await _patch(client, b, depends_on=[a])
        assert r.status_code == 200, r.text
        assert r.json()["dependency_changes"][0]["to"] == "blocked"
        card = await _card(client, bid, b)
        assert card["status"] == "blocked"
        assert card["blocked_by_dependency"] is True
        # 不能手動推回進行中
        r = await _status(client, b, "in_progress")
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "dependencies_unmet"
        assert r.json()["detail"]["blocked_by_dependency"] is True
        # 依賴完成 → 自動恢復，旗標清掉
        assert (await _status(client, a, "done")).status_code == 200
        card = await _card(client, bid, b)
        assert card["status"] == "in_progress"
        assert card["blocked_by_dependency"] is False
        # 增量讀取拿得到這張卡的變化（board_seq 有推進）
        inc = (await client.get(f"/api/boards/{bid}?after_board_seq={seq0}",
                                headers=OWNER)).json()
        assert b in [t["id"] for t in inc["tasks"]]
        # 稽核串有自動轉移的 event
        ev = (await client.get(f"/api/boards/{bid}/items/{b}",
                               headers=OWNER)).json()["events"]
        assert "task_dependency_status" in [e["event_type"] for e in ev]


async def test_reopened_dependency_blocks_dependent_again(tmp_path):
    app, client = await _client(tmp_path, "reopen")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B", depends_on=[a])
        await _status(client, a, "done")
        await client.post(f"/api/board/tasks/{b}/claim", headers=OWNER)
        await _status(client, b, "in_progress")
        # A 被打回（人類）→ B 又有未滿足的依賴 → 自動卡住
        assert (await _status(client, a, "in_progress")).status_code == 200
        card = await _card(client, bid, b)
        assert card["status"] == "blocked" and card["blocked_by_dependency"]


async def test_manual_blocked_is_not_auto_resumed(tmp_path):
    app, client = await _client(tmp_path, "manual")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B")
        await _status(client, b, "in_progress")
        await _status(client, b, "blocked")          # 人手動卡住
        await _patch(client, b, depends_on=[a])
        card = await _card(client, bid, b)
        assert card["status"] == "blocked"
        assert card["blocked_by_dependency"] is False
        await _status(client, a, "done")
        card = await _card(client, bid, b)
        assert card["status"] == "blocked", "人手動設的 blocked 不該被自動恢復"


async def test_cancelled_releases_and_moved_follows_target(tmp_path):
    app, client = await _client(tmp_path, "settle")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        m = await _task(client, sid, "M")
        t = await _task(client, sid, "T")
        x = await _task(client, sid, "X", depends_on=[a, m])
        # cancelled：解除，但標示已取消
        assert (await _status(client, a, "cancelled")).status_code == 200
        entry = next(e for e in (await _card(client, bid, x))["depends_on"]
                     if e["id"] == a)
        assert entry["met"] is True and entry["cancelled"] is True
        # moved 沒有 moved_to：視為未滿足
        assert (await _status(client, m, "moved")).status_code == 200
        card = await _card(client, bid, x)
        assert card["dependency_blocked"] is True
        assert _ids(card["unmet"]) == [m]
        # 補上去向 → 跟隨目標卡的狀態（目標還沒完成 → 仍未滿足）
        assert (await _status(client, m, "moved", moved_to=t)).status_code == 200
        card = await _card(client, bid, x)
        assert card["dependency_blocked"] is True
        entry = next(e for e in card["depends_on"] if e["id"] == m)
        assert entry["via"] == t and entry["met"] is False
        # 目標卡完成 → 解除
        assert (await _status(client, t, "done")).status_code == 200
        card = await _card(client, bid, x)
        assert card["dependency_blocked"] is False


async def test_affects_write_rewrites_the_other_cards_dependencies(tmp_path):
    app, client = await _client(tmp_path, "affects")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        b = await _task(client, sid, "B")
        c = await _task(client, sid, "C")
        await _status(client, c, "in_progress")
        # 建立 A 時填「影響」B、C ＝ B、C 依賴 A
        a = await _task(client, sid, "A", affects=[b, c])
        assert _ids((await _card(client, bid, b))["depends_on"]) == [a]
        assert _ids((await _card(client, bid, c))["depends_on"]) == [a]
        assert _ids((await _card(client, bid, a))["affects"]) == [b, c]
        # 已開始的 C 因此被自動卡住
        card_c = await _card(client, bid, c)
        assert card_c["status"] == "blocked" and card_c["blocked_by_dependency"]
        # 編輯整份覆寫：只留 B → C 不再依賴 A，並自動恢復
        r = await _patch(client, a, affects=[b])
        assert r.status_code == 200, r.text
        assert (await _card(client, bid, c))["depends_on"] == []
        card_c = await _card(client, bid, c)
        assert card_c["status"] == "in_progress"
        assert card_c["blocked_by_dependency"] is False
        assert _ids((await _card(client, bid, b))["depends_on"]) == [a]


async def test_deleting_a_dependency_card_releases_dependents(tmp_path):
    app, client = await _client(tmp_path, "delete")
    async with app.router.lifespan_context(app), client:
        bid, sid = await _setup(client)
        a = await _task(client, sid, "A")
        b = await _task(client, sid, "B")
        await _status(client, b, "in_progress")
        await _patch(client, b, depends_on=[a])
        assert (await _card(client, bid, b))["status"] == "blocked"
        r = await client.delete(f"/api/board/tasks/{a}", headers=OWNER)
        assert r.status_code == 200, r.text
        card = await _card(client, bid, b)
        assert card["depends_on"] == []
        assert card["status"] == "in_progress"


async def test_migration_adds_table_and_column_to_old_db(tmp_path):
    path = str(tmp_path / "old.db")
    db = await open_db(path)
    await db.executescript(
        "DROP TABLE task_dependency;"
        "ALTER TABLE board_task DROP COLUMN blocked_by_dependency;"
        "PRAGMA user_version=11;")
    await db.commit()
    await db.close()
    db = await open_db(path)
    try:
        cols = {r["name"] for r in await (await db.execute(
            "PRAGMA table_info(board_task)")).fetchall()}
        assert "blocked_by_dependency" in cols
        tcols = {r["name"] for r in await (await db.execute(
            "PRAGMA table_info(task_dependency)")).fetchall()}
        assert {"task_id", "depends_on_id", "board_id", "created_at",
                "created_by"} <= tcols
        assert (await (await db.execute(
            "PRAGMA user_version")).fetchone())[0] == DATA_VERSION
    finally:
        await db.close()
