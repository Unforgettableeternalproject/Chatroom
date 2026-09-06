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


async def _join_and_add_to_board(client, rid, session_key, name,
                                 role="agent", owner_key="agent-1"):
    """加入房間**並**被加進板——A+ 之後這是兩件事。

    §3.1：房裡的人不會自動變成板上的人。所以「另一個 agent 來接手孤兒卡」
    這種流程，現在多一步：owner 要先把他加進板。

    ⚠️ 這一步在產品上是有代價的——孤兒機制的意義正是「讓別人接手」，而
    接手的人通常是後來才進來的。這裡照新規則走，把代價顯性化。
    """
    hdr, body = await _join(client, rid, session_key, name, role=role)
    b = (await client.get(f"/api/rooms/{rid}/board",
                          headers={"X-Host-View": "1"})).json()
    if b.get("board_id"):
        await client.post(
            f"/api/boards/{b['board_id']}/members",
            json={"actor_key": session_key, "role": "editor"},
            headers={"X-Session-Key": owner_key})
    return hdr, body


async def _task(client, rid, hdr, tid):
    """讀一張卡的當下狀態。**走主持人視角**，理由與被測的東西無關：

    A+ 之後「後來才加入這間房的人」不會自動是板成員（§3.1），而這裡好幾條
    測試正是拿一個後加入的旁觀者去看卡——那在產品上會（正確地）拿到 403。
    這些測試要驗的是**孤兒與收尾的行為**，不是 ACL；用 .env 主 token 的
    主持人視角讀，才不會讓一道正確的門檻把不相干的斷言染紅。

    ACL 本身在 tests/test_board_v2_api.py 有專門的測試守著。
    """
    board = (await client.get(f"/api/rooms/{rid}/board",
                              headers={**hdr, "X-Host-View": "1"})).json()
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
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
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
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
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
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
        human, _ = await _join_and_add_to_board(client, rid, "human-1", "Bernie", role="human")
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
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
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
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
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
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        before = (await client.get(f"/api/rooms/{rid}/board",
                                   headers=other)).json()["board_seq"]
        await client.post(f"/api/rooms/{rid}/leave", headers=mine)
        delta = (await client.get(
            f"/api/rooms/{rid}/board?after_board_seq={before}",
            headers=other)).json()
        assert [t["id"] for t in delta["tasks"]] == [tid]
        assert delta["tasks"][0]["claim_state"] == "orphaned"


async def test_claiming_exempts_an_agent_from_the_idle_sweeper(tmp_path):
    """接案中的 agent **不會**被閒置掃走（艾斯維爾 2026-09-02 拍板）。

    這條原本測的是相反的事：閒置逾時把卡標成孤兒。那個行為是對的，直到
    使用者指出它的代價——做任務做到一半被踢出去，卡變孤兒、房內身分失效，
    而 agent 自己完全不知道發生了什麼。

    豁免是**完全的**，沒有時限：掛著卡就 crash 的殘影由人類強制 release
    收拾（那條路徑本來就有）。用「延長門檻」會讓長任務在某個說不出理由的
    時點被打斷，而那個時點永遠比任務短。
    """
    app, client = await _client(tmp_path, "claim-exempt",
                                idle_timeout=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "human-1"})).json()["id"]
        human, _ = await _join_and_add_to_board(client, rid, "human-1", "Bernie", role="human")
        agent, _ = await _join(client, rid, "agent-1", "Novia")
        apid = agent["X-Participant-Id"]
        tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                                 json={"title": "長工作"},
                                 headers=human)).json()["id"]
        await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)

        await app.state.sweep_once()

        row = await (await app.state.db.execute(
            "SELECT status FROM participant WHERE id=?", (apid,))).fetchone()
        assert row["status"] == "active", "接案中的人被掃出去了"
        task = await _task(client, rid, human, tid)
        assert task["claim_state"] == "held"

        # 放掉之後就不再豁免——豁免跟著卡走，不是跟著人走
        await client.post(f"/api/board/tasks/{tid}/release", headers=agent)
        await app.state.sweep_once()
        row = await (await app.state.db.execute(
            "SELECT status FROM participant WHERE id=?", (apid,))).fetchone()
        assert row["status"] == "removed", "卡都放掉了還在豁免"


