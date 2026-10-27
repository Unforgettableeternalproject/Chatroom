"""訊息的表情回應。

表情不是訊息：不佔房內 seq、不碰 update_seq、不喚醒 long-poll 與 watcher。
每人對同一則訊息同時只有一個表情（選另一個＝替換，選同一個再按＝取消）。
agent 只能對人類發的訊息按；人類可以按任何未刪除的一般訊息。
"""

import json
import sqlite3
import urllib.parse

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.testclient import TestClient

from chatroom_server.app import REACTION_EMOJIS, create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

THUMB, HEART, EYES, CHECK = "\U0001F44D", "❤️", "\U0001F440", "✅"


def _cfg(tmp_path, name="rx"):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token="")


async def _make(tmp_path, name="rx"):
    app = create_app(_cfg(tmp_path, name))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _join(client, room_id, key, name, role="human", kind="human"):
    return (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": key, "preferred_name": name,
              "role": role},
    )).json()


async def _say(client, room_id, sender, text):
    return (await client.post(
        f"/api/rooms/{room_id}/messages", json={"content": text},
        headers=_pid(sender))).json()


def _url(mid, emoji):
    return f"/api/messages/{mid}/reactions/{urllib.parse.quote(emoji)}"


async def _setup(client):
    room_id = (await client.post(
        "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
    alice = await _join(client, room_id, "owner", "Alice")
    bob = await _join(client, room_id, "bob-k", "Bob")
    bot = await _join(client, room_id, "bot-k", "Bot", role="agent", kind="claude")
    return room_id, alice, bob, bot


async def _zed(client, room_id):
    """第四個人類，專門當發話者——自己不能對自己的訊息按表情。"""
    return await _join(client, room_id, "zed-k", "Zed")


async def _msgs(client, room_id, viewer, reactions=True):
    params = {"include_reactions": "true"} if reactions else {}
    return (await client.get(f"/api/rooms/{room_id}/messages", params=params,
                             headers=_pid(viewer))).json()["messages"]


async def _rx(client, room_id, viewer, mid):
    return next(x for x in await _msgs(client, room_id, viewer)
                if x["id"] == mid)["reactions"]


async def _last_seq(client, room_id):
    rooms = (await client.get("/api/rooms",
                              params={"session_key": "owner"})).json()["rooms"]
    return next(r for r in rooms if r["id"] == room_id)["last_seq"]


async def test_add_replace_cancel_and_idempotent(tmp_path):
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, _ = await _setup(client)
        m = await _say(client, room_id, await _zed(client, room_id), "早安")

        r = await client.put(_url(m["id"], THUMB), headers=_pid(alice))
        assert r.status_code == 200 and r.json()["changed"] is True
        # 同一個再加：冪等
        r = await client.put(_url(m["id"], THUMB), headers=_pid(alice))
        assert r.status_code == 200 and r.json()["changed"] is False
        await client.put(_url(m["id"], THUMB), headers=_pid(bob))

        got = await _rx(client, room_id, alice, m["id"])
        assert got == [{"emoji": THUMB, "count": 2, "mine": True,
                        "names": ["Alice", "Bob"]}]

        # 換表情＝替換：Alice 只剩新的，舊的 count 跟著少
        r = await client.put(_url(m["id"], HEART), headers=_pid(alice))
        assert r.json()["changed"] is True
        got = {x["emoji"]: x for x in
               await _rx(client, room_id, alice, m["id"])}
        assert got[THUMB]["count"] == 1 and got[THUMB]["mine"] is False
        assert got[HEART]["count"] == 1 and got[HEART]["mine"] is True

        # 取消：只刪自己現在選的那個；對沒選的表情取消是 no-op
        r = await client.delete(_url(m["id"], THUMB), headers=_pid(alice))
        assert r.json()["changed"] is False
        r = await client.delete(_url(m["id"], HEART), headers=_pid(alice))
        assert r.json()["changed"] is True
        got = await _rx(client, room_id, alice, m["id"])
        assert [x["emoji"] for x in got] == [THUMB]
        assert got[0]["mine"] is False


async def test_unique_key_is_per_person_per_message(tmp_path):
    """唯一鍵由資料庫保證，不只靠 endpoint 的邏輯。"""
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, _, _ = await _setup(client)
        m = await _say(client, room_id, await _zed(client, room_id), "x")
        await client.put(_url(m["id"], THUMB), headers=_pid(alice))
        await client.put(_url(m["id"], HEART), headers=_pid(alice))
        con = sqlite3.connect(str(tmp_path / "rx.db"))
        try:
            rows = con.execute(
                "SELECT emoji FROM message_reaction WHERE message_id=?",
                (m["id"],)).fetchall()
            assert rows == [(HEART,)]
            with pytest.raises(sqlite3.IntegrityError):
                con.execute(
                    "INSERT INTO message_reaction VALUES (?,?,?,?,?)",
                    (m["id"], alice["participant_id"], THUMB, room_id, "t"))
        finally:
            con.close()


async def test_whitelist_and_variation_selector(tmp_path):
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, _, _ = await _setup(client)
        m = await _say(client, room_id, await _zed(client, room_id), "x")
        r = await client.put(_url(m["id"], "\U0001F4A9"), headers=_pid(alice))
        assert r.status_code == 400
        d = r.json()["detail"]
        assert d["code"] == "invalid_reaction" and d["allowed"] == list(REACTION_EMOJIS)
        # 不帶 variation selector 的 ❤ 也認得，存的是標準寫法
        r = await client.put(_url(m["id"], "❤"), headers=_pid(alice))
        assert r.status_code == 200 and r.json()["emoji"] == HEART


async def test_agent_may_react_only_to_human_messages(tmp_path):
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, bot = await _setup(client)
        human_msg = await _say(client, room_id, await _zed(client, room_id), "請看")
        other_bot = await _join(client, room_id, "bot2-k", "Bot2",
                                role="agent", kind="claude")
        bot_msg = await _say(client, room_id, other_bot, "好")
        r = await client.put(_url(human_msg["id"], EYES), headers=_pid(bot))
        assert r.status_code == 200
        r = await client.put(_url(bot_msg["id"], EYES), headers=_pid(bot))
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "reaction_human_message_only"
        # 人類可以按 agent 的訊息
        r = await client.put(_url(bot_msg["id"], CHECK), headers=_pid(bob))
        assert r.status_code == 200
        # agent 按的表情也出現在名單裡，並標出是 agent
        got = await _rx(client, room_id, alice, human_msg["id"])
        assert got[0]["names"] == ["Bot"]
        who = (await client.get(f"/api/messages/{human_msg['id']}/reactions",
                                headers=_pid(alice))).json()["reactors"]
        assert who[0]["name"] == "Bot" and who[0]["role"] == "agent"


async def test_refusals(tmp_path):
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, _ = await _setup(client)
        other = (await client.post(
            "/api/rooms", json={"name": "別房", "session_key": "o2"})).json()["id"]
        stranger = await _join(client, other, "s", "Stranger")
        m = await _say(client, room_id, await _zed(client, room_id), "x")

        # 非成員（身分屬於別的房）
        r = await client.put(_url(m["id"], THUMB), headers=_pid(stranger))
        assert r.status_code == 403
        # 沒帶身分
        r = await client.put(_url(m["id"], THUMB))
        assert r.status_code == 401

        # system 訊息
        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(alice))).json()["messages"]
        sysm = next(x for x in msgs if x["kind"] == "system")
        r = await client.put(_url(sysm["id"], THUMB), headers=_pid(alice))
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "not_a_chat_message"

        # 已刪除訊息
        await client.delete(f"/api/messages/{m['id']}", headers=_pid(alice))
        r = await client.put(_url(m["id"], THUMB), headers=_pid(bob))
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "message_deleted"

        # 封存房
        m2 = await _say(client, room_id, await _zed(client, room_id), "y")
        await client.post(f"/api/rooms/{room_id}/archive",
                          headers={"X-Session-Key": "owner"})
        r = await client.put(_url(m2["id"], THUMB), headers=_pid(alice))
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "room_archived"


