"""回歸測試：Codex Phase 1 審核的兩個缺口。

1. 阻斷：Phase 0 舊 DB 升級——open_db 必須補上 room.activated_at 與
   message.update_seq，且升級可重入。
2. 中度：reply_to 必須指向同房既有訊息；preview 查詢帶 room_id 縱深防禦。
"""

import aiosqlite
import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.db import open_db

pytestmark = pytest.mark.asyncio

# Phase 0 當時的 schema 快照（room 無 activated_at、message 無 update_seq），
# 用來模擬已有資料的舊 DB。刻意硬編碼而非讀 git 歷史，讓測試自足。
PHASE0_SCHEMA = """
CREATE TABLE room (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    topic       TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'active',
    next_seq    INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    archived_at TEXT
);
CREATE TABLE participant (
    id           TEXT PRIMARY KEY,
    room_id      TEXT NOT NULL REFERENCES room(id),
    kind         TEXT NOT NULL,
    session_key  TEXT NOT NULL,
    display_name TEXT NOT NULL,
    role         TEXT NOT NULL DEFAULT 'agent',
    status       TEXT NOT NULL DEFAULT 'active',
    joined_at    TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    left_at      TEXT
);
CREATE TABLE message (
    id         TEXT PRIMARY KEY,
    room_id    TEXT NOT NULL REFERENCES room(id),
    seq        INTEGER NOT NULL,
    sender_id  TEXT REFERENCES participant(id),
    kind       TEXT NOT NULL DEFAULT 'chat',
    content    TEXT NOT NULL,
    mentions   TEXT NOT NULL DEFAULT '[]',
    reply_to   TEXT,
    pinned     INTEGER NOT NULL DEFAULT 0,
    pinned_by  TEXT,
    deleted    INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    UNIQUE(room_id, seq)
);
CREATE TABLE assignment (
    id                 TEXT PRIMARY KEY,
    room_id            TEXT NOT NULL REFERENCES room(id),
    target_session_key TEXT NOT NULL,
    note               TEXT NOT NULL DEFAULT '',
    status             TEXT NOT NULL DEFAULT 'pending',
    created_at         TEXT NOT NULL,
    resolved_at        TEXT
);
"""


async def _make_phase0_db(path: str) -> None:
    db = await aiosqlite.connect(path)
    await db.executescript(PHASE0_SCHEMA)
    await db.execute(
        "INSERT INTO room (id, name, next_seq, created_at) VALUES (?,?,?,?)",
        ("r0", "舊房間", 2, "2026-08-27T00:00:00+00:00"),
    )
    await db.execute(
        "INSERT INTO message (id, room_id, seq, kind, content, created_at)"
        " VALUES (?,?,?,?,?,?)",
        ("m0", "r0", 1, "chat", "舊訊息", "2026-08-27T00:00:01+00:00"),
    )
    await db.commit()
    await db.close()


async def _columns(db, table: str) -> set[str]:
    rows = await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
    return {r["name"] for r in rows}


async def test_phase0_db_upgrade(tmp_path):
    """舊 DB 經 open_db 後必須補齊新欄位，且既有資料可查。"""
    path = str(tmp_path / "old.db")
    await _make_phase0_db(path)

    db = await open_db(path)
    assert "activated_at" in await _columns(db, "room")
    assert "update_seq" in await _columns(db, "message")
    # 舊資料拿得到、預設值正確——Codex 重現的兩個 no such column 查詢
    room = await (
        await db.execute("SELECT activated_at FROM room WHERE id='r0'")
    ).fetchone()
    assert room["activated_at"] is None
    msg = await (
        await db.execute("SELECT update_seq FROM message WHERE id='m0'")
    ).fetchone()
    assert msg["update_seq"] == 0
    await db.close()

    # 可重入：再開一次不得報錯（duplicate column）
    db = await open_db(path)
    assert "update_seq" in await _columns(db, "message")
    await db.close()