async def test_leaving_orphans_the_card_and_announces_it(tmp_path):
    """孤兒發**獨立的 BOARD 系統訊息**（艾斯維爾 09-01 裁定，照設計稿），
    主詞是卡不是人：讀的人在意的是哪張卡沒人做了。而且**不 mention 任何人**
    ——孤兒不是誰的待辦，是板上的事實。

    觸發改用主動離開：閒置那條路徑自 09-02 起對接案者不再成立。
    """
    app, client = await _client(tmp_path, "orphan-leave")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "human-1"})).json()["id"]
        human, _ = await _join_and_add_to_board(client, rid, "human-1", "Bernie", role="human")
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

        await client.post(f"/api/rooms/{rid}/leave", headers=agent)

        task = await _task(client, rid, human, tid)
        assert task["claim_state"] == "orphaned"
        assert task["claim_name"] == "Novia", "接手的人要看得出上一個是誰"

        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=human)).json()["messages"]
        board = [m for m in msgs if m["system_event"] == "board_orphaned"]
        assert len(board) == 1
        assert "「接端點」" in board[0]["content"]
        assert board[0]["mentions"] == [], "孤兒不是誰的待辦，不該喚醒任何人"


async def test_orphan_reason_distinguishes_the_four_paths(tmp_path):
    """設計稿要寫得出「因閒置移出」還是「session 已結束」。

    原因**只有在離場那一刻知道**：同一把 session_key 下次 join 會產生新的
    一列，事後從 participant 反推不回這張卡是在哪一次走的時候掉的。
    """
    app, client = await _client(tmp_path, "orphan-reason")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
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


# ---------- F6：已收尾的卡不孤兒化（測試 Novia 實機發現）----------

async def test_a_settled_task_is_never_orphaned(tmp_path):
    """孤兒的意思是「這件事沒人做了」，而 done 的事**已經沒有人需要做**。

    標成 orphaned 會產生一個自相矛盾的組合：完成了、而且沒人在做。
    UI 讀到那個組合只能二選一顯示，怎麼選都是錯的。
    """
    app, client = await _client(tmp_path, "settled")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "in_progress"}, headers=mine)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=mine)

        r = await client.post(f"/api/rooms/{rid}/leave", headers=mine)
        assert r.json()["orphaned_tasks"] == []

        task = await _task(client, rid, other, tid)
        assert task["status"] == "done"
        assert task["claim_state"] == "held", "做完的人仍然是做它的人"
        assert task["orphaned_reason"] == ""


async def test_cancelled_tasks_are_not_orphaned_either(tmp_path):
    app, client = await _client(tmp_path, "settled-cancel")
    async with app.router.lifespan_context(app), client:
        rid, mine, tid = await _room_with_task(client)
        other, _ = await _join_and_add_to_board(client, rid, "agent-2", "Miller")
        await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "cancelled"}, headers=mine)
        await client.post(f"/api/rooms/{rid}/leave", headers=mine)
        assert (await _task(client, rid, other, tid))["claim_state"] == "held"


async def test_existing_contradictions_are_healed_at_startup(tmp_path):
    """改了根因不會動到已經寫進去的資料——存量要另外清（同 HOST 徽章那次）。

    只清「它現在沒人做」這個宣稱；`claim_name` / `claimed_at` 是歷史，留著。
    """
    path = str(tmp_path / "heal.db")
    cfg = Config(db_path=path, api_token=ROOT)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        # 手工造出那個矛盾組合（舊版本會產生它）
        await app.state.db.execute(
            "UPDATE board_task SET status='done', claim_state='orphaned',"
            " claim_name='前世的我', claimed_at='2026-09-01',"
            " orphaned_at='2026-09-01', orphaned_reason='因閒置移出'"
            " WHERE id=?", (tid,))
        await app.state.db.commit()

    # 重開一次 Hub：開機修復應該把它清乾淨
    app2 = create_app(Config(db_path=path, api_token=ROOT))
    client2 = AsyncClient(transport=ASGITransport(app=app2),
                          base_url="http://test",
                          headers={"Authorization": f"Bearer {ROOT}"})
    async with app2.router.lifespan_context(app2), client2:
        row = await (await app2.state.db.execute(
            "SELECT * FROM board_task WHERE id=?", (tid,))).fetchone()
        assert row["claim_state"] == ""
        assert row["orphaned_at"] is None
        assert row["orphaned_reason"] == ""
        assert row["claim_name"] == "前世的我", "誰做的是歷史，不是矛盾"
        assert row["claimed_at"] == "2026-09-01"
        # 增量 client 要看得到這次修復，否則它手上那張卡永遠是矛盾的
        seq = await (await app2.state.db.execute(
            "SELECT board_seq FROM room WHERE id=?", (rid,))).fetchone()
        assert row["board_seq"] == seq["board_seq"]


