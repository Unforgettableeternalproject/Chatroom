"""上板（release）：候選計算、觸發閘、與 verify 的合流（契約 C3／C4）。

這份檔案守的幾條不變式，每一條都對應一個**安靜的錯誤**：

- 候選列出沒動過的 repo：人在對話框上勾了一個這個週期根本沒碰過的專案，
  而畫面上它與真的改過的長得一模一樣
- 候選跨週期：別的週期的 commit 被算進這一次上板，合併範圍比人以為的大
- agent 觸發得了上板：穩定分支被一個沒有人看著的 run 動掉
- `release_in_progress` 失守：同一個週期兩筆上板同時在跑，兩邊都在 merge
  同一條穩定分支
- 舊庫沒補欄：Hub 升級後開不起來，或 `head_before` 讀出 None 讓判準整個歪掉
"""

import aiosqlite
import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"
WS = "ai-website"
# 第二個工作區：板改掛到別間工作房時，候選要跟著換成**那一間**的 key。
# 兩間房綁同一個 key 的話，「拿錯房」與「拿對房」在斷言上長得一模一樣
WS_B = "ai-app"


def _clients(tmp_path, name, **cfg_kw):
    """人類憑證與 agent 憑證各一把，**指向同一個 app**（同 supervisor 那份）。

    共用一把的話，`_is_human_credential` 在沒設 `CHATROOM_HUMAN_TOKEN` 時
    一律 True，`release_requires_human` 那條會因為憑證關沒觸發而假綠。
    """
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 human_api_token=HUMAN, **cfg_kw)
    app = create_app(cfg)

    def _c(token):
        client = AsyncClient(transport=ASGITransport(app=app),
                             base_url="http://test",
                             headers={"Authorization": f"Bearer {token}"})
        client.hub_app = app
        return client

    return app, _c(HUMAN), _c(ROOT)


class _Runner(str):
    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _bind_workspace(client, rid, workspace=WS):
    # 直接寫欄位：綁定端點要求「當下已經有執行器服務這個 key」，而這裡
    # 是先建房後註冊。綁定端點自己的契約在 tests/test_room_workspace.py
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET workspace_key=? WHERE id=?",
                     (workspace, rid))
    await db.commit()


async def _ops_room(client, key="human-a", workspace=WS):
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": key})
    assert r.status_code == 200, r.text
    rid = r.json()["id"]
    await _bind_workspace(client, rid, workspace)
    return rid


async def _join_human(client, rid, key="human-a", name="艾斯維爾"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _join_agent(client, rid, key, name="諾薇亞"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "claude", "role": "agent",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _register_runner(client, projects=(WS,)):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": "ex1",
                                "projects": list(projects),
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    runner = _Runner(r.json()["runner"]["id"])
    runner.token = r.json()["runner_token"]
    return runner


DASH = {
    "repos": {
        f"{WS}/hub": {"branch": "develop", "stable_branch": "main",
                      "stable_branch_exists": True},
        f"{WS}/app": {"branch": "develop", "stable_branch": "",
                      "stable_branch_exists": False},
        f"{WS}/docs": {"branch": "main", "stable_branch": "main",
                       "stable_branch_exists": True},
        "other-ws/hub": {"branch": "x", "stable_branch": "main",
                         "stable_branch_exists": True},
    },
    "workspaces": {WS: {"release": {"merge_method": "squash",
                                    "merge_message": "release: {source}",
                                    "tag_message": "{objective}"}}},
}


DASH_BOTH = {
    "repos": {
        f"{WS}/hub": {"branch": "develop", "stable_branch": "main",
                      "stable_branch_exists": True},
        f"{WS_B}/hub": {"branch": "develop", "stable_branch": "release",
                        "stable_branch_exists": True},
    },
    "workspaces": {
        WS: {"release": {"merge_method": "squash"}},
        WS_B: {"release": {"merge_method": "ff_only"}},
    },
}


async def _archive_room(client, rid):
    """直接改欄位：封存端點的契約（誰按得動、成員只能提請求）在別處
    測，這裡要的只是「那間房已經封存」這個事實。"""
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET status=? WHERE id=?",
                     ("archived", rid))
    await db.commit()


async def _attach(client, bid, rid, key="human-a"):
    r = await client.post(f"/api/boards/{bid}/rooms/{rid}",
                          headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text


async def _heartbeat(client, runner, dashboard=None):
    r = await client.post(f"/api/runners/{runner}/heartbeat",
                          json={"status": "online", "running_count": 0,
                                "dashboard_json": (DASH if dashboard is None
                                                   else dashboard)},
                          headers=runner.headers)
    assert r.status_code == 200, r.text


async def _tree(client, rid, hdr, title="週期一", tasks=1):
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": title},
                             headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"},
                             headers=hdr)).json()["id"]
    tids = [(await client.post(f"/api/board/checklists/{cid}/tasks",
                               json={"title": f"任務{i}"},
                               headers=hdr)).json()["id"]
            for i in range(tasks)]
    return oid, cid, tids


