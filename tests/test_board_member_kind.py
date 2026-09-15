"""建板的人是誰——`board_member.actor_kind` 要留下來。

這一欄看起來只是拿來顯示，實際上它是**權限判定的輸入**：想法板的守門靠它
分辨「人類的段落」與「agent 的段落」（BOARD_DESIGN §15.1）。空著的話，
建板的人自己會被當成 agent，於是**在他自己開的板上改不動別人寫的東西**。

`_ensure_board_for_room`（換軸時自動建板）一直有帶，只有顯式的
`POST /api/boards` 漏了——兩條路建出來的板不一樣，而那個差別在權限出問題
之前完全看不出來。
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


async def _kind(app, bid, actor):
    row = await (await app.state.db.execute(
        "SELECT actor_kind, display_name FROM board_member"
        " WHERE board_id=? AND actor_key=?", (bid, actor))).fetchone()
    return row["actor_kind"], row["display_name"]


async def test_creating_a_board_from_a_room_keeps_who_you_are(tmp_path):
    """顯式建板：`POST /api/boards` 帶著房內身分時，kind 要跟著進去。"""
    app, client = await _client(tmp_path, "explicit")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "claude-h"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-h",
                "preferred_name": "艾斯維爾"})
            hdr = {"X-Participant-Id": j.json()["participant_id"],
                   "X-Session-Key": "claude-h"}
            bid = (await client.post("/api/boards",
                                     json={"name": "我的板"},
                                     headers=hdr)).json()["id"]
            kind, name = await _kind(app, bid, "claude-h")
            assert name == "艾斯維爾"
            assert kind == "human", (
                "建板者的 kind 沒留下來。想法板的守門用它分辨人類與 agent，"
                "空著的話他在自己開的板上會被當成 agent")


async def test_both_ways_of_getting_a_board_agree(tmp_path):
    """換軸自動建板與顯式建板，**建出來的成員列要是同一種東西**。

    兩條路長出不同形狀的資料，是那種要等到很久以後才會有人發現的問題——
    而發現的當下沒有人記得這兩條路曾經不一樣。
    """
    app, client = await _client(tmp_path, "both")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "claude-h"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-h",
                "preferred_name": "艾斯維爾"})
            hdr = {"X-Participant-Id": j.json()["participant_id"]}
            # 在房裡建一張卡 ⇒ 換軸時自動建板
            await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": "週期"}, headers=hdr)
            auto = (await client.get(f"/api/rooms/{rid}/board",
                                     headers=hdr)).json()["board_id"]
            assert (await _kind(app, auto, "claude-h"))[0] == "human"
