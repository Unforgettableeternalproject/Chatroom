"""Supervisor 自派工（艾斯維爾 2026-09-19）。

`create_run` 原本是 human-only 的雙重閘（人類憑證 ∧ role=human）。放寬之後
多出來的那條路是**這塊板的 Supervisor**，而它整個安全性靠三件事撐著，
每一件失守都不會有任何地方報錯：

- 一般 agent 照樣被擋。放寬的是「Supervisor 這個身分」，不是「agent 憑證」
- **run 不能當 Supervisor**。它能當的話，run 派 run 派 run 就成立了，而沒有
  人在那個迴圈裡——遞迴的口堵在設定端，不是在派工端數深度
- 配額算在**指定它的那個人類**頭上。獨立配額池等於給 agent 一個不受人類
  每日上限牽制的派工池，agent 誤判時沒有任何東西會先耗盡
"""

from contextlib import asynccontextmanager

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"


def _clients(tmp_path, name, **cfg_kw):
    """人類憑證與 agent 憑證各一把，**指向同一個 app**。

    兩把分開才驗得到「Supervisor 走的是 agent 憑證」：共用一把的話，
    `_is_human_credential` 在沒設 `CHATROOM_HUMAN_TOKEN` 時一律 True，
    這份檔案的每一條都會因為憑證那一關沒觸發而假綠。
    """
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 human_api_token=HUMAN, **cfg_kw)
    app = create_app(cfg)

    def _c(token):
        client = AsyncClient(transport=ASGITransport(app=app),
                             base_url="http://test",
                             headers={"Authorization": f"Bearer {token}"})
        # `_bind_workspace` 要拿得到 db；換成各個呼叫點多傳一個 app 的話，
        # 漏掉一處的症狀是一條跟工作區無關的測試跑出 409
        client.hub_app = app
        return client

    return app, _c(HUMAN), _c(ROOT)


async def _bind_workspace(client, rid, workspace="ai-website"):
    # 工作房要先綁工作區才派得了工（Hub 契約）。這裡直接寫欄位而不走
    # `POST /api/rooms/{id}/workspace`：那個端點要求綁定當下已經有執行器
    # 服務這個 key，而這些測試多半是先建房、後註冊執行器。綁定端點本身的
    # 契約在 tests/test_room_workspace.py
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET workspace_key=? WHERE id=?",
                     (workspace, rid))
    await db.commit()


async def _ops_room(client, key="human-a", workspace="ai-website"):
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
            "X-Session-Key": key}, r.json()


class _Runner(str):
    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _register_runner(client, projects=("ai-website",)):
    r = await client.post("/api/runners/register",
                          json={"host": "esvel-pc", "label": "ex1",
                                "projects": list(projects),
                                "max_parallel": 3, "version": "0.1"})
    assert r.status_code == 200, r.text
    runner = _Runner(r.json()["runner"]["id"])
    runner.token = r.json()["runner_token"]
    return runner


async def _set_supervisor(client, rid, owner, session_key=None,
                          participant_id=None):
    body = {}
    if session_key is not None:
        body["session_key"] = session_key
    if participant_id is not None:
        body["participant_id"] = participant_id
    return await client.post(f"/api/rooms/{rid}/board/supervisor",
                             json=body, headers=owner)


def _run(kind="investigate", ref="task-1", project="ai-website"):
    return {"kind": kind, "project": project, "ref": ref, "brief": "查一下"}


async def _messages(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}/messages", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["messages"]


@asynccontextmanager
async def _setup(tmp_path, name, **cfg_kw):
    """一間 ops 房、一個人類房主、一台執行器、一個被指定的 Supervisor。

    ⚠️ **lifespan 要先進**：`app.state.db` 是在那裡掛上去的，先發請求的話
    每一條都會炸在 `'State' object has no attribute 'db'`，而那與「這條測試
    本來就該 403」長得完全不一樣，卻同樣是紅的。
    """
    app, human, agent = _clients(tmp_path, name, **cfg_kw)
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            owner = await _join_human(human, rid)
            runner = await _register_runner(agent)
            sup, _ = await _join_agent(agent, rid, "claude-sup", "諾薇亞")
            r = await _set_supervisor(human, rid, owner,
                                      session_key="claude-sup")
            assert r.status_code == 200, r.text
            yield human, agent, rid, owner, sup, runner


