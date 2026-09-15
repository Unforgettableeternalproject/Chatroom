"""用 participant_id 指派：把已離開的成員請回來。

成員的 `session_key` **刻意不外流**（它同時是指派目標），所以 App 手上
只有 `participant_id`——沒有這條路的話，「請一個因閒置被移出的 agent
重新加入」這件事在 UI 上根本做不出來，而 watcher 其實還掛著、指派照樣
收得到。

兩條路擇一：`target_session_key` 是正典（agent 與 CLI 用），
`target_participant_id` 給 UI 用，由 Hub 內部換。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def client(tmp_path):
    cfg = Config(db_path=str(tmp_path / "t.db"), api_token="")
    app = create_app(cfg)
    c = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
    async with c:
        async with app.router.lifespan_context(app):
            yield c


async def _room(client, owner="owner-key"):
    r = await client.post("/api/rooms", json={"name": "房", "session_key": owner})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _join(client, room_id, key, name):
    r = await client.post(f"/api/rooms/{room_id}/join",
                          json={"kind": "claude", "session_key": key,
                                "preferred_name": name})
    assert r.status_code == 200, r.text
    return r.json()["participant_id"]


async def test_assign_a_departed_member_by_participant_id(client):
    """被移出之後照樣請得回來——watcher 沒有跟著消失。"""
    room = await _room(client)
    pid = await _join(client, room, "agent-key", "開發Novia-1")
    r = await client.post(f"/api/rooms/{room}/leave",
                          headers={"X-Participant-Id": pid})
    assert r.status_code == 200, r.text

    r = await client.post(
        f"/api/rooms/{room}/assignments",
        json={"target_participant_id": pid, "note": "請重新加入",
              "assigned_name": "開發Novia-1"},
        headers={"X-Session-Key": "owner-key"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["target_known"] is True, "session 還在名錄裡"

    # 那筆指派真的落在對方的 key 上
    r = await client.get("/api/assignments",
                         params={"session_key": "agent-key"})
    assert r.status_code == 200, r.text
    got = r.json()["assignments"]
    assert len(got) == 1
    assert got[0]["note"] == "請重新加入"
    assert got[0]["assigned_name"] == "開發Novia-1"


async def test_session_key_still_works(client):
    """正典那條不可以被改壞。"""
    room = await _room(client)
    r = await client.post(
        f"/api/rooms/{room}/assignments",
        json={"target_session_key": "agent-key", "note": "來幫忙"},
        headers={"X-Session-Key": "owner-key"},
    )
    assert r.status_code == 200, r.text


async def test_unknown_participant_is_not_silently_assigned_to_nobody(client):
    """打錯 id 要當場講。靜靜建立一筆指派給「空字串」的話，
    發的人會以為叫到了人，而那與成功長得一模一樣。"""
    room = await _room(client)
    r = await client.post(
        f"/api/rooms/{room}/assignments",
        json={"target_participant_id": "沒有這個人"},
        headers={"X-Session-Key": "owner-key"},
    )
    assert r.status_code == 404, r.text
    assert r.json()["detail"]["code"] == "participant_not_found"


async def test_two_targets_at_once_is_rejected(client):
    """兩條路只能給一條——不然「以哪個為準」會變成一個沒人講清楚的默契。"""
    room = await _room(client)
    pid = await _join(client, room, "agent-key", "甲")
    r = await client.post(
        f"/api/rooms/{room}/assignments",
        json={"target_participant_id": pid, "target_session_key": "別人"},
        headers={"X-Session-Key": "owner-key"},
    )
    assert r.status_code == 422, r.text


async def test_no_target_at_all_is_rejected(client):
    room = await _room(client)
    r = await client.post(f"/api/rooms/{room}/assignments", json={"note": "誰?"},
                          headers={"X-Session-Key": "owner-key"})
    assert r.status_code == 422, r.text