async def _board_id(client, oid):
    row = await (await client.hub_app.state.db.execute(
        "SELECT board_id FROM board_objective WHERE id=?", (oid,))).fetchone()
    return row["board_id"]


async def _ran(human, agent, rid, hdr, runner, *, ref, board_id,
               repo="hub", branch="develop", before="aaa", after="bbb"):
    """派一筆 ticket、讓執行器領走、終局回報時帶 `git`。

    走完整條路而不是直接寫 agent_run：候選的判準吃的是 report 寫進去的那
    四欄，繞過端點的話「report 沒把 git 寫進去」這個缺陷驗不出來。
    """
    r = await human.post(f"/api/rooms/{rid}/runs",
                         json={"kind": "ticket", "project": WS, "ref": ref,
                               "brief": "做一下", "board_id": board_id},
                         headers=hdr)
    assert r.status_code == 200, r.text
    run_id = r.json()["run"]["id"]
    c = await agent.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    assert c.status_code == 200, c.text
    assert c.json()["run"]["id"] == run_id
    for status in ("running", "done"):
        rep = await agent.post(
            f"/api/runs/{run_id}/report",
            json={"status": status, "runner_id": str(runner),
                  "git": {"repo": repo, "branch": branch,
                          "head_before": before, "head_after": after}},
            headers=runner.headers)
        assert rep.status_code == 200, rep.text
    return run_id


async def _finish(client, cid, tids, hdr):
    for tid in tids:
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "in_progress"}, headers=hdr)
        await client.post(f"/api/board/tasks/{tid}/status",
                          json={"status": "done"}, headers=hdr)
    await client.post(f"/api/board/checklists/{cid}/status",
                      json={"status": "done"}, headers=hdr)


async def _to_review(human, agent_client, rid, oid, cid, tids, hdr):
    """把週期推到 review。**送審的人是 agent**——人類自己送審自己確認雖然
    合法，但閘 4 的存在讓這條路在別處已經有測試，這裡要的是乾淨的 review。
    """
    await _finish(human, cid, tids, hdr)
    sender = await _join_agent(agent_client, rid, "claude-worker", "工人")
    r = await agent_client.post(f"/api/board/objectives/{oid}/review",
                                headers=sender)
    assert r.status_code == 200, r.text


def _cand(body, name):
    return next((r for r in body["repos"] if r["name"] == name), None)


# ── 候選計算 ─────────────────────────────────────────────────────────

async def test_candidates_list_only_repos_this_cycle_actually_touched(tmp_path):
    """🚨 只列 head 真的變過的 repo。

    `head_before == head_after` 是「跑過但沒改」，兩欄一起空是「說不出來」
    （舊執行器）。任一種被列進候選，人就會在對話框上勾到一個這次根本沒動
    過的專案，而它與真的改過的長得一模一樣。
    """
    app, human, agent = _clients(tmp_path, "cand")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr, tasks=3)
            bid = await _board_id(human, oid)
            # 改過的
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", branch="develop",
                       before="a1", after="a2")
            # 跑過但沒改
            await _ran(human, agent, rid, hdr, runner, ref=tids[1],
                       board_id=bid, repo="docs", branch="main",
                       before="same", after="same")
            # 舊執行器：說不出來
            await _ran(human, agent, rid, hdr, runner, ref=tids[2],
                       board_id=bid, repo="app", branch="", before="",
                       after="")

            r = await human.get(
                f"/api/board/objectives/{oid}/release/candidates", headers=hdr)
            assert r.status_code == 200, r.text
            body = r.json()
            assert [x["name"] for x in body["repos"]] == ["hub"]
            hub = _cand(body, "hub")
            assert hub["stable_branch"] == "main"
            assert hub["stable_branch_exists"] is True
            assert hub["branches"] == ["develop"]
            assert hub["last_branch"] == "develop"
            assert hub["commits"] == 1
            assert hub["current_branch"] == "develop"
            assert body["workspace_key"] == WS
            assert body["possible"] is True
            # C1 的工作區設定順便帶出來給 App 顯示
            assert body["release_settings"]["merge_method"] == "squash"