# ── 身分閘 ──────────────────────────────────────────────────────────

async def test_a_plain_agent_still_cannot_dispatch(tmp_path):
    """放寬的是 Supervisor 這個身分，不是 agent 憑證。"""
    app, human, agent = _clients(tmp_path, "plainagent")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            await _join_human(human, rid)
            await _register_runner(agent)
            hdr, _ = await _join_agent(agent, rid, "claude-nobody", "路人")
            r = await agent.post(f"/api/rooms/{rid}/runs", json=_run(),
                                 headers=hdr)
            assert r.status_code == 403, r.text
            # 憑證那一關先擋下來（它拿的是 agent token）。Supervisor 那條路
            # 是在憑證之前先問的，所以「問過了、不是 Supervisor」才會落到
            # 這裡——兩層都拆掉的話，這一條會 200
            assert r.json()["detail"]["code"] == "human_token_required_for_run"


@pytest.mark.parametrize("kind", ["investigate", "ticket", "stage"])
async def test_the_supervisor_can_dispatch_the_three_model_templates(
        tmp_path, kind):
    """三種走模型的模板都開放給 Supervisor。"""
    async with _setup(tmp_path, f"dispatch-{kind}") as (human, agent, rid, owner, sup, runner):
        r = await agent.post(f"/api/rooms/{rid}/runs",
                             json=_run(kind=kind, ref=f"ref-{kind}"),
                             headers=sup)
        assert r.status_code == 200, r.text
        run = r.json()["run"]
        assert run["status"] == "queued"
        assert run["kind"] == kind
        # 誰動的手與配額算誰的是兩欄，Supervisor 代派時兩者不同
        assert run["requester_kind"] == "agent"
        assert run["requester_name"] == "諾薇亞"
        assert run["requested_by_name"] == "艾斯維爾"


async def test_the_supervisor_cannot_dispatch_push(tmp_path):
    """push 是不經模型的固定腳本，那顆鈕留給人類。"""
    async with _setup(tmp_path, "nopush") as (human, agent, rid, owner, sup, runner):
        r = await agent.post(f"/api/rooms/{rid}/runs",
                             json=_run(kind="push", ref="ai-website"),
                             headers=sup)
        assert r.status_code == 403, r.text
        assert (r.json()["detail"]["code"]
                == "kind_not_allowed_for_supervisor")
        # 同一筆由人類來派就過得了——證明擋的是身分不是這個 kind 本身
        assert (await human.post(
            f"/api/rooms/{rid}/runs",
            json=_run(kind="push", ref="ai-website"),
            headers=owner)).status_code == 200


async def test_a_departed_supervisor_can_no_longer_dispatch(tmp_path):
    """離場之後這條路就關上——`_is_board_supervisor` 把離場排除在外。

    走了就不算（`board_supervisor_left_at` 有值），直到他回來為止——見下面
    那一條。
    """
    async with _setup(tmp_path, "departed") as (human, agent, rid, owner, sup, runner):
        await agent.post(f"/api/rooms/{rid}/leave", headers=sup)
        # 還沒回來，但要有一個活著的 participant 才走得到身分閘那一關
        other, _ = await _join_agent(agent, rid, "claude-other", "路人")
        r = await agent.post(f"/api/rooms/{rid}/runs",
                             json=_run(ref="after-left"), headers=other)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_token_required_for_run"


