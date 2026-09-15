"""主持人視角視同所有板的 owner（09/07 卡 a03fa6e8）。

艾斯維爾 09/06 產品裁定。理由與 `host_view` 當初一字不差：主 token 放在
`server/.env`，拿得到它的人本來就讀得寫得同一個目錄下的 `chatroom.db`——
給的不是新權限，是把既有能力變得可用。

⚠️ 這條擴權**掛在人類憑證上**：09/07 起 `host_view` 只認 human token
（見 `test_human_agent_tokens.py`）。少了那道閘，每一個拿 bridge token 的
agent 都是每一塊板的 owner。

對照組一律附上：放寬的是主持人，不是所有人。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HOST = {"X-Host-View": "1"}


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _someone_elses_private_board(client):
    """別人的私人板——主持人不是它的成員，也不在它掛的房裡。"""
    rid = (await client.post("/api/rooms", json={
        "name": "別人的房", "session_key": "other-1",
        "visibility": "private"})).json()["id"]
    await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "claude", "role": "agent", "session_key": "other-1",
        "preferred_name": "別人"})
    bid = (await client.post("/api/boards",
                             headers={"X-Session-Key": "other-1"},
                             json={"name": "別人的板",
                                   "visibility": "private"})).json()["id"]
    await client.post(f"/api/boards/{bid}/rooms/{rid}",
                      headers={"X-Session-Key": "other-1"})
    return bid, rid


async def test_the_host_can_read_someone_elses_private_board(tmp_path):
    """症狀①：以主持人模式看別人的私人板會出錯（艾斯維爾 09/06 實測）。"""
    app, client = await _client(tmp_path, "host-read")
    async with app.router.lifespan_context(app), client:
        bid, _ = await _someone_elses_private_board(client)
        r = await client.get(f"/api/boards/{bid}", headers=HOST)
        assert r.status_code == 200, r.text
        assert r.json()["my_role"] == "owner"


async def test_a_stranger_still_cannot_read_it(tmp_path):
    """對照：沒開主持人模式的陌生人還是進不去。"""
    app, client = await _client(tmp_path, "stranger-read")
    async with app.router.lifespan_context(app), client:
        bid, _ = await _someone_elses_private_board(client)
        r = await client.get(f"/api/boards/{bid}",
                             headers={"X-Session-Key": "stranger-1"})
        assert r.status_code == 403, r.text


async def test_the_host_can_do_owner_only_things(tmp_path):
    """加減成員是 owner 專屬的六個操作之一。

    （不用「改可見性」當樣本：那條另有業務規則擋著——板還掛在房上時一律
    不能改，而那道閘與權限無關，測起來會分不出是哪一個擋的。）
    """
    app, client = await _client(tmp_path, "host-owner-op")
    async with app.router.lifespan_context(app), client:
        bid, _ = await _someone_elses_private_board(client)
        r = await client.post(f"/api/boards/{bid}/members", headers=HOST,
                              json={"actor_key": "newcomer-1",
                                    "display_name": "新來的"})
        assert r.status_code == 200, r.text


async def test_a_stranger_cannot_do_owner_only_things(tmp_path):
    app, client = await _client(tmp_path, "stranger-owner-op")
    async with app.router.lifespan_context(app), client:
        bid, _ = await _someone_elses_private_board(client)
        r = await client.post(f"/api/boards/{bid}/members",
                              headers={"X-Session-Key": "stranger-1"},
                              json={"actor_key": "newcomer-1",
                                    "display_name": "新來的"})
        assert r.status_code == 403, r.text


async def test_the_host_can_write_on_someone_elses_board(tmp_path):
    """寫入走的是另一條門檻（`_board_writer_v2`），要分開驗——
    「讀得到卻寫不動」正是這張卡最容易做出來的半套。"""
    app, client = await _client(tmp_path, "host-write")
    async with app.router.lifespan_context(app), client:
        bid, _ = await _someone_elses_private_board(client)
        r = await client.post(f"/api/boards/{bid}/tasks", headers=HOST,
                              json={"title": "主持人寫的卡"})
        assert r.status_code == 200, r.text


async def test_host_view_must_be_explicit(tmp_path):
    """主 token 本身不打穿門檻，要明示 `X-Host-View`——與 `host_view` 的
    既有語意一致：預設開著等於沒有開關。"""
    app, client = await _client(tmp_path, "host-explicit")
    async with app.router.lifespan_context(app), client:
        bid, _ = await _someone_elses_private_board(client)
        r = await client.get(f"/api/boards/{bid}",
                             headers={"X-Session-Key": "stranger-1",
                                      "X-Host-View": "0"})
        assert r.status_code == 403, r.text
