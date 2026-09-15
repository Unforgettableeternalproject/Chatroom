"""封存房不擋板子收尾，但封存房仍看得到板（09/07 卡 1c920235，J4 判準）。

艾斯維爾 09/06 實測後的產品裁定，**推翻 09/06 Hub 的刻意決定**
（`37a1feb`：「封存不等於解除掛接」）。兩個要求並存：

1. 封存房不計入 outcome 前置的掛接數——房都封了還說「房裡的人還在用它」，
   那塊板就永遠收不了尾
2. 封存房內仍看得到板（唯讀入口不動）——那是歷史，不是失效

改判準會冒出原註解警告的那個矛盾：「掛接數 1、但可以宣告結局」。決策 09/07
裁走 B：**拆欄位**。`attached_room_count` 維持歷史語意（掛過幾間、還沒解除），
`live_attached_room_count` 回答「還有幾間活著」。一個數字回答兩個問題才是
矛盾的根源，選一邊只是把它藏起來。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = {"X-Session-Key": "human-1"}


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _room(client, name):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": "human-1"})).json()["id"]


async def _board(client, name="板"):
    return (await client.post("/api/boards", headers=OWNER,
                              json={"name": name})).json()["id"]


async def _attach(client, bid, rid):
    r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
    assert r.status_code == 200, r.text


async def _archive(client, rid):
    r = await client.post(f"/api/rooms/{rid}/archive", headers=OWNER)
    assert r.status_code == 200, r.text


async def _detail(client, bid):
    r = await client.get(f"/api/boards/{bid}", headers=OWNER)
    assert r.status_code == 200, r.text
    return r.json()


async def test_an_archived_room_no_longer_blocks_the_outcome(tmp_path):
    """房都封了還說「房裡的人還在用它」，那塊板就永遠收不了尾。"""
    app, client = await _client(tmp_path, "gate-archived")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        bid = await _board(client)
        await _attach(client, bid, rid)
        assert (await _detail(client, bid))["outcome_eligible"] is False
        await _archive(client, rid)
        d = await _detail(client, bid)
        assert d["outcome_eligible"] is True, d["outcome_block_reason"]
        assert d["outcome_block_reason"] == ""


async def test_a_live_room_still_blocks_it(tmp_path):
    """還有人在用就還不是結局的時候。"""
    app, client = await _client(tmp_path, "gate-live")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        bid = await _board(client)
        await _attach(client, bid, rid)
        d = await _detail(client, bid)
        assert d["outcome_eligible"] is False
        assert d["outcome_block_reason"] == "still_attached"


async def test_a_board_that_never_had_a_room_still_cannot_settle(tmp_path):
    """收尾是對一段共同工作的結論，而它從來沒有共同過——這條不動。"""
    app, client = await _client(tmp_path, "gate-never")
    async with app.router.lifespan_context(app), client:
        bid = await _board(client)
        d = await _detail(client, bid)
        assert d["outcome_eligible"] is False
        assert d["outcome_block_reason"] == "never_attached"


async def test_the_two_counts_answer_two_different_questions(tmp_path):
    """拆欄位就是這張卡的重點：**掛過幾間**與**還有幾間活著**。

    合成一個數字的話，改了 gate 就會出現「掛接數 1、但可以宣告結局」——
    而那個矛盾只會被讀成畫面壞了。
    """
    app, client = await _client(tmp_path, "gate-counts")
    async with app.router.lifespan_context(app), client:
        old = await _room(client, "舊房")
        new = await _room(client, "新房")
        bid = await _board(client)
        await _attach(client, bid, old)
        await _attach(client, bid, new)
        await _archive(client, old)

        d = await _detail(client, bid)
        assert d["attached_room_count"] == 2      # 歷史：掛過兩間、都沒解除
        assert d["live_attached_room_count"] == 1  # 現況：只剩一間活著

        row = [b for b in (await client.get("/api/boards", headers=OWNER)
                           ).json()["boards"] if b["id"] == bid][0]
        assert row["attached_room_count"] == 2
        assert row["live_attached_room_count"] == 1


async def test_an_archived_room_can_still_see_its_board(tmp_path):
    """②「封存房內仍看得到板」——那是歷史，不是失效。

    這條與 gate 的改動同一張卡：只做前半的話，板收得了尾，但那間房從此
    看不到自己做過什麼。
    """
    app, client = await _client(tmp_path, "gate-visible")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        pid = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "Bernie"})).json()["participant_id"]
        bid = await _board(client)
        await _attach(client, bid, rid)
        await _archive(client, rid)
        r = await client.get(f"/api/rooms/{rid}/board",
                             headers={**OWNER, "X-Participant-Id": pid})
        assert r.status_code == 200, r.text
        assert r.json()["board_id"] == bid
