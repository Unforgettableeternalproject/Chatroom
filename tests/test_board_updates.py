"""T-08：board 變動要能把掛著的 long-poll 叫醒。

三件缺一不可：多收 `after_board_seq`、回應多 `board_seq`、**等待迴圈多一個
返回條件**。只做前兩件的話 board 變動會被 `events.notify` 叫醒、卻因為
查不到訊息而再掛回去——最多延遲一整個 poll 週期，而且看起來完全正常：
逾時返回本來就是正常路徑，回應裡的水位也是對的，只是慢。

所以這裡的斷言不是「回應有沒有 board_seq」，而是**多快拿到**。
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
                            base_url="http://test", timeout=30.0,
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _room(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    return rid, await _join(client, rid, "agent-1", "Novia")


async def _drain(client, rid, hdr) -> int:
    """把加入的系統訊息讀掉，回傳目前的 last_seq。

    不先排空的話 `after_seq=0` 會立刻命中那幾則 join 訊息而馬上返回，
    測到的就不是 long-poll 的等待行為了。
    """
    r = await client.get(
        f"/api/rooms/{rid}/updates?after_seq=0&timeout=0.1", headers=hdr)
    return r.json()["last_seq"]


async def test_board_change_wakes_a_waiting_poll_promptly(tmp_path):
    """核心：掛著的 long-poll 要**立刻**醒，不是等到逾時。"""
    app, client = await _client(tmp_path, "wake")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _room(client)
        other = await _join(client, rid, "agent-2", "Miller")
        cursor = (await client.get(f"/api/rooms/{rid}/board",
                                   headers=hdr)).json()["board_seq"]
        last = await _drain(client, rid, hdr)

        async def _waiter():
            return await client.get(
                f"/api/rooms/{rid}/updates?after_seq={last}&timeout=25"
                f"&after_board_seq={cursor}", headers=hdr)

        task = asyncio.create_task(_waiter())
        await asyncio.sleep(0.05)          # 讓它真的掛上去
        assert not task.done(), "沒有 board 變動時不該立刻返回"

        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=other)
        r = await asyncio.wait_for(task, timeout=5.0)   # 25 秒逾時的話這裡會炸
        body = r.json()
        assert body["board_seq"] > cursor
        assert body["messages"] == [], "board 變動不進訊息流"


async def test_old_clients_are_not_spun_by_board_data(tmp_path):
    """省略 after_board_seq ＝ 不關心 board。

    當成 0 的話，任何已經有 board 資料的房間都會讓舊 client 的 long-poll
    立刻返回，變成 25 秒 25 次的空轉迴圈——而它同樣不會報錯。
    """
    app, client = await _client(tmp_path, "oldclient")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=hdr)
        last = await _drain(client, rid, hdr)

        task = asyncio.create_task(client.get(
            f"/api/rooms/{rid}/updates?after_seq={last}&timeout=25", headers=hdr))
        await asyncio.sleep(0.2)
        assert not task.done(), "舊 client 不該因為房裡有 board 資料就被彈回來"
        task.cancel()


async def test_board_seq_is_always_reported(tmp_path):
    """即使 client 沒傳 after_board_seq，回應也要帶水位——它才知道要開始關心。"""
    app, client = await _client(tmp_path, "report")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=hdr)
        r = await client.get(
            f"/api/rooms/{rid}/updates?after_seq=0&timeout=0.1", headers=hdr)
        assert r.json()["board_seq"] == 1


async def test_mention_flag_is_unaffected_by_board(tmp_path):
    """board 把人叫醒 ≠ 那個人被 @ 了。watcher 靠這個旗標決定要不要打擾 agent。"""
    app, client = await _client(tmp_path, "mention")
    async with app.router.lifespan_context(app), client:
        rid, hdr = await _room(client)
        other = await _join(client, rid, "agent-2", "Miller")
        cursor = (await client.get(f"/api/rooms/{rid}/board",
                                   headers=hdr)).json()["board_seq"]
        last = await _drain(client, rid, hdr)
        task = asyncio.create_task(client.get(
            f"/api/rooms/{rid}/updates?after_seq={last}&timeout=25"
            f"&after_board_seq={cursor}", headers=hdr))
        await asyncio.sleep(0.05)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=other)
        body = (await asyncio.wait_for(task, timeout=5.0)).json()
        assert body["you_were_mentioned"] is False
