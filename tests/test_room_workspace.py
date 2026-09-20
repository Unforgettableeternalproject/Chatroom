"""工作房綁定工作區（一次性）：`POST /api/rooms/{id}/workspace`。

綁定之前，一間 ops 房與「哪一份工作樹」沒有任何關係——面板只好把所有執行器
都列出來，而派工時填錯一個 project key，工作會落在別人的倉庫上。這份檔案守
的每一條都對應一個**安靜的失敗**：

- 綁定可以改：run 的稽核串橫跨兩份工作樹，回頭看分不出哪筆動的是哪邊
- 非房主綁得動：房裡任何一個 agent 都能決定整間房以後派到哪
- 綁一個沒人服務的 key：派出去的工排進一條永遠不會動的佇列
- 綁定不留訊息：房間的能力被改掉，而對話裡看不出發生過這件事
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = "human-a"
PROJECT = "ai-website"


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _room(client, kind="ops", key=OWNER, name="工作房",
                visibility="public"):
    r = await client.post("/api/rooms",
                          json={"name": name, "kind": kind,
                                "session_key": key,
                                "visibility": visibility})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _join_human(client, rid, key=OWNER, name="艾斯維爾"):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


class _Runner(str):
    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _register_runner(client, projects=(PROJECT,), label="ex1",
                           private_projects=None):
    body = {"host": "esvel-pc", "label": label, "projects": list(projects),
            "max_parallel": 3, "version": "0.1"}
    if private_projects is not None:
        # 舊執行器根本不帶這一欄，預設路徑要跟它一模一樣
        body["private_projects"] = list(private_projects)
    r = await client.post("/api/runners/register", json=body)
    assert r.status_code == 200, r.text
    runner = _Runner(r.json()["runner"]["id"])
    runner.token = r.json()["runner_token"]
    return runner


async def _bind(client, rid, key=PROJECT, session_key=OWNER):
    return await client.post(f"/api/rooms/{rid}/workspace",
                             json={"workspace_key": key},
                             headers={"X-Session-Key": session_key})


def _code(r) -> str:
    return r.json()["detail"]["code"]


async def _room_view(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["room"]


# ── 綁定 ─────────────────────────────────────────────────────────────

async def test_owner_binds_workspace_and_the_room_says_so(tmp_path):
    """綁定成功 ⇒ 回更新後的 room，而且房裡看得到一則系統訊息。

    只改欄位不留訊息的話，「這間房以後只能派 X 的工」是一個只存在於面板
    的事實——沒看面板的人會一直以為自己派得了別的專案。
    """
    app, client = await _client(tmp_path, "bind")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client)

        r = await _bind(client, rid)
        assert r.status_code == 200, r.text
        assert r.json()["room"]["workspace_key"] == PROJECT
        assert r.json()["room"]["workspace_served"] is True

        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=hdr)).json()["messages"]
        bound = [m for m in msgs if m["system_event"] == "workspace_bound"]
        assert len(bound) == 1, msgs
        assert bound[0]["content"] == (
            f"艾斯維爾 將這個房間綁定到工作區「{PROJECT}」")


async def test_binding_twice_is_refused(tmp_path):
    """一次性：第二次綁定回 409，且原本的 key 一個字都不會變。"""
    app, client = await _client(tmp_path, "rebind")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client, projects=(PROJECT, "u-e-p"))
        assert (await _bind(client, rid)).status_code == 200

        r = await _bind(client, rid, key="u-e-p")
        assert r.status_code == 409, r.text
        assert _code(r) == "workspace_already_bound"
        assert r.json()["detail"]["workspace_key"] == PROJECT
        assert (await _room_view(client, rid, hdr))["workspace_key"] == PROJECT


async def test_only_the_owner_can_bind(tmp_path):
    """房裡的其他人綁不動：那是「這間房以後派到哪」，不是成員的事。"""
    app, client = await _client(tmp_path, "notowner")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _join_human(client, rid, key="human-b", name="米絲媞")
        await _register_runner(client)

        r = await _bind(client, rid, session_key="human-b")
        assert r.status_code == 403, r.text
        assert _code(r) == "room_owner_required"
        assert (await _room_view(client, rid, hdr))["workspace_key"] is None


async def test_binding_an_unserved_key_is_refused(tmp_path):
    """沒有任何非 offline 的執行器宣告這個 key ⇒ 409，綁不進去。

    綁得進去的話，之後每一筆派工都會排進一條永遠不會動的佇列——而那在
    畫面上與「執行器待會就上線」長得一模一樣。
    """
    app, client = await _client(tmp_path, "unserved")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client, projects=("u-e-p",))

        r = await _bind(client, rid)
        assert r.status_code == 409, r.text
        assert _code(r) == "project_not_served"
        assert (await _room_view(client, rid, hdr))["workspace_key"] is None


async def test_chat_room_cannot_be_bound(tmp_path):
    """一般房沒有工作區可言 ⇒ 409 `room_not_ops`，與派工同一道判準。"""
    app, client = await _client(tmp_path, "chatbind")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, kind="chat", name="一般房")
        await _join_human(client, rid)
        await _register_runner(client)

        r = await _bind(client, rid)
        assert r.status_code == 409, r.text
        assert _code(r) == "room_not_ops"


# ── GET /api/rooms/{id} 的兩個欄位 ───────────────────────────────────

async def test_room_reports_workspace_key_and_whether_it_is_served(tmp_path):
    """三種狀態都要分得開：未綁定／綁了有人服務／綁了但執行器離線。

    只給 `workspace_key` 的話，最後一種在畫面上與第二種一樣——使用者按下
    派工，然後看著它排隊排到天亮。
    """
    app, client = await _client(tmp_path, "roomfields")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)

        before = await _room_view(client, rid, hdr)
        assert before["workspace_key"] is None
        assert before["workspace_served"] is False

        runner = await _register_runner(client)
        assert (await _bind(client, rid)).status_code == 200
        served = await _room_view(client, rid, hdr)
        assert served["workspace_key"] == PROJECT
        assert served["workspace_served"] is True

        await app.state.db.execute(
            "UPDATE runner SET status='offline' WHERE id=?", (str(runner),))
        await app.state.db.commit()
        gone = await _room_view(client, rid, hdr)
        assert gone["workspace_key"] == PROJECT, "綁定不該因為離線而消失"
        assert gone["workspace_served"] is False


# ── 執行儀表板 ───────────────────────────────────────────────────────

async def test_dashboard_is_empty_until_the_room_is_bound(tmp_path):
    """未綁定 ⇒ `runners: []`。這時候哪一台都還不相關。"""
    app, client = await _client(tmp_path, "dashunbound")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client)

        r = await client.get(f"/api/rooms/{rid}/runner", headers=hdr)
        assert r.status_code == 200, r.text
        assert r.json()["runners"] == []
        assert r.json()["workspace_key"] is None


async def test_dashboard_lists_only_runners_serving_the_workspace(tmp_path):
    """綁定後只列宣告了這個 key 的執行器，別人的機器不該出現在這裡。"""
    app, client = await _client(tmp_path, "dashbound")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        mine = await _register_runner(client, label="ex1")
        await _register_runner(client, projects=("u-e-p",), label="ex2")
        assert (await _bind(client, rid)).status_code == 200

        body = (await client.get(f"/api/rooms/{rid}/runner",
                                 headers=hdr)).json()
        assert body["workspace_key"] == PROJECT
        assert [r["id"] for r in body["runners"]] == [str(mine)]


# ── 派工要先綁 ───────────────────────────────────────────────────────

async def test_run_needs_a_bound_workspace(tmp_path):
    """未綁定 ⇒ 409 `workspace_not_bound`，在 `project_not_served` 之前。

    順序要緊：key 服務得到但房間沒綁時，回 `project_not_served` 會把人指去
    檢查執行器，而該做的是先綁房間。
    """
    app, client = await _client(tmp_path, "rununbound")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client)

        r = await client.post(f"/api/rooms/{rid}/runs",
                              json={"kind": "investigate", "project": PROJECT,
                                    "ref": "task-1", "brief": "查一下"},
                              headers=hdr)
        assert r.status_code == 409, r.text
        assert _code(r) == "workspace_not_bound"


async def test_run_project_must_match_the_bound_workspace(tmp_path):
    """綁了 A 卻派 B ⇒ 409 `workspace_project_mismatch`，回應帶著 A。

    讓它過去的話，同一間房的稽核串會橫跨兩份工作樹，而事後沒有任何一欄
    說得出某一筆 run 當時動的是哪一邊。
    """
    app, client = await _client(tmp_path, "runmismatch")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client, projects=(PROJECT, "u-e-p"))
        assert (await _bind(client, rid)).status_code == 200

        r = await client.post(f"/api/rooms/{rid}/runs",
                              json={"kind": "investigate", "project": "u-e-p",
                                    "ref": "task-1", "brief": "查一下"},
                              headers=hdr)
        assert r.status_code == 409, r.text
        assert _code(r) == "workspace_project_mismatch"
        assert r.json()["detail"]["workspace_key"] == PROJECT

        ok = await client.post(f"/api/rooms/{rid}/runs",
                               json={"kind": "investigate",
                                     "project": PROJECT,
                                     "ref": "task-1", "brief": "查一下"},
                               headers=hdr)
        assert ok.status_code == 200, "對照組派不出去，這條測試等於沒驗"


# ── 工作區清單與私人工作區 ───────────────────────────────────────────

async def test_dashboard_offers_candidates_before_and_after_binding(tmp_path):
    """`workspace_candidates` 未綁定也要給，而且排序去重。

    未綁定時 `runners` 是空的——App 靠它列下拉選單，沒有它的話房主永遠挑不
    出一個 key，這間房就綁不了。
    """
    app, client = await _client(tmp_path, "candidates")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client, projects=("u-e-p", PROJECT))
        await _register_runner(client, projects=(PROJECT, "chatroom"),
                               label="ex2")

        before = (await client.get(f"/api/rooms/{rid}/runner",
                                   headers=hdr)).json()
        assert before["runners"] == []
        assert before["workspace_candidates"] == [
            PROJECT, "chatroom", "u-e-p"]

        assert (await _bind(client, rid)).status_code == 200
        after = (await client.get(f"/api/rooms/{rid}/runner",
                                  headers=hdr)).json()
        assert after["workspace_candidates"] == [PROJECT, "chatroom", "u-e-p"]


async def test_a_public_room_never_sees_a_private_workspace(tmp_path):
    """公開房：私人 key 不在清單裡，硬填也綁不上。

    公開房的成員名單不受控制。綁得上的話，那個工作區的名字跟它裡面的派工
    會在一間誰都進得來的房裡走光。
    """
    app, client = await _client(tmp_path, "publicprivate")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        await _register_runner(client, projects=(PROJECT,),
                               private_projects=("secret-lab",))

        board = (await client.get(f"/api/rooms/{rid}/runner",
                                  headers=hdr)).json()
        assert board["workspace_candidates"] == [PROJECT]

        r = await _bind(client, rid, key="secret-lab")
        assert r.status_code == 409, r.text
        assert _code(r) == "workspace_private_room_required"
        assert (await _room_view(client, rid, hdr))["workspace_key"] is None


async def test_a_private_room_can_use_a_private_workspace(tmp_path):
    """私人房：私人 key 列得出來、綁得上，也派得了工。

    只擋不放的話，私人工作區等於永遠派不出工——這條規則就只是一個關掉功能
    的開關。
    """
    app, client = await _client(tmp_path, "privateroom")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, visibility="private")
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client, projects=(PROJECT,),
                                        private_projects=("secret-lab",))

        board = (await client.get(f"/api/rooms/{rid}/runner",
                                  headers=hdr)).json()
        assert board["workspace_candidates"] == [PROJECT, "secret-lab"]

        assert (await _bind(client, rid, key="secret-lab")).status_code == 200
        view = await _room_view(client, rid, hdr)
        assert view["workspace_key"] == "secret-lab"
        assert view["workspace_served"] is True

        board = (await client.get(f"/api/rooms/{rid}/runner",
                                  headers=hdr)).json()
        assert [r["id"] for r in board["runners"]] == [str(runner)]
        assert "private_projects" not in board["runners"][0], (
            "私人工作區的名單不該隨著執行器物件出去")

        run = await client.post(f"/api/rooms/{rid}/runs",
                                json={"kind": "investigate",
                                      "project": "secret-lab",
                                      "ref": "task-1", "brief": "查一下"},
                                headers=hdr)
        assert run.status_code == 200, run.text
        claimed = await client.post(f"/api/runners/{runner}/claim",
                                    headers=runner.headers)
        assert claimed.status_code == 200, "私人工作區的單領不到，它會永遠排著"


async def test_a_runner_that_never_heard_of_private_projects_still_works(
        tmp_path):
    """舊執行器：body 不帶 `private_projects`，一切照舊。

    升級一次 Hub 就讓遠端那些沒人重跑註冊的執行器全部失效的話，症狀是所有
    工作房同時派不出工。
    """
    app, client = await _client(tmp_path, "legacyrunner")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client)
        hdr = await _join_human(client, rid)
        runner = await _register_runner(client)

        assert (await _bind(client, rid)).status_code == 200
        board = (await client.get(f"/api/rooms/{rid}/runner",
                                  headers=hdr)).json()
        assert board["workspace_candidates"] == [PROJECT]
        assert [r["id"] for r in board["runners"]] == [str(runner)]

        # 不帶這一欄的心跳不會把已經宣告過的清單抹掉
        hb = await client.post(f"/api/runners/{runner}/heartbeat",
                               json={"status": "online"},
                               headers=runner.headers)
        assert hb.status_code == 200, hb.text
        row = await (await app.state.db.execute(
            "SELECT private_projects FROM runner WHERE id=?",
            (str(runner),))).fetchone()
        assert row["private_projects"] == "[]"