async def test_healing_keeps_a_settled_card_on_its_holder(tmp_path):
    """F7：清理不只是移除矛盾，**它同時挑了一個表示**——要跟正常路徑一致。

    上面那條造的矛盾卡沒有 `claim_participant_id`，而真實的孤兒卡一定有
    （它是從 `held` 來的），所以那條守住的空字串是個不會發生的情形。

    正常完成的卡停在 `held`（見 `test_a_settled_task_is_never_orphaned`：
    「做完的人仍然是做它的人」）。存量若清成空字串，同一種情形在資料庫裡
    就有兩種表示，而 UI 兩種都畫成 completed ⇒ 它會一直安靜地存在，
    直到有人去查「還掛在誰名下的卡」才發現對不起來。
    """
    path = str(tmp_path / "heal_held.db")
    cfg = Config(db_path=path, api_token=ROOT)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        pid = hdr["X-Participant-Id"]
        await app.state.db.execute(
            "UPDATE board_task SET status='done', claim_state='orphaned',"
            " claim_participant_id=?, claim_name='前世的我',"
            " claimed_at='2026-09-01', orphaned_at='2026-09-01',"
            " orphaned_reason='因閒置移出' WHERE id=?", (pid, tid))
        await app.state.db.commit()
    assert rid

    app2 = create_app(Config(db_path=path, api_token=ROOT))
    client2 = AsyncClient(transport=ASGITransport(app=app2),
                          base_url="http://test",
                          headers={"Authorization": f"Bearer {ROOT}"})
    async with app2.router.lifespan_context(app2), client2:
        row = await (await app2.state.db.execute(
            "SELECT * FROM board_task WHERE id=?", (tid,))).fetchone()
        assert row["claim_state"] == "held", (
            "有持有者的收尾卡要清回 held，與正常完成的卡同一種表示"
        )
        # 矛盾本身仍然要消失
        assert row["orphaned_at"] is None
        assert row["orphaned_reason"] == ""
        assert row["claim_name"] == "前世的我"


async def _room_with_cancellable_tree(client):
    """回傳 (rid, 人類 hdr, agent hdr, oid, tid)。取消週期要人類或建立者。"""
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    human, _ = await _join(client, rid, "human-1", "艾斯維爾", role="human")
    agent, _ = await _join(client, rid, "agent-1", "Novia")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=human)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段一"}, headers=human)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "一件事"}, headers=human)).json()["id"]
    return rid, human, agent, oid, tid


async def test_a_task_under_a_cancelled_objective_is_never_orphaned(tmp_path):
    """A5：父層被取消的卡，持有者離場也不該變孤兒。

    objective 的 cancel **不 cascade 子層**（刻意的——cascade 會讓週期
    reopen 時救不回子卡狀態），所以那些卡的 status 還是 todo，不符「已收尾」
    的豁免 ⇒ 會被永久標成孤兒。而顯示那側早就把取消的週期濾掉了 ⇒
    app bar 一直寫著 N 個孤兒，進板一張也找不到。

    豁免而不 cascade：孤兒化的語意是「讓別人接手」，而父層取消的卡
    **沒有人需要接手**。
    """
    app, client = await _client(tmp_path, "orphan_cancelled")
    async with app.router.lifespan_context(app), client:
        rid, human, agent, oid, tid = await _room_with_cancellable_tree(client)
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/objectives/{oid}/cancel",
                              headers=human)
        assert r.status_code == 200, r.text

        # 持有者離場
        r = await client.post(f"/api/rooms/{rid}/leave", headers=agent)
        assert r.status_code == 200, r.text

        row = await (await app.state.db.execute(
            "SELECT status, claim_state FROM board_task WHERE id=?", (tid,),
        )).fetchone()
        assert row["status"] == "todo", "取消週期不 cascade 子層，這是刻意的"
        assert row["claim_state"] != "orphaned", (
            "父層已取消的卡不該變孤兒——沒有人需要接手它"
        )


