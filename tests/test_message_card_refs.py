"""訊息裡的卡片指涉（`#[卡片標題]`）。

契約定案在 09/09 房 seq 32（已釘選）。這份守住其中最容易靜默壞掉的三條：

1. **欄位與內文必須一致。** 欄位是給 App 畫 chip 用的，bridge 與 watcher
   只看得到內文——欄位有而內文沒有的話，那則訊息對純文字端沒有意義，
   而且不會有任何地方報錯。`mentions` 上個月就是在這裡出過事。
2. **比對式只有一條。** 中文沒有詞邊界，子字串比對會讓 `#[登入頁重構]`
   在 `#[登入頁重構v2]` 裡假通過。括號把範圍講死就是為了這個。
3. **卡被刪／被搬，指涉不消失。** 訊息當時說了什麼是歷史；把 ref 拿掉
   比顯示「這張卡已刪除」糟得多。
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


async def _room_board(client, who="claude-h", name="艾斯維爾"):
    """一間房 + 一塊掛在它上面的板，回 (room_id, board_id, headers)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": who})).json()["id"]
    j = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": who,
        "preferred_name": name})
    hdr = {"X-Participant-Id": j.json()["participant_id"],
           "X-Session-Key": who}
    await client.post(f"/api/rooms/{rid}/board/objectives",
                      json={"title": "週期"}, headers=hdr)
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    return rid, bid, hdr


async def _task(client, rid, hdr, title):
    return (await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": title},
                              headers=hdr)).json()["id"]


async def _post(client, rid, hdr, content, refs):
    return await client.post(f"/api/rooms/{rid}/messages",
                             json={"content": content, "card_refs": refs},
                             headers=hdr)


async def _messages(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}/messages", headers=hdr)
    return r.json()["messages"]


async def test_ref_lands_with_snapshot_and_live_preview(tmp_path):
    """快照答「當時指的是哪一張」，preview 答「它現在怎麼了」。"""
    app, client = await _client(tmp_path, "ok")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "登入頁重構")
            r = await _post(client, rid, hdr, "先看 #[登入頁重構] 這張", [tid])
            assert r.status_code == 200, r.text
            assert r.json()["card_refs"] == [
                {"board_id": bid, "task_id": tid, "title": "登入頁重構"}]

            # 改了標題之後：快照留著當時那個，preview 給現況
            await client.patch(f"/api/board/tasks/{tid}",
                               json={"title": "登入頁重構（第二版）"}, headers=hdr)
            ref = (await _messages(client, rid, hdr))[-1]["card_refs"][0]
            assert ref["title"] == "登入頁重構"
            assert ref["card_preview"]["status"] == "ok"
            assert ref["card_preview"]["title"] == "登入頁重構（第二版）"


async def test_field_without_literal_is_refused(tmp_path):
    """欄位有、內文沒有 ⇒ 422。純文字端沒有 chip 這條後路。"""
    app, client = await _client(tmp_path, "nolit")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "登入頁重構")
            r = await _post(client, rid, hdr, "先看那張卡", [tid])
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_not_in_content"
            assert "#[登入頁重構]" in r.json()["detail"]["message"]


async def test_prefix_title_does_not_pass_by_substring(tmp_path):
    """`#[登入頁重構]` 不可以在 `#[登入頁重構v2]` 裡假通過。

    這是 `'@Nova-2'.contains('@Nova')` 那個坑的同一個形狀——只是在這裡的
    症狀是**假通過**：使用者根本沒提到那張卡，訊息卻指著它。
    """
    app, client = await _client(tmp_path, "prefix")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            short = await _task(client, rid, hdr, "登入頁重構")
            r = await _post(client, rid, hdr, "談的是 #[登入頁重構v2]", [short])
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_not_in_content"


async def test_title_with_hash_and_space(tmp_path):
    """標題自己含 `#` 或空白也不特殊——括號界定了範圍。"""
    app, client = await _client(tmp_path, "weird")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "修 #12 的 race condition")
            r = await _post(client, rid, hdr,
                            "見 #[修 #12 的 race condition] 一張", [tid])
            assert r.status_code == 200, r.text
            assert r.json()["card_refs"][0]["title"] == "修 #12 的 race condition"


async def test_duplicate_refs_collapse(tmp_path):
    """同一張卡指涉兩次，落庫一筆。內文出現幾次不管。"""
    app, client = await _client(tmp_path, "dup")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "登入頁重構")
            r = await _post(client, rid, hdr,
                            "#[登入頁重構] 跟 #[登入頁重構] 是同一張", [tid, tid])
            assert r.status_code == 200, r.text
            assert len(r.json()["card_refs"]) == 1


