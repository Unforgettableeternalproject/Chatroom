"""改標題／敘述要有資格（艾斯維爾 09/08 seq 87，裁定 B）。

`PATCH /api/board/{objectives,checklists,tasks}/{id}` 走 `_board_patch`，
而那條路上**一個權限檢查都沒有**：只要是 board writer（房軸＝房內任何
participant）就改得動別人建的東西。測試Novia 在 8788 上用一個非 owner、
非 supervisor、非建立者的路人身分，把三種物件的標題都改成「被路人改了」。

裁定收緊到三軸：**板 owner／房 supervisor／建立者**。人類成員不在其中——
`human_only` 那個錯誤碼會說謊，所以這裡用 `not_board_editor`。

⚠️ 建立者那一軸**必須共用 `_is_creator` 的雙軸比對**（測試Novia 的警告）：
自己寫一份只比對 participant id 的話，board-scoped 建的東西一樣認不出
建立者——建立者連自己的卡都改不了名，原地複製今天那個 bug。
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
    """一間房、建立者、路人，以及建立者開的一組週期／階段／卡。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "creator"})).json()["id"]
    creator = await _join(client, rid, "creator", "建立者")
    stranger = await _join(client, rid, "stranger", "路人")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"},
                             headers=creator)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段"},
                             headers=creator)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "卡"},
                             headers=creator)).json()["id"]
    return rid, creator, stranger, {"objectives": oid,
                                    "checklists": cid,
                                    "tasks": tid}


async def _patch(client, kind, item_id, headers, **fields):
    return await client.patch(f"/api/board/{kind}/{item_id}",
                              json=fields, headers=headers)


async def _title(client, rid, kind, item_id, headers):
    board = (await client.get(f"/api/rooms/{rid}/board",
                              headers=headers)).json()
    return [x for x in board[kind] if x["id"] == item_id][0]["title"]


async def test_a_stranger_cannot_rename_what_someone_else_made(tmp_path):
    """🔴 三種物件都要擋。共用 `_board_patch` ⇒ 漏一種就是三種都漏。"""
    app, client = await _client(tmp_path, "patch-stranger")
    async with app.router.lifespan_context(app), client:
        rid, creator, stranger, ids = await _setup(client)
        for kind, item_id in ids.items():
            r = await _patch(client, kind, item_id, stranger,
                             title="被路人改了")
            assert r.status_code == 403, f"{kind}: {r.text}"
            assert r.json()["detail"]["code"] == "not_board_editor"
            # 擋下來要真的沒寫進去——回 403 卻已經改掉是最糟的組合
            assert await _title(client, rid, kind, item_id, creator) != "被路人改了"


async def test_the_creator_can_rename_their_own(tmp_path):
    app, client = await _client(tmp_path, "patch-creator")
    async with app.router.lifespan_context(app), client:
        rid, creator, _, ids = await _setup(client)
        for kind, item_id in ids.items():
            r = await _patch(client, kind, item_id, creator, title=f"{kind} 新名")
            assert r.status_code == 200, f"{kind}: {r.text}"
            assert await _title(client, rid, kind, item_id, creator) \
                == f"{kind} 新名"


async def test_the_room_supervisor_can_rename_anything(tmp_path):
    """supervisor 是那個負責看的人，收尾時得改得動別人留下的東西。"""
    app, client = await _client(tmp_path, "patch-supervisor")
    async with app.router.lifespan_context(app), client:
        rid, creator, stranger, ids = await _setup(client)
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "stranger"},
                              headers=creator)
        assert r.status_code == 200, r.text
        for kind, item_id in ids.items():
            r = await _patch(client, kind, item_id, stranger,
                             title=f"{kind} 由監督者改")
            assert r.status_code == 200, f"{kind}: {r.text}"


async def test_a_creator_from_the_board_axis_is_still_the_creator(tmp_path):
    """🔴 board-scoped 建的東西 `created_by` 是 None，身分在 actor_key。

    這條在的理由：新的檢查若自己寫一份只比對 participant id 的建立者判斷，
    這裡會 403——建立者改不了自己從 Board Library 建的週期，與 09/08 那個
    「建立者取消不了自己的卡」是同一個 bug 換一個動作。
    """
    app, client = await _client(tmp_path, "patch-board-axis")
    async with app.router.lifespan_context(app), client:
        rid, creator, _, _ = await _setup(client)
        board_id = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=creator)).json()["board_id"]
        sk = {"X-Session-Key": "creator"}
        oid = (await client.post(f"/api/boards/{board_id}/objectives",
                                 json={"title": "板軸建的週期"},
                                 headers=sk)).json()["id"]
        r = await _patch(client, "objectives", oid, sk, title="改得動")
        assert r.status_code == 200, r.text


async def test_legacy_cards_with_no_creator_stay_editable(tmp_path):
    """🔴 v1 存量卡（沒有建立者資訊）不可以變成誰都改不動。

    換軸前直接寫進 DB 的卡 `created_by` 與 `created_by_actor_key` 兩邊都空。
    收緊的理由是「別人建的東西不該被路人改」——**沒有建立者就沒有要保護的
    對象**。不豁免的話升級後的房裡那些卡全部凍住，而且不會有人來抱怨：
    使用者只會以為板壞了。
    """
    app, client = await _client(tmp_path, "patch-legacy")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "升級上來的房", "session_key": "someone"})).json()["id"]
        hdr = await _join(client, rid, "someone", "路過的人")
        db = app.state.db
        await db.execute(
            "INSERT INTO board_objective (id, room_id, board_id, title,"
            " created_at) VALUES ('o-legacy', ?, '', '舊週期', '2026-01-01')",
            (rid,))
        await db.commit()
        r = await _patch(client, "objectives", "o-legacy", hdr, title="改得動")
        assert r.status_code == 200, r.text


async def test_the_exemption_is_strictly_both_empty(tmp_path):
    """🔴 豁免條件是 AND（兩者皆空），不是 OR——寫成 OR 會炸開一個更大的洞。

    board-scoped 建的卡 `created_by` **就是空的**（`_board_writer_v2` 明文
    「不是從房裡發出來的」），身分只在 `created_by_actor_key`。條件一旦沾到
    OR，所有走 Board Library 建的東西就變成人人可改——**而且不會有任何測試
    報錯，因為它「通過」了**（測試Novia 09/08 事前指出）。

    所以這條打的不是豁免本身，是它的邊界：有 actor_key 就代表有建立者。
    """
    app, client = await _client(tmp_path, "patch-exemption-boundary")
    async with app.router.lifespan_context(app), client:
        rid, creator, stranger, _ = await _setup(client)
        board_id = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=creator)).json()["board_id"]
        oid = (await client.post(f"/api/boards/{board_id}/objectives",
                                 json={"title": "板軸建的週期"},
                                 headers={"X-Session-Key": "creator"})
               ).json()["id"]
        r = await _patch(client, "objectives", oid, stranger, title="路人改")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"
