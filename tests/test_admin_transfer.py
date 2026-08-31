"""管理員身分：標示、移轉，以及「管理員要離開」這個缺口。

房間的管理權綁在 `creator_session_key` 上，而它從來沒有出口——成員列表看不出
誰是管理員，也沒有任何方式把它交給別人。於是管理員一離開，房間就永遠沒有人
能封存、踢人或收回邀請。

**不變量：一個 active 的房間永遠有一個管理員。** 「管理員離開」是這條不變量
最後一個缺口，補上之後才算閉合。

管理員只能是人類：agent 會被 presence sweeper 以閒置移除，把管理權交給一個
隨時會消失的身分等於把它丟掉。
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


async def _room(client, key="owner"):
    return (await client.post(
        "/api/rooms", json={"name": "房", "session_key": key})).json()["id"]


async def _join(client, room_id, key, name, role="human", kind="human"):
    return (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": kind, "session_key": key,
              "preferred_name": name, "role": role},
    )).json()


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def _members(client, room_id, viewer):
    r = await client.get(f"/api/rooms/{room_id}", headers=_pid(viewer))
    return {m["display_name"]: m for m in r.json()["participants"]}


async def test_member_list_says_who_the_admin_is(tmp_path):
    """成員列表要標出管理員。

    `you_are_admin` 只答得出「我是不是」，答不出「誰是」——沒有這個欄位，
    App 想在名字後面掛一個標籤都做不到。
    """
    app, client = await _make(tmp_path, "flag")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "guest", "Guest")

        members = await _members(client, room_id, admin)
        assert members["Xavier"]["is_admin"] is True
        assert members["Guest"]["is_admin"] is False


async def test_admin_can_hand_over_to_another_human(tmp_path):
    app, client = await _make(tmp_path, "transfer")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        heir = await _join(client, room_id, "guest", "Guest")

        r = await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": heir["participant_id"]},
            headers=_pid(admin),
        )
        assert r.status_code == 200, r.text

        members = await _members(client, room_id, heir)
        assert members["Guest"]["is_admin"] is True
        # 原管理員降為一般成員——兩個管理員與零個管理員一樣糟
        assert members["Xavier"]["is_admin"] is False

        # 交出去就真的交出去了：舊管理員不能再交回來
        back = await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": admin["participant_id"]},
            headers=_pid(admin),
        )
        assert back.status_code == 403


async def test_admin_must_be_human(tmp_path):
    """agent 當管理員＝把管理權丟掉。

    presence sweeper 會以閒置移除 agent，那時房間就沒有管理員了，而這條
    不變量沒有任何地方會替它報錯。
    """
    app, client = await _make(tmp_path, "human_only")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        bot = await _join(client, room_id, "a1", "Novia",
                          role="agent", kind="claude")

        r = await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": bot["participant_id"]},
            headers=_pid(admin),
        )
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "admin_must_be_human"


async def test_only_the_admin_can_hand_over(tmp_path):
    app, client = await _make(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        await _join(client, room_id, "owner", "Xavier")
        a = await _join(client, room_id, "g1", "Guest")
        b = await _join(client, room_id, "g2", "Other")

        r = await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": b["participant_id"]},
            headers=_pid(a),
        )
        assert r.status_code == 403


async def test_cannot_hand_over_to_someone_who_left(tmp_path):
    """交給一個已經離開的人，等於把管理權丟進黑洞。"""
    app, client = await _make(tmp_path, "gone")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        leaver = await _join(client, room_id, "guest", "Guest")
        await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(leaver))

        r = await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": leaver["participant_id"]},
            headers=_pid(admin),
        )
        # 驗 code 不只驗 404：端點不存在時也是 404，那顆綠燈什麼都不代表
        assert r.status_code == 404
        assert r.json()["detail"]["code"] == "heir_not_found"


async def test_admin_leaving_is_refused_until_they_decide(tmp_path):
    """管理員不能就這樣走掉。

    走掉的話房間永遠沒有人能封存、踢人或收回邀請——而那個狀態沒有任何地方
    會報錯，只會在下次有人需要管理員時才發現。

    回應要附上可以接手的人，App 才跳得出「移轉給誰」那個選項；候選是空的
    時候，UI 只剩封存那條路可走。
    """
    app, client = await _make(tmp_path, "leave")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "guest", "Guest")
        await _join(client, room_id, "a1", "Novia", role="agent", kind="claude")

        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(admin))
        assert r.status_code == 409
        detail = r.json()["detail"]
        assert detail["code"] == "admin_must_hand_over"
        # agent 不算候選——它不能當管理員
        assert [c["display_name"] for c in detail["human_candidates"]] == ["Guest"]


async def test_the_last_human_admin_can_leave_by_archiving_first(tmp_path):
    """房裡沒有別的人類時，封存是唯一的出路。

    封存過的房間不再需要管理員（它已經唯讀），所以那條不變量只約束 active
    的房間。
    """
    app, client = await _make(tmp_path, "last")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        await _join(client, room_id, "a1", "Novia", role="agent", kind="claude")

        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(admin))
        assert r.status_code == 409
        assert r.json()["detail"]["human_candidates"] == []

        await client.post(f"/api/rooms/{room_id}/archive", headers=_pid(admin))
        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(admin))
        assert r.status_code == 200, r.text


async def test_after_handing_over_the_old_admin_can_leave(tmp_path):
    app, client = await _make(tmp_path, "then_leave")
    async with app.router.lifespan_context(app), client:
        room_id = await _room(client)
        admin = await _join(client, room_id, "owner", "Xavier")
        heir = await _join(client, room_id, "guest", "Guest")

        await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": heir["participant_id"]},
            headers=_pid(admin),
        )
        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(admin))
        assert r.status_code == 200, r.text

        # 新管理員真的握得住權：他自己要走時也會被同一條規則擋下
        r = await client.post(f"/api/rooms/{room_id}/leave", headers=_pid(heir))
        assert r.status_code == 409