async def test_reaction_does_not_touch_seq_or_updates(tmp_path):
    """表情回應不佔 seq、不推進 update_seq，/updates 看不到任何新東西。"""
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, bot = await _setup(client)
        m = await _say(client, room_id, await _zed(client, room_id), "x")
        cursor = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": 0, "timeout": 1},
            headers=_pid(bot))).json()["last_seq"]
        before_seq = await _last_seq(client, room_id)

        await client.put(_url(m["id"], THUMB), headers=_pid(bob))
        await client.put(_url(m["id"], HEART), headers=_pid(bob))
        await client.delete(_url(m["id"], HEART), headers=_pid(bob))

        assert await _last_seq(client, room_id) == before_seq
        upd = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": cursor, "timeout": 1},
            headers=_pid(bot))).json()
        assert upd["messages"] == []
        con = sqlite3.connect(str(tmp_path / "rx.db"))
        try:
            assert con.execute(
                "SELECT update_seq FROM message WHERE id=?", (m["id"],)
            ).fetchone() == (0,)
        finally:
            con.close()


async def test_agent_reads_do_not_include_reactions(tmp_path):
    """預設（bridge 走的）讀取不附 reactions；/updates 也不附。"""
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, bot = await _setup(client)
        m = await _say(client, room_id, await _zed(client, room_id), "x")
        await client.put(_url(m["id"], THUMB), headers=_pid(bob))
        plain = await _msgs(client, room_id, bot, reactions=False)
        assert all("reactions" not in x for x in plain)
        upd = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": 0, "timeout": 1}, headers=_pid(bot))).json()
        assert all("reactions" not in x for x in upd["messages"])


