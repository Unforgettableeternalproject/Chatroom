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


async def test_nfc_normalisation_before_compare(tmp_path):
    """內文與標題正規化形式不同時仍要對得上。

    兩邊在畫面上長得一模一樣，字串包含卻失敗，而錯誤訊息說「缺 #[標題]」
    ——使用者不可能自己排除那種錯。
    """
    import unicodedata

    app, client = await _client(tmp_path, "nfc")
    async with client:
        async with app.router.lifespan_context(app):
            rid, _, hdr = await _room_board(client)
            title = "設計稿 café 版"          # NFC
            tid = await _task(client, rid, hdr, title)
            decomposed = unicodedata.normalize("NFD", f"#[{title}]")
            assert decomposed != f"#[{title}]", "這個標題要有可分解的字元"
            r = await _post(client, rid, hdr, f"見 {decomposed}", [tid])
            assert r.status_code == 200, r.text


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
