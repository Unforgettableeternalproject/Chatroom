"""房軸回整塊板（艾斯維爾 2026-09-04 #296 拍板）。

原本 `/api/rooms/{rid}/board` 三張表各自用 `room_id` 過濾 ⇒ 一塊板掛兩間房
時，每間房只看得到「在這間房寫的那些卡」。那讓板退化成每房獨立，跨聊天室
共用這件事就沒有意義了——板存在的理由正是共用。

⚠️ 水位不必跟著改：`_next_seq_for_board` 每次領號就把板水位同步回**所有**
active 掛接房的 `room.board_seq`，房軸回的 `board_seq` 早就是板軸的號。
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


async def _room(client, name, session_key):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _join(client, rid, session_key, name):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": session_key}


async def _card(client, rid, hdr, title):
    r = await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": title}, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _two_rooms_one_board(client):
    """A、B 兩房掛同一塊板，各寫一張卡。回 (ra, rb, hdr_a, hdr_b, bid)。"""
    ra = await _room(client, "A房", "claude-a")
    hdr_a = await _join(client, ra, "claude-a", "A")
    await _card(client, ra, hdr_a, "A房的卡")
    bid = (await client.get(f"/api/rooms/{ra}/board",
                            headers=hdr_a)).json()["board_id"]

    rb = await _room(client, "B房", "claude-a")
    hdr_b = await _join(client, rb, "claude-a", "A")
    r = await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr_b)
    assert r.status_code == 200, r.text
    await _card(client, rb, hdr_b, "B房的卡")
    return ra, rb, hdr_a, hdr_b, bid


async def test_room_axis_returns_the_whole_board(tmp_path):
    """從任一間掛接房讀，看到的都是整塊板——不是「在這房寫的那些」。"""
    app, client = await _client(tmp_path, "axis_full")
    async with client:
        async with app.router.lifespan_context(app):
            ra, rb, hdr_a, hdr_b, bid = await _two_rooms_one_board(client)

            for rid, hdr, who in ((ra, hdr_a, "A房"), (rb, hdr_b, "B房")):
                body = (await client.get(f"/api/rooms/{rid}/board",
                                         headers=hdr)).json()
                titles = sorted(t["title"] for t in body["tasks"])
                assert titles == ["A房的卡", "B房的卡"], f"{who} 只看到自己那半"

            # 房軸與板軸必須是同一份：兩條路進到同一塊板，看到的不能不一樣
            axis = (await client.get(f"/api/boards/{bid}",
                                     headers=hdr_a)).json()
            assert sorted(t["title"] for t in axis["tasks"]) == \
                ["A房的卡", "B房的卡"]


async def test_room_axis_increment_carries_the_other_rooms_changes(tmp_path):
    """增量也要跨房：拿 A 房的水位問，要收得到 B 房剛寫的東西。

    水位本來就是板軸的（見模組 docstring），所以這條驗的是「撈列的範圍跟
    水位的範圍對得上」——只改全量不改增量的話，第二次讀就會漏。
    """
    app, client = await _client(tmp_path, "axis_incr")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            hdr_a = await _join(client, ra, "claude-a", "A")
            await _card(client, ra, hdr_a, "A房的卡")
            bid = (await client.get(f"/api/rooms/{ra}/board",
                                    headers=hdr_a)).json()["board_id"]
            rb = await _room(client, "B房", "claude-a")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr_b)

            body = (await client.get(f"/api/rooms/{ra}/board",
                                     headers=hdr_a)).json()
            water = body["board_seq"]

            await _card(client, rb, hdr_b, "B房後來寫的卡")

            body = (await client.get(
                f"/api/rooms/{ra}/board?after_board_seq={water}",
                headers=hdr_a)).json()
            assert body["full"] is False
            assert [t["title"] for t in body["tasks"]] == ["B房後來寫的卡"]


async def test_reclaimable_spans_the_whole_board(tmp_path):
    """孤兒卡的清單也是板的範圍：在別房領走的卡，這房也該讓你認回。

    不對齊的話會出現「板上看得到那張孤兒卡、可接手清單裡沒有」——同一份
    判準在兩處寫法不同的老形狀。⚠️ 只放寬**房**過濾，身分仍限同一個
    session_key（裁定 #301）。
    """
    app, client = await _client(tmp_path, "axis_reclaim")
    async with client:
        async with app.router.lifespan_context(app):
            ra, rb, hdr_a, hdr_b, bid = await _two_rooms_one_board(client)

            # 第三個 agent 進 A 房領走 A 房那張卡，然後離開 ⇒ 孤兒
            hdr_c = await _join(client, ra, "claude-c", "C")
            tid = [t["id"] for t in (await client.get(
                f"/api/rooms/{ra}/board", headers=hdr_c)).json()["tasks"]
                if t["title"] == "A房的卡"][0]
            r = await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers=hdr_c)
            assert r.status_code == 200, r.text
            r = await client.post(f"/api/rooms/{ra}/leave", headers=hdr_c)
            assert r.status_code == 200, r.text

            # 同一個 session 從 B 房回來：那張卡要出現在可接手清單裡
            hdr_c2 = await _join(client, rb, "claude-c", "C")
            body = (await client.get(f"/api/rooms/{rb}/board",
                                     headers=hdr_c2)).json()
            assert [t["id"] for t in body["reclaimable_tasks"]] == [tid]

            # 別人的孤兒卡不會跑進來——放寬的是房，不是身分
            body = (await client.get(f"/api/rooms/{rb}/board",
                                     headers=hdr_b)).json()
            assert body["reclaimable_tasks"] == []
