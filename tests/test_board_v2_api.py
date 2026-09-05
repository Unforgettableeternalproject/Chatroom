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
                {"id": rid, "name": "房", "status": "active", "detached": True,
                 # supervisor 是 per-room 的，沒指定就是 None
                 "supervisor": None,
                 # 房的可見度：板 owner 要看得出自己掛在哪種房上
                 "visibility": "public"}]

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


async def test_someone_from_no_room_at_all_is_still_not_a_board_member(tmp_path):
    """房外的人仍然什麼都拿不到。

    ⚠️ 這條**原本測的是相反的事**（驗收 6：房裡的人不會自動變成板上的人）。
    艾斯維爾 2026-09-03 推翻了那條裁決——掛接房的成員自動算 editor，理由見
    `_board_role`。所以剩下要守的界線只有一條：**沒有進任何掛接房的人**。
    退路要是連這個都放過，`board_member` 就完全沒有意義了。
    """
    app, client = await _client(tmp_path, "v2_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            r = await client.get(f"/api/boards/{bid}",
                                 headers={"X-Session-Key": "claude-outsider"})
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"

            # 進了房就算數——同一把 key，差別只在他現在在房裡
            inside = await _join(client, rid, "claude-outsider", "路人")
            ok = await client.get(f"/api/boards/{bid}", headers=inside)
            assert ok.status_code == 200
            assert ok.json()["my_role"] == "editor"


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


