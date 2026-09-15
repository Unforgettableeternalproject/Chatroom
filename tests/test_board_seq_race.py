"""board 水位號的併發正確性（除錯 Novia 於 T-01~T-03 審查發現）。

`UPDATE … ; SELECT …` 拆成兩句時，中間那個 await 會讓出——後一個協程加完
再回來讀，兩邊讀到同一個號。**後果不是號碼難看，是變更會消失**：

    A、B 都領到 8 → client 讀到 A 那批、水位停在 8
    → 下次帶 after_board_seq=8 → `board_seq > 8` 撈不到 B
    ⇒ B 的變更永遠不會到達任何 client

而 Hub 這邊一切正常，沒有任何地方會報錯。既有的 `next_seq` 本來就用
`UPDATE … RETURNING` 領號，board 沒有理由自己走一套比較弱的。
"""

import asyncio

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


async def _join(client, rid, session_key, name):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def test_concurrent_writes_never_share_a_board_seq(tmp_path):
    app, client = await _client(tmp_path, "race")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "owner"})).json()["id"]
        hdr = await _join(client, rid, "agent-1", "Novia")

        n = 8
        results = await asyncio.gather(*[
            client.post(f"/api/rooms/{rid}/board/objectives",
                        json={"title": f"週期{i}"}, headers=hdr)
            for i in range(n)
        ])
        seqs = [r.json()["board_seq"] for r in results]
        assert len(set(seqs)) == n, f"領到重複的水位號：{sorted(seqs)}"

        # 真正的後果：每一筆都要能被增量讀取撈到。撞號的那些會整批消失
        seen = []
        cursor = 0
        for _ in range(n + 1):
            body = (await client.get(
                f"/api/rooms/{rid}/board?after_board_seq={cursor}",
                headers=hdr)).json()
            seen.extend(o["id"] for o in body["objectives"])
            if body["board_seq"] == cursor:
                break
            cursor = body["board_seq"]
        assert len(set(seen)) == n, "有 objective 從增量流裡消失了"


async def test_patch_cannot_write_status(tmp_path):
    """狀態一律走專用端點。

    一個欄位兩條寫入路徑，遲早會有一條漏掉檢查——所以 PATCH 根本不收
    `status`，而不是「PATCH 也記得檢查一次」。
    """
    app, client = await _client(tmp_path, "nostatus")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "owner"})).json()["id"]
        hdr = await _join(client, rid, "agent-1", "Novia")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=hdr)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "Hub 端"},
                                 headers=hdr)).json()["id"]
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "接端點"},
                                 headers=hdr)).json()["id"]

        for path in (f"/api/board/objectives/{oid}",
                     f"/api/board/checklists/{cid}",
                     f"/api/board/tasks/{tid}"):
            r = await client.patch(path, json={"status": "done"}, headers=hdr)
            assert r.status_code == 422, f"{path} 不該接受 status：{r.text}"

        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=hdr)).json()
        assert board["objectives"][0]["status"] == "active"
        assert board["checklists"][0]["status"] == "open"
        assert board["tasks"][0]["status"] == "todo"
