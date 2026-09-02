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