async def test_candidates_ignore_runs_from_another_cycle(tmp_path):
    """只認同一個週期底下的 checklist／task。

    板是跨週期共用的，run 全部掛在同一塊板上——不照 ref 過濾的話，上一個
    週期動過的 repo 會被算進這一次，合併範圍比人以為的大。
    """
    app, human, agent = _clients(tmp_path, "othercycle")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr, "週期一")
            other_oid, other_cid, other_tids = await _tree(
                human, rid, hdr, "週期二")
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=other_tids[0],
                       board_id=bid, repo="docs", before="b1", after="b2")
            r = await human.get(
                f"/api/board/objectives/{oid}/release/candidates", headers=hdr)
            assert r.json()["repos"] == []
            assert r.json()["possible"] is False
            # 對照組：那一筆確實算在週期二頭上，這條測試才有驗到東西
            r2 = await human.get(
                f"/api/board/objectives/{other_oid}/release/candidates",
                headers=hdr)
            assert [x["name"] for x in r2.json()["repos"]] == ["docs"]


async def test_candidates_count_checklist_level_runs_too(tmp_path):
    """run.ref 也可能是 checklist_id（stage 派工），不是只有 task_id。"""
    app, human, agent = _clients(tmp_path, "checklistref")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=cid, board_id=bid,
                       repo="hub", branch="feature/x", before="c1",
                       after="c2")
            body = (await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr)).json()
            assert _cand(body, "hub")["last_branch"] == "feature/x"


# ── 上板走哪一間房 ───────────────────────────────────────────────────
#
# 規則（艾斯維爾 2026-09-22 裁定）：**上板只能從工作房觸發**。呼叫者必須是
# 「掛著這塊板、綁了工作區的 ops 房」的人類房內成員，上板才動得了那間房的
# 工作區。沒有退路——從板分頁進來（只有 session_key、沒有 participant）一律
# 不給上板，因為板可以同時掛很多房，而板分頁上看不出這一次會動到誰。

async def _cycle_in_a_then_move_to_b(human, agent):
    """週期建在房 A，板改掛到房 B，A 封存。回 `(oid, bid, rid_a, rid_b,
    hdr)`。

    這正是實測撞到的形狀（艾斯維爾 2026-09-21）：`board_objective.room_id`
    記的是建卡那間房，而它已經不是這塊板現在所在的地方。
    """
    rid_a = await _ops_room(human, workspace=WS)
    hdr = await _join_human(human, rid_a)
    runner = await _register_runner(agent, projects=(WS, WS_B))
    await _heartbeat(agent, runner, DASH_BOTH)
    oid, cid, tids = await _tree(human, rid_a, hdr)
    bid = await _board_id(human, oid)
    await _ran(human, agent, rid_a, hdr, runner, ref=tids[0], board_id=bid,
               repo="hub", branch="develop", before="k1", after="k2")
    await _to_review(human, agent, rid_a, oid, cid, tids, hdr)
    rid_b = await _ops_room(human, workspace=WS_B)
    await _attach(human, bid, rid_b)
    await _archive_room(human, rid_a)
    return oid, bid, rid_a, rid_b, hdr


