"""改名（09/07 卡 c271c7ff）。契約由決策 09/07 定死（房內 seq 91）。

`PATCH /api/rooms/{id}` 與 `PATCH /api/boards/{id}`，body `{"name": ...}`。
權限沿用既有那兩道：房是管理者、板是 owner。改名發一則 system 訊息留痕——
名字是所有人共用的指涉，換掉它而不留痕，別人會以為自己記錯了。

⚠️ 這裡有一個不明顯的依賴：`board_room.room_name` 是**房名的快照**（房被刪
之後板上還要說得出「那間房叫什麼」）。房改名時若不同步，板上會一直顯示舊
名字，而兩邊都不會報錯。
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


async def _room(client, name="舊房名"):
    rid = (await client.post("/api/rooms", json={
        "name": name, "session_key": "human-1"})).json()["id"]
    pid = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})).json()["participant_id"]
    return rid, {**OWNER, "X-Participant-Id": pid}


async def _board(client, name="舊板名"):
    return (await client.post("/api/boards", headers=OWNER,
                              json={"name": name})).json()["id"]


async def _rename_room(client, rid, name, headers=OWNER):
    return await client.patch(f"/api/rooms/{rid}", headers=headers,
                              json={"name": name})


async def _rename_board(client, bid, name, headers=OWNER):
    """⚠️ `PATCH /api/boards/{id}` **早就存在**（改名字或描述，限 owner）。

    09/07 這張卡只補了它缺的那一半：改名時在掛接房裡留痕。回應形狀維持既有
    契約（`changed` 是這次改了哪些欄位），只多帶一個生效後的 `name`。
    """
    return await client.patch(f"/api/boards/{bid}", headers=headers,
                              json={"name": name})


# ---------- 房 ----------

async def test_the_room_admin_can_rename_the_room(tmp_path):
    app, client = await _client(tmp_path, "rename-room")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        r = await _rename_room(client, rid, "新房名", me)
        assert r.status_code == 200, r.text
        assert r.json()["name"] == "新房名"


async def test_renaming_a_room_leaves_a_trace(tmp_path):
    """名字是所有人共用的指涉。換掉它而不留痕，別人會以為自己記錯了。"""
    app, client = await _client(tmp_path, "rename-room-trace")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        await _rename_room(client, rid, "新房名", me)
        msgs = (await client.get(f"/api/rooms/{rid}/messages", headers=me)
                ).json()["messages"]
        renamed = [m for m in msgs if m["system_event"] == "rename"]
        assert renamed, "改名沒有留下任何痕跡"
        assert "新房名" in renamed[-1]["content"]


async def test_a_plain_member_cannot_rename_the_room(tmp_path):
    app, client = await _client(tmp_path, "rename-room-acl")
    async with app.router.lifespan_context(app), client:
        rid, _ = await _room(client)
        other = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": "claude-1",
            "preferred_name": "Novia"})).json()["participant_id"]
        r = await _rename_room(client, rid, "我說了算",
                               {"X-Participant-Id": other})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_admin"


async def test_an_archived_room_cannot_be_renamed(tmp_path):
    """封存房唯讀，改名也不例外——那間房的紀錄已經定稿了。"""
    app, client = await _client(tmp_path, "rename-room-archived")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        await client.post(f"/api/rooms/{rid}/archive", headers=me)
        r = await _rename_room(client, rid, "改不動", me)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "room_archived"


async def test_an_empty_name_is_refused(tmp_path):
    """空字串在畫面上與「載入中」長得一樣。"""
    app, client = await _client(tmp_path, "rename-empty")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        assert (await _rename_room(client, rid, "", me)).status_code == 422
        assert (await _rename_room(client, rid, "   ", me)).status_code == 422


async def test_renaming_to_the_same_name_says_nothing(tmp_path):
    """同名不是變更——發一則「改名為原本那個名字」的訊息只是噪音。"""
    app, client = await _client(tmp_path, "rename-noop")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        r = await _rename_room(client, rid, "舊房名", me)
        assert r.status_code == 200, r.text
        assert r.json()["changed"] is False
        msgs = (await client.get(f"/api/rooms/{rid}/messages", headers=me)
                ).json()["messages"]
        assert not [m for m in msgs if m["system_event"] == "rename"]


async def test_the_boards_snapshot_of_the_room_name_follows(tmp_path):
    """`board_room.room_name` 是快照，房改名要跟著走。

    不同步的話，板上會一直顯示舊名字——而兩邊都不會報錯，只有記得舊名的人
    才看得出哪裡怪。
    """
    app, client = await _client(tmp_path, "rename-snapshot")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        bid = await _board(client)
        await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
        await _rename_room(client, rid, "新房名", me)
        body = (await client.get(f"/api/boards/{bid}", headers=OWNER)).json()
        names = [r["name"] for r in body["attached_rooms"] if r["id"] == rid]
        assert names == ["新房名"]


# ---------- 板 ----------

async def test_the_board_owner_can_rename_the_board(tmp_path):
    app, client = await _client(tmp_path, "rename-board")
    async with app.router.lifespan_context(app), client:
        bid = await _board(client)
        r = await _rename_board(client, bid, "新板名")
        assert r.status_code == 200, r.text
        assert r.json()["name"] == "新板名"


async def test_a_stranger_cannot_rename_the_board(tmp_path):
    app, client = await _client(tmp_path, "rename-board-acl")
    async with app.router.lifespan_context(app), client:
        bid = await _board(client)
        r = await _rename_board(client, bid, "我說了算",
                                {"X-Session-Key": "stranger-1"})
        assert r.status_code == 403, r.text


async def test_renaming_a_board_tells_the_rooms_it_hangs_on(tmp_path):
    """板名出現在每一間掛接房的 app bar 上——改了要讓那些房知道。"""
    app, client = await _client(tmp_path, "rename-board-trace")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        bid = await _board(client)
        await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
        await _rename_board(client, bid, "新板名")
        msgs = (await client.get(f"/api/rooms/{rid}/messages", headers=me)
                ).json()["messages"]
        renamed = [m for m in msgs if m["system_event"] == "rename"]
        assert renamed and "新板名" in renamed[-1]["content"]


async def test_an_archived_board_cannot_be_renamed(tmp_path):
    """封存的板唯讀，與它的卡同一條規則。"""
    app, client = await _client(tmp_path, "rename-board-archived")
    async with app.router.lifespan_context(app), client:
        bid = await _board(client)
        await client.post(f"/api/boards/{bid}/archive", headers=OWNER)
        r = await _rename_board(client, bid, "改不動")
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "board_archived"