async def test_departed_member_reaction_is_kept_with_name(tmp_path):
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, _ = await _setup(client)
        m = await _say(client, room_id, await _zed(client, room_id), "x")
        await client.put(_url(m["id"], THUMB), headers=_pid(bob))
        await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(bob))
        got = await _rx(client, room_id, alice, m["id"])
        assert got[0]["count"] == 1 and got[0]["names"] == ["Bob"]


async def test_room_reactions_resync_endpoint(tmp_path):
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, _ = await _setup(client)
        m1 = await _say(client, room_id, await _zed(client, room_id), "a")
        m2 = await _say(client, room_id, await _zed(client, room_id), "b")
        await client.put(_url(m1["id"], THUMB), headers=_pid(bob))
        await client.put(_url(m2["id"], EYES), headers=_pid(bob))
        r = (await client.get(f"/api/rooms/{room_id}/reactions",
                              params={"min_seq": m2["seq"]},
                              headers=_pid(bob))).json()["reactions"]
        assert list(r) == [m2["id"]] and r[m2["id"]][0]["mine"] is True


def _next_of(ws, type_, tries=10):
    for _ in range(tries):
        evt = json.loads(ws.receive_text())
        if evt.get("type") == type_:
            return evt
    raise AssertionError(f"沒有收到 {type_}")


