"""取消一張卡：**目前的認領者**也可以，不只建立者與人類。

艾斯維爾 2026-09-05 核准（卡 `56a07ff3`）。起因是一張「問題已經自己消失了」
的收尾票：查證的人三件都驗完、把結論寫上卡，卻**按不下最後那一下**——
`cancelled` 原本限建立者或人類成員，而查證的人兩者都不是。

⚠️ 與 Objective 的 `verified` 那道閘**不同，後者維持不動**：確認「真的做完
了」要跑測試、看畫面，那件事只有人做得到。而 cancel 一張「前提已經不成立」
的票不需要人類判斷——**它就是把查證結果登記進去**，而做那個查證的正是認領者。

⚠️ 放行只給 `claim_state='held'` 的**當前**持有者。孤兒卡（原持有者已不在房裡）
不算：那張卡此刻沒有人在做，讓一個已經離開的身分遙控取消它，等於把「認領者
最清楚」這個理由用在一個不再成立的前提上。要取消得先重新認領——那條路本來
就在（`reclaimable_tasks`）。
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
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _room_with_task(client, creator="agent-creator"):
    """房 + 一張卡。回 (rid, 建立者的 hdr, task_id)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    hdr = await _join(client, rid, creator, "建卡的人")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "一張票"}, headers=hdr)).json()["id"]
    return rid, hdr, tid


async def _cancel(client, tid, hdr):
    return await client.post(f"/api/board/tasks/{tid}/status",
                             json={"status": "cancelled"}, headers=hdr)


async def test_the_current_claimer_can_cancel(tmp_path):
    """驗完的人按得下最後那一下——這張卡的全部意義。"""
    app, client = await _client(tmp_path, "cancel_claimer")
    async with app.router.lifespan_context(app), client:
        rid, creator, tid = await _room_with_task(client)
        # 另一個 agent 來認領（不是建立者、不是人類）
        other = await _join(client, rid, "agent-other", "接手的人")
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=other)
        assert r.status_code == 200, r.text

        r = await _cancel(client, tid, other)
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "cancelled"


async def test_someone_who_never_claimed_it_still_cannot(tmp_path):
    """放行的是認領者，不是「房裡任何人」。"""
    app, client = await _client(tmp_path, "cancel_stranger")
    async with app.router.lifespan_context(app), client:
        rid, creator, tid = await _room_with_task(client)
        claimer = await _join(client, rid, "agent-other", "接手的人")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=claimer)

        bystander = await _join(client, rid, "agent-third", "路過的人")
        r = await _cancel(client, tid, bystander)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_only"


async def test_the_creator_can_still_cancel_without_claiming(tmp_path):
    """既有的兩條路不動：建立者仍然可以。"""
    app, client = await _client(tmp_path, "cancel_creator")
    async with app.router.lifespan_context(app), client:
        rid, creator, tid = await _room_with_task(client)
        r = await _cancel(client, tid, creator)
        assert r.status_code == 200, r.text


async def test_an_orphaned_claim_does_not_carry_the_permission(tmp_path):
    """孤兒卡此刻沒有人在做——放行的理由（認領者最清楚）已經不成立。

    要取消得先重新認領，那條路本來就在。
    """
    app, client = await _client(tmp_path, "cancel_orphan")
    async with app.router.lifespan_context(app), client:
        rid, creator, tid = await _room_with_task(client)
        claimer = await _join(client, rid, "agent-other", "接手的人")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=claimer)
        # 離開房間 ⇒ 他領的卡變孤兒
        await client.post(f"/api/rooms/{rid}/leave", headers=claimer)

        again = await _join(client, rid, "agent-other", "接手的人")
        r = await _cancel(client, tid, again)
        assert r.status_code == 403, r.text

        # 重新認領之後就可以了——路徑存在，不是封死
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=again)
        assert r.status_code == 200, r.text
        assert (await _cancel(client, tid, again)).status_code == 200
