"""訊息讀取的篩選與 tail：時間範圍、發言者、種類、卡片參照。

舊參數（after_seq / before_seq / limit）的行為不能變：watcher 與 agent 的
增量讀取依賴它。tail 是新增的 opt-in，不帶時與舊版相同。
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    app = create_app(Config(db_path=str(tmp_path / f"{name}.db"), api_token=""))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, name, kind, key):
    me = (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": key, "preferred_name": name,
              "role": "human" if kind == "human" else "agent"},
    )).json()
    return {"X-Participant-Id": me["participant_id"]}


async def _room(client):
    room_id = (await client.post(
        "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
    human = await _join(client, room_id, "Xavier", "human", "owner")
    agent = await _join(client, room_id, "Novia", "claude", "novia")
    return room_id, human, agent


async def _say(client, room_id, headers, text):
    return (await client.post(f"/api/rooms/{room_id}/messages",
                              json={"content": text}, headers=headers)).json()


async def _get(client, room_id, headers, **params):
    r = await client.get(f"/api/rooms/{room_id}/messages",
                         params=params, headers=headers)
    return r


def _contents(r):
    return [m["content"] for m in r.json()["messages"] if m["kind"] == "chat"]


async def test_tail_returns_newest_in_ascending_order(tmp_path):
    app, client = await _make(tmp_path, "tail")
    async with app.router.lifespan_context(app), client:
        room_id, human, _ = await _room(client)
        for i in range(10):
            await _say(client, room_id, human, f"m{i}")
        r = await _get(client, room_id, human, tail="true", limit=3)
        assert _contents(r) == ["m7", "m8", "m9"]
        assert r.json()["has_more"] is True
        seqs = [m["seq"] for m in r.json()["messages"]]
        assert seqs == sorted(seqs)
        assert r.json()["next_after_seq"] == seqs[-1]


async def test_default_without_tail_is_unchanged(tmp_path):
    """不帶新參數時仍是從 after_seq 起正向取最舊的 limit 則。"""
    app, client = await _make(tmp_path, "legacy")
    async with app.router.lifespan_context(app), client:
        room_id, human, _ = await _room(client)
        for i in range(6):
            await _say(client, room_id, human, f"m{i}")
        r = await _get(client, room_id, human, limit=2)
        msgs = r.json()["messages"]
        assert msgs[0]["seq"] < msgs[-1]["seq"]
        # 舊語意：取最舊那批，而不是最新
        assert "m5" not in _contents(r)


async def test_sender_and_sender_kind_filters(tmp_path):
    app, client = await _make(tmp_path, "sender")
    async with app.router.lifespan_context(app), client:
        room_id, human, agent = await _room(client)
        await _say(client, room_id, human, "from-human")
        await _say(client, room_id, agent, "from-agent")

        r = await _get(client, room_id, human, sender="Novia")
        assert _contents(r) == ["from-agent"]
        r = await _get(client, room_id, human, sender_kind="human")
        assert _contents(r) == ["from-human"]
        r = await _get(client, room_id, human, sender_kind="agent")
        assert _contents(r) == ["from-agent"]
        r = await _get(client, room_id, human, sender_kind="system")
        msgs = r.json()["messages"]
        assert msgs and all(m["kind"] == "system" for m in msgs)
        r = await _get(client, room_id, human, sender_kind="bogus")
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "invalid_sender_kind"


async def test_time_range_filter(tmp_path):
    app, client = await _make(tmp_path, "time")
    async with app.router.lifespan_context(app), client:
        room_id, human, _ = await _room(client)
        sent = [await _say(client, room_id, human, f"m{i}") for i in range(4)]
        db = app.state.db
        # 把四則訊息的時間釘成已知值（含一則帶微秒、一則不帶）
        stamps = ["2026-01-01T00:00:00+00:00", "2026-01-02T00:00:00.500000+00:00",
                  "2026-01-03T00:00:00+00:00", "2026-01-04T00:00:00+00:00"]
        for m, ts in zip(sent, stamps):
            await db.execute("UPDATE message SET created_at=? WHERE id=?",
                             (ts, m["id"]))
        await db.commit()

        r = await _get(client, room_id, human,
                       since="2026-01-02T00:00:00Z", until="2026-01-04T00:00:00Z")
        assert _contents(r) == ["m1", "m2"]  # 含 since、不含 until
        r = await _get(client, room_id, human, since="2026-01-03T00:00:00")
        assert _contents(r) == ["m2", "m3"]  # 無時區視為 UTC
        r = await _get(client, room_id, human, since="not-a-time")
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "invalid_time_filter"
        # 時間只是篩選；翻頁游標仍是 seq，可與 after_seq 組合
        r = await _get(client, room_id, human, since="2026-01-01T00:00:00Z",
                       after_seq=sent[1]["seq"])
        assert _contents(r) == ["m2", "m3"]


async def test_has_card_refs_filter_and_combination(tmp_path):
    app, client = await _make(tmp_path, "cards")
    async with app.router.lifespan_context(app), client:
        room_id, human, agent = await _room(client)
        a = await _say(client, room_id, human, "plain")
        b = await _say(client, room_id, agent, "with-card")
        c = await _say(client, room_id, human, "human-card")
        db = app.state.db
        ref = json.dumps([{"board_id": "b", "task_id": "t", "title": "T"}])
        for m in (b, c):
            await db.execute("UPDATE message SET card_refs=? WHERE id=?",
                             (ref, m["id"]))
        await db.commit()

        r = await _get(client, room_id, human, has_card_refs="true")
        assert _contents(r) == ["with-card", "human-card"]
        r = await _get(client, room_id, human, has_card_refs="true",
                       sender_kind="agent")
        assert _contents(r) == ["with-card"]
        # 篩選 + tail：符合條件的最新 1 則
        r = await _get(client, room_id, human, has_card_refs="true",
                       tail="true", limit=1)
        assert _contents(r) == ["human-card"]
        assert r.json()["has_more"] is True
        assert a["seq"] < b["seq"]


async def test_around_seq_rejects_filters(tmp_path):
    app, client = await _make(tmp_path, "around")
    async with app.router.lifespan_context(app), client:
        room_id, human, _ = await _room(client)
        m = await _say(client, room_id, human, "x")
        r = await _get(client, room_id, human, around_seq=m["seq"], sender="Novia")
        assert r.status_code == 422