async def test_stale_orphans_under_a_cancelled_objective_are_healed(tmp_path):
    """存量那半。不清的話，這些列會被 v2 遷移一起帶過去。"""
    path = str(tmp_path / "heal_cancelled.db")
    cfg = Config(db_path=path, api_token=ROOT)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    async with app.router.lifespan_context(app), client:
        rid, human, agent, oid, tid = await _room_with_cancellable_tree(client)
        pid = agent["X-Participant-Id"]
        await client.post(f"/api/board/objectives/{oid}/cancel", headers=human)
        # 舊版本會產生的狀態：父層取消了，卡卻被標成孤兒
        await app.state.db.execute(
            "UPDATE board_task SET claim_state='orphaned',"
            " claim_participant_id=?, claim_name='前世的我',"
            " orphaned_at='2026-09-01', orphaned_reason='因閒置移出'"
            " WHERE id=?", (pid, tid))
        await app.state.db.commit()
    assert rid

    app2 = create_app(Config(db_path=path, api_token=ROOT))
    client2 = AsyncClient(transport=ASGITransport(app=app2),
                          base_url="http://test",
                          headers={"Authorization": f"Bearer {ROOT}"})
    async with app2.router.lifespan_context(app2), client2:
        row = await (await app2.state.db.execute(
            "SELECT claim_state, orphaned_reason FROM board_task WHERE id=?",
            (tid,))).fetchone()
        assert row["claim_state"] == "held", "有持有者的清回 held（F7）"
        assert row["orphaned_reason"] == ""


async def test_exemption_survives_a_session_key_with_whitespace(tmp_path):
    """session_key 帶空白時豁免仍要成立（@開發Novia (除錯) 2026-09-02 實測）。

    `claim_actor_key` 走 `actor_key()` 做過 strip，而 `participant.session_key`
    以前是原樣存入——兩邊一比就不相等，**接案豁免靜默失效**：agent 被掃掉、
    卡變孤兒，而它不知道為什麼。正是 H5 要消滅的那個現象。

    機率低但值得修：session_key 是呼叫端自己產的字串，而從 `.env` 或 shell
    環境變數讀來的很容易帶尾隨空白——那正是 kit 使用者最常見的設定方式。
    """
    app, client = await _client(tmp_path, "claim-spaced",
                                idle_timeout=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "human-1"})).json()["id"]
        human, _ = await _join_and_add_to_board(client, rid, "human-1", "Bernie", role="human")
        agent, _ = await _join(client, rid, "  claude-spaced  ", "Novia")
        apid = agent["X-Participant-Id"]
        tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                                 json={"title": "長工作"},
                                 headers=human)).json()["id"]
        await client.post(f"/api/board/tasks/{tid}/claim", headers=agent)

        db = app.state.db
        row = await (await db.execute(
            "SELECT session_key FROM participant WHERE id=?",
            (apid,))).fetchone()
        assert row["session_key"] == "claude-spaced", "join 時就該規範化"

        await app.state.sweep_once()
        row = await (await db.execute(
            "SELECT status FROM participant WHERE id=?", (apid,))).fetchone()
        assert row["status"] == "active"

        # 存量：改 join 只救得了新的。既有列已經帶著空白存進去了，
        # 所以比對那一側也要 TRIM——不然升級之後那批人照樣被掃
        await db.execute(
            "UPDATE participant SET session_key='  claude-spaced  ',"
            " status='active', left_at=NULL WHERE id=?", (apid,))
        await db.commit()
        await app.state.sweep_once()
        row = await (await db.execute(
            "SELECT status FROM participant WHERE id=?", (apid,))).fetchone()
        assert row["status"] == "active", "存量那批帶空白的接案者被掃掉了"


# ---------------------------------------------------------------------------
# board 軸身分不是繞過 ACL 的側門（09/06 卡 46f096b5 的前置驗證）
#
# @測試Novia 09/06 #32 先講明他會打這一發：修「卡片端點不認 board_id」這個
# 缺口，不能順手變成「不在任何掛接房裡的人也能動卡」。
#
# 這兩條一開始就是綠的——**那正是重點**。要開通 bridge 的 board 軸之前，
# 得先證明那道門真的擋得住，而不是我以為它擋得住。
# ---------------------------------------------------------------------------


async def test_a_stranger_cannot_claim_with_a_bare_session_key(tmp_path):
    """沒進房、也不是板成員的人，拿 session_key 直接打 claim 要被擋。

    `_board_item_writer` 在拿不到 participant 時會退回純 actor 身分，
    但最後一律過 `_board_member_or_403`——那道門才是防線。
    """
    app, client = await _client(tmp_path, "axis_stranger")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)

        r = await client.post(f"/api/board/tasks/{tid}/claim",
                              headers={"X-Session-Key": "agent-outsider"})
        assert r.status_code == 403, r.text

        # 而且真的沒領到——403 之後卡還是空的
        assert (await _task(client, rid, hdr, tid))["claim_state"] == ""


