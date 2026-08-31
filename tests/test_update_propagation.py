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
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": 0, "timeout": 1}, headers=headers,
                )
            ).json()
            cursor = data["last_seq"]

            # 釘選既有訊息 → 同一 cursor 應該掃得到該訊息的新狀態
            await client.post(f"/api/messages/{mid}/pin", headers=headers)
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": cursor, "timeout": 1}, headers=headers,
                )
            ).json()
            changed = {m["id"]: m for m in data["messages"]}
            assert mid in changed and changed[mid]["pinned"] is True
            cursor = data["last_seq"]

            # 軟刪除同理
            await client.delete(f"/api/messages/{mid}", headers=headers)
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": cursor, "timeout": 1}, headers=headers,
                )
            ).json()
            changed = {m["id"]: m for m in data["messages"]}
            assert mid in changed and changed[mid]["deleted"] is True
            # cursor 繼續前進，不會重複收到
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/updates",
                    params={"after_seq": data["last_seq"], "timeout": 0.2}, headers=headers,
                )
            ).json()
            assert data["messages"] == []


@pytest.mark.asyncio
async def test_pinning_an_old_message_does_not_rementions_its_targets(tmp_path):
    """釘選一則舊訊息，不該把當初被 @ 的人再喚醒一次。

    狀態變更會讓原訊息重新落進 updates 批次（那是預期行為，client 要看到
    新的 pinned 狀態）；但 ``you_were_mentioned`` 若跟著整批算，被 @ 的人
    就會為了一句幾天前的話醒來。判定只認新訊息。
    """
    app = create_app(_cfg(tmp_path, "remention"))
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]

            async def join(key, name):
                return (await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude", "session_key": key,
                          "preferred_name": name},
                )).json()

            a, b, c = (await join("sa", "A"), await join("sb", "B"),
                       await join("sc", "C"))
            hb = {"X-Participant-Id": b["participant_id"]}

            mid = (await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "@B 看一下", "mentions": ["B"]},
                headers={"X-Participant-Id": a["participant_id"]},
            )).json()["id"]

            # B 讀掉那則（醒過一次，這是正當的）
            data = (await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": 0, "timeout": 1}, headers=hb,
            )).json()
            assert data["you_were_mentioned"] is True
            cursor = data["last_seq"]

            # C 釘選那則舊訊息
            await client.post(
                f"/api/messages/{mid}/pin",
                headers={"X-Participant-Id": c["participant_id"]},
            )
            data = (await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": cursor, "timeout": 1}, headers=hb,
            )).json()
            # 正向錨點：這一批確實有東西（原訊息重投＋釘選收據），
            # 「沒被 mention」不是因為測試根本沒跑起來
            assert any(m["id"] == mid for m in data["messages"])
            assert data["you_were_mentioned"] is False
            cursor = data["last_seq"]

            # 反向錨點：真的有人在新訊息裡 @ B，照樣要醒
            await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "@B 這次是新的", "mentions": ["B"]},
                headers={"X-Participant-Id": c["participant_id"]},
            )
            data = (await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": cursor, "timeout": 1}, headers=hb,
            )).json()
            assert data["you_were_mentioned"] is True


@pytest.mark.asyncio
async def test_new_member_does_not_inherit_the_previous_namesakes_mentions(tmp_path):
    """名字會被回收，舊的 @ 不該跟著轉手給下一個同名的人。

    房內唯一名稱只約束 active 成員，所以離開者的名字會被釋出；而 mentions
    存的是名字字串。沒有 joined_seq 這條界線的話，帶著同一個名字進來的下
    一個人第一次拉歷史（after_seq=0）必定命中前一任的 @。
    """
    app = create_app(_cfg(tmp_path, "namesake"))
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]

            async def join(key):
                return (await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude", "session_key": key,
                          "preferred_name": "Novia"},
                )).json()

            a = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "sa", "preferred_name": "A"},
            )).json()
            first = await join("s-old")
            assert first["display_name"] == "Novia"

            await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "@Novia 這件事給你", "mentions": ["Novia"]},
                headers={"X-Participant-Id": a["participant_id"]},
            )
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": first["participant_id"]},
            )

            # 名字被釋出，下一個人拿到同一個 Novia
            second = await join("s-new")
            assert second["display_name"] == "Novia"
            hs = {"X-Participant-Id": second["participant_id"]}

            data = (await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": 0, "timeout": 1}, headers=hs,
            )).json()
            # 正向錨點：那則舊訊息確實在這一批裡（他讀得到歷史），
            # 只是不該因此被叫醒
            assert any("這件事給你" in m["content"] for m in data["messages"])
            assert data["you_were_mentioned"] is False
            cursor = data["last_seq"]

            # 反向錨點：加入之後的 @ 照樣要醒
            await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "@Novia 這次是給你的", "mentions": ["Novia"]},
                headers={"X-Participant-Id": a["participant_id"]},
            )
            data = (await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": cursor, "timeout": 1}, headers=hs,
            )).json()
            assert data["you_were_mentioned"] is True


def _next_messages(ws):
    """取下一則 messages 事件。

    帶身分訂閱時 pump 會先推一則 ``questions``（多半是空清單）——那是定向
    問題的通道，與訊息共用同一條 socket。測試要的是訊息，跳過其餘事件。
    """
    while True:
        evt = ws.receive_json()
        if evt["type"] == "messages":
            return evt


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
            # 訂閱要帶身分：WS 是 App 的主要讀取通道，不驗成員等於留一扇後門
            ws.send_json({"type": "subscribe", "room_id": room_id, "after_seq": 0,
                          "participant_id": p["participant_id"]})
            _next_messages(ws)  # 既有訊息批
            client.post(f"/api/messages/{mid}/pin", headers=headers)
            evt = _next_messages(ws)
            pinned = {m["id"]: m["pinned"] for m in evt["messages"]}
            assert pinned.get(mid) is True


@pytest.mark.asyncio
async def test_room_assignments_and_list_metadata_and_reply_preview(tmp_path):
    app = create_app(_cfg(tmp_path, "meta"))
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "owner-key"})).json()["id"]
            aid = (
                await client.post(
                    f"/api/rooms/{room_id}/assignments",
                    json={"target_session_key": "sx", "note": "來"},
                )
            ).json()["id"]
            await client.post(f"/api/assignments/{aid}/resolve",
                              json={"status": "declined"},
                              headers={"X-Session-Key": "sx"})

            # 房間視角的指派列表（含已解決的）
            data = (await client.get(
                f"/api/rooms/{room_id}/assignments",
                headers={"X-Session-Key": "owner-key"})).json()
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
            msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                              headers=headers)).json()["messages"]
            reply = msgs[-1]
            assert reply["reply_preview"]["sender_name"] == "Nova"
            assert len(reply["reply_preview"]["excerpt"]) == 80
