"""T-06：兩條通知規則。

需求只指名了兩條要通知的事：Task 完成通知「執行該 Task 以外的其他人」、
Objective 完成通知所有人。**其餘 board 變動一律不喚醒任何人**——喚醒是打擾，
一個十人在跑的 board 每分鐘會動好幾次，逐筆喚醒等於把每個 agent 的上下文
塞滿別人的進度。

「其餘一律不通知」那條測起來像是在測「什麼都沒發生」，但它守的是一個很容易
在加功能時被打破的預設值，所以寫成明確的斷言。
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


async def _room(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "human-1"})).json()["id"]
    human = await _join(client, rid, "human-1", "Bernie", role="human")
    a1 = await _join(client, rid, "agent-1", "Novia")
    a2 = await _join(client, rid, "agent-2", "Miller")
    return rid, human, a1, a2


async def _tree(client, rid, hdr, tasks=1):
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"}, headers=hdr)).json()["id"]
    tids = [(await client.post(f"/api/board/checklists/{cid}/tasks",
                               json={"title": f"任務{i}"},
                               headers=hdr)).json()["id"] for i in range(tasks)]
    return oid, cid, tids


async def _events(client, rid, hdr, event):
    msgs = (await client.get(f"/api/rooms/{rid}/messages",
                             headers=hdr)).json()["messages"]
    return [m for m in msgs if m["system_event"] == event]


async def _status(client, tid, status, hdr):
    return await client.post(f"/api/board/tasks/{tid}/status",
                             json={"status": status}, headers=hdr)


async def test_task_done_notifies_everyone_except_the_one_who_did_it(tmp_path):
    app, client = await _client(tmp_path, "task-done")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        _, _, (tid,) = await _tree(client, rid, a1)
        await _status(client, tid, "in_progress", a1)
        await _status(client, tid, "done", a1)

        (msg,) = await _events(client, rid, human, "board_task_done")
        assert set(msg["mentions"]) == {"Bernie", "Miller"}
        assert "Novia" not in msg["mentions"], "完成者不該被自己的完成叫醒"
        assert "任務0" in msg["content"]


async def test_objective_done_notifies_everyone_including_the_verifier(tmp_path):
    """需求原文就是「全部」——他確認的是週期，不是自己那張卡。"""
    app, client = await _client(tmp_path, "obj-done")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        oid, cid, (tid,) = await _tree(client, rid, a1)
        await _status(client, tid, "in_progress", a1)
        await _status(client, tid, "done", a1)
        await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=a1)
        await client.post(f"/api/board/objectives/{oid}/review", headers=a1)
        await client.post(f"/api/board/objectives/{oid}/verify", headers=human)
        await client.post(f"/api/board/objectives/{oid}/complete", headers=human)

        (msg,) = await _events(client, rid, human, "board_objective_done")
        assert set(msg["mentions"]) == {"Bernie", "Novia", "Miller"}


async def test_every_other_board_change_wakes_nobody(tmp_path):
    """喚醒是打擾。需求只指名兩條要通知的事，其餘的預設就是不通知。"""
    app, client = await _client(tmp_path, "quiet")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        oid, cid, (tid,) = await _tree(client, rid, a1)
        before = len((await client.get(f"/api/rooms/{rid}/messages",
                                       headers=human)).json()["messages"])

        await client.post(f"/api/board/tasks/{tid}/claim", headers=a1)
        await client.patch(f"/api/board/tasks/{tid}",
                           json={"description": "改個描述"}, headers=a1)
        await _status(client, tid, "in_progress", a1)
        await _status(client, tid, "blocked", a1)
        await client.post(f"/api/board/tasks/{tid}/release", headers=a1)
        await client.post(f"/api/rooms/{rid}/board/reorder", json={
            "kind": "objective",
            "items": [{"id": oid, "order_index": 3}]}, headers=a1)

        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=human)).json()["messages"]
        assert len(msgs) == before, f"這些動作都不該進訊息流：{msgs[before:]}"


async def test_checklist_completion_is_silent(tmp_path):
    """Q5 定案：Checklist 完成不通知。"""
    app, client = await _client(tmp_path, "cl-silent")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        oid, cid, (tid,) = await _tree(client, rid, a1)
        await _status(client, tid, "in_progress", a1)
        await _status(client, tid, "done", a1)
        before = [m["system_event"] for m in
                  (await client.get(f"/api/rooms/{rid}/messages",
                                    headers=human)).json()["messages"]]
        await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=a1)
        after = [m["system_event"] for m in
                 (await client.get(f"/api/rooms/{rid}/messages",
                                   headers=human)).json()["messages"]]
        assert after == before


async def test_subagents_are_not_in_the_audience(tmp_path):
    """subagent 沒有自己的 watcher——mention 它只會經父層再叫醒一次。"""
    app, client = await _client(tmp_path, "sub-audience")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        # a2 底下派一個 subagent
        parent_id = a2["X-Participant-Id"]
        await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": "agent-2/sub-1",
            "preferred_name": "戴爾", "parent_participant_id": parent_id})

        _, _, (tid,) = await _tree(client, rid, a1)
        await _status(client, tid, "in_progress", a1)
        await _status(client, tid, "done", a1)

        (msg,) = await _events(client, rid, human, "board_task_done")
        assert "戴爾" not in msg["mentions"]
        assert set(msg["mentions"]) == {"Bernie", "Miller"}


# ---------- 週期收尾的兩步（艾斯維爾 2026-09-01 拍板補上）----------

async def _finish_to_review(client, rid, cid, tid, hdr):
    await _status(client, tid, "in_progress", hdr)
    await _status(client, tid, "done", hdr)
    await client.post(f"/api/board/checklists/{cid}/status",
                      json={"status": "done"}, headers=hdr)


async def test_review_wakes_humans_only(tmp_path):
    """送審與確認是整個設計裡僅有的兩個「非人類不可」的步驟。

    其餘 board 變動靠「沒被通知的人自己會來看板」撐著——唯獨這兩步的收件人
    是**沒在看板子的人類**，而他正是唯一能讓週期往下走的人。忘了就停在這裡，
    板上一切正常、沒有任何地方會報錯。
    """
    app, client = await _client(tmp_path, "review-notify")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        oid, cid, (tid,) = await _tree(client, rid, a1)
        await _finish_to_review(client, rid, cid, tid, a1)
        await client.post(f"/api/board/objectives/{oid}/review", headers=a1)

        (msg,) = await _events(client, rid, human, "board_objective_review")
        assert msg["mentions"] == ["Bernie"], "agent 不必被叫醒，它們本來就在看板"
        assert "週期一" in msg["content"]


async def test_a_human_reviewer_does_not_wake_themselves(tmp_path):
    app, client = await _client(tmp_path, "review-self")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        oid, cid, (tid,) = await _tree(client, rid, a1)
        await _finish_to_review(client, rid, cid, tid, a1)
        await client.post(f"/api/board/objectives/{oid}/review", headers=human)
        assert await _events(client, rid, human,
                             "board_objective_review") == []


async def test_verified_wakes_humans_including_the_verifier(tmp_path):
    """確認者本人也要收——他正是下一步（完成）要按的那個人。

    verified 比 review 更容易停住：App 的金色會退掉，畫面主動告訴你
    「已確認」，看起來像收工了而實際還差一步。
    """
    app, client = await _client(tmp_path, "verified-notify")
    async with app.router.lifespan_context(app), client:
        rid, human, a1, a2 = await _room(client)
        oid, cid, (tid,) = await _tree(client, rid, a1)
        await _finish_to_review(client, rid, cid, tid, a1)
        await client.post(f"/api/board/objectives/{oid}/review", headers=a1)
        await client.post(f"/api/board/objectives/{oid}/verify", headers=human)

        (msg,) = await _events(client, rid, human, "board_objective_verified")
        assert msg["mentions"] == ["Bernie"]
        assert "完成" in msg["content"], "要說得出下一步是什麼"
