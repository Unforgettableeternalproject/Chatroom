"""跨週期搬遷：Task 的 `moved` 終態（09/07 卡 73fe4d94）。

決策裁（釘選 seq 16 第 4 點）：新增終態 `moved`，記 `moved_to` 指向新卡；
板 owner 與房 Supervisor 可直接收，不需先認領。**不做自動搬遷工具——先解
「收不掉」。**

要解的到底是什麼：一張卡的工作被搬到新週期之後，舊卡卡在原地。它不是 done
（那件事在這裡沒有做完）、也不是 cancelled（那不是「不做了」），於是沒有
任何一個狀態說得出實話。而底下有一張沒收尾的卡，整份清單就送不出審——
**一個週期會被一張早就搬走的卡永遠擋著。**

所以 `moved` 必須在每一個「已收尾」的判斷裡都算數，不只是多一個狀態名。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = {"X-Session-Key": "human-1"}


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _setup(client):
    """一塊板、一間房、一張別人認領的卡。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    agent = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": "claude-1",
        "preferred_name": "Novia"})).json()["participant_id"]
    bid = (await client.post("/api/boards", headers=OWNER,
                             json={"name": "板"})).json()["id"]
    r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
    assert r.status_code == 200, r.text
    tid = (await client.post(f"/api/boards/{bid}/tasks", headers=OWNER,
                             json={"title": "舊週期的卡"})).json()["id"]
    return bid, rid, tid, agent


async def _status(client, tid, status, headers, **extra):
    return await client.post(f"/api/board/tasks/{tid}/status",
                             headers=headers,
                             json={"status": status, **extra})


async def _task(client, bid, tid):
    board = (await client.get(f"/api/boards/{bid}", headers=OWNER)).json()
    return [t for t in board["tasks"] if t["id"] == tid][0]


async def test_a_task_can_be_marked_moved(tmp_path):
    app, client = await _client(tmp_path, "moved-basic")
    async with app.router.lifespan_context(app), client:
        bid, _, tid, _ = await _setup(client)
        new = (await client.post(f"/api/boards/{bid}/tasks", headers=OWNER,
                                 json={"title": "新週期的卡"})).json()["id"]
        r = await _status(client, tid, "moved", OWNER, moved_to=new)
        assert r.status_code == 200, r.text
        t = await _task(client, bid, tid)
        assert t["status"] == "moved"
        assert t["moved_to"] == new


async def test_moved_to_must_point_at_a_card_that_exists(tmp_path):
    """指向不存在的卡等於沒有指向——而畫面會照樣畫一個點得下去的連結。"""
    app, client = await _client(tmp_path, "moved-dangling")
    async with app.router.lifespan_context(app), client:
        bid, _, tid, _ = await _setup(client)
        r = await _status(client, tid, "moved", OWNER, moved_to="不存在")
        assert r.status_code == 404, r.text
        assert r.json()["detail"]["code"] == "moved_to_not_found"


async def test_a_card_can_be_moved_without_saying_where(tmp_path):
    """搬去哪還沒建卡的情況是真的——**先解收不掉**，指向是加分。"""
    app, client = await _client(tmp_path, "moved-no-target")
    async with app.router.lifespan_context(app), client:
        bid, _, tid, _ = await _setup(client)
        r = await _status(client, tid, "moved", OWNER)
        assert r.status_code == 200, r.text
        assert (await _task(client, bid, tid))["moved_to"] == ""


async def test_a_card_cannot_be_moved_onto_itself(tmp_path):
    """自己指向自己的卡是一個沒有出口的迴圈，而它讀起來完全正常。"""
    app, client = await _client(tmp_path, "moved-self")
    async with app.router.lifespan_context(app), client:
        bid, _, tid, _ = await _setup(client)
        r = await _status(client, tid, "moved", OWNER, moved_to=tid)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "moved_to_self"