async def test_a_board_member_may_claim_without_being_in_a_room(tmp_path):
    """反過來那半：**是板成員就構得到卡**，不必先進房。

    這是 46f096b5 要開通的那條路。防線是「板成員資格」而不是「房內身分」——
    兩者不同，混為一談會讓板房分離之後的板變成沒有人動得了的東西。
    """
    app, client = await _client(tmp_path, "axis_member")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        b = (await client.get(f"/api/rooms/{rid}/board",
                              headers={"X-Host-View": "1"})).json()
        r = await client.post(
            f"/api/boards/{b['board_id']}/members",
            json={"actor_key": "agent-remote", "role": "editor"},
            headers={"X-Session-Key": "agent-1"})
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/tasks/{tid}/claim",
                              headers={"X-Session-Key": "agent-remote"})
        assert r.status_code == 200, r.text
        assert (await _task(client, rid, hdr, tid))["claim_state"] == "held"


# ---------------------------------------------------------------------------
# 同名不同世：錯誤訊息要說得出差別（09/06 卡 13661deb，@開發Novia (UI) 實測）
#
# 復現：session A 認領後結束；同一個 display_name 的 session B 進房（新
# session_key），對那張卡 release ⇒ 403「這張卡由 開發Novia (UI) 持有」——
# **而呼叫者的名字就是它**。訊息讀起來等於「你不是你」。
#
# 認領綁 session_key 是對的（`_is_claim_holder` 已修過跨房問題），錯的是
# 訊息只投影出 display_name。名字在房內唯一，但**只在 active 成員之間**——
# 前一世離開後名字就釋出了，下一世拿得回同一個名字。
# ---------------------------------------------------------------------------


async def test_a_namesake_is_told_it_is_another_session(tmp_path):
    """同名不同 session 時，訊息要明講那是另一個 session。"""
    app, client = await _client(tmp_path, "namesake_release")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers=hdr)).status_code == 200
        # ⚠️ 卡要先收尾：**已 done 的卡不會被孤兒化**（09/03 那條修法），
        # 認領停在 held。未收尾的卡在持有者離開時會變 orphaned，那時 release
        # 走的是另一條（409 not_claimed）——UI 撞到的正是前者
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=hdr)
        # 前一世走了，名字釋出
        await client.post(f"/api/rooms/{rid}/leave", headers=hdr)
        # 下一世用同一個名字回來（新 session_key）
        again, _ = await _join_and_add_to_board(client, rid, "agent-2", "Novia")

        r = await client.post(f"/api/board/tasks/{tid}/release", headers=again)
        assert r.status_code == 403, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "not_claim_holder"
        assert "另一個" in detail["message"],             f"訊息讀起來像「你不是你」：{detail['message']}"
        # 結構化欄位讓 client 不必解析中文
        assert detail["held_by_same_name"] is True


async def test_a_different_name_reads_as_before(tmp_path):
    """不同名時維持原本的說法——**放寬的只有同名那一格**。

    寫成明確的斷言是因為最容易的寫法是「一律改成新句子」，那會讓正常情況
    的訊息多出一個沒有意義的「另一個 session」。
    """
    app, client = await _client(tmp_path, "namesake_normal")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
        other, _ = await _join_and_add_to_board(client, rid, "agent-9", "Miller")

        r = await client.post(f"/api/board/tasks/{tid}/release", headers=other)
        assert r.status_code == 403, r.text
        detail = r.json()["detail"]
        assert "另一個" not in detail["message"]
        assert detail["held_by_same_name"] is False


async def test_the_same_signal_reaches_the_claim_conflict(tmp_path):
    """認領衝突那條也帶同一個旗標。

    「已經被『你自己』領走了」是同一個誤導的另一個入口——而它多半是上一世。

    ⚠️ 三處各寫一份判斷的話，改了一處另外兩處會靜靜地留在舊說法上，而
    「訊息不一致」不會有任何測試或使用者報上來。所以判準抽成一支共用。
    """
    app, client = await _client(tmp_path, "namesake_claim")
    async with app.router.lifespan_context(app), client:
        rid, hdr, tid = await _room_with_task(client)
        await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=hdr)
        await client.post(f"/api/rooms/{rid}/leave", headers=hdr)
        again, _ = await _join_and_add_to_board(client, rid, "agent-2", "Novia")

        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=again)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["held_by_same_name"] is True
