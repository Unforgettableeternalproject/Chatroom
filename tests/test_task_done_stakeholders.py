"""task 完成只叫醒利害關係人（艾斯維爾 2026-09-08 裁定）。

起因是測試Novia 算出來的實際成本：一天至少 9 則 `board_task_done`，每則
mention 全房 4~5 人 ⇒ **約 45 次 agent 喚醒**，而多數對收件人沒有行動價值
（UI 收一張 App 卡，Hub 和測試端都被叫醒，但兩邊都不會因此做任何事）。
這與契約第一條「不要一次 tag 太多人」直接衝突。

分層（同日定案，兩層用同一條邏輯）：

- **task 層**＝局部事件：mention 縮到利害關係人，訊息只發來源房
- **objective 層**（週期收尾）＝「這一段工作結束了」：維持全房，且發到
  每一間 active 掛接房

利害關係人 = 認領者 ∪ 被指派者 ∪ supervisor ∪ 追蹤者，完成者自己不算。

順帶關掉一個既有的洞：舊的定向分支掃每一間 active 掛接房、每房各 mention
一次 ⇒ **同一個追蹤者在兩間房裡被叫兩次**。「一個事件叫醒一個人一次」。
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


async def _room(client, name, key):
    r = await client.post("/api/rooms", json={"name": name, "session_key": key})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _done_message(client, rid, hdr):
    """回房內最後一則 board_task_done（沒有就 None）。"""
    r = await client.get(f"/api/rooms/{rid}/messages",
                         params={"after_seq": 0, "limit": 200}, headers=hdr)
    hits = [m for m in r.json()["messages"]
            if m["system_event"] == "board_task_done"]
    return hits[-1] if hits else None


async def _notices(client, key):
    r = await client.get("/api/board/notices", params={"unread_only": True},
                         headers={"X-Session-Key": key})
    return r.json()["notices"]


async def _card(client, rid, hdr, title="一張卡"):
    cid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                             json={"title": title},
                             headers=hdr)).json()["id"]
    return cid


async def test_only_stakeholders_get_woken(tmp_path):
    """房裡的路人不該被叫醒——他不會因為這則訊息做任何事。"""
    app, client = await _client(tmp_path, "stake_basic")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, rid, "agent-worker", "認領的人")
        await _join(client, rid, "agent-bystander", "路人")
        await _join(client, rid, "agent-sup", "監督者")
        assert (await client.post(f"/api/rooms/{rid}/board/supervisor",
                                  json={"session_key": "agent-sup"},
                                  headers=human)).status_code == 200

        tid = await _card(client, rid, human)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=worker)
        assert (await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": "done"},
                                  headers=worker)).status_code == 200

        msg = await _done_message(client, rid, human)
        assert msg is not None, "完成一張卡連留痕都沒有"
        got = set(msg["mentions"])
        assert "監督者" in got, f"supervisor 沒被叫到：{got}"
        assert "路人" not in got, f"路人被叫醒了：{got}"
        assert "認領的人" not in got, f"完成者被自己的動作叫醒了：{got}"


async def test_the_assignee_counts_too(tmp_path):
    """被指派者也是利害關係人——他本來就在等這張卡。"""
    app, client = await _client(tmp_path, "stake_assignee")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        target = await _join(client, rid, "agent-target", "被指派的人")
        await _join(client, rid, "agent-other", "路人")

        tid = await _card(client, rid, human)
        r = await client.post(f"/api/board/tasks/{tid}/assign",
                              json={"target_session_key": "agent-target"},
                              headers=human)
        assert r.status_code == 200, f"指派失敗，這條測試不成立：{r.text}"
        await client.post(f"/api/board/tasks/{tid}/claim", headers=target)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=human)

        got = set((await _done_message(client, rid, human))["mentions"])
        assert "被指派的人" in got, f"被指派者沒被叫到：{got}"
        assert "路人" not in got, f"路人被叫醒了：{got}"


async def test_it_does_not_leak_into_other_attached_rooms(tmp_path):
    """task 完成只發來源房——跨房的讀者該看板，不該靠訊息流（決策 09/08）。"""
    app, client = await _client(tmp_path, "stake_scope")
    async with app.router.lifespan_context(app), client:
        ra = await _room(client, "A房", "human-1")
        human_a = await _join(client, ra, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, ra, "agent-worker", "認領的人")
        tid = await _card(client, ra, human_a)
        bid = (await client.get(f"/api/rooms/{ra}/board",
                                headers=human_a)).json()["board_id"]

        rb = await _room(client, "B房", "human-1")
        human_b = await _join(client, rb, "human-1", "艾斯維爾", role="human")
        assert (await client.post(f"/api/boards/{bid}/rooms/{rb}",
                                  headers=human_b)).status_code == 200
        # 🔑 認領者在 B 房也有身分——舊的定向分支會在兩間房各叫他一次
        await _join(client, rb, "agent-worker", "認領的人")

        await client.post(f"/api/board/tasks/{tid}/claim", headers=worker)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=worker)

        assert await _done_message(client, ra, human_a) is not None, "來源房沒有留痕"
        assert await _done_message(client, rb, human_b) is None, (
            "task 完成外漏到另一間掛接房了——同一個人會被叫醒兩次"
        )


async def test_an_absent_claimer_is_not_mentioned_but_still_told(tmp_path):
    """認領者離房（孤兒卡）：**不 mention 不在的人**，改走收件匣。

    mention 一個已經離開的人只會進 `unresolved_mentions`——看起來 tag 了，
    實際上沒有任何人收到，是典型的靜默失效。
    """
    app, client = await _client(tmp_path, "stake_orphan")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, rid, "agent-worker", "認領的人")

        tid = await _card(client, rid, human)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=worker)
        await client.post(f"/api/rooms/{rid}/leave", headers=worker)

        # 人類替他把卡標完成
        assert (await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": "done"},
                                  headers=human)).status_code == 200

        msg = await _done_message(client, rid, human)
        assert msg is not None, "留痕不見了"
        assert "認領的人" not in msg["mentions"], (
            f"mention 了一個不在房裡的人：{msg['mentions']}"
        )
        got = {n["event_type"] for n in await _notices(client, "agent-worker")}
        assert "task_done" in got, (
            f"離房的認領者既沒被 mention 也沒收到收件匣——他永遠不會知道：{got}"
        )


async def test_the_trace_survives_with_nobody_to_mention(tmp_path):
    """沒有利害關係人時，訊息照樣留痕，只是 mentions 是空的。

    與 objective 層同一條原則（09/08 迴歸的教訓）：**留痕與喚醒是兩件事**，
    「沒有人要叫醒」不等於「不用留痕」。
    """
    app, client = await _client(tmp_path, "stake_empty")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        await _join(client, rid, "agent-bystander", "路人")

        tid = await _card(client, rid, human)
        # 沒有人認領、沒有指派、沒有 supervisor ⇒ 人類自己標完成
        assert (await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": "done"},
                                  headers=human)).status_code == 200

        msg = await _done_message(client, rid, human)
        assert msg is not None, "沒有人要叫醒，於是整則留痕也不見了"
        assert msg["mentions"] == [], f"憑空叫醒了人：{msg['mentions']}"
