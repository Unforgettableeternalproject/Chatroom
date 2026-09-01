"""收尾的容器不收新卡（艾斯維爾 2026-09-02 裁定走「拒收」）。

這個缺陷是驗收當下自己撞出來的：把一份 Checklist 推 `done` 之後，二十秒內
就有一張新卡建進去了，而 Hub 完全沒擋。

**後果不是那張卡有問題，是送審閘失效**：閘驗的是 Checklist 的狀態，不是底下
Task 的狀態 ⇒ 一份 `done` 的 Checklist 底下躺著一張 `todo` 的卡時，週期照樣
送得出去、確認得了、完成得掉——板上寫著全部做完，實際上有一件沒做。

「未分類」是**唯一的例外**，理由見 `_reopen_if_settled` 的說明。
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


async def _setup(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "艾斯維爾"})
    hdr = {"X-Participant-Id": r.json()["participant_id"]}
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段一"}, headers=hdr)).json()["id"]
    return rid, hdr, oid, cid


async def _settle_checklist(client, hdr, cid, tid=None):
    """收尾一份 Checklist：底下至少要有一張 done 的卡。"""
    if tid is None:
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "先做一件"},
                                 headers=hdr)).json()["id"]
    for target in ("in_progress", "done"):
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": target}, headers=hdr)
    r = await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=hdr)
    assert r.status_code == 200, r.text


async def test_a_done_checklist_refuses_new_tasks(tmp_path):
    app, client = await _client(tmp_path, "settled_cl")
    async with app.router.lifespan_context(app), client:
        rid, hdr, oid, cid = await _setup(client)
        assert rid and oid
        await _settle_checklist(client, hdr, cid)

        r = await client.post(f"/api/board/checklists/{cid}/tasks",
                              json={"title": "偷渡一張"}, headers=hdr)
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "container_settled"
        # 被擋下來的人要拿得到往下走的資訊（F1 的教訓）
        assert detail["reopen_to"] == "open"


async def test_a_cancelled_objective_refuses_new_checklists(tmp_path):
    app, client = await _client(tmp_path, "settled_obj")
    async with app.router.lifespan_context(app), client:
        rid, hdr, oid, cid = await _setup(client)
        assert rid and cid
        r = await client.post(f"/api/board/objectives/{oid}/cancel", headers=hdr)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/objectives/{oid}/checklists",
                              json={"title": "偷渡一段"}, headers=hdr)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "container_settled"


async def test_the_gate_checks_both_levels(tmp_path):
    """⚠️ 只擋直接父層的話，這個組合會整個漏掉。

    週期收尾**不要求**先把每一份清單收掉（閘只看「所有 checklist ∈
    done/cancelled」，而 cancelled 的清單不必收），所以「Objective 已收尾、
    底下某個 Checklist 還 open」是走得到的狀態。
    """
    app, client = await _client(tmp_path, "settled_two_levels")
    async with app.router.lifespan_context(app), client:
        rid, hdr, oid, cid = await _setup(client)
        assert rid
        # 另開一份清單，讓它保持 open；主清單收尾後把週期取消
        other = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                   json={"title": "還開著的階段"},
                                   headers=hdr)).json()["id"]
        await client.post(f"/api/board/objectives/{oid}/cancel", headers=hdr)

        row = await (await app.state.db.execute(
            "SELECT status FROM board_checklist WHERE id=?", (other,))).fetchone()
        assert row["status"] == "open", "前提：取消週期不 cascade 子層"

        r = await client.post(f"/api/board/checklists/{other}/tasks",
                              json={"title": "從還開著的那層偷渡"}, headers=hdr)
        assert r.status_code == 409, "直接父層還開著，但上面那層收尾了"
        assert r.json()["detail"]["code"] == "container_settled"
        assert cid


async def test_uncategorised_is_reopened_instead_of_refused(tmp_path):
    """🔑 唯一的例外：「未分類」收到就打回，不拒收。

    它不是任何人選的容器，是 Hub 自己的收納格，靠固定名字找回同一格。
    而它**一定會被收尾**——週期要送審就得先把它收掉。純拒收的話，「隨手記
    一件事」從那一刻起整條壞掉，而且不能改用新建一組繞過（unique index 擋著）。
    """
    app, client = await _client(tmp_path, "uncat_reopen")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "owner"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "艾斯維爾"})
        hdr = {"X-Participant-Id": r.json()["participant_id"]}

        first = (await client.post(f"/api/rooms/{rid}/board/tasks",
                                   json={"title": "隨手記一件"},
                                   headers=hdr)).json()["id"]
        row = await (await app.state.db.execute(
            "SELECT checklist_id FROM board_task WHERE id=?", (first,))).fetchone()
        cid = row["checklist_id"]
        await _settle_checklist(client, hdr, cid, tid=first)

        # 收尾之後再記一件事：要成功，而且那一格要被打回 open
        r = await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "收尾之後又想到一件"}, headers=hdr)
        assert r.status_code == 200, r.text
        second = r.json()["id"]

        row = await (await app.state.db.execute(
            "SELECT checklist_id FROM board_task WHERE id=?", (second,))).fetchone()
        assert row["checklist_id"] == cid, "應該重用同一格，不是新建一組"

        row = await (await app.state.db.execute(
            "SELECT status FROM board_checklist WHERE id=?", (cid,))).fetchone()
        assert row["status"] == "open", "未分類要被打回，不是留在 done"

        # 只有一組——unique index 與重用都還在
        n = await (await app.state.db.execute(
            "SELECT COUNT(*) AS n FROM board_checklist WHERE room_id=?"
            " AND title='未分類' AND deleted=0", (rid,))).fetchone()
        assert n["n"] == 1


async def test_a_reviewed_objective_refuses_new_checklists(tmp_path):
    """🔑 判準是「不是 active 就拒收」，不只是收尾。

    **閘只在送審那一刻驗過一次。** 之後加進來的 Checklist 是 `open` 的，
    而週期會一路走到 `done`——底下卻掛著一段從沒做完的東西。同一個 bug，
    只是換到上面一層。

    （第一版我只擋收尾，理由是「送審會被打回，那時卡還要進得來」；但打回
    之後狀態就是 `active`，本來就進得來，那個理由不支撐 review 可寫。）
    """
    app, client = await _client(tmp_path, "reviewed_obj")
    async with app.router.lifespan_context(app), client:
        rid, hdr, oid, cid = await _setup(client)
        assert rid
        await _settle_checklist(client, hdr, cid)
        r = await client.post(f"/api/board/objectives/{oid}/review", headers=hdr)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/objectives/{oid}/checklists",
                              json={"title": "送審之後偷渡一段"}, headers=hdr)
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "container_settled"
        assert detail["item_status"] == "review"
        assert detail["reopen_to"] == "active"


async def test_a_verified_objective_refuses_new_checklists(tmp_path):
    """`verified` 更明顯：人類已經確認過，之後加進來的不會再被任何人看一眼，
    而 `complete` 不重驗。"""
    app, client = await _client(tmp_path, "verified_obj")
    async with app.router.lifespan_context(app), client:
        rid, hdr, oid, cid = await _setup(client)
        assert rid
        await _settle_checklist(client, hdr, cid)
        await client.post(f"/api/board/objectives/{oid}/review", headers=hdr)
        r = await client.post(f"/api/board/objectives/{oid}/verify", headers=hdr)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/objectives/{oid}/checklists",
                              json={"title": "確認之後偷渡一段"}, headers=hdr)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["item_status"] == "verified"


async def test_an_active_objective_still_accepts_checklists(tmp_path):
    """錨點：擋掉「把整個閘關死」也會過的寫法。"""
    app, client = await _client(tmp_path, "active_obj_ok")
    async with app.router.lifespan_context(app), client:
        rid, hdr, oid, cid = await _setup(client)
        assert rid and cid
        r = await client.post(f"/api/board/objectives/{oid}/checklists",
                              json={"title": "正常加一段"}, headers=hdr)
        assert r.status_code == 200, r.text
