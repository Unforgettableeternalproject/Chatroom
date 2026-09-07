"""刪板的前置與善後（09/07 卡 029e24f6，艾斯維爾裁定）。

⚠️ **這張卡原本的方向（軟刪除）已被推翻。** `DELETE /api/boards/{id}` 早就
存在而且是永久硬刪；房間那邊也是實際清除而不是軟刪，兩者要一致。艾斯維爾
09/07 的裁定改成三件事：

1. 硬刪保留
2. **板必須先封存才刪得掉**——刪除是不可復原的決定，封存是它的緩衝
3. 板被刪掉之後，房間要說得出實話：
   - 進行中的房 → 就是「沒綁板」，而且房主可以重新綁一塊
   - 已封存的房 → 「此房間原先的任務板已刪除」

第 3 點的前半**本來就成立**（硬刪一併刪掉 `board_room` 的列），後半不成立
——痕跡跟著被刪光了，所以要留墓碑。
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


async def _room(client, name="工作房"):
    rid = (await client.post("/api/rooms", json={
        "name": name, "session_key": "human-1"})).json()["id"]
    pid = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})).json()["participant_id"]
    return rid, {**OWNER, "X-Participant-Id": pid}


async def _board(client, name="板"):
    return (await client.post("/api/boards", headers=OWNER,
                              json={"name": name})).json()["id"]


async def _archive_board(client, bid):
    r = await client.post(f"/api/boards/{bid}/archive", headers=OWNER)
    assert r.status_code == 200, r.text


async def _delete(client, bid, headers=OWNER):
    return await client.request("DELETE", f"/api/boards/{bid}",
                                headers=headers)


async def _room_board(client, rid, headers):
    r = await client.get(f"/api/rooms/{rid}/board", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


# ---------- 前置：先封存才刪得掉 ----------

async def test_an_active_board_cannot_be_deleted(tmp_path):
    """刪除不可復原，封存是它的緩衝——**要先按過一次「這份工作收尾了」**。"""
    app, client = await _client(tmp_path, "delete-needs-archive")
    async with app.router.lifespan_context(app), client:
        bid = await _board(client)
        r = await _delete(client, bid)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "board_not_archived"


async def test_an_archived_board_can_be_deleted(tmp_path):
    app, client = await _client(tmp_path, "delete-after-archive")
    async with app.router.lifespan_context(app), client:
        bid = await _board(client)
        await _archive_board(client, bid)
        r = await _delete(client, bid)
        assert r.status_code == 200, r.text
        assert r.json()["deleted"]["board"] == 1
        assert (await client.get(f"/api/boards/{bid}",
                                 headers=OWNER)).status_code == 404


# ---------- 善後：房間要說得出實話 ----------

async def test_a_live_room_simply_has_no_board_again(tmp_path):
    """進行中的房：就是「沒綁板」，與從來沒綁過的房長得一樣。

    這半本來就成立（硬刪一併刪掉掛接列），測試是為了守住它——之後改刪除
    流程的人不會知道有人依賴這個結果。
    """
    app, client = await _client(tmp_path, "delete-live-room")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        bid = await _board(client)
        await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
        await _archive_board(client, bid)
        assert (await _delete(client, bid)).status_code == 200

        body = await _room_board(client, rid, me)
        assert body["board_id"] is None
        # ⚠️ server 回的是**事實**（這間房曾經有一塊板、它被刪了），
        # 不替 App 決定要畫哪一種頁面：進行中的房畫「沒綁板＋可重綁」、
        # 封存房畫訃聞，那是呈現，而呈現的條件（房狀態）client 手上就有。
        # server 這側做判斷的話，同一份事實會有兩個真相來源
        assert body["previous_board"] is not None
        assert body["previous_board"]["name"] == "板"


async def test_a_live_room_can_bind_a_new_board(tmp_path):
    """房主可以重新綁一塊新的——刪掉板不該讓那間房從此沒有板可用。"""
    app, client = await _client(tmp_path, "delete-rebind")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        old = await _board(client, "舊板")
        await client.post(f"/api/boards/{old}/rooms/{rid}", headers=OWNER)
        await _archive_board(client, old)
        await _delete(client, old)

        new = await _board(client, "新板")
        r = await client.post(f"/api/boards/{new}/rooms/{rid}", headers=OWNER)
        assert r.status_code == 200, r.text
        assert (await _room_board(client, rid, me))["board_id"] == new


async def test_an_archived_room_keeps_a_headstone(tmp_path):
    """已封存的房：**「此房間原先的任務板已刪除」**。

    那間房不會再有新的板，所以「沒綁板」對它是錯的說法——它有過，而且那段
    工作紀錄現在不在了。名字要留著：沒有名字的訃聞等於沒有訃聞。
    """
    app, client = await _client(tmp_path, "delete-headstone")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        bid = await _board(client, "09/06 週期")
        await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
        await client.post(f"/api/rooms/{rid}/archive", headers=me)
        await _archive_board(client, bid)
        assert (await _delete(client, bid)).status_code == 200

        body = await _room_board(client, rid, me)
        assert body["board_id"] is None
        assert body["previous_board"] is not None
        assert body["previous_board"]["name"] == "09/06 週期"
        assert body["previous_board"]["deleted_at"]


async def test_binding_a_new_board_clears_the_headstone(tmp_path):
    """重綁之後那句訃聞要收掉——**它講的是「現在沒有板」**，而現在有了。"""
    app, client = await _client(tmp_path, "delete-headstone-cleared")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        old = await _board(client, "舊板")
        await client.post(f"/api/boards/{old}/rooms/{rid}", headers=OWNER)
        await _archive_board(client, old)
        await _delete(client, old)

        new = await _board(client, "新板")
        await client.post(f"/api/boards/{new}/rooms/{rid}", headers=OWNER)
        assert (await _room_board(client, rid, me))["previous_board"] is None


async def test_a_room_that_never_had_a_board_has_no_headstone(tmp_path):
    """沒有過就是沒有過——墓碑不能出現在從來沒下葬過的地方。"""
    app, client = await _client(tmp_path, "delete-no-history")
    async with app.router.lifespan_context(app), client:
        rid, me = await _room(client)
        assert (await _room_board(client, rid, me))["previous_board"] is None
