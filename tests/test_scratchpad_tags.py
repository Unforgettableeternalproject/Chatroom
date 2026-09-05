"""想法板段落標籤（艾斯維爾想法板觀察 ④，2026-09-04 定案）。

原話：「想法版要可以有標籤 (Bug, 新功能等等)」，#403 補答：**單選＋預設集合
＋每塊板可自訂額外標籤**。

**標在段落不標在板**：那六則觀察躺在同一份想法板裡，性質卻各不相同（兩則
bug、三則新功能、一則權限設計）。標在板上的話一份板只能有一個標籤，等於標
不出任何東西（@開發Novia (UI) 的判讀，依據是艾斯維爾實際的用法）。

🔑 **schema 寬、行為窄**：欄位是 JSON 陣列，UI 只給單選。這樣「單選還是多選」
之後改主意時**不用動資料**——反過來（存單一 TEXT）有一半機率要遷移。

⚠️ **驗證在 server**：只靠 UI 給選單的話，任何直打 REST 的人都能塞任意字串，
而那正是「固定集合」要防的髒資料——它會從畫面防不到的那條路進來。
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


async def _room_with_pad(client):
    """房 + 板 + 一份想法板。回 (rid, hdr, board_id, pad_id)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "想法房", "session_key": "human-1"})).json()["id"]
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "艾斯維爾"})
    hdr = {"X-Participant-Id": r.json()["participant_id"],
           "X-Session-Key": "human-1"}
    # 寫一張卡讓板長出來（換軸就發生在這一刻）
    await client.post(f"/api/rooms/{rid}/board/tasks",
                      json={"title": "第一張"}, headers=hdr)
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    pad = (await client.post(f"/api/boards/{bid}/scratchpads",
                             json={"title": "功能"}, headers=hdr)).json()
    return rid, hdr, bid, pad["id"]


async def _add_block(client, bid, pad_id, hdr, content, tags=None):
    body = {"content": content}
    if tags is not None:
        body["tags"] = tags
    return await client.post(f"/api/boards/{bid}/scratchpads/{pad_id}/blocks",
                             json=body, headers=hdr)


async def _blocks(client, bid, pad_id, hdr):
    r = await client.get(f"/api/boards/{bid}/scratchpads/{pad_id}",
                         headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["blocks"]


async def test_a_block_carries_its_tag(tmp_path):
    """段落帶得動標籤，讀回來還在。"""
    app, client = await _client(tmp_path, "tag_basic")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            r = await _add_block(client, bid, pad, hdr, "輸入框會清空",
                                 tags=["bug"])
            assert r.status_code == 200, r.text
            blocks = await _blocks(client, bid, pad, hdr)
            assert blocks[0]["tags"] == ["bug"]


async def test_a_block_without_tags_is_fine(tmp_path):
    """不標也可以——想法板是「還沒成形」的地方，逼人先分類就違背了它的用途。"""
    app, client = await _client(tmp_path, "tag_none")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            await _add_block(client, bid, pad, hdr, "還不知道算什麼")
            blocks = await _blocks(client, bid, pad, hdr)
            assert blocks[0]["tags"] == []


async def test_an_unknown_tag_is_refused(tmp_path):
    """🔴 不在集合裡的標籤擋下——**驗證在 server 不在 UI**。

    只靠選單的話，任何直打 REST 的人都能塞任意字串進去，而「固定集合」要防
    的正是 `bug`／`Bug`／`BUG`／`錯誤` 這種**不會報錯、只會讓分堆慢慢失效**
    的髒資料。它會從畫面防不到的那條路進來。
    """
    app, client = await _client(tmp_path, "tag_unknown")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            r = await _add_block(client, bid, pad, hdr, "亂標", tags=["BUG"])
            assert r.status_code == 422, r.text
            assert r.json()["detail"]["code"] == "unknown_tag"
            # 錯誤要說得出「可以用哪些」，否則呼叫端只能猜
            assert "bug" in r.json()["detail"]["allowed"]


async def test_a_board_can_register_its_own_tags(tmp_path):
    """每塊板可以有自訂的額外標籤（艾斯維爾 #403）。

    ⚠️ 這與「自由輸入」是兩件事：**加標籤是一次明確的動作**，之後仍然從選單
    挑。所以固定集合要防的東西一個都沒放掉——選單的內容變成
    「預設集合 ∪ 這塊板自訂的」，而不是一個空白輸入框。
    """
    app, client = await _client(tmp_path, "tag_custom")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)

            # 還沒註冊之前擋下
            r = await _add_block(client, bid, pad, hdr, "效能問題",
                                 tags=["perf"])
            assert r.status_code == 422

            r = await client.post(f"/api/boards/{bid}/tags",
                                  json={"tags": ["perf"]}, headers=hdr)
            assert r.status_code == 200, r.text
            assert "perf" in r.json()["tags"]
            # 預設集合仍在——自訂是**附加**不是取代
            assert "bug" in r.json()["allowed"]

            r = await _add_block(client, bid, pad, hdr, "效能問題",
                                 tags=["perf"])
            assert r.status_code == 200, r.text


