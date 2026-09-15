"""房間是讀取的邊界，不只是名冊。

起因：測試人員回報「被踢出的人仍然看得到聊天室」。實測屬實——所有讀取端點
原本只驗 token，不驗成員，所以被踢的人照樣讀得到全部歷史、還能掛 long-poll
收即時訊息，只是不能發言。**只擋寫入的移除，在使用者眼中就是沒有生效。**

門檻定義是「**曾經**是這個房的成員，且不是被踢出的」：
- 被踢 → 讀不到（這是整件事的目的）
- 自己離開、閒置被移出 → 仍讀得到歷史（離開不是銷毀自己的紀錄）
- 從未加入 → 讀不到（房間成為真的邊界）
- 建立者 → 房間詳情與指派列表讀得到（指派 UI 開在「自己還沒進去」的空窗上）
"""

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.testclient import TestClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

# ⚠️ 這個檔**刻意不寫** `pytestmark = pytest.mark.asyncio`（別的測試檔有，
# 那是慣例）：底下 `test_websocket_subscribe_refuses_non_members` 是同步的
# （`TestClient` 的 WS 只有同步介面），而檔案層的 mark 會連它一起標，
# pytest 每跑一次就叫一次。`pytest.ini` 是 `asyncio_mode = auto`，async
# 測試不必標也會被收，所以那一行本來就是冗餘的。


def _cfg(tmp_path, name):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token="")


async def _make(tmp_path, name):
    app = create_app(_cfg(tmp_path, name))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name, role="human", kind="human"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key,
              "preferred_name": name, "role": role},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _room(client, session_key="admin-key"):
    r = await client.post("/api/rooms",
                          json={"name": "房", "session_key": session_key})
    return r.json()["id"]


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _read_paths(client, room_id, headers):
    """所有「讀房內內容」的路徑，回傳 {路徑: status}。"""
    return {
        "detail": (await client.get(f"/api/rooms/{room_id}",
                                    headers=headers)).status_code,
        "messages": (await client.get(f"/api/rooms/{room_id}/messages",
                                      headers=headers)).status_code,
        "updates": (await client.get(f"/api/rooms/{room_id}/updates",
                                     params={"timeout": 0.1},
                                     headers=headers)).status_code,
        "questions": (await client.get(f"/api/rooms/{room_id}/questions",
                                       headers=headers)).status_code,
        "assignments": (await client.get(f"/api/rooms/{room_id}/assignments",
                                         headers=headers)).status_code,
    }


async def test_a_stranger_reads_nothing(tmp_path):
    """沒有身分就什麼都讀不到——這是「房間是邊界」的最小陳述。"""
    app, client = await _make(tmp_path, "stranger")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        await _join(client, room_id, "admin-key", "Xavier")

        codes = await _read_paths(client, room_id, {})
        assert set(codes.values()) == {401}, codes

        # 別房的身分也不行：participant 是房間層級身分
        other_room = await _room(client, "other-admin")
        outsider = await _join(client, other_room, "other-admin", "Outsider")
        codes = await _read_paths(client, room_id, _pid(outsider))
        assert set(codes.values()) == {403}, codes


async def test_kicked_member_loses_read_access(tmp_path):
    """這條就是使用者回報的那件事。"""
    app, client = await _make(tmp_path, "kicked")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "admin-key", "Xavier")
        guest = await _join(client, room_id, "guest-key", "Guest")

        # 被踢之前讀得到
        assert set((await _read_paths(client, room_id, _pid(guest))).values()) == {200}

        await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers=_pid(admin),
        )

        codes = await _read_paths(client, room_id, _pid(guest))
        assert set(codes.values()) == {403}, codes
        r = await client.get(f"/api/rooms/{room_id}/messages", headers=_pid(guest))
        # 錯誤碼要說得出「為什麼」：被踢與閒置移除，呼叫端的處置完全不同
        assert r.json()["detail"]["code"] == "participant_kicked"


