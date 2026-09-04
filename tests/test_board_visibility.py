"""板的公開／私人，以及 BOARDS 分頁上「誰看得到什麼」。

艾斯維爾 2026-09-03 的規則，翻成可判定的形式：

- **owner 永遠有完整權限**，與掛接狀態、在不在房裡都無關
- 其餘人的資格**完全動態**：以現存（未封存）掛接房的 active 成員為準
- BOARDS 分頁常駐 ＝ 自己 owner 的板 ∪ 別人的**公開**板（且我在某個現存
  掛接房裡）。別人的**私人板永不進分頁**，只能從聊天室路徑進
- 私人板只能掛進**私人房**（「只能放在自己開的私人聊天室」；「自己開的」
  那一半由既有的房管理者檢查擔，這裡不重複）

🚨 這份檔案守的是**兩個死欄位被喚醒**的那一刻：`board.visibility` 與
`board.owner_actor_key` schema 裡都早就有，卻從來沒有被讀過。死欄位一旦
開始生效，語意錯了不會有任何地方報錯——只會有人的板從畫面上消失。
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


async def _room(client, name="房", who="claude-a", visibility="public"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": who,
        "visibility": visibility})).json()["id"]


async def _join(client, rid, who, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": who,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": who}


async def _board(client, hdr, name="板", visibility="public", room=""):
    body = {"name": name, "visibility": visibility}
    if room:
        body["origin_room_id"] = room
    r = await client.post("/api/boards", json=body, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _library(client, hdr):
    r = await client.get("/api/boards", headers=hdr)
    assert r.status_code == 200, r.text
    return {b["id"] for b in r.json()["boards"]}


async def test_the_owner_keeps_full_rights_without_any_room(tmp_path):
    """owner 永遠是 owner——換 session、板沒掛房、他不在任何房裡都一樣。

    🚨 `board.owner_actor_key` 一直是**死欄位**（只寫不讀），owner 的權限
    完全靠 `board_member` 那一列。而 board_member 綁 actor_key ⇒ owner 換一
    個 session 就對不上 ⇒ 落到房內身分退路 ⇒ **降級成 editor**；板要是沒掛
    房，退路也沒有來源 ⇒ **對自己的板完全沒權限**
    （@開發Novia (除錯) 2026-09-03）。

    而「BOARDS 分頁開一塊板」建出來的板本來就沒掛任何房——這條路徑天天走。
    """
    app, client = await _client(tmp_path, "owner-always")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            me = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, me)          # 不掛任何房

            body = await client.get(f"/api/boards/{bid}", headers=me)
            assert body.status_code == 200
            assert body.json()["my_role"] == "owner"

            # 離開唯一那間房——板本來就沒掛它，權限不該有任何變化
            await client.post(f"/api/rooms/{rid}/leave", headers=me)
            after = await client.get(f"/api/boards/{bid}",
                                     headers={"X-Session-Key": "claude-a"})
            assert after.status_code == 200
            assert after.json()["my_role"] == "owner"
            assert bid in await _library(client,
                                         {"X-Session-Key": "claude-a"})


async def test_the_library_shows_my_boards_and_other_peoples_public_ones(
        tmp_path):
    """分頁常駐 ＝ 自己的板 ∪ 別人的公開板（且我在某個現存掛接房裡）。"""
    app, client = await _client(tmp_path, "library-source")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, who="claude-a")
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")

            mine = await _board(client, b, "B 自己的")
            shared = await _board(client, a, "公開板", room=rid)
            secret = await _board(client, a, "私人板", visibility="private")

            seen = await _library(client, b)
            assert mine in seen, "自己 owner 的板不在分頁上"
            assert shared in seen, "同房的公開板看不到"
            assert secret not in seen, "別人的私人板出現在分頁上了"

            # 離開房 ⇒ 別人的公開板從分頁消失，自己的留著
            await client.post(f"/api/rooms/{rid}/leave", headers=b)
            seen = await _library(client, {"X-Session-Key": "claude-b"})
            assert shared not in seen
            assert mine in seen


async def test_a_private_board_is_still_reachable_from_the_room(tmp_path):
    """私人板不進分頁，但**房裡的人進得去**——不可見不等於沒有權限。"""
    app, client = await _client(tmp_path, "private-via-room")
    async with client:
        async with app.router.lifespan_context(app):
            # 先公開讓人進來再鎖起來——私人房本來就不能自行加入，
            # 而這條測的是「已經在裡面的人」看不看得到
            rid = await _room(client, who="claude-a")
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")
            lock = await client.post(f"/api/rooms/{rid}/visibility",
                                     json={"visibility": "private"}, headers=a)
            assert lock.status_code == 200, lock.text
            bid = await _board(client, a, "私人板", visibility="private")
            r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=a)
            assert r.status_code == 200, r.text

            assert bid not in await _library(client, b)
            got = await client.get(f"/api/boards/{bid}", headers=b)
            assert got.status_code == 200, "房裡的人連私人板都進不去"
            assert got.json()["my_role"] == "editor"


async def test_a_private_board_only_goes_into_a_private_room(tmp_path):
    """私人板只能掛進私人房。

    「自己開的」那一半由既有的房管理者檢查擔（`attach_board` 已經要求
    是房的建立者），這裡守的是**剩下那一半**：自己開的**公開**房也不行。
    """
    app, client = await _client(tmp_path, "private-needs-private-room")
    async with client:
        async with app.router.lifespan_context(app):
            open_room = await _room(client, "公開房", "claude-a", "public")
            a = await _join(client, open_room, "claude-a", "A")
            bid = await _board(client, a, "私人板", visibility="private")

            no = await client.post(f"/api/boards/{bid}/rooms/{open_room}",
                                   headers=a)
            assert no.status_code == 409
            assert no.json()["detail"]["code"] == "private_board_public_room"

            # 公開板掛公開房沒問題
            pub = await _board(client, a, "公開板")
            ok = await client.post(f"/api/boards/{pub}/rooms/{open_room}",
                                   headers=a)
            assert ok.status_code == 200, ok.text


async def test_boards_from_before_this_feature_are_public(tmp_path):
    """存量板一律遷成 `public`（艾斯維爾 2026-09-03：「現有的板都是以公開為主」）。

    🚨 欄位的 schema 預設是 `private`，而**它到今天為止都沒有作用** ⇒ 現有
    的板在資料庫裡真的存著 `private`（活庫實查確認）。功能一開那個值立刻
    生效 ⇒ 所有既有的板從所有人的分頁消失，只剩建立者看得到，而且沒有任何
    地方會報錯。
    """
    from chatroom_server.db import open_db

    path = str(tmp_path / "legacy.db")
    db = await open_db(path)
    await db.execute(
        "INSERT INTO board (id, name, description, status, visibility,"
        " owner_actor_key, board_seq, created_at, updated_at)"
        " VALUES ('old','舊板','','active','private','claude-a',0,'t','t')")
    # 倒回功能上線之前的版次——這塊板就是那時候建的
    await db.execute("PRAGMA user_version=0")
    await db.commit()
    await db.close()

    # 再開一次＝升級一次。遷移要把它改成 public，而且**冪等**
    for _ in range(2):
        db = await open_db(path)
        row = await (await db.execute(
            "SELECT visibility FROM board WHERE id='old'")).fetchone()
        assert row["visibility"] == "public"
        await db.close()


# ── owner 的轉移與接管（裁定Novia 2026-09-03，照房間那兩條抄）──────────

async def test_the_owner_can_hand_the_board_to_someone_else(tmp_path):
    """現任 owner 把板交給別人（對應房間的 `transfer_admin`）。

    只做接管不做交棒的話，**活著的 owner 想主動交棒得先把自己弄死**。
    """
    app, client = await _client(tmp_path, "board-transfer")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")
            bid = await _board(client, a, room=rid)

            no = await client.post(f"/api/boards/{bid}/owner",
                                   json={"target_actor_key": "claude-b"},
                                   headers=b)
            assert no.status_code == 403, "非 owner 也交得出去"

            r = await client.post(f"/api/boards/{bid}/owner",
                                  json={"target_actor_key": "claude-b"},
                                  headers=a)
            assert r.status_code == 200, r.text

            assert (await client.get(f"/api/boards/{bid}",
                                     headers=b)).json()["my_role"] == "owner"
            # 交出去的人不會變成陌生人——他還在房裡，所以還是 editor
            assert (await client.get(f"/api/boards/{bid}",
                                     headers=a)).json()["my_role"] == "editor"


async def test_the_host_can_take_over_a_board_whose_owner_is_gone(tmp_path):
    """owner 的身分死掉時，Hub 主持人接管（對應房間的 `claim_admin`）。

    🚨 這是艾斯維爾早上報的「永久孤兒」升了一層：當時是卡，這裡是**整塊板**。
    根因同一個——`session_key` 被當成永久身分用，而 agent 每開一個新 session
    就換一把。owner 專屬的六個操作（改公開/私人、指派 supervisor、加減成員、
    封存板）於是**沒有任何人做得到**（@開發Novia (除錯) 2026-09-03，活庫實證
    「Chatroom 開發 09/02」那塊板就是這個狀態）。

    「owner 永遠有完整權限」那條規則讓它更硬：權限牢牢綁在一把死掉的 key 上。
    規則對，但它預設 owner 是個活得下去的身分——**agent 的 session key 不是**。
    """
    app, client = await _client(tmp_path, "board-claim")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, who="claude-dead")
            dead = await _join(client, rid, "claude-dead", "昨天的我")
            bid = await _board(client, dead, room=rid)
            await client.post(f"/api/rooms/{rid}/leave", headers=dead)

            host = {"X-Session-Key": "human-host", "X-Host-View": "1"}
            plain = await client.post(f"/api/boards/{bid}/owner/claim",
                                      headers={"X-Session-Key": "human-host"})
            assert plain.status_code == 403, "沒有主持人視角也接管得了"

            r = await client.post(f"/api/boards/{bid}/owner/claim",
                                  headers=host)
            assert r.status_code == 200, r.text
            assert r.json()["changed"] is True

            got = await client.get(f"/api/boards/{bid}",
                                   headers={"X-Session-Key": "human-host"})
            assert got.json()["my_role"] == "owner"

            # 冪等：再按一次不該長得像錯誤
            again = await client.post(f"/api/boards/{bid}/owner/claim",
                                      headers=host)
            assert again.status_code == 200
            assert again.json()["changed"] is False


async def test_a_board_whose_owner_is_still_around_cannot_be_taken_over(
        tmp_path):
    """owner 還活著就接管不了——**板有沒有掛房與這件事無關**。

    🚨 迴歸測試。判準一度被寫成「owner 是不是某個**掛接房**的 active 成員」，
    那會把剛用「＋ 開一塊板」建出來的板判成無主：沒掛任何房是它**正常的
    初始狀態**，而 owner 三秒前才建它、人就在線上 ⇒ 主持人接管得走別人剛
    建好的私人板，而艾斯維爾的規則是「owner 無論如何都能編輯自己的板」
    （@開發Novia (除錯) 2026-09-03 攔下）。

    正確判準：`owner_actor_key` 這把 key 在**任何**現存未封存的房裡是不是
    active participant。
    """
    app, client = await _client(tmp_path, "owner-alive-no-claim")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, "剛建好的", visibility="private")

            host = {"X-Session-Key": "human-host", "X-Host-View": "1"}
            no = await client.post(f"/api/boards/{bid}/owner/claim",
                                   headers=host)
            assert no.status_code == 409, "主持人接管得走別人剛建好的板"
            detail = no.json()["detail"]
            assert detail["code"] == "board_has_owner"
            # 主持人要判斷得出「這個 owner 是 20 分鐘前還在，還是昨天之後
            # 就沒出現過」——兩者現在長得一模一樣
            assert detail["owner_display_name"] == "A"
            assert detail["owner_last_seen_at"]

            # owner 離開最後一間房 ⇒ 這把 key 到處都不是 active ⇒ 可接管
            await client.post(f"/api/rooms/{rid}/leave", headers=a)
            ok = await client.post(f"/api/boards/{bid}/owner/claim",
                                   headers=host)
            assert ok.status_code == 200, ok.text


async def test_an_owner_who_only_lives_in_an_archived_room_counts_as_gone(
        tmp_path):
    """owner 只在**封存房**裡 active ⇒ 算無主。

    由「封存的房只是曾經存在」（艾斯維爾 2026-09-03）直接推出來，不需要
    靠「限主持人所以可以放寬」來撐。
    """
    app, client = await _client(tmp_path, "owner-archived-only")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, room=rid)

            host = {"X-Session-Key": "human-host", "X-Host-View": "1"}
            assert (await client.post(f"/api/boards/{bid}/owner/claim",
                                      headers=host)).status_code == 409

            # 房封存，但他**沒有離開**——participant 仍是 active
            r = await client.post(f"/api/rooms/{rid}/archive", headers=a)
            assert r.status_code == 200, r.text

            ok = await client.post(f"/api/boards/{bid}/owner/claim",
                                   headers=host)
            assert ok.status_code == 200, ok.text
            assert ok.json()["had_owner"] is True


async def test_visibility_can_only_change_while_the_board_hangs_nowhere(
        tmp_path):
    """掛在任何現存非封存房上時，一律擋下改可見性（艾斯維爾 2026-09-03）。

    **不做自動解除掛接。** 公開改私人時順手把房解除掉的話，房裡的人會在
    沒有任何提示的情況下失去一塊他們正在用的板——那是一個看不見的副作用，
    而使用者按的只是「改成私人」。擋下來至少他知道自己要先做什麼。

    全部解除、或掛接房全封存之後才可改（封存的房只是曾經存在）。
    """
    app, client = await _client(tmp_path, "visibility-change")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")
            bid = await _board(client, a, room=rid)

            no = await client.post(f"/api/boards/{bid}/visibility",
                                   json={"visibility": "private"}, headers=a)
            assert no.status_code == 409
            detail = no.json()["detail"]
            assert detail["code"] == "board_still_attached"
            # 要說得出**是哪幾間房**擋著，否則使用者只知道「不行」
            assert detail["rooms"] == [{"id": rid, "name": "房"}]

            # 非 owner 更不行——即使板已經沒掛房
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=a)
            nope = await client.post(f"/api/boards/{bid}/visibility",
                                     json={"visibility": "private"}, headers=b)
            assert nope.status_code == 403

            ok = await client.post(f"/api/boards/{bid}/visibility",
                                   json={"visibility": "private"}, headers=a)
            assert ok.status_code == 200, ok.text
            assert ok.json()["visibility"] == "private"

            # 同值再送一次＝什麼都沒發生，不該長得像錯誤
            same = await client.post(f"/api/boards/{bid}/visibility",
                                     json={"visibility": "private"}, headers=a)
            assert same.status_code == 200
            assert same.json()["changed"] is False


async def test_an_archived_room_does_not_block_the_visibility_change(tmp_path):
    """掛接房全封存之後就改得動——封存的房「只是曾經存在」。"""
    app, client = await _client(tmp_path, "visibility-archived-room")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, room=rid)
            assert (await client.post(f"/api/boards/{bid}/visibility",
                                      json={"visibility": "private"},
                                      headers=a)).status_code == 409

            await client.post(f"/api/rooms/{rid}/archive", headers=a)

            ok = await client.post(f"/api/boards/{bid}/visibility",
                                   json={"visibility": "private"}, headers=a)
            assert ok.status_code == 200, ok.text


# ── 板軸：手上只有 session_key 也動得了卡 ────────────────────────────

async def test_cards_can_be_worked_on_with_only_a_session_key(tmp_path):
    """卡片端點要認 `X-Session-Key`，不能只認 `X-Participant-Id`。

    🚨 板軸**沒有房，也就沒有 participant_id**。Board Library 進來的 client
    手上只有 session_key ⇒ 那些畫面上一張卡都改不動，而
    `_actor_from_headers` 的 docstring 早就寫著「Board Library 沒有房，
    所以 session_key 是主要來源」——底層一直支援，是這批端點沒去拿
    （@開發Novia (UI) 2026-09-03）。

    「＋ 開一塊板」上線之後，零掛接板是**正常狀態**，這條路徑天天走。
    """
    app, client = await _client(tmp_path, "cards-by-session-key")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, room=rid)
            only_key = {"X-Session-Key": "claude-a"}   # 刻意不帶 participant

            oid = (await client.post(f"/api/boards/{bid}/objectives",
                                     json={"title": "週期"},
                                     headers=only_key)).json()["id"]
            cid = (await client.post(
                f"/api/board/objectives/{oid}/checklists",
                json={"title": "清單"}, headers=only_key)).json()["id"]
            tid = (await client.post(
                f"/api/board/checklists/{cid}/tasks",
                json={"title": "卡"}, headers=only_key)).json()["id"]

            for path, body in (
                    (f"/api/board/tasks/{tid}/claim", None),
                    (f"/api/board/tasks/{tid}/status", {"status": "in_progress"}),
                    (f"/api/board/tasks/{tid}/status", {"status": "done"})):
                r = await client.post(path, json=body, headers=only_key)
                assert r.status_code == 200, (path, r.text)

            r = await client.patch(f"/api/board/tasks/{tid}",
                                   json={"title": "改過的卡"}, headers=only_key)
            assert r.status_code == 200, r.text

            # 房外的人照樣被擋——放寬的是身分來源，不是權限
            no = await client.patch(f"/api/board/tasks/{tid}",
                                    json={"title": "路人改的"},
                                    headers={"X-Session-Key": "claude-out"})
            assert no.status_code == 403


async def test_a_claim_from_the_board_axis_still_orphans_when_he_leaves(
        tmp_path):
    """從板軸認領的卡，持有者離房之後**照樣會被孤兒化**。

    ⚠️ 孤兒判定（`_orphan_claims`）是 JOIN `claim_participant_id` 的。板軸
    的呼叫者沒有 participant_id，若就這樣寫成 NULL，他離房之後那張卡**永遠
    不會被孤兒化**——畫面上一直有人在做，而那個人早就走了。

    所以身分解析要**先找 participant**（他多半正在某個掛接房裡，只是從板那
    條路點進來），真的不在任何房裡才退回純 actor 身分——那時 NULL 才是對的，
    因為沒有房內存在可以失去。
    """
    app, client = await _client(tmp_path, "board-axis-claim-orphans")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")
            bid = await _board(client, a, room=rid)
            oid = (await client.post(f"/api/boards/{bid}/objectives",
                                     json={"title": "週期"},
                                     headers=a)).json()["id"]
            cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                                     json={"title": "清單"},
                                     headers=a)).json()["id"]
            tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                     json={"title": "卡"},
                                     headers=a)).json()["id"]

            # B 從板軸認領——只帶 session_key
            r = await client.post(f"/api/board/tasks/{tid}/claim",
                                  headers={"X-Session-Key": "claude-b"})
            assert r.status_code == 200, r.text

            await client.post(f"/api/rooms/{rid}/leave", headers=b)

            body = (await client.get(f"/api/boards/{bid}", headers=a)).json()
            card = next(t for t in body["tasks"] if t["id"] == tid)
            assert card["claim_state"] == "orphaned", (
                "板軸認領的卡在持有者離房後沒有被孤兒化——畫面上會一直"
                "顯示有人在做")


async def test_the_board_detail_says_whether_it_is_public(tmp_path):
    """詳情端點也要回 `visibility` 與 `owner_actor_key`。

    清單有、詳情沒有 ⇒ 從 Board Library 點進去那個畫面**不知道自己是公開
    還是私人**，而改可見性的入口正是在那裡（@開發Novia (除錯) 2026-09-03）。
    同一個東西的兩個讀取端點給不同欄位，差別要等有人做那件事才看得見——
    今天已經因為同一種形狀（`read_scratchpad` 少一個 `can_edit`）繞了一圈。
    """
    app, client = await _client(tmp_path, "detail-has-visibility")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, "私人板", visibility="private")

            body = (await client.get(f"/api/boards/{bid}", headers=a)).json()
            assert body["visibility"] == "private"
            assert body["owner_actor_key"] == "claude-a"

            # 清單與詳情必須說同一件事
            card = next(b for b in (await client.get(
                "/api/boards", headers=a)).json()["boards"] if b["id"] == bid)
            assert card["visibility"] == body["visibility"]


async def test_an_owner_who_never_joined_a_room_still_cannot_be_robbed(
        tmp_path):
    """從沒進過任何房的 owner **不算「不見了」**。

    🚨 `_board_owner_alive` 原本問的是「owner 現在是不是某間活房的 active
    participant」——**純 REST／Board Library 的使用者從頭到尾沒有 participant
    列**，於是恆判為無主 ⇒ 任何拿得到主 token 的人一次請求就搶得走整塊板，
    包括私人板，而回應自己還寫著 `had_owner: true`
    （@測試Novia 2026-09-03 在 8788 實測，可無限重複）。

    修正：接管要有 **owner 已經不在了的正面證據**，不是「查不到他在」。
    他若從來沒有出現過任何 participant 列，那是「不知道」，而不知道時
    不該提權。
    """
    app, client = await _client(tmp_path, "owner-never-in-a-room")
    async with client:
        async with app.router.lifespan_context(app):
            # A 完全走 REST，沒有加入任何房間
            only_key = {"X-Session-Key": "claude-a"}
            bid = await _board(client, only_key, "我的私人板",
                               visibility="private")

            host = {"X-Session-Key": "claude-thief", "X-Host-View": "1"}
            r = await client.post(f"/api/boards/{bid}/owner/claim",
                                  headers=host)
            assert r.status_code == 409, "沒進過房的 owner 被搶走了"
            assert r.json()["detail"]["code"] == "board_has_owner"

            # owner 仍然是他
            body = (await client.get(f"/api/boards/{bid}",
                                     headers=only_key)).json()
            assert body["my_role"] == "owner"


async def test_an_owner_who_was_here_and_left_can_be_replaced(tmp_path):
    """曾經在、現在不在了 ⇒ 有正面證據，接管成立。

    這是接管功能存在的理由，與上一條的差別只有一件事：**有沒有留下過痕跡**。
    """
    app, client = await _client(tmp_path, "owner-was-here-and-left")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, who="claude-a")
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, room=rid)
            host = {"X-Session-Key": "human-host", "X-Host-View": "1"}
            assert (await client.post(f"/api/boards/{bid}/owner/claim",
                                      headers=host)).status_code == 409

            await client.post(f"/api/rooms/{rid}/leave", headers=a)

            ok = await client.post(f"/api/boards/{bid}/owner/claim",
                                   headers=host)
            assert ok.status_code == 200, ok.text


async def test_making_the_room_public_cannot_expose_a_private_board(tmp_path):
    """私人房改公開時，掛著的私人板要擋下。

    🚨 這是「私人板只能放在私人聊天室」的側門：掛接那一頭守住了，**房這一頭
    改可見度就把同一個保證繞過去**，而板從頭到尾沒有被碰過
    （@測試Novia 2026-09-03 打穿）。

    擋下而不是自動解除掛接，與可見性那條同一個形狀——靜默的副作用會讓房裡
    的人在沒有提示的情況下失去一塊正在用的板。
    """
    app, client = await _client(tmp_path, "room-public-exposes-board")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, who="claude-a")
            a = await _join(client, rid, "claude-a", "A")
            await client.post(f"/api/rooms/{rid}/visibility",
                              json={"visibility": "private"}, headers=a)
            bid = await _board(client, a, "私人板", visibility="private")
            assert (await client.post(f"/api/boards/{bid}/rooms/{rid}",
                                      headers=a)).status_code == 200

            no = await client.post(f"/api/rooms/{rid}/visibility",
                                   json={"visibility": "public"}, headers=a)
            assert no.status_code == 409, "改房間可見度就把私人板曝光了"
            detail = no.json()["detail"]
            assert detail["code"] == "private_board_attached"
            assert detail["boards"] == [{"id": bid, "name": "私人板"}]

            # 解除掛接之後就改得動
            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=a)
            ok = await client.post(f"/api/rooms/{rid}/visibility",
                                   json={"visibility": "public"}, headers=a)
            assert ok.status_code == 200, ok.text


async def test_a_board_created_with_only_a_session_key_still_has_a_name(
        tmp_path):
    """只帶 `X-Session-Key` 建板，owner 在名冊上也要有名字與 kind。

    🚨 Board Library 那條路沒有 `participant_id`（板軸沒有房）⇒ 建板時查不到
    名字 ⇒ **建立者在自己的板上是一個沒有名字的 actor_key**。kind 空著更糟：
    想法板的守門靠它分辨人類與 agent，空的會把人類當成 agent，**在他自己開
    的板上改不動別人寫的東西**（@測試Novia 2026-09-03 實測，owner 有 join 房、
    有帶 preferred_name，`members[]` 仍是空字串）。
    """
    app, client = await _client(tmp_path, "board-member-name")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            await _join(client, rid, "claude-a", "諾薇亞")
            only_key = {"X-Session-Key": "claude-a"}   # 刻意不帶 participant
            bid = await _board(client, only_key)

            me = next(m for m in (await client.get(
                f"/api/boards/{bid}", headers=only_key)).json()["members"]
                if m["actor_key"] == "claude-a")
            assert me["display_name"] == "諾薇亞"
            assert me["actor_kind"] == "claude"


async def test_attached_rooms_say_whether_each_room_is_private(tmp_path):
    """`attached_rooms[]` 要說得出每間房是公開還是私人。

    側門擋住的是「之後才改」；**已經掛著的存量仍然要看得見**，否則板的 owner
    看不出自己的私人板正掛在一間公開房上（@測試Novia 2026-09-03）。
    """
    app, client = await _client(tmp_path, "attached-room-visibility")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            a = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, a, room=rid)
            entry = (await client.get(f"/api/boards/{bid}",
                                      headers=a)).json()["attached_rooms"][0]
            assert entry["visibility"] == "public"

            await client.post(f"/api/rooms/{rid}/visibility",
                              json={"visibility": "private"}, headers=a)
            entry = (await client.get(f"/api/boards/{bid}",
                                      headers=a)).json()["attached_rooms"][0]
            assert entry["visibility"] == "private"


async def test_host_view_lists_other_peoples_private_boards(tmp_path):
    """主持人模式看得到別人的私人板（艾斯維爾想法板觀察 ②）。

    比照主持人可見私人房的既有語意：`.env` 主 token 的持有者本來就讀得到
    同一個目錄下的 `chatroom.db`，這裡給的不是新權限，是把既有能力變得可用。

    ⚠️ **兩個條件缺一不可**，這條測試也把「只帶其中一個不算」一起釘住：
    沒帶 `X-Host-View` 就是普通清單（不是預設開著），而 header 帶了但
    token 不對也一樣——否則任何人加一個標頭就看得到全部。
    """
    app, client = await _client(tmp_path, "host_private")
    async with client:
        async with app.router.lifespan_context(app):
            mine = {"X-Session-Key": "claude-owner"}
            secret = await _board(client, mine, "別人的私人板", "private")
            open_one = await _board(client, mine, "別人的公開板", "public")

            # 路人：兩塊都不是他的，公開那塊他也不在任何掛接房裡
            stranger = {"X-Session-Key": "claude-stranger"}
            assert await _library(client, stranger) == set()

            host = {"X-Session-Key": "claude-stranger", "X-Host-View": "1"}
            got = (await client.get("/api/boards", headers=host)).json()
            names = {b["id"]: b for b in got["boards"]}
            assert set(names) == {secret, open_one}, "主持人模式沒看到全部的板"
            # 標得出哪一塊是私人的——UI 要據此加註記
            assert names[secret]["visibility"] == "private"

            # 🔴 沒帶 header ⇒ 不是主持人模式（主 token 不自動打穿）
            assert await _library(client, stranger) == set()

            # 🔴 帶了 header 但 token 不對 ⇒ 一樣看不到
            bad = AsyncClient(transport=ASGITransport(app=app),
                              base_url="http://test",
                              headers={"Authorization": "Bearer not-the-root-token"})
            async with bad:
                r = await bad.get("/api/boards", headers=host)
                # 認證那關先擋下就已經達到目的；放行的話清單必須是空的
                assert r.status_code != 200 or r.json()["boards"] == []


async def test_host_view_still_honours_the_status_filter(tmp_path):
    """主持人模式放寬的是**看得到誰的板**，不是把其他篩選一起關掉。

    放寬一個維度時順手把別的維度也放掉，是最容易混進來的那種錯——它不會
    報錯，只會讓「進行中／已封存」切換在主持人模式下靜靜失效。
    """
    app, client = await _client(tmp_path, "host_status")
    async with client:
        async with app.router.lifespan_context(app):
            mine = {"X-Session-Key": "claude-owner"}
            live = await _board(client, mine, "還在跑的板", "private")
            done = await _board(client, mine, "已封存的板", "private")
            r = await client.post(f"/api/boards/{done}/archive", headers=mine)
            assert r.status_code == 200, r.text

            host = {"X-Session-Key": "claude-stranger", "X-Host-View": "1"}
            got = (await client.get("/api/boards?status=active",
                                    headers=host)).json()
            assert [b["id"] for b in got["boards"]] == [live]


async def test_library_says_who_owns_each_board(tmp_path):
    """清單要說得出每塊板是誰的（@開發Novia (UI) 2026-09-04）。

    主持人開了開關會多出一堆別人的板，每塊標著「私人」——**看得到卻不知道
    是誰的，等於只做了一半**。而主持人模式存在的理由正是「看得到別人的
    東西」。

    ⚠️ `owner_actor_key` 單獨不夠：畫面上要能唸得出來的是名字。key 是給
    比對用的，兩個都要。
    """
    app, client = await _client(tmp_path, "library_owner")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, "有人的房", "claude-owner")
            owner = await _join(client, rid, "claude-owner", "板主")
            bid = await _board(client, owner, "他的私人板", "private")

            mine = (await client.get("/api/boards",
                                     headers=owner)).json()["boards"]
            assert [b["owner_display_name"] for b in mine] == ["板主"]
            assert mine[0]["owner_actor_key"]

            host = {"X-Session-Key": "claude-stranger", "X-Host-View": "1"}
            seen = (await client.get("/api/boards", headers=host)).json()
            row = [b for b in seen["boards"] if b["id"] == bid][0]
            assert row["owner_display_name"] == "板主", \
                "主持人看得到這塊板，卻不知道是誰的"
