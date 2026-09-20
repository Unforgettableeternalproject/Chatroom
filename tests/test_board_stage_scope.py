"""板的讀取要有**階段粒度**（`checklist_id=`）。

起因：一個派工 agent 在房裡要找某個階段底下還沒做完的那兩張卡的 `task_id`，
而那塊板全量回 **72,970 字元**——超過它單次讀得下的量。既有的收窄只到
「週期」（`objective_id=`），而一期底下十幾個階段、上百張卡，那個粒度對
它一樣讀不動。

這個檔按 `test_board_scope.py`（週期粒度）的形狀寫，釘四件事：

1. 給了階段就**只有那個階段**的卡——連同它所屬的週期那一列（少了週期，
   讀的人不知道自己在哪一期，而那正是他要回報的座標）
2. **`checklist_id` 比 `objective_id` 優先**，兩個都給時週期那個被忽略
3. 找不到的階段回**機器可讀的 code**；把週期 id 當階段傳進來要講得出
   「它是別的層」，不是「找不到」
4. **增量也篩**——與週期粒度刻意不同：週期那條不篩是因為「斷線期間收尾
   的週期照樣要送達」，而 `checklist_id` 是讀的人這一次明確要的範圍，
   增量把別的階段塞回去的話，那個參數就只有第一次有用
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
    """一塊板、一個週期底下**兩個階段**，外加另一個週期。

    回 (bid, rid, me, ids)。兩個階段是重點：只有一個的話，「只回這個階段」
    與「回整個週期」長得一模一樣。
    """
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    pid = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})).json()["participant_id"]
    me = {**OWNER, "X-Participant-Id": pid}
    bid = (await client.post("/api/boards", headers=OWNER,
                             json={"name": "板"})).json()["id"]
    await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)

    ids = {"stages": {}, "tasks": {}}
    oid = (await client.post(f"/api/boards/{bid}/objectives", headers=OWNER,
                             json={"title": "JSAI-2383"})).json()["id"]
    ids["objective"] = oid
    for stage in ("要的那個階段", "別的階段"):
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 headers=OWNER,
                                 json={"title": stage})).json()["id"]
        ids["stages"][stage] = cid
        ids["tasks"][stage] = [
            (await client.post(f"/api/board/checklists/{cid}/tasks",
                               headers=OWNER,
                               json={"title": f"{stage} 的卡 {i}"})).json()["id"]
            for i in range(2)
        ]
    # 另一個週期：階段收窄要把它整個擋在外面
    other = (await client.post(f"/api/boards/{bid}/objectives", headers=OWNER,
                               json={"title": "別的週期"})).json()["id"]
    ids["other_objective"] = other
    ids["other_stage"] = (await client.post(
        f"/api/board/objectives/{other}/checklists", headers=OWNER,
        json={"title": "別的週期的階段"})).json()["id"]
    return bid, rid, me, ids


async def _read(client, bid, headers, **params):
    q = "&".join(f"{k}={v}" for k, v in params.items())
    r = await client.get(f"/api/boards/{bid}" + (f"?{q}" if q else ""),
                         headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def test_one_stage_comes_back_on_its_own(tmp_path):
    """判準 1：只回那個階段的卡，外加它所屬的週期那一列。"""
    app, client = await _client(tmp_path, "stage-one")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        want = ids["stages"]["要的那個階段"]
        body = await _read(client, bid, OWNER, checklist_id=want)

        assert [c["id"] for c in body["checklists"]] == [want]
        assert sorted(t["id"] for t in body["tasks"]) == sorted(
            ids["tasks"]["要的那個階段"])
        # 週期要在——少了它，讀的人不知道這階段掛在哪一期
        assert [o["id"] for o in body["objectives"]] == [ids["objective"]]


async def test_it_says_that_this_is_not_the_whole_board(tmp_path):
    """篩掉了就要說出來（與週期粒度同一條判準）。"""
    app, client = await _client(tmp_path, "stage-says-so")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        want = ids["stages"]["要的那個階段"]
        f = (await _read(client, bid, OWNER, checklist_id=want))["filtered"]
        assert f is not None, "只回了一個階段卻沒說"
        assert f["checklist_id"] == want
        assert f["objective_id"] == ids["objective"]
        # 兩句話：手上這份不是全部、我知道怎麼看到全部
        assert "只有" in f["reason"]
        assert ids["objective"] in f["how_to_see_them"]
        assert "checklist_id" in f["how_to_see_them"]


async def test_the_stage_wins_over_the_cycle(tmp_path):
    """判準 2：兩個都給時以 `checklist_id` 為準——兩個都給的意思就是
    「要更細的那個」。"""
    app, client = await _client(tmp_path, "stage-beats-cycle")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        want = ids["stages"]["要的那個階段"]
        body = await _read(client, bid, OWNER, checklist_id=want,
                           objective_id=ids["other_objective"])
        assert [c["id"] for c in body["checklists"]] == [want]
        assert [o["id"] for o in body["objectives"]] == [ids["objective"]]


async def test_an_unknown_stage_is_refused_with_a_code(tmp_path):
    """判準 3：找不到要有 code，不是安靜地回整塊板。"""
    app, client = await _client(tmp_path, "stage-missing")
    async with app.router.lifespan_context(app), client:
        bid, _, _, _ = await _setup(client)
        r = await client.get(f"/api/boards/{bid}?checklist_id=nope",
                             headers=OWNER)
        assert r.status_code == 404, r.text
        assert r.json()["detail"]["code"] == "checklist_not_found"


async def test_a_stage_from_another_board_is_not_reachable(tmp_path):
    """URL 上的 board_id 要真的守門：別塊板的階段不能從這裡讀出來。"""
    app, client = await _client(tmp_path, "stage-cross-board")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        other_bid = (await client.post("/api/boards", headers=OWNER,
                                       json={"name": "另一塊板"})).json()["id"]
        r = await client.get(
            f"/api/boards/{other_bid}?checklist_id={ids['stages']['別的階段']}",
            headers=OWNER)
        assert r.status_code == 404, r.text
        assert r.json()["detail"]["code"] == "checklist_not_found"


async def test_passing_an_objective_id_says_it_is_the_wrong_layer(tmp_path):
    """「這個 id 不存在」與「這個 id 是別的層」必須是兩句話——壓成同一句
    的話，傳錯層的人會去重讀板、確認它還在、再撞一次。"""
    app, client = await _client(tmp_path, "stage-wrong-kind")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        r = await client.get(
            f"/api/boards/{bid}?checklist_id={ids['objective']}",
            headers=OWNER)
        assert r.status_code == 422, r.text
        assert r.json()["detail"]["code"] == "board_item_wrong_kind"


async def test_the_incremental_read_is_narrowed_too(tmp_path):
    """判準 4：增量也只給那個階段的變動。

    ⚠️ 與週期粒度刻意不同——那條不篩是為了讓斷線期間收尾的週期送達；
    這條是讀的人**這一次明確要的範圍**，塞回別的階段等於那個參數只有
    第一次有用，而他正是因為讀不下整塊板才傳它。
    """
    app, client = await _client(tmp_path, "stage-incremental")
    async with app.router.lifespan_context(app), client:
        bid, _, me, ids = await _setup(client)
        want = ids["stages"]["要的那個階段"]
        before = (await _read(client, bid, OWNER))["board_seq"]

        # 兩個階段各動一張卡
        for stage in ("要的那個階段", "別的階段"):
            await client.post(
                f"/api/board/tasks/{ids['tasks'][stage][0]}/status",
                headers=me, json={"status": "in_progress"})

        body = await _read(client, bid, OWNER, after_board_seq=before,
                           checklist_id=want)
        got = {t["id"] for t in body["tasks"]}
        assert got == {ids["tasks"]["要的那個階段"][0]}, (
            "增量把別的階段的變動也塞回來了")


async def test_the_room_axis_behaves_the_same(tmp_path):
    """兩軸一致——從聊天室讀與從 Board Library 讀不該不同。"""
    app, client = await _client(tmp_path, "stage-room-axis")
    async with app.router.lifespan_context(app), client:
        _, rid, me, ids = await _setup(client)
        want = ids["stages"]["要的那個階段"]
        r = await client.get(f"/api/rooms/{rid}/board?checklist_id={want}",
                             headers=me)
        assert r.status_code == 200, r.text
        body = r.json()
        assert [c["id"] for c in body["checklists"]] == [want]
        assert [o["id"] for o in body["objectives"]] == [ids["objective"]]
        assert body["filtered"]["checklist_id"] == want

        bad = await client.get(f"/api/rooms/{rid}/board?checklist_id=nope",
                               headers=me)
        assert bad.status_code == 404, bad.text
        assert bad.json()["detail"]["code"] == "checklist_not_found"
