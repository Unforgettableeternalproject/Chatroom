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
from chatroom_server.naming import all_names
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    # `_bind_workspace` 要拿得到 db；換成各個呼叫點多傳一個 app 的話，
    # 漏掉一處的症狀是一條跟工作區無關的測試跑出 409
    client.hub_app = app
    return app, client


async def _bind_workspace(client, rid, workspace="ai-website"):
    # 工作房要先綁工作區才派得了工（Hub 契約）。這裡直接寫欄位而不走
    # `POST /api/rooms/{id}/workspace`：那個端點要求綁定當下已經有執行器
    # 服務這個 key，而這些測試多半是先建房、後註冊執行器。綁定端點本身的
    # 契約在 tests/test_room_workspace.py
    db = client.hub_app.state.db
    await db.execute("UPDATE room SET workspace_key=? WHERE id=?",
                     (workspace, rid))
    await db.commit()


async def _ops_room(client, key="human-a", workspace="ai-website",
                    visibility="public"):
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": key,
                                              "visibility": visibility})
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


# ── 命名 ─────────────────────────────────────────────────────────────

async def test_a_run_member_gets_a_pool_name_not_its_own(tmp_path):
    """run 自報的名字**不採用**：那個位置送過來的一直是編號或模板名。

    實測進房的名字是 `Runner-01ad9f1e`（執行器塞的 `<label>-<run 短碼>`）與
    `Minka-Ticket`（模型自己編的），成員列讀起來就是一串 id。run 的識別在
    `participant.run_id` 上，名字該是名字。
    """
    # 斷言的是英文 Adjective-Noun 池，語言要說死，不吃 Hub 預設的 zh-TW
    app, client = await _client(tmp_path, "poolname", locale="en")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}",
                                    f"Runner-{run_id[:8]}")
        name = body["display_name"]
        assert name != f"Runner-{run_id[:8]}"
        assert run_id[:8] not in name and run_id not in name
        # 名字來自英文名字池（預製名單或「形容詞-名詞」組合）
        assert name in all_names("en"), name
        # 識別沒有因此消失
        assert (await _row(app, body["participant_id"]))["run_id"] == run_id


async def test_a_lookalike_keeps_its_self_reported_name(tmp_path):
    """特例只套在**真的對得上**的 run 上。

    綁在前綴上的話，任何自己打得出 `claude-run-` 的 agent 都會被沒收名字。
    """
    app, client = await _client(tmp_path, "poolname-lookalike")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        await _join_human(client, rid)
        _, body = await _join_agent(client, rid, "claude-run-不存在的", "假冒")
        assert body["display_name"] == "假冒"


