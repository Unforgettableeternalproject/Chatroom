"""R-4 修復回歸：既有訊息的釘選/刪除變更要能被增量 cursor 掃到並推播。

另含奈也盤點的契約補強：房間指派列表、房間列表最後活動、回覆原文摘要。
"""

import pytest
from fastapi.testclient import TestClient
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


def _cfg(tmp_path, name):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token="")


@pytest.mark.asyncio
async def test_pin_and_delete_visible_via_updates_cursor(tmp_path):
    app = create_app(_cfg(tmp_path, "touch"))
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            p = (
                await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude", "session_key": "s1"},
                )
            ).json()
            headers = {"X-Participant-Id": p["participant_id"]}
            mid = (
                await client.post(
                    f"/api/rooms/{room_id}/messages",
                    json={"content": "重要"}, headers=headers,
                )
            ).json()["id"]

            # 讀到底，拿到 cursor
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates", params={"after_seq": 0, "timeout": 1}
                )
            ).json()
            cursor = data["last_seq"]

            # 釘選既有訊息 → 同一 cursor 應該掃得到該訊息的新狀態
            await client.post(f"/api/messages/{mid}/pin", headers=headers)
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": cursor, "timeout": 1},
                )
            ).json()
            changed = {m["id"]: m for m in data["messages"]}
            assert mid in changed and changed[mid]["pinned"] is True
            cursor = data["last_seq"]

            # 軟刪除同理
            await client.delete(f"/api/messages/{mid}")
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": cursor, "timeout": 1},
                )
            ).json()
            changed = {m["id"]: m for m in data["messages"]}
            assert mid in changed and changed[mid]["deleted"] is True
            # cursor 繼續前進，不會重複收到
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": data["last_seq"], "timeout": 0.2},
                )
            ).json()
            assert data["messages"] == []


def test_ws_receives_pin_change_of_old_message(tmp_path):
    """兩個視角驗證：WS 訂閱者要能收到「別人」釘選舊訊息的變更。"""
    app = create_app(_cfg(tmp_path, "wspin"))
    with TestClient(app) as client:
        room_id = client.post("/api/rooms", json={"name": "房"}).json()["id"]
        p = client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "claude", "session_key": "s1"},
        ).json()
        headers = {"X-Participant-Id": p["participant_id"]}
        mid = client.post(
            f"/api/rooms/{room_id}/messages",
            json={"content": "決策"}, headers=headers,
        ).json()["id"]

        with client.websocket_connect("/ws") as ws:
            ws.send_json({"type": "subscribe", "room_id": room_id, "after_seq": 0})
            ws.receive_json()  # 既有訊息批
            client.post(f"/api/messages/{mid}/pin", headers=headers)
            evt = ws.receive_json()
            pinned = {m["id"]: m["pinned"] for m in evt["messages"]}
            assert pinned.get(mid) is True


@pytest.mark.asyncio
async def test_room_assignments_and_list_metadata_and_reply_preview(tmp_path):
    app = create_app(_cfg(tmp_path, "meta"))
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            aid = (
                await client.post(
                    f"/api/rooms/{room_id}/assignments",
                    json={"target_session_key": "sx", "note": "來"},
                )
            ).json()["id"]
            await client.post(f"/api/assignments/{aid}/resolve", json={"status": "declined"})

            # 房間視角的指派列表（含已解決的）
            data = (await client.get(f"/api/rooms/{room_id}/assignments")).json()
            assert [a["status"] for a in data["assignments"]] == ["declined"]

            # 房間列表帶最後活動資訊
            p = (
                await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude", "session_key": "s1", "preferred_name": "Nova"},
                )
            ).json()
            rooms = (await client.get("/api/rooms")).json()["rooms"]
            assert rooms[0]["last_seq"] >= 1
            assert rooms[0]["last_activity_at"] is not None

            # 回覆原文摘要
            headers = {"X-Participant-Id": p["participant_id"]}
            mid = (
                await client.post(
                    f"/api/rooms/{room_id}/messages",
                    json={"content": "原文" * 100}, headers=headers,
                )
            ).json()["id"]
            await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "回覆", "reply_to": mid}, headers=headers,
            )
            msgs = (await client.get(f"/api/rooms/{room_id}/messages")).json()["messages"]
            reply = msgs[-1]
            assert reply["reply_preview"]["sender_name"] == "Nova"
            assert len(reply["reply_preview"]["excerpt"]) == 80
