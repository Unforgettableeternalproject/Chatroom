"""週期收尾要通知**接過任務的人**，包含已經離開的、包含 agent。

艾斯維爾 2026-09-06 實測：verify ＋ 完成 09/03 週期之後，接過任務的成員
（含 agent session）**一個通知都沒收到**，而系統沒有報任何錯——它「正確地」
只通知了在場的人類。

兩層根因：

1. `verified` 那則走 `_board_audience(..., humans_only=True)` ⇒ **agent 一律
   排除**。原註解的理由是「agent 本來就在看板，不用叫」——board 與 chatroom
   分離、agent 又會換 session 之後，**接過任務的 agent 多半早就離開、不在看板**，
   那個前提失效了。
2. 兩則都用 `_board_audience(row["room_id"])`，而它是
   `WHERE room_id=? AND status='active'` ⇒ **只掃 objective 所在那一間房的
   當前成員**。接過任務的人散在多個掛接房、而且可能已經走了。

⇒ 收尾通知的收件人不該從「現在誰在房裡」算，要從「**誰在這個週期底下做過事**」
算，而且要落進收件匣（`board_watch_notice` 綁 `actor_key`，換 session 也收得到），
不能只靠房內 mention——**最需要它的那個人正好就是不在場的那個**。
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
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": key,
        "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _notices(client, key):
    r = await client.get("/api/board/notices",
                         params={"unread_only": True},
                         headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text
    return r.json()["notices"]


async def _run_a_cycle(client):
    """人類開週期、agent 接一張卡做完、agent 離開房間。

    回 (objective_id, 人類 hdr, checklist_id)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
    worker = await _join(client, rid, "agent-worker", "做事的人")

    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "09/03 需求落地"},
                             headers=human)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Server 端"},
                             headers=human)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "一張卡"},
                             headers=human)).json()["id"]

    assert (await client.post(f"/api/board/tasks/{tid}/claim",
                              headers=worker)).status_code == 200
    assert (await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"},
                              headers=worker)).status_code == 200
    # 🔑 他做完就離開了——這正是常態（sweeper 也會把閒置 agent 掃出去）
    await client.post(f"/api/rooms/{rid}/leave", headers=worker)
    # ⚠️ checklist 的收尾**留給呼叫端**推：收尾的容器會拒收新卡
    # （`container_settled`），而有的測試要在那之前再插一張
    return oid, human, cid


async def _settle_checklist(client, cid, human):
    r = await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=human)
    assert r.status_code == 200, r.text


async def test_the_worker_hears_about_it_even_after_leaving(tmp_path):
    """做過事的 agent 離開之後，週期收尾仍然通知得到他。"""
    app, client = await _client(tmp_path, "settle_notice")
    async with app.router.lifespan_context(app), client:
        oid, human, cid = await _run_a_cycle(client)
        await _settle_checklist(client, cid, human)

        assert await _notices(client, "agent-worker") == [], "收尾之前不該有"

        for step in ("review", "verify", "complete"):
            r = await client.post(f"/api/board/objectives/{oid}/{step}",
                                  headers=human)
            assert r.status_code == 200, f"{step}: {r.text}"

        got = await _notices(client, "agent-worker")
        kinds = {n["event_type"] for n in got}
        assert got, (
            "接過任務的人在週期收尾後一個通知都沒有——"
            "而他正是最需要知道的那個（他已經不在房裡了）"
        )
        assert "objective_done" in kinds, f"實際收到：{kinds}"
        assert all(n["item_id"] == oid for n in got)


async def test_the_person_who_pressed_it_does_not_notify_themselves(tmp_path):
    """按下那個按鈕的人不必收到自己的通知——與追蹤通知同一條規則。

    ⚠️ **這條測試第一版是假通過**：那時人類從頭到尾沒有認領或完成任何卡，
    所以他本來就不在收件人集合裡——把「排除自己」那行拿掉，測試照樣綠。
    它驗的不是它宣稱的東西（2026-09-06，就在把「PASS 也要問它證明了什麼」
    寫進 FAILURE-PATTERNS 的同一個小時）。

    ⇒ 現在人類**自己也做完一張卡**，因此確實落在「做過事的人」裡面，
    唯一讓他收不到的理由就只剩「他是按下按鈕的那個」。改法驗過：
    拿掉 `k != me_key` 這條測試會紅。
    """
    app, client = await _client(tmp_path, "settle_self")
    async with app.router.lifespan_context(app), client:
        oid, human, cid = await _run_a_cycle(client)

        # 🔑 人類自己也接一張並做完 ⇒ 他進得了「做過事的人」那個集合
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "人類自己做的"},
                                 headers=human)).json()["id"]
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers=human)).status_code == 200
        assert (await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": "done"},
                                  headers=human)).status_code == 200
        await _settle_checklist(client, cid, human)

        for step in ("review", "verify", "complete"):
            r = await client.post(f"/api/board/objectives/{oid}/{step}",
                                  headers=human)
            assert r.status_code == 200, f"{step}: {r.text}"

        # 做過事的 agent 收得到 ⇒ 通知確實發出去了，不是整批沒發
        assert await _notices(client, "agent-worker"), "通知根本沒發，這條不成立"
        assert await _notices(client, "human-1") == [], (
            "按下完成的人收到了自己觸發的通知"
        )
