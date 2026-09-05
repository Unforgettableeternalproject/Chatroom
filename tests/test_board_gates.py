"""T-05：狀態機守門。

「Objective 只有在週期確認無誤之後才可完成」是需求原文。它的實作是四道
獨立的閘，而**第 4 道是整組設計的重點**——沒有它，「確認無誤」就只是同一個
agent 連按兩顆按鈕：它會照著把兩顆都按完，因為它剛才才宣告自己做完了。

閘 4 的前提「送審者是 agent 時」同樣不可省。Q4 規定只有人類能確認，若閘 4
再無條件比對，房裡只有一個人類時他自己送審的週期就永遠沒人能確認。
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


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _tree(client, rid, hdr, tasks=1):
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"}, headers=hdr)).json()["id"]
    tids = [(await client.post(f"/api/board/checklists/{cid}/tasks",
                               json={"title": f"任務{i}"},
                               headers=hdr)).json()["id"] for i in range(tasks)]
    return oid, cid, tids


async def _room(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "human-1"})).json()["id"]
    human = await _join(client, rid, "human-1", "Bernie", role="human")
    agent = await _join(client, rid, "agent-1", "Novia")
    return rid, human, agent


async def _task_status(client, tid, status, hdr):
    return await client.post(f"/api/board/tasks/{tid}/status",
                             json={"status": status}, headers=hdr)


async def _finish_everything(client, cid, tids, hdr):
    for tid in tids:
        await _task_status(client, tid, "in_progress", hdr)
        await _task_status(client, tid, "done", hdr)
    await client.post(f"/api/board/checklists/{cid}/status",
                      json={"status": "done"}, headers=hdr)


# ---------- Task ----------

async def test_task_cannot_skip_states(tmp_path):
    """卡在 blocked 的東西不能直接宣告完成——先解除阻塞。

    ⚠️ 這條原本守的是「`todo` 不能直接去 `blocked`」，2026-09-05 改掉了：
    那個守門建立在「每張卡都是在板上被人逐步推進的」這個假設上，而它不成立
    （見下面那條測試）。**狀態機守的應該是「這個宣稱與現況矛盾」，不是
    「你沒有照順序按按鈕」**——後者擋不住任何錯誤，只會逼人先造一段假紀錄。
    """
    app, client = await _client(tmp_path, "task-skip")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        _, _, (tid,) = await _tree(client, rid, agent)
        await _task_status(client, tid, "blocked", agent)
        r = await _task_status(client, tid, "done", agent)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "invalid_transition"
        assert "in_progress" in r.json()["detail"]["allowed"]
        assert "done" not in r.json()["detail"]["allowed"]


async def test_a_task_can_go_straight_from_todo_to_blocked_or_done(tmp_path):
    """`todo` 可以直接去 `blocked` 或 `done`，不必先經過 `in_progress`。

    兩種都是真實的走法，而且逼人繞路的代價是**在板上留下假紀錄**：

    - 直接 `blocked`：一張卡從來沒開工，但前提一開始就不成立（等別人交東西、
      等人類決斷）。最誠實的表達就是 todo → blocked
      （@測試Novia 2026-09-05 撞到：kit 版本不對，卡根本還沒動工）
    - 直接 `done`：認領的當下調查就做完了——例如「這個 bug 早就修好了，
      只是卡的狀態沒收回來」
      （@開發Novia (除錯) 2026-09-05 撞到，D9 與 app.py:2674 兩張都是）

    繞路推出來的 `in_progress` 會被永久記成「它曾經在動工」，而那件事沒有
    發生過。**板是給人讀的紀錄，讓它說謊比讓它少擋一次嚴重。**
    """
    app, client = await _client(tmp_path, "task-todo-direct")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        _, _, (blocked_tid, done_tid) = await _tree(client, rid, agent, tasks=2)

        r = await _task_status(client, blocked_tid, "blocked", agent)
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "blocked"

        r = await _task_status(client, done_tid, "done", agent)
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "done"


async def test_only_holder_or_human_pushes_a_claimed_task(tmp_path):
    app, client = await _client(tmp_path, "task-holder")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        other = await _join(client, rid, "agent-2", "Miller")
        _, _, (tid,) = await _tree(client, rid, agent)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)

        r = await _task_status(client, tid, "in_progress", other)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_claim_holder"
        assert (await _task_status(client, tid, "in_progress",
                                   agent)).status_code == 200
        # 人類不受持有者限制
        assert (await _task_status(client, tid, "blocked",
                                   human)).status_code == 200


async def test_agent_cannot_reopen_its_own_done_task(tmp_path):
    """agent 不能撤銷自己剛做出的宣告。"""
    app, client = await _client(tmp_path, "task-reopen")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        _, _, (tid,) = await _tree(client, rid, agent)
        await _task_status(client, tid, "in_progress", agent)
        await _task_status(client, tid, "done", agent)

        r = await _task_status(client, tid, "in_progress", agent)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "human_only"
        assert (await _task_status(client, tid, "in_progress",
                                   human)).status_code == 200


# ---------- Checklist ----------

async def test_checklist_needs_every_task_settled(tmp_path):
    app, client = await _client(tmp_path, "cl-incomplete")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        _, cid, tids = await _tree(client, rid, agent, tasks=2)
        await _task_status(client, tids[0], "in_progress", agent)
        await _task_status(client, tids[0], "done", agent)

        r = await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"}, headers=agent)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "tasks_incomplete"
        assert r.json()["detail"]["done"] == 1


async def test_a_fully_cancelled_checklist_is_not_complete(tmp_path):
    """全部取消是「這一段不做了」，與「這一段做完了」在驗收上是兩件事。"""
    app, client = await _client(tmp_path, "cl-allcancel")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        _, cid, tids = await _tree(client, rid, agent, tasks=2)
        for tid in tids:
            await _task_status(client, tid, "cancelled", agent)
        r = await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"}, headers=agent)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "tasks_incomplete"


# ---------- Objective 四道閘 ----------

async def test_gate3_review_requires_finished_checklists(tmp_path):
    app, client = await _client(tmp_path, "gate3")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        r = await client.post(f"/api/board/objectives/{oid}/review",
                              headers=agent)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "checklists_incomplete"


async def test_gate2_cannot_verify_before_review(tmp_path):
    app, client = await _client(tmp_path, "gate2")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=human)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "objective_not_in_review"


async def test_gate1_cannot_complete_before_verified(tmp_path):
    """這條就是需求原文「確認無誤之後才可完成」。"""
    app, client = await _client(tmp_path, "gate1")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        await _finish_everything(client, cid, tids, agent)
        await client.post(f"/api/board/objectives/{oid}/review", headers=agent)

        r = await client.post(f"/api/board/objectives/{oid}/complete",
                              headers=human)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "objective_not_verified"


async def test_gate4_agent_cannot_verify_at_all(tmp_path):
    """Q4：確認一律由人。agent 連這顆按鈕都沒有。"""
    app, client = await _client(tmp_path, "gate4-agent")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        await _finish_everything(client, cid, tids, agent)
        await client.post(f"/api/board/objectives/{oid}/review", headers=agent)

        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=agent)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "human_only"


async def test_gate4_human_may_verify_what_they_reviewed(tmp_path):
    """Q8：房裡常態只有一個人類，無條件比對會讓他自己送審的週期永遠卡住。"""
    app, client = await _client(tmp_path, "gate4-human")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        await _finish_everything(client, cid, tids, agent)
        assert (await client.post(f"/api/board/objectives/{oid}/review",
                                  headers=human)).status_code == 200
        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=human)
        assert r.status_code == 200, "閘 4 是用來擋 agent 的，不是擋人"
        assert (await client.post(f"/api/board/objectives/{oid}/complete",
                                  headers=human)).status_code == 200


async def test_full_cycle_agent_reviews_human_verifies(tmp_path):
    """正常的一輪：agent 宣告做完，人確認，人完成。"""
    app, client = await _client(tmp_path, "cycle")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent, tasks=2)
        await _finish_everything(client, cid, tids, agent)
        assert (await client.post(f"/api/board/objectives/{oid}/review",
                                  headers=agent)).status_code == 200
        assert (await client.post(f"/api/board/objectives/{oid}/verify",
                                  headers=human)).status_code == 200
        assert (await client.post(f"/api/board/objectives/{oid}/complete",
                                  headers=human)).status_code == 200
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=human)).json()
        obj = board["objectives"][0]
        assert obj["status"] == "done"
        assert obj["reviewed_by"] and obj["verified_by"] and obj["completed_by"]


async def test_reopen_clears_the_review_trail(tmp_path):
    """不清的話，下一輪送審會留著上一輪的 reviewed_by——閘 4 會比錯對象。"""
    app, client = await _client(tmp_path, "reopen")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        await _finish_everything(client, cid, tids, agent)
        await client.post(f"/api/board/objectives/{oid}/review", headers=agent)
        await client.post(f"/api/board/objectives/{oid}/verify", headers=human)

        r = await client.post(f"/api/board/objectives/{oid}/reopen", headers=human)
        assert r.status_code == 200
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=human)).json()
        obj = board["objectives"][0]
        assert obj["status"] == "active"
        assert obj["reviewed_by"] is None and obj["verified_by"] is None


async def test_agent_cannot_reopen(tmp_path):
    app, client = await _client(tmp_path, "reopen-perm")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        oid, cid, tids = await _tree(client, rid, agent)
        await _finish_everything(client, cid, tids, agent)
        await client.post(f"/api/board/objectives/{oid}/review", headers=agent)
        r = await client.post(f"/api/board/objectives/{oid}/reopen", headers=agent)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "human_only"


async def test_second_agent_still_cannot_verify_after_first_reviews(tmp_path):
    """閘 4 的 agent 條件不是靠「只有一個 agent」成立的。"""
    app, client = await _client(tmp_path, "gate4-two-agents")
    async with app.router.lifespan_context(app), client:
        rid, human, agent = await _room(client)
        other = await _join(client, rid, "agent-2", "Miller")
        oid, cid, tids = await _tree(client, rid, agent)
        await _finish_everything(client, cid, tids, agent)
        await client.post(f"/api/board/objectives/{oid}/review", headers=agent)
        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=other)
        assert r.status_code == 403, "換一個 agent 來按仍然不行"
        assert r.json()["detail"]["code"] == "human_only"