async def test_custom_tags_do_not_leak_across_boards(tmp_path):
    """A 板註冊的標籤不會讓 B 板也能用。

    自訂是**板層級**的：漏掉這道界線的話，第一個註冊 `perf` 的人等於替全 Hub
    決定了標籤集合，而那正是「每塊板可以有自訂的」要避免的相反面。
    """
    app, client = await _client(tmp_path, "tag_isolation")
    async with client:
        async with app.router.lifespan_context(app):
            rid_a, hdr_a, bid_a, pad_a = await _room_with_pad(client)
            await client.post(f"/api/boards/{bid_a}/tags",
                              json={"tags": ["perf"]}, headers=hdr_a)

            rid_b = (await client.post("/api/rooms", json={
                "name": "另一個房", "session_key": "human-1"})).json()["id"]
            r = await client.post(f"/api/rooms/{rid_b}/join", json={
                "kind": "human", "role": "human", "session_key": "human-1",
                "preferred_name": "艾斯維爾"})
            hdr_b = {"X-Participant-Id": r.json()["participant_id"],
                     "X-Session-Key": "human-1"}
            await client.post(f"/api/rooms/{rid_b}/board/tasks",
                              json={"title": "卡"}, headers=hdr_b)
            bid_b = (await client.get(f"/api/rooms/{rid_b}/board",
                                      headers=hdr_b)).json()["board_id"]
            pad_b = (await client.post(f"/api/boards/{bid_b}/scratchpads",
                                       json={"title": "想法"},
                                       headers=hdr_b)).json()["id"]

            r = await _add_block(client, bid_b, pad_b, hdr_b, "也想標",
                                 tags=["perf"])
            assert r.status_code == 422, "A 板註冊的標籤漏到 B 板了"


async def test_the_tag_list_comes_back_with_the_board(tmp_path):
    """選單要畫得出來，所以「這塊板能用哪些標籤」要隨板回。

    不回的話 UI 只能把預設集合寫死一份在自己那邊——**第二份判準**，而板自訂
    的那些它永遠不會知道。
    """
    app, client = await _client(tmp_path, "tag_listing")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            await client.post(f"/api/boards/{bid}/tags",
                              json={"tags": ["perf"]}, headers=hdr)

            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert "perf" in body["allowed_tags"]
            assert "bug" in body["allowed_tags"]

            # 房軸也要有——從聊天室進板的人看到的選單不能比較少
            body = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=hdr)).json()
            assert "perf" in body["allowed_tags"]


async def test_editing_a_block_can_change_its_tag(tmp_path):
    """改標籤走既有的改寫端點，不另開一支。

    標籤是段落的一部分，不是掛在旁邊的東西——另開端點的話「改內容」與
    「改標籤」會各自領一個 `board_seq`，而它們常常是同一個動作。
    """
    app, client = await _client(tmp_path, "tag_edit")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            r = await _add_block(client, bid, pad, hdr, "統計對不上",
                                 tags=["question"])
            blk = r.json()

            r = await client.put(
                f"/api/boards/{bid}/scratchpads/{pad}/blocks/{blk['id']}",
                json={"content": "統計對不上", "tags": ["bug"],
                      "rev": blk["rev"]}, headers=hdr)
            assert r.status_code == 200, r.text

            blocks = await _blocks(client, bid, pad, hdr)
            assert blocks[0]["tags"] == ["bug"]
            assert blocks[0]["content"] == "統計對不上", "改標籤把內容洗掉了"