async def test_leaving_does_not_erase_your_own_history(tmp_path):
    """離開不是銷毀自己的紀錄。要求 active 會讓封存房唯讀瀏覽整個消失。"""
    app, client = await _make(tmp_path, "left")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        await _join(client, room_id, "admin-key", "Xavier")
        me = await _join(client, room_id, "my-key", "Me")
        await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(me))

        assert (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(me))).status_code == 200
        assert (await client.get(f"/api/rooms/{room_id}",
                                 headers=_pid(me))).status_code == 200
        # 但即時通道要 active 身分：已經離開的人不需要推送
        assert (await client.get(f"/api/rooms/{room_id}/updates",
                                 params={"timeout": 0.1},
                                 headers=_pid(me))).status_code == 403


async def test_creator_can_open_a_room_before_joining_it(tmp_path):
    """指派 UI 開在「自己還沒進去」的空窗上——邀請別人本來就發生在那時候。"""
    app, client = await _make(tmp_path, "creator")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client, "owner-key")
        owner = {"X-Session-Key": "owner-key"}

        assert (await client.get(f"/api/rooms/{room_id}",
                                 headers=owner)).status_code == 200
        assert (await client.get(f"/api/rooms/{room_id}/assignments",
                                 headers=owner)).status_code == 200
        # 但訊息內容仍要真的進來才讀得到——建立者例外只開到「房主視角」為止
        assert (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=owner)).status_code == 401


async def test_attachments_follow_the_same_boundary(tmp_path):
    """附件跟著訊息走，門檻就跟著訊息一樣——否則檔案是房間邊界的破口。"""
    app, client = await _make(tmp_path, "attach")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "admin-key", "Xavier")
        guest = await _join(client, room_id, "guest-key", "Guest")

        r = await client.post(
            f"/api/rooms/{room_id}/attachments",
            headers=_pid(admin),
            files={"file": ("secret.txt", "房內機密".encode("utf-8"), "text/plain")},
        )
        assert r.status_code == 200, r.text
        aid = r.json()["id"]

        assert (await client.get(f"/api/attachments/{aid}",
                                 headers=_pid(guest))).status_code == 200
        await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers=_pid(admin),
        )
        assert (await client.get(f"/api/attachments/{aid}",
                                 headers=_pid(guest))).status_code == 403
        assert (await client.get(f"/api/attachments/{aid}/meta",
                                 headers=_pid(guest))).status_code == 403


def test_websocket_subscribe_refuses_non_members(tmp_path):
    """WS 是 App 的主要讀取通道。REST 收緊而這裡沒收，等於整件事白做。"""
    app = create_app(_cfg(tmp_path, "ws"))
    with TestClient(app) as client:
        room_id = client.post(
            "/api/rooms", json={"name": "房", "session_key": "admin-key"}
        ).json()["id"]
        admin = client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "human", "session_key": "admin-key",
                  "preferred_name": "Xavier", "role": "human"},
        ).json()
        guest = client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "human", "session_key": "guest-key",
                  "preferred_name": "Guest", "role": "human"},
        ).json()

        with client.websocket_connect("/ws") as ws:
            # 沒有身分：直接拒絕
            ws.send_json({"type": "subscribe", "room_id": room_id, "after_seq": 0})
            evt = ws.receive_json()
            assert evt["type"] == "error"

            # 有身分：正常收到訊息批
            ws.send_json({"type": "subscribe", "room_id": room_id, "after_seq": 0,
                          "participant_id": guest["participant_id"]})
            while True:
                evt = ws.receive_json()
                if evt["type"] == "messages":
                    break

        client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers={"X-Participant-Id": admin["participant_id"]},
        )
        with client.websocket_connect("/ws") as ws:
            ws.send_json({"type": "subscribe", "room_id": room_id, "after_seq": 0,
                          "participant_id": guest["participant_id"]})
            evt = ws.receive_json()
            assert evt["type"] == "error"
            assert evt["code"] == "participant_kicked"