async def test_a_moved_card_no_longer_blocks_its_checklist(tmp_path):
    """**這是這張卡真正要解的東西。**

    底下有一張沒收尾的卡，整份清單就送不出審。搬走的卡若不算收尾，一個週期
    會被一張早就不在這裡的卡永遠擋著。
    """
    app, client = await _client(tmp_path, "moved-unblocks")
    async with app.router.lifespan_context(app), client:
        bid, _, tid, _ = await _setup(client)
        done_id = (await client.post(f"/api/boards/{bid}/tasks", headers=OWNER,
                                     json={"title": "真的做完的卡"})
                   ).json()["id"]
        assert (await _status(client, done_id, "done", OWNER)).status_code == 200
        assert (await _status(client, tid, "moved", OWNER)).status_code == 200

        board = (await client.get(f"/api/boards/{bid}", headers=OWNER)).json()
        cid = [t for t in board["tasks"] if t["id"] == tid][0]["checklist_id"]
        r = await client.post(f"/api/board/checklists/{cid}/status",
                              headers=OWNER, json={"status": "done"})
        assert r.status_code == 200, r.text


async def test_a_moved_card_cannot_be_claimed(tmp_path):
    """它已經不在這裡了。認領它的人會對著一張沒有工作的卡做事。"""
    app, client = await _client(tmp_path, "moved-claim")
    async with app.router.lifespan_context(app), client:
        _, _, tid, agent = await _setup(client)
        assert (await _status(client, tid, "moved", OWNER)).status_code == 200
        r = await client.post(f"/api/board/tasks/{tid}/claim",
                              headers={"X-Participant-Id": agent})
        assert r.status_code == 409, r.text


async def test_the_board_owner_can_move_someone_elses_card(tmp_path):
    """不需先認領——搬遷是收拾，而要收拾的正是別人留下來的東西。"""
    app, client = await _client(tmp_path, "moved-owner")
    async with app.router.lifespan_context(app), client:
        _, _, tid, agent = await _setup(client)
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers={"X-Participant-Id": agent})
                ).status_code == 200
        r = await _status(client, tid, "moved", OWNER)
        assert r.status_code == 200, r.text


async def test_the_rooms_supervisor_can_move_someone_elses_card(tmp_path):
    """決策明列 Supervisor——他是那個負責看的人，而搬遷正是他在收的尾。"""
    app, client = await _client(tmp_path, "moved-supervisor")
    async with app.router.lifespan_context(app), client:
        bid, rid, tid, agent = await _setup(client)
        sup = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": "sup-1",
            "preferred_name": "監督者"})).json()["participant_id"]
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              headers=OWNER, json={"session_key": "sup-1"})
        assert r.status_code == 200, r.text
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers={"X-Participant-Id": agent})
                ).status_code == 200
        r = await _status(client, tid, "moved",
                          {"X-Participant-Id": sup})
        assert r.status_code == 200, r.text


async def test_a_plain_agent_still_cannot_move_someone_elses_card(tmp_path):
    """放寬的是 owner 與 Supervisor，不是所有人。"""
    app, client = await _client(tmp_path, "moved-outsider")
    async with app.router.lifespan_context(app), client:
        _, rid, tid, agent = await _setup(client)
        other = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": "claude-2",
            "preferred_name": "旁人"})).json()["participant_id"]
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers={"X-Participant-Id": agent})
                ).status_code == 200
        r = await _status(client, tid, "moved",
                          {"X-Participant-Id": other})
        assert r.status_code == 403, r.text


async def test_a_settled_card_cannot_be_moved_sideways(tmp_path):
    """收尾了的不能橫向改成另一種收尾——與 done↔cancelled 同一條既有規則。"""
    app, client = await _client(tmp_path, "moved-sideways")
    async with app.router.lifespan_context(app), client:
        _, _, tid, _ = await _setup(client)
        assert (await _status(client, tid, "done", OWNER)).status_code == 200
        r = await _status(client, tid, "moved", OWNER)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "invalid_transition"


async def test_a_move_can_be_undone_by_a_human(tmp_path):
    """搬錯了要收得回來，與 cancelled 的復原對稱。"""
    app, client = await _client(tmp_path, "moved-undo")
    async with app.router.lifespan_context(app), client:
        bid, rid, tid, _ = await _setup(client)
        human = (await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "Bernie"})).json()["participant_id"]
        assert (await _status(client, tid, "moved", OWNER)).status_code == 200
        r = await _status(client, tid, "todo", {"X-Participant-Id": human})
        assert r.status_code == 200, r.text
        t = await _task(client, bid, tid)
        assert t["status"] == "todo"
        # 指向也要跟著清掉——留著的話那張卡同時「在這裡」與「搬到別處了」
        assert t["moved_to"] == ""
