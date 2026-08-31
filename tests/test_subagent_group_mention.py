"""subagent 發 `@all` 不該叫醒自己的父層。

C1 的註解說「`@all` 不展開 ephemeral subagent，因為它們沒有自己的 watcher，
被 @ 會透過 `relayed_mentions` 再把父層叫醒一次」。那條防住了**被 @ 的是
subagent**，沒防住**發話的是 subagent**——同一個機制、反方向。

subagent 與父層共用同一個進程。subagent 發 `@all` 時，「排除發話者」只排除了
subagent 自己的 participant id，父層仍在展開結果裡，於是那個進程被自己剛發出
的訊息叫醒。

> 排除的單位是**發話的那個進程**，不是那個 participant id。

（審核用 Codex F9，2026-08-31）
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


async def _room(client):
    return (await client.post(
        "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]


async def _join(client, room_id, key, name, role="agent", kind="claude",
                parent=None):
    body = {"kind": kind, "session_key": key, "preferred_name": name,
            "role": role}
    if parent is not None:
        body["parent_participant_id"] = parent
    return (await client.post(f"/api/rooms/{room_id}/join", json=body)).json()


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _say(client, room_id, sender, text, mentions):
    return (await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": text, "mentions": mentions}, headers=_pid(sender),
    )).json()


async def _setup(client):
    room_id = await _room(client)
    parent = await _join(client, room_id, "s-parent", "Dale")
    sub = await _join(client, room_id, "s-parent#worker", "Worker",
                      parent=parent["participant_id"])
    other = await _join(client, room_id, "s-other", "Mira")
    human = await _join(client, room_id, "s-human", "Xavier",
                        role="human", kind="human")
    return room_id, parent, sub, other, human


async def test_subagent_all_does_not_expand_to_its_own_parent(tmp_path):
    """父層不該出現在自己 subagent 發的 @all 裡。

    父層與 subagent 是同一個進程：叫醒父層＝那個進程被自己剛說的話叫醒。
    """
    app, client = await _make(tmp_path, "sub_all")
    async with app.router.lifespan_context(app), client:
        room_id, parent, sub, other, human = await _setup(client)
        assert sub.get("participant_id"), sub

        r = await _say(client, room_id, sub, "大家看一下", ["all"])

        assert parent["display_name"] not in r["mentions"], r["mentions"]
        # 正向錨點：其他人照樣叫得到，否則「沒叫到父層」可能只是整個展開壞了
        assert set(r["mentions"]) == {"Mira", "Xavier"}


async def test_subagent_agents_group_also_excludes_the_parent(tmp_path):
    """`@agents` 走同一條排除，不能只修 `@all`。

    三個群組共用一個展開函式，只補一個等於留兩個。
    """
    app, client = await _make(tmp_path, "sub_agents")
    async with app.router.lifespan_context(app), client:
        room_id, parent, sub, other, _human = await _setup(client)

        r = await _say(client, room_id, sub, "agent 們", ["agents"])

        assert parent["display_name"] not in r["mentions"], r["mentions"]
        assert r["mentions"] == ["Mira"]


async def test_the_parent_is_not_woken_by_its_subagents_group_mention(tmp_path):
    """端到端：父層的 updates 不該因為自己 subagent 的 @all 而 mentioned。

    展開結果正確但喚醒判定仍成立的話，這個修法就沒有真的解決問題——
    `relayed_mentions` 是另一條會叫醒父層的路徑。
    """
    app, client = await _make(tmp_path, "sub_wake")
    async with app.router.lifespan_context(app), client:
        room_id, parent, sub, _other, _human = await _setup(client)

        cursor = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": 0, "timeout": 1}, headers=_pid(parent),
        )).json()["last_seq"]

        await _say(client, room_id, sub, "大家看一下", ["all"])

        data = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": cursor, "timeout": 1}, headers=_pid(parent),
        )).json()
        # 正向錨點：那則訊息確實送到父層的批次裡了
        assert any("大家看一下" in m["content"] for m in data["messages"])
        assert data["you_were_mentioned"] is False


async def test_a_normal_sender_still_reaches_the_parent(tmp_path):
    """反向錨點：別人發 @all，父層照樣要被叫到。

    沒有這條的話，上面三條可以靠「父層被永久排除」一起變綠。
    """
    app, client = await _make(tmp_path, "normal")
    async with app.router.lifespan_context(app), client:
        room_id, parent, _sub, other, _human = await _setup(client)

        r = await _say(client, room_id, other, "大家", ["all"])

        assert parent["display_name"] in r["mentions"]
