"""封存房的列表可見性：看得到就該進得去。"""
import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test")


async def test_archived_public_room_hidden_from_non_members(tmp_path):
    """封存的公開房對非成員不顯示——它是個死胡同。

    公開房出現在陌生人的列表上是刻意的（發現並加入的入口），但那個理由
    只對 active 成立：封存房不能 join（409），讀取又要成員資格。看得到、
    點進去 401、也加入不了。
    """
    app, client = await _client(tmp_path, "vis")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "公開房", "session_key": "owner"})).json()["id"]
            await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human",
                "session_key": "owner", "preferred_name": "Owner"})

            # 還活著的時候：陌生人看得到（那是入口）
            rooms = (await client.get(
                "/api/rooms", params={"session_key": "stranger"})).json()
            assert any(r["id"] == rid for r in rooms["rooms"])

            await client.post(f"/api/rooms/{rid}/archive",
                              headers={"X-Session-Key": "owner"})

            # 封存之後：陌生人看不到了
            rooms = (await client.get("/api/rooms", params={
                "status": "archived", "session_key": "stranger"})).json()
            assert all(r["id"] != rid for r in rooms["rooms"]), \
                "封存的公開房不該出現在非成員的列表上"

            # 但成員仍看得到——封存房唯讀瀏覽是刻意保留的功能
            rooms = (await client.get("/api/rooms", params={
                "status": "archived", "session_key": "owner"})).json()
            assert any(r["id"] == rid for r in rooms["rooms"])


async def test_every_listed_archived_room_is_actually_readable(tmp_path):
    """守門條件：列表上的每一個封存房都要真的讀得到。

    「看得到卻讀不到」是使用者實際撞到的形狀，這條把兩套判準綁在一起。
    """
    app, client = await _client(tmp_path, "consistent")
    async with client:
        async with app.router.lifespan_context(app):
            for i, vis in enumerate(("public", "private")):
                rid = (await client.post("/api/rooms", json={
                    "name": f"房{i}", "session_key": "owner",
                    "visibility": vis})).json()["id"]
                await client.post(f"/api/rooms/{rid}/join", json={
                    "kind": "human", "role": "human",
                    "session_key": "owner", "preferred_name": f"O{i}"})
                await client.post(f"/api/rooms/{rid}/archive",
                                  headers={"X-Session-Key": "owner"})

            me = await client.post("/api/rooms", json={
                "name": "我的房", "session_key": "me"})
            mine = me.json()["id"]
            j = (await client.post(f"/api/rooms/{mine}/join", json={
                "kind": "human", "role": "human",
                "session_key": "me", "preferred_name": "Me"})).json()
            await client.post(f"/api/rooms/{mine}/archive",
                              headers={"X-Session-Key": "me"})

            rooms = (await client.get("/api/rooms", params={
                "status": "archived", "session_key": "me"})).json()["rooms"]
            assert rooms, "至少要看得到自己的房"
            for r in rooms:
                got = await client.get(
                    f"/api/rooms/{r['id']}/messages",
                    headers={"X-Participant-Id": j["participant_id"]})
                assert got.status_code == 200, (
                    f"「{r['name']}」出現在列表上卻讀不到（{got.status_code}）"
                    "——列表與讀取用了兩套判準")