async def test_cannot_reference_card_on_unattached_board(tmp_path):
    """只能指涉本房掛接板上的卡——擋在 Hub，不是擋在 App。

    標題快照會跟著訊息落庫，指到房外的板等於把那塊板的卡名寫進這個房，
    而事後的 ACL 擋不掉已經寫下的東西。
    """
    app, client = await _client(tmp_path, "cross")
    async with client:
        async with app.router.lifespan_context(app):
            rid_a, _, hdr_a = await _room_board(client, who="claude-a", name="甲")
            rid_b, _, hdr_b = await _room_board(client, who="claude-b", name="乙")
            other = await _task(client, rid_b, hdr_b, "別房的卡")
            r = await _post(client, rid_a, hdr_a, "看 #[別房的卡]", [other])
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_not_available"


async def test_deleted_card_keeps_ref_and_reports_status(tmp_path):
    """卡被刪，指涉留著，狀態由 preview 說。移除 ref 是無聲改寫歷史。"""
    app, client = await _client(tmp_path, "del")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "會被刪的卡")
            await _post(client, rid, hdr, "見 #[會被刪的卡]", [tid])
            await client.delete(f"/api/board/tasks/{tid}", headers=hdr)

            ref = (await _messages(client, rid, hdr))[-1]["card_refs"][0]
            assert ref["task_id"] == tid
            assert ref["card_preview"]["status"] == "deleted"
            # 退回快照標題——不然 chip 會變成空的
            assert ref["card_preview"]["title"] == "會被刪的卡"


async def test_refs_not_editable_and_literal_cannot_be_removed(tmp_path):
    """指涉不可編輯；改內文也不能把 `#[標題]` 拿掉。

    只擋 `card_refs` 參數是半套的——把字面從內文刪掉會走到同一個壞狀態，
    只是換一條路徑進來。
    """
    app, client = await _client(tmp_path, "edit")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "登入頁重構")
            mid = (await _post(client, rid, hdr,
                               "見 #[登入頁重構]", [tid])).json()["id"]

            r = await client.patch(f"/api/messages/{mid}",
                                   json={"content": "見 #[登入頁重構]",
                                         "card_refs": []}, headers=hdr)
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_refs_not_editable"

            r = await client.patch(f"/api/messages/{mid}",
                                   json={"content": "算了不講那張"}, headers=hdr)
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_not_in_content"

            # 內文照樣可以改，只要字面還在
            r = await client.patch(f"/api/messages/{mid}",
                                   json={"content": "其實 #[登入頁重構] 才是重點"},
                                   headers=hdr)
            assert r.status_code == 200, r.text


async def test_literal_without_field_is_refused(tmp_path):
    """反向：內文寫了 `#[某卡]`、欄位卻空著 ⇒ 422。

    這是同一個坑的鏡像面。單向驗證會放行，做出一則**看起來指了卡、卻沒有
    chip、沒有 preview、點不下去**的訊息，而且沒有任何地方報錯。
    """
    app, client = await _client(tmp_path, "orphan")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            await _task(client, rid, hdr, "登入頁重構")
            r = await _post(client, rid, hdr, "看 #[登入頁重構]", [])
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_field_missing"

            # 湊巧寫成這個形狀、但板上沒有這張卡的一般句子不該被擋
            ok = await _post(client, rid, hdr, "隨手記 #[買牛奶]", [])
            assert ok.status_code == 200, ok.text


async def test_no_unicode_normalisation_anywhere(tmp_path):
    """一律原樣比對，Hub 不做 NFC（2026-09-09 裁定，方案②）。

    做 NFC 的話 Hub 會認得 App 認不得的字面（Dart 核心沒有內建正規化），
    於是板上標題 NFC、使用者手打 NFD 字面時，Hub 要求帶 ref 而 App 給不
    出來，他從候選也選不回那個字面——死局。同一條比對規則三端各自實作，
    只要有一端不一樣就會湊出死局，最小一致面優先。

    已知代價（刻意接受）：內文是 NFD、又明確帶了 ref 的訊息從過變成擋。
    """
    import unicodedata as ud

    app, client = await _client(tmp_path, "normalise")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            title = ud.normalize("NFC", "ログイン画面のバグ")
            assert ud.normalize("NFD", title) != title
            tid = await _task(client, rid, hdr, title)
            nfd_body = "看 " + ud.normalize("NFD", f"#[{title}]")

            # 反向：手打 NFD 字面、欄位空 ⇒ 兩端一致地不認得，照發
            assert (await _post(client, rid, hdr, nfd_body, [])).status_code == 200

            # 正向：NFD 內文 + 明確帶 ref ⇒ 擋（已知代價，不是漏擋）
            r = await _post(client, rid, hdr, nfd_body, [tid])
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_not_in_content"
            # 錯誤要指向使用者改得動的東西
            assert "字形差異" in r.json()["detail"]["message"]

            # 原樣那條照樣通過
            ok = await _post(client, rid, hdr, f"看 #[{title}]", [tid])
            assert ok.status_code == 200, ok.text


