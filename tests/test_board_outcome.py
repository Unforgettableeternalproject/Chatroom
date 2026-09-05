"""板的結局：`outcome` 與 `status` 是兩軸，不是同一個欄位的四個值。

艾斯維爾 2026-09-05 裁定 A（兩軸分離）：

| 軸 | 值 | 回答的問題 | 可逆 |
|---|---|---|---|
| `status` | active / archived | 現在還能不能編輯 | 是 |
| `outcome` | ""／completed／abandoned | 這份工作的結局是什麼 | 可 reopen |

塞成四選一的話，「完成**且**收起來」——最常見的收尾——反而表達不出來。
同一個判斷在 Task 那裡做過：status 與 claim 正交，不把 `claimed` 放進 status。
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


async def _join(client, rid, who, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": who,
        "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": who}


async def _room(client, who="human-1", name="房"):
    r = await client.post("/api/rooms", json={"name": name,
                                              "session_key": who})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _board(client, hdr, name="板"):
    r = await client.post("/api/boards", json={"name": name,
                                               "visibility": "public"},
                          headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _settle(client, bid, hdr, outcome):
    return await client.post(f"/api/boards/{bid}/outcome",
                             json={"outcome": outcome}, headers=hdr)


async def _library_ids(client, hdr, **params):
    r = await client.get("/api/boards", params=params, headers=hdr)
    assert r.status_code == 200, r.text
    return [b["id"] for b in r.json()["boards"]]


async def test_a_new_board_has_no_outcome_yet(tmp_path):
    """沒有結局是空字串，不是缺欄位——client 分不出「還在做」與「舊版
    Hub 不會回」的話，兩者會被畫成同一個樣子。"""
    app, client = await _client(tmp_path, "oc_new")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
        assert body["outcome"] == ""


async def test_a_human_owner_can_settle_and_reopen(tmp_path):
    """完成是可逆的——不可逆的只有刪除（封存那條的同一個判斷）。"""
    app, client = await _client(tmp_path, "oc_settle")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 200, r.text
        assert r.json()["outcome"] == "completed"

        r = await _settle(client, bid, hdr, "")
        assert r.status_code == 200, r.text
        assert (await client.get(f"/api/boards/{bid}",
                                 headers=hdr)).json()["outcome"] == ""


async def test_an_agent_cannot_declare_the_work_finished(tmp_path):
    """限人類，照 Objective `verified` 那道閘的同一個理由：判斷「真的做完
    了嗎」要跑測試、看畫面，那件事只有人做得到。"""
    app, client = await _client(tmp_path, "oc_agent")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client, who="agent-1")
        hdr = await _join(client, rid, "agent-1", "諾薇亞")
        bid = await _board(client, hdr)

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_only"


async def test_outcome_and_archived_are_independent(tmp_path):
    """「完成**且**收起來」要表達得出來——那正是四值互斥做不到的事。"""
    app, client = await _client(tmp_path, "oc_orthogonal")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        await _settle(client, bid, hdr, "completed")
        r = await client.post(f"/api/boards/{bid}/archive", headers=hdr)
        assert r.status_code == 200, r.text

        body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
        assert body["status"] == "archived"
        assert body["outcome"] == "completed", "封存把結局洗掉了"


async def test_settled_boards_leave_the_library_but_can_be_asked_for(tmp_path):
    """卡上那句「顯示至完成或廢止」——收尾之後預設不佔分頁，但要找得回來。"""
    app, client = await _client(tmp_path, "oc_library")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        live = await _board(client, hdr, "還在做")
        done = await _board(client, hdr, "做完了")

        await _settle(client, done, hdr, "completed")

        ids = await _library_ids(client, hdr)
        assert live in ids
        assert done not in ids, "收尾的板還佔著分頁"

        ids = await _library_ids(client, hdr, outcome="completed")
        assert done in ids
        assert live not in ids

        ids = await _library_ids(client, hdr, outcome="any")
        assert live in ids and done in ids


async def test_an_unknown_outcome_is_refused(tmp_path):
    """值不合法要明確擋下：默默存進去的話，分堆會慢慢失效而不報錯。"""
    app, client = await _client(tmp_path, "oc_bad")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        r = await _settle(client, bid, hdr, "finished")
        assert r.status_code == 422, r.text


async def test_the_library_row_says_what_the_outcome_was(tmp_path):
    """清單**過濾**得掉收尾的板，但每一列也要說得出自己的結局是什麼。

    ⚠️ 與 `custom_tags` 那次同型（09/05 卡 d10ae5f2）：**過濾做了、值沒回**。
    切到「已收尾」時每一列都不知道自己是 completed 還是 abandoned——而那兩者
    在畫面上必須分得出來，「做完了」與「不做了」是兩件事。
    """
    app, client = await _client(tmp_path, "oc_row")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        done = await _board(client, hdr, "做完了")
        dropped = await _board(client, hdr, "不做了")
        live = await _board(client, hdr, "還在做")

        await _settle(client, done, hdr, "completed")
        await _settle(client, dropped, hdr, "abandoned")

        r = await client.get("/api/boards", params={"outcome": "any"},
                             headers=hdr)
        rows = {b["id"]: b for b in r.json()["boards"]}
        assert rows[done]["outcome"] == "completed"
        assert rows[dropped]["outcome"] == "abandoned"
        assert rows[live]["outcome"] == ""
