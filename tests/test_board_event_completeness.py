"""每一次 Board 變更，都要留下一筆 canonical event。

`board_event` 是稽核與跨房通知的真相來源（BOARD_DESIGN §2.4、§7.3）。
只有部分路徑記 event 的話，`GET /api/boards/{bid}/events` 會回一條**有洞的
稽核串**——而那比沒有稽核串更糟：它看起來完整。

⚠️ 這份測試的做法是**列舉所有會推進 `board.board_seq` 的操作**，然後斷言
每一個被領走的號都對應到一筆 event。用「挑幾個操作來驗」的寫法會漏——
我自己的驗收 8 測試就只驗了 claim 與 done，恰好避開了缺 event 的那些
（審核用Codex 2026-09-02 指出）。
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


async def _seq_and_events(app, bid):
    db = app.state.db
    seq = (await (await db.execute(
        "SELECT board_seq FROM board WHERE id=?", (bid,))).fetchone()
    )["board_seq"]
    rows = await (await db.execute(
        "SELECT board_seq, event_type FROM board_event WHERE board_id=?",
        (bid,))).fetchall()
    return seq, {r["board_seq"]: r["event_type"] for r in rows}


async def test_every_board_seq_has_exactly_one_event(tmp_path):
    """走一遍板上做得到的每一種變更，**每個被領走的號都要有一筆 event**。

    這條會把「只有少數路徑記 event」照出來——它不挑樣本，它列舉。
    """
    app, client = await _client(tmp_path, "matrix")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "板子房", "session_key": "claude-a"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-a",
                "preferred_name": "A"})
            hdr = {"X-Participant-Id": j.json()["participant_id"]}
            key = {"X-Session-Key": "claude-a"}

            # ── 建立三層（room-scoped）
            oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                     json={"title": "週期"},
                                     headers=hdr)).json()["id"]
            bid = (await client.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()["board_id"]
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "階段"},
                                     headers=hdr)).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": "一件事"},
                                     headers=hdr)).json()["id"]

            # ── 建立（board-scoped）
            await client.post(f"/api/boards/{bid}/objectives",
                              json={"title": "板上開的週期"}, headers=key)
            loose = (await client.post(f"/api/boards/{bid}/tasks",
                                       json={"title": "隨手記"},
                                       headers=key)).json()["id"]

            # ── 編輯
            await client.patch(f"/api/board/tasks/{tid}",
                               json={"title": "改過"}, headers=hdr)
            await client.patch(f"/api/board/objectives/{oid}",
                               json={"description": "補一句"}, headers=hdr)

            # ── 認領與狀態（含 in_progress，那正是原本漏掉的那一種）
            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "blocked"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=hdr)
            await client.post(f"/api/board/tasks/{loose}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{loose}/release", headers=hdr)

            # ── 排序
            await client.post(f"/api/boards/{bid}/reorder",
                              json={"kind": "task",
                                    "items": [{"id": tid, "order_index": 1}]},
                              headers=key)

            # ── 軟刪除
            await client.delete(f"/api/board/tasks/{loose}", headers=hdr)

            # ── 週期收尾的四步
            await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"}, headers=hdr)
            await client.post(f"/api/board/objectives/{oid}/review",
                              headers=hdr)
            await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=hdr)
            await client.post(f"/api/board/objectives/{oid}/reopen",
                              headers=hdr)

            # ── 板本身
            await client.patch(f"/api/boards/{bid}",
                               json={"name": "改名"}, headers=key)

            seq, events = await _seq_and_events(app, bid)
            missing = [n for n in range(1, seq + 1) if n not in events]
            assert not missing, (
                f"這些 board_seq 沒有對應的 canonical event：{missing}"
                f"（總共領了 {seq} 個號，只有 {len(events)} 筆 event）。"
                "board_event 是稽核與跨房通知的真相來源，缺一個就是一條"
                "看起來完整、實際上有洞的稽核串。"
            )


async def test_the_events_endpoint_serves_the_whole_trail(tmp_path):
    """`GET /api/boards/{bid}/events`：對外的稽核串。

    它與 board delta 共用同一個 cursor，所以「板動了」與「動了什麼」對得
    起來。權限與讀板相同——不是板成員就看不到這塊板的歷史。
    """
    app, client = await _client(tmp_path, "events_api")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-a"}
            bid = (await client.post("/api/boards", json={"name": "板"},
                                     headers=key)).json()["id"]
            await client.post(f"/api/boards/{bid}/objectives",
                              json={"title": "週期"}, headers=key)
            await client.patch(f"/api/boards/{bid}", json={"name": "改名"},
                               headers=key)

            body = (await client.get(f"/api/boards/{bid}/events",
                                     headers=key)).json()
            kinds = [e["event_type"] for e in body["events"]]
            assert "objective_created" in kinds
            assert "board_updated" in kinds
            assert body["has_more"] is False
            # 與 delta 同一個 cursor：最後一筆的號就是板現在的水位
            assert body["events"][-1]["board_seq"] == body["board_seq"]

            # 增量：拿上一次的水位再問一次，不該重複收到
            after = body["board_seq"]
            body = (await client.get(
                f"/api/boards/{bid}/events?after_board_seq={after}",
                headers=key)).json()
            assert body["events"] == []

            # 不是成員就看不到
            r = await client.get(f"/api/boards/{bid}/events",
                                 headers={"X-Session-Key": "claude-zzz"})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"


async def test_failed_requests_leave_no_gap_either(tmp_path):
    """**被拒絕的請求也是發生過的事。**

    ⚠️ 上面那條只走成功路徑，所以它守不到這一半：CAS 輸掉、狀態轉移被擋、
    重排被拒——這些路徑裡有些**先領了號才發現不行**，於是水位前進而
    `/events` 沒有對應的 event（審核用Codex-2 2026-09-03）。

    兩種修法都可以，這條不挑：**要嘛不領號，要嘛留一筆 conflict event。**
    不能接受的是號被領走而沒有任何交代——那正是「看起來完整、實際上有洞」
    的稽核串。
    """
    app, client = await _client(tmp_path, "failures")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "板子房", "session_key": "claude-a"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-a",
                "preferred_name": "A"})
            hdr = {"X-Participant-Id": j.json()["participant_id"]}
            key = {"X-Session-Key": "claude-a"}
            oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                     json={"title": "週期"},
                                     headers=hdr)).json()["id"]
            bid = (await client.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()["board_id"]
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "階段"},
                                     headers=hdr)).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": "一件事"},
                                     headers=hdr)).json()["id"]

            # ── 被拒絕的路徑（每一條都預期非 2xx）
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=hdr)   # 沒認領
            await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"}, headers=hdr)   # 底下沒完成
            await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=hdr)                            # 還沒送審
            await client.post(f"/api/boards/{bid}/reorder",
                              json={"kind": "task",
                                    "items": [{"id": "不存在", "order_index": 0}]},
                              headers=key)
            await client.post(f"/api/rooms/{rid}/board/reorder",
                              json={"kind": "task",
                                    "items": [{"id": tid, "order_index": 3}]},
                              headers=hdr)

            seq, events = await _seq_and_events(app, bid)
            missing = [n for n in range(1, seq + 1) if n not in events]
            assert not missing, (
                f"這些 board_seq 沒有對應的 canonical event：{missing}"
                f"（總共領了 {seq} 個號，只有 {len(events)} 筆 event）。"
                "被拒絕的請求也是發生過的事——要嘛不領號，要嘛留一筆 "
                "conflict event，不能號被領走而沒有任何交代。"
            )


async def test_the_cas_loser_leaves_no_gap_either(tmp_path):
    """**真的撞在一起的那一路，也不能留下空號。**

    ⚠️ 上一條走的是「狀態機把它擋下來」——那是單線程的拒絕，在領號**之前**
    就發生了。這條走的是另一種：兩路都通過了檢查，CAS 讓其中一個輸掉，而
    輸家**已經把號領走了**（審核用Codex-2 2026-09-03）。

    兩者長得很像而性質不同：前者是「不該做的事被擋下」，後者是「該做的事
    被別人搶先」。只驗前者的話，稽核串的洞會留在後者那一半。
    """
    import asyncio

    app, client = await _client(tmp_path, "casrace")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "板子房", "session_key": "claude-a"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-a",
                "preferred_name": "A"})
            hdr = {"X-Participant-Id": j.json()["participant_id"]}
            oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                     json={"title": "週期"},
                                     headers=hdr)).json()["id"]
            bid = (await client.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()["board_id"]
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "階段"},
                                     headers=hdr)).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": "一件事"},
                                     headers=hdr)).json()["id"]

            # ① 兩路同時認領同一張卡
            await asyncio.gather(
                client.post(f"/api/board/tasks/{tid}/claim", headers=hdr),
                client.post(f"/api/board/tasks/{tid}/claim", headers=hdr))
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)

            # ② 兩路同時把它推向不同的終點
            await asyncio.gather(
                client.post(f"/api/board/tasks/{tid}/status",
                            json={"status": "done"}, headers=hdr),
                client.post(f"/api/board/tasks/{tid}/status",
                            json={"status": "blocked"}, headers=hdr))

            # ③ 兩路同時收尾同一份清單
            await asyncio.gather(
                client.post(f"/api/board/checklists/{cid}/status",
                            json={"status": "done"}, headers=hdr),
                client.post(f"/api/board/checklists/{cid}/status",
                            json={"status": "done"}, headers=hdr))

            # ④ 兩路同時送審同一個週期
            await asyncio.gather(
                client.post(f"/api/board/objectives/{oid}/review",
                            headers=hdr),
                client.post(f"/api/board/objectives/{oid}/review",
                            headers=hdr))

            seq, events = await _seq_and_events(app, bid)
            missing = [n for n in range(1, seq + 1) if n not in events]
            assert not missing, (
                f"CAS 輸家留下了空號：{missing}"
                f"（總共領了 {seq} 個號，只有 {len(events)} 筆 event）。"
                "輸掉的那一路已經把號領走了，要嘛把領號移到 CAS 之後，"
                "要嘛留一筆 conflict event。"
            )


async def test_a_room_that_never_switched_axis_can_still_be_written_to(
        tmp_path):
    """🚨 **還沒換軸的房：寫入不能 500。**

    v1 時代留下來的卡，`board_id` 是空字串。`_record_board_event` 拿它去寫
    `board_event` 會撞外鍵（那一欄 `REFERENCES board(id)`）⇒ IntegrityError
    ⇒ 500，**而水位已經先被領走一格**。

    ⚠️ 這條路徑在 event 補齊之前根本走不到：在那之前只有少數幾種變更會記
    event，剛好都不在這條路上。所以它是**新的不變式打到舊資料**——而症狀
    極難從外面看懂：v1 的讀取完全正常（走 room_id），只有寫入會炸
    （@測試Novia 2026-09-03 升級後第一次在生產房動卡時撞到）。

    沒有板就沒有板的稽核串，這是對的；不能接受的是它把整個請求打掛。
    """
    app, client = await _client(tmp_path, "noaxis")
    async with client:
        async with app.router.lifespan_context(app):
            db = app.state.db
            now = "2026-09-03T00:00:00+00:00"
            rid = (await client.post("/api/rooms", json={
                "name": "舊房", "session_key": "claude-a"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-a",
                "preferred_name": "A"})
            hdr = {"X-Participant-Id": j.json()["participant_id"]}
            # v1 時代的卡：board_id 是空字串，沒有 board、沒有 board_room
            await db.execute(
                "INSERT INTO board_objective (id, room_id, board_id, title,"
                " created_at) VALUES ('o1', ?, '', '週期', ?)", (rid, now))
            await db.execute(
                "INSERT INTO board_checklist (id, room_id, board_id,"
                " objective_id, title, created_at)"
                " VALUES ('c1', ?, '', 'o1', '階段', ?)", (rid, now))
            await db.execute(
                "INSERT INTO board_task (id, room_id, board_id, checklist_id,"
                " title, created_at) VALUES ('t1', ?, '', 'c1', '一件事', ?)",
                (rid, now))
            await db.commit()

            for label, r in (
                ("改描述", await client.patch("/api/board/tasks/t1",
                                              json={"description": "改過"},
                                              headers=hdr)),
                ("認領", await client.post("/api/board/tasks/t1/claim",
                                           headers=hdr)),
                ("推狀態", await client.post("/api/board/tasks/t1/status",
                                             json={"status": "in_progress"},
                                             headers=hdr)),
            ):
                assert r.status_code == 200, f"{label} 回了 {r.status_code}"

            # 改一張既有的卡也會把房接上板（艾斯維爾裁決 B 2026-09-03）。
            # 原本只有「建卡」會換軸，而升級後的房除非有人建新卡就永遠停在
            # v1——那個失敗方式是安靜的，沒有人會來抱怨自己的房沒換軸
            body = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=hdr)).json()
            assert body["board_id"], "改卡沒有觸發換軸"
            bid = body["board_id"]
            rows = await (await db.execute(
                "SELECT id FROM board_task WHERE board_id=?", (bid,))).fetchall()
            assert [r["id"] for r in rows] == ["t1"], (
                "板建起來了，但既有的卡沒有跟著接上——那比不換軸更糟："
                "板上是空的，而卡還在 v1 的世界")
            assert len(body["tasks"]) == 1


async def test_the_trail_says_where_it_started(tmp_path):
    """換軸的起點是**事實，不是推論**。

    `board_seq` 會跟著每一次變更長，所以事後看不出當初從哪一格接上。而
    稽核串的完整性判準需要那個下界：換軸之前的號屬於 v1 的房內序列，那段
    本來就不會有 board_event——把它算成「洞」是誤判（@測試Novia T19）。

    ⚠️ 拿 `min(existing events)` 當下界是**吃得掉一格的**：洞剛好落在換軸後
    的第一格時，它會被一起吃掉而沒有人發現。
    """
    app, client = await _client(tmp_path, "lowerbound")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "舊房", "session_key": "claude-a"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-a",
                "preferred_name": "A"})
            hdr = {"X-Participant-Id": j.json()["participant_id"]}
            # v1 時代已經走掉的水位
            await app.state.db.execute(
                "UPDATE room SET board_seq=42 WHERE id=?", (rid,))
            await app.state.db.commit()

            await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": "換軸"}, headers=hdr)
            bid = (await client.get(f"/api/rooms/{rid}/board",
                                    headers=hdr)).json()["board_id"]
            body = (await client.get(f"/api/boards/{bid}/events",
                                     headers={"X-Session-Key": "claude-a"})
                    ).json()
            assert body["migrated_from_seq"] == 42, (
                "換軸的起點沒有被保留下來——沒有它，1..42 那段會被算成 42 個洞")
            # 下界之後的每一個號都要有 event
            got = {e["board_seq"] for e in body["events"]}
            missing = [n for n in range(43, body["board_seq"] + 1)
                       if n not in got]
            assert not missing, missing

            # 顯式建的板從頭就是 v2，下界是 0
            fresh = (await client.post("/api/boards", json={"name": "新板"},
                                       headers={"X-Session-Key": "claude-a"})
                     ).json()["id"]
            body = (await client.get(f"/api/boards/{fresh}/events",
                                     headers={"X-Session-Key": "claude-a"})
                    ).json()
            assert body["migrated_from_seq"] == 0