async def test_edit_cannot_add_an_orphan_literal(tmp_path):
    """改文時**加**一個字面同樣做得出點不下去的 chip。

    指涉不可編輯，所以那個欄位永遠補不上——只擋刪除是半套的。
    """
    app, client = await _client(tmp_path, "editadd")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            await _task(client, rid, hdr, "登入頁重構")
            mid = (await client.post(
                f"/api/rooms/{rid}/messages",
                json={"content": "先講別的"}, headers=hdr)).json()["id"]
            r = await client.patch(f"/api/messages/{mid}",
                                   json={"content": "其實是 #[登入頁重構]"},
                                   headers=hdr)
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_ref_field_missing"


async def test_no_refs_is_the_default(tmp_path):
    """不帶參數的一般訊息不受影響，欄位是空清單而不是缺席。"""
    app, client = await _client(tmp_path, "plain")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            await client.post(f"/api/rooms/{rid}/messages",
                              json={"content": "沒有指涉任何卡"}, headers=hdr)
            assert (await _messages(client, rid, hdr))[-1]["card_refs"] == []


async def test_cap_counts_literals_not_fields(tmp_path):
    """上限算在內文上——兩條分開算會開出一個發不出去的死局。

    內文寫了 21 個對得上的字面時，反向驗證要 21 筆、上限只准 20 筆，
    使用者會在兩個錯誤碼之間來回跳，而他不可能從那兩句話推出「要改內文」。
    """
    app, client = await _client(tmp_path, "cap")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            ids, parts = [], []
            for i in range(21):
                ids.append(await _task(client, rid, hdr, f"卡{i:02d}"))
                parts.append(f"#[卡{i:02d}]")
            r = await _post(client, rid, hdr, " ".join(parts), ids)
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_refs_too_many"
            # 錯誤要講的是內文，不是欄位——講錯的話他會去砍 refs，
            # 然後撞上反向驗證
            assert "內文" in r.json()["detail"]["message"]

            # 砍到 20 個（內文與欄位一起砍）就過
            ok = await _post(client, rid, hdr, " ".join(parts[:20]), ids[:20])
            assert ok.status_code == 200, ok.text


async def test_field_side_has_a_hard_gate_before_any_query(tmp_path):
    """大量無效 id 要在查詢之前被擋下。

    內文那條上限擋不住它——那些 id 對不上任何字面，`matched` 是 0，
    上限檢查直接放行，然後整包展開成 `WHERE id IN (?...)`。
    「未經檢查的請求欄位直接變成 SQL 參數」這個形狀本身就該有個閘。
    """
    app, client = await _client(tmp_path, "gate")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            r = await _post(client, rid, hdr, "沒有任何字面",
                            [f"nonexistent-{i:04d}" for i in range(1000)])
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "card_refs_field_limit"


async def test_same_title_twice_on_one_board(tmp_path):
    """同一塊板上兩張同名的卡，指涉第二張要過。

    一個標題對到的是一份清單而不是一張卡——只留第一張的話，反向檢查會
    拿第一張來要：欄位帶了 B、它說你少帶 A，而兩張在畫面上同名，
    發話者看不出差別也補不出來。
    """
    app, client = await _client(tmp_path, "dupname")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            await _task(client, rid, hdr, "同名卡")
            second = await _task(client, rid, hdr, "同名卡")
            r = await _post(client, rid, hdr, "講的是 #[同名卡]", [second])
            assert r.status_code == 200, r.text
            assert r.json()["card_refs"][0]["task_id"] == second