async def test_candidates_follow_the_board_not_the_original_room(tmp_path):
    """🚨 候選看**呼叫者所在的那間工作房**，不看週期是在哪一間房建的。

    原始房封存之後，拿 `objective.room_id` 去查房會 409 `room_archived`，
    而 App 顯示的是「此聊天室已封存」——週期看起來壞了，實際上只是查錯
    了房（艾斯維爾 2026-09-21 實測）。

    所以呼叫者要是**房 B 的成員**才拿得到 B 的工作區：板掛在 B、人在 B，
    兩邊對上了，上板才動他看得到的那個工作區。
    """
    app, human, agent = _clients(tmp_path, "roomfollow")
    async with human, agent:
        async with app.router.lifespan_context(app):
            oid, bid, rid_a, rid_b, _hdr_a = await _cycle_in_a_then_move_to_b(
                human, agent)
            hdr_b = await _join_human(human, rid_b)
            r = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr_b)
            assert r.status_code == 200, r.text
            body = r.json()
            # B 的工作區，不是 A 的
            assert body["workspace_key"] == WS_B
            assert [x["name"] for x in body["repos"]] == ["hub"]
            assert _cand(body, "hub")["stable_branch"] == "release"
            assert body["possible"] is True
            assert body["reason"] == ""
            assert body["release_settings"]["merge_method"] == "ff_only"


async def test_the_release_run_lands_in_the_room_the_board_is_on(tmp_path):
    """verify 帶 release 建出來的 run，`room_id` 是呼叫者按下去的那間房。

    建在原始房的話，那筆 run 掛在一間封存的房底下：執行頁看不到它，
    收尾的週期報告也發不進任何人在看的地方。
    """
    app, human, agent = _clients(tmp_path, "runroom")
    async with human, agent:
        async with app.router.lifespan_context(app):
            oid, bid, rid_a, rid_b, _hdr_a = await _cycle_in_a_then_move_to_b(
                human, agent)
            hdr_b = await _join_human(human, rid_b)
            r = await human.post(
                f"/api/board/objectives/{oid}/verify",
                json={"release": {
                    "repos": [{"name": "hub",
                               "source_branch": "develop"}]}},
                headers=hdr_b)
            assert r.status_code == 200, r.text
            run = r.json()["release_run"]
            assert run["room_id"] == rid_b
            assert run["room_id"] != rid_a
            assert run["project"] == WS_B
            assert run["spec"]["room_id"] == rid_b
            assert run["spec"]["repos"] == [{"name": "hub",
                                             "source_branch": "develop",
                                             "stable_branch": "release"}]


async def test_the_board_axis_caller_has_no_room_context(tmp_path):
    """🚨 只帶 `X-Session-Key`（板分頁那條路）**上不了板**。

    那條路沒有 participant，`_board_item_writer` 退回 session_key 身分，
    補出來的 `room_id` 是**週期的原始房**——它可能早就封存了，而板同時
    掛著好幾間工作房時，板分頁上看不出這一次會動到哪一個工作區。與其
    替他挑一間，不如不給：候選靜靜地空（`reason=board_axis`），真的按
    下去才 403（艾斯維爾 2026-09-22）。
    """
    app, human, agent = _clients(tmp_path, "boardaxis")
    async with human, agent:
        async with app.router.lifespan_context(app):
            oid, bid, rid_a, rid_b, _hdr = await _cycle_in_a_then_move_to_b(
                human, agent)
            # 刻意不帶 X-Participant-Id，也不 join 房 B：session_key 那條
            # 退路只找得到「掛接房裡還活著的 participant」，這裡一個都沒有
            only_key = {"X-Session-Key": "human-a"}
            r = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=only_key)
            assert r.status_code == 200, r.text
            assert r.json() == {"workspace_key": "", "possible": False,
                                "repos": [], "release_settings": {},
                                "reason": "board_axis"}

            v = await human.post(
                f"/api/board/objectives/{oid}/verify",
                json={"release": {
                    "repos": [{"name": "hub",
                               "source_branch": "develop"}]}},
                headers=only_key)
            assert v.status_code == 403, v.text
            assert v.json()["detail"]["code"] == "release_requires_ops_room"
            assert v.json()["detail"]["reason"] == "board_axis"
            # 閘沒過 ⇒ 週期維持 review，不會被「確認並上板」順手確認掉
            o = await (await app.state.db.execute(
                "SELECT status FROM board_objective WHERE id=?",
                (oid,))).fetchone()
            assert o["status"] == "review"


