"""板的結局：`outcome` 與 `status` 是兩軸，不是同一個欄位的四個值。

艾斯維爾 2026-09-05 裁定 A（兩軸分離）：

| 軸 | 值 | 回答的問題 | 可逆 |
|---|---|---|---|
| `status` | active / archived | 現在還能不能編輯 | 是 |
| `outcome` | ""／completed／abandoned | 這份工作的結局是什麼 | 可 reopen |

塞成四選一的話，「完成**且**收起來」——最常見的收尾——反而表達不出來。
同一個判斷在 Task 那裡做過：status 與 claim 正交，不把 `claimed` 放進 status。
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


async def _join(client, rid, who, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": who,
        "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": who}


async def _room(client, who="human-1", name="房"):
    r = await client.post("/api/rooms", json={"name": name,
                                              "session_key": who})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _board(client, hdr, name="板"):
    r = await client.post("/api/boards", json={"name": name,
                                               "visibility": "public"},
                          headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _settle(client, bid, hdr, outcome):
    return await client.post(f"/api/boards/{bid}/outcome",
                             json={"outcome": outcome}, headers=hdr)


async def _library_ids(client, hdr, **params):
    r = await client.get("/api/boards", params=params, headers=hdr)
    assert r.status_code == 200, r.text
    return [b["id"] for b in r.json()["boards"]]


async def test_a_new_board_has_no_outcome_yet(tmp_path):
    """沒有結局是空字串，不是缺欄位——client 分不出「還在做」與「舊版
    Hub 不會回」的話，兩者會被畫成同一個樣子。"""
    app, client = await _client(tmp_path, "oc_new")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
        assert body["outcome"] == ""


async def test_a_human_owner_can_settle_and_reopen(tmp_path):
    """完成是可逆的——不可逆的只有刪除（封存那條的同一個判斷）。

    ⚠️ 板要先掛過房再解除才收得了尾（09/06 起的前置條件，見本檔末段）。
    """
    app, client = await _client(tmp_path, "oc_settle")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid, _ = await _settleable(client, hdr, room_name="工作房")

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 200, r.text
        assert r.json()["outcome"] == "completed"

        r = await _settle(client, bid, hdr, "")
        assert r.status_code == 200, r.text
        assert (await client.get(f"/api/boards/{bid}",
                                 headers=hdr)).json()["outcome"] == ""


async def test_an_agent_cannot_declare_the_work_finished(tmp_path):
    """限人類，照 Objective `verified` 那道閘的同一個理由：判斷「真的做完
    了嗎」要跑測試、看畫面，那件事只有人做得到。"""
    app, client = await _client(tmp_path, "oc_agent")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client, who="agent-1")
        hdr = await _join(client, rid, "agent-1", "諾薇亞")
        bid = await _board(client, hdr)

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_only"


async def test_outcome_and_archived_are_independent(tmp_path):
    """「完成**且**收起來」要表達得出來——那正是四值互斥做不到的事。"""
    app, client = await _client(tmp_path, "oc_orthogonal")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid, _ = await _settleable(client, hdr, room_name="工作房")

        assert (await _settle(client, bid, hdr, "completed")).status_code == 200
        r = await client.post(f"/api/boards/{bid}/archive", headers=hdr)
        assert r.status_code == 200, r.text

        body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
        assert body["status"] == "archived"
        assert body["outcome"] == "completed", "封存把結局洗掉了"


async def test_settled_boards_leave_the_library_but_can_be_asked_for(tmp_path):
    """卡上那句「顯示至完成或廢止」——收尾之後預設不佔分頁，但要找得回來。"""
    app, client = await _client(tmp_path, "oc_library")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        live = await _board(client, hdr, "還在做")
        done, _ = await _settleable(client, hdr, "做完了", room_name="工作房")

        assert (await _settle(client, done, hdr,
                              "completed")).status_code == 200

        ids = await _library_ids(client, hdr)
        assert live in ids
        assert done not in ids, "收尾的板還佔著分頁"

        ids = await _library_ids(client, hdr, outcome="completed")
        assert done in ids
        assert live not in ids

        ids = await _library_ids(client, hdr, outcome="any")
        assert live in ids and done in ids


async def test_an_unknown_outcome_is_refused(tmp_path):
    """值不合法要明確擋下：默默存進去的話，分堆會慢慢失效而不報錯。"""
    app, client = await _client(tmp_path, "oc_bad")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        r = await _settle(client, bid, hdr, "finished")
        assert r.status_code == 422, r.text


async def test_the_library_row_says_what_the_outcome_was(tmp_path):
    """清單**過濾**得掉收尾的板，但每一列也要說得出自己的結局是什麼。

    ⚠️ 與 `custom_tags` 那次同型（09/05 卡 d10ae5f2）：**過濾做了、值沒回**。
    切到「已收尾」時每一列都不知道自己是 completed 還是 abandoned——而那兩者
    在畫面上必須分得出來，「做完了」與「不做了」是兩件事。
    """
    app, client = await _client(tmp_path, "oc_row")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        done, _ = await _settleable(client, hdr, "做完了", room_name="房甲")
        dropped, _ = await _settleable(client, hdr, "不做了", room_name="房乙")
        live = await _board(client, hdr, "還在做")

        assert (await _settle(client, done, hdr,
                              "completed")).status_code == 200
        assert (await _settle(client, dropped, hdr,
                              "abandoned")).status_code == 200

        r = await client.get("/api/boards", params={"outcome": "any"},
                             headers=hdr)
        rows = {b["id"]: b for b in r.json()["boards"]}
        assert rows[done]["outcome"] == "completed"
        assert rows[dropped]["outcome"] == "abandoned"
        assert rows[live]["outcome"] == ""


async def test_claimed_count_means_still_being_worked_on(tmp_path):
    """清單的 `claimed` 是「**還在做**幾張」，不是「歷史上有幾張被領過」。

    🟠 審核用Codex 2026-09-05 以現行板實測：API 回 `claimed=65`，而真正未收尾
    且 held 的只有 **3** 張——其餘 61 張 done-held ＋ 1 張 cancelled-held 全被
    算進去了。App 又把這個數字直接標成「N 進行中」。

    根因：**認領與狀態是兩個正交的軸**（`BOARD_DESIGN` §3.3 明寫），而卡
    做完之後認領不會自動解除——`claim_state` 停在 `held` 是正常的，它記的是
    「這張是誰做的」。所以數「還在做幾張」時，只看 `claim_state` 必然虛高，
    而且**板越活躍虛得越多**：它跟著歷史累積，永遠只增不減。
    """
    app, client = await _client(tmp_path, "oc_claimed")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期"},
                                 headers=hdr)).json()["id"]
        cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                 json={"title": "一段"},
                                 headers=hdr)).json()["id"]

        async def _task(title):
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": title},
                                     headers=hdr)).json()["id"]
            r = await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            assert r.status_code == 200, r.text
            return tid

        working = await _task("還在做")
        finished = await _task("做完了")
        dropped = await _task("不做了")
        for tid, status in ((finished, "done"), (dropped, "cancelled")):
            r = await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": status}, headers=hdr)
            assert r.status_code == 200, r.text

        bid = (await client.get(f"/api/rooms/{rid}/board",
                                headers=hdr)).json()["board_id"]
        (row,) = [b for b in (await client.get("/api/boards", headers=hdr)
                              ).json()["boards"] if b["id"] == bid]

        assert row["task_counts"]["claimed"] == 1, (
            "已收尾的卡還被算成「進行中」——"
            f"實際 {row['task_counts']['claimed']}，應該只有 {working[:8]} 那張"
        )
        # 另外兩個數字不動：total 仍是全部、done 仍是完成數
        assert row["task_counts"]["total"] == 3
        assert row["task_counts"]["done"] == 1


# ---------------------------------------------------------------------------
# 宣告結局的前置條件（09/06 卡 47f0ee5a）
#
# 艾斯維爾 09/06（想法板 #8 段）：還被聊天室綁定的板不能宣告結局；從未被
# 綁定過的也不能。只有「曾掛過房且已全部解除掛接」的板可以收尾。
#
# 判準寫在 server，client 不重算——所以讀取回應要出 `outcome_eligible` 與
# `outcome_block_reason`，409 用同一組字串。UI 拿它決定入口顯示，409 只是
# 兜底（@開發Novia (UI) 09/06 #16）。
# ---------------------------------------------------------------------------


async def _attach(client, bid, rid, hdr):
    r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)
    assert r.status_code == 200, r.text
    return r


async def _detach(client, bid, rid, hdr):
    r = await client.request("DELETE", f"/api/boards/{bid}/rooms/{rid}",
                             headers=hdr)
    assert r.status_code == 200, r.text
    return r


async def _settleable(client, hdr, name="板", room_name="房",
                      who="human-1"):
    """一塊「曾掛過房、現在已解除」的板——可以宣告結局的那種狀態。"""
    rid = await _room(client, who=who, name=room_name)
    bid = await _board(client, hdr, name)
    await _attach(client, bid, rid, hdr)
    await _detach(client, bid, rid, hdr)
    return bid, rid


async def test_a_board_that_never_had_a_room_cannot_be_settled(tmp_path):
    """從未掛過房的板不能宣告結局。

    這種板上的東西沒有經過任何人——收尾是對一段共同工作的結論，而它從來
    沒有共同過。擋在 server：只讓 UI 藏入口的話，bridge 那條路仍然打得進來。
    """
    app, client = await _client(tmp_path, "oc_never")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "never_attached"


async def test_a_board_still_attached_cannot_be_settled(tmp_path):
    """還掛在房上就不能收尾——房裡的人還在用它。"""
    app, client = await _client(tmp_path, "oc_attached")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid = await _board(client, hdr)
        await _attach(client, bid, rid, hdr)

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "still_attached"


async def test_a_board_whose_rooms_are_all_detached_can_be_settled(tmp_path):
    """掛過、而且已經全部解除——這才是可以宣告結局的狀態。"""
    app, client = await _client(tmp_path, "oc_detached")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid, _ = await _settleable(client, hdr)

        r = await _settle(client, bid, hdr, "completed")
        assert r.status_code == 200, r.text


async def test_reopening_is_never_blocked_by_the_precondition(tmp_path):
    """**重新打開不受前置條件管。**

    前置條件擋的是「宣告結局」這個動作。反過來擋 reopen 的話，一塊收尾後
    又被掛回房的板會卡在 completed 拿不下來——那是個沒有出口的狀態。
    """
    app, client = await _client(tmp_path, "oc_reopen")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        bid, room_id = await _settleable(client, hdr)
        assert (await _settle(client, bid, hdr, "completed")).status_code == 200

        # 又掛回去了（於是它「還被綁定著」）
        await _attach(client, bid, room_id, hdr)

        r = await _settle(client, bid, hdr, "")
        assert r.status_code == 200, r.text
        assert (await client.get(f"/api/boards/{bid}",
                                 headers=hdr)).json()["outcome"] == ""


async def test_the_server_says_whether_the_outcome_can_be_declared(tmp_path):
    """判準只有一份：server 出結論，UI 不重算。

    ⚠️ `attached_room_count` 給的是當下值，**0 分不出「從未掛過」與「掛過
    已全解」**——UI 拿它自己算會算錯，而算錯的方向是把入口開給不該開的板。
    """
    app, client = await _client(tmp_path, "oc_eligible")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")

        never = await _board(client, hdr, "從沒掛過")
        still = await _board(client, hdr, "還掛著")
        await _attach(client, still, rid, hdr)
        ok, _ = await _settleable(client, hdr, "已解除", room_name="另一間房")

        r = await client.get("/api/boards", params={"outcome": "any"},
                             headers=hdr)
        rows = {b["id"]: b for b in r.json()["boards"]}
        assert rows[never]["outcome_eligible"] is False
        assert rows[never]["outcome_block_reason"] == "never_attached"
        assert rows[still]["outcome_eligible"] is False
        assert rows[still]["outcome_block_reason"] == "still_attached"
        assert rows[ok]["outcome_eligible"] is True
        assert rows[ok]["outcome_block_reason"] == ""

        # 詳情端點也要說得出來——UI 的宣告入口在詳情頁上
        body = (await client.get(f"/api/boards/{ok}", headers=hdr)).json()
        assert body["outcome_eligible"] is True
        assert body["outcome_block_reason"] == ""


async def test_the_library_can_ask_for_everything_already_settled(tmp_path):
    """`?outcome=settled` ＝ completed ∪ abandoned（09/06 卡 cc6228fb）。

    「已收尾」那一頁要的是兩者，而現在得送 `any` 再由 client 自己挑——
    判準又多了一份。
    """
    app, client = await _client(tmp_path, "oc_settled_filter")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        done, _ = await _settleable(client, hdr, "做完了", room_name="房甲")
        dropped, _ = await _settleable(client, hdr, "不做了", room_name="房乙")
        live = await _board(client, hdr, "還在做")

        await _settle(client, done, hdr, "completed")
        await _settle(client, dropped, hdr, "abandoned")

        ids = await _library_ids(client, hdr, outcome="settled")
        assert done in ids and dropped in ids
        assert live not in ids


async def test_an_unknown_library_outcome_filter_is_refused(tmp_path):
    """值域擋下時，`allowed` 要把 `settled` 一起講出來——回應自己就是文件。"""
    app, client = await _client(tmp_path, "oc_bad_filter")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        r = await client.get("/api/boards", params={"outcome": "finished"},
                             headers=hdr)
        assert r.status_code == 422, r.text
        assert "settled" in r.json()["detail"]["allowed"]
