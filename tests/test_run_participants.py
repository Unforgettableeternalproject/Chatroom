"""派工（run）帶進來的成員：進得來，也要走得掉，而且不留在名單上。

工作房是**常駐**的（`kind=ops` 永不自動封存），而每一筆 run 都是一個新身分
——`claude-run-<run_id>`。這兩件事合起來就是這份檔案守的東西：

- run 結束而成員還 active：成員列上多一個永遠不動的名字，房裡的人會以為
  那一輪還在跑；他領的卡也永遠顯示「有人在做」。
- run 成員留在「已離開」：那份名單會隨派工次數無限變長，而沒有任何一列對
  讀的人有意義——他要的是稽核串，不是一排用過即丟的名字。
- 一般成員被一起清掉：那是**反過來的錯**，而且是靜默的——他離開過這間房
  是事實，名單上不該沒有他。
"""

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


async def _ops_room(client, key="human-a"):
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": key})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _join_human(client, rid, key="human-a", name="艾斯維爾"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _join_agent(client, rid, key, name):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "claude", "role": "agent",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"]}, r.json()


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


async def _dispatch_running(client, rid, hdr, runner, ref="task-1"):
    """派一筆並把它推到 running：run 成員是在這之後才進房的。"""
    run_id = (await client.post(
        f"/api/rooms/{rid}/runs",
        json={"kind": "investigate", "project": "ai-website", "ref": ref,
              "brief": "查一下"}, headers=hdr)).json()["run"]["id"]
    await client.post(f"/api/runners/{runner}/claim", headers=runner.headers)
    r = await client.post(f"/api/runs/{run_id}/report",
                          json={"status": "running", "runner_id": runner},
                          headers=runner.headers)
    assert r.status_code == 200, r.text
    return run_id


async def _report(client, run_id, runner, status, **extra):
    r = await client.post(f"/api/runs/{run_id}/report",
                          json={"status": status, "runner_id": runner, **extra},
                          headers=runner.headers)
    assert r.status_code == 200, r.text
    return r.json()


async def _participants(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["participants"]


async def _row(app, pid):
    return await (await app.state.db.execute(
        "SELECT * FROM participant WHERE id=?", (pid,))).fetchone()


# ── 辨識 ─────────────────────────────────────────────────────────────

async def test_a_run_session_key_is_recorded_as_a_run_member(tmp_path):
    """`claude-run-<run_id>` 對得上這間房的 run ⇒ 成員身上留下那筆 run。

    不留的話，run 結束時沒有任何一條路說得出「該把誰請出去」——而漏掉的
    症狀是安靜的：名單上多一個永遠不動的名字。
    """
    app, client = await _client(tmp_path, "tag")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        assert (await _row(app, body["participant_id"]))["run_id"] == run_id


async def test_a_lookalike_session_key_is_just_an_ordinary_member(tmp_path):
    """前綴只是一串字，任何人都打得出來。**對不上就當一般成員，不報錯。**

    反過來（加入失敗）會把一個只是名字長得像的 agent 擋在門外；當成 run
    成員則更糟——他會在下一筆 run 結束時被請出房間，而他什麼都沒做。
    """
    app, client = await _client(tmp_path, "lookalike")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        await _join_human(client, rid)
        _, body = await _join_agent(client, rid, "claude-run-不存在的", "假冒")
        assert (await _row(app, body["participant_id"]))["run_id"] == ""


async def test_a_run_from_another_room_does_not_count(tmp_path):
    """run id 是真的，但那筆 run 在別間房。

    只查「這個 id 存在嗎」的話，A 房的 run 結束會把 B 房的成員掃出去——
    兩間房各自看起來都沒有錯，而那個人就這樣從 B 房消失了。
    """
    app, client = await _client(tmp_path, "crossroom")
    async with app.router.lifespan_context(app), client:
        other = await _ops_room(client)
        hdr = await _join_human(client, other)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, other, hdr, runner)

        rid = await _ops_room(client)
        await _join_human(client, rid)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "串門子")
        assert (await _row(app, body["participant_id"]))["run_id"] == ""


# ── 收場即離房 ───────────────────────────────────────────────────────

@pytest.mark.parametrize("final_status", ["done", "failed", "cancelled"])
async def test_a_finished_run_takes_its_member_out_of_the_room(
        tmp_path, final_status):
    """收場的每一個狀態都要離房——只接 done 的話，失敗的那幾輪會全留下來。"""
    app, client = await _client(tmp_path, f"end-{final_status}")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        pid = body["participant_id"]
        assert any(p["id"] == pid for p in await _participants(client, rid, hdr))

        await _report(client, run_id, runner, final_status)

        assert (await _row(app, pid))["status"] == "left"
        names = [p["display_name"] for p in await _participants(client, rid, hdr)]
        assert "Runner" not in names, (
            "run 成員留在名冊上——工作房常駐，這份名單會無限變長")


async def test_the_departure_does_not_add_a_second_system_message(tmp_path):
    """run 結束本來就公告一則。再補一則「某某離開了」是同一件事講兩遍。"""
    app, client = await _client(tmp_path, "quiet")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        await _report(client, run_id, runner, "done")

        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=hdr)).json()["messages"]
        assert not [m for m in msgs
                    if m.get("system_event") == "leave"], (
            "離場另發了系統訊息，時間軸上會與 run 結束的公告永遠成對出現")


