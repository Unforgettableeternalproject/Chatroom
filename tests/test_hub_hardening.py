"""P1-06 ~ P1-09 測試：分頁契約、指派過期、認證一致性、sweeper 韌性。"""

import asyncio
import logging

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


def _app(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **cfg_kw)
    return create_app(cfg)


async def _join(client, room_id, session_key, name=None, kind="claude", role="agent"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key,
              "preferred_name": name, "role": role},
    )
    assert r.status_code == 200, r.text
    return r.json()


# ---------- P1-06 分頁 ----------

async def test_pagination_contract(tmp_path):
    app = _app(tmp_path, "page")
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            p = await _join(client, room_id, "s1", "Nova")
            headers = {"X-Participant-Id": p["participant_id"]}
            for i in range(250):
                await client.post(
                    f"/api/rooms/{room_id}/messages",
                    json={"content": f"msg-{i}"}, headers=headers,
                )
            total = 251  # 250 chat + 1 join system

            # 正向三次翻頁：完整、無重複、has_more 正確
            seqs, cursor, pages = [], 0, 0
            while True:
                data = (
                    await client.get(
                        f"/api/rooms/{room_id}/messages",
                        params={"after_seq": cursor, "limit": 100},
                    )
                ).json()
                seqs += [m["seq"] for m in data["messages"]]
                pages += 1
                if not data["has_more"]:
                    break
                cursor = data["next_after_seq"]
            assert pages == 3
            assert len(seqs) == total and len(set(seqs)) == total
            assert seqs == sorted(seqs)

            # 反向翻頁：內容與正向一致（皆遞增排列）
            back, before = [], None
            while True:
                params = {"limit": 100}
                if before is not None:
                    params["before_seq"] = before
                else:
                    params["before_seq"] = seqs[-1] + 1
                data = (
                    await client.get(f"/api/rooms/{room_id}/messages", params=params)
                ).json()
                assert [m["seq"] for m in data["messages"]] == sorted(
                    m["seq"] for m in data["messages"]
                )
                back = [m["seq"] for m in data["messages"]] + back
                if not data["has_more"]:
                    break
                before = data["next_before_seq"]
            assert back == seqs

            # 非法 limit → 422
            for bad in (0, -1, 501):
                r = await client.get(
                    f"/api/rooms/{room_id}/messages", params={"limit": bad}
                )
                assert r.status_code == 422, bad
            # after_seq 與 before_seq 互斥
            r = await client.get(
                f"/api/rooms/{room_id}/messages",
                params={"after_seq": 5, "before_seq": 10},
            )
            assert r.status_code == 422

            # pinned_only 與分頁同時使用
            mid = (
                await client.get(
                    f"/api/rooms/{room_id}/messages", params={"after_seq": 0, "limit": 1}
                )
            ).json()["messages"][0]["id"]
            await client.post(f"/api/messages/{mid}/pin", headers=headers)
            data = (
                await client.get(
                    f"/api/rooms/{room_id}/messages",
                    params={"pinned_only": True, "limit": 100},
                )
            ).json()
            assert [m["id"] for m in data["messages"]] == [mid]
            assert data["has_more"] is False


# ---------- P1-07 指派過期 ----------

async def test_assignment_expiry(tmp_path):
    app = _app(tmp_path, "ttl", assignment_ttl=0.0, sweep_interval=3600)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            await client.post(
                f"/api/rooms/{room_id}/assignments",
                json={"target_session_key": "sess-x", "note": "n"},
            )
            # accepted 的不受影響
            aid2 = (
                await client.post(
                    f"/api/rooms/{room_id}/assignments",
                    json={"target_session_key": "sess-y", "note": "n"},
                )
            ).json()["id"]
            await client.post(
                f"/api/assignments/{aid2}/resolve", json={"status": "accepted"}
            )

            await app.state.sweep_once()

            r = await client.get("/api/assignments", params={"session_key": "sess-x"})
            assert r.json()["assignments"] == []
            db = app.state.db
            rows = await (
                await db.execute("SELECT target_session_key, status FROM assignment")
            ).fetchall()
            statuses = {r["target_session_key"]: r["status"] for r in rows}
            assert statuses == {"sess-x": "expired", "sess-y": "accepted"}