async def test_a_room_that_is_not_the_boards_ops_room_gets_nothing(tmp_path):
    """呼叫者在一間**沒掛這塊板**的工作房裡：候選空、上板 403。

    他是這塊板的成員（所以進得來改卡），但他所在的那間房與這塊板沒有
    掛接關係——照著板現在掛在哪去挑一間，等於讓他上到一個他不在的房的
    工作區。`reason=not_ops_room_member` 讓 App 說得出為什麼。
    """
    app, human, agent = _clients(tmp_path, "otherroom")
    async with human, agent:
        async with app.router.lifespan_context(app):
            oid, bid, rid_a, rid_b, _hdr = await _cycle_in_a_then_move_to_b(
                human, agent)
            # 綁了工作區的 ops 房，只是**沒掛這塊板**
            rid_c = await _ops_room(human, workspace=WS)
            hdr_c = await _join_human(human, rid_c)

            c = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr_c)
            assert c.status_code == 200, c.text
            assert c.json() == {"workspace_key": "", "possible": False,
                                "repos": [], "release_settings": {},
                                "reason": "not_ops_room_member"}

            rel = await human.post(
                f"/api/board/objectives/{oid}/verify",
                json={"release": {
                    "repos": [{"name": "hub",
                               "source_branch": "develop"}]}},
                headers=hdr_c)
            assert rel.status_code == 403, rel.text
            assert rel.json()["detail"]["code"] == "release_requires_ops_room"
            assert rel.json()["detail"]["reason"] == "not_ops_room_member"


async def test_two_bound_ops_rooms_each_caller_gets_his_own(tmp_path):
    """板同時掛好幾間綁了工作區的工作房：**各拿自己那一間，沒有退回**。

    他按下去的那一間才是他以為會動的那一間——同一塊板、同一個週期，
    三個人按下去動到的是三個不同的工作區。以前沒有房內身分時會退回
    「最早掛上去的那一間」，那條退路已經拿掉了（見
    `test_the_board_axis_caller_has_no_room_context`）。
    """
    app, human, agent = _clients(tmp_path, "tworooms")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid_a = await _ops_room(human, workspace=WS)
            hdr_a = await _join_human(human, rid_a)
            runner = await _register_runner(agent, projects=(WS, WS_B))
            await _heartbeat(agent, runner, DASH_BOTH)
            oid, cid, tids = await _tree(human, rid_a, hdr_a)
            bid = await _board_id(human, oid)
            rid_b = await _ops_room(human, workspace=WS_B)
            await _attach(human, bid, rid_b)
            hdr_b = await _join_human(human, rid_b)
            # 第三間，**最晚掛上**：舊的退路會挑最早那一間（A），所以它
            # 拿到 ai-docs 這件事本身就證明沒有人在替他挑
            rid_c = await _ops_room(human, workspace="ai-docs")
            await _attach(human, bid, rid_c)
            hdr_c = await _join_human(human, rid_c)

            # 從 B 房的身分打進來是 B
            r2 = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr_b)
            assert r2.json()["workspace_key"] == WS_B
            # 從 A 房的身分打進來仍然是 A
            r3 = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr_a)
            assert r3.json()["workspace_key"] == WS
            # 從 C 房的身分打進來是 C
            r4 = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr_c)
            assert r4.json()["workspace_key"] == "ai-docs"