def test_ws_pushes_reaction_event_without_messages_event(tmp_path):
    app = create_app(_cfg(tmp_path, "ws"))
    with TestClient(app) as tc:
        room_id = tc.post("/api/rooms", json={"name": "房", "session_key": "o"}
                          ).json()["id"]
        alice = tc.post(f"/api/rooms/{room_id}/join", json={
            "kind": "human", "role": "human", "session_key": "a",
            "preferred_name": "Alice"}).json()
        bob = tc.post(f"/api/rooms/{room_id}/join", json={
            "kind": "human", "role": "human", "session_key": "b",
            "preferred_name": "Bob"}).json()
        zed = tc.post(f"/api/rooms/{room_id}/join", json={
            "kind": "human", "role": "human", "session_key": "z",
            "preferred_name": "Zed"}).json()
        mid = tc.post(f"/api/rooms/{room_id}/messages", json={"content": "hi"},
                      headers=_pid(zed)).json()["id"]
        with tc.websocket_connect("/ws") as ws:
            ws.send_json({"type": "subscribe", "room_id": room_id,
                          "after_seq": 0,
                          "participant_id": alice["participant_id"]})
            first = _next_of(ws, "messages")
            assert first["messages"][0]["reactions"] == []
            tc.put(_url(mid, THUMB), headers=_pid(bob))
            evt = _next_of(ws, "reaction")
            assert evt["message_id"] == mid and evt["room_id"] == room_id
            assert evt["reactions"] == [{"emoji": THUMB, "count": 1,
                                         "mine": False, "names": ["Bob"]}]
            # 不能再冒出 messages 事件：下一個事件必須是 pong
            ws.send_json({"type": "ping"})
            nxt = json.loads(ws.receive_text())
            while nxt.get("type") == "board":
                nxt = json.loads(ws.receive_text())
            assert nxt["type"] == "pong"
            # 自己按的，mine 以這條連線的身分計算
            tc.put(_url(mid, HEART), headers=_pid(alice))
            evt = _next_of(ws, "reaction")
            assert {x["emoji"]: x["mine"] for x in evt["reactions"]} == {
                THUMB: False, HEART: True}


async def test_table_created_on_existing_db(tmp_path):
    """舊 DB（沒有這張表）開起來會補上，且可重入。"""
    app, client = await _make(tmp_path, "mig")
    async with app.router.lifespan_context(app), client:
        pass
    con = sqlite3.connect(str(tmp_path / "mig.db"))
    con.execute("DROP TABLE message_reaction")
    con.commit()
    con.close()
    for _ in range(2):
        app = create_app(_cfg(tmp_path, "mig"))
        async with app.router.lifespan_context(app):
            pass
    con = sqlite3.connect(str(tmp_path / "mig.db"))
    try:
        cols = [r[1] for r in con.execute("PRAGMA table_info(message_reaction)")]
        assert cols == ["message_id", "participant_id", "emoji", "room_id",
                        "created_at"]
    finally:
        con.close()


async def test_cannot_react_to_own_message_but_can_remove_old_one(tmp_path):
    """對自己的訊息 PUT 被拒（403 reaction_own_message）；DELETE 不擋，
    讓舊資料能移除。"""
    app, client = await _make(tmp_path)
    async with app.router.lifespan_context(app), client:
        room_id, alice, bob, bot = await _setup(client)
        m = await _say(client, room_id, alice, "我說的")
        r = await client.put(_url(m["id"], THUMB), headers=_pid(alice))
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "reaction_own_message"
        assert await _rx(client, room_id, alice, m["id"]) == []
        # agent 對自己的訊息同樣不行
        bm = await _say(client, room_id, bot, "好")
        r = await client.put(_url(bm["id"], EYES), headers=_pid(bot))
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "reaction_own_message"
        # 別人仍可按
        r = await client.put(_url(m["id"], THUMB), headers=_pid(bob))
        assert r.status_code == 200
        # 舊資料：直接塞一筆自己對自己的表情，DELETE 仍能移除
        con = sqlite3.connect(str(tmp_path / "rx.db"))
        try:
            con.execute(
                "INSERT INTO message_reaction VALUES (?,?,?,?,?)",
                (m["id"], alice["participant_id"], HEART, room_id, "t"))
            con.commit()
        finally:
            con.close()
        r = await client.delete(_url(m["id"], HEART), headers=_pid(alice))
        assert r.status_code == 200 and r.json()["changed"] is True