async def test_reverse_check_covers_titles_containing_brackets(tmp_path):
    """標題含 `]` 的卡，反向檢查也要抓得到。

    用正則從內文抓 `#[...]` 的話，`修復[A]問題` 只會被抓成 `修復[A`，
    對不上任何卡 ⇒ 反向閘靜靜地不觸發 ⇒ 那則訊息看起來指了卡卻點不下去，
    而且 200 照發。這正是反向閘要消滅的形狀，在這類標題上原樣復活。

    改成拿板上的卡標題去比內文就沒有這個洞——比對的是完整標題，
    裡面有什麼字元都不影響。
    """
    app, client = await _client(tmp_path, "brackets")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr, "修復[A]問題")

            bad = await _post(client, rid, hdr, "修這個 #[修復[A]問題] 好嗎", [])
            assert bad.status_code == 422
            assert bad.json()["detail"]["code"] == "card_ref_field_missing"

            ok = await _post(client, rid, hdr, "修這個 #[修復[A]問題] 好嗎", [tid])
            assert ok.status_code == 200, ok.text
            assert ok.json()["card_refs"][0]["title"] == "修復[A]問題"


async def test_mixed_bracket_and_plain_titles(tmp_path):
    """一則訊息裡同時有含 `]` 與不含的標題——這種會**部分**成功。

    正則抓法在這裡只抓到半截的 `修復[A` 加上完整的 `登入頁重構`：帶了
    後者就過關，而前者那張卡從頭到尾沒有人問過。訊息上有兩個字面、
    只有一個點得下去，兩邊都不報錯。（@測試Novia 09/09 房 seq 104）
    """
    app, client = await _client(tmp_path, "mixed")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            a = await _task(client, rid, hdr, "修復[A]問題")
            b = await _task(client, rid, hdr, "登入頁重構")
            body = "先修 #[修復[A]問題] 再看 #[登入頁重構] 這張"

            half = await _post(client, rid, hdr, body, [b])
            assert half.status_code == 422
            assert half.json()["detail"]["code"] == "card_ref_field_missing"

            both = await _post(client, rid, hdr, body, [a, b])
            assert both.status_code == 200, both.text
            assert {x["task_id"] for x in both.json()["card_refs"]} == {a, b}


async def test_cancelled_and_moved_cards_are_not_forbidden_words(tmp_path):
    """取消／搬走的卡不再是禁字——反向檢查的集合要與 App 候選一致。

    兩邊篩選條件不一樣會湊出一個解不掉的死局：板上有張取消掉的卡叫 X，
    有人把含 `#[X]` 的舊文字複製貼上進輸入框（不必手打），App 候選沒有 X
    所以不帶 ref，Hub 卻認得 X 於是擋下來，還叫他「從 # 候選重選一次」
    ——候選裡根本沒有那張卡。（@開發Novia (UI) 09/09 房 seq 111）

    正向那側維持寬鬆：明確帶了 id 的人知道自己在指誰。
    """
    app, client = await _client(tmp_path, "settled")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            gone = await _task(client, rid, hdr, "取消掉的卡")
            await client.post(f"/api/board/tasks/{gone}/status",
                              json={"status": "cancelled"}, headers=hdr)

            # 反向：貼上含字面的舊文字、欄位空 ⇒ 照發，不是禁字
            r = await _post(client, rid, hdr, "之前講的 #[取消掉的卡] 那張", [])
            assert r.status_code == 200, r.text

            # 正向：明確帶 id 仍然可以指它
            ok = await _post(client, rid, hdr, "之前講的 #[取消掉的卡] 那張",
                             [gone])
            assert ok.status_code == 200, ok.text
            assert ok.json()["card_refs"][0]["task_id"] == gone


async def test_moved_preview_shows_the_current_title(tmp_path):
    """`moved` 給的是**現況**標題，不是快照（契約 §3 修訂後的文字）。

    卡搬走時標題沒變的話，快照與現況長得一模一樣，顯示哪一個都看不出
    差別——那種案例證不了這條。要證明得讓兩者不同。
    （@測試Novia 09/09 房 seq 115 指出我造的案例區分不出來）
    """
    app, client = await _client(tmp_path, "movedtitle")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            old = await _task(client, rid, hdr, "改名前的標題")
            new = await _task(client, rid, hdr, "新家")
            await _post(client, rid, hdr, "指涉 #[改名前的標題] 這張", [old])
            await client.patch(f"/api/board/tasks/{old}",
                               json={"title": "改名後的標題"}, headers=hdr)
            await client.post(f"/api/board/tasks/{old}/status",
                              json={"status": "moved", "moved_to": new},
                              headers=hdr)

            msg = (await _messages(client, rid, hdr))[-1]
            ref = msg["card_refs"][0]
            assert "#[改名前的標題]" in msg["content"], "內文不該被改寫"
            assert ref["title"] == "改名前的標題", "快照答的是當時指的是誰"
            assert ref["card_preview"]["status"] == "moved"
            assert ref["card_preview"]["title"] == "改名後的標題"
            assert ref["card_preview"]["moved_to"] == new
