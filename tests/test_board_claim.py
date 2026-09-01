"""T-04：認領的 CAS 與孤兒釋放。

「同時只能一個 Agent 領取一個任務」是需求原文。實作上的兩個要害：

1. **CAS 的成敗判定**——`UPDATE … RETURNING` 在 fetch 之前 `rowcount` 是 0。
   照 `rowcount == 1` 寫的話，每一次認領都會確實改到資料庫、卻回報「已被
   別人領走」。狀態變了而呼叫端以為沒變，是最難查的一種。
2. **孤兒**——agent 閒置被掃出房間時沒有人會去釋放它領走的卡，那張卡會永遠
   顯示「有人在做」。這在別的任務板上是例外，在這裡是日常。
"""

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    body = r.json()
    return {"X-Participant-Id": body["participant_id"]}, body


async def _room_with_task(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    hdr, _ = await _join(client, rid, "agent-1", "Novia")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "接端點"}, headers=hdr)).json()["id"]
    return rid, hdr, tid


async def _task(client, rid, hdr, tid):
    board = (await client.get(f"/api/rooms/{rid}/board", headers=hdr)).json()
    return next(t for t in board["tasks"] if t["id"] == tid)


async def test_claim_succeeds_and_marks_holder(tmp_path):
    app, client = await _client(tmp_path, "claim")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
        assert r.status_code == 200, r.text
        assert r.json()["reclaimed"] is False
        task = await _task(client, rid, hdr, tid)
        assert task["claim_state"] == "held"
        assert task["claim_name"] == "Novia"


async def test_second_claimer_gets_409_not_a_silent_takeover(tmp_path):
    """CAS 判定寫成 rowcount 的話，這條會反過來紅：DB 改了卻回 409。"""
    app, client = await _client(tmp_path, "claim2")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers=mine)).status_code == 200
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=other)
        assert r.status_code == 409
        detail = r.json()["detail"]
        assert detail["code"] == "task_already_claimed"
        assert detail["claim_name"] == "Novia", "409 要說得出現在是誰在做"
        # 卡仍在第一個人手上——沒有被悄悄搶走
        assert (await _task(client, rid, mine, tid))["claim_name"] == "Novia"


async def test_concurrent_claims_exactly_one_wins(tmp_path):
    app, client = await _client(tmp_path, "claim-race")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        results = await asyncio.gather(
            client.post(f"/api/board/tasks/{tid}/claim", headers=mine),
            client.post(f"/api/board/tasks/{tid}/claim", headers=other),
        )
        codes = sorted(r.status_code for r in results)
        assert codes == [200, 409], f"應該一成一敗，實際 {codes}"


async def test_claim_is_refused_once_done(tmp_path):
    app, client = await _client(tmp_path, "claim-done")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        await app.state.db.execute(
            "UPDATE board_task SET status='done' WHERE id=?", (tid,))
        await app.state.db.commit()
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
        assert r.status_code == 409
        assert r.json()["detail"]["task_status"] == "done"


async def test_release_by_holder_clears_not_orphans(tmp_path):
    """主動放棄＝「這張卡沒人做」，與「持有者不在了」是兩件事。"""
    app, client = await _client(tmp_path, "release")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
        r = await client.post(f"/api/board/tasks/{tid}/release", headers=hdr)
        assert r.status_code == 200
        assert r.json()["forced"] is False
        task = await _task(client, rid, hdr, tid)
        assert task["claim_state"] == ""
        assert task["claim_name"] == ""


async def test_only_holder_or_human_can_release(tmp_path):
    app, client = await _client(tmp_path, "release-perm")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        human, _ = await _join(client, rid, "human-1", "Bernie", role="human")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)

        r = await client.post(f"/api/board/tasks/{tid}/release", headers=other)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_claim_holder"

        # 人類可以強制解除（Q7 定案），而且回應說得出這是強制的
        r = await client.post(f"/api/board/tasks/{tid}/release", headers=human)
        assert r.status_code == 200
        assert r.json()["forced"] is True


async def test_leaving_orphans_the_card_but_keeps_the_trail(tmp_path):
    """清空 claim_participant_id 就查不出上一個是誰在做——那是接手的人最需要的。"""
    app, client = await _client(tmp_path, "orphan-leave")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)

        r = await client.post(f"/api/rooms/{rid}/leave", headers=mine)
        assert r.status_code == 200
        assert r.json()["orphaned_tasks"] == [tid]

        task = await _task(client, rid, other, tid)
        assert task["claim_state"] == "orphaned"
        assert task["claim_name"] == "Novia", "線索不能被抹掉"
        assert task["orphaned_at"]


async def test_orphaned_card_can_be_claimed_by_someone_else(tmp_path):
    """持有者已經不在房內，就不算「同時」。"""
    app, client = await _client(tmp_path, "orphan-reclaim")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        await client.post(f"/api/rooms/{rid}/leave", headers=mine)

        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=other)
        assert r.status_code == 200
        assert r.json()["reclaimed"] is False, "別人的卡不是「認回」"
        assert (await _task(client, rid, other, tid))["claim_name"] == "Miller"


