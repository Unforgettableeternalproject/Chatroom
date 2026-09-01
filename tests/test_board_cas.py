"""狀態轉移的併發正確性，與 assignee 的房間歸屬（審核用 Codex 於 v1 驗收發現）。

轉移守門原本做在 Python 對 `row` 那份快照的判斷上，而讀到寫之間有 await：
兩路同時把 `in_progress` 推向 `done` 與 `cancelled`，**兩邊都通過檢查、
兩邊都回 200**，最後只剩後寫的那個。

後果不只是狀態被覆蓋。`done` 那條分支會發一則系統訊息，所以板上會寫著
`cancelled`、房裡卻留著一則「某某完成了任務」——而兩邊的呼叫者都收到成功。

⚠️ 這裡**不能**用「先推到 done，再推 cancelled」來測：那條路徑會被轉移表
本身擋下（done 不能去 cancelled），測到的是轉移表不是 CAS。必須讓兩路讀到
同一份快照，所以用 gather。
"""

import asyncio

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


async def _join(client, rid, session_key, name, role="human"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return r.json()["participant_id"]


async def _room(client, session_key="owner", name="板子房"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _tree(client, rid, hdr):
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段一"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "一件事"}, headers=hdr)).json()["id"]
    return oid, cid, tid


async def test_two_routes_cannot_both_settle_the_same_task(tmp_path):
    app, client = await _client(tmp_path, "cas_task")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        pid = await _join(client, rid, "human-1", "艾斯維爾")
        # 房裡要有第二個人，完成通知的收件名單才不是空的——排除完成者本人
        # 之後沒人可收的話，那則系統訊息根本不會發，下面的斷言就測不到東西
        await _join(client, rid, "agent-1", "諾薇亞", role="agent")
        hdr = {"X-Participant-Id": pid}
        _, _, tid = await _tree(client, rid, hdr)
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
        assert r.status_code == 200, r.text

        done, cancelled = await asyncio.gather(
            client.post(f"/api/board/tasks/{tid}/status",
                        json={"status": "done"}, headers=hdr),
            client.post(f"/api/board/tasks/{tid}/status",
                        json={"status": "cancelled"}, headers=hdr),
        )
        codes = sorted([done.status_code, cancelled.status_code])
        assert codes == [200, 409], f"兩路都成功了：{codes}"

        winner = done if done.status_code == 200 else cancelled
        row = await (await app.state.db.execute(
            "SELECT status FROM board_task WHERE id=?", (tid,),
        )).fetchone()
        assert row["status"] == winner.json()["status"], "落地的不是回 200 的那個"

        # 板上寫著 cancelled、房裡卻有一則說它完成了——這是最難查的殘局
        msgs = await (await app.state.db.execute(
            "SELECT COUNT(*) AS n FROM message WHERE room_id=?"
            " AND system_event='board_task_done'", (rid,),
        )).fetchone()
        expected = 1 if row["status"] == "done" else 0
        assert msgs["n"] == expected, "完成訊息與實際落地的狀態對不上"


async def test_two_routes_cannot_both_settle_the_same_checklist(tmp_path):
    app, client = await _client(tmp_path, "cas_checklist")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        pid = await _join(client, rid, "human-1", "艾斯維爾")
        hdr = {"X-Participant-Id": pid}
        _, cid, tid = await _tree(client, rid, hdr)
        for target in ("in_progress", "done"):
            r = await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": target}, headers=hdr)
            assert r.status_code == 200, r.text

        a, b = await asyncio.gather(
            client.post(f"/api/board/checklists/{cid}/status",
                        json={"status": "done"}, headers=hdr),
            client.post(f"/api/board/checklists/{cid}/status",
                        json={"status": "cancelled"}, headers=hdr),
        )
        assert sorted([a.status_code, b.status_code]) == [200, 409]


async def test_two_routes_cannot_both_cancel_the_same_objective(tmp_path):
    """`_objective_set` 是五個端點共用的 helper，CAS 放在它裡面。

    放在呼叫端的話，漏掉一個不會有任何地方報錯。
    """
    app, client = await _client(tmp_path, "cas_objective")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        pid = await _join(client, rid, "human-1", "艾斯維爾")
        hdr = {"X-Participant-Id": pid}
        oid, _, _ = await _tree(client, rid, hdr)

        a, b = await asyncio.gather(
            client.post(f"/api/board/objectives/{oid}/cancel", headers=hdr),
            client.post(f"/api/board/objectives/{oid}/cancel", headers=hdr),
        )
        assert sorted([a.status_code, b.status_code]) == [200, 409]


async def test_an_assignee_from_another_room_is_refused(tmp_path):
    """`assignee_participant_id` 的外鍵只保證 id 存在，不保證它屬於本房。"""
    app, client = await _client(tmp_path, "assignee_room")
    async with app.router.lifespan_context(app), client:
        a_rid = await _room(client, "owner-a", "A 房")
        b_rid = await _room(client, "owner-b", "B 房")
        a_pid = await _join(client, a_rid, "human-a", "艾斯維爾")
        b_pid = await _join(client, b_rid, "human-b", "外人")
        hdr = {"X-Participant-Id": a_pid}
        _, cid, tid = await _tree(client, a_rid, hdr)

        # 建立時
        r = await client.post(f"/api/board/checklists/{cid}/tasks",
                              json={"title": "掛給外人",
                                    "assignee_participant_id": b_pid},
                              headers=hdr)
        assert r.status_code == 400, r.text
        assert r.json()["detail"]["code"] == "assignee_not_in_room"

        # 事後 PATCH
        r = await client.patch(f"/api/board/tasks/{tid}",
                               json={"assignee_participant_id": b_pid},
                               headers=hdr)
        assert r.status_code == 400, r.text
        assert r.json()["detail"]["code"] == "assignee_not_in_room"

        # 錨點：同房的人照樣指得動，別把守門寫得太寬
        r = await client.patch(f"/api/board/tasks/{tid}",
                               json={"assignee_participant_id": a_pid},
                               headers=hdr)
        assert r.status_code == 200, r.text
