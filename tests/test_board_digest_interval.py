"""任務板可調 supervisor 摘要間隔（`board.digest_interval_sec`）。

NULL＝用 Hub 預設（`board_digest_interval`）；範圍 60～86400 秒，超出回 400；
只有板 owner 改得動（沿用 PATCH /api/boards/{id} 的權限）。
"""

from datetime import timedelta

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 sweep_interval=3600, **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _setup(client):
    """一間房、一塊掛上去的板、人類 owner、已指定的 supervisor。"""
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "human-1"})).json()["id"]
    owner = await _join(client, rid, "human-1", "Bernie", role="human")
    await _join(client, rid, "agent-sup", "Nova")
    bid = (await client.post("/api/boards",
                             json={"name": "板", "origin_room_id": rid},
                             headers=owner)).json()["id"]
    r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
    assert r.status_code == 200, r.text
    return rid, bid, owner


async def _digests(client, rid, hdr):
    msgs = (await client.get(f"/api/rooms/{rid}/messages",
                             headers=hdr)).json()["messages"]
    return [m for m in msgs if m["system_event"] == "board_digest"]


async def _change_then_sweep(app, client, rid, owner, backdate_sec):
    """製造一筆變動、掃一輪（記下起算點）、把起算點往前撥、再掃一輪。"""
    await client.post(f"/api/rooms/{rid}/board/objectives",
                      json={"title": "週期"}, headers=owner)
    await app.state.sweep_once()
    pending = app.state.board_digest_pending_since
    assert rid in pending, "第一輪要記下起算點"
    pending[rid] = pending[rid] - timedelta(seconds=backdate_sec)
    await app.state.sweep_once()


async def test_board_value_is_used_instead_of_the_default(tmp_path):
    app, client = await _client(tmp_path, "board-val",
                                board_digest_interval=3600.0)
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        r = await client.patch(f"/api/boards/{bid}",
                               json={"digest_interval_sec": 60}, headers=owner)
        assert r.status_code == 200, r.text
        assert r.json()["digest_interval_sec"] == 60
        assert r.json()["digest_interval_default"] == 3600

        await _change_then_sweep(app, client, rid, owner, backdate_sec=120)
        assert len(await _digests(client, rid, owner)) == 1, \
            "板設 60 秒、已等 120 秒就該送"


async def test_null_falls_back_to_the_hub_default(tmp_path):
    app, client = await _client(tmp_path, "null-default",
                                board_digest_interval=3600.0)
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        await _change_then_sweep(app, client, rid, owner, backdate_sec=120)
        assert await _digests(client, rid, owner) == [], \
            "沒設＝用 Hub 預設 3600 秒，等 120 秒不該送"


async def test_a_longer_board_value_holds_the_digest_back(tmp_path):
    app, client = await _client(tmp_path, "board-long",
                                board_digest_interval=0.0)
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        await client.patch(f"/api/boards/{bid}",
                           json={"digest_interval_sec": 3600}, headers=owner)
        await _change_then_sweep(app, client, rid, owner, backdate_sec=120)
        assert await _digests(client, rid, owner) == []


async def test_range_is_validated_with_a_400(tmp_path):
    app, client = await _client(tmp_path, "range")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        for bad in (59, 0, -5, 86401):
            r = await client.patch(f"/api/boards/{bid}",
                                   json={"digest_interval_sec": bad},
                                   headers=owner)
            assert r.status_code == 400, (bad, r.text)
            assert r.json()["detail"]["code"] == "invalid_digest_interval"
            assert "秒" in r.json()["detail"]["message"]
        for ok in (60, 86400):
            r = await client.patch(f"/api/boards/{bid}",
                                   json={"digest_interval_sec": ok},
                                   headers=owner)
            assert r.status_code == 200, (ok, r.text)


async def test_null_resets_to_default_and_omitting_leaves_it(tmp_path):
    app, client = await _client(tmp_path, "reset")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        await client.patch(f"/api/boards/{bid}",
                           json={"digest_interval_sec": 300}, headers=owner)
        # 只改名字：間隔不動
        await client.patch(f"/api/boards/{bid}", json={"name": "新名字"},
                           headers=owner)
        body = (await client.get(f"/api/boards/{bid}", headers=owner)).json()
        assert body["digest_interval_sec"] == 300
        assert body["digest_interval_default"] == 900
        # 明確送 null：改回預設
        r = await client.patch(f"/api/boards/{bid}",
                               json={"digest_interval_sec": None},
                               headers=owner)
        assert r.status_code == 200, r.text
        body = (await client.get(f"/api/boards/{bid}", headers=owner)).json()
        assert body["digest_interval_sec"] is None


async def test_only_the_owner_may_change_it(tmp_path):
    app, client = await _client(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        other = await _join(client, rid, "agent-2", "路人")
        r = await client.patch(f"/api/boards/{bid}",
                               json={"digest_interval_sec": 300}, headers=other)
        assert r.status_code == 403, r.text
        body = (await client.get(f"/api/boards/{bid}", headers=owner)).json()
        assert body["digest_interval_sec"] is None


async def test_contributions_carries_the_value_for_the_settings_page(tmp_path):
    app, client = await _client(tmp_path, "contrib")
    async with app.router.lifespan_context(app), client:
        rid, bid, owner = await _setup(client)
        await client.patch(f"/api/boards/{bid}",
                           json={"digest_interval_sec": 1800}, headers=owner)
        r = await client.get(f"/api/boards/{bid}/contributions", headers=owner)
        assert r.status_code == 200, r.text
        board = r.json()["board"]
        assert board["digest_interval_sec"] == 1800
        assert board["digest_interval_default"] == 900


async def test_old_db_gets_the_column(tmp_path):
    path = str(tmp_path / "old.db")
    db = await open_db(path)
    await db.executescript("ALTER TABLE board DROP COLUMN digest_interval_sec;")
    await db.commit()
    await db.close()
    db = await open_db(path)
    try:
        cols = {r["name"] for r in await (await db.execute(
            "PRAGMA table_info(board)")).fetchall()}
        assert "digest_interval_sec" in cols
    finally:
        await db.close()