async def test_a_tag_in_use_cannot_be_deleted_but_points_the_way_out(tmp_path):
    """刪掉還有人用的自訂標籤 → 409，**而且指得出路**（做法 C）。

    三種做法裡只有這個不會在事後才發現：
    - 保留段落的 tag ⇒ 那些段落**從篩選器裡消失**（想法板的用途就是回來翻）
    - 刪標籤時清掉段落的 tag ⇒ **靜靜改掉一批段落**，按下刪除的人不知道動了幾則

    🔴 但「不給刪」若沒有出口，標籤會被用過一次就**永久鎖死**——那不是保護，
    是沒有人收拾得了的狀態。所以 409 要帶 `block_ids`：畫面才說得出
    「還有 3 則在用，去看看」，而不只是「不能刪」。
    **擋下來但指得出路才是 C；擋下來而已是把問題換個地方放。**
    """
    app, client = await _client(tmp_path, "tag_in_use")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            await client.post(f"/api/boards/{bid}/tags",
                              json={"tags": ["perf"]}, headers=hdr)
            r = await _add_block(client, bid, pad, hdr, "很慢", tags=["perf"])
            blk_id = r.json()["id"]

            r = await client.delete(f"/api/boards/{bid}/tags/perf", headers=hdr)
            assert r.status_code == 409, r.text
            detail = r.json()["detail"]
            assert detail["code"] == "tag_in_use"
            assert detail["in_use_count"] == 1
            assert detail["block_ids"] == [blk_id], "擋下來卻指不出是哪幾則"

            # 改掉那則之後就刪得掉——出口是通的
            blocks = await _blocks(client, bid, pad, hdr)
            await client.put(
                f"/api/boards/{bid}/scratchpads/{pad}/blocks/{blk_id}",
                json={"content": blocks[0]["content"], "tags": [],
                      "rev": blocks[0]["rev"]}, headers=hdr)
            r = await client.delete(f"/api/boards/{bid}/tags/perf", headers=hdr)
            assert r.status_code == 200, r.text
            assert "perf" not in r.json()["tags"]


async def test_a_default_tag_cannot_be_removed(tmp_path):
    """預設集合不是板的資產，刪不掉。

    讓它刪得掉的話，同一個 `bug` 在不同板上會有不同意思——而預設集合存在的
    理由正是「跨板一致」。
    """
    app, client = await _client(tmp_path, "tag_default")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            r = await client.delete(f"/api/boards/{bid}/tags/bug", headers=hdr)
            assert r.status_code == 422, r.text
            assert r.json()["detail"]["code"] == "tag_is_default"


async def test_the_board_says_which_tags_are_deletable(tmp_path):
    """`allowed_tags` 是聯集，分不出哪些刪得掉——所以 `custom_tags` 也要回。

    UI 的刪除按鈕要嘛對預設標籤也開放（按了必吃 422 `tag_is_default`，
    一顆註定失敗的按鈕），要嘛自己在本地寫一份預設集合去反推——**第二份
    判準**，跟 `allowed_tags` 當初要消除的是同一個東西。

    房軸與板軸都要回：從聊天室進板的人，看到的東西不能比較少。
    """
    app, client = await _client(tmp_path, "tag_deletable")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            await client.post(f"/api/boards/{bid}/tags",
                              json={"tags": ["perf"]}, headers=hdr)

            for label, url in (("板軸", f"/api/boards/{bid}"),
                               ("房軸", f"/api/rooms/{rid}/board")):
                body = (await client.get(url, headers=hdr)).json()
                assert "custom_tags" in body, f"{label}沒有回 custom_tags"
                assert body["custom_tags"] == ["perf"], (
                    f"{label}的 custom_tags 應該只有自訂的那些，"
                    f"實際是 {body['custom_tags']}"
                )
                # 預設標籤不在裡面 = UI 據此鎖住它們的刪除按鈕
                assert "bug" not in body["custom_tags"]
                assert "bug" in body["allowed_tags"]


async def test_a_board_without_custom_tags_returns_an_empty_list(tmp_path):
    """沒有自訂標籤時回空陣列，不是缺欄位——缺欄位 UI 分不出「沒有」與
    「舊版 Hub 不會回」，而那兩者要畫的東西不同。"""
    app, client = await _client(tmp_path, "tag_none")
    async with client:
        async with app.router.lifespan_context(app):
            rid, hdr, bid, pad = await _room_with_pad(client)
            body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
            assert body["custom_tags"] == []
