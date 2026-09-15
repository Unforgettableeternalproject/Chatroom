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


async def test_v1_cards_survive_when_a_foreign_board_is_attached(tmp_path):
    """房裡有 v1 存量卡（`board_id` 空）、之後掛進**別的**板——舊卡不能消失。

    `_ensure_board_for_room`（換軸）會把該房的卡回填 `board_id`，但
    `attach_board` 不會：它掛的是另一塊板，那些卡本來就不屬於它。於是房軸
    改用 `board_id` 過濾之後，這批卡**兩邊都看不到**——板軸沒有它們（不是
    那塊板的），房軸也撈不到（board_id 空）。舊行為至少房軸還看得到。

    這裡只保證**不比改之前差**：卡留在房軸看得見。它們該不該併進那塊板是
    語意問題，不由讀取路徑順手決定。
    """
    app, client = await _client(tmp_path, "axis_v1_orphan")
    async with client:
        async with app.router.lifespan_context(app):
            # 甲房：v1 存量卡（直接塞 DB，模擬換軸前寫下的卡）
            rv = await _room(client, "存量房", "claude-v")
            hdr_v = await _join(client, rv, "claude-v", "V")
            db = app.state.db
            t0 = "2026-01-01T00:00:00+00:00"
            # 整棵樹都是 v1 的：board_id 一律空（真實存量卡就長這樣）
            await db.execute(
                "INSERT INTO board_objective (id, room_id, board_id, title,"
                " status, created_at, board_seq)"
                " VALUES ('legacy-o', ?, '', '舊週期', 'active', ?, 1)", (rv, t0))
            await db.execute(
                "INSERT INTO board_checklist (id, room_id, board_id,"
                " objective_id, title, status, created_at, board_seq)"
                " VALUES ('legacy-c', ?, '', 'legacy-o', '舊清單', 'open', ?, 2)",
                (rv, t0))
            await db.execute(
                "INSERT INTO board_task (id, room_id, board_id, checklist_id,"
                " title, status, created_at, board_seq)"
                " VALUES ('legacy-1', ?, '', 'legacy-c', 'v1 存量卡', 'todo',"
                " ?, 3)", (rv, t0))
            await db.commit()
            assert [t["title"] for t in (await client.get(
                f"/api/rooms/{rv}/board", headers=hdr_v)).json()["tasks"]] \
                == ["v1 存量卡"]

            # 乙房長出一塊板，把它掛到甲房上
            ro = await _room(client, "別房", "claude-v")
            hdr_o = await _join(client, ro, "claude-v", "V")
            await _card(client, ro, hdr_o, "別房的卡")
            bid = (await client.get(f"/api/rooms/{ro}/board",
                                    headers=hdr_o)).json()["board_id"]
            r = await client.post(f"/api/boards/{bid}/rooms/{rv}",
                                  headers=hdr_v)
            assert r.status_code == 200, r.text

            titles = sorted(t["title"] for t in (await client.get(
                f"/api/rooms/{rv}/board", headers=hdr_v)).json()["tasks"])
            assert "v1 存量卡" in titles, "掛進外部板之後，房裡的存量卡不見了"


async def test_room_axis_reports_the_attached_rooms(tmp_path):
    """房軸也要回 `attached_rooms`，與板軸**同一份**。

    少了它，從聊天室進板的畫面畫不出「這塊板掛了哪幾間房」的徽章，只能顯示
    預設值「未掛接聊天室」——而那塊板明明就掛在你正看著的這間房上
    （艾斯維爾想法板觀察 ①）。

    ⚠️ 兩邊必須逐欄相同：判準複製一份出來的話，漂移的那一半沒有人在看。
    """
    app, client = await _client(tmp_path, "axis_attached")
    async with client:
        async with app.router.lifespan_context(app):
            ra, rb, hdr_a, hdr_b, bid = await _two_rooms_one_board(client)

            room_axis = (await client.get(f"/api/rooms/{ra}/board",
                                          headers=hdr_a)).json()
            board_axis = (await client.get(f"/api/boards/{bid}",
                                           headers=hdr_a)).json()
            assert room_axis["attached_rooms"] == board_axis["attached_rooms"]
            assert sorted(x["id"] for x in room_axis["attached_rooms"]) \
                == sorted([ra, rb])


async def test_a_room_with_no_board_reports_no_attached_rooms(tmp_path):
    """沒掛板的房回空清單——那與「掛了但一間也沒有」是同一種畫面，但
    `board_id` 是 null 已經把兩者分開了，這裡不必再發明第三種值。"""
    app, client = await _client(tmp_path, "axis_attached_none")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, "空房", "claude-a")
            hdr = await _join(client, rid, "claude-a", "A")
            body = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=hdr)).json()
            assert body["board_id"] is None
            assert body["attached_rooms"] == []


async def test_attached_rooms_shape_is_pinned(tmp_path):
    """釘住 `attached_rooms` 每一列的鍵集合。

    🔑 **這條是跨層接縫的 server 半邊。** App 那側有一份契約測試
    （`app/test/contract/room_axis_attached_rooms_test.dart`，@開發Novia (UI)
    2026-09-04），形狀取自這支端點的輸出——但它吃的是**寫死的假 JSON**，所以
    這邊改了形狀，那邊不會紅：它守的是「UI 解得動這個形狀」，不是「Hub 還在
    送這個形狀」。兩者都要有人守，缺哪一半都會讓另一半變成假的安全感。

    改這裡的形狀時，**要同時去改 App 那份**——它不會自己提醒你。
    """
    app, client = await _client(tmp_path, "axis_attached_shape")
    async with client:
        async with app.router.lifespan_context(app):
            ra, rb, hdr_a, hdr_b, bid = await _two_rooms_one_board(client)
            body = (await client.get(f"/api/rooms/{ra}/board",
                                     headers=hdr_a)).json()
            assert set(body["attached_rooms"][0]) == {
                "id", "name", "status", "visibility", "detached",
                # 沒指定時是 None，但**鍵一定在**——鍵時有時無的話，client
                # 得先判斷有沒有這個鍵再判斷值，那是兩層而不是一層
                "supervisor",
            }
