"""憑證位置統一：四支端點也收 header（09/07 卡 87ec8297 的 server 半）。

正典（決策 09/07 裁）：`access_token` 走 `Authorization: Bearer`，
`session_key` 走 `X-Session-Key`。這一半只做**收**——舊位置照常收，等 bridge
與 App 切過去之後，下一個 kit 週期才拔。

⚠️ **順序是硬的**（@開發Novia (UI) seq 156 擋下反向）：server 先收齊 → bridge
拔 + App 切 → 出包。反過來的話 App 啟動第一支 `GET /api/rooms` 就拿不到身分，
而症狀是「你不是成員」，不是「缺參數」。

三個不在清理範圍的東西，一併釘住免得下一個人手滑：
- `/ws` 的 `?token=` 是**永久例外**（WS 握手沒有地方放 header，協定層限制）
- `POST /api/rooms/{id}/board/supervisor` body 的 `session_key` 是**指派目標
  不是憑證**——照字串搜尋改的話，症狀是 supervisor 靜默指到錯的人
- `_session_params` 的 `kind`／`label`／`host` 是向名錄自報的資訊，不是憑證
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
KEY = "human-1"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


# ---------- GET /api/rooms ----------

async def test_list_rooms_takes_the_header(tmp_path):
    """App 啟動打的第一支。它拿不到身分的話，`you_are_host` 與待處理指派
    一起消失，而畫面上看起來只是「什麼都沒有」。"""
    app, client = await _client(tmp_path, "pos-rooms-header")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/rooms", headers={"X-Session-Key": KEY})
        assert r.status_code == 200, r.text


async def test_list_rooms_still_takes_the_query(tmp_path):
    """相容期：舊位置照收——bridge 與 App 還沒切。"""
    app, client = await _client(tmp_path, "pos-rooms-query")
    async with app.router.lifespan_context(app), client:
        assert (await client.get(f"/api/rooms?session_key={KEY}")
                ).status_code == 200


# ---------- GET /api/assignments ----------

async def test_assignments_takes_the_header(tmp_path):
    app, client = await _client(tmp_path, "pos-assign-header")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/assignments",
                             headers={"X-Session-Key": KEY})
        assert r.status_code == 200, r.text


async def test_assignments_no_longer_demands_the_query(tmp_path):
    """它原本是**必填 query**——舊 client 與新 client 只能活一種
    （@開發Novia (UI) seq 156）。改成兩邊擇一。"""
    app, client = await _client(tmp_path, "pos-assign-compat")
    async with app.router.lifespan_context(app), client:
        assert (await client.get(f"/api/assignments?session_key={KEY}")
                ).status_code == 200


async def test_assignments_without_any_identity_says_so(tmp_path):
    """兩邊都沒有時要**明確講**。靜默回空清單的話，那與「你沒有指派」
    長得一模一樣——而後者是每天都會發生的正常狀態。"""
    app, client = await _client(tmp_path, "pos-assign-none")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/assignments")
        assert r.status_code == 422, r.text
        assert r.json()["detail"]["code"] == "session_key_required"


# ---------- POST /api/rooms ----------

async def test_creating_a_room_takes_the_header(tmp_path):
    """建房的 session_key 決定**誰是管理者**。它掉了的話症狀不在現場——
    是三步之後的「建板 403 not_room_admin」（09/06 卡 48da086a）。"""
    app, client = await _client(tmp_path, "pos-create-header")
    async with app.router.lifespan_context(app), client:
        r = await client.post("/api/rooms", headers={"X-Session-Key": KEY},
                              json={"name": "房"})
        assert r.status_code == 200, r.text
        rid = r.json()["id"]
        detail = await client.get(f"/api/rooms/{rid}",
                                  headers={"X-Session-Key": KEY})
        assert detail.json()["you_are_admin"] is True


async def test_creating_a_room_without_any_key_is_still_refused(tmp_path):
    """48da086a 的保護不能因為多一個位置就消失：**兩個位置都沒有才是錯**。"""
    app, client = await _client(tmp_path, "pos-create-none")
    async with app.router.lifespan_context(app), client:
        r = await client.post("/api/rooms", json={"name": "房"})
        assert r.status_code == 422, r.text


# ---------- POST /api/rooms/{id}/join ----------

async def test_joining_takes_the_header(tmp_path):
    app, client = await _client(tmp_path, "pos-join-header")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", headers={"X-Session-Key": KEY},
                                 json={"name": "房"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join",
                              headers={"X-Session-Key": "claude-1"},
                              json={"kind": "claude", "role": "agent",
                                    "preferred_name": "Novia"})
        assert r.status_code == 200, r.text
        assert r.json()["session_key"] == "claude-1"


async def test_joining_without_any_key_is_refused(tmp_path):
    app, client = await _client(tmp_path, "pos-join-none")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", headers={"X-Session-Key": KEY},
                                 json={"name": "房"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/join",
                              json={"kind": "claude", "role": "agent"})
        assert r.status_code == 422, r.text


# ---------- 優先序 ----------

async def test_the_header_wins(tmp_path):
    """兩個位置都給且不同時，**header 是正典**。

    悄悄用舊的那個會讓「我改成 header 了」這件事看起來生效、實際沒有——
    而切換期正是兩邊都會出現的時候。
    """
    app, client = await _client(tmp_path, "pos-priority")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post(
            "/api/rooms", headers={"X-Session-Key": "from-header"},
            json={"name": "房", "session_key": "from-body"})).json()["id"]
        d = await client.get(f"/api/rooms/{rid}",
                             headers={"X-Session-Key": "from-header"})
        assert d.json()["you_are_admin"] is True


# ---------- 不在清理範圍的三個 ----------

async def test_the_supervisor_body_key_is_a_target_not_a_credential(tmp_path):
    """`board/supervisor` body 的 `session_key` 是**要指派誰**。

    照字串搜尋改的話它會被一起搬走，而症狀是 supervisor 靜默指到呼叫者
    自己——那在畫面上完全正常（@開發Novia (UI) seq 153）。
    """
    app, client = await _client(tmp_path, "pos-supervisor")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", headers={"X-Session-Key": KEY},
                                 json={"name": "房"})).json()["id"]
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              headers={"X-Session-Key": KEY},
                              json={"session_key": "someone-else"})
        assert r.status_code == 200, r.text
        # 指到 body 那個人，不是 header 那個
        assert r.json()["supervisor"] == "someone-else"


async def test_the_websocket_keeps_its_query_token(tmp_path):
    """WS 握手沒有地方放 `Authorization`——**協定層限制，不是技術債**。

    「相容期結束」的定義是「REST 的舊位置不收」。把 WS 一起清掉的話，
    症狀是「訊息不會自己出現，重開才看得到」而 REST 全部正常，比整個
    連不上難查得多（@開發Novia (UI) seq 159）。
    """
    import inspect

    from chatroom_server import app as mod
    src = inspect.getsource(mod.create_app)
    assert 'query_params.get("token")' in src, "WS 的 ?token= 被拔掉了"


async def test_two_positions_with_different_values_are_reported(tmp_path, caplog):
    """🔴 雙送的隱藏成本：**「兩處是同一個值」沒有人會主動檢查。**

    @開發Novia (除錯) 09/07 在 bridge 那側撞到——`derive_key` 每次回不同值，
    於是 subagent 的 body 與標頭送出兩把不同的 key。Hub 只讀其中一把，另一把
    去哪了沒有人看得出來。他當場炸是因為那個函式不純；**如果它是純函式，
    這個 bug 會安靜到下一輪拔舊位置那天。**

    Hub 這側看得到兩個位置，所以由這裡守。不 raise——切換期把服務停掉太重，
    而 header 優先本來就是定義好的行為；要的是**留下痕跡**。
    """
    import logging

    app, client = await _client(tmp_path, "pos-mismatch")
    async with app.router.lifespan_context(app), client:
        with caplog.at_level(logging.WARNING, logger="chatroom"):
            r = await client.post("/api/rooms",
                                  headers={"X-Session-Key": "from-header"},
                                  json={"name": "房",
                                        "session_key": "from-body"})
        assert r.status_code == 200, r.text
        assert any(getattr(rec, "event", "") == "credential_position_mismatch"
                   for rec in caplog.records), "兩個位置不一致卻沒有留下痕跡"
