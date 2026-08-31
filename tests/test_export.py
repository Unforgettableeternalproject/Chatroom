"""匯出整房對話（jsonl）。

匯出與刪除的威脅模型不同，門檻不可互相沿用：**刪除是破壞，匯出是外流**——
它把整個房間打包成一個檔案交出去。所以權限走 `_member_or_403`（曾經是成員
即可，被踢的不行），不是只驗 token。

封存房必須匯得出來，那才是主要用途：房間可以被永久刪除，而那不可逆。
"""

import json

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


async def _join(client, room_id, key, name):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human", "session_key": key,
              "preferred_name": name, "role": "human"},
    )
    return r.json()


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


def _lines(text: str) -> list[dict]:
    return [json.loads(ln) for ln in text.splitlines() if ln.strip()]


async def test_export_returns_one_json_object_per_line(tmp_path):
    app, client = await _make(tmp_path, "basic")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = await _join(client, room_id, "owner", "Xavier")
        for i in range(3):
            await client.post(f"/api/rooms/{room_id}/messages",
                              json={"content": f"第 {i} 則"}, headers=_pid(me))

        r = await client.get(f"/api/rooms/{room_id}/export", headers=_pid(me))
        assert r.status_code == 200, r.text
        rows = _lines(r.text)

        # 系統訊息（join）也要在裡面：匯出是完整紀錄，不是聊天摘要
        assert [m["content"] for m in rows if m["kind"] == "chat"] == [
            "第 0 則", "第 1 則", "第 2 則"]
        assert [m["seq"] for m in rows] == sorted(m["seq"] for m in rows)


async def test_export_goes_beyond_the_read_page_limit(tmp_path):
    """匯出的是整個房，不是第一頁。

    read_messages 的 limit 上限是 500，匯出若只是它的包裝，超過的部分會
    安靜地不見——而檔案看起來完全正常。
    """
    app, client = await _make(tmp_path, "big")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = await _join(client, room_id, "owner", "Xavier")
        for i in range(520):
            await client.post(f"/api/rooms/{room_id}/messages",
                              json={"content": f"m{i}"}, headers=_pid(me))

        r = await client.get(f"/api/rooms/{room_id}/export", headers=_pid(me))
        chat = [m for m in _lines(r.text) if m["kind"] == "chat"]
        assert len(chat) == 520
        assert chat[-1]["content"] == "m519"


async def test_export_is_an_exfiltration_boundary(tmp_path):
    app, client = await _make(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        admin = await _join(client, room_id, "owner", "Xavier")
        guest = await _join(client, room_id, "guest", "Guest")
        await client.post(f"/api/rooms/{room_id}/messages",
                          json={"content": "房內機密"}, headers=_pid(admin))

        # 沒有身分：只有 token 不足以把整個房間帶走
        assert (await client.get(f"/api/rooms/{room_id}/export")).status_code == 401

        # 別房的身分也不行
        other = (await client.post(
            "/api/rooms", json={"name": "別房", "session_key": "x"})).json()["id"]
        outsider = await _join(client, other, "x", "Outsider")
        assert (await client.get(f"/api/rooms/{room_id}/export",
                                 headers=_pid(outsider))).status_code == 403

        # 成員可以
        assert (await client.get(f"/api/rooms/{room_id}/export",
                                 headers=_pid(guest))).status_code == 200

        # 被踢之後不行——讀不到的人也不該打包帶走
        await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers=_pid(admin),
        )
        assert (await client.get(f"/api/rooms/{room_id}/export",
                                 headers=_pid(guest))).status_code == 403


async def test_archived_room_can_still_be_exported(tmp_path):
    """封存房是匯出的主要用途——房間可以被永久刪除，而那不可逆。"""
    app, client = await _make(tmp_path, "archived")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = await _join(client, room_id, "owner", "Xavier")
        await client.post(f"/api/rooms/{room_id}/messages",
                          json={"content": "留著"}, headers=_pid(me))
        await client.post(f"/api/rooms/{room_id}/archive", headers=_pid(me))

        r = await client.get(f"/api/rooms/{room_id}/export", headers=_pid(me))
        assert r.status_code == 200, r.text
        assert any(m["content"] == "留著" for m in _lines(r.text))


async def test_export_keeps_deletion_visible_and_does_not_inline_attachments(tmp_path):
    """撤回要看得出來是撤回；附件只出 metadata。

    內嵌 base64 會讓一次匯出變成幾百 MB——訊息有 32KB 上限，附件沒有。
    """
    app, client = await _make(tmp_path, "shape")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = await _join(client, room_id, "owner", "Xavier")

        aid = (await client.post(
            f"/api/rooms/{room_id}/attachments", headers=_pid(me),
            files={"file": ("圖.png", b"\x89PNG\r\n\x1a\n" + b"0" * 64, "image/png")},
        )).json()["id"]
        await client.post(
            f"/api/rooms/{room_id}/messages",
            json={"content": "附件在此", "attachment_ids": [aid]}, headers=_pid(me),
        )
        doomed = (await client.post(
            f"/api/rooms/{room_id}/messages",
            json={"content": "說錯了"}, headers=_pid(me))).json()["id"]
        await client.delete(f"/api/messages/{doomed}", headers=_pid(me))

        r = await client.get(f"/api/rooms/{room_id}/export", headers=_pid(me))
        rows = {m["id"]: m for m in _lines(r.text)}

        assert rows[doomed]["deleted"] is True
        assert rows[doomed]["content"] == ""

        withfile = next(m for m in rows.values() if m["content"] == "附件在此")
        assert withfile["attachments"][0]["filename"] == "圖.png"
        assert "data" not in withfile["attachments"][0]
        assert "content_base64" not in withfile["attachments"][0]


async def test_unknown_format_is_refused_rather_than_silently_jsonl(tmp_path):
    """要求 csv 卻拿到 jsonl，比報錯難查得多。"""
    app, client = await _make(tmp_path, "fmt")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = await _join(client, room_id, "owner", "Xavier")

        r = await client.get(f"/api/rooms/{room_id}/export",
                             params={"format": "csv"}, headers=_pid(me))
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "unsupported_format"
