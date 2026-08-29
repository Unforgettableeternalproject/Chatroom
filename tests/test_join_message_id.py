"""join 回應要交出「這次加入產生的那則 system 訊息」的精確身分。

client 首次進房的時序是：先以 null 身分訂閱 → 才 POST join。而 Hub 在 join
回應送出**之前**就 post 了加入訊息，所以它常常已經躺在 client 的暖 feed 裡，
接著被「首批快照只立基準線」當成歷史整個吃掉——同一台機器上的 agent 於是
不知道這個人進來了。

給出 id/seq，client 才能只補投「就是這一筆」，不必靠時間窗去猜哪則加入算
「剛剛發生」（那會被 Hub 與 client 的時鐘偏差打敗，而且要嘛放寬到重播歷史）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make_client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def test_join_returns_the_join_message_identity(tmp_path):
    app, client = await _make_client(tmp_path, "join_msg")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            joined = (
                await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude", "session_key": "s1", "preferred_name": "Novia"},
                )
            ).json()

            assert joined["join_message_id"]
            assert isinstance(joined["join_seq"], int)

            # 指的必須真的是那一則：id、seq、sender、system_event 全部對得上
            msgs = (await client.get(
                f"/api/rooms/{room_id}/messages",
                headers={"X-Participant-Id": joined["participant_id"]},
            )).json()["messages"]
            match = [m for m in msgs if m["id"] == joined["join_message_id"]]
            assert len(match) == 1
            msg = match[0]
            assert msg["seq"] == joined["join_seq"]
            assert msg["kind"] == "system"
            assert msg["system_event"] == "join"
            # sender 是加入者本人——client 靠它分辨誰進來了，不必解析中文內容
            assert msg["sender_id"] == joined["participant_id"]


async def test_idempotent_rejoin_has_no_join_message(tmp_path):
    """冪等 rejoin 沒有產生新的加入訊息，就不該給 id——否則 client 會補投一則舊的。"""
    app, client = await _make_client(tmp_path, "rejoin_msg")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            body = {"kind": "claude", "session_key": "s1", "preferred_name": "Novia"}
            first = (await client.post(f"/api/rooms/{room_id}/join", json=body)).json()
            again = (await client.post(f"/api/rooms/{room_id}/join", json=body)).json()

            assert again["rejoined"] is True
            assert again.get("join_message_id") is None
            assert again.get("join_seq") is None

            # 而且確實沒有第二則加入訊息
            msgs = (await client.get(
                f"/api/rooms/{room_id}/messages",
                headers={"X-Participant-Id": first["participant_id"]},
            )).json()["messages"]
            joins = [m for m in msgs if m.get("system_event") == "join"]
            assert len(joins) == 1
            assert joins[0]["id"] == first["join_message_id"]
