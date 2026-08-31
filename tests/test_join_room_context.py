"""join 的回傳要帶得出「這是哪個房、這房要我做什麼」（票 A2）。

被指派進房的 agent 拿到 `chatroom_join` 的回應時，手上只有 participant_id
和自己的名字——**它讀不到房名、主題，也讀不到指派者寫的那句 note**。要嘛
再繞一次 `chatroom_list_rooms`，要嘛（resume 之後）永遠拿不回來：note 原本
只出現在 watcher 的一次性事件裡。

新欄位一律**只增不改**：舊版 bridge 看不到就當沒有，不會壞。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make_client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **cfg_kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def test_join_returns_room_context(tmp_path):
    """房名與主題跟著身分一起回來，不必再問一次。"""
    app, client = await _make_client(tmp_path, "jc-room")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={
                "name": "Chatroom 開發", "topic": "把邀請卡修好",
                "session_key": "owner-key"})).json()["id"]

            r = await client.post(f"/api/rooms/{room_id}/join",
                                  json={"kind": "claude", "session_key": "s-a"})
            assert r.status_code == 200, r.text
            room = r.json()["room"]
            # 巢狀而不是攤平成 room_name：「房間的什麼」與「我的什麼」混在
            # 同一層之後，補 zone / visibility 只會愈補愈亂
            assert room["id"] == room_id
            assert room["name"] == "Chatroom 開發"
            assert room["topic"] == "把邀請卡修好"
            assert room["status"] == "active"


async def test_join_by_assignment_returns_the_note(tmp_path):
    """指派者寫的那句 note 要拿得回來——它是「這房要我做什麼」的唯一來源。"""
    app, client = await _make_client(tmp_path, "jc-note")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "owner-key"})).json()["id"]
            aid = (await client.post(
                f"/api/rooms/{room_id}/assignments",
                json={"target_session_key": "s-a", "note": "並行處理其他問題",
                      "assigned_name": "除錯手"},
                headers={"X-Session-Key": "owner-key"},
            )).json()["id"]

            r = await client.post(f"/api/rooms/{room_id}/join", json={
                "kind": "claude", "session_key": "s-a", "assignment_id": aid})
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["assignment_note"] == "並行處理其他問題"
            assert body["name_from_assignment"] is True
            assert body["room"]["name"] == "房"


async def test_note_comes_back_on_rejoin(tmp_path):
    """resume 之後 rejoin 也要拿得到——那正是 note 最容易掉的時刻。

    watcher 的指派事件是一次性的：進程重啟、context 滾掉之後，那句話就再也
    沒有第二個出口。冪等 rejoin 是 agent 回到房裡的正常路徑，不能是空的。
    """
    app, client = await _make_client(tmp_path, "jc-rejoin")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "owner-key"})).json()["id"]
            aid = (await client.post(
                f"/api/rooms/{room_id}/assignments",
                json={"target_session_key": "s-a", "note": "看住 sweeper"},
                headers={"X-Session-Key": "owner-key"},
            )).json()["id"]
            await client.post(f"/api/rooms/{room_id}/join", json={
                "kind": "claude", "session_key": "s-a", "assignment_id": aid})

            again = await client.post(f"/api/rooms/{room_id}/join",
                                      json={"kind": "claude", "session_key": "s-a"})
            assert again.status_code == 200, again.text
            body = again.json()
            assert body["rejoined"] is True
            assert body["assignment_note"] == "看住 sweeper"
            assert body["room"]["id"] == room_id


async def test_no_assignment_means_no_note_key(tmp_path):
    """自己走進來的沒有 note——回空字串會讓 agent 以為有人交代過什麼。"""
    app, client = await _make_client(tmp_path, "jc-plain")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "owner-key"})).json()["id"]
            r = await client.post(f"/api/rooms/{room_id}/join",
                                  json={"kind": "claude", "session_key": "s-a"})
            assert "assignment_note" not in r.json()


async def test_subagent_join_also_gets_room(tmp_path):
    """subagent 同樣需要——它不進訊息流，房間脈絡更沒有別的來源。"""
    app, client = await _make_client(tmp_path, "jc-sub")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={
                "name": "房", "topic": "T", "session_key": "owner-key"})).json()["id"]
            parent = (await client.post(f"/api/rooms/{room_id}/join", json={
                "kind": "claude", "session_key": "s-p",
                "preferred_name": "Parent"})).json()
            r = await client.post(f"/api/rooms/{room_id}/join", json={
                "kind": "claude", "session_key": "s-p#tester-a1b2c3d4",
                "preferred_name": "Child",
                "parent_participant_id": parent["participant_id"]})
            assert r.status_code == 200, r.text
            assert r.json()["room"]["topic"] == "T"
