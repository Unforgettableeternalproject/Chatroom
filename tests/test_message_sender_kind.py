"""訊息帶 sender_kind 快照（REMOTE-OPS-PLAN §12 待辦 3）。

run 成員結束後**不進成員名冊**，於是 client 從名冊反查「這則是誰說的」就
查不到，只能退回 `other`——一輪 run 講過的每一句話，在它結束的那一刻全部
變成來路不明的雜訊，而沒有任何一端會報錯。

快照存在訊息上：發話當下是什麼 kind 就是什麼，之後名冊怎麼變都不改寫。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    # `_bind_workspace` 要拿得到 db；換成各個呼叫點多傳一個 app 的話，
    # 漏掉一處的症狀是一條跟工作區無關的測試跑出 409
    client.hub_app = app
    return app, client


async def _bind_workspace(client, rid, workspace="ai-website"):
    # 工作房要先綁工作區才派得了工（Hub 契約）。這裡直接寫欄位而不走
    # `POST /api/rooms/{id}/workspace`：那個端點要求綁定當下已經有執行器
    # 服務這個 key，而這些測試多半是先建房、後註冊執行器。綁定端點本身的
    # 契約在 tests/test_room_workspace.py
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET workspace_key=? WHERE id=?",
                     (workspace, rid))
    await db.commit()


async def _ops_room(client, key="human-a", workspace="ai-website"):
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": key})
    assert r.status_code == 200, r.text
    rid = r.json()["id"]
    await _bind_workspace(client, rid, workspace)
    return rid


async def _join_human(client, rid, key="human-a", name="艾斯維爾"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _register_runner(client):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": "ex1",
                                "projects": ["ai-website"],
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    return r.json()["runner"]["id"], {"X-Runner-Token": r.json()["runner_token"]}


async def _messages(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}/messages", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["messages"]


async def test_run_member_message_keeps_its_kind_after_leaving(tmp_path):
    """run 結束、成員離房之後，那則訊息仍說得出它是 claude 說的。"""
    app, client = await _client(tmp_path, "snapshot")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner, rhdr = await _register_runner(client)

        run_id = (await client.post(
            f"/api/rooms/{rid}/runs",
            json={"kind": "investigate", "project": "ai-website",
                  "ref": "task-1", "brief": "查一下"},
            headers=hdr)).json()["run"]["id"]
        await client.post(f"/api/runners/{runner}/claim", headers=rhdr)
        await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "running", "runner_id": runner},
                          headers=rhdr)

        # run 身分進房、說一句話
        j = await client.post(f"/api/rooms/{rid}/join",
                              json={"kind": "claude", "role": "agent",
                                    "session_key": f"claude-run-{run_id}",
                                    "preferred_name": "Novia-run"})
        assert j.status_code == 200, j.text
        ahdr = {"X-Participant-Id": j.json()["participant_id"]}
        post = await client.post(f"/api/rooms/{rid}/messages",
                                 json={"content": "查完了"}, headers=ahdr)
        assert post.status_code == 200, post.text
        said_seq = post.json()["seq"]

        before = [m for m in await _messages(client, rid, hdr)
                  if m["seq"] == said_seq][0]
        assert before["sender_kind"] == "claude"

        # run 收工：成員被請出房，名冊上再也查不到他
        done = await client.post(f"/api/runs/{run_id}/report",
                                 json={"status": "done", "runner_id": runner,
                                       "result": "ok"}, headers=rhdr)
        assert done.status_code == 200, done.text
        room = (await client.get(f"/api/rooms/{rid}", headers=hdr)).json()
        assert all(p["display_name"] != "Novia-run"
                   for p in room["participants"])

        after = [m for m in await _messages(client, rid, hdr)
                 if m["seq"] == said_seq][0]
        assert after["sender_kind"] == "claude", "離房後就查不出 kind 了"


async def test_human_and_system_messages(tmp_path):
    """人類的訊息帶 human；系統訊息不編造發話者。"""
    app, client = await _client(tmp_path, "kinds")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        await client.post(f"/api/rooms/{rid}/messages",
                          json={"content": "早"}, headers=hdr)
        msgs = await _messages(client, rid, hdr)
        chat = [m for m in msgs if m["kind"] == "chat"]
        assert chat and all(m["sender_kind"] == "human" for m in chat)
        for m in msgs:
            if m["sender_id"] is None:
                assert m["sender_kind"] == ""


async def test_migration_backfills_old_messages(tmp_path):
    """舊訊息回填一次：JOIN 得到 participant 就填，拿不到就留空。"""
    path = str(tmp_path / "old.db")
    db = await open_db(path)
    now = "2026-09-01T00:00:00Z"
    await db.execute("INSERT INTO room (id, name, created_at, next_seq)"
                     " VALUES ('r1','房',?,3)", (now,))
    await db.execute(
        "INSERT INTO participant (id, room_id, kind, session_key,"
        " display_name, joined_at, last_seen_at)"
        " VALUES ('p1','r1','codex','codex-1','米絲媞',?,?)", (now, now))
    await db.execute(
        "INSERT INTO message (id, room_id, seq, sender_id, content, created_at)"
        " VALUES ('m1','r1',1,'p1','舊話',?)", (now,))
    # 發話者的成員列已經不在了：說不出來就留空，不猜。
    # 這一列在正常路徑上建不出來（FK 擋著），但**舊庫裡真的有**——
    # `board_task` 那批重建就是為了拆掉這類跨生命週期的外鍵
    # ⚠️ `PRAGMA foreign_keys` 在交易裡是**無聲的 no-op**，所以先 commit
    await db.commit()
    await db.execute("PRAGMA foreign_keys=OFF")
    await db.execute(
        "INSERT INTO message (id, room_id, seq, sender_id, content, created_at)"
        " VALUES ('m2','r1',2,'gone','更舊的話',?)", (now,))
    await db.commit()
    await db.execute("PRAGMA foreign_keys=ON")
    # 回到欄位加上之前的狀態：快照清空、版次退回
    await db.execute("UPDATE message SET sender_kind=''")
    await db.execute("PRAGMA user_version=3")
    await db.commit()
    await db.close()

    db = await open_db(path)
    rows = {r["id"]: r["sender_kind"] for r in await (await db.execute(
        "SELECT id, sender_kind FROM message")).fetchall()}
    await db.close()
    assert rows["m1"] == "codex"
    assert rows["m2"] == ""
