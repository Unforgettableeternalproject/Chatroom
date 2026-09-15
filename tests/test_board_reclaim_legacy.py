"""v2 的「可接手清單」對 H2 之前領的存量卡也要認得出來。

H2 把 Board 的身分從 session_key 換成 actor_key，但**存量資料沒有回填**：
DB 裡每一張舊卡的 `claim_actor_key` 都是空字串，身分只留在
`claim_session_key`。於是同一份資料在兩條路上給出不同答案——

- `_orphan_claims` 有 `COALESCE(NULLIF(claim_actor_key,''), claim_session_key)`
  回退，判得出「這張卡是誰的」，照樣把它標成孤兒
- `GET /api/boards/{bid}` 的 `reclaimable_tasks` 直接比 `claim_actor_key`，
  對存量卡**恆為空**

結果就是使用者看得到「1 張卡的持有者已不在房內」，卻在可接手清單裡
一張也找不到。兩邊都不會報錯（@開發Novia (除錯) 2026-09-03 DB 實證）。
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


async def _room(client, name="板子房", session_key="claude-owner"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": session_key}


async def _board_with_card(client, rid, hdr, title="存量卡"):
    """寫第一張卡（換軸就發生在這一刻），回傳 (board_id, task_id)。"""
    tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                             json={"title": title},
                             headers=hdr)).json()["id"]
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    return bid, tid


async def _make_legacy_orphan(app, task_id, session_key):
    """把卡改成 H2 之前的樣子：身分只在 session_key，actor_key 是空的。"""
    db = app.state.db
    await db.execute(
        "UPDATE board_task SET claim_state='orphaned', claim_actor_key='',"
        " claim_session_key=?, claim_name='前世的我',"
        " orphaned_at='2026-09-03', orphaned_reason='session 已結束'"
        " WHERE id=?",
        (session_key, task_id))
    await db.commit()


async def test_reclaimable_finds_cards_claimed_before_the_actor_key_migration(
        tmp_path):
    """存量卡（actor_key 空、身分只在 session_key）也要進可接手清單。"""
    app, client = await _client(tmp_path, "legacy_reclaim")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-mine", "諾薇亞")
            bid, tid = await _board_with_card(client, rid, hdr)
            await _make_legacy_orphan(app, tid, "claude-mine")

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=hdr)).json()
            assert [t["id"] for t in body["reclaimable_tasks"]] == [tid]
            assert body["reclaimable_tasks"][0]["claim_name"] == "前世的我"


async def test_reclaimable_does_not_leak_other_peoples_legacy_orphans(
        tmp_path):
    """回退不能把別人的存量孤兒也算成我的——那是把別人的認領交到我手上。"""
    app, client = await _client(tmp_path, "legacy_leak")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-mine", "諾薇亞")
            bid, tid = await _board_with_card(client, rid, hdr)
            await _make_legacy_orphan(app, tid, "claude-someone-else")

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=hdr)).json()
            assert body["reclaimable_tasks"] == []


async def test_actor_key_still_wins_when_both_are_present(tmp_path):
    """兩欄都有值時以 actor_key 為準——回退只在 actor_key 空的時候生效。

    ⚠️ 這條守的是回退的**方向**。寫成 `COALESCE(claim_session_key, ...)`
    或把兩欄 OR 起來也能讓上面兩條過，但那樣一張卡會同時屬於兩個身分。
    """
    app, client = await _client(tmp_path, "legacy_precedence")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-mine", "諾薇亞")
            bid, tid = await _board_with_card(client, rid, hdr)
            db = app.state.db
            await db.execute(
                "UPDATE board_task SET claim_state='orphaned',"
                " claim_actor_key='claude-someone-else',"
                " claim_session_key='claude-mine',"
                " claim_name='前世的我', orphaned_at='2026-09-03'"
                " WHERE id=?", (tid,))
            await db.commit()

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=hdr)).json()
            assert body["reclaimable_tasks"] == []