async def test_app_works_on_upgraded_db(tmp_path):
    """升級後的舊 DB 要能跑完整 app 流程（發言、釘選走 update_seq 路徑）。"""
    path = str(tmp_path / "old_app.db")
    await _make_phase0_db(path)
    app = create_app(Config(db_path=path, api_token=""))
    client = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    async with client:
        async with app.router.lifespan_context(app):
            p = (
                await client.post(
                    "/api/rooms/r0/join",
                    json={"kind": "claude", "session_key": "s1"},
                )
            ).json()
            headers = {"X-Participant-Id": p["participant_id"]}
            mid = (
                await client.post(
                    "/api/rooms/r0/messages", json={"content": "升級後發言"},
                    headers=headers,
                )
            ).json()["id"]
            assert (
                await client.post(f"/api/messages/{mid}/pin", headers=headers)
            ).status_code == 200
            msgs = (await client.get("/api/rooms/r0/messages")).json()["messages"]
            assert any(m["id"] == "m0" for m in msgs)


async def _make_client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name=None):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_reply_target_validation(tmp_path):
    """reply_to 指向他房或不存在的訊息必須被 4xx 擋下；同房正常。"""
    app, client = await _make_client(tmp_path, "reply")
    async with client:
        async with app.router.lifespan_context(app):
            room_a = (await client.post("/api/rooms", json={"name": "A"})).json()["id"]
            room_b = (await client.post("/api/rooms", json={"name": "B"})).json()["id"]
            pa = await _join(client, room_a, "sa", "Alpha")
            pb = await _join(client, room_b, "sb", "Beta")
            ha = {"X-Participant-Id": pa["participant_id"]}
            hb = {"X-Participant-Id": pb["participant_id"]}
            b_mid = (
                await client.post(
                    f"/api/rooms/{room_b}/messages",
                    json={"content": "B 房祕密"}, headers=hb,
                )
            ).json()["id"]

            # 跨房 reply → 422，且不可落地
            r = await client.post(
                f"/api/rooms/{room_a}/messages",
                json={"content": "偷渡", "reply_to": b_mid}, headers=ha,
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "reply_target_not_found"

            # 不存在的目標 → 422
            r = await client.post(
                f"/api/rooms/{room_a}/messages",
                json={"content": "x", "reply_to": "no-such-id"}, headers=ha,
            )
            assert r.status_code == 422

            # 同房 reply 正常，preview 帶 sender 與摘要
            a_mid = (
                await client.post(
                    f"/api/rooms/{room_a}/messages",
                    json={"content": "A 房原文"}, headers=ha,
                )
            ).json()["id"]
            r = await client.post(
                f"/api/rooms/{room_a}/messages",
                json={"content": "回覆", "reply_to": a_mid}, headers=ha,
            )
            assert r.status_code == 200
            msgs = (await client.get(f"/api/rooms/{room_a}/messages")).json()["messages"]
            reply = next(m for m in msgs if m["reply_to"] == a_mid)
            assert reply["reply_preview"]["sender_name"] == "Alpha"
            assert reply["reply_preview"]["excerpt"] == "A 房原文"

            # A 房時間軸不得混入任何 B 房內容
            assert all("B 房祕密" not in (m["reply_preview"] or {}).get("excerpt", "")
                       for m in msgs if m["reply_preview"])


async def test_reply_preview_cross_room_defense(tmp_path):
    """縱深防禦：即使 DB 中被塞入跨房 reply_to，讀取端也不得洩漏他房內容。"""
    app, client = await _make_client(tmp_path, "defense")
    async with client:
        async with app.router.lifespan_context(app):
            room_a = (await client.post("/api/rooms", json={"name": "A"})).json()["id"]
            room_b = (await client.post("/api/rooms", json={"name": "B"})).json()["id"]
            pa = await _join(client, room_a, "sa")
            pb = await _join(client, room_b, "sb")
            b_mid = (
                await client.post(
                    f"/api/rooms/{room_b}/messages", json={"content": "B 房祕密"},
                    headers={"X-Participant-Id": pb["participant_id"]},
                )
            ).json()["id"]
            a_mid = (
                await client.post(
                    f"/api/rooms/{room_a}/messages", json={"content": "正常"},
                    headers={"X-Participant-Id": pa["participant_id"]},
                )
            ).json()["id"]
            # 繞過 API 直接竄改 DB，模擬歷史髒資料
            await app.state.db.execute(
                "UPDATE message SET reply_to=? WHERE id=?", (b_mid, a_mid)
            )
            await app.state.db.commit()
            msgs = (await client.get(f"/api/rooms/{room_a}/messages")).json()["messages"]
            dirty = next(m for m in msgs if m["id"] == a_mid)
            assert dirty["reply_preview"] is None
