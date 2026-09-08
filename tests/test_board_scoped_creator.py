"""board-scoped 建的東西，建立者自己收不掉（09/08 測試Novia 8788 實測）。

`_board_writer_v2` 明文寫 `"id": None  # 不是從房裡發出來的`——Board Library
裡沒有房，那條路徑上根本沒有 participant 可記，所以身分記在
`created_by_actor_key`。**這是設計，不是遺漏。**

遺漏在另一端：四處權限檢查全部只比對 `created_by == me["id"]`：

- `_board_can_remove`（刪任何一張卡）
- Task `status=cancelled`
- Checklist `status=cancelled`
- Objective cancel

⇒ 同一個身分、同一塊板，只差建立途徑：room-scoped 建的取消得掉，
board-scoped 建的回 403「只有建立者或人類成員可以取消」——**把建立者擋在
他自己建的東西外面**。而 board-scoped 正是 Board V2「板與房分離」的主要
入口，純 agent 場景下那些週期沒有任何 agent 收得掉。

順帶一條同日的漏網（同一批留痕改動）：`cancelled` / `reopened` 的房內
mention 沒有排除動作發起人。`review` 排除了、`verified` / `done` 刻意含
（那兩步的下一步就是發起人要按的），而打回與取消之後發起人沒有下一步——
叫他等於叫假的。
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


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    """一間房、一個 agent、一塊板。回 (rid, hdr, board_id)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "agent-1"})).json()["id"]
    hdr = await _join(client, rid, "agent-1", "做事的人")
    # 房軸建一張卡，板才會長出來
    await client.post(f"/api/rooms/{rid}/board/tasks",
                      json={"title": "開板用"}, headers=hdr)
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    return rid, hdr, bid


async def test_the_creator_can_cancel_what_he_made_from_the_board(tmp_path):
    """board-scoped 建的週期，建立者（agent）自己取消得掉。

    對照組是同一個身分走房軸建的——兩條路只差建立途徑，權限不該分邊。
    """
    app, client = await _client(tmp_path, "bs_cancel")
    async with app.router.lifespan_context(app), client:
        rid, hdr, bid = await _setup(client)

        via_room = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                      json={"title": "房軸建的"},
                                      headers=hdr)).json()["id"]
        via_board = (await client.post(f"/api/boards/{bid}/objectives",
                                       json={"title": "板軸建的"},
                                       headers=hdr)).json()["id"]

        r1 = await client.post(f"/api/board/objectives/{via_room}/cancel",
                               headers=hdr)
        assert r1.status_code == 200, f"對照組就掛了，這條測試不成立：{r1.text}"

        r2 = await client.post(f"/api/board/objectives/{via_board}/cancel",
                               headers=hdr)
        assert r2.status_code == 200, (
            "建立者被擋在自己從板上建的週期外面——"
            f"board-scoped 的 created_by 是 None，權限只認 participant id：{r2.text}"
        )


async def test_the_same_hole_in_tasks_and_delete(tmp_path):
    """Task 的取消與刪除是同一個洞的另外兩處，修 objective 不會順便修到。

    ⚠️ **這裡刻意不含 checklist**（測試Novia 09/08 指正）：checklist 只有
    `POST /api/board/objectives/{oid}/checklists` 一條建立途徑、且必帶房
    ⇒ 永遠有 participant id ⇒ 那行比對永遠比得中。程式碼確實只比對
    participant，但**沒有任何輸入走得到那個分支**——把它放進來，這條測試
    修補前後都會綠，卻掛在一個宣稱「同一個洞」的名字底下。
    它的防迴歸價值另立一條，不與缺陷證明混在一起。
    """
    app, client = await _client(tmp_path, "bs_all")
    async with app.router.lifespan_context(app), client:
        rid, hdr, bid = await _setup(client)

        # 隨手記的卡走 board-scoped 那條（進「未分類」）⇒ created_by 是 None
        tid = (await client.post(f"/api/boards/{bid}/tasks",
                                 json={"title": "板軸卡"},
                                 headers=hdr)).json()["id"]
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "cancelled"}, headers=hdr)
        assert r.status_code == 200, f"task cancel 被擋：{r.text}"

        tid2 = (await client.post(f"/api/boards/{bid}/tasks",
                                  json={"title": "要刪的"},
                                  headers=hdr)).json()["id"]
        r = await client.delete(f"/api/board/tasks/{tid2}", headers=hdr)
        assert r.status_code == 200, f"刪除被擋：{r.text}"


async def test_checklist_cancel_stays_reachable(tmp_path):
    """防迴歸，**不是**缺陷證明：修補前後都綠，寫明白免得被誤讀成證據。

    checklist 現在只有一條必帶房的建立途徑。哪天多開一條 board-scoped 的
    （Board Library 裡建階段），它就會掉進同一個洞——那時這條會紅，
    而紅的原因會直接指向 `_is_creator`。
    """
    app, client = await _client(tmp_path, "bs_checklist")
    async with app.router.lifespan_context(app), client:
        rid, hdr, bid = await _setup(client)
        oid = (await client.post(f"/api/boards/{bid}/objectives",
                                 json={"title": "板軸週期"},
                                 headers=hdr)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "清單"},
                                 headers=hdr)).json()["id"]
        r = await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "cancelled"}, headers=hdr)
        assert r.status_code == 200, f"checklist cancel 被擋：{r.text}"


async def test_someone_else_still_cannot_cancel_it(tmp_path):
    """比對 actor_key **不是**放寬權限——別人照樣收不掉。"""
    app, client = await _client(tmp_path, "bs_other")
    async with app.router.lifespan_context(app), client:
        rid, hdr, bid = await _setup(client)
        other = await _join(client, rid, "agent-2", "別人")

        oid = (await client.post(f"/api/boards/{bid}/objectives",
                                 json={"title": "板軸週期"},
                                 headers=hdr)).json()["id"]
        r = await client.post(f"/api/board/objectives/{oid}/cancel",
                              headers=other)
        assert r.status_code == 403, (
            f"別人取消得掉建立者的週期——這條修法把門開太大了：{r.status_code}"
        )


async def test_cancel_and_reopen_do_not_mention_the_one_who_pressed(tmp_path):
    """打回與取消之後，發起人沒有下一步要按——不該把他也叫醒。

    對照：`verified` / `done` **刻意**含發起人（他就是下一步要按的那個），
    所以這條測的是 `cancelled` / `reopened` 兩則，不是全部。
    """
    app, client = await _client(tmp_path, "no_self_mention")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "工作房", "session_key": "human-1"})).json()["id"]
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, rid, "agent-worker", "做事的人")

        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期"},
                                 headers=human)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "一段"},
                                 headers=human)).json()["id"]
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "一張卡"},
                                 headers=human)).json()["id"]
        await client.post(f"/api/board/tasks/{tid}/claim", headers=worker)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=worker)
        await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=human)
        await client.post(f"/api/board/objectives/{oid}/review", headers=worker)
        assert (await client.post(f"/api/board/objectives/{oid}/reopen",
                                  headers=human)).status_code == 200

        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 params={"after_seq": 0, "limit": 100},
                                 headers=human)).json()["messages"]
        trace = [m for m in msgs
                 if m["system_event"] == "board_objective_reopened"]
        assert trace, "打回沒有留痕，這條測試不成立"
        assert "做事的人" in trace[0]["mentions"], (
            "做事的人沒被叫到——他才是需要知道自己的東西被打回的那個"
        )
        assert "艾斯維爾" not in trace[0]["mentions"], (
            f"按下打回的人被自己的動作叫醒了：{trace[0]['mentions']}"
        )