async def test_a_supervisor_who_came_back_can_dispatch_again(tmp_path):
    """回來了資格就回來——房裡已經公告過「監督者回來了」。

    回房那條路把 `board_supervisor_left_at` 清成空字串、資格判準問的卻是
    `IS NULL` 的話，這一條會 403，而畫面上同時寫著他在。
    """
    async with _setup(tmp_path, "returned") as (human, agent, rid, owner, sup, runner):
        await agent.post(f"/api/rooms/{rid}/leave", headers=sup)
        back, _ = await _join_agent(agent, rid, "claude-sup", "諾薇亞")
        r = await agent.post(f"/api/rooms/{rid}/runs",
                             json=_run(ref="after-return"), headers=back)
        assert r.status_code == 200, r.text
        assert r.json()["run"]["requester_kind"] == "agent"


# ── run 不能當 Supervisor ────────────────────────────────────────────

async def _running_run(client, rid, hdr, runner, ref="task-seed"):
    run_id = (await client.post(f"/api/rooms/{rid}/runs",
                                json=_run(ref=ref),
                                headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    r = await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "running", "runner_id": runner},
                          headers=runner.headers)
    assert r.status_code == 200, r.text
    return run_id


@pytest.mark.parametrize("by", ["session_key", "participant_id"])
async def test_a_run_member_cannot_be_made_supervisor(tmp_path, by):
    """兩條指定路徑都要擋——只擋一條，另一條就是完整的遞迴入口。"""
    app, human, agent = _clients(tmp_path, f"norun-{by}")
    async with human, agent:
        async with app.router.lifespan_context(app):
            rid = await _ops_room(human)
            owner = await _join_human(human, rid)
            runner = await _register_runner(agent)
            run_id = await _running_run(human, rid, owner, runner)
            key = f"claude-run-{run_id}"
            _, body = await _join_agent(agent, rid, key, "臨時工")
            kw = ({"session_key": key} if by == "session_key"
                  else {"participant_id": body["participant_id"]})
            r = await _set_supervisor(human, rid, owner, **kw)
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["code"] == "supervisor_cannot_be_run"
            # 真的沒設進去：擋了卻寫了的話，下一次呼叫就照樣放行
            board = (await human.get(f"/api/rooms/{rid}/board",
                                     headers=owner)).json()
            assert not (board["supervisor"] or {}).get("session_key")


# ── 配額歸屬 ────────────────────────────────────────────────────────

async def test_the_quota_is_charged_to_the_human_who_appointed_him(tmp_path):
    """Supervisor 代派吃掉的是**指定它的那個人類**的每日額度。

    算在 agent 自己頭上的話，人類的儀表板上看不到今天被派了幾筆，而那是
    唯一能讓濫用自然止血的地方。
    """
    async with _setup(tmp_path, "quota", run_daily_quota=1) as (human, agent, rid, owner, sup, runner):
        r = await agent.post(f"/api/rooms/{rid}/runs",
                             json=_run(ref="sup-1"), headers=sup)
        assert r.status_code == 200, r.text
        assert r.json()["run"]["requested_by_name"] == "艾斯維爾"
        # 人類自己再派一筆——額度已經被 Supervisor 那一筆用掉了
        r = await human.post(f"/api/rooms/{rid}/runs",
                             json=_run(ref="human-1"), headers=owner)
        assert r.status_code == 429, r.text
        assert r.json()["detail"]["code"] == "run_daily_quota_exceeded"


# ── 可觀測 ──────────────────────────────────────────────────────────

async def test_the_room_message_says_who_dispatched_it(tmp_path):
    """房內看到的是「派工 X 完成」，而那一筆可能根本不是人類按的。"""
    async with _setup(tmp_path, "announce") as (human, agent, rid, owner, sup, runner):
        run_id = (await agent.post(f"/api/rooms/{rid}/runs",
                                   json=_run(ref="say-who"),
                                   headers=sup)).json()["run"]["id"]
        await agent.post(f"/api/runners/{runner}/claim",
                         headers=runner.headers)
        await agent.post(f"/api/runs/{run_id}/report",
                         json={"status": "running", "runner_id": runner},
                         headers=runner.headers)
        msgs = await _messages(human, rid, owner)
        started = [m for m in msgs if m["system_event"] == "run_running"]
        assert started, "開始執行那則訊息不見了，這條測試等於沒驗"
        assert "由 Supervisor 諾薇亞 派工" in started[-1]["content"]