async def test_a_board_on_no_bound_ops_room_is_quiet_then_loud(tmp_path):
    """呼叫者那間工作房沒綁工作區：候選靜靜地空，上板才 403。

    候選**不報錯**是刻意的——確認週期本身不該因為上板不成立而被擋下來，
    而畫面上「沒有東西可以上板」只有一種顯示。真的按下上板才要說清楚
    為什麼：403 `release_requires_ops_room`，`reason=workspace_not_bound`
    ——房本身沒問題，缺的是綁定，那要人類房主去執行頁綁一次。
    """
    app, human, agent = _clients(tmp_path, "unbound")
    async with human, agent:
        async with app.router.lifespan_context(app):
            r = await human.post("/api/rooms",
                                 json={"name": "沒綁的工作房",
                                       "kind": "ops",
                                       "session_key": "human-a"})
            rid = r.json()["id"]
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            # 沒綁工作區的房連 ticket 都派不出去（409 `workspace_not_bound`），
            # 所以這裡本來就不會有動過的 repo——候選空是雙重的

            c = await human.get(
                f"/api/board/objectives/{oid}/release/candidates",
                headers=hdr)
            assert c.status_code == 200, c.text
            assert c.json() == {"workspace_key": "", "possible": False,
                                "repos": [], "release_settings": {},
                                "reason": "workspace_not_bound"}

            # 這道閘排在狀態閘之前，所以週期還在 active 也驗得到
            rel = await human.post(
                f"/api/board/objectives/{oid}/release",
                json={"repos": [{"name": "hub",
                                 "source_branch": "develop"}]},
                headers=hdr)
            assert rel.status_code == 403, rel.text
            assert rel.json()["detail"]["code"] == "release_requires_ops_room"
            assert rel.json()["detail"]["reason"] == "workspace_not_bound"


# ── report 帶 git ────────────────────────────────────────────────────

async def test_report_writes_the_git_columns(tmp_path):
    """C3：執行器回報的 `git` 要落進 `agent_run` 的四欄，並由 `_run_public`
    帶出來——只存不帶出去的話，App 與候選判準各讀各的。"""
    app, human, agent = _clients(tmp_path, "gitcols")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            run_id = await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                                board_id=bid, repo="hub", branch="develop",
                                before="d1", after="d2")
            row = await (await app.state.db.execute(
                "SELECT repo, branch, head_before, head_after FROM agent_run"
                " WHERE id=?", (run_id,))).fetchone()
            assert (row["repo"], row["branch"]) == ("hub", "develop")
            assert (row["head_before"], row["head_after"]) == ("d1", "d2")
            got = (await human.get(f"/api/runs/{run_id}",
                                   headers=hdr)).json()["run"]
            assert got["head_after"] == "d2"
            # 沒有 spec 的 run 也要有這個鍵：執行器那邊只寫一種取法
            assert got["spec"] == {}


# ── 觸發閘 ───────────────────────────────────────────────────────────

async def test_agent_cannot_trigger_a_release(tmp_path):
    """上板只有人類按得下去。agent 憑證 ＋ agent 成員一律 403。"""
    app, human, agent = _clients(tmp_path, "agentgate")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", before="e1", after="e2")
            await _to_review(human, agent, rid, oid, cid, tids, hdr)
            await human.post(f"/api/board/objectives/{oid}/verify",
                             headers=hdr)
            spy = await _join_agent(agent, rid, "claude-spy", "路人")
            r = await agent.post(
                f"/api/board/objectives/{oid}/release",
                json={"repos": [{"name": "hub", "source_branch": "develop"}]},
                headers=spy)
            assert r.status_code == 403, r.text
            assert r.json()["detail"]["code"] == "release_requires_human"


async def test_release_needs_a_verified_objective(tmp_path):
    """還在 active／review 的週期上不了板。"""
    app, human, agent = _clients(tmp_path, "notverified")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", before="f1", after="f2")
            r = await human.post(
                f"/api/board/objectives/{oid}/release",
                json={"repos": [{"name": "hub", "source_branch": "develop"}]},
                headers=hdr)
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "objective_not_verified"


