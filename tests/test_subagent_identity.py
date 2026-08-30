"""Subagent identity — Hub 側契約（docs/SUBAGENT-IDENTITY.md C1/C2/C6/C8/C9）。

這些測試對應的是文件裡的可觀測契約，條號寫在各測試的 docstring 裡，
改行為時兩邊要一起改。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name, **cfg_kwargs):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **cfg_kwargs)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name, **extra):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key,
              "preferred_name": name, "role": "agent", **extra},
    )
    return r


async def _join_ok(client, room_id, session_key, name, **extra):
    r = await _join(client, room_id, session_key, name, **extra)
    assert r.status_code == 200, r.text
    return r.json()


async def _sub(client, room_id, parent, slug, name):
    """以 parent 為父層加入一個 subagent。派生 key 帶隨機段避免撞號。"""
    return await _join(
        client, room_id, f"{parent['session_key']}#{slug}", name,
        parent_participant_id=parent["participant_id"],
    )


async def _room(client, room_id, participant_id):
    r = await client.get(
        f"/api/rooms/{room_id}", headers={"X-Participant-Id": participant_id}
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _seq(client, room_id, participant_id):
    r = await client.get(
        f"/api/rooms/{room_id}/messages?after_seq=0",
        headers={"X-Participant-Id": participant_id},
    )
    assert r.status_code == 200, r.text
    return r.json()["next_after_seq"]


async def _new_room(client, session_key="parent-key"):
    r = await client.post("/api/rooms", json={"name": "房", "session_key": session_key})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def test_subagent_appears_nested_and_scope_is_observable(tmp_path):
    """C1 — subagent 自報後出現在成員列，且 identity_scope 是正向可觀測量。"""
    app, client = await _make(tmp_path, "c1")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            assert parent["identity_scope"] == "parent"

            r = await _sub(client, room_id, parent, "tester-a1b2c3d4", "米勒")
            assert r.status_code == 200, r.text
            sub = r.json()
            assert sub["identity_scope"] == "subagent"
            assert sub["parent_participant_id"] == parent["participant_id"]
            assert sub["parent_name"] == "Novia"
            # 加入不進訊息流，所以沒有加入訊息可指
            assert sub["join_message_id"] is None
            assert sub["join_seq"] is None

            detail = await _room(client, room_id, parent["participant_id"])
            by_name = {p["display_name"]: p for p in detail["participants"]}
            # subagent 的「存在」對所有人可見，這正是本功能要的
            assert by_name["米勒"]["ephemeral"] is True
            assert by_name["米勒"]["parent_id"] == parent["participant_id"]
            # 錨點：父層自己不是 ephemeral，也沒有 parent
            assert by_name["Novia"]["ephemeral"] is False
            assert by_name["Novia"]["parent_id"] is None


async def test_subagent_join_and_leave_stay_out_of_message_stream(tmp_path):
    """C2 — 進出不進訊息流：seq 差值恰好等於刻意發出的則數。"""
    app, client = await _make(tmp_path, "c2")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            before = await _seq(client, room_id, parent["participant_id"])

            sub = (await _sub(client, room_id, parent, "t-1111", "米勒")).json()
            # 錨點：父層發一則普通訊息，seq 必須前進——否則「沒變」只證明
            # 得了讀取根本沒生效
            r = await client.post(
                f"/api/rooms/{room_id}/messages", json={"content": "錨點"},
                headers={"X-Participant-Id": parent["participant_id"]},
            )
            assert r.status_code == 200, r.text
            r = await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": sub["participant_id"]},
            )
            assert r.status_code == 200, r.text

            after = await _seq(client, room_id, parent["participant_id"])
            assert after - before == 1, "只有錨點那一則該推進 seq"


async def test_subagent_key_must_derive_from_parent(tmp_path):
    """C4/C9 的鄰居：自報的隸屬關係一律驗到底，驗不過報錯不退回父層。"""
    app, client = await _make(tmp_path, "guards")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")

            # 派生 key 對不上父層
            r = await _join(
                client, room_id, "somebody-else#t-1", "冒牌",
                parent_participant_id=parent["participant_id"],
            )
            assert r.status_code == 400
            assert r.json()["detail"]["code"] == "subagent_key_mismatch"

            # 父層不存在
            r = await _join(
                client, room_id, "ghost-key#t-1", "孤兒",
                parent_participant_id="no-such-participant",
            )
            assert r.status_code == 404
            assert r.json()["detail"]["code"] == "parent_not_found"

            # 孫層
            sub = (await _sub(client, room_id, parent, "t-2222", "米勒")).json()
            r = await _join(
                client, room_id, f"{sub['session_key']}#g-1", "孫子",
                parent_participant_id=sub["participant_id"],
            )
            assert r.status_code == 400
            assert r.json()["detail"]["code"] == "subagent_cannot_nest"


async def test_subagent_join_is_not_idempotent(tmp_path):
    """C9 — 派生 key 撞號要報 409，不可回 rejoined。"""
    app, client = await _make(tmp_path, "c9")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")

            first = await _sub(client, room_id, parent, "t-3333", "米勒")
            assert first.status_code == 200
            second = await _sub(client, room_id, parent, "t-3333", "米勒")
            assert second.status_code == 409, second.text
            assert second.json()["detail"]["code"] == "subagent_already_exists"


async def test_parent_leaving_cascades_to_its_own_subagents_only(tmp_path):
    """C8 — 父層離開時級聯移除，且只掃自己旗下的。"""
    app, client = await _make(tmp_path, "c8")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            other = await _join_ok(client, room_id, "other-key", "米絲媞")
            await _sub(client, room_id, parent, "t-a1", "米勒")
            await _sub(client, room_id, parent, "t-a2", "戴爾")
            await _sub(client, room_id, other, "t-b1", "埃里爾")

            r = await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": parent["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert sorted(r.json()["cascaded_subagents"]) == ["戴爾", "米勒"]

            detail = await _room(client, room_id, other["participant_id"])
            status = {p["display_name"]: p["status"] for p in detail["participants"]}
            assert status["米勒"] == "left"
            assert status["戴爾"] == "left"
            # 錨點：別人的 subagent 不受影響——擋掉「級聯條件寫太寬」
            assert status["埃里爾"] == "active"


async def test_subagent_alone_does_not_count_as_room_activity(tmp_path):
    """C6 — subagent 不算「房內還有 agent」，不會擋住自動封存倒數。

    級聯移除讓「只剩 subagent」在正常路徑上不可達，所以這裡直接驗封存判定
    本身：手動把父層標成已離開、只留 subagent，倒數仍該起算（縱深防禦）。
    """
    app, client = await _make(tmp_path, "c6", archive_grace=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            await _sub(client, room_id, parent, "t-c1", "米勒")

            db = app.state.db
            # 繞過級聯，刻意佈置出「只剩 subagent」這個不該影響判定的狀態
            await db.execute(
                "UPDATE participant SET status='left' WHERE id=?",
                (parent["participant_id"],),
            )
            await db.commit()

            await app.state.sweep_once()   # 起算封存倒數
            await app.state.sweep_once()   # grace=0，這輪封存
            row = await (
                await db.execute("SELECT status FROM room WHERE id=?", (room_id,))
            ).fetchone()
            assert row["status"] == "archived", "只剩 subagent 時房間仍該被收掉"


async def test_updates_relays_subagent_events_only_to_parent(tmp_path):
    """C3 — subagent 的進出只出現在父層的 updates，第三方拿不到。"""
    app, client = await _make(tmp_path, "c3")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            third = await _join_ok(client, room_id, "third-key", "米絲媞")

            # 先各拿一次游標（第一輪不補發歷史）
            p_first = (await client.get(
                f"/api/rooms/{room_id}/updates?timeout=0",
                headers={"X-Participant-Id": parent["participant_id"]},
            )).json()
            t_first = (await client.get(
                f"/api/rooms/{room_id}/updates?timeout=0",
                headers={"X-Participant-Id": third["participant_id"]},
            )).json()

            sub = (await _sub(client, room_id, parent, "t-d1", "米勒")).json()
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": sub["participant_id"]},
            )
            # 錨點：第三方在同一時段收得到房內的普通訊息，證明它的通道活著
            await client.post(
                f"/api/rooms/{room_id}/messages", json={"content": "錨點"},
                headers={"X-Participant-Id": parent["participant_id"]},
            )

            p_now = (await client.get(
                f"/api/rooms/{room_id}/updates?timeout=0"
                f"&subagents_since={p_first['subagents_cursor']}",
                headers={"X-Participant-Id": parent["participant_id"]},
            )).json()
            t_now = (await client.get(
                f"/api/rooms/{room_id}/updates?timeout=0"
                f"&after_seq={t_first['last_seq']}"
                f"&subagents_since={t_first['subagents_cursor']}",
                headers={"X-Participant-Id": third["participant_id"]},
            )).json()

            kinds = [e["event"] for e in p_now["subagent_events"]]
            assert kinds == ["subagent_joined", "subagent_left"]
            assert all(e["name"] == "米勒" for e in p_now["subagent_events"])
            # 第三方：沒有那兩個事件，但錨點訊息收得到
            assert t_now["subagent_events"] == []
            assert [m["content"] for m in t_now["messages"]] == ["錨點"]


async def test_mentioning_a_subagent_wakes_its_parent(tmp_path):
    """C7 — @ subagent＝叫醒父層，並標明是給誰的。"""
    app, client = await _make(tmp_path, "c7")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            third = await _join_ok(client, room_id, "third-key", "米絲媞")
            await _sub(client, room_id, parent, "t-e1", "米勒")

            r = await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "@米勒 這條給你", "mentions": ["米勒"]},
                headers={"X-Participant-Id": third["participant_id"]},
            )
            assert r.status_code == 200, r.text
            # 錨點：名字有解析到，不是打進空氣
            assert not r.json().get("unresolved_mentions")

            upd = (await client.get(
                f"/api/rooms/{room_id}/updates?timeout=0",
                headers={"X-Participant-Id": parent["participant_id"]},
            )).json()
            assert upd["you_were_mentioned"] is True
            target = [m for m in upd["messages"] if m["content"].startswith("@米勒")]
            assert target and target[0]["relayed_mentions"] == ["米勒"]

            # 第三方自己不該因為這則而被叫醒
            t_upd = (await client.get(
                f"/api/rooms/{room_id}/updates?timeout=0",
                headers={"X-Participant-Id": third["participant_id"]},
            )).json()
            assert t_upd["you_were_mentioned"] is False


async def test_ephemeral_name_is_held_while_its_parent_lives(tmp_path):
    """問題二 — subagent 的名字在父層存活期間不釋出。

    名字被別家的 subagent 撿走，@ 那個名字就會轉投遞到錯誤的父層（C7 靠名字
    轉投遞），而且兩邊都不會看到錯誤。保留名字讓晚到的 @ 變成一個發話者看得
    見的失敗。
    """
    app, client = await _make(tmp_path, "namehold")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            other = await _join_ok(client, room_id, "other-key", "米絲媞")

            sub = (await _sub(client, room_id, parent, "t-h1", "米勒")).json()
            assert sub["display_name"] == "米勒"
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": sub["participant_id"]},
            )

            # 別家的 subagent 自報同名 → 拿到調整過的名字，不是原名
            poacher = (await _sub(client, room_id, other, "t-h2", "米勒")).json()
            assert poacher["display_name"] != "米勒"

            # 錨點：一般成員的名字**照舊釋出**——這條修法不該外溢到既有語意
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": other["participant_id"]},
            )
            revived = await _join_ok(client, room_id, "newcomer-key", "米絲媞")
            assert revived["display_name"] == "米絲媞"


async def test_ephemeral_name_frees_up_once_the_parent_is_gone(tmp_path):
    """名字隨父層的級聯一起釋放——保留期綁在父層的生命週期上，不是永久。"""
    app, client = await _make(tmp_path, "namefree")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _new_room(client)
            parent = await _join_ok(client, room_id, "parent-key", "Novia")
            other = await _join_ok(client, room_id, "other-key", "米絲媞")
            await _sub(client, room_id, parent, "t-h3", "米勒")

            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": parent["participant_id"]},
            )
            reused = (await _sub(client, room_id, other, "t-h4", "米勒")).json()
            assert reused["display_name"] == "米勒"