async def test_an_assigned_name_still_wins_for_a_run(tmp_path):
    """指派者取的名字仍然優先——那是人挑的名字，不是自動生成的編號。"""
    app, client = await _client(tmp_path, "poolname-assigned")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        r = await client.post(
            f"/api/rooms/{rid}/assignments",
            json={"target_session_key": f"claude-run-{run_id}",
                  "assigned_name": "鐵衛", "note": "去做"},
            headers=hdr)
        assert r.status_code == 200, r.text
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}",
                                    f"Runner-{run_id[:8]}")
        assert body["display_name"] == "鐵衛"


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
        ids = [p["id"] for p in await _participants(client, rid, hdr)]
        assert pid not in ids, (
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
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        listed = await _participants(client, rid, hdr)
        assert body["participant_id"] in [p["id"] for p in listed]


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
        assert first_body["participant_id"] not in [
            p["id"] for p in await _participants(client, rid, hdr)]
        assert (await _task_row(client, rid, tid))["claim_state"] == "orphaned"

        # 下一棒真的領得走——「孤兒化了」本身不是驗收，接手成功才是
        child_key = f"claude-run-{child_id}"
        second, second_body = await _join_agent(client, rid, child_key, "二棒")
        await _add_to_board(client, board_id, child_key)
        r = await client.post(f"/api/board/tasks/{tid}/claim", headers=second)
        assert r.status_code == 200, r.text
        # 名字由 Hub 發，拿 join 回來的那個比對，不是自報的「二棒」
        assert (await _task_row(client, rid, tid))["claim_name"] ==             second_body["display_name"]


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
        assert body["participant_id"] not in [
            p["id"] for p in await _participants(client, rid, hdr)]


# ── hold 與成員列表 ──────────────────────────────────────────────────

async def _set_hold(app, pid, value):
    await app.state.db.execute(
        "UPDATE participant SET hold_until=? WHERE id=?", (value, pid))
    await app.state.db.commit()


async def test_a_run_member_holds_from_the_moment_it_joins(tmp_path):
    """run 帶進來的身分一進房就有 hold。

    掃描本來就豁免它（run 還在跑），但 `hold_until` 是**對外那一半**：
    App 的成員列讀的是這一欄，沒有它就照樣印「最快 N 分後移出」——一個
    不會發生的倒數，而使用者會以為 hold 沒生效。
    """
    app, client = await _client(tmp_path, "hold-join")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        assert (await _row(app, body["participant_id"]))["hold_until"]
        # 一般成員不受影響：他該照常被閒置掃描看見
        _, plain = await _join_agent(client, rid, "codex-main", "米絲媞")
        assert not (await _row(app, plain["participant_id"]))["hold_until"]


async def test_the_runner_heartbeat_extends_the_hold(tmp_path):
    """心跳＝這台手上的 run 還在跑，hold 要跟著往前推。

    `hold_max` 是有上限的（掛著 hold 就 crash 的 agent 不能永遠掃不掉），
    所以長時間的 run 一定會走到過期那一刻——不續期的話，畫面在那之後又
    開始倒數。
    """
    app, client = await _client(tmp_path, "hold-hb")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        pid = body["participant_id"]
        await _set_hold(app, pid, "2020-01-01T00:00:00+00:00")
        r = await client.post(f"/api/runners/{runner}/heartbeat",
                              json={"status": "online", "running_count": 1},
                              headers=runner.headers)
        assert r.status_code == 200, r.text
        assert (await _row(app, pid))["hold_until"] > "2021-01-01"


async def test_a_run_report_extends_the_hold(tmp_path):
    """回報也是「這一輪還在」的證據——執行器可能只回報、不心跳。"""
    app, client = await _client(tmp_path, "hold-report")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        pid = body["participant_id"]
        await _set_hold(app, pid, "2020-01-01T00:00:00+00:00")
        await _report(client, run_id, runner, "running", reason="stalled",
                      stalled_seconds=90)
        assert (await _row(app, pid))["hold_until"] > "2021-01-01"


async def test_the_member_list_says_which_run_a_member_belongs_to(tmp_path):
    """成員列表要帶 `run_id`：空字串＝一般成員。

    App 靠它把那一列標成「派工中」。沒有這個欄位，client 只能拿
    `last_seen` 自己算倒數，而那個倒數對 run 成員永遠不會發生。
    """
    app, client = await _client(tmp_path, "list-run-id")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        listed = {p["id"]: p for p in await _participants(client, rid, hdr)}
        assert listed[body["participant_id"]]["run_id"] == run_id
        listed = {p["display_name"]: p for p in listed.values()}
        assert listed["艾斯維爾"]["run_id"] == ""


# ── 回報卡的標題 ──────────────────────────────────────────────────────

async def _run_body(client, run_id, hdr):
    r = await client.get(f"/api/runs/{run_id}", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["run"]


async def test_a_run_carries_the_name_of_the_agent_that_joined(tmp_path):
    """run 的回應要答得出「這一輪是誰做的」。

    沒有這一欄，回報卡只剩下 run id 可以當標題——而那串 32 碼對讀的人沒有
    任何意義，房裡講話的是 `Amber-Badger`，卡上寫的是 `5e61ec64…`。
    """
    app, client = await _client(tmp_path, "agent-name")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        name = body["display_name"]

        assert (await _run_body(client, run_id, hdr))["agent_name"] == name
        listing = (await client.get(f"/api/rooms/{rid}/runs",
                                    headers=hdr)).json()["runs"]
        assert [r["agent_name"] for r in listing] == [name]


async def test_the_name_survives_the_run_ending(tmp_path):
    """成員離場之後還要答得出來——回報卡是**做完之後**才在看的。

    跟著 `status='active'` 濾的話，卡片會在那一輪結束的瞬間把標題換回 id。
    """
    app, client = await _client(tmp_path, "agent-name-ended")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        name = body["display_name"]
        await _report(client, run_id, runner, "done", result="做完了")

        assert (await _row(app, body["participant_id"]))["status"] == "left"
        assert (await _run_body(client, run_id, hdr))["agent_name"] == name


async def test_a_run_with_nobody_in_the_room_yet_has_no_name(tmp_path):
    """排隊中的 run 沒有 agent_name——那是「還沒有人」，不是沒名字。

    退回空字串的話，App 分不出「還沒進房」與「Hub 沒講」。
    """
    app, client = await _client(tmp_path, "agent-name-queued")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client)
        r = await client.post(
            f"/api/rooms/{rid}/runs",
            json={"kind": "investigate", "project": "ai-website",
                  "ref": "T-1", "brief": "等一下"}, headers=hdr)
        assert r.status_code == 200, r.text
        run_id = r.json()["run"]["id"]
        assert (await _run_body(client, run_id, hdr))["agent_name"] is None


async def test_a_subagent_does_not_take_over_the_title(tmp_path):
    """子代理與父層共用同一個 `run_id`，但卡上要寫的是領這一輪的人。

    不濾 `parent_id` 的話，標題會在子代理進房的那一刻換成別人的名字。
    """
    app, client = await _client(tmp_path, "agent-name-sub")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        _, body = await _join_agent(client, rid, f"claude-run-{run_id}", "Runner")
        parent_id, name = body["participant_id"], body["display_name"]

        _, sub = await _join_agent(client, rid, "claude-sub", "子代理")
        # 直接改欄位：這裡要驗的是查詢的濾法，不是 spawn 的那條路徑
        await app.state.db.execute(
            "UPDATE participant SET run_id=?, parent_id=?,"
            " joined_at='2000-01-01T00:00:00+00:00' WHERE id=?",
            (run_id, parent_id, sub["participant_id"]))
        await app.state.db.commit()

        assert (await _run_body(client, run_id, hdr))["agent_name"] == name


# ── 私人工作房 ───────────────────────────────────────────────────────

async def _try_join(client, rid, key, name="Runner"):
    return await client.post(f"/api/rooms/{rid}/join",
                             json={"kind": "claude", "role": "agent",
                                   "session_key": key, "preferred_name": name})


async def test_a_run_can_enter_the_private_room_that_dispatched_it(tmp_path):
    """私人工作房派出去的 run 進得來——房主派工那一刻就是邀請。

    擋掉的話，私人房派得出工卻收不到回報：那個 run 一路跑完，房裡的人
    只看得到一張永遠停在 running 的卡。
    """
    app, client = await _client(tmp_path, "private-run")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, visibility="private")
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)

        r = await _try_join(client, rid, f"claude-run-{run_id}")
        assert r.status_code == 200, r.text
        assert (await _row(app, r.json()["participant_id"]))["run_id"] == run_id