async def test_a_human_dispatch_is_not_labelled_as_supervisor(tmp_path):
    """對照組：人類派的不能被貼上「由 Supervisor 派工」。"""
    async with _setup(tmp_path, "noannounce") as (human, agent, rid, owner, sup, runner):
        run_id = (await human.post(f"/api/rooms/{rid}/runs",
                                   json=_run(ref="by-human"),
                                   headers=owner)).json()["run"]["id"]
        await agent.post(f"/api/runners/{runner}/claim",
                         headers=runner.headers)
        await agent.post(f"/api/runs/{run_id}/report",
                         json={"status": "running", "runner_id": runner},
                         headers=runner.headers)
        msgs = await _messages(human, rid, owner)
        started = [m for m in msgs if m["system_event"] == "run_running"]
        assert started
        assert "Supervisor" not in started[-1]["content"]


async def test_leaving_supervisor_leaves_a_reminder_about_queued_runs(tmp_path):
    """離場不取消它派過的 run——但也不能安靜地留著。

    那幾筆會照常被領走、照常跑，而當初決定要派它們的那個身分已經不在房裡。
    """
    async with _setup(tmp_path, "leftruns") as (human, agent, rid, owner, sup, runner):
        run_id = (await agent.post(f"/api/rooms/{rid}/runs",
                                   json=_run(ref="left-behind"),
                                   headers=sup)).json()["run"]["id"]
        await agent.post(f"/api/rooms/{rid}/leave", headers=sup)
        msgs = await _messages(human, rid, owner)
        notes = [m for m in msgs
                 if m["system_event"] == "board_supervisor_left_runs"]
        assert notes, "離場提醒不見了"
        assert "1 筆" in notes[-1]["content"]
        assert "艾斯維爾" in (notes[-1]["mentions"] or [])
        # **不自動取消**：取消只有人類或主持人下得了（§6.1）
        run = (await human.get(f"/api/runs/{run_id}",
                               headers=owner)).json()["run"]
        assert run["status"] == "queued"


async def test_no_reminder_when_the_supervisor_left_nothing_queued(tmp_path):
    """沒有待排就不發第二則——每次離場都喊一句，真的有事時沒人在看。"""
    async with _setup(tmp_path, "quietleft") as (human, agent, rid, owner, sup, runner):
        await agent.post(f"/api/rooms/{rid}/leave", headers=sup)
        msgs = await _messages(human, rid, owner)
        assert [m for m in msgs
                if m["system_event"] == "board_supervisor_left"]
        assert not [m for m in msgs
                    if m["system_event"] == "board_supervisor_left_runs"]


async def test_a_handoff_child_keeps_the_supervisor_as_its_requester(tmp_path):
    """交接是同一份工作的接力，派工者身分整組跟著走。

    不繼承的話，Supervisor 派的工作一交接就變成「人類派的」，房內訊息與
    稽核串從第二棒起都在說錯話——而每一棒看起來都完全正常。
    """
    async with _setup(tmp_path, "handoff") as (human, agent, rid, owner, sup, runner):
        run_id = (await agent.post(f"/api/rooms/{rid}/runs",
                                   json=_run(ref="relay"),
                                   headers=sup)).json()["run"]["id"]
        await agent.post(f"/api/runners/{runner}/claim", headers=runner.headers)
        await agent.post(f"/api/runs/{run_id}/report",
                         json={"status": "running", "runner_id": runner},
                         headers=runner.headers)
        r = await agent.post(f"/api/runs/{run_id}/report",
                             json={"status": "handoff", "runner_id": runner,
                                   "result": "做到一半"},
                             headers=runner.headers)
        assert r.status_code == 200, r.text
        child = r.json()["child_run"]
        assert child is not None, "沒有建下一棒，這條測試等於沒驗"
        assert child["requester_kind"] == "agent"
        assert child["requester_name"] == "諾薇亞"
