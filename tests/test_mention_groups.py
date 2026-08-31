"""群組標籤 @all / @agents / @humans。

**展開發生在 Hub，不是 client。** 這是 multi-agent 聊天室，agent 透過 MCP
發 `@all` 也必須生效；在 App 展開等於只有人類用得到。而且展開之後 joined_seq
界線、subagent 轉投遞、unresolved 語意全部免費沿用——那三處都比對實名。

保留字是這張票最容易漏的一塊：`preferred_name` 是自由字串，房裡真的可以有
成員叫 `all`，而那會在有人取那個名字之前完全看不出來。
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


async def test_all_expands_to_everyone_except_the_speaker(tmp_path):
    """@all 展開成實名，且**不含發話者自己**。

    含自己的話 you_were_mentioned 會對自己成立——每發一句 @all 就把自己叫醒
    一次，而那個迴圈沒有任何錯誤訊息。
    """
    app, client = await _make(tmp_path, "all")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        await _join(client, room_id, "s2", "Dale")
        await _join(client, room_id, "s3", "Xavier", role="human", kind="human")

        r = await _say(client, room_id, me, "大家看一下", ["all"])

        assert set(r["mentions"]) == {"Dale", "Xavier"}
        assert "Novia" not in r["mentions"]
        assert "all" not in r["mentions"], "群組字面不該落庫成一個人名"
        assert r["mention_groups"] == ["all"]


async def test_agents_and_humans_split_by_role(tmp_path):
    app, client = await _make(tmp_path, "roles")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        await _join(client, room_id, "s2", "Dale")
        await _join(client, room_id, "s3", "Xavier", role="human", kind="human")
        await _join(client, room_id, "s4", "Mira", role="human", kind="human")

        agents = await _say(client, room_id, me, "agent 們", ["agents"])
        humans = await _say(client, room_id, me, "人類們", ["humans"])

        assert set(agents["mentions"]) == {"Dale"}
        assert set(humans["mentions"]) == {"Xavier", "Mira"}


async def test_group_names_are_case_insensitive(tmp_path):
    """`@All` 與 `@all` 是同一件事——大小寫敏感會讓它時靈時不靈。"""
    app, client = await _make(tmp_path, "case")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        await _join(client, room_id, "s2", "Dale")

        r = await _say(client, room_id, me, "喂", ["ALL"])
        assert r["mentions"] == ["Dale"]


async def test_all_does_not_expand_to_ephemeral_subagents(tmp_path):
    """子代理不進 @all。

    它們沒有自己的 watcher（活在父層的進程裡），被 @ 會透過 relayed_mentions
    再把父層叫醒一次——房裡有 N 個子代理，父層就被叫醒 N+1 次。子代理該由
    父層自己轉手。
    """
    app, client = await _make(tmp_path, "ephemeral")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        parent = await _join(client, room_id, "s2", "Dale")
        # 派生 key 必須真的長在父層底下（`父key#子`），Hub 會驗
        sub = await _join(client, room_id, "s2#worker", "Worker",
                          parent=parent["participant_id"])
        assert sub.get("participant_id"), sub

        r = await _say(client, room_id, me, "大家", ["all"])

        assert "Dale" in r["mentions"]
        assert sub["display_name"] not in r["mentions"]


async def test_an_empty_group_is_reported_not_silently_dropped(tmp_path):
    """展開成空的群組要講出來。

    語意與 unresolved_mentions 同族——「你以為叫到人了，其實沒有」。安靜
    丟掉的話，發話者看到的回應與成功送達完全一樣。
    """
    app, client = await _make(tmp_path, "empty")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")

        r = await _say(client, room_id, me, "有人嗎", ["humans"])

        assert r["mentions"] == []
        assert r["empty_groups"] == ["humans"]


async def test_group_names_never_become_unresolved_mentions(tmp_path):
    """`unresolved_mentions` 只管「打錯的人名」。

    群組名混進去的話，發話者會被告知「這個名字沒喚醒任何人」，然後去查一個
    不存在的成員。
    """
    app, client = await _make(tmp_path, "unresolved")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        await _join(client, room_id, "s2", "Dale")

        r = await _say(client, room_id, me, "喂", ["all", "Ghost"])

        assert r.get("unresolved_mentions") == ["Ghost"]
        assert "all" not in r.get("unresolved_mentions", [])


async def test_group_names_are_reserved_at_the_naming_layer(tmp_path):
    """房裡不能有人叫 all / agents / humans。

    preferred_name 是自由字串。有人取了那個名字，`@all` 的語意就被他劫持，
    而且在那之前完全看不出來——這是命名層的事，不是展開層補得掉的。
    """
    app, client = await _make(tmp_path, "reserved")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        for wanted in ("all", "Agents", "HUMANS"):
            p = await _join(client, room_id, f"s-{wanted}", wanted)
            assert p["display_name"].casefold() != wanted.casefold(), p


async def test_expanded_mentions_survive_a_read(tmp_path):
    """讀訊息時要拿得回展開結果與原字面。

    mentions 給 client 渲染 chip、mention_groups 讓它還原成一顆 @all——
    否則 UI 上會攤出一整排全房名單。
    """
    app, client = await _make(tmp_path, "read")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        await _join(client, room_id, "s2", "Dale")
        await _say(client, room_id, me, "大家", ["all"])

        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=_pid(me))).json()["messages"]
        latest = msgs[-1]
        assert latest["mentions"] == ["Dale"]
        assert latest["mention_groups"] == ["all"]


async def test_a_group_mention_wakes_the_members(tmp_path):
    """展開的最終目的：被展開到的人真的會醒。

    這條是整張票的驗收——前面幾條驗的都是形狀，這條驗它真的接上了喚醒判定。
    """
    app, client = await _make(tmp_path, "wake")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        me = await _join(client, room_id, "s1", "Novia")
        dale = await _join(client, room_id, "s2", "Dale")

        cursor = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": 0, "timeout": 1}, headers=_pid(dale),
        )).json()["last_seq"]

        await _say(client, room_id, me, "大家看一下", ["all"])

        data = (await client.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": cursor, "timeout": 1}, headers=_pid(dale),
        )).json()
        assert data["you_were_mentioned"] is True
