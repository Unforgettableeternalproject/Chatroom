"""板的預設讀取只回進行中週期（09/07 卡 659e9ff0）。

實測：本專案的板 `full=true` 回 **274,701 字元 / 5,943 行**（三台一致），
超過 agent 單次可讀上限 ⇒ **板一大就讀不動**。我自己今天早上讀它時就撞到了。

測試端 09/07 定了四條驗收（房內 seq 121），這個檔按它寫：

1. 預設回應要進得了讀取上限
2. 🚨 **「被篩掉了」必須說出來**——最糟的不是回太多，是回了 12 張卡而讀的人
   以為那就是全部。沒有這個欄位的話，這張卡把「拿不到」換成「拿到假的」
3. 舊週期要拿得到，**而且路要在回應裡**（不必回去翻文件）
4. **`full=true` 的語意不能被偷換**：它的意思是「重看整塊板」。收窄的是
   預設值，不是 full——要改 full 的語意就得換個名字，否則下一個人會照舊
   語意用它
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
    """一塊板、兩個週期：一個還在做、一個已經收尾（各帶一張卡）。"""
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    pid = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "Bernie"})).json()["participant_id"]
    me = {**OWNER, "X-Participant-Id": pid}
    bid = (await client.post("/api/boards", headers=OWNER,
                             json={"name": "板"})).json()["id"]
    await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)

    ids = {}
    for key, title in (("old", "08/31 週期"), ("live", "09/07 週期")):
        oid = (await client.post(f"/api/boards/{bid}/objectives", headers=OWNER,
                                 json={"title": title})).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 headers=OWNER,
                                 json={"title": f"{title} 的階段"})).json()["id"]
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 headers=OWNER,
                                 json={"title": f"{title} 的卡"})).json()["id"]
        ids[key] = {"objective": oid, "checklist": cid, "task": tid}
    # 舊週期收尾：卡 → 清單 → 送審 → 確認 → 完成。**走完整條閘**——
    # 直接 UPDATE 的話測到的是一個 API 產不出來的狀態
    oid = ids["old"]["objective"]
    await client.post(f"/api/board/tasks/{ids['old']['task']}/status",
                      headers=me, json={"status": "done"})
    await client.post(f"/api/board/checklists/{ids['old']['checklist']}/status",
                      headers=me, json={"status": "done"})
    for step in ("review", "verify", "complete"):
        r = await client.post(f"/api/board/objectives/{oid}/{step}", headers=me)
        assert r.status_code == 200, f"{step}: {r.text}"
    return bid, rid, me, ids


async def _read(client, bid, headers, **params):
    q = "&".join(f"{k}={v}" for k, v in params.items())
    r = await client.get(f"/api/boards/{bid}" + (f"?{q}" if q else ""),
                         headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def test_the_default_read_only_carries_live_cycles(tmp_path):
    """預設不回已收尾的週期——那是這張卡的本體。"""
    app, client = await _client(tmp_path, "scope-default")
    async with app.router.lifespan_context(app), client:
        bid, _, me, ids = await _setup(client)
        body = await _read(client, bid, OWNER)
        got = {o["id"] for o in body["objectives"]}
        assert ids["live"]["objective"] in got
        assert ids["old"]["objective"] not in got
        # 子項要跟著走：只篩週期而留下它的卡，畫面上會是一堆沒有歸屬的卡
        assert ids["old"]["task"] not in {t["id"] for t in body["tasks"]}
        assert ids["old"]["checklist"] not in {c["id"]
                                               for c in body["checklists"]}


async def test_what_was_filtered_out_is_said_out_loud(tmp_path):
    """🚨 判準 2：最糟的不是回太多，是**回了一部分而讀的人以為那就是全部**。

    沒有這個欄位的話，這張卡把一個「拿不到」換成一個「拿到假的」。
    """
    app, client = await _client(tmp_path, "scope-says-so")
    async with app.router.lifespan_context(app), client:
        bid, _, _, _ = await _setup(client)
        body = await _read(client, bid, OWNER)
        f = body["filtered"]
        assert f is not None, "篩掉了東西卻沒說"
        assert f["objectives"] == 1
        assert f["tasks"] == 1
        # 判準 3：路要在回應裡，不必回去翻文件
        assert "include_settled" in f["how_to_see_them"]


async def test_nothing_filtered_means_no_notice(tmp_path):
    """沒篩掉東西就不要無中生有——一個恆存在的欄位會被讀成「總是有東西
    被藏起來」。"""
    app, client = await _client(tmp_path, "scope-clean")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "房", "session_key": "human-1"})).json()["id"]
        bid = (await client.post("/api/boards", headers=OWNER,
                                 json={"name": "板"})).json()["id"]
        await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=OWNER)
        await client.post(f"/api/boards/{bid}/objectives", headers=OWNER,
                          json={"title": "還在做"})
        assert (await _read(client, bid, OWNER))["filtered"] is None


async def test_include_settled_brings_the_history_back(tmp_path):
    """判準 3：舊週期要拿得到。"""
    app, client = await _client(tmp_path, "scope-all")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        body = await _read(client, bid, OWNER, include_settled="true")
        got = {o["id"] for o in body["objectives"]}
        assert ids["old"]["objective"] in got and ids["live"]["objective"] in got
        assert body["filtered"] is None


async def test_one_cycle_can_be_fetched_on_its_own(tmp_path):
    """整份歷史仍然可能太大，所以還要有「只看這一個週期」那條路。"""
    app, client = await _client(tmp_path, "scope-one")
    async with app.router.lifespan_context(app), client:
        bid, _, _, ids = await _setup(client)
        body = await _read(client, bid, OWNER,
                           objective_id=ids["old"]["objective"])
        assert [o["id"] for o in body["objectives"]] == [ids["old"]["objective"]]
        assert [t["id"] for t in body["tasks"]] == [ids["old"]["task"]]


async def test_the_incremental_path_is_untouched(tmp_path):
    """增量不篩（卡上明列）。**斷線期間收尾的週期照樣要送達**——
    篩掉的話，client 手上那份會永遠停在「還在做」。
    """
    app, client = await _client(tmp_path, "scope-incremental")
    async with app.router.lifespan_context(app), client:
        bid, _, me, ids = await _setup(client)
        before = (await _read(client, bid, OWNER,
                              include_settled="true"))["board_seq"]
        # 再收尾一次（reopen → done）製造一筆增量
        oid = ids["old"]["objective"]
        await client.post(f"/api/board/objectives/{oid}/reopen", headers=me)
        for step in ("review", "verify", "complete"):
            await client.post(f"/api/board/objectives/{oid}/{step}", headers=me)
        body = await _read(client, bid, OWNER, after_board_seq=before)
        assert ids["old"]["objective"] in {o["id"] for o in body["objectives"]}


async def test_the_room_axis_behaves_the_same(tmp_path):
    """兩軸一致——同一塊板從聊天室看與從 Board Library 看不該不同。"""
    app, client = await _client(tmp_path, "scope-room-axis")
    async with app.router.lifespan_context(app), client:
        _, rid, me, ids = await _setup(client)
        r = await client.get(f"/api/rooms/{rid}/board", headers=me)
        assert r.status_code == 200, r.text
        body = r.json()
        assert ids["old"]["objective"] not in {o["id"]
                                               for o in body["objectives"]}
        assert body["filtered"] is not None


async def test_the_default_response_is_small_enough_to_read(tmp_path):
    """判準 1：預設回應要進得了 agent 的讀取上限。

    這條測的是**比例**不是絕對值：造 30 個收尾週期，預設回應必須遠小於
    全量。真實的門檻（~275k 字元）在測試裡造不出來，但「篩掉的那些真的沒有
    被送出去」是同一件事的可驗證形式。
    """
    app, client = await _client(tmp_path, "scope-size")
    async with app.router.lifespan_context(app), client:
        bid, _, me, _ = await _setup(client)
        for i in range(30):
            oid = (await client.post(f"/api/boards/{bid}/objectives",
                                     headers=OWNER,
                                     json={"title": f"歷史週期 {i}",
                                           "description": "x" * 500})
                   ).json()["id"]
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     headers=OWNER,
                                     json={"title": "階段"})).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     headers=OWNER,
                                     json={"title": "卡",
                                           "description": "y" * 500})
                   ).json()["id"]
            await client.post(f"/api/board/tasks/{tid}/status", headers=me,
                              json={"status": "done"})
            await client.post(f"/api/board/checklists/{cid}/status", headers=me,
                              json={"status": "done"})
            for step in ("review", "verify", "complete"):
                await client.post(f"/api/board/objectives/{oid}/{step}",
                                  headers=me)
        import json
        default_size = len(json.dumps(await _read(client, bid, OWNER)))
        full_size = len(json.dumps(await _read(client, bid, OWNER,
                                               include_settled="true")))
        assert default_size * 3 < full_size, (
            f"預設 {default_size} 對全量 {full_size}——沒有真的變小")
