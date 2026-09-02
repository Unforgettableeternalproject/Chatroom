"""Board v2 端點：Library、以 board_id 讀、掛接／解除。

驗收條件（BOARD_DESIGN §12）在這裡的對應：
1. 同一塊板掛 A／B 兩房，A 建卡後 B 與 Library 看到同一個 seq
2. A 封存後 B 仍可寫板
6. room member 但非 board member 讀不到板
7. 解除掛接不刪卡，重新掛接看得到原狀態
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


async def _room(client, name="房", session_key="claude-a"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": session_key}


async def _first_card(client, rid, hdr, title="第一張卡"):
    """在房裡寫第一張卡——**換軸就發生在這一刻**（第一次有人寫板）。"""
    r = await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": title}, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _board_id(client, rid, hdr):
    body = (await client.get(f"/api/rooms/{rid}/board", headers=hdr)).json()
    return body["board_id"]


async def test_writing_a_card_creates_and_attaches_a_board(tmp_path):
    """建房**不會**長出空板；第一次寫卡才建，而且建立者是 owner。"""
    app, client = await _client(tmp_path, "v2_lazy")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            assert await _board_id(client, rid, hdr) is None, "讀一下就長出板了"

            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            assert bid

            row = await (await app.state.db.execute(
                "SELECT role FROM board_member WHERE board_id=? AND actor_key=?",
                (bid, "claude-a"))).fetchone()
            assert row["role"] == "owner"


async def test_existing_cards_are_moved_onto_the_board(tmp_path):
    """換軸時這間房既有的卡要一起帶過去，不能留一批沒有板的孤卡。"""
    app, client = await _client(tmp_path, "v2_backfill")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            row = await (await app.state.db.execute(
                "SELECT COUNT(*) AS n FROM board_task WHERE board_id=''"
            )).fetchone()
            assert row["n"] == 0, "有卡沒被換軸"
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert len(body["tasks"]) == 1


async def test_one_board_two_rooms_share_one_seq(tmp_path):
    """驗收 1：A 建卡後，B 與 Library 看到的是同一條水位。"""
    app, client = await _client(tmp_path, "v2_share")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr = await _join(client, ra, "claude-a", "A")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await _first_card(client, ra, hdr)
            bid = await _board_id(client, ra, hdr)

            r = await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr)
            assert r.status_code == 200, r.text

            before = (await client.get(f"/api/boards/{bid}",
                                       headers=hdr)).json()["board_seq"]
            await client.post(f"/api/rooms/{ra}/board/tasks",
                              json={"title": "第二張"}, headers=hdr)
            after = (await client.get(f"/api/boards/{bid}",
                                      headers=hdr)).json()["board_seq"]
            assert after > before

            # B 房的 v1 水位也要跟上——不同步的話，B 的舊 client 會停在
            # 原地，而它只會收到 200 與空清單，不會知道自己漏了
            b_body = (await client.get(f"/api/rooms/{rb}/board",
                                       headers=hdr_b)).json()
            assert b_body["board_seq"] == after
            assert b_body["board_id"] == bid


async def test_detach_keeps_the_cards_and_reattach_restores_the_view(tmp_path):
    """驗收 7：解除掛接不刪任何東西，掛回來看到的是原狀態。"""
    app, client = await _client(tmp_path, "v2_detach")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            r = await client.delete(f"/api/boards/{bid}/rooms/{rid}",
                                    headers=hdr)
            assert r.status_code == 200, r.text
            assert await _board_id(client, rid, hdr) is None

            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert len(body["tasks"]) == 1, "解除掛接把卡刪掉了"
            # 已解除的房仍要出現在清單裡，帶 detached: true
            assert body["attached_rooms"] == [
                {"id": rid, "name": "房", "status": "active", "detached": True}]

            r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert len(body["tasks"]) == 1
            assert [x["detached"] for x in body["attached_rooms"]] == [True, False]


async def test_a_room_cannot_hold_two_boards(tmp_path):
    app, client = await _client(tmp_path, "v2_two")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr_a = await _join(client, ra, "claude-a", "A")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await _first_card(client, ra, hdr_a)
            await _first_card(client, rb, hdr_b)
            bid_a = await _board_id(client, ra, hdr_a)

            r = await client.post(f"/api/boards/{bid_a}/rooms/{rb}",
                                  headers=hdr_a)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "room_already_has_board"


async def test_room_member_is_not_automatically_a_board_member(tmp_path):
    """驗收 6：房裡的人不會自動變成板上的人。"""
    app, client = await _client(tmp_path, "v2_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            other = await _join(client, rid, "claude-b", "B")
            r = await client.get(f"/api/boards/{bid}", headers=other)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"


async def test_library_lists_only_my_boards_with_counts(tmp_path):
    app, client = await _client(tmp_path, "v2_lib")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            mine = await _join(client, rid, "claude-a", "A")
            tid = await _first_card(client, rid, mine)
            await client.post(f"/api/board/tasks/{tid}/claim", headers=mine)

            body = (await client.get("/api/boards", headers=mine)).json()
            assert len(body["boards"]) == 1
            card = body["boards"][0]
            assert card["my_role"] == "owner"
            assert card["attached_room_count"] == 1
            assert card["task_counts"] == {"total": 1, "done": 0, "claimed": 1}

            stranger = {"X-Session-Key": "claude-zzz"}
            body = (await client.get("/api/boards", headers=stranger)).json()
            assert body["boards"] == []


async def test_archived_room_does_not_freeze_the_board(tmp_path):
    """驗收 2：一間房封存了，板還活著——從別間房照樣寫得動。"""
    app, client = await _client(tmp_path, "v2_archive")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr_a = await _join(client, ra, "claude-a", "A")
            hdr_b = await _join(client, rb, "claude-a", "A")
            await _first_card(client, ra, hdr_a)
            bid = await _board_id(client, ra, hdr_a)
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr_a)

            r = await client.post(f"/api/rooms/{ra}/archive",
                                  headers={"X-Session-Key": "claude-a"})
            assert r.status_code == 200, r.text

            r = await client.post(f"/api/rooms/{rb}/board/tasks",
                                  json={"title": "從 B 房寫"}, headers=hdr_b)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=hdr_a)).json()
            assert len(body["tasks"]) == 2


async def test_creating_cards_from_the_board_without_a_room(tmp_path):
    """Board Library 裡沒有房——那個畫面上也要建得了東西。

    權限看 `board_member` 而不是房內身分：拿房內身分當門檻的話，
    Library 上什麼都做不了。
    """
    app, client = await _client(tmp_path, "v2_bcards")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            # 只帶 session_key，沒有 participant、沒有房
            only_key = {"X-Session-Key": "claude-a"}
            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "從板上開的週期"},
                                  headers=only_key)
            assert r.status_code == 200, r.text
            assert r.json()["board_id"] == bid

            r = await client.post(f"/api/boards/{bid}/tasks",
                                  json={"title": "從板上隨手記"},
                                  headers=only_key)
            assert r.status_code == 200, r.text

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=only_key)).json()
            assert {o["title"] for o in body["objectives"]} == {
                "未分類", "從板上開的週期"}
            assert {t["title"] for t in body["tasks"]} == {
                "第一張卡", "從板上隨手記"}
            # 兩條路徑共用同一組「未分類」，不各長一組
            assert len([o for o in body["objectives"]
                        if o["title"] == "未分類"]) == 1


async def test_board_cards_reject_non_members(tmp_path):
    app, client = await _client(tmp_path, "v2_bcards_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "闖進來"},
                                  headers={"X-Session-Key": "claude-zzz"})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"


async def test_board_with_no_attached_room_says_so_clearly(tmp_path):
    """過渡期限制要**明確擋下來**，不是撞 FK 回 500。

    item 的 room_id 還是 NOT NULL（v1 遺留，等 table rebuild 才拿得掉），
    所以板上沒房時建不了卡。回 500 的話，查半天才知道是這件事。
    """
    app, client = await _client(tmp_path, "v2_noroom")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)

            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "沒房可掛"}, headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "board_has_no_room"


async def test_session_key_can_come_from_header_or_query(tmp_path):
    """房那邊的 /api/rooms 收 query session_key。兩邊不一致的話，照著既有
    慣例寫的 client 會拿到 400 而不知道差在哪——同一份憑證，兩種放法都收。
    """
    app, client = await _client(tmp_path, "v2_key_place")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)

            r = await client.get("/api/boards?session_key=claude-a")
            assert r.status_code == 200, r.text
            assert [b["id"] for b in r.json()["boards"]] == [bid]

            r = await client.get(f"/api/boards/{bid}?session_key=claude-a")
            assert r.status_code == 200, r.text

            # 完全不給仍要擋，而且要講清楚缺什麼
            r = await client.get("/api/boards")
            assert r.status_code == 400
            assert r.json()["detail"]["code"] == "session_key_required"


async def test_board_member_name_is_decided_by_the_first_room(tmp_path):
    """同一個 actor 在兩間房叫不同名字：板上以**最早進入的那個**為準，
    另一個進 aliases（艾斯維爾第 2 點）。

    板上只能有一個稱呼——否則同一個人在同一張卡的歷史裡會以兩個名字出現，
    看起來像兩個人。alias 連 room_name 一起存快照：房可以被永久刪除，
    那時 room_id 只是一個查不到的字串。
    """
    app, client = await _client(tmp_path, "v2_alias")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            hdr_a = await _join(client, ra, "claude-a", "先進來的名字")
            await _first_card(client, ra, hdr_a)
            bid = await _board_id(client, ra, hdr_a)
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=hdr_a)

            # 同一把 session_key，B 房用另一個名字，然後在板上寫東西
            hdr_b = await _join(client, rb, "claude-a", "後來的名字")
            await client.post(f"/api/rooms/{rb}/board/tasks",
                              json={"title": "從 B 房寫"}, headers=hdr_b)

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=hdr_a)).json()
            me = [m for m in body["members"]
                  if m["actor_key"] == "claude-a"][0]
            assert me["display_name"] == "先進來的名字"
            assert me["role"] == "owner"
            assert len(me["aliases"]) == 1
            alias = me["aliases"][0]
            assert alias["name"] == "後來的名字"
            assert alias["room_id"] == rb
            assert alias["room_name"] == "B房", "房刪掉之後 hover 就靠它了"


async def test_a_visitor_from_an_attached_room_becomes_an_editor(tmp_path):
    """從掛接房走進來的人自動成為 editor。

    給 viewer 的話，房裡的人會發現自己動不了眼前這塊板——而他明明在
    這間房裡，那個「為什麼」沒有地方講得清楚。
    """
    app, client = await _client(tmp_path, "v2_visitor")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            other = await _join(client, rid, "claude-b", "B")
            await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "B 也寫一張"}, headers=other)

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=other)).json()
            roles = {m["actor_key"]: m["role"] for m in body["members"]}
            assert roles == {"claude-a": "owner", "claude-b": "editor"}


async def test_supervisor_directive_is_recorded_and_projected(tmp_path):
    """H6：Supervisor 對正在工作的 agent 送判斷。

    兩件事一起做，缺一不可——寫 board_event（真相與稽核串），以及在目標
    所在的那間房投影一則 mention 他的訊息（喚醒）。光寫 event 的話，agent
    沒去讀板就收不到，而送出的人這邊看起來一切正常：最典型的靜默失效。
    """
    app, client = await _client(tmp_path, "v2_directive")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            worker = await _join(client, rid, "claude-w", "Worker")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "Worker 的卡"}, headers=worker)

            # Supervisor 是一個**不在這間房裡**的身分
            r = await client.post(
                f"/api/boards/{bid}/supervisor",
                json={"target_actor_key": "claude-sup",
                      "display_name": "米絲媞", "actor_kind": "claude"},
                headers=owner)
            assert r.status_code == 200, r.text

            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"target_actor_key": "claude-w",
                      "text": "那條查詢會漏掉解除掛接的房"},
                headers={"X-Session-Key": "claude-sup"})
            assert r.status_code == 200, r.text
            assert r.json()["delivered"] is True
            assert r.json()["delivered_room_id"] == rid

            # 投影：目標被 mention 到，watcher 才叫得醒他
            msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                     headers=owner)).json()["messages"]
            hit = [m for m in msgs if m["system_event"] == "board_directive"]
            assert len(hit) == 1
            assert hit[0]["mentions"] == ["Worker"]
            assert "那條查詢會漏掉解除掛接的房" in hit[0]["content"]

            # 稽核串：一次送出只留一筆 canonical event
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert len(body["directives"]) == 1
            d = body["directives"][0]
            assert d["from_actor_key"] == "claude-sup"
            assert d["to_actor_key"] == "claude-w"
            assert body["supervisor"] == {"actor_key": "claude-sup",
                                          "display_name": "米絲媞",
                                          "actor_kind": "claude"}


async def test_directive_to_someone_who_is_not_around_says_so(tmp_path):
    """目標不在任何掛接房時要**誠實回 delivered: false**。

    假裝送到了會讓 Supervisor 以為對方已經知道了——而那正是他接下來所有
    判斷的前提。
    """
    app, client = await _client(tmp_path, "v2_directive_away")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"target_actor_key": "claude-nobody", "text": "在嗎"},
                headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["delivered"] is False
            # 送不到不代表不記——他下次讀板還是看得到
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert len(body["directives"]) == 1


async def test_only_supervisor_or_owner_can_send_directives(tmp_path):
    app, client = await _client(tmp_path, "v2_directive_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            other = await _join(client, rid, "claude-b", "B")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            # B 在板上寫過東西 ⇒ 是 editor，但 editor 不能送判斷
            await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "B 的卡"}, headers=other)

            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"target_actor_key": "claude-a", "text": "我來指揮"},
                headers=other)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_supervisor"


async def test_supervisor_can_be_dismissed(tmp_path):
    """人類可以卸任 Supervisor 並重派（艾斯維爾第 4 點）。"""
    app, client = await _client(tmp_path, "v2_sup_clear")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            await client.post(f"/api/boards/{bid}/supervisor",
                              json={"target_actor_key": "claude-s1",
                                    "display_name": "第一任"}, headers=owner)
            r = await client.post(f"/api/boards/{bid}/supervisor",
                                  json={"target_actor_key": ""},
                                  headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["supervisor"] is None

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert body["supervisor"] is None

            # 卸任之後前任就不能再送判斷了
            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"target_actor_key": "claude-a", "text": "我還在"},
                headers={"X-Session-Key": "claude-s1"})
            assert r.status_code == 403


async def test_no_duplicate_request_model_names(tmp_path):
    """`app.py` 裡不能有兩個同名的請求模型。

    Python 的後定義會**靜默覆蓋**前一個，於是端點宣告的是 A、實際驗證的是
    B——請求回 422 說「這些欄位不被允許」，而你看著自己剛寫好的模型定義，
    上面明明有那些欄位。（2026-09-02 實際踩過：board-scoped 的
    Supervisor 模型與房內那個同名。）
    """
    import re
    from pathlib import Path

    src = Path(__file__).resolve().parents[1] / "server" / "chatroom_server" / "app.py"
    names = re.findall(r"^class (\w+)\(BaseModel\):",
                       src.read_text(encoding="utf-8"), re.M)
    dupes = sorted({n for n in names if names.count(n) > 1})
    assert not dupes, f"這些請求模型有同名的兩份，後定義的會靜默覆蓋：{dupes}"


async def test_create_a_board_from_the_library_and_from_a_room(tmp_path):
    """`POST /api/boards`：Library 上建新板，也可以順便掛到一間房。

    @開發Novia (UI) 打真貨時發現這條路由不存在——Library 有「建立」按鈕
    卻沒有對應端點。從房裡自動長出來的那條服務的是「我只是想記一件事」，
    這條服務的是「我要開一個新專案」，兩者並存。
    """
    app, client = await _client(tmp_path, "v2_create")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-a"}
            r = await client.post("/api/boards",
                                  json={"name": "沒有房的板"}, headers=key)
            assert r.status_code == 200, r.text
            assert r.json()["attached_room_id"] is None

            rid = await _room(client)
            r = await client.post("/api/boards",
                                  json={"name": "掛在房上的板",
                                        "origin_room_id": rid}, headers=key)
            assert r.status_code == 200, r.text
            bid = r.json()["id"]
            assert r.json()["attached_room_id"] == rid

            hdr = await _join(client, rid, "claude-a", "A")
            assert await _board_id(client, rid, hdr) == bid

            # 已經掛了一塊，不能再掛第二塊
            r = await client.post("/api/boards",
                                  json={"name": "第二塊",
                                        "origin_room_id": rid}, headers=key)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "room_already_has_board"

            body = (await client.get("/api/boards", headers=key)).json()
            assert {b["name"] for b in body["boards"]} == {
                "沒有房的板", "掛在房上的板"}