async def test_same_session_key_reclaim_is_flagged(tmp_path):
    """重新 join 拿到的是新的 participant_id，認回要靠 session_key 認出來。"""
    app, client = await _client(tmp_path, "reclaim-flag")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        await client.post(f"/api/rooms/{rid}/leave", headers=mine)

        again, _ = await _join(client, rid, "agent-1", "Novia")
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=again)).json()
        assert [x["id"] for x in board["reclaimable_tasks"]] == [tid]

        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=again)
        assert r.status_code == 200
        assert r.json()["reclaimed"] is True, "要讓 agent 知道這是它上一世領的"


async def test_kick_also_orphans(tmp_path):
    app, client = await _client(tmp_path, "orphan-kick")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "human-1"})).json()["id"]
        human, hbody = await _join(client, rid, "human-1", "Bernie", role="human")
        agent, abody = await _join(client, rid, "agent-1", "Novia")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=human)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "Hub 端"},
                                 headers=human)).json()["id"]
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "接端點"},
                                 headers=human)).json()["id"]
        await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)

        r = await client.post(
            f"/api/rooms/{rid}/participants/{abody['participant_id']}/kick",
            headers=human)
        assert r.status_code == 200, r.text
        task = await _task(client, rid, human, tid)
        assert task["claim_state"] == "orphaned"
        assert task["claim_name"] == "Novia"


async def test_orphaning_advances_board_seq(tmp_path):
    """孤兒化是 board 上的一次變更——不推進水位的話增量 client 看不到。"""
    app, client = await _client(tmp_path, "orphan-seq")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        before = (await client.get(f"/api/rooms/{rid}/board",
                                   headers=other)).json()["board_seq"]
        await client.post(f"/api/rooms/{rid}/leave", headers=mine)
        delta = (await client.get(
            f"/api/rooms/{rid}/board?after_board_seq={before}",
            headers=other)).json()
        assert [t["id"] for t in delta["tasks"]] == [tid]
        assert delta["tasks"][0]["claim_state"] == "orphaned"


async def test_idle_sweeper_orphans_and_announces_it_as_a_board_event(tmp_path):
    """閒置逾時是孤兒的主要來源——agent session 結束沒有人會去釋放它的卡。

    孤兒發**獨立的 BOARD 系統訊息**（艾斯維爾 09-01 裁定，照設計稿），
    主詞是卡不是人：讀的人在意的是哪張卡沒人做了。而且**不 mention 任何人**
    ——孤兒不是誰的待辦，是板上的事實。
    """
    app, client = await _client(tmp_path, "orphan-sweep",
                                idle_timeout=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "human-1"})).json()["id"]
        human, _ = await _join(client, rid, "human-1", "Bernie", role="human")
        agent, _ = await _join(client, rid, "agent-1", "Novia")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=human)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "Hub 端"},
                                 headers=human)).json()["id"]
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "接端點"},
                                 headers=human)).json()["id"]
        await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)

        await app.state.sweep_once()

        task = await _task(client, rid, human, tid)
        assert task["claim_state"] == "orphaned"
        assert task["claim_name"] == "Novia", "接手的人要看得出上一個是誰"
        assert task["orphaned_reason"] == "因閒置移出"

        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=human)).json()["messages"]
        board = [m for m in msgs if m["system_event"] == "board_orphaned"]
        assert len(board) == 1
        assert "「接端點」" in board[0]["content"]
        assert "因閒置移出" in board[0]["content"]
        assert board[0]["mentions"] == [], "孤兒不是誰的待辦，不該喚醒任何人"


async def test_orphan_reason_distinguishes_the_four_paths(tmp_path):
    """設計稿要寫得出「因閒置移出」還是「session 已結束」。

    原因**只有在離場那一刻知道**：同一把 session_key 下次 join 會產生新的
    一列，事後從 participant 反推不回這張卡是在哪一次走的時候掉的。
    """
    app, client = await _client(tmp_path, "orphan-reason")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        await client.post(f"/api/rooms/{rid}/leave", headers=mine)
        task = await _task(client, rid, other, tid)
        assert task["orphaned_reason"] == "session 已結束"
        assert task["claim_kind"] == "claude", "種類徽章要畫得出來"


async def test_snapshots_survive_the_holder_leaving(tmp_path):
    """名字／種類的快照就是為了「查不回來的時候還看得到」而存在。"""
    app, client = await _client(tmp_path, "snapshot")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, obody = await _join(client, rid, "agent-2", "Miller")
        await client.patch(f"/api/board/tasks/{tid}", json={
            "assignee_participant_id": obody["X-Participant-Id"]
            if "X-Participant-Id" in obody else None}, headers=mine)
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=mine)).json()
        task = next(t for t in board["tasks"] if t["id"] == tid)
        assert task["created_by_name"] == "Novia"
        assert board["objectives"][0]["created_by_name"] == "Novia"
        assert board["checklists"][0]["created_by_name"] == "Novia"
