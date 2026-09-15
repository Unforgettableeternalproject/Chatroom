"""編輯訊息。

**刪掉看得出來，改掉看不出來。** 所以編輯的門檻刻意比刪除嚴：刪除是本人
或房間建立者（建立者管得了房間秩序），編輯只限本人——建立者不該改得動別人
說過的話。三者（刪除／匯出／編輯）的權限模型各自獨立，不互相沿用。

編輯**不動 mentions**（2026-08-31 裁定）。Hub 的喚醒判定只認新訊息，前提是
「update 路徑不會新增 mention」；一旦編輯能補 @ 人，那條界線就會把正當的
喚醒吃掉，而症狀是「我 @ 了他，他沒醒」，全程零錯誤。要 @ 新的人就發新訊息。
那個前提由 tests/test_update_seq_mention_invariant.py 守著。
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


async def _room(client, key="owner"):
    return (await client.post(
        "/api/rooms", json={"name": "房", "session_key": key})).json()["id"]


async def _join(client, room_id, key, name):
    return (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human", "session_key": key,
              "preferred_name": name, "role": "human"},
    )).json()


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _say(client, room_id, sender, text, mentions=None):
    return (await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": text, "mentions": mentions or []}, headers=_pid(sender),
    )).json()


async def test_author_can_edit_and_it_is_marked_as_edited(tmp_path):
    """改過的訊息要看得出來改過——沒有標記的編輯就是無聲改寫歷史。"""
    app, client = await _make(tmp_path, "edit")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "owner", "Xavier")
        m = await _say(client, room_id, me, "說錯了")

        r = await client.patch(f"/api/messages/{m['id']}",
                               json={"content": "更正後"}, headers=_pid(me))
        assert r.status_code == 200, r.text

        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(me))).json()["messages"]
        edited = next(x for x in msgs if x["id"] == m["id"])
        assert edited["content"] == "更正後"
        assert edited["edited_at"], "改過卻沒有標記，等於無聲改寫歷史"


async def test_edit_reaches_people_who_already_read_it(tmp_path):
    """編輯要走既有的 update_seq 推播管線，不需要新的通道。

    已經讀過那則的人，cursor 已經越過它——不推進 update_seq 的話，他手上
    永遠是舊內容，而畫面看起來完全正常。
    """
    app, client = await _make(tmp_path, "propagate")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "owner", "Xavier")
        other = await _join(client, room_id, "guest", "Guest")
        m = await _say(client, room_id, me, "原文")

        cursor = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": 0, "timeout": 1}, headers=_pid(other),
        )).json()["last_seq"]

        await client.patch(f"/api/messages/{m['id']}",
                           json={"content": "改過的"}, headers=_pid(me))

        data = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": cursor, "timeout": 1}, headers=_pid(other),
        )).json()
        changed = {x["id"]: x for x in data["messages"]}
        assert m["id"] in changed
        assert changed[m["id"]]["content"] == "改過的"


async def test_editing_does_not_wake_anyone_again(tmp_path):
    """改自己的舊訊息，不該把當初被 @ 的人再叫醒一次。

    這是 update_seq 重新入流的既有語意；編輯只是又一個會觸發它的動作。
    """
    app, client = await _make(tmp_path, "nowake")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "owner", "Xavier")
        guest = await _join(client, room_id, "guest", "Guest")
        m = await _say(client, room_id, me, "@Guest 看一下", ["Guest"])

        data = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": 0, "timeout": 1}, headers=_pid(guest),
        )).json()
        assert data["you_were_mentioned"] is True  # 第一次是正當的
        cursor = data["last_seq"]

        await client.patch(f"/api/messages/{m['id']}",
                           json={"content": "@Guest 看一下（補充）"}, headers=_pid(me))

        data = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": cursor, "timeout": 1}, headers=_pid(guest),
        )).json()
        # 正向錨點：這一批確實有東西，「沒被叫醒」不是因為根本沒收到
        assert any(x["id"] == m["id"] for x in data["messages"])
        assert data["you_were_mentioned"] is False


async def test_only_the_author_can_edit_not_even_the_room_creator(tmp_path):
    """建立者刪得掉、改不動。

    刪掉看得出來（留下占位），改掉看不出來——所以編輯的門檻不沿用刪除那條。
    """
    app, client = await _make(tmp_path, "author_only")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        creator = await _join(client, room_id, "owner", "Xavier")
        guest = await _join(client, room_id, "guest", "Guest")
        m = await _say(client, room_id, guest, "我說的話")

        # 建立者：刪得掉（既有行為），但改不動
        r = await client.patch(f"/api/messages/{m['id']}",
                               json={"content": "我幫你改"}, headers=_pid(creator))
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_message_author"

        # 沒帶身分是 401 不是 403：「你沒說你是誰」與「你不是作者」處置不同
        assert (await client.patch(f"/api/messages/{m['id']}",
                                   json={"content": "x"})).status_code == 401

        # 內容沒有被動到
        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(guest))).json()["messages"]
        assert next(x for x in msgs if x["id"] == m["id"])["content"] == "我說的話"


async def test_mentions_are_not_editable(tmp_path):
    """編輯只改內文。

    Hub 的喚醒界線假設 update 路徑不新增 mention。開放改 mentions 就得存
    「上一版的 mentions」做 diff，而禁掉它這個坑直接關閉——要 @ 新的人就
    發新訊息，那也比較誠實。
    """
    app, client = await _make(tmp_path, "no_mentions")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "guest", "Guest")
        m = await _say(client, room_id, me, "原文")

        r = await client.patch(
            f"/api/messages/{m['id']}",
            json={"content": "改過", "mentions": ["Guest"]}, headers=_pid(me),
        )
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "mentions_not_editable"


async def test_what_cannot_be_edited(tmp_path):
    app, client = await _make(tmp_path, "refuse")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "owner", "Xavier")

        # 已刪除的：改一則已經撤回的訊息，等於讓它復活
        gone = await _say(client, room_id, me, "撤回我")
        await client.delete(f"/api/messages/{gone['id']}", headers=_pid(me))
        r = await client.patch(f"/api/messages/{gone['id']}",
                               json={"content": "復活"}, headers=_pid(me))
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "message_deleted"

        # 空內容：那不是編輯，是撤回，而撤回有自己的端點
        alive = await _say(client, room_id, me, "還在")
        r = await client.patch(f"/api/messages/{alive['id']}",
                               json={"content": "   "}, headers=_pid(me))
        assert r.status_code == 422

        # system 訊息沒有作者，不存在「本人」
        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(me))).json()["messages"]
        sys_msg = next(x for x in msgs if x["kind"] == "system")
        r = await client.patch(f"/api/messages/{sys_msg['id']}",
                               json={"content": "改系統訊息"}, headers=_pid(me))
        assert r.status_code in (403, 422)


async def test_archived_room_is_read_only_for_edits_too(tmp_path):
    """封存房唯讀。發言擋了、編輯沒擋的話，那條唯讀就是半套的。"""
    app, client = await _make(tmp_path, "archived")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "owner", "Xavier")
        m = await _say(client, room_id, me, "封存前")
        await client.post(f"/api/rooms/{room_id}/archive", headers=_pid(me))

        r = await client.patch(f"/api/messages/{m['id']}",
                               json={"content": "封存後偷改"}, headers=_pid(me))
        assert r.status_code == 409