# ---------- P1-02 補：human 不被移除（用 sweep_once，不靠 sleep） ----------

async def test_sweep_keeps_human(tmp_path):
    app = _app(tmp_path, "human", idle_timeout=0.0, sweep_interval=3600)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            await _join(client, room_id, "h1", "Xavier", kind="human", role="human")
            await _join(client, room_id, "a1", "Nova")
            await app.state.sweep_once()
            detail = (await client.get(f"/api/rooms/{room_id}")).json()
            by_name = {p["display_name"]: p["status"] for p in detail["participants"]}
            assert by_name == {"Xavier": "active", "Nova": "removed"}
            # 房內只剩「一個」human → 封存（沒有對話對象）
            assert detail["room"]["status"] == "archived"


async def test_sweep_spares_room_with_multiple_humans(tmp_path):
    """兩個以上人類仍在對話時，agent 離場不得觸發自動封存。"""
    app = _app(tmp_path, "humans2", idle_timeout=0.0, sweep_interval=3600)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            await _join(client, room_id, "h1", "Xavier", kind="human", role="human")
            await _join(client, room_id, "h2", "Bernie", kind="human", role="human")
            agent = await _join(client, room_id, "a1", "Nova")
            # agent 主動離開（比閒置移除更直接）
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": agent["participant_id"]},
            )
            await app.state.sweep_once()
            detail = (await client.get(f"/api/rooms/{room_id}")).json()
            assert detail["room"]["status"] == "active"

            # 其中一個人類也走了 → 只剩一人，下一輪才封存
            h2 = next(
                p for p in detail["participants"] if p["display_name"] == "Bernie"
            )
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": h2["id"]},
            )
            await app.state.sweep_once()
            assert (await client.get(f"/api/rooms/{room_id}")).json()["room"][
                "status"
            ] == "archived"


# ---------- P1-08 認證 ----------

async def test_auth_required_when_token_set(tmp_path):
    cfg = Config(db_path=str(tmp_path / "auth.db"), api_token="secret")
    app = create_app(cfg)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            assert (await client.get("/api/rooms")).status_code == 401
            assert (
                await client.get(
                    "/api/rooms", headers={"Authorization": "Bearer wrong"}
                )
            ).status_code == 401
            assert (
                await client.get(
                    "/api/rooms", headers={"Authorization": "Bearer secret"}
                )
            ).status_code == 200
            # health 不需 token 且不洩漏設定
            r = await client.get("/api/health")
            assert r.status_code == 200
            assert "secret" not in r.text


async def test_no_token_warns_on_startup(tmp_path, caplog):
    app = _app(tmp_path, "warn")
    with caplog.at_level(logging.WARNING, logger="chatroom"):
        async with app.router.lifespan_context(app):
            pass
    assert any("驗證停用" in r.message for r in caplog.records)


# ---------- P1-09 sweeper 例外韌性 ----------

async def test_sweeper_survives_exception(tmp_path, caplog):
    app = _app(tmp_path, "resilient", sweep_interval=0.05)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        async with app.router.lifespan_context(app):
            db = app.state.db
            await db.execute("ALTER TABLE participant RENAME TO participant_broken")
            await db.commit()
            with caplog.at_level(logging.ERROR, logger="chatroom"):
                await asyncio.sleep(0.15)
            assert any("sweeper" in r.message for r in caplog.records)
            assert not app.state.sweeper_task.done()  # 迴圈仍在跑
            # 修復後下一輪恢復正常
            await db.execute("ALTER TABLE participant_broken RENAME TO participant")
            await db.commit()
            caplog.clear()
            room_id = (await client.post("/api/rooms", json={"name": "房"})).json()["id"]
            await _join(client, room_id, "s1")
            assert (await client.get(f"/api/rooms/{room_id}")).status_code == 200