async def test_an_ordinary_member_who_left_is_still_listed(tmp_path):
    """反過來的錯也要擋：一般成員離開是**事實**，名單上不該沒有他。"""
    app, client = await _client(tmp_path, "ordinary")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        plain, plain_body = await _join_agent(client, rid, "codex-main", "米絲媞")
        await client.post(f"/api/rooms/{rid}/leave", headers=plain)

        await _report(client, run_id, runner, "done")

        listed = await _participants(client, rid, hdr)
        mine = [p for p in listed if p["id"] == plain_body["participant_id"]]
        assert mine and mine[0]["status"] == "left"
        assert "Runner" not in [p["display_name"] for p in listed]


async def test_the_run_member_is_listed_while_the_run_is_still_running(tmp_path):
    """還在跑的那一個要看得見——房裡的人正是靠它知道誰在動這間房的工作樹。"""
    app, client = await _client(tmp_path, "visible")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        listed = await _participants(client, rid, hdr)
        assert "Runner" in [p["display_name"] for p in listed]


async def test_a_subagent_of_the_run_member_goes_with_it(tmp_path):
    """run 的 agent 也派得出 subagent。父層走了它們要跟著走。

    只寫一句 UPDATE 打自己那一列的話，子代理會留在房裡——而它連父層都沒有
    了，`ephemeral` 的 TTL 是它唯一的出路。
    """
    app, client = await _client(tmp_path, "subagent")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        parent_key = f"claude-run-{run_id}"
        _, parent = await _join_agent(client, rid, parent_key, "Runner")
        r = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent",
            "session_key": f"{parent_key}#sub-1",
            "preferred_name": "worker",
            "parent_participant_id": parent["participant_id"]})
        assert r.status_code == 200, r.text
        sub_id = r.json()["participant_id"]

        await _report(client, run_id, runner, "done")

        assert (await _row(app, parent["participant_id"]))["status"] == "left"
        assert (await _row(app, sub_id))["status"] == "left"


# ── handoff：卡要空出來給下一棒 ──────────────────────────────────────

async def _board_task(client, rid, hdr):
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Hub 端"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "接端點"}, headers=hdr)).json()["id"]
    board_id = (await client.get(f"/api/rooms/{rid}/board",
                                 headers={"X-Host-View": "1"})).json()["board_id"]
    return board_id, tid


async def _add_to_board(client, board_id, actor_key, owner_key="human-a"):
    r = await client.post(f"/api/boards/{board_id}/members",
                          json={"actor_key": actor_key, "role": "editor"},
                          headers={"X-Session-Key": owner_key})
    assert r.status_code in (200, 409), r.text


async def _task_row(client, rid, tid):
    board = (await client.get(f"/api/rooms/{rid}/board",
                              headers={"X-Host-View": "1"})).json()
    return next(t for t in board["tasks"] if t["id"] == tid)


async def test_handoff_frees_the_card_for_the_child_run(tmp_path):
    """交接也是收場：這一棒的身分到此為止，卡由子 run 重新認領（§5.4）。

    不離房的話，`_orphan_claims` 的條件（持有者已不在房內）永遠不成立——
    那張卡會一直顯示上一棒在做，而下一棒認領時撞 409。
    """
    app, client = await _client(tmp_path, "handoff")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        board_id, tid = await _board_task(client, rid, hdr)
        run_id = await _dispatch_running(client, rid, hdr, runner, ref=tid)

        first_key = f"claude-run-{run_id}"
        first, first_body = await _join_agent(client, rid, first_key, "一棒")
        await _add_to_board(client, board_id, first_key)
        assert (await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers=first)).status_code == 200

        body = await _report(client, run_id, runner, "handoff", reason="context")
        child_id = body["child_run"]["id"]
        assert child_id

        assert (await _row(app, first_body["participant_id"]))["status"] == "left"
        assert "一棒" not in [p["display_name"]
                             for p in await _participants(client, rid, hdr)]
        assert (await _task_row(client, rid, tid))["claim_state"] == "orphaned"

        # 下一棒真的領得走——「孤兒化了」本身不是驗收，接手成功才是
        child_key = f"claude-run-{child_id}"
        second, _ = await _join_agent(client, rid, child_key, "二棒")
        await _add_to_board(client, board_id, child_key)
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=second)
        assert r.status_code == 200, r.text
        assert (await _task_row(client, rid, tid))["claim_name"] == "二棒"


async def test_the_capped_handoff_also_sends_its_member_home(tmp_path):
    """交接鏈撞上限那一條是**另一個 return**，很容易漏掉。

    漏了的症狀最難查：只有交接到上限的那幾輪會留下成員，而那是罕見路徑。
    """
    app, client = await _client(tmp_path, "capped", run_handoff_max=0)
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "末棒")

        out = await _report(client, run_id, runner, "handoff")
        assert out["child_run"] is None
        assert out["run"]["status"] == "failed"
        assert (await _row(app, body["participant_id"]))["status"] == "left"
        assert "末棒" not in [p["display_name"]
                             for p in await _participants(client, rid, hdr)]
