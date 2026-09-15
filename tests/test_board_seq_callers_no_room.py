"""`_next_board_seq` 其餘三個呼叫點在零掛接房情境下的正向驗證。

D9（`5817aee`）與它的同型問題（`0851d1b`）都是「拿空的 room_id 去領號」。
修完之後還有三個呼叫點**沒有帶 `board_id`**，2026-09-05 的稽核把它們列為
驗證缺口——當時只有讀碼推論說它們撞不到，而**同型問題已經出現兩次**。

三個呼叫點與它們的 `room_id` 來源：

| 位置 | 端點／函式 | room_id 從哪來 |
|---|---|---|
| `create_objective` | `POST /api/rooms/{room_id}/board/objectives` | 路徑參數 |
| `reorder_board` | `POST /api/rooms/{room_id}/board/reorder` | 路徑參數 |
| `_orphan_claims` | 四條離場路徑 + sweeper | 路徑參數／`participant.room_id` |

⇒ 三者都不可能是空字串。但「不可能」要有東西釘著，否則哪天有人加一條
board-scoped 的入口進來，紅的應該是這裡。
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


async def _room(client, name="房", session_key="claude-a"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _join(client, rid, session_key, name):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": session_key}


async def _loose_board(client, key):
    """一塊**沒有掛任何房**的板，上面有一張卡。"""
    bid = (await client.post("/api/boards", json={"name": "沒掛房的板"},
                             headers=key)).json()["id"]
    tid = (await client.post(f"/api/boards/{bid}/tasks",
                             json={"title": "無房卡"}, headers=key)).json()["id"]
    return bid, tid


async def test_room_scoped_writes_still_work_beside_a_roomless_board(tmp_path):
    """零掛接房的板存在時，room-scoped 的建立與排序仍然正常。

    這兩條的 `room_id` 來自路徑參數，所以領號一定有 scope——**這條測試存在
    的意義是釘住那個前提**：哪天有人給它們加一條 board-scoped 的入口，
    紅的會是這裡，而不是某個使用者撞到 500。
    """
    app, client = await _client(tmp_path, "callers_room_axis")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-a"}
            await _loose_board(client, key)          # 旁邊擺一塊零掛接房的板

            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            r = await client.post(f"/api/rooms/{rid}/board/objectives",
                                  json={"title": "週期一"}, headers=hdr)
            assert r.status_code == 200, r.text
            oid = r.json()["id"]

            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "清單"},
                                     headers=hdr)).json()["id"]
            tids = [(await client.post(f"/api/board/checklists/{cid}/tasks",
                                       json={"title": f"卡{i}"},
                                       headers=hdr)).json()["id"]
                    for i in range(2)]

            r = await client.post(
                f"/api/rooms/{rid}/board/reorder",
                json={"kind": "task",
                      "items": [{"id": t, "order_index": i}
                                for i, t in enumerate(reversed(tids))]},
                headers=hdr)
            assert r.status_code == 200, r.text


async def test_leaving_a_room_does_not_touch_a_roomless_boards_claims(tmp_path):
    """離場路徑撈卡的條件是 `t.room_id=?`，所以零掛接房的卡碰不到。

    ⚠️ **這條同時揭露一個缺口，不是缺陷但要有人知道**：正因為撈的條件是
    room_id，零掛接房的板上的認領**永遠不會被孤兒化**——沒有任何離場路徑會
    帶著空的 room_id 呼叫。那張卡會一直顯示「有人在做」，即使領它的 session
    早就結束了。

    這是「零掛接房先不支援」（艾斯維爾裁決）的又一個表現，不是這次修法造成
    的迴歸。釘在這裡是為了讓它**被看見**：哪天決定支援零掛接房，這條測試的
    第二個斷言就該反過來。
    """
    app, client = await _client(tmp_path, "callers_orphan")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-a"}
            bid, loose_tid = await _loose_board(client, key)
            r = await client.post(f"/api/board/tasks/{loose_tid}/claim",
                                  headers=key)
            assert r.status_code == 200, r.text

            # 另一間房裡有人領了卡然後離開 ⇒ 走 _orphan_claims
            rid = await _room(client, name="有房的房", session_key="claude-a")
            # 讀板要房內身分（`X-Session-Key` 不夠），所以留一個沒離開的成員
            watcher = await _join(client, rid, "claude-a", "A")
            hdr = await _join(client, rid, "claude-b", "B")
            tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                                     json={"title": "有房卡"},
                                     headers=hdr)).json()["id"]
            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            r = await client.post(f"/api/rooms/{rid}/leave", headers=hdr)
            assert r.status_code == 200, r.text

            # ① 有房的那張確實被孤兒化了 ⇒ 這條路徑真的跑過，不是空轉
            body = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=watcher)).json()
            got = [t for t in body["tasks"] if t["id"] == tid][0]
            assert got["claim_state"] == "orphaned"

            # ② 零掛接房那張沒有被碰到——既沒炸，也沒被誤掃
            loose = (await client.get(f"/api/boards/{bid}", headers=key)).json()
            card = [t for t in loose["tasks"] if t["id"] == loose_tid][0]
            assert card["claim_state"] == "held"
