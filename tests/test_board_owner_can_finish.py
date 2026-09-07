"""板 owner 與主持人推得動別人認領的卡（09/07 卡 0a19355051 + a03fa6e8）。

艾斯維爾 09/06 實測：人類、而且是板的創建者，從 **Board 分頁**想把別人接的
卡標 done，被回「沒有權限」；從聊天室進去做同一件事卻可以。

根因不是權限判斷寫錯，是**判準裡根本沒有 owner 這一項**：能推動別人的卡的
只有「持有者本人」與「人類成員」，而「人類」是從 participant 的 role 讀的
——板軸沒有房，走到那條路的人拿不到 participant，`role` 就被填成 `agent`。
於是板 owner 在自己的板上是一個沒有份量的 actor。

兩軸行為一致是驗收條件，所以這裡兩條路都測。
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


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    return r.json()["participant_id"]


async def _setup(client):
    """一塊板、一個人類 owner、一張被 agent 認領的卡。

    owner **不在**板掛的房裡——那正是從 Board Library 進來的樣子，也是
    「板軸拿不到 participant」的來源。
    """
    rid = (await client.post("/api/rooms", json={
        "name": "工作房", "session_key": "human-1"})).json()["id"]
    # owner 先在別的地方以人類身分存在過，board_member 才記得住 kind
    other = (await client.post("/api/rooms", json={
        "name": "owner 自己的房", "session_key": "human-1"})).json()["id"]
    await _join(client, other, "human-1", "Bernie", role="human")
    agent = await _join(client, rid, "claude-1", "Novia")

    bid = (await client.post("/api/boards",
                             headers={"X-Session-Key": "human-1"},
                             json={"name": "板"})).json()["id"]
    att = await client.post(f"/api/boards/{bid}/rooms/{rid}",
                            headers={"X-Session-Key": "human-1"})
    assert att.status_code == 200, att.text
    tid = (await client.post(f"/api/boards/{bid}/tasks",
                             headers={"X-Session-Key": "human-1"},
                             json={"title": "別人的卡"})).json()["id"]
    r = await client.post(f"/api/board/tasks/{tid}/claim",
                          headers={"X-Participant-Id": agent})
    assert r.status_code == 200, r.text
    return bid, tid, rid, agent


async def test_the_board_owner_can_finish_someone_elses_card(tmp_path):
    """板軸這條路——`X-Session-Key`、沒有 participant。"""
    app, client = await _client(tmp_path, "owner-done")
    async with app.router.lifespan_context(app), client:
        _, tid, _, _ = await _setup(client)
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              headers={"X-Session-Key": "human-1"},
                              json={"status": "done"})
        assert r.status_code == 200, r.text


async def test_a_plain_member_still_cannot(tmp_path):
    """放寬的是 owner，不是所有人。別人的卡仍然是別人的。"""
    app, client = await _client(tmp_path, "member-blocked")
    async with app.router.lifespan_context(app), client:
        bid, tid, rid, _ = await _setup(client)
        outsider = await _join(client, rid, "claude-2", "旁人")
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              headers={"X-Participant-Id": outsider},
                              json={"status": "done"})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_claim_holder"


async def test_the_host_counts_as_the_owner_of_every_board(tmp_path):
    """主持人視同所有板的 owner（艾斯維爾 09/06 產品裁定，卡 a03fa6e8）。

    Hub 主持人本來就讀得到同一個目錄下的 `chatroom.db`；這裡給的不是新權限，
    是把既有能力變得可用——與 `host_view` 當初的理由一字不差。
    """
    app, client = await _client(tmp_path, "host-done")
    async with app.router.lifespan_context(app), client:
        _, tid, _, _ = await _setup(client)
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              headers={"X-Host-View": "1",
                                       "X-Session-Key": "someone-else"},
                              json={"status": "done"})
        assert r.status_code == 200, r.text


async def test_the_room_axis_behaves_the_same(tmp_path):
    """兩軸一致是這張卡的驗收條件——房裡的人類本來就做得到，
    別在修板軸的時候把它弄壞。"""
    app, client = await _client(tmp_path, "room-axis")
    async with app.router.lifespan_context(app), client:
        _, tid, rid, _ = await _setup(client)
        human = await _join(client, rid, "human-1", "Bernie", role="human")
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              headers={"X-Participant-Id": human},
                              json={"status": "done"})
        assert r.status_code == 200, r.text
