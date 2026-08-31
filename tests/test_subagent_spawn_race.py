"""spawn 與父層離場交錯時，不得留下「父層已走、subagent 還活著」的孤兒。

級聯移除保證的是「父層退場那一刻，旗下 subagent 一起消失」。但那個保證是
**時序**的：spawn 先 SELECT 到 active 的父層、leave 隨後把父層與當時的
subagent 一起移除並 commit、spawn 再拿著手上那份快照 INSERT——INSERT 沒有
重新要求父層仍是 active，於是插進一個永遠不會被級聯到的 ephemeral 成員。

契約（docs/SUBAGENT-IDENTITY.md §3.5）說這個狀態不可達。要讓它真的不可達，
條件必須寫進 INSERT 本身，由資料庫保證，而不是靠兩次查詢之間沒有人插隊。

由 Codex review 第三輪抓出（房內 seq 148 #3）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def test_spawn_racing_parent_leave_leaves_no_orphan(tmp_path):
    """父層在 spawn 的兩次查詢之間離場 → subagent 必須被拒，不是變成孤兒。

    交錯點用 db.execute 的攔截器製造：spawn 走到 INSERT 的**前一刻**，讓
    父層完成 leave。這比 sleep 對時可靠——競態測試若靠時間湊，綠燈多半來自
    沒撞上，而不是來自修好了。
    """
    app, client = await _make(tmp_path, "spawn_race")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms", json={"name": "房"})).json()["id"]
            parent = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "p-1",
                      "preferred_name": "Parent", "role": "agent"},
            )).json()

            db = app.state.db
            original = db.execute
            fired = False

            async def intercept(sql, *args, **kwargs):
                # 只攔第一次：leave 本身也會走 execute，攔它會無限套疊
                nonlocal fired
                if not fired and "INSERT INTO participant" in sql:
                    fired = True
                    r = await client.post(
                        f"/api/rooms/{room_id}/leave",
                        headers={"X-Participant-Id": parent["participant_id"]},
                    )
                    assert r.status_code == 200, r.text
                return await original(sql, *args, **kwargs)

            db.execute = intercept
            try:
                spawned = await client.post(
                    f"/api/rooms/{room_id}/join",
                    json={"kind": "claude",
                          "session_key": f"{parent['session_key']}#worker-a1b2",
                          "preferred_name": "worker", "role": "agent",
                          "parent_participant_id": parent["participant_id"]},
                )
            finally:
                db.execute = original

            assert fired, "攔截器沒被觸發，這一輪根本沒有製造出交錯"

            # 正向錨點：父層真的走了（否則下面的「沒有孤兒」是因為沒人離場）
            # 房間是讀取邊界，要帶身分；離開過的成員仍讀得到（刻意的）
            detail = (await client.get(
                f"/api/rooms/{room_id}",
                headers={"X-Participant-Id": parent["participant_id"]},
            )).json()
            actives = [p for p in detail["participants"]
                       if p["status"] == "active"]
            assert all(p["id"] != parent["participant_id"] for p in actives), \
                "父層還在，交錯沒有成立"

            assert spawned.status_code == 404, spawned.text
            assert spawned.json()["detail"]["code"] == "parent_not_found"
            assert [p for p in actives if p.get("ephemeral")] == [], \
                "留下了孤兒：父層已離場，旗下 subagent 仍是 active"


async def test_spawn_still_works_when_parent_stays(tmp_path):
    """反向錨點：父層沒走的時候，spawn 照樣成功。

    少了這條，把 INSERT 的條件寫成「永遠 0 rows」也會讓上面那條變綠——
    功能整個關掉與競態修好，在單邊斷言下同形。
    """
    app, client = await _make(tmp_path, "spawn_race_ok")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms", json={"name": "房"})).json()["id"]
            parent = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "p-1",
                      "preferred_name": "Parent", "role": "agent"},
            )).json()
            r = await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude",
                      "session_key": f"{parent['session_key']}#worker-a1b2",
                      "preferred_name": "worker", "role": "agent",
                      "parent_participant_id": parent["participant_id"]},
            )
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["identity_scope"] == "subagent"
            assert body["parent_participant_id"] == parent["participant_id"]


async def test_join_returns_joined_seq(tmp_path):
    """join 要把 `joined_seq` 交給呼叫端。

    Hub 早就算好它（mention 判定的界線），但沒有回傳——於是 bridge 想拿
    「這個身分是從房內哪一則開始的」當 subagent 的游標起點時，只能自己猜
    一個。猜出來的起點會重播或漏訊息，而兩者都不會報錯。
    """
    app, client = await _make(tmp_path, "joined_seq_out")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms", json={"name": "房"})).json()["id"]
            first = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "p-1",
                      "preferred_name": "Parent", "role": "agent"},
            )).json()
            # 空房的第一個成員：加入前房內沒有任何訊息
            assert first["joined_seq"] == 0

            await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "先講幾句"},
                headers={"X-Participant-Id": first["participant_id"]},
            )
            later = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude", "session_key": "p-2",
                      "preferred_name": "Later", "role": "agent"},
            )).json()
            # 晚到的人：界線是他加入前的最後一則，而不是 0
            assert later["joined_seq"] > first["joined_seq"]

            sub = (await client.post(
                f"/api/rooms/{room_id}/join",
                json={"kind": "claude",
                      "session_key": f"{later['session_key']}#worker-a1b2",
                      "preferred_name": "worker", "role": "agent",
                      "parent_participant_id": later["participant_id"]},
            )).json()
            # subagent 也要有：它正是要拿這個值當游標起點的那一個
            assert sub["joined_seq"] >= later["joined_seq"]


async def test_rejoin_returns_the_existing_boundary_not_a_fresh_one(tmp_path):
    """冪等 rejoin 回的是既有身分的界線，不是此刻的房內 seq。

    身分沒變，它「從哪一則開始」也就沒變。回當下的值會讓呼叫端以為自己
    剛出生，於是把中間那段當成加入前的東西跳過去。
    """
    app, client = await _make(tmp_path, "rejoin_boundary")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post(
                "/api/rooms", json={"name": "房"})).json()["id"]
            body = {"kind": "claude", "session_key": "p-1",
                    "preferred_name": "Parent", "role": "agent"}
            first = (await client.post(
                f"/api/rooms/{room_id}/join", json=body)).json()

            for _ in range(3):
                await client.post(
                    f"/api/rooms/{room_id}/messages",
                    json={"content": "訊息"},
                    headers={"X-Participant-Id": first["participant_id"]},
                )

            again = (await client.post(
                f"/api/rooms/{room_id}/join", json=body)).json()
            assert again["rejoined"] is True
            assert again["joined_seq"] == first["joined_seq"]
