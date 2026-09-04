"""N-4 孤兒卡指派協定（server 半邊）。

艾斯維爾 2026-09-03 的需求：**管理員可直接指派孤兒卡；非管理員可請求指派給
他人，需對方同意**。載體定案 C——獨立表 `board_task_request`，不復用 assignment
（那張是「邀請某個 session 進房」，這張是「請某個人接手這張卡」，目標、生命
週期、結束條件都不同）。

⚠️ 這裡的「指派」是**建議不是鎖**：卡仍要對方自己認領。指派一個沒醒著的
agent 然後把卡鎖起來，board 會停在那裡（`board_task.assignee_*` 的欄位註解
從第一天就這樣寫）。
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
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    """房 + 建立者（人類）+ 一張被別人領走又變成孤兒的卡。"""
    rid = (await client.post("/api/rooms", json={
        "name": "指派房", "session_key": "human-boss"})).json()["id"]
    boss = await _join(client, rid, "human-boss", "老闆", role="human")
    gone = await _join(client, rid, "agent-gone", "走掉的人")
    tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                             json={"title": "孤兒卡"},
                             headers=boss)).json()["id"]
    r = await client.post(f"/api/board/tasks/{tid}/claim", headers=gone)
    assert r.status_code == 200, r.text
    r = await client.post(f"/api/rooms/{rid}/leave", headers=gone)
    assert r.status_code == 200, r.text
    return rid, boss, tid


async def _card(client, rid, hdr, tid):
    body = (await client.get(f"/api/rooms/{rid}/board", headers=hdr)).json()
    return [t for t in body["tasks"] if t["id"] == tid][0]


async def test_an_admin_assigns_directly(tmp_path):
    """建立者直接指派，不必對方點頭——他本來就是那個分派工作的人。"""
    app, client = await _client(tmp_path, "assign_admin")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            worker = await _join(client, rid, "agent-worker", "接手的人")

            r = await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=boss)
            assert r.status_code == 200, r.text
            assert r.json()["assigned"] is True, "管理員指派不該降級成請求"

            card = await _card(client, rid, boss, tid)
            assert card["assignee_participant_id"] == worker["X-Participant-Id"]
            assert card["assigned_by_name"] == "老闆"

            # ⚠️ 指派是**建議不是鎖**：卡的認領狀態一個字都沒動
            assert card["claim_state"] == "orphaned", \
                "指派順手改了認領狀態——接手仍要對方自己來"


async def test_a_non_admin_creates_a_request_instead(tmp_path):
    """非管理員只能「請求」——指派別人做事需要那個人點頭。"""
    app, client = await _client(tmp_path, "assign_request")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            r = await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"],
                      "note": "這塊你比較熟"},
                headers=asker)
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["assigned"] is False
            assert body["request"]["status"] == "pending"

            # 卡上什麼都還沒變——請求還沒被接受
            card = await _card(client, rid, boss, tid)
            assert card["assignee_participant_id"] is None


async def test_the_target_accepts_and_the_card_gets_assigned(tmp_path):
    app, client = await _client(tmp_path, "assign_accept")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            req = (await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)).json()["request"]

            r = await client.post(
                f"/api/board/task-requests/{req['id']}/resolve",
                json={"accept": True}, headers=worker)
            assert r.status_code == 200, r.text
            assert r.json()["accepted"] is True

            card = await _card(client, rid, boss, tid)
            assert card["assignee_participant_id"] == worker["X-Participant-Id"]


async def test_only_the_target_may_answer_the_request(tmp_path):
    """🔴 別人不能替你答應。少了這條，「需要對方同意」等於沒有。"""
    app, client = await _client(tmp_path, "assign_thief")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            req = (await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)).json()["request"]

            for who, label in ((asker, "提議者自己"), (boss, "建立者")):
                r = await client.post(
                    f"/api/board/task-requests/{req['id']}/resolve",
                    json={"accept": True}, headers=who)
                assert r.status_code == 403, f"{label} 替對方答應了：{r.text}"


async def test_a_settled_card_cannot_be_assigned(tmp_path):
    """驗收條件 ②：done／cancelled 的卡擋指派。

    收尾的卡再指派給誰都沒有意義，而畫面上會出現一張「已完成、指派給某某」
    的卡——看的人得先讀完狀態才知道那個指派是空的。
    """
    app, client = await _client(tmp_path, "assign_settled")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            worker = await _join(client, rid, "agent-worker", "接手的人")
            for st in ("in_progress", "done"):
                r = await client.post(f"/api/board/tasks/{tid}/status",
                                      json={"status": st}, headers=boss)
                assert r.status_code == 200, r.text

            r = await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=boss)
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "task_already_settled"


async def test_asking_the_same_person_twice_reuses_the_request(tmp_path):
    """同一張卡對同一個人只留一筆待回應的請求。

    三個人各自請求同一個對象是合理的（他們不知道彼此），但同一個人連按三次
    不該生出三筆——對方的收件匣會出現三則一模一樣的東西，而拒絕一則之後
    另外兩則還在。
    """
    app, client = await _client(tmp_path, "assign_dup")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            first = (await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)).json()["request"]
            again = (await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)).json()["request"]
            assert again["id"] == first["id"], "同一個人連按兩次生出了兩筆請求"


async def test_pending_requests_ride_along_with_the_board(tmp_path):
    """請求隨板一起回，不另開清單端點（@開發Novia (UI) 要的 0 支新端點）。

    ⚠️ 只回**與我有關**的：我發出的、或指名我的。全部都回的話，房裡每個人
    都看得到別人之間的商量，而那不是板要傳達的資訊。
    """
    app, client = await _client(tmp_path, "assign_ride")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")
            bystander = await _join(client, rid, "agent-by", "路人")

            await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)

            for who, label in ((asker, "提議者"), (worker, "被指名的人")):
                body = (await client.get(f"/api/rooms/{rid}/board",
                                         headers=who)).json()
                assert len(body["task_requests"]) == 1, f"{label} 看不到"

            body = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=bystander)).json()
            assert body["task_requests"] == [], "路人看到了別人之間的商量"


async def test_declining_leaves_the_card_alone_and_records_the_answer(tmp_path):
    """拒絕**要留下紀錄**而不是刪掉。

    提議者需要分得出「他看過了說不要」與「他還沒看到」——那是兩種完全不同的
    後續處置（既有的 `archive_request` 也是這樣做的）。
    """
    app, client = await _client(tmp_path, "assign_decline")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            req = (await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)).json()["request"]

            r = await client.post(
                f"/api/board/task-requests/{req['id']}/resolve",
                json={"accept": False}, headers=worker)
            assert r.status_code == 200, r.text
            assert r.json()["accepted"] is False

            card = await _card(client, rid, boss, tid)
            assert card["assignee_participant_id"] is None

            body = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=asker)).json()
            mine = [x for x in body["task_requests"] if x["id"] == req["id"]]
            assert mine and mine[0]["status"] == "declined", \
                "拒絕之後那筆請求消失了——提議者分不出他是拒絕還是還沒看到"

            # 答完就不能再答一次：重複回應會讓同一筆請求有兩種結局
            r = await client.post(
                f"/api/board/task-requests/{req['id']}/resolve",
                json={"accept": True}, headers=worker)
            assert r.status_code == 409, r.text


async def test_the_target_agent_can_find_the_request_from_its_watcher_poll(
        tmp_path):
    """agent 側的通知鏈：指派請求掛在 watcher 既有的輪詢點上。

    🔑 **不另開一條輪詢。** watcher 每隔幾秒就打一次 `/api/assignments`
    （那也是 session 名錄的心跳來源），把請求掛在同一支回應裡，agent 就不必
    多跑一條迴圈——**多一條輪詢就多一個會漏、會失步、會忘了關的地方**。

    ⚠️ 這與艾斯維爾 #265「不復用 assignment 表」不衝突：表仍然是獨立的，
    共用的只是**輪詢的入口**。合併發生在傳輸層，不在資料層。
    """
    app, client = await _client(tmp_path, "assign_watch")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"],
                      "note": "幫個忙"},
                headers=asker)

            got = (await client.get(
                "/api/assignments?session_key=agent-worker")).json()
            reqs = got["task_requests"]
            assert len(reqs) == 1, "被指名的 agent 在輪詢裡看不到請求"
            assert reqs[0]["task_title"] == "孤兒卡"
            assert reqs[0]["requester_name"] == "提議的人"
            assert reqs[0]["note"] == "幫個忙"

            # 🔴 別人的請求不會出現在我的輪詢裡
            got = (await client.get(
                "/api/assignments?session_key=agent-asker")).json()
            assert got["task_requests"] == [], \
                "提議者自己的輪詢收到了要對方回答的請求"

            # 答完就不再出現——留著會讓 agent 每一輪都被同一件事叫醒一次
            r = await client.post(
                f"/api/board/task-requests/{reqs[0]['id']}/resolve",
                json={"accept": True}, headers=worker)
            assert r.status_code == 200, r.text
            got = (await client.get(
                "/api/assignments?session_key=agent-worker")).json()
            assert got["task_requests"] == []


async def test_assigning_to_nobody_clears_the_assignment(tmp_path):
    """空 target ＝ 取消指派（測試Novia #390 缺口 ①）。

    照 `BoardSupervisorSet` 的既有慣例：**空字串是卸任，不是「這個欄位沒填」**。
    另開一條 DELETE 也做得到，但指定與取消是同一個決定的兩面，兩條路徑會讓
    「現在到底指派給誰」多一個出錯的地方。

    在此之前空 target 回 422 ⇒ **指派出去收不回**，而人事會變、卡會轉手。
    """
    app, client = await _client(tmp_path, "assign_clear")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            worker = await _join(client, rid, "agent-worker", "接手的人")

            await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=boss)
            assert (await _card(client, rid, boss, tid)
                    )["assignee_participant_id"] is not None

            r = await client.post(f"/api/board/tasks/{tid}/assign",
                                  json={}, headers=boss)
            assert r.status_code == 200, r.text
            assert r.json()["assigned"] is False
            assert r.json()["cleared"] is True

            card = await _card(client, rid, boss, tid)
            assert card["assignee_participant_id"] is None
            assert card["assignee_actor_key"] == ""

            # 🔴 取消是管理動作：非管理員不能清掉別人做的指派
            other = await _join(client, rid, "agent-other", "路人")
            await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=boss)
            r = await client.post(f"/api/board/tasks/{tid}/assign",
                                  json={}, headers=other)
            assert r.status_code == 403, r.text


async def test_the_requester_hears_back_when_the_answer_comes(tmp_path):
    """發起者要知道對方答了沒（測試Novia #390 缺口 ②）。

    在此之前 `/api/assignments` **只回「指名我的」** ⇒ 送出請求的人靠通知
    完全不知道結果，而他正是最需要知道的那個：對方拒絕了他要另找人，對方
    接下了他就可以放手。

    ⚠️ **回過就標記**（`requester_notified_at`），否則 watcher 重啟後會把
    三天前的答覆再通知一次——那種「舊事重播」比沒有通知更難信任。
    """
    app, client = await _client(tmp_path, "assign_echo")
    async with client:
        async with app.router.lifespan_context(app):
            rid, boss, tid = await _setup(client)
            asker = await _join(client, rid, "agent-asker", "提議的人")
            worker = await _join(client, rid, "agent-worker", "接手的人")

            req = (await client.post(
                f"/api/board/tasks/{tid}/assign",
                json={"target_participant_id": worker["X-Participant-Id"]},
                headers=asker)).json()["request"]

            # 還沒答之前，發起者的輪詢裡沒有東西要通知他
            got = (await client.get(
                "/api/assignments?session_key=agent-asker")).json()
            assert got["task_request_answers"] == []

            await client.post(
                f"/api/board/task-requests/{req['id']}/resolve",
                json={"accept": False}, headers=worker)

            got = (await client.get(
                "/api/assignments?session_key=agent-asker")).json()
            answers = got["task_request_answers"]
            assert len(answers) == 1, "發起者收不到對方的答覆"
            assert answers[0]["status"] == "declined"
            assert answers[0]["target_name"] == "接手的人"
            assert answers[0]["task_title"] == "孤兒卡"

            # 🔴 只通知一次——標記過就不再回，否則 watcher 每一輪都被同一件
            # 已經結束的事叫醒
            got = (await client.get(
                "/api/assignments?session_key=agent-asker")).json()
            assert got["task_request_answers"] == [], "同一個答覆通知了兩次"

            # 被指名者那側不會收到自己答過的東西
            got = (await client.get(
                "/api/assignments?session_key=agent-worker")).json()
            assert got["task_request_answers"] == []
