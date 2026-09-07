"""directive 送不進封存房時要在**送出端**講（09/07 卡 c81f757a）。

決策 09/06 #56 裁過形狀，09/07 #78 定了錯誤碼：沿用既有的 `room_archived`
（409），不另造新 code。

要害：**投遞層擋等於「200 但永遠不到」。** 封存房唯讀，投影進不去，而送出的
Supervisor 看到的是成功——他會以為對方已經知道了。這與「目標不在任何房裡」
不是同一件事，後者既有語意是誠實回 `delivered: false`，那條不動：
「他現在收不到」與「這件事根本送不出去」對送出的人意味著不同的下一步。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _room(client, name):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": "human-1"})).json()["id"]


async def _join(client, rid, key, name, role="agent"):
    return (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})).json()["participant_id"]


async def _board_on(client, rid, name="板"):
    bid = (await client.post("/api/boards",
                             headers={"X-Session-Key": "human-1"},
                             json={"name": name})).json()["id"]
    r = await client.post(f"/api/boards/{bid}/rooms/{rid}",
                          headers={"X-Session-Key": "human-1"})
    assert r.status_code == 200, r.text
    return bid


async def _make_supervisor(client, rid, key):
    r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                          headers={"X-Session-Key": "human-1"},
                          json={"session_key": key})
    assert r.status_code == 200, r.text


async def _archive(client, rid):
    r = await client.post(f"/api/rooms/{rid}/archive",
                          headers={"X-Session-Key": "human-1"})
    assert r.status_code == 200, r.text


async def _send(client, bid, key, target=""):
    return await client.post(f"/api/boards/{bid}/directives",
                             headers={"X-Session-Key": key},
                             json={"target_actor_key": target,
                                   "text": "往這個方向改"})


async def test_a_directive_into_an_archived_room_is_refused_at_send(tmp_path):
    """唯一的收件人在封存房裡——這則判斷送不出去，而送出端必須知道。"""
    app, client = await _client(tmp_path, "directive-archived")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        await _join(client, rid, "sup-1", "監督者")
        await _join(client, rid, "worker-1", "工人")
        bid = await _board_on(client, rid)
        await _make_supervisor(client, rid, "sup-1")
        await _archive(client, rid)

        r = await _send(client, bid, "sup-1", target="worker-1")
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "room_archived"


async def test_a_live_room_still_receives_it(tmp_path):
    """板掛兩間房、一間封存：**照送**，只是不投進封存的那間。

    擋的是「送不到」，不是「板上有封存房」——後者會讓一塊有歷史的板從此
    再也送不出任何判斷。
    """
    app, client = await _client(tmp_path, "directive-mixed")
    async with app.router.lifespan_context(app), client:
        old = await _room(client, "舊房")
        new = await _room(client, "新房")
        await _join(client, old, "worker-1", "工人")
        await _join(client, new, "worker-1", "工人")
        await _join(client, new, "sup-1", "監督者")
        bid = await _board_on(client, old)
        r = await client.post(f"/api/boards/{bid}/rooms/{new}",
                              headers={"X-Session-Key": "human-1"})
        assert r.status_code == 200, r.text
        await _make_supervisor(client, new, "sup-1")
        await _archive(client, old)

        r = await _send(client, bid, "sup-1", target="worker-1")
        assert r.status_code == 200, r.text
        assert r.json()["delivered"] is True
        assert r.json()["delivered_rooms"] == [new]


async def test_someone_who_is_simply_not_around_still_gets_the_old_answer(
        tmp_path):
    """目標不在任何掛接房裡——既有語意不動，回 `delivered: false`。

    「他現在收不到」與「這件事根本送不出去」對送出的人意味著不同的下一步：
    前者等他回來，後者要換一個地方說。把兩者合成同一個錯誤等於把那個差別
    抹掉。
    """
    app, client = await _client(tmp_path, "directive-absent")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        await _join(client, rid, "sup-1", "監督者")
        bid = await _board_on(client, rid)
        await _make_supervisor(client, rid, "sup-1")

        r = await _send(client, bid, "sup-1", target="never-here")
        assert r.status_code == 200, r.text
        assert r.json()["delivered"] is False


async def test_a_broadcast_into_an_archived_board_is_refused_too(tmp_path):
    """對整塊板說的那種也一樣——收件人全在封存房裡就是送不出去。"""
    app, client = await _client(tmp_path, "directive-broadcast")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        await _join(client, rid, "sup-1", "監督者")
        await _join(client, rid, "worker-1", "工人")
        bid = await _board_on(client, rid)
        # 廣播的收件人是**板上的成員**，不是房裡的所有人——要顯式加進去，
        # 否則這條測的會是「他不是板成員」，與封存無關
        await client.post(f"/api/boards/{bid}/members",
                          headers={"X-Session-Key": "human-1"},
                          json={"actor_key": "worker-1",
                                "display_name": "工人"})
        await _make_supervisor(client, rid, "sup-1")
        await _archive(client, rid)

        r = await _send(client, bid, "sup-1")
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "room_archived"


async def test_the_audit_trail_does_not_record_what_was_never_sent(tmp_path):
    """被拒的那則**不進稽核串**。

    先寫 event 再擋的話，板上會留下一筆「送出過」，而收件人那邊什麼都沒有
    ——那正是這張卡要消滅的落差，只是換了個地方出現。
    """
    app, client = await _client(tmp_path, "directive-no-audit")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        await _join(client, rid, "sup-1", "監督者")
        await _join(client, rid, "worker-1", "工人")
        bid = await _board_on(client, rid)
        await _make_supervisor(client, rid, "sup-1")
        await _archive(client, rid)
        await _send(client, bid, "sup-1", target="worker-1")

        events = (await client.get(f"/api/boards/{bid}/events",
                                   headers={"X-Session-Key": "human-1"})
                  ).json()["events"]
        assert not [e for e in events if e["event_type"] == "directive"]


async def test_a_refused_directive_does_not_burn_a_sequence_number(tmp_path):
    """被拒的那則連**號碼**都不該領走。

    board_seq 是稽核串的骨架，`tests/test_board_event_completeness.py` 守的是
    「每個被領走的號都有一筆 event」。領了號卻不寫 event 會在串上留一個空洞，
    而空洞比多一筆假紀錄更難查——它不指向任何東西。

    （@開發Novia (UI) 09/07 追問「拒收發生在寫入之前嗎」時一起查出來的：
    event 確實沒寫，但號已經領走了。）
    """
    app, client = await _client(tmp_path, "directive-no-seq")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房")
        await _join(client, rid, "sup-1", "監督者")
        await _join(client, rid, "worker-1", "工人")
        bid = await _board_on(client, rid)
        await _make_supervisor(client, rid, "sup-1")
        await _archive(client, rid)

        before = (await client.get(f"/api/boards/{bid}",
                                   headers={"X-Session-Key": "human-1"})
                  ).json()["board_seq"]
        r = await _send(client, bid, "sup-1", target="worker-1")
        assert r.status_code == 409, r.text
        after = (await client.get(f"/api/boards/{bid}",
                                  headers={"X-Session-Key": "human-1"})
                 ).json()["board_seq"]
        assert after == before
