"""離場語意：被踢／閒置移除／封存要能被 agent 分辨，並讓 watcher 收掉監看。

這三種情況以前全被壓成同一個 403 + 同一句中文，watcher 只能發一句含糊的
watch_ended，agent 分不出「我該退場」還是「Hub 出問題」，監看就一直掛著空轉。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_mcp.hub import translate_status
from chatroom_server.app import create_app
from chatroom_server.config import Config

async def _make(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name, kind="claude", role="agent"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": session_key,
              "preferred_name": name, "role": role},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_kicked_and_idle_removal_are_distinguishable(tmp_path):
    """被踢與閒置移除必須回不同的 code——處置完全不同，混在一起 agent 只能猜。"""
    # idle_timeout=0：join 當下就已逾時，下一輪 sweep 立刻移除
    app, client = await _make(tmp_path, "departure", idle_timeout=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            admin = await _join(client, room_id, "admin-key", "Xavier",
                                kind="human", role="human")
            kicked = await _join(client, room_id, "kick-me", "被踢的")
            idle = await _join(client, room_id, "go-idle", "閒置的")

            await client.post(
                f"/api/rooms/{room_id}/participants/{kicked['participant_id']}/kick",
                headers={"X-Participant-Id": admin["participant_id"]},
            )
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": kicked["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "participant_kicked"

            await app.state.sweep_once()
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": idle["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "participant_removed_idle"


@pytest.mark.asyncio
async def test_left_participant_reports_left(tmp_path):
    app, client = await _make(tmp_path, "left")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            me = await _join(client, room_id, "bye-key", "要走的")
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": me["participant_id"]},
            )
            r = await client.post(
                f"/api/rooms/{room_id}/heartbeat",
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "participant_left"


@pytest.mark.asyncio
async def test_updates_reports_room_status(tmp_path):
    """封存不會讓身分失效，所以 long-poll 必須自己講房間狀態——
    否則 watcher 對著已封存的房間永遠等不到任何訊號。"""
    app, client = await _make(tmp_path, "archived")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            me = await _join(client, room_id, "watcher-key", "看著的")

            r = await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": 0, "timeout": 0.1},
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.json()["room_status"] == "active"

            await client.post(f"/api/rooms/{room_id}/archive")
            r = await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": 0, "timeout": 0.1},
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.status_code == 200, "封存房仍可讀，不該變成錯誤"
            assert r.json()["room_status"] == "archived"


def test_bridge_translates_departure_codes():
    """bridge 要把 code 轉成 departure 標記，watcher 才知道該不該收掉監看。"""
    kicked = translate_status(403, {"code": "participant_kicked", "message": ""}, "u")
    assert kicked.departure == "kicked"
    assert kicked.identity_invalid

    idle = translate_status(403, {"code": "participant_removed_idle", "message": ""}, "u")
    assert idle.departure == "idle"

    left = translate_status(403, {"code": "participant_left", "message": ""}, "u")
    assert left.departure == "left"

    # 舊版 Hub 只回泛用 403：仍要視為身分失效，但不得謊報離場原因
    legacy = translate_status(403, "身分已失效", "u")
    assert legacy.identity_invalid
    assert legacy.departure is None


def test_kicked_guidance_tells_agent_not_to_rejoin():
    """被踢是人為決定。訊息若只說『請重新加入』，agent 就會照做而推翻它。"""
    err = translate_status(403, {"code": "participant_kicked", "message": ""}, "u")
    assert "不要再自己加回去" in err.reason
    idle = translate_status(403, {"code": "participant_removed_idle", "message": ""}, "u")
    assert "重新呼叫 chatroom_join" in idle.reason


@pytest.mark.asyncio
async def test_assignment_reports_target_liveness(tmp_path):
    """派給一把沒人在領的 key，外觀跟派錯人一模一樣——建立當下就要講清楚。"""
    app, client = await _make(tmp_path, "assign_live")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]

            # 從沒出現過的 key：Hub 連見都沒見過
            r = await client.post(
                f"/api/rooms/{room_id}/assignments",
                json={"target_session_key": "claude-never-seen", "note": "在嗎"},
            )
            body = r.json()
            assert body["target_known"] is False
            assert body["target_active"] is False
            assert body["target_last_seen_at"] is None

            # 有 watcher 在輪詢的 key：輪詢本身就是心跳來源
            await client.get(
                "/api/assignments",
                params={"session_key": "claude-alive", "kind": "claude"},
            )
            r = await client.post(
                f"/api/rooms/{room_id}/assignments",
                json={"target_session_key": "claude-alive", "note": "在嗎"},
            )
            body = r.json()
            assert body["target_known"] is True
            assert body["target_active"] is True

            # 指派本身仍然成立——對方稍後上線還是收得到
            r = await client.get(
                "/api/assignments", params={"session_key": "claude-never-seen"}
            )
            assert len(r.json()["assignments"]) == 1


def test_unknown_403_code_still_counts_as_identity_invalid():
    """滾動升級的保命契約：不是每台機器都會同步更新。

    新 Hub 回的新 code，舊 bridge 不認得——只要它仍落在 identity_invalid 那條
    路徑，舊 watcher 就會結束進程；若哪天有人把 403 的 fallback 改成「暫時性
    錯誤」，舊 watcher 會變成永遠退不掉、還一直打 Hub 的殭屍。
    """
    err = translate_status(403, {"code": "some_future_code", "message": "x"}, "u")
    assert err.identity_invalid is True
    assert err.departure is None, "不認得的 code 不得亂猜離場原因"


@pytest.mark.asyncio
async def test_system_messages_carry_machine_readable_event(tmp_path):
    """client 要精確過濾就不能比對中文內容——改一個字就會無聲失效。"""
    app, client = await _make(tmp_path, "sysevent", idle_timeout=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            admin = await _join(client, room_id, "admin-key", "Xavier",
                                kind="human", role="human")
            guest = await _join(client, room_id, "guest-key", "訪客")
            await client.post(
                f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
                headers={"X-Participant-Id": admin["participant_id"]},
            )
            await client.post(f"/api/rooms/{room_id}/archive")

            msgs = (
                await client.get(
                    f"/api/rooms/{room_id}/messages",
                    headers={"X-Participant-Id": admin["participant_id"]})
            ).json()["messages"]
            events = [m["system_event"] for m in msgs if m["kind"] == "system"]
            assert "join" in events
            assert "kick" in events
            assert "archive" in events
            # 一般發言不該帶 system_event
            chat = [m for m in msgs if m["kind"] == "chat"]
            assert all(m["system_event"] is None for m in chat)


@pytest.mark.asyncio
async def test_mentioning_someone_who_left_is_reported(tmp_path):
    """房裡常有名字只差一個字的舊身分，挑錯就等於對著空氣說話。"""
    app, client = await _make(tmp_path, "mention_ghost")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (
                await client.post(
                    "/api/rooms", json={"name": "房", "session_key": "admin-key"}
                )
            ).json()["id"]
            me = await _join(client, room_id, "me-key", "我")
            ghost = await _join(client, room_id, "ghost-key", "Novia")
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": ghost["participant_id"]},
            )
            live = await _join(client, room_id, "live-key", "Novia-2")

            r = await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "在嗎", "mentions": ["Novia"]},
                headers={"X-Participant-Id": me["participant_id"]},
            )
            body = r.json()
            assert body["unresolved_mentions"] == ["Novia"]
            assert "Novia-2" in body["active_names"], "要給得出正確的名字"

            # mention 活著的人不該有警告
            r = await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "在嗎", "mentions": ["Novia-2"]},
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert "unresolved_mentions" not in r.json()
            assert live["display_name"] == "Novia-2"
