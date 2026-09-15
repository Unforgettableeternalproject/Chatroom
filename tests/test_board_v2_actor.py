"""Board v2：卡片上的身分改用持久的 actor_key。

v1 的 `created_by` / `assignee` / `completed_by` 全是 participant 外鍵，
而 **participant 隨著離房消失**——板上「誰建的、誰在做、誰確認的」在那之後
只剩一個名字快照，認不出「這是同一個人回來了」。v2 一律改記 actor_key
（規範化後的 session_key），舊欄位並存不刪（BOARD_DESIGN §11 步驟 1）。

這裡驗的是**寫入端真的有寫進去**。少寫任何一個欄位都不會報錯：
卡片照建、API 照回 200，只有半年後想追「這是誰做的」時才會發現它是空的。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import actor_key, create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _room(client):
    return (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]


async def test_actor_key_normalisation():
    """去空白，但**不轉小寫**。

    統一小寫能吸收人為輸入差異，代價是兩把只差大小寫的 key 被併成同一個
    人——那是把別人的認領交到你手上，比多出一個身分嚴重得多。
    """
    assert actor_key("  claude-abc  ") == "claude-abc"
    assert actor_key(None) == ""
    assert actor_key("Claude-ABC") != actor_key("claude-abc")


async def test_created_by_actor_key_on_all_three_layers(tmp_path):
    app, client = await _client(tmp_path, "actor_create")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-alice", "Alice")
            oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                     json={"title": "週期"},
                                     headers=hdr)).json()["id"]
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "階段"},
                                     headers=hdr)).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": "一件事"},
                                     headers=hdr)).json()["id"]
            db = app.state.db
            for table, iid in (("board_objective", oid),
                               ("board_checklist", cid),
                               ("board_task", tid)):
                row = await (await db.execute(
                    f"SELECT created_by_actor_key FROM {table} WHERE id=?",
                    (iid,))).fetchone()
                assert row["created_by_actor_key"] == "claude-alice", table


async def test_uncategorised_containers_also_carry_actor_key(tmp_path):
    """「隨手記」自動長出來的那兩層也算數。

    它們是 Hub 代建的，最容易在補欄位時被漏掉——而板上多數卡片其實掛在
    這兩層底下。
    """
    app, client = await _client(tmp_path, "actor_uncat")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-bob", "Bob")
            await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "隨手記"}, headers=hdr)
            db = app.state.db
            for table in ("board_objective", "board_checklist"):
                row = await (await db.execute(
                    f"SELECT created_by_actor_key FROM {table}"
                    " WHERE title='未分類'")).fetchone()
                assert row["created_by_actor_key"] == "claude-bob", table


async def test_claim_and_release_track_actor_key(tmp_path):
    app, client = await _client(tmp_path, "actor_claim")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-carol", "Carol")
            tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                                     json={"title": "接案"},
                                     headers=hdr)).json()["id"]
            db = app.state.db
            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            row = await (await db.execute(
                "SELECT claim_actor_key FROM board_task WHERE id=?",
                (tid,))).fetchone()
            assert row["claim_actor_key"] == "claude-carol"

            await client.post(f"/api/board/tasks/{tid}/release", headers=hdr)
            row = await (await db.execute(
                "SELECT claim_actor_key FROM board_task WHERE id=?",
                (tid,))).fetchone()
            assert row["claim_actor_key"] == "", "放掉了卻還掛著身分"


async def test_assignee_and_source_room_are_recorded(tmp_path):
    """指定執行者記 actor_key；來源訊息記房間。

    v1 只存 `source_seq`——一房一板時夠用，但一塊板掛多間房之後，
    光有 seq 講不出「是哪一間房的第幾則」。
    """
    app, client = await _client(tmp_path, "actor_assign")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            boss = await _join(client, rid, "human-x", "艾斯維爾", role="human")
            worker = await _join(client, rid, "claude-dave", "Dave")
            wid = worker["X-Participant-Id"]
            tid = (await client.post(
                f"/api/rooms/{rid}/board/tasks",
                json={"title": "指給人的卡", "assignee_participant_id": wid,
                      "source_seq": 7},
                headers=boss)).json()["id"]
            row = await (await app.state.db.execute(
                "SELECT assignee_actor_key, assigned_by_actor_key,"
                " source_room_id, source_seq FROM board_task WHERE id=?",
                (tid,))).fetchone()
            assert row["assignee_actor_key"] == "claude-dave"
            assert row["assigned_by_actor_key"] == "human-x"
            assert row["source_room_id"] == rid
            assert row["source_seq"] == 7


async def test_review_verify_and_reopen_carry_actor_key(tmp_path):
    """收尾三步各記一份，**打回時要一起清乾淨**。

    少清一個，下一輪送審會拿到上一輪的 actor_key——而「送審的人不能自己
    確認」那道閘判的正是這個值。
    """
    app, client = await _client(tmp_path, "actor_gates")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            agent = await _join(client, rid, "claude-eve", "Eve")
            human = await _join(client, rid, "human-y", "人類", role="human")
            oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                     json={"title": "週期"},
                                     headers=agent)).json()["id"]
            # 送審有閘：底下的階段要全部收尾，而階段收尾又要它底下的卡收尾
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "階段"},
                                     headers=agent)).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": "一件事"},
                                     headers=agent)).json()["id"]
            for step in ("in_progress", "done"):   # todo 不能直接跳 done
                r = await client.post(f"/api/board/tasks/{tid}/status",
                                      json={"status": step}, headers=agent)
                assert r.status_code == 200, r.text
            r = await client.post(f"/api/board/checklists/{cid}/status",
                                  json={"status": "done"}, headers=agent)
            assert r.status_code == 200, r.text
            db = app.state.db
            r = await client.post(f"/api/board/objectives/{oid}/review",
                                  headers=agent)
            assert r.status_code == 200, r.text
            row = await (await db.execute(
                "SELECT reviewed_by_actor_key FROM board_objective WHERE id=?",
                (oid,))).fetchone()
            assert row["reviewed_by_actor_key"] == "claude-eve"

            r = await client.post(f"/api/board/objectives/{oid}/verify",
                                  headers=human)
            assert r.status_code == 200, r.text
            row = await (await db.execute(
                "SELECT verified_by_actor_key FROM board_objective WHERE id=?",
                (oid,))).fetchone()
            assert row["verified_by_actor_key"] == "human-y"

            r = await client.post(f"/api/board/objectives/{oid}/reopen",
                                  headers=human)
            assert r.status_code == 200, r.text
            row = await (await db.execute(
                "SELECT reviewed_by_actor_key, verified_by_actor_key,"
                " completed_by_actor_key FROM board_objective WHERE id=?",
                (oid,))).fetchone()
            assert row["reviewed_by_actor_key"] == ""
            assert row["verified_by_actor_key"] == ""
            assert row["completed_by_actor_key"] == ""
