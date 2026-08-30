"""撤回提問。

2026-08-30（艾斯維爾提出）：agent 問完之後可能自己找到答案、被指派去做別的
事、或 session 直接結束。題目還掛在 TTL 裡，人看到了、認真想了、回答了——
而那個答案不會有任何人讀。

這是「人回答了但 agent 收不到」的鏡像，代價一樣：**人的時間被花掉，而他不
知道花掉了。** 這個專案裡人類的時間最貴。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _setup(client):
    room = (await client.post("/api/rooms", json={"name": "房"})).json()
    agent = (await client.post(
        f"/api/rooms/{room['id']}/join",
        json={"kind": "claude", "session_key": "a1", "preferred_name": "Novia"},
    )).json()
    human = (await client.post(
        f"/api/rooms/{room['id']}/join",
        json={"kind": "human", "session_key": "h1", "preferred_name": "Bernie",
              "role": "human"},
    )).json()
    return room, agent, human


async def _ask(client, room, agent, human):
    r = await client.post(
        f"/api/rooms/{room['id']}/questions",
        json={"prompt": "還在等嗎？", "target_participant_id": human["participant_id"]},
        headers={"X-Participant-Id": agent["participant_id"]},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_asker_can_cancel_and_the_answer_path_closes(tmp_path):
    app, client = await _make(tmp_path, "cancel_ok")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human)

            r = await client.post(
                f"/api/questions/{q['id']}/cancel",
                headers={"X-Participant-Id": agent["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["status"] == "cancelled"

            got = (await client.get(f"/api/questions/{q['id']}")).json()["question"]
            assert got["status"] == "cancelled"

            # 被問的人現在答不了，而且訊息要說清楚「不用答」
            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "我還是答一下"},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "question_cancelled"
            assert "沒有人在等" in r.json()["detail"]["message"]


@pytest.mark.asyncio
async def test_only_the_asker_can_cancel(tmp_path):
    """被問的人不能撤掉別人的題目——那等於幫對方決定不用問了。"""
    app, client = await _make(tmp_path, "cancel_who")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human)
            r = await client.post(
                f"/api/questions/{q['id']}/cancel",
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_your_question"


@pytest.mark.asyncio
async def test_answered_questions_cannot_be_cancelled(tmp_path):
    """已經回答的撤不掉——人已經花了時間，抹掉等於當作沒發生。"""
    app, client = await _make(tmp_path, "cancel_late")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human)
            await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "在"},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            r = await client.post(
                f"/api/questions/{q['id']}/cancel",
                headers={"X-Participant-Id": agent["participant_id"]},
            )
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "question_already_resolved"


@pytest.mark.asyncio
async def test_leaving_the_room_cancels_your_open_questions(tmp_path):
    """走了就沒有人在等——最常見的情況是 agent 收工，而它不會記得自己還問著。"""
    app, client = await _make(tmp_path, "cancel_leave")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q1 = await _ask(client, room, agent, human)
            q2 = await _ask(client, room, agent, human)

            r = await client.post(
                f"/api/rooms/{room['id']}/leave",
                headers={"X-Participant-Id": agent["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["cancelled_questions"] == 2

            for q in (q1, q2):
                got = (await client.get(
                    f"/api/questions/{q['id']}")).json()["question"]
                assert got["status"] == "cancelled"


@pytest.mark.asyncio
async def test_leaving_does_not_touch_other_peoples_questions(tmp_path):
    """只撤自己問的。別人還在等的題目不該被我的離開帶走。"""
    app, client = await _make(tmp_path, "cancel_leave_mine")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            other = (await client.post(
                f"/api/rooms/{room['id']}/join",
                json={"kind": "claude", "session_key": "a2",
                      "preferred_name": "Miller"},
            )).json()
            mine = await _ask(client, room, agent, human)
            theirs = (await client.post(
                f"/api/rooms/{room['id']}/questions",
                json={"prompt": "我的題目",
                      "target_participant_id": human["participant_id"]},
                headers={"X-Participant-Id": other["participant_id"]},
            )).json()

            await client.post(
                f"/api/rooms/{room['id']}/leave",
                headers={"X-Participant-Id": agent["participant_id"]},
            )

            assert (await client.get(
                f"/api/questions/{mine['id']}")).json()["question"]["status"] \
                == "cancelled"
            assert (await client.get(
                f"/api/questions/{theirs['id']}")).json()["question"]["status"] \
                == "pending"


@pytest.mark.asyncio
async def test_every_ending_leaves_a_receipt(tmp_path):
    """問題有三種結局，每一種都要在時間軸上留下痕跡。

    2026-08-30（艾斯維爾）：「可以消失沒錯，但要跟有回答一樣留下一個區塊在
    訊息歷史中。」answered 早就有收據，cancelled 與 expired 原本什麼都沒有
    ——被撤回的題目在人的畫面上無聲消失，逾時的題目則是發問的 agent 永遠
    不知道對方沒看到。

    三種走同一條路徑，就不會再有「哪一種忘了處理」——結局本來就是列舉的。
    """
    app, client = await _make(tmp_path, "receipts")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)

            answered = await _ask(client, room, agent, human)
            await client.post(
                f"/api/questions/{answered['id']}/answer",
                json={"kind": "free_text", "answer": "好"},
                headers={"X-Participant-Id": human["participant_id"]},
            )

            cancelled = await _ask(client, room, agent, human)
            await client.post(
                f"/api/questions/{cancelled['id']}/cancel",
                headers={"X-Participant-Id": agent["participant_id"]},
            )

            expired = await _ask(client, room, agent, human)
            await app.state.db.execute(
                "UPDATE question SET expires_at=? WHERE id=?",
                ("2020-01-01T00:00:00+00:00", expired["id"]),
            )
            await app.state.db.commit()
            await app.state.sweep_once()

            msgs = (await client.get(
                f"/api/rooms/{room['id']}/messages",
                headers={"X-Participant-Id": agent["participant_id"]},
            )).json()["messages"]
            events = {m["system_event"]: m for m in msgs if m["kind"] == "system"}

            assert "question_answered" in events
            assert "question_cancelled" in events
            assert "question_expired" in events

            # 撤回：告訴**被問的人**不用答了
            assert events["question_cancelled"]["mentions"] == ["Bernie"]
            assert "不用回答" in events["question_cancelled"]["content"]
            # 逾時：告訴**發問者**沒有人看到——他是卡在那裡等的那一個
            assert events["question_expired"]["mentions"] == ["Novia"]
            assert "沒有在時限內" in events["question_expired"]["content"]
