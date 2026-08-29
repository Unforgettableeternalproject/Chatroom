"""成員清單去重：同一 session 換名重進不出現重複人員，舊名以 previous_name 附註。"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make_client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name=None, kind="claude"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_rename_rejoin_dedupes_with_previous_name(tmp_path):
    app, client = await _make_client(tmp_path, "dedupe")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            first = await _join(client, room_id, "s1", name="Bright-Drift")
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": first["participant_id"]},
            )
            second = await _join(client, room_id, "s1", name="Novia")
            await _join(client, room_id, "s2", name="Miller")

            data = (await client.get(
                f"/api/rooms/{room_id}",
                headers={"X-Participant-Id": second["participant_id"]})).json()
            participants = data["participants"]

            # s1 只出現一次（active 代表列），s2 照常
            assert len(participants) == 2
            mine = next(p for p in participants if p["id"] == second["participant_id"])
            assert mine["display_name"] == "Novia"
            assert mine["previous_name"] == "Bright-Drift"
            assert first["participant_id"] in mine["alias_ids"]
            # session_key 不可外流
            assert all("session_key" not in p for p in participants)


async def test_duplicate_name_between_left_and_active_gets_hint(tmp_path):
    """active 與已離開的成員重名時，各附消歧提示（agent 給 session 片段）。"""
    app, client = await _make_client(tmp_path, "duphint")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            first = await _join(client, room_id, "session-alpha", name="Nova")
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": first["participant_id"]},
            )
            beta = await _join(client, room_id, "session-beta", name="Nova")

            participants = (await client.get(
                f"/api/rooms/{room_id}",
                headers={"X-Participant-Id": beta["participant_id"]})).json()["participants"]
            assert len(participants) == 2
            hints = {p["distinct_hint"] for p in participants}
            # 兩個 Nova 各自帶「不同」的 session 尾碼，且不含整把 key
            assert len(hints) == 2
            for p in participants:
                assert len(p["distinct_hint"]) <= 8
                assert p["distinct_hint"] not in ("session-alpha", "session-beta")


async def test_unique_names_have_no_hint(tmp_path):
    app, client = await _make_client(tmp_path, "nohint")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            await _join(client, room_id, "s1", name="Nova")
            miller = await _join(client, room_id, "s2", name="Miller")
            participants = (await client.get(
                f"/api/rooms/{room_id}",
                headers={"X-Participant-Id": miller["participant_id"]})).json()["participants"]
            assert all("distinct_hint" not in p for p in participants)


async def test_same_name_rejoin_has_no_previous_name(tmp_path):
    app, client = await _make_client(tmp_path, "samename")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            first = await _join(client, room_id, "s1", name="Novia")
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": first["participant_id"]},
            )
            again = await _join(client, room_id, "s1", name="Novia")

            participants = (await client.get(
                f"/api/rooms/{room_id}",
                headers={"X-Participant-Id": again["participant_id"]})).json()["participants"]
            assert len(participants) == 1
            assert "previous_name" not in participants[0]
            assert first["participant_id"] in participants[0]["alias_ids"]