async def test_a_repo_outside_the_candidates_is_rejected(tmp_path):
    """不在候選裡、或沒設穩定分支的 repo 一律擋下來。

    兩種都用同一個 code：對 client 而言處置一樣（那個 repo 勾不得），
    而分成兩個 code 等於把「這個 repo 這次沒動過」這件事洩給呼叫端。
    """
    app, human, agent = _clients(tmp_path, "noteligible")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr, tasks=2)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", before="g1", after="g2")
            # app 動過，但它在儀表板上沒有穩定分支
            await _ran(human, agent, rid, hdr, runner, ref=tids[1],
                       board_id=bid, repo="app", before="g3", after="g4")
            await _to_review(human, agent, rid, oid, cid, tids, hdr)
            await human.post(f"/api/board/objectives/{oid}/verify",
                             headers=hdr)

            r = await human.post(
                f"/api/board/objectives/{oid}/release",
                json={"repos": [{"name": "app", "source_branch": "develop"}]},
                headers=hdr)
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "release_repo_not_eligible"

            r2 = await human.post(
                f"/api/board/objectives/{oid}/release",
                json={"repos": [{"name": "nope",
                                 "source_branch": "develop"}]},
                headers=hdr)
            assert r2.json()["detail"]["code"] == "release_repo_not_eligible"

            # 來源就是穩定分支＝沒有東西可以併
            r3 = await human.post(
                f"/api/board/objectives/{oid}/release",
                json={"repos": [{"name": "hub", "source_branch": "main"}]},
                headers=hdr)
            assert r3.status_code == 409, r3.text
            assert r3.json()["detail"]["code"] == "release_source_is_stable"


async def test_verify_with_release_creates_the_run_in_one_call(tmp_path):
    """人按一次「確認並上板」：週期 verified，同時多一筆 kind=release 的 run。"""
    app, human, agent = _clients(tmp_path, "verifyrelease")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", branch="develop",
                       before="h1", after="h2")
            await _to_review(human, agent, rid, oid, cid, tids, hdr)
            r = await human.post(
                f"/api/board/objectives/{oid}/verify",
                json={"release": {
                    "repos": [{"name": "hub", "source_branch": "develop"}],
                    "tag": "v1.3.0"}},
                headers=hdr)
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["status"] == "verified"
            run = body["release_run"]
            assert run["kind"] == "release"
            assert run["ref"] == oid
            assert run["board_id"] == bid
            assert run["project"] == WS
            assert run["requester_kind"] == "human"
            spec = run["spec"]
            assert spec["objective_id"] == oid
            assert spec["objective_title"] == "週期一"
            assert spec["room_id"] == rid
            assert spec["tag"] == "v1.3.0"
            assert spec["repos"] == [{"name": "hub",
                                      "source_branch": "develop",
                                      "stable_branch": "main"}]


async def test_a_failed_release_gate_does_not_verify_the_objective(tmp_path):
    """閘沒過就整筆 4xx，週期**維持 review**。

    先確認再驗的話，人看到一個 409 而週期其實已經被確認掉了——畫面與錯誤
    說的是兩件事，而那一步沒有回頭鍵。
    """
    app, human, agent = _clients(tmp_path, "gatefirst")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", before="i1", after="i2")
            await _to_review(human, agent, rid, oid, cid, tids, hdr)
            r = await human.post(
                f"/api/board/objectives/{oid}/verify",
                json={"release": {
                    "repos": [{"name": "app", "source_branch": "develop"}]}},
                headers=hdr)
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "release_repo_not_eligible"
            row = await (await app.state.db.execute(
                "SELECT status FROM board_objective WHERE id=?",
                (oid,))).fetchone()
            assert row["status"] == "review"


async def test_only_one_release_per_cycle_at_a_time(tmp_path):
    """同一個週期不能有兩筆上板同時在跑——兩邊都在 merge 同一條穩定分支。"""
    app, human, agent = _clients(tmp_path, "inprogress")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            runner = await _register_runner(agent)
            await _heartbeat(agent, runner)
            oid, cid, tids = await _tree(human, rid, hdr)
            bid = await _board_id(human, oid)
            await _ran(human, agent, rid, hdr, runner, ref=tids[0],
                       board_id=bid, repo="hub", before="j1", after="j2")
            await _to_review(human, agent, rid, oid, cid, tids, hdr)
            payload = {"repos": [{"name": "hub",
                                  "source_branch": "develop"}]}
            first = await human.post(f"/api/board/objectives/{oid}/verify",
                                     json={"release": payload}, headers=hdr)
            assert first.status_code == 200, first.text
            second = await human.post(
                f"/api/board/objectives/{oid}/release", json=payload,
                headers=hdr)
            assert second.status_code == 409, second.text
            assert second.json()["detail"]["code"] == "release_in_progress"
            assert (second.json()["detail"]["run_id"]
                    == first.json()["release_run"]["id"])


