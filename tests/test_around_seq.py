"""錨定讀取：以某一則為中心，取它前後各 N 則。

給「從釘選牆跳回原文」用——client 手上只有一個 seq，而它多半不在已載入的
視窗裡。沒有這條路徑的話，client 只能反覆往回翻頁直到撞見目標。

**這裡最容易寫錯的是「前後 N 則」的算法。** seq 與 update_seq 共用同一個
room.next_seq 計數器，所以 seq 天生有洞：`seq BETWEEN N-10 AND N+10` 會依
房間的釘選頻率給出不同數量的訊息，而它在乾淨的測試資料上看起來完全正常。
正確的做法是兩段各自 LIMIT 再拼起來。
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


async def _room_with_member(client):
    room_id = (await client.post(
        "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
    me = (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human", "session_key": "owner",
              "preferred_name": "Xavier", "role": "human"},
    )).json()
    return room_id, {"X-Participant-Id": me["participant_id"]}


async def _say(client, room_id, headers, text):
    return (await client.post(f"/api/rooms/{room_id}/messages",
                              json={"content": text}, headers=headers)).json()


async def test_around_seq_returns_the_anchor_in_the_middle(tmp_path):
    app, client = await _make(tmp_path, "around")
    async with app.router.lifespan_context(app), client:
        room_id, headers = await _room_with_member(client)
        sent = [await _say(client, room_id, headers, f"m{i}") for i in range(20)]
        anchor = sent[10]["seq"]

        r = await client.get(f"/api/rooms/{room_id}/messages",
                             params={"around_seq": anchor, "radius": 3},
                             headers=headers)
        assert r.status_code == 200, r.text
        seqs = [m["seq"] for m in r.json()["messages"]]

        assert anchor in seqs
        assert seqs == sorted(seqs)
        # 前後各 3 則 + 錨點自己
        assert len(seqs) == 7
        assert seqs.index(anchor) == 3


async def test_radius_counts_messages_not_seq_distance(tmp_path):
    """seq 有洞，所以「前後 N 則」不能用算術範圍算。

    這條是本檔的核心。釘選會讓既有訊息領一個新的 update_seq，那個號碼由同一
    個計數器發出，於是訊息的 seq 之間出現空洞——`BETWEEN anchor-3 AND
    anchor+3` 會少給好幾則，而且少幾則取決於別人釘了幾次。
    """
    app, client = await _make(tmp_path, "holes")
    async with app.router.lifespan_context(app), client:
        room_id, headers = await _room_with_member(client)
        sent = []
        for i in range(12):
            m = await _say(client, room_id, headers, f"m{i}")
            sent.append(m)
            # 每則都釘一次再取消，狠狠地在 seq 上鑿洞
            await client.post(f"/api/messages/{m['id']}/pin", headers=headers)
            await client.delete(f"/api/messages/{m['id']}/pin", headers=headers)

        anchor = sent[6]["seq"]
        # 前提檢查：洞真的鑿出來了，否則這條測試等於沒驗
        assert sent[7]["seq"] - anchor > 1, "seq 沒有出現空洞，測試前提不成立"

        r = await client.get(f"/api/rooms/{room_id}/messages",
                             params={"around_seq": anchor, "radius": 2},
                             headers=headers)
        seqs = [m["seq"] for m in r.json()["messages"]]

        # 「則」包含釘選收據那種系統訊息——它們也在時間軸上，跳轉時看得到
        assert len(seqs) == 5, f"要的是前後各兩「則」，拿到 {seqs}"
        assert seqs.index(anchor) == 2
        assert seqs == sorted(seqs)
        # 這行才是重點：實際跨度大於 2*radius，所以
        # `seq BETWEEN anchor-2 AND anchor+2` 會少給好幾則，而少幾則取決於
        # 別人釘了幾次——在乾淨的測試資料上它看起來完全正常
        assert max(seqs) - min(seqs) > 4, seqs


async def test_anchor_near_the_edges_returns_fewer_not_an_error(tmp_path):
    app, client = await _make(tmp_path, "edges")
    async with app.router.lifespan_context(app), client:
        room_id, headers = await _room_with_member(client)
        sent = [await _say(client, room_id, headers, f"m{i}") for i in range(5)]

        first = await client.get(f"/api/rooms/{room_id}/messages",
                                 params={"around_seq": sent[0]["seq"], "radius": 1},
                                 headers=headers)
        last = await client.get(f"/api/rooms/{room_id}/messages",
                                params={"around_seq": sent[-1]["seq"], "radius": 1},
                                headers=headers)

        assert first.status_code == 200 and last.status_code == 200
        head, tail = first.json()["messages"], last.json()["messages"]
        # 不足的部分安靜給少一點。上限仍要成立——否則「錨點在裡面」這個
        # 斷言在「參數被忽略、整房照回」的實作下也會通過
        assert len(head) <= 3 and len(tail) <= 3, (len(head), len(tail))
        assert sent[0]["seq"] in [m["seq"] for m in head]
        assert sent[-1]["seq"] in [m["seq"] for m in tail]
        # 最後一則之後沒有東西了
        assert max(m["seq"] for m in tail) == sent[-1]["seq"]


async def test_a_seq_that_never_was_a_message_still_anchors(tmp_path):
    """錨點是位置，不是一則訊息。

    被 update_seq 吃掉的號碼不對應任何訊息，但 client 手上可能就是拿到那個
    數字（例如從 cursor 推算）。回 404 會把一個能用的請求變成錯誤。
    """
    app, client = await _make(tmp_path, "ghost")
    async with app.router.lifespan_context(app), client:
        room_id, headers = await _room_with_member(client)
        sent = [await _say(client, room_id, headers, f"m{i}") for i in range(6)]
        m = sent[3]
        await client.post(f"/api/messages/{m['id']}/pin", headers=headers)
        after_pin = [await _say(client, room_id, headers, f"n{i}") for i in range(3)]
        ghost = after_pin[0]["seq"] - 1  # 釘選領走的那個號

        r = await client.get(f"/api/rooms/{room_id}/messages",
                             params={"around_seq": ghost, "radius": 2},
                             headers=headers)
        assert r.status_code == 200, r.text
        got = r.json()["messages"]
        assert got, "錨點不存在不代表附近沒有東西"
        # 仍然是「附近」而不是整房——否則這條在「參數被忽略」的實作下也會綠
        assert len(got) <= 5, got


async def test_around_seq_conflicts_with_every_other_cursor(tmp_path):
    """三方互斥要三方都擋，不能只擋兩兩組合。"""
    app, client = await _make(tmp_path, "conflict")
    async with app.router.lifespan_context(app), client:
        room_id, headers = await _room_with_member(client)
        await _say(client, room_id, headers, "有東西")

        for params in (
            {"around_seq": 2, "after_seq": 1},
            {"around_seq": 2, "before_seq": 5},
            {"around_seq": 2, "after_seq": 1, "before_seq": 5},
            # 釘選牆是「整房的釘選」，錨定是「這一則附近」，兩種語意矛盾
            {"around_seq": 2, "pinned_only": True},
        ):
            r = await client.get(f"/api/rooms/{room_id}/messages",
                                 params=params, headers=headers)
            assert r.status_code == 422, f"{params} 應該被擋下，卻回 {r.status_code}"
            assert r.json()["detail"]["code"] == "conflicting_cursors"


async def test_around_seq_stays_inside_the_read_boundary(tmp_path):
    """新的讀取路徑要跟舊的守同一條線，否則它就是繞過邊界的後門。"""
    app, client = await _make(tmp_path, "boundary")
    async with app.router.lifespan_context(app), client:
        room_id, headers = await _room_with_member(client)
        await _say(client, room_id, headers, "房內機密")

        assert (await client.get(
            f"/api/rooms/{room_id}/messages",
            params={"around_seq": 2, "radius": 2})).status_code == 401
