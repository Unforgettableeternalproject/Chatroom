"""Board v2 端點：Library、以 board_id 讀、掛接／解除。

驗收條件（BOARD_DESIGN §12）在這裡的對應：
1. 同一塊板掛 A／B 兩房，A 建卡後 B 與 Library 看到同一個 seq
2. A 封存後 B 仍可寫板
6. room member 但非 board member 讀不到板
7. 解除掛接不刪卡，重新掛接看得到原狀態
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


async def _room(client, name="房", session_key="claude-a"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": session_key}


async def _first_card(client, rid, hdr, title="第一張卡"):
    """在房裡寫第一張卡——**換軸就發生在這一刻**（第一次有人寫板）。"""
    r = await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": title}, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _board_id(client, rid, hdr):
    body = (await client.get(f"/api/rooms/{rid}/board", headers=hdr)).json()
    return body["board_id"]


async def test_writing_a_card_creates_and_attaches_a_board(tmp_path):
    """建房**不會**長出空板；第一次寫卡才建，而且建立者是 owner。"""
    app, client = await _client(tmp_path, "v2_lazy")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            assert await _board_id(client, rid, hdr) is None, "讀一下就長出板了"

            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            assert bid

            row = await (await app.state.db.execute(
                "SELECT role FROM board_member WHERE board_id=? AND actor_key=?",
                (bid, "claude-a"))).fetchone()
            assert row["role"] == "owner"


async def test_existing_cards_are_moved_onto_the_board(tmp_path):
    """換軸時這間房既有的卡要一起帶過去，不能留一批沒有板的孤卡。"""
    app, client = await _client(tmp_path, "v2_backfill")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            row = await (await app.state.db.execute(
                "SELECT COUNT(*) AS n FROM board_task WHERE board_id=''"
            )).fetchone()
            assert row["n"] == 0, "有卡沒被換軸"
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert len(body["tasks"]) == 1


async def test_one_board_two_rooms_share_one_seq(tmp_path):
    """驗收 1：A 建卡後，B 與 Library 看到的是同一條水位。"""
    app, client = await _client(tmp_path, "v2_share")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr = await _join(client, ra, "claude-a", "A")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await _first_card(client, ra, hdr)
            bid = await _board_id(client, ra, hdr)

            r = await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr)
            assert r.status_code == 200, r.text

            before = (await client.get(f"/api/boards/{bid}",
                                       headers=hdr)).json()["board_seq"]
            await client.post(f"/api/rooms/{ra}/board/tasks",
                              json={"title": "第二張"}, headers=hdr)
            after = (await client.get(f"/api/boards/{bid}",
                                      headers=hdr)).json()["board_seq"]
            assert after > before

            # B 房的 v1 水位也要跟上——不同步的話，B 的舊 client 會停在
            # 原地，而它只會收到 200 與空清單，不會知道自己漏了
            b_body = (await client.get(f"/api/rooms/{rb}/board",
                                       headers=hdr_b)).json()
            assert b_body["board_seq"] == after
            assert b_body["board_id"] == bid


async def test_detach_keeps_the_cards_and_reattach_restores_the_view(tmp_path):
    """驗收 7：解除掛接不刪任何東西，掛回來看到的是原狀態。"""
    app, client = await _client(tmp_path, "v2_detach")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            r = await client.delete(f"/api/boards/{bid}/rooms/{rid}",
                                    headers=hdr)
            assert r.status_code == 200, r.text
            assert await _board_id(client, rid, hdr) is None

            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert len(body["tasks"]) == 1, "解除掛接把卡刪掉了"
            # 已解除的房仍要出現在清單裡，帶 detached: true
            assert body["attached_rooms"] == [
                {"id": rid, "name": "房", "status": "active", "detached": True}]

            r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert len(body["tasks"]) == 1
            assert [x["detached"] for x in body["attached_rooms"]] == [True, False]


async def test_a_room_cannot_hold_two_boards(tmp_path):
    app, client = await _client(tmp_path, "v2_two")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr_a = await _join(client, ra, "claude-a", "A")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await _first_card(client, ra, hdr_a)
            await _first_card(client, rb, hdr_b)
            bid_a = await _board_id(client, ra, hdr_a)

            r = await client.post(f"/api/boards/{bid_a}/rooms/{rb}",
                                  headers=hdr_a)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "room_already_has_board"


async def test_room_member_is_not_automatically_a_board_member(tmp_path):
    """驗收 6：房裡的人不會自動變成板上的人。"""
    app, client = await _client(tmp_path, "v2_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            other = await _join(client, rid, "claude-b", "B")
            r = await client.get(f"/api/boards/{bid}", headers=other)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"


async def test_library_lists_only_my_boards_with_counts(tmp_path):
    app, client = await _client(tmp_path, "v2_lib")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            mine = await _join(client, rid, "claude-a", "A")
            tid = await _first_card(client, rid, mine)
            await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)

            body = (await client.get("/api/boards", headers=mine)).json()
            assert len(body["boards"]) == 1
            card = body["boards"][0]
            assert card["my_role"] == "owner"
            assert card["attached_room_count"] == 1
            assert card["task_counts"] == {"total": 1, "done": 0, "claimed": 1}

            stranger = {"X-Session-Key": "claude-zzz"}
            body = (await client.get("/api/boards", headers=stranger)).json()
            assert body["boards"] == []


async def test_archived_room_does_not_freeze_the_board(tmp_path):
    """驗收 2：一間房封存了，板還活著——從別間房照樣寫得動。"""
    app, client = await _client(tmp_path, "v2_archive")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr_a = await _join(client, ra, "claude-a", "A")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await _first_card(client, ra, hdr_a)
            bid = await _board_id(client, ra, hdr_a)
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr_a)

            r = await client.post(f"/api/rooms/{ra}/archive",
                                  headers={"X-Session-Key": "claude-a"})
            assert r.status_code == 200, r.text

            r = await client.post(f"/api/rooms/{rb}/board/tasks",
                                  json={"title": "從 B 房寫"}, headers=hdr_b)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=hdr_a)).json()
            assert len(body["tasks"]) == 2


async def test_creating_cards_from_the_board_without_a_room(tmp_path):
    """Board Library 裡沒有房——那個畫面上也要建得了東西。

    權限看 `board_member` 而不是房內身分：拿房內身分當門檻的話，
    Library 上什麼都做不了。
    """
    app, client = await _client(tmp_path, "v2_bcards")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            # 只帶 session_key，沒有 participant、沒有房
            only_key = {"X-Session-Key": "claude-a"}
            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "從板上開的週期"},
                                  headers=only_key)
            assert r.status_code == 200, r.text
            assert r.json()["board_id"] == bid

            r = await client.post(f"/api/boards/{bid}/tasks",
                                  json={"title": "從板上隨手記"},
                                  headers=only_key)
            assert r.status_code == 200, r.text

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=only_key)).json()
            assert {o["title"] for o in body["objectives"]} == {
                "未分類", "從板上開的週期"}
            assert {t["title"] for t in body["tasks"]} == {
                "第一張卡", "從板上隨手記"}
            # 兩條路徑共用同一組「未分類」，不各長一組
            assert len([o for o in body["objectives"]
                        if o["title"] == "未分類"]) == 1


async def test_board_cards_reject_non_members(tmp_path):
    app, client = await _client(tmp_path, "v2_bcards_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "闖進來"},
                                  headers={"X-Session-Key": "claude-zzz"})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"


async def test_board_with_no_attached_room_says_so_clearly(tmp_path):
    """過渡期限制要**明確擋下來**，不是撞 FK 回 500。

    item 的 room_id 還是 NOT NULL（v1 遺留，等 table rebuild 才拿得掉），
    所以板上沒房時建不了卡。回 500 的話，查半天才知道是這件事。
    """
    app, client = await _client(tmp_path, "v2_noroom")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)

            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "沒房可掛"}, headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "board_has_no_room"


async def test_session_key_can_come_from_header_or_query(tmp_path):
    """房那邊的 /api/rooms 收 query session_key。兩邊不一致的話，照著既有
    慣例寫的 client 會拿到 400 而不知道差在哪——同一份憑證，兩種放法都收。
    """
    app, client = await _client(tmp_path, "v2_key_place")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            r = await client.get("/api/boards?session_key=claude-a")
            assert r.status_code == 200, r.text
            assert [b["id"] for b in r.json()["boards"]] == [bid]

            r = await client.get(f"/api/boards/{bid}?session_key=claude-a")
            assert r.status_code == 200, r.text

            # 完全不給仍要擋，而且要講清楚缺什麼
            r = await client.get("/api/boards")
            assert r.status_code == 400
            assert r.json()["detail"]["code"] == "session_key_required"