async def test_supervisor_cannot_dispatch_a_release_run(tmp_path):
    """Supervisor 派得了 investigate／ticket／stage，release 與 push 同級擋掉。"""
    app, human, agent = _clients(tmp_path, "supgate")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            hdr = await _join_human(human, rid)
            await _register_runner(agent)
            sup = await _join_agent(agent, rid, "claude-sup", "監督者")
            r = await human.post(f"/api/rooms/{rid}/board/supervisor",
                                 json={"session_key": "claude-sup"},
                                 headers=hdr)
            assert r.status_code == 200, r.text
            # 對照組：一般 kind 它派得動，這條測試才驗得到「擋的是 kind」
            ok = await agent.post(f"/api/rooms/{rid}/runs",
                                  json={"kind": "investigate", "project": WS,
                                        "ref": "task-ok", "brief": "查"},
                                  headers=sup)
            assert ok.status_code == 200, ok.text
            bad = await agent.post(f"/api/rooms/{rid}/runs",
                                   json={"kind": "release", "project": WS,
                                         "ref": "task-bad", "brief": "上板"},
                                   headers=sup)
            assert bad.status_code == 403, bad.text
            assert (bad.json()["detail"]["code"]
                    == "kind_not_allowed_for_supervisor")


# ── 舊庫補欄 ─────────────────────────────────────────────────────────

LEGACY = """
CREATE TABLE room (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    topic TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    next_seq INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    archived_at TEXT
);
CREATE TABLE agent_run (
    id TEXT PRIMARY KEY,
    room_id TEXT NOT NULL,
    board_id TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL,
    project TEXT NOT NULL DEFAULT '',
    ref TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'queued',
    priority INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""


async def test_legacy_agent_run_gains_the_git_and_spec_columns(tmp_path):
    """一直在跑的 `chatroom.db` 要補得出這五欄，且舊列的語意不變。

    回填任何值都會讓「本週期 commit 過」的判準開始把沒碰過的 repo 列成
    候選——空字串是唯一說得出口的答案：說不出來。
    """
    path = str(tmp_path / "legacy.db")
    async with aiosqlite.connect(path) as db:
        await db.executescript(LEGACY)
        await db.execute(
            "INSERT INTO agent_run (id, room_id, kind, ref, status,"
            " created_at, updated_at) VALUES"
            " ('r1','room1','ticket','task-1','done','2026-01-01','2026-01-01')")
        await db.commit()

    db = await open_db(path)
    try:
        cols = {r[1] for r in await (
            await db.execute("PRAGMA table_info(agent_run)")).fetchall()}
        assert {"repo", "branch", "head_before", "head_after",
                "spec_json"} <= cols
        row = await (await db.execute(
            "SELECT repo, branch, head_before, head_after, spec_json"
            " FROM agent_run WHERE id='r1'")).fetchone()
        assert tuple(row) == ("", "", "", "", "")
    finally:
        await db.close()


def test_git_ref_pattern_rejects_argument_looking_values():
    """分支名與 tag 會原樣進執行器的 git argv：以 `-` 開頭、含空白或 `..`
    的值在 Hub 就 422，不能等到執行器組指令時才炸。"""
    import re
    from chatroom_server.app import _GIT_REF_PATTERN
    ok = ["develop", "feature/x-1", "v1.2.3", "release_2026.09"]
    bad = ["-x", "--force", "a b", "a..b", "", "a\nb", "a;b", "a`b`"]
    for v in ok:
        assert re.match(_GIT_REF_PATTERN, v), v
    for v in bad:
        assert not re.match(_GIT_REF_PATTERN, v), v


def test_release_request_rejects_argument_looking_branch_and_tag():
    import pytest as _pytest
    from chatroom_server.app import ReleaseRequest
    ReleaseRequest(repos=[{"name": "hub", "source_branch": "develop"}],
                   tag="v1.2.5")
    for bad in ("-x", "--force", "a b", "a..b"):
        with _pytest.raises(ValueError):
            ReleaseRequest(repos=[{"name": "hub", "source_branch": bad}])
        with _pytest.raises(ValueError):
            ReleaseRequest(repos=[{"name": "hub", "source_branch": "dev"}],
                           tag=bad)