async def test_a_board_with_no_room_can_still_hold_cards(tmp_path):
    """板上沒有任何掛接房時**照樣建得了卡**（§11 步驟 8 換表之後）。

    換表前這裡會回 409：item 的 room_id 是 NOT NULL 且有外鍵，卡沒有一間
    活著的房可指就存不下來。一塊還沒掛上任何房的板，本來就該能先把要做的
    事寫下來。
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
                                  json={"title": "沒房也寫得下"}, headers=hdr)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert "沒房也寫得下" in {o["title"] for o in body["objectives"]}
            assert body["attached_rooms"] == [
                {"id": rid, "name": "房", "status": "active", "detached": True,
                 # supervisor 是 per-room 的，沒指定就是 None
                 "supervisor": None,
                 # 房的可見度：板 owner 要看得出自己掛在哪種房上
                 "visibility": "public"}]


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


async def test_a_visitor_from_an_attached_room_may_write_but_stays_off_the_roster(
        tmp_path):
    """從掛接房走進來的人寫得動板，但**不會被寫進成員名冊**。

    這條的歷史值得留著：它原本測「自動升成 editor」，2026-09-02 被改成測
    相反的事（那個自動升級讓 v1 的 room 路徑成了 ACL 後門），2026-09-03 又
    被艾斯維爾推回來——因為那道門擋掉的是「在 B 房接 A 房帶過來的卡」，
    而那正是他要的功能。後門與正門是同一扇，差別只在誰說了算。

    但**名冊不動**：`members[]` 只列明示加入的人。房內身分是動態的（離房
    就沒了），寫進名冊會讓「誰被正式加進這塊板」與「誰現在剛好在房裡」
    混成同一件事，而清掉前者要靠移除後者。
    """
    app, client = await _client(tmp_path, "v2_visitor")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            other = await _join(client, rid, "claude-b", "B")
            r = await client.post(f"/api/rooms/{rid}/board/tasks",
                                  json={"title": "B 想寫一張"}, headers=other)
            assert r.status_code == 200, r.text

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert [m["actor_key"] for m in body["members"]] == ["claude-a"],                 "房內身分不該被寫進成員名冊"

            # 房外的人照樣被擋，而且 403 要講得出是哪塊板——UI 靠它畫
            # 「這間房掛著某某板，但你還不是它的成員」
            out = await client.get(f"/api/boards/{bid}",
                                   headers={"X-Session-Key": "claude-out"})
            assert out.status_code == 403
            assert out.json()["detail"]["board_id"] == bid
            assert out.json()["detail"]["board_name"]


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

            # Supervisor 是一個**不在這間房裡**的身分——指派走房軸，
            # 而房軸刻意不驗「他是不是成員」，正是為了這種還沒進房的情形
            r = await client.post(
                f"/api/rooms/{rid}/board/supervisor",
                json={"session_key": "claude-sup"},
                headers={"X-Session-Key": "claude-a"})
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
            # Supervisor 只在掛接房那一層有答案（N-6，2026-09-05）——
            # 頂層那份已經退場，它在多房時本來就答不出「是哪一間的」
            assert "supervisor" not in body
            assert [r["supervisor"]["actor_key"]
                    for r in body["attached_rooms"]] == ["claude-sup"]


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
    """人類可以卸任 Supervisor 並重派（艾斯維爾第 4 點）。

    ⚠️ 2026-09-05 改走房軸：board-scoped 的指派端點退場了（N-6），
    Supervisor 一律 per-room。卸任的**效果**沒有變——前任送不出判斷。
    """
    app, client = await _client(tmp_path, "v2_sup_clear")
    admin = {"X-Session-Key": "claude-a"}
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "claude-s1"}, headers=admin)
            r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                                  json={"session_key": ""}, headers=admin)
            assert r.status_code == 200, r.text

            # 板軸看得到的是**掛接房的彙整**，不是板自己的一份答案
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert [r["supervisor"] for r in body["attached_rooms"]] == [None]

            # 卸任之後前任就不能再送判斷了
            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"target_actor_key": "claude-a", "text": "我還在"},
                headers={"X-Session-Key": "claude-s1"})
            assert r.status_code == 403


async def test_the_board_scoped_supervisor_endpoint_is_gone(tmp_path):
    """board-scoped 的 Supervisor 指派端點已退場（N-6）。

    Supervisor 屬於 room 不屬於 board（艾斯維爾 2026-09-03 推翻原設計），
    而兩個層級並存的代價不是多一條路，是**同一個問題有兩個答案**：
    授權判定得兩邊都問、畫面得決定要顯示哪一個，而兩者不一致時沒有人是錯的。

    `BOARD_DESIGN.md` §端點表 09/03 就把它劃掉了，程式碼晚了兩天才跟上。
    """
    app, client = await _client(tmp_path, "v2_sup_gone")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            r = await client.post(f"/api/boards/{bid}/supervisor",
                                  json={"target_actor_key": "claude-s1"},
                                  headers=owner)
            assert r.status_code == 404, r.text


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


async def test_patch_archive_and_unarchive(tmp_path):
    """改名／封存／解除封存。**板封存與房封存是兩件事**（§3.2）。"""
    app, client = await _client(tmp_path, "v2_admin")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            r = await client.patch(f"/api/boards/{bid}",
                                   json={"name": "改過的名字"}, headers=owner)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert body["name"] == "改過的名字"

            r = await client.post(f"/api/boards/{bid}/archive", headers=owner)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert body["status"] == "archived"

            # 板封存了，房照樣進得去、寫得動——兩件事不能綁在一起
            r = await client.post(f"/api/rooms/{rid}/messages",
                                  json={"content": "板封了但話還講得動"},
                                  headers=owner)
            assert r.status_code == 200, r.text

            # 封存的板不能從板上建卡
            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "還想寫"}, headers=owner)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "board_archived"

            r = await client.post(f"/api/boards/{bid}/unarchive", headers=owner)
            assert r.status_code == 200, r.text
            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "解封之後"}, headers=owner)
            assert r.status_code == 200, r.text


async def test_members_can_be_added_and_removed(tmp_path):
    """成員管理：加、改角色、移除。移除會讓他手上的卡立刻變孤兒。"""
    app, client = await _client(tmp_path, "v2_members")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            worker = await _join(client, rid, "claude-w", "Worker")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            # A+ 之後房裡的人不會自動是板成員——owner 要先把他加進來，
            # 他才做得了事。這一步本身就是新規則的一部分
            r = await client.post(f"/api/boards/{bid}/members",
                                  json={"actor_key": "claude-w",
                                        "role": "editor"}, headers=owner)
            assert r.status_code == 200, r.text
            tid = (await client.post(f"/api/rooms/{rid}/board/tasks",
                                     json={"title": "Worker 的卡"},
                                     headers=worker)).json()["id"]
            await client.post(f"/api/board/tasks/{tid}/claim", headers=worker)

            # 重複加是**改角色**，不是報錯
            r = await client.post(f"/api/boards/{bid}/members",
                                  json={"actor_key": "claude-w",
                                        "role": "viewer"}, headers=owner)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            roles = {m["actor_key"]: m["role"] for m in body["members"]}
            assert roles["claude-w"] == "viewer"

            r = await client.delete(f"/api/boards/{bid}/members/claude-w",
                                    headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["orphaned_tasks"] == 1, "他手上的卡沒有讓出來"

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert [m["actor_key"] for m in body["members"]] == ["claude-a"]
            card = [t for t in body["tasks"] if t["id"] == tid][0]
            assert card["claim_state"] == "orphaned"
            assert card["orphaned_reason"] == "已被移出這塊板"
            # 但他做過的事還在：抹掉會讓板上一段紀錄變成沒有人做過
            assert card["created_by_name"] == "Worker"


async def test_the_last_owner_cannot_be_removed(tmp_path):
    """移掉最後一個 owner 之後就沒有人能管這塊板了。"""
    app, client = await _client(tmp_path, "v2_last_owner")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            r = await client.delete(f"/api/boards/{bid}/members/claude-a",
                                    headers=owner)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "last_owner"


async def test_deleting_a_board_is_never_triggered_by_deleting_a_room(tmp_path):
    """刪房只解除掛接；板要被刪必須是**對著板本身下的決定**（§3.2）。

    否則使用者刪掉一間聊完的對話，會連同整份工作紀錄一起消失。
    """
    app, client = await _client(tmp_path, "v2_delete")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            # 板掛在兩間房上：刪掉 A 之後卡要搬到 B，不能跟著消失
            rb = await _room(client, "B房", "claude-a")
            await _join(client, rb, "claude-a", "A")
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=owner)

            r = await client.delete(f"/api/rooms/{rid}", headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["deleted"]["board_items_kept"] >= 1
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert len(body["tasks"]) == 1, "刪房把板上的卡帶走了"
            # provenance 留著：那間房已經不在了，快照是唯一講得出來的東西
            assert body["tasks"][0]["source_room_id"] in ("", rid)

            r = await client.delete(f"/api/boards/{bid}", headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["deleted"]["board"] == 1
            r = await client.get(f"/api/boards/{bid}", headers=owner)
            assert r.status_code == 404


async def test_board_admin_actions_require_owner(tmp_path):
    app, client = await _client(tmp_path, "v2_admin_acl")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            other = await _join(client, rid, "claude-b", "B")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "B 的卡"}, headers=other)   # 成 editor

            for method, path, payload in [
                ("patch", f"/api/boards/{bid}", {"name": "我要改名"}),
                ("post", f"/api/boards/{bid}/archive", None),
                ("post", f"/api/boards/{bid}/members",
                 {"actor_key": "claude-c"}),
                ("delete", f"/api/boards/{bid}", None),
            ]:
                call = getattr(client, method)
                r = (await call(path, json=payload, headers=other)
                     if payload is not None else
                     await call(path, headers=other))
                assert r.status_code == 403, f"{method} {path} 讓 editor 過了"
                assert r.json()["detail"]["code"] == "not_board_owner"


async def test_reorder_from_the_board(tmp_path):
    """批次排序（board-scoped）：**整批只領一個號**。

    每列各領一個的話，拖十張卡在增量流裡會變成十次獨立變更，而它們本來
    就是同一個動作。
    """
    app, client = await _client(tmp_path, "v2_reorder")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            t2 = (await client.post(f"/api/boards/{bid}/tasks",
                                    json={"title": "第二張"},
                                    headers=hdr)).json()["id"]
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            t1 = [t["id"] for t in body["tasks"] if t["id"] != t2][0]
            before = body["board_seq"]

            r = await client.post(
                f"/api/boards/{bid}/reorder",
                json={"kind": "task",
                      "items": [{"id": t2, "order_index": 0},
                                {"id": t1, "order_index": 1}]},
                headers=hdr)
            assert r.status_code == 200, r.text
            assert r.json()["count"] == 2
            assert r.json()["board_seq"] == before + 1, "整批不只領了一個號"

            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            order = {t["id"]: t["order_index"] for t in body["tasks"]}
            assert order[t2] == 0 and order[t1] == 1

            # 不屬於這塊板的卡：整批不套用，不是部分成功
            r = await client.post(
                f"/api/boards/{bid}/reorder",
                json={"kind": "task",
                      "items": [{"id": t1, "order_index": 5},
                                {"id": "不存在的卡", "order_index": 6}]},
                headers=hdr)
            assert r.status_code == 404
            assert r.json()["detail"]["code"] == "board_item_not_found"
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert {t["id"]: t["order_index"]
                    for t in body["tasks"]}[t1] == 1, "部分套用了"


async def test_directive_reaches_every_room_the_target_is_in(tmp_path):
    """一塊板掛兩房、目標兩房都在：**兩房都要收到**。

    原本只投最近活躍的那一間，@測試Novia 的 T5-4 抓到它是漏送——agent 待在
    房 A、directive 投到房 B，於是它永遠不會醒，而送出端看到的是 200、
    稽核串也有紀錄。**漏送從送出端完全看不出來。**

    判準：去重要去的是「同一個人被通知多次」，不是「同一個人只在其中一個房
    被通知」。所以去重的單位是房，不是人。
    """
    app, client = await _client(tmp_path, "v2_directive_all")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            owner = await _join(client, ra, "claude-a", "A")
            await _first_card(client, ra, owner)
            bid = await _board_id(client, ra, owner)
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=owner)
            owner_b = await _join(client, rb, "claude-a", "A")

            # 目標在兩間房，而且兩房用不同名字
            await _join(client, ra, "claude-w", "Worker-在A")
            await _join(client, rb, "claude-w", "Worker-在B")

            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"target_actor_key": "claude-w", "text": "兩邊都要看到"},
                headers=owner)
            assert r.status_code == 200, r.text
            assert set(r.json()["delivered_rooms"]) == {ra, rb}

            for rid, name, hdr in ((ra, "Worker-在A", owner),
                                   (rb, "Worker-在B", owner_b)):
                msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                         headers=hdr)).json()["messages"]
                hit = [m for m in msgs
                       if m["system_event"] == "board_directive"]
                assert len(hit) == 1, f"{rid} 沒收到 directive"
                # mention 用**該房的**名字，不是板上的定案名——比對的是
                # 房內名稱，用板上那個會 mention 不到人
                assert hit[0]["mentions"] == [name]

            # 稽核串仍然只有一筆：投了兩個房不代表發生了兩件事
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert len(body["directives"]) == 1


async def test_one_change_makes_one_event_however_many_rooms(tmp_path):
    """驗收 8：一次 Board 變更只有一筆 canonical event，掛三房不變三筆。"""
    app, client = await _client(tmp_path, "v2_one_event")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            owner = await _join(client, ra, "claude-a", "A")
            tid = await _first_card(client, ra, owner)
            bid = await _board_id(client, ra, owner)
            await client.post(f"/api/boards/{bid}/rooms/{rb}", headers=owner)

            await client.post(f"/api/board/tasks/{tid}/claim", headers=owner)
            for step in ("in_progress", "done"):
                await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": step}, headers=owner)

            rows = await (await app.state.db.execute(
                "SELECT event_type, COUNT(*) AS n FROM board_event"
                " WHERE board_id=? GROUP BY event_type", (bid,))).fetchall()
            counts = {r["event_type"]: r["n"] for r in rows}
            assert counts.get("task_claimed") == 1
            assert counts.get("task_done") == 1


async def test_editing_a_detached_card_does_not_conjure_a_new_board(tmp_path):
    """改一張**已解除掛接**的卡，不能在舊房靜默長出一塊新板。

    `_ensure_board_for_room` 原本掛在所有寫入的共同門檻上，於是改卡時會走到
    「這個房沒有板 → 建一塊」——改的是原板的卡、推進的是新板的 seq，原板
    水位不動，通知與 delta 契約當場分裂（審核用Codex 2026-09-02 實測）。

    分界是：**建卡需要「房要有板」，改卡不需要——卡自己已經有 board_id。**
    """
    app, client = await _client(tmp_path, "v2_detached_edit")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            tid = await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)

            db = app.state.db
            before = (await (await db.execute(
                "SELECT COUNT(*) AS n FROM board")).fetchone())["n"]
            seq_before = (await (await db.execute(
                "SELECT board_seq FROM board WHERE id=?", (bid,))).fetchone()
            )["board_seq"]

            r = await client.patch(f"/api/board/tasks/{tid}",
                                   json={"title": "改個標題"}, headers=hdr)
            assert r.status_code == 200, r.text

            after = (await (await db.execute(
                "SELECT COUNT(*) AS n FROM board")).fetchone())["n"]
            assert after == before, "改卡的時候長出了一塊新板"
            row = await (await db.execute(
                "SELECT board_id, title, board_seq FROM board_task WHERE id=?",
                (tid,))).fetchone()
            assert row["board_id"] == bid, "卡被搬到別塊板上了"
            assert row["title"] == "改個標題"
            seq_after = (await (await db.execute(
                "SELECT board_seq FROM board WHERE id=?", (bid,))).fetchone()
            )["board_seq"]
            assert seq_after > seq_before, "推進的是別塊板的水位"
            assert row["board_seq"] == seq_after


async def test_an_archived_board_is_read_only_from_the_room_path_too(tmp_path):
    """封存的板一律唯讀，**v1 的 room 路徑也不例外**。

    漏了這道閘，那條路就成了繞過封存的後門——而封存在畫面上看起來是生效的。
    """
    app, client = await _client(tmp_path, "v2_archived_room_path")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            hdr = await _join(client, rid, "claude-a", "A")
            tid = await _first_card(client, rid, hdr)
            bid = await _board_id(client, rid, hdr)
            r = await client.post(f"/api/boards/{bid}/archive", headers=hdr)
            assert r.status_code == 200, r.text

            for method, path, payload in [
                ("patch", f"/api/board/tasks/{tid}", {"title": "還想改"}),
                ("post", f"/api/board/tasks/{tid}/status",
                 {"status": "in_progress"}),
                ("post", f"/api/board/tasks/{tid}/claim", None),
                ("delete", f"/api/board/tasks/{tid}", None),
            ]:
                call = getattr(client, method)
                r = (await call(path, json=payload, headers=hdr)
                     if payload is not None else await call(path, headers=hdr))
                assert r.status_code == 409, f"{method} {path} 繞過了封存"
                assert r.json()["detail"]["code"] == "board_archived"
                # 被擋下的回應裡要講得出是哪塊板——那是唯一還拿得到的線索
                assert r.json()["detail"]["board_id"] == bid


async def test_attach_can_import_the_rooms_members(tmp_path):
    """§3.1 的可用性出口：掛接時 owner 可以把這間房現在的人帶進板。

    A+ 的另一半。只做收緊不做匯入的話，房裡除了建板者沒有人用得了板，
    而 owner 手上唯一的工具需要 `actor_key`——那個值房內看不到。
    """
    app, client = await _client(tmp_path, "v2_import")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            owner = await _join(client, ra, "claude-a", "A")
            await _first_card(client, ra, owner)
            bid = await _board_id(client, ra, owner)

            # B 房裡有兩個人，掛接時把他們一起帶進來
            await _join(client, rb, "claude-a", "A")
            await _join(client, rb, "claude-x", "X")
            await _join(client, rb, "claude-y", "Y")
            r = await client.post(
                f"/api/boards/{bid}/rooms/{rb}?import_members=true",
                headers=owner)
            assert r.status_code == 200, r.text
            assert set(r.json()["imported_members"]) == {"claude-x", "claude-y"}

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            roles = {m["actor_key"]: m["role"] for m in body["members"]}
            assert roles["claude-x"] == "editor"
            assert roles["claude-y"] == "editor"
            assert roles["claude-a"] == "owner", "既有成員的角色被覆寫了"

            # 帶進來的人現在寫得動板了
            x = {"X-Participant-Id": (await client.post(
                f"/api/rooms/{rb}/join",
                json={"kind": "claude", "session_key": "claude-x",
                      "preferred_name": "X"})).json()["participant_id"]}
            r = await client.post(f"/api/rooms/{rb}/board/tasks",
                                  json={"title": "X 寫得動了"}, headers=x)
            assert r.status_code == 200, r.text


async def test_import_on_an_already_attached_room(tmp_path):
    """已經掛著同一塊板時，匯入**照樣要生效**。

    App 建新板的流程是：先 `POST /api/boards` 帶 origin_room_id（那時就掛
    好了），再回頭要求匯入。早退的話那個勾選會靜靜沒有效果
    （審核用Codex 2026-09-02）。
    """
    app, client = await _client(tmp_path, "v2_import_again")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _join(client, rid, "claude-z", "Z")
            r = await client.post("/api/boards",
                                  json={"name": "新板", "origin_room_id": rid},
                                  headers=owner)
            bid = r.json()["id"]

            r = await client.post(
                f"/api/boards/{bid}/rooms/{rid}?import_members=true",
                headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["already_attached"] is True
            assert "claude-z" in r.json()["imported_members"], "勾了卻沒生效"


async def test_import_never_downgrades_an_existing_member(tmp_path):
    """匯入**不覆寫**既有成員的角色。

    會覆寫的話，勾一下就可能把某個 owner 降成 editor——而使用者不會預期
    一個叫「匯入」的動作會降級任何人。
    """
    app, client = await _client(tmp_path, "v2_import_no_downgrade")
    async with client:
        async with app.router.lifespan_context(app):
            ra = await _room(client, "A房", "claude-a")
            rb = await _room(client, "B房", "claude-a")
            owner = await _join(client, ra, "claude-a", "A")
            await _first_card(client, ra, owner)
            bid = await _board_id(client, ra, owner)
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-b", "role": "owner"},
                              headers=owner)

            await _join(client, rb, "claude-a", "A")
            await _join(client, rb, "claude-b", "B")
            r = await client.post(
                f"/api/boards/{bid}/rooms/{rb}?import_members=true",
                headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["imported_members"] == [], "既有成員被當成新的匯入"

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            roles = {m["actor_key"]: m["role"] for m in body["members"]}
            assert roles["claude-b"] == "owner", "owner 被降成 editor 了"


async def test_library_can_filter_by_status(tmp_path):
    """`?status=`：App 的「進行中／已封存」切換一直有送它。

    Hub 從來沒宣告這個參數 ⇒ FastAPI 靜默忽略、SQL 也沒有 WHERE ⇒
    **兩邊都不報錯，篩選就是沒有作用**（審核用Codex 2026-09-02）。
    """
    app, client = await _client(tmp_path, "v2_status_filter")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-a"}
            live = (await client.post("/api/boards", json={"name": "還在跑"},
                                      headers=key)).json()["id"]
            gone = (await client.post("/api/boards", json={"name": "收工了"},
                                      headers=key)).json()["id"]
            await client.post(f"/api/boards/{gone}/archive", headers=key)

            both = (await client.get("/api/boards", headers=key)).json()
            assert {b["id"] for b in both["boards"]} == {live, gone}

            r = await client.get("/api/boards?status=active", headers=key)
            assert [b["id"] for b in r.json()["boards"]] == [live]
            r = await client.get("/api/boards?status=archived", headers=key)
            assert [b["id"] for b in r.json()["boards"]] == [gone]

            # 打錯字要擋下來——默默回全部會讓人以為「那塊板不見了」
            r = await client.get("/api/boards?status=活著的", headers=key)
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "invalid_status"


async def test_a_directive_with_no_target_speaks_to_the_whole_board(tmp_path):
    """空的 target ＝對整塊板說（艾斯維爾 2026-09-02）。

    不是每一則 Supervisor 的判斷都針對某個人——「這個方向要改」是說給板上
    所有人聽的。UI 早就做好那個介面，而 Hub 這側原本必填、送出去一律 422。

    **收件人是板的成員，不是房裡的所有人**：一個剛好在場、卻不屬於這塊板
    的人被叫醒也沒有意義，他對這塊板一無所知。
    """
    app, client = await _client(tmp_path, "v2_broadcast")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            # worker 在建板之後才進房 ⇒ 不是板成員，要 owner 明示加入
            await _join(client, rid, "claude-w", "Worker")
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-w", "role": "editor"},
                              headers=owner)
            # 這一位也在房裡，但**不是**板成員——他不該被叫醒
            await _join(client, rid, "claude-out", "路過的")

            r = await client.post(
                f"/api/boards/{bid}/directives",
                json={"text": "這個方向要改"}, headers=owner)
            assert r.status_code == 200, r.text
            assert r.json()["delivered"] is True

            msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                     headers=owner)).json()["messages"]
            hit = [m for m in msgs if m["system_event"] == "board_directive"]
            assert len(hit) == 1
            assert hit[0]["mentions"] == ["Worker"], "叫醒了不屬於這塊板的人"

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=owner)).json()
            assert body["directives"][0]["to_actor_key"] == "", "廣播不該有收件人"


async def test_a_loose_task_on_a_board_with_no_room_does_not_crash(tmp_path):
    """🚨 零掛接房的板上「隨手記一件事」不能 500。

    `_board_writer_v2` 在沒有掛接房時給的是**空的 provenance room**，而
    `_uncategorised_checklist` 拿它去 `_next_board_seq("")`：
    `UPDATE room WHERE id=''` 什麼都沒更新 → `RETURNING` 回 None →
    `row["board_seq"]` ⇒ `TypeError: 'NoneType' object is not subscriptable`
    ⇒ 500（@開發Novia (除錯) 2026-09-03 D9 的現場）。

    ⚠️ 一塊還沒掛上任何房的板**本來就該能先把要做的事寫下來**——那是
    `_board_writer_v2` 註解裡寫著的設計意圖，只是領號那一步沒跟上。
    """
    app, client = await _client(tmp_path, "noroomloose")
    async with client:
        async with app.router.lifespan_context(app):
            key = {"X-Session-Key": "claude-a"}
            bid = (await client.post("/api/boards", json={"name": "還沒掛房的板"},
                                     headers=key)).json()["id"]
            r = await client.post(f"/api/boards/{bid}/tasks",
                                  json={"title": "隨手記一件事"}, headers=key)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=key)).json()
            assert [t["title"] for t in body["tasks"]] == ["隨手記一件事"]


# ── 掛接房的成員自動算板成員（艾斯維爾 2026-09-03 推翻明示匯入）──────

async def test_being_in_an_attached_room_is_enough_to_work_on_the_board(
        tmp_path):
    """掛接房的 active 成員自動是板的 editor。

    🚨 09/02 裁決過「房裡的人不會自動變成板上的人，要 owner 明示匯入」，
    而今天那條裁決的直接後果是：**在 B 房沒辦法接 A 房帶過來的卡**——
    沒被手動加進板的人一律 403，跟他在哪間房無關。艾斯維爾 2026-09-03：
    「在 A 聊天室接那塊板的人，跟在 B 聊天室要接那塊板的人理論上被視為
    不同的實體，所以這樣的接手應該要沒有問題才對」。

    連帶解掉的還有「agent 換一個 session 就對自己昨天的板變成陌生人」：
    `board_member` 綁 session_key，而 session_key 每個 session 都會換。
    重新進房就又算數了，不必另外做跨 session 的穩定身分。
    """
    app, client = await _client(tmp_path, "room-member-is-board-member")
    async with client:
        async with app.router.lifespan_context(app):
            a_room = await _room(client)
            a = await _join(client, a_room, "claude-a", "A")
            await _first_card(client, a_room, a)
            bid = await _board_id(client, a_room, a)

            # B 房掛同一塊板。裡面的人從來沒被加進 board_member
            b_room = await _room(client)
            b = await _join(client, b_room, "claude-b", "B")
            r = await client.post(f"/api/boards/{bid}/rooms/{b_room}",
                                  headers={**a, "X-Session-Key": "claude-a"})
            assert r.status_code == 200, r.text

            body = await client.get(f"/api/boards/{bid}",
                                    headers={**b, "X-Session-Key": "claude-b"})
            assert body.status_code == 200, "B 房的人連看都看不到"
            assert body.json()["my_role"] == "editor"

            task = next(t for t in body.json()["tasks"])
            claimed = await client.post(f"/api/board/tasks/{task['id']}/claim",
                                        headers=b)
            assert claimed.status_code == 200, claimed.text


async def test_an_explicit_viewer_is_not_promoted_by_being_in_the_room(
        tmp_path):
    """明示指定的角色優先——被指成 viewer 的人不會因為在房裡就升級。

    退路只補「查不到」的情形。蓋過明示角色的話，降權就變成一件做不到的
    事，而做這個降權的人不會收到任何提示。
    """
    app, client = await _client(tmp_path, "explicit-viewer-wins")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, a)
            bid = await _board_id(client, rid, a)

            eye = await _join(client, rid, "claude-eye", "旁觀")
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-eye",
                                    "role": "viewer", "display_name": "旁觀",
                                    "actor_kind": "claude"},
                              headers={**a, "X-Session-Key": "claude-a"})

            body = (await client.get(
                f"/api/boards/{bid}",
                headers={**eye, "X-Session-Key": "claude-eye"})).json()
            assert body["my_role"] == "viewer"
            task = body["tasks"][0]
            r = await client.post(f"/api/board/tasks/{task['id']}/claim",
                                  headers=eye)
            assert r.status_code == 403


async def test_finishing_an_orphaned_card_does_not_leave_it_orphaned(tmp_path):
    """收尾一張孤兒卡要把孤兒狀態一起收掉。

    🚨 `done` ∧ `orphaned` 是一個**沒有出口的矛盾狀態**：`claim` 的 CAS 條件
    有 `status NOT IN ('done','cancelled')` ⇒ UPDATE 恆回 0 列 ⇒ 永遠 409，
    誰都接不了；而畫面上它還掛著「沒人在做」。

    「已收尾的卡不孤兒化」這條規則原本只擋了 `_orphan_claims` 的入口，沒擋
    **先孤兒、後完成**這個順序；修復又只跑在開機路徑（`_heal_settled_orphans`）
    ⇒ 重啟前它是永久的（@開發Novia (除錯) 2026-09-03 DB 實證）。
    """
    app, client = await _client(tmp_path, "done-not-orphan")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            human = await _join(client, rid, "human-1", "艾斯維爾",
                                role="human")
            bot = await _join(client, rid, "claude-bot", "諾薇亞")
            tid = await _first_card(client, rid, human)
            await client.post(f"/api/board/tasks/{tid}/claim", headers=bot)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=bot)
            # 持有者離房 ⇒ 卡被孤兒化
            await client.post(f"/api/rooms/{rid}/leave", headers=bot)
            bid = await _board_id(client, rid, human)
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=human)).json()
            card = next(t for t in body["tasks"] if t["id"] == tid)
            assert card["claim_state"] == "orphaned"

            r = await client.post(f"/api/board/tasks/{tid}/status",
                                  json={"status": "done"}, headers=human)
            assert r.status_code == 200, r.text

            body = (await client.get(f"/api/boards/{bid}",
                                     headers=human)).json()
            card = next(t for t in body["tasks"] if t["id"] == tid)
            assert card["status"] == "done"
            assert card["claim_state"] != "orphaned", (
                "完成了、而且沒人在做——這個組合自相矛盾，而且接不回來")


async def test_a_board_with_no_attached_room_still_answers_to_its_members(
        tmp_path):
    """零掛接的板不會因為沒有房就把 owner 鎖在外面。

    ⚠️ `_board_role` 的房內身分退路來源是「任一未解除掛接房的 active
    成員」——板沒掛任何房時那個來源是空的。退路一旦被誤寫成**取代**明示
    成員（而不是補在後面），這種板就對所有人 403，包括建立它的人。
    剛好撞上 #2 確認的「未綁房不該唯讀」，所以這條界線要有測試釘住
    （@開發Novia (除錯) 2026-09-03）。
    """
    app, client = await _client(tmp_path, "zero-attach-role")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=owner)

            body = await client.get(f"/api/boards/{bid}", headers=owner)
            assert body.status_code == 200
            assert body.json()["my_role"] == "owner"
            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "沒房也寫得下"}, headers=owner)
            assert r.status_code == 200, r.text

            # 但退路的來源沒了 ⇒ 只在房裡的人現在什麼都不是
            await _join(client, rid, "claude-b", "B")
            out = await client.get(f"/api/boards/{bid}",
                                   headers={"X-Session-Key": "claude-b"})
            assert out.status_code == 403


async def test_leaving_the_room_takes_the_board_access_with_it(tmp_path):
    """離開房間的當下就失去這塊板的存取權（艾斯維爾 2026-09-03）。

    「被邀請進聊天室就自動拿到板的編輯權，**對方離開之後就不再有存取權**」
    ——後半這件事是 `_board_role` 退路裡 `p.status='active'` 那個條件在擔的。
    它沒有自己的測試：拿掉條件的話前面那些「房裡的人接得動卡」照樣全綠，
    而**退路會變成永久授權**，離了房、被踢了都還寫得動。

    明示成員不受影響——他們的權限來源是 `board_member`，不是在不在房裡。
    """
    app, client = await _client(tmp_path, "leave-revokes")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)

            guest = await _join(client, rid, "claude-guest", "客人")
            gkey = {"X-Session-Key": "claude-guest"}
            assert (await client.get(f"/api/boards/{bid}",
                                     headers=gkey)).status_code == 200

            await client.post(f"/api/rooms/{rid}/leave", headers=guest)

            gone = await client.get(f"/api/boards/{bid}", headers=gkey)
            assert gone.status_code == 403, "離房之後還看得到這塊板"
            assert gone.json()["detail"]["code"] == "not_board_member"

            # owner 是明示成員，權限不隨在不在房裡變動
            await client.post(f"/api/rooms/{rid}/leave", headers=owner)
            still = await client.get(f"/api/boards/{bid}",
                                     headers={"X-Session-Key": "claude-a"})
            assert still.status_code == 200
            assert still.json()["my_role"] == "owner"


async def test_an_archived_room_no_longer_counts_as_being_in_it(tmp_path):
    """封存的房不算「你還在裡面」（艾斯維爾 2026-09-03：只是曾經存在）。

    退路的 SQL 原本只看 `board_room.detached_at IS NULL` 與 participant 的
    status，**沒有看房本身是不是還活著**；而封存一間房完全不碰 `participant`
    ⇒ 房封存了，裡面的人照樣是 active ⇒ 存取權永久保留。
    agent 會被 sweeper 掃掉而自然失效，**人類永遠不會**
    （@開發Novia (除錯) 2026-09-03，活庫查到 8 列這種狀態）。

    對照組 `_live_room_count` 早就寫對了——同一份判準兩處寫得不一樣。
    """
    app, client = await _client(tmp_path, "archived-room-no-access")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            guest = await _join(client, rid, "human-g", "客人", role="human")
            gkey = {"X-Session-Key": "human-g"}
            assert (await client.get(f"/api/boards/{bid}",
                                     headers=gkey)).status_code == 200

            r = await client.post(f"/api/rooms/{rid}/archive", headers=owner)
            assert r.status_code == 200, r.text

            gone = await client.get(f"/api/boards/{bid}", headers=gkey)
            assert gone.status_code == 403, "房封存了他還在裡面"

            # owner 不受影響——他的權限來源是 board_member
            assert (await client.get(
                f"/api/boards/{bid}",
                headers={"X-Session-Key": "claude-a"})).status_code == 200


async def test_a_removed_member_cannot_walk_back_in_through_the_room(tmp_path):
    """被移出板的人，即使還在掛接房裡也回不來。

    🚨 退路的邏輯是「明示查不到 ⇒ 走退路」，而 `removed_at IS NOT NULL`
    在第一段查詢眼裡**就等於查不到** ⇒ 被移除的成員只要還在房裡是 active，
    立刻以 editor 身分回來。降成 viewer 擋得住、整個移除反而擋不住
    （@開發Novia (除錯) 2026-09-03；這是 `removed_at IS NULL` 補上去之後
    才成立的組合，兩件事單獨看都對）。

    更難看的是它**沒有任何畫面會揭露**：`remove_board_member` 回 200、
    卡也孤兒化了、`list_boards` 也把板從他清單拿掉 ⇒ **看不到，但寫得動**。
    """
    app, client = await _client(tmp_path, "removed-cannot-return")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            bad = await _join(client, rid, "claude-bad", "被移除的")
            bkey = {"X-Session-Key": "claude-bad"}
            # 先成為明示成員，才有得移除
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-bad", "role": "editor",
                                    "display_name": "被移除的",
                                    "actor_kind": "claude"},
                              headers={**owner, "X-Session-Key": "claude-a"})
            assert (await client.get(f"/api/boards/{bid}",
                                     headers=bkey)).status_code == 200

            r = await client.request(
                "DELETE", f"/api/boards/{bid}/members/claude-bad",
                headers={**owner, "X-Session-Key": "claude-a"})
            assert r.status_code == 200, r.text

            # 他**還在房裡**（沒有離開），但不該因此回來
            back = await client.get(f"/api/boards/{bid}", headers=bkey)
            assert back.status_code == 403, "被移除的人從房間那條路走回來了"
            assert back.json()["detail"]["code"] == "not_board_member"

            wrote = await client.post(f"/api/rooms/{rid}/board/tasks",
                                      json={"title": "我又回來了"}, headers=bad)
            assert wrote.status_code == 403, "看不到卻寫得動，是最糟的組合"


async def test_objectives_can_be_created_on_the_board_axis(tmp_path):
    """週期也要能從板軸建。

    其他寫入端點（checklist / task / status / claim / release）**全部是
    `/api/board/...` 板軸**，只有新增週期是房軸
    （`/api/rooms/{rid}/board/objectives`）⇒ 從 Board Library 進來、或一塊
    還沒掛任何房的板，就是少了這一個入口
    （@開發Novia (UI) 2026-09-03）。而「顯式建一塊板」剛上線之後，
    零掛接板是**正常狀態**不是邊界案例。
    """
    app, client = await _client(tmp_path, "objective-board-axis")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            owner = await _join(client, rid, "claude-a", "A")
            await _first_card(client, rid, owner)
            bid = await _board_id(client, rid, owner)
            akey = {**owner, "X-Session-Key": "claude-a"}
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=akey)

            r = await client.post(f"/api/boards/{bid}/objectives",
                                  json={"title": "沒房也開得了週期"},
                                  headers=akey)
            assert r.status_code == 200, r.text
            body = (await client.get(f"/api/boards/{bid}", headers=akey)).json()
            assert "沒房也開得了週期" in {o["title"] for o in body["objectives"]}

            # 同一道門：viewer 寫不進去
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-eye", "role": "viewer",
                                    "display_name": "旁觀",
                                    "actor_kind": "claude"}, headers=akey)
            no = await client.post(f"/api/boards/{bid}/objectives",
                                   json={"title": "旁觀者想寫"},
                                   headers={"X-Session-Key": "claude-eye"})
            assert no.status_code == 403
