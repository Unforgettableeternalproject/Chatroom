"""T-02：`GET /api/rooms/{id}/board` 的增量讀取契約。

重點全在**增量**那一半：全量誰都寫得出來，會出事的是 tombstone
（軟刪除的列必須照樣回得來，否則 board 上永遠留著一張已經不存在的卡）
與水位語意。CRUD 還沒有（T-03），所以這裡直接寫 DB 造資料——驗的是讀取
契約本身，不是誰寫進去的。
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


async def _room_with_member(client, session_key="agent-1", name="Novia"):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    me = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": session_key,
        "preferred_name": name})).json()
    return rid, me["participant_id"]


async def _seed(app, room_id, *, seq, deleted=0, claim_state="",
                claim_session_key="", suffix="1"):
    """直接寫一組 objective / checklist / task（同一個 board_seq）。"""
    db = app.state.db
    oid, cid, tid = f"o{suffix}", f"c{suffix}", f"t{suffix}"
    await db.execute(
        "INSERT INTO board_objective (id, room_id, title, board_seq, deleted, created_at)"
        " VALUES (?,?,?,?,?,'2026-09-01')", (oid, room_id, f"週期{suffix}", seq, deleted))
    await db.execute(
        "INSERT INTO board_checklist (id, room_id, objective_id, title, board_seq,"
        " deleted, created_at) VALUES (?,?,?,?,?,?,'2026-09-01')",
        (cid, room_id, oid, f"階段{suffix}", seq, deleted))
    await db.execute(
        "INSERT INTO board_task (id, room_id, checklist_id, title, board_seq, deleted,"
        " claim_state, claim_session_key, claim_name, orphaned_at, created_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,'2026-09-01')",
        (tid, room_id, cid, f"任務{suffix}", seq, deleted, claim_state,
         claim_session_key, "前世的我" if claim_state else "", "2026-09-01"))
    await db.execute("UPDATE room SET board_seq=? WHERE id=? AND board_seq<?",
                     (seq, room_id, seq))
    await db.commit()
    return oid, cid, tid


async def test_zero_cursor_returns_everything_and_says_full(tmp_path):
    app, client = await _client(tmp_path, "full")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client)
        await _seed(app, rid, seq=1, suffix="1")
        await _seed(app, rid, seq=2, suffix="2")
        r = await client.get(f"/api/rooms/{rid}/board",
                             headers={"X-Participant-Id": pid})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["full"] is True
        assert body["board_seq"] == 2
        assert [o["id"] for o in body["objectives"]] == ["o1", "o2"]
        assert len(body["tasks"]) == 2


async def test_cursor_returns_only_what_changed(tmp_path):
    app, client = await _client(tmp_path, "incr")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client)
        await _seed(app, rid, seq=1, suffix="1")
        await _seed(app, rid, seq=2, suffix="2")
        r = await client.get(f"/api/rooms/{rid}/board?after_board_seq=1",
                             headers={"X-Participant-Id": pid})
        body = r.json()
        assert body["full"] is False
        assert [o["id"] for o in body["objectives"]] == ["o2"]
        assert [t["id"] for t in body["tasks"]] == ["t2"]


async def test_soft_deleted_rows_come_back_as_tombstones(tmp_path):
    """增量協定最常漏的一條：看不到刪除事件的 client 會永遠留著那張卡。"""
    app, client = await _client(tmp_path, "tomb")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client)
        await _seed(app, rid, seq=1, suffix="1")
        await _seed(app, rid, seq=5, deleted=1, suffix="2")
        r = await client.get(f"/api/rooms/{rid}/board?after_board_seq=1",
                             headers={"X-Participant-Id": pid})
        body = r.json()
        tombs = [t for t in body["tasks"] if t["deleted"]]
        assert [t["id"] for t in tombs] == ["t2"]


async def test_reclaimable_only_lists_my_own_orphans(tmp_path):
    """孤兒卡是「你上一世領的」才該回收，別人的不該出現在你的清單裡。"""
    app, client = await _client(tmp_path, "reclaim")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client, session_key="agent-mine")
        await _seed(app, rid, seq=1, claim_state="orphaned",
                    claim_session_key="agent-mine", suffix="1")
        await _seed(app, rid, seq=2, claim_state="orphaned",
                    claim_session_key="agent-someone-else", suffix="2")
        await _seed(app, rid, seq=3, claim_state="held",
                    claim_session_key="agent-mine", suffix="3")
        r = await client.get(f"/api/rooms/{rid}/board",
                             headers={"X-Participant-Id": pid})
        body = r.json()
        assert [t["id"] for t in body["reclaimable_tasks"]] == ["t1"]
        assert body["reclaimable_tasks"][0]["claim_name"] == "前世的我"


async def test_non_member_cannot_read_board(tmp_path):
    app, client = await _client(tmp_path, "guard")
    async with app.router.lifespan_context(app), client:
        rid, _ = await _room_with_member(client)
        r = await client.get(f"/api/rooms/{rid}/board")
        assert r.status_code == 401
        assert r.json()["detail"]["code"] == "participant_header_required"


async def test_missing_room_is_404_before_identity_check(tmp_path):
    """順序相反會產生「403 叫你重 join → join 回 404」的死路。"""
    app, client = await _client(tmp_path, "order")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/rooms/nope/board")
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "room_not_found"


async def test_archived_room_board_is_still_readable(tmp_path):
    """封存房唯讀瀏覽是既有語意，board 不該自己長出另一套。"""
    app, client = await _client(tmp_path, "arch")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client)
        await _seed(app, rid, seq=1, suffix="1")
        await app.state.db.execute(
            "UPDATE room SET status='archived' WHERE id=?", (rid,))
        await app.state.db.commit()
        r = await client.get(f"/api/rooms/{rid}/board",
                             headers={"X-Participant-Id": pid})
        assert r.status_code == 200
        assert len(r.json()["objectives"]) == 1


async def test_response_shape_is_pinned(tmp_path):
    """回應的鍵集合本身是契約（除錯 Novia 於 T-02 審查提出）。

    這條契約橫跨兩個語言：Dart 那側解析不到欄位**不會報錯，只會顯示空白**。
    改個欄位名在 Python 這側看起來完全正常，而 App 上那一格就這樣安靜地空掉。
    錨點只有放在產生端才有效——消費端的 fixture 是靜態的，抓不到。
    """
    app, client = await _client(tmp_path, "shape")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client, session_key="agent-mine")
        await _seed(app, rid, seq=1, claim_state="orphaned",
                    claim_session_key="agent-mine", suffix="1")
        body = (await client.get(f"/api/rooms/{rid}/board",
                                 headers={"X-Participant-Id": pid})).json()
        assert set(body) == {
            # v2：舊路由兼任 resolver，告訴舊 client 它讀的是哪塊板
            "board_id",
            "board_seq", "full", "objectives", "checklists", "tasks",
            "reclaimable_tasks", "supervisor",
            # 從聊天室進板的徽章靠它畫「掛了哪幾間房」，與板軸同一份
            # （艾斯維爾想法板觀察 ①）
            "attached_rooms",
            # N-4：與我有關的指派請求隨板一起回，不另開清單端點
            "task_requests",
            # 想法板標籤選單（預設 ∪ 板自訂），與板軸同一份
            "allowed_tags",
            # `allowed_tags` 是聯集，分不出哪些刪得掉——UI 靠這個鎖住預設
            # 標籤的刪除鈕（09/05 卡 d10ae5f2）
            "custom_tags",
            # 板的結局，與 status 正交（09/05 裁定 A，卡 N-2）：從聊天室
            # 進板的人看不出這塊板已經收尾的話，他會在一塊結束了的板上繼續加卡
            "outcome",
        }
        assert set(body["objectives"][0]) == {
            "id", "room_id", "title", "description", "status", "order_index",
            "created_by", "created_by_name", "reviewed_by", "reviewed_at",
            "verified_by", "verified_at", "completed_by", "completed_at",
            "deleted", "board_seq", "created_at",
            # v2：身分改記持久的 actor_key（participant 隨離房消失）。
            # 舊欄位並存不刪，等所有 client 升級後才 rebuild 清掉。
            # `board_id` 刻意**不在**這份清單裡——它換軸前恆為空字串，
            # 先給出去只會讓 client 拿空值去打 /api/boards/{board_id}
            "created_by_actor_key", "reviewed_by_actor_key",
            "verified_by_actor_key", "completed_by_actor_key",
        }
        assert set(body["checklists"][0]) == {
            "id", "room_id", "objective_id", "title", "description", "status",
            "order_index", "created_by", "created_by_name", "completed_by",
            "completed_at", "deleted", "board_seq", "created_at",
            "created_by_actor_key", "completed_by_actor_key",
        }
        assert set(body["tasks"][0]) == {
            "id", "room_id", "checklist_id", "title", "description", "status",
            "order_index", "priority", "claim_participant_id",
            "claim_session_key", "claim_name", "claim_kind", "claim_state",
            "claimed_at", "orphaned_at", "orphaned_reason", "source_seq",
            "assignee_participant_id", "assigned_by", "assigned_by_name",
            "created_by", "created_by_name", "completed_by", "completed_at",
            "deleted", "board_seq", "created_at",
            "created_by_actor_key", "completed_by_actor_key",
            "claim_actor_key", "assignee_actor_key", "assigned_by_actor_key",
            # 來源訊息的完整座標：一塊板掛多間房之後，光有 seq 講不出
            # 「是哪一間房的第幾則」
            "source_room_id", "source_room_name", "source_message_id",
        }
        assert set(body["reclaimable_tasks"][0]) == {
            "id", "title", "orphaned_at", "claim_name",
        }


async def test_full_read_omits_tombstones(tmp_path):
    """墓碑只對增量讀取有意義（測試 Novia 第二輪 F4）。

    全量 client 手上沒有「記得的那份」可以移除，那些列對它純粹是噪音，
    而且會隨刪除次數無上限成長。增量仍然要拿得到，否則它永遠不知道那張卡
    被刪了——兩種語意在同一個端點上，用游標分。
    """
    app, client = await _client(tmp_path, "full-tomb")
    async with app.router.lifespan_context(app), client:
        rid, pid = await _room_with_member(client)
        hdr = {"X-Participant-Id": pid}
        await _seed(app, rid, seq=1, suffix="1")
        await _seed(app, rid, seq=5, deleted=1, suffix="2")

        full = (await client.get(f"/api/rooms/{rid}/board", headers=hdr)).json()
        assert [o["id"] for o in full["objectives"]] == ["o1"]
        assert [t["id"] for t in full["tasks"]] == ["t1"]

        delta = (await client.get(f"/api/rooms/{rid}/board?after_board_seq=1",
                                  headers=hdr)).json()
        assert [t["id"] for t in delta["tasks"]] == ["t2"]
        assert delta["tasks"][0]["deleted"] is True