async def test_a_run_from_another_room_still_cannot_enter(tmp_path):
    """豁免只給**這間房自己派出去的** run。

    前綴誰都打得出來；只認前綴的話，一個真實的 run id 就是任何私人房的鑰匙。
    """
    app, client = await _client(tmp_path, "private-run-crossroom")
    async with app.router.lifespan_context(app), client:
        other = await _ops_room(client)
        hdr = await _join_human(client, other)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, other, hdr, runner)

        rid = await _ops_room(client, key="human-b", visibility="private")
        r = await _try_join(client, rid, f"claude-run-{run_id}")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "room_is_private"


async def test_a_finished_run_cannot_enter_the_private_room(tmp_path):
    """收場的 run 不再是這間房派出去的人。

    豁免綁在「還在跑」上；已結束還放行，等於那把 key 永久有效。
    """
    app, client = await _client(tmp_path, "private-run-done")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, visibility="private")
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)
        run_id = await _dispatch_running(client, rid, hdr, runner)
        await _report(client, run_id, runner, "done", summary="做完了")

        r = await _try_join(client, rid, f"claude-run-{run_id}")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "room_is_private"


async def test_a_queued_run_cannot_enter_the_private_room_yet(tmp_path):
    """排隊中的 run 還沒有人認領，也就還沒有那個子進程。"""
    app, client = await _client(tmp_path, "private-run-queued")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, visibility="private")
        hdr = await _join_human(client, rid)
        await _register_runner(client)
        run_id = (await client.post(
            f"/api/rooms/{rid}/runs",
            json={"kind": "investigate", "project": "ai-website",
                  "ref": "T-9", "brief": "等一下"},
            headers=hdr)).json()["run"]["id"]

        r = await _try_join(client, rid, f"claude-run-{run_id}")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "room_is_private"


async def test_an_ordinary_agent_still_needs_an_invitation(tmp_path):
    """私人房對一般 agent 的門沒有因此變鬆。"""
    app, client = await _client(tmp_path, "private-run-ordinary")
    async with app.router.lifespan_context(app), client:
        rid = await _ops_room(client, visibility="private")
        await _join_human(client, rid)

        r = await _try_join(client, rid, "claude-someone", name="路人")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "room_is_private"
