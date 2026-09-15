"""被踢或已離開的人不能再改動房內的訊息。

讀取邊界刻意允許「曾經是成員」的人讀歷史（離開不是銷毀自己的紀錄），而
**寫入不該沿用那條寬鬆**。編輯與刪除都只比對 `id + room_id`，沒有驗
`status='active'`——於是被踢的人手上那個 participant id 仍然有效，他照樣
改得動、刪得掉自己說過的話。

踢出的用意就是「這個人不能再影響這個房間」。擋得住發言卻擋不住改寫既有
發言，那條移除就是半套的——而畫面上完全看不出來（審核用 Codex 2026-08-31）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


def _cfg(tmp_path, name):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token="")


async def _make(tmp_path, name):
    app = create_app(_cfg(tmp_path, name))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _setup(client):
    room_id = (await client.post(
        "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]

    async def join(key, name):
        return (await client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "human", "session_key": key,
                  "preferred_name": name, "role": "human"},
        )).json()

    admin = await join("owner", "Xavier")
    guest = await join("guest", "Guest")
    return room_id, admin, guest


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _say(client, room_id, sender, text):
    return (await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": text}, headers=_pid(sender),
    )).json()


async def test_kicked_member_cannot_edit_their_own_messages(tmp_path):
    app, client = await _make(tmp_path, "kick_edit")
    async with app.router.lifespan_context(app), client:
        room_id, admin, guest = await _setup(client)
        m = await _say(client, room_id, guest, "我說的話")

        await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers=_pid(admin),
        )

        r = await client.patch(f"/api/messages/{m['id']}",
                               json={"content": "被踢之後偷改"}, headers=_pid(guest))
        assert r.status_code == 403, r.text

        # 內容真的沒被動到——擋下請求卻已經寫進去是最糟的那種「擋住了」
        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(admin))).json()["messages"]
        assert next(x for x in msgs if x["id"] == m["id"])["content"] == "我說的話"


async def test_kicked_member_cannot_delete_their_own_messages(tmp_path):
    """踢出擋得住發言卻擋不住撤回的話，那條移除是半套的。"""
    app, client = await _make(tmp_path, "kick_delete")
    async with app.router.lifespan_context(app), client:
        room_id, admin, guest = await _setup(client)
        m = await _say(client, room_id, guest, "留在這裡")

        await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers=_pid(admin),
        )

        r = await client.delete(f"/api/messages/{m['id']}", headers=_pid(guest))
        assert r.status_code == 403, r.text

        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(admin))).json()["messages"]
        assert next(x for x in msgs if x["id"] == m["id"])["deleted"] is False


async def test_a_member_who_left_cannot_edit_either(tmp_path):
    """離開的人讀得到歷史，但改不動它。

    讀與寫的門檻刻意不同：讀允許「曾經是成員」（離開不是銷毀自己的紀錄），
    寫要求「現在還在」。沿用同一條的話，任何離開過的人都保有永久的改寫權。
    """
    app, client = await _make(tmp_path, "left_edit")
    async with app.router.lifespan_context(app), client:
        room_id, admin, guest = await _setup(client)
        m = await _say(client, room_id, guest, "我先走了")
        await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(guest))

        r = await client.patch(f"/api/messages/{m['id']}",
                               json={"content": "走了還改"}, headers=_pid(guest))
        assert r.status_code == 403, r.text

        # 但他照樣讀得到歷史——那條寬鬆是刻意的，不要一起收掉
        assert (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(guest))).status_code == 200


async def test_active_member_is_unaffected(tmp_path):
    """反向錨點：正常成員照樣改得動、刪得掉。

    沒有這條的話，上面三條可以靠「編輯功能整個壞掉」一起變綠。
    """
    app, client = await _make(tmp_path, "ok")
    async with app.router.lifespan_context(app), client:
        room_id, _admin, guest = await _setup(client)
        m = await _say(client, room_id, guest, "原文")

        r = await client.patch(f"/api/messages/{m['id']}",
                               json={"content": "改過"}, headers=_pid(guest))
        assert r.status_code == 200, r.text
        r = await client.delete(f"/api/messages/{m['id']}", headers=_pid(guest))
        assert r.status_code == 200, r.text
