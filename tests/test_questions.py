"""向人類提問：定向、只有被問的人能答、逾時不作廢。

存在理由是消除重複發問——多個 agent 各自在自己的 session 裡問同一個人同一件事，
而且答案只有其中一個 agent 看得到。問在房裡，答案就留在房裡。
"""

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

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


async def _room(client, name="房"):
    return (
        await client.post("/api/rooms", json={"name": name, "session_key": "admin"})
    ).json()["id"]


async def _setup(client, humans=1, agents=1):
    room_id = await _room(client)
    people = []
    for i in range(humans):
        people.append(await _join(client, room_id, f"human-{i}", f"人類{i}",
                                  kind="human", role="human"))
    bots = []
    for i in range(agents):
        bots.append(await _join(client, room_id, f"agent-{i}", f"機器{i}"))
    return room_id, people, bots


@pytest.mark.asyncio
async def test_ask_and_answer_roundtrip(tmp_path):
    app, client = await _make(tmp_path, "q_round")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            r = await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "要用哪個方案？",
                      "options": [{"label": "A"}, {"label": "B", "description": "較慢"}]},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            assert r.status_code == 200, r.text
            qid = r.json()["id"]
            # 房內只有一位人類時自動解析對象，不必發問方自己查
            assert r.json()["target_name"] == "人類0"

            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "option", "answer": "B"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            assert r.status_code == 200
            q = (await client.get(f"/api/questions/{qid}")).json()["question"]
            assert q["status"] == "answered"
            assert q["answer"] == "B"
            assert q["answer_kind"] == "option"
            assert q["options"][1]["description"] == "較慢"


@pytest.mark.asyncio
async def test_questions_stay_out_of_the_message_stream(tmp_path):
    """問題是定向的。灌進公開時間軸會變噪音，也會讓別人以為該由自己回答。"""
    app, client = await _make(tmp_path, "q_stream")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            before = (
                await client.get(f"/api/rooms/{room_id}/messages")
            ).json()["messages"]
            await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            after = (
                await client.get(f"/api/rooms/{room_id}/messages")
            ).json()["messages"]
            assert len(after) == len(before)


@pytest.mark.asyncio
async def test_only_the_asked_person_can_answer(tmp_path):
    """定向提問若誰都能答就形同虛設，agent 還可能自問自答。"""
    app, client = await _make(tmp_path, "q_who")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client, humans=1, agents=2)
            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "要繼續嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]

            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "free_text", "answer": "我自己答"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_your_question"

            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "free_text", "answer": "別人答"},
                headers={"X-Participant-Id": bots[1]["participant_id"]},
            )
            assert r.status_code == 403


@pytest.mark.asyncio
async def test_target_resolution_rules(tmp_path):
    app, client = await _make(tmp_path, "q_target")
    async with client:
        async with app.router.lifespan_context(app):
            # 房裡沒有人類：明確要求改用原本的方式問
            room_id, _, bots = await _setup(client, humans=0, agents=1)
            r = await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "no_human_in_room"

            # 多位人類：Hub 不替人猜「誰該回答」
            room2, people2, bots2 = await _setup(client, humans=2, agents=1)
            r = await client.post(
                f"/api/rooms/{room2}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots2[0]["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "target_required"
            assert "人類0" in r.json()["detail"]["message"], "要列出候選才問得下去"

            # 指定之後就成立
            r = await client.post(
                f"/api/rooms/{room2}/questions",
                json={"prompt": "在嗎",
                      "target_participant_id": people2[1]["participant_id"]},
                headers={"X-Participant-Id": bots2[0]["participant_id"]},
            )
            assert r.status_code == 200
            assert r.json()["target_name"] == "人類1"


@pytest.mark.asyncio
async def test_cannot_ask_an_agent(tmp_path):
    """問到 agent 頭上會永遠等不到答案，而且症狀是靜默的（就是一直逾時）。"""
    app, client = await _make(tmp_path, "q_agent")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client, humans=1, agents=2)
            r = await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎",
                      "target_participant_id": bots[1]["participant_id"]},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "target_not_human"


@pytest.mark.asyncio
async def test_skip_is_distinct_from_timeout(tmp_path):
    """人類選擇不在這裡回答 vs 沒看到——agent 的後續處置完全不同。"""
    app, client = await _make(tmp_path, "q_skip")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]
            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "skip"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            assert r.status_code == 200
            assert r.json()["status"] == "skipped"
            q = (await client.get(f"/api/questions/{qid}")).json()["question"]
            assert q["status"] == "skipped"


@pytest.mark.asyncio
async def test_timeout_leaves_question_answerable(tmp_path):
    """逾時只代表『當下沒等到』。標成過期只是畫面好看，代價是丟掉還有用的答案。"""
    app, client = await _make(tmp_path, "q_timeout")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]

            r = await client.get(f"/api/questions/{qid}", params={"wait": 0.2})
            assert r.json()["timed_out"] is True
            assert r.json()["question"]["status"] == "pending"

            # 逾時之後人類仍然答得出來
            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "free_text", "answer": "晚一點才看到"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            assert r.status_code == 200


@pytest.mark.asyncio
async def test_waiting_call_wakes_on_answer(tmp_path):
    """發問方是阻塞等待的——答案進來要立刻喚醒，不能等到逾時才發現。"""
    app, client = await _make(tmp_path, "q_wake")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]

            async def answer_soon():
                await asyncio.sleep(0.1)
                await client.post(
                    f"/api/questions/{qid}/answer",
                    json={"kind": "free_text", "answer": "在"},
                    headers={"X-Participant-Id": people[0]["participant_id"]},
                )

            waiter = asyncio.create_task(
                client.get(f"/api/questions/{qid}", params={"wait": 20.0})
            )
            await answer_soon()
            r = await asyncio.wait_for(waiter, timeout=10.0)
            assert r.json()["question"]["status"] == "answered"
            assert r.json()["question"]["answer"] == "在"
            assert "timed_out" not in r.json()


@pytest.mark.asyncio
async def test_rejects_unanswerable_and_duplicate_answers(tmp_path):
    app, client = await _make(tmp_path, "q_guard")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            # 沒有選項又不准自由作答＝這題無法回答
            r = await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "?", "allow_free_text": False},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "unanswerable_question"

            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "?", "options": [{"label": "A"}],
                      "allow_free_text": False},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]
            # 只准選項時不接受自由作答
            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "free_text", "answer": "我要自己寫"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "free_text_not_allowed"

            await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "option", "answer": "A"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "option", "answer": "A"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            assert r.status_code == 409


@pytest.mark.asyncio
async def test_room_questions_are_visible_to_agents(tmp_path):
    """發問前看得到別人問過什麼，才擋得住重複發問——這是整個機制的目的。"""
    app, client = await _make(tmp_path, "q_list")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client, humans=1, agents=2)
            await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "要用哪個方案？"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )
            r = await client.get(
                f"/api/rooms/{room_id}/questions", params={"status": "pending"}
            )
            qs = r.json()["questions"]
            assert len(qs) == 1
            assert qs[0]["prompt"] == "要用哪個方案？"
            assert qs[0]["asker_name"] == "機器0", "要看得出是誰問的"


@pytest.mark.asyncio
async def test_ws_pushes_questions_only_to_the_target(tmp_path):
    """定向提問若推給全房，UI 上就會出現不是問自己的題目——形同公開發問。"""
    from httpx import ASGITransport
    app, client = await _make(tmp_path, "q_ws")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client, humans=2, agents=1)
            asked = people[0]
            other = people[1]
            await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "只問你一個人",
                      "target_participant_id": asked["participant_id"]},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )

            from starlette.testclient import TestClient
            with TestClient(app) as tc:
                with tc.websocket_connect("/ws") as ws:
                    ws.send_json({"type": "subscribe", "room_id": room_id,
                                  "participant_id": asked["participant_id"]})
                    # 訂閱當下就要收到——問題可能在連線之前就問了
                    for _ in range(5):
                        event = ws.receive_json()
                        if event["type"] == "questions":
                            break
                    assert event["type"] == "questions"
                    assert len(event["questions"]) == 1
                    assert event["questions"][0]["prompt"] == "只問你一個人"

                with tc.websocket_connect("/ws") as ws:
                    ws.send_json({"type": "subscribe", "room_id": room_id,
                                  "participant_id": other["participant_id"]})
                    ws.send_json({"type": "ping"})
                    events = []
                    for _ in range(3):
                        events.append(ws.receive_json())
                        if events[-1]["type"] == "pong":
                            break
                    kinds = [e["type"] for e in events]
                    assert "questions" not in kinds, "不是問他的題目不該推給他"


@pytest.mark.asyncio
async def test_option_answer_must_be_one_of_the_options(tmp_path):
    """不驗的話 kind=option 只是個標籤——agent 會把它當成「從我的清單選的」信任。"""
    app, client = await _make(tmp_path, "q_option_guard")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "A 還是 B？",
                      "options": [{"label": "A"}, {"label": "B"}]},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]
            r = await client.post(
                f"/api/questions/{qid}/answer",
                json={"kind": "option", "answer": "C"},
                headers={"X-Participant-Id": people[0]["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "unknown_option"


@pytest.mark.asyncio
async def test_concurrent_answers_do_not_overwrite_each_other(tmp_path):
    """先 SELECT 再 UPDATE 之間的空隙會讓後到的答案靜靜蓋掉先到的。"""
    app, client = await _make(tmp_path, "q_race")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            qid = (await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "在嗎"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )).json()["id"]

            async def answer(text):
                return await client.post(
                    f"/api/questions/{qid}/answer",
                    json={"kind": "free_text", "answer": text},
                    headers={"X-Participant-Id": people[0]["participant_id"]},
                )

            results = await asyncio.gather(answer("先到"), answer("後到"))
            codes = sorted(r.status_code for r in results)
            assert codes == [200, 409], "只能有一個成功，另一個要明確衝突"
            q = (await client.get(f"/api/questions/{qid}")).json()["question"]
            assert q["answer"] in ("先到", "後到")
            assert q["status"] == "answered"


@pytest.mark.asyncio
async def test_resubscribe_with_identity_upgrades_the_pump(tmp_path):
    """首次進房是「先訂閱、join 完才拿到身分」——補送的 subscribe 必須生效。

    只看「有沒有 pump」的話，第二次 subscribe 會被整個忽略，而既有 pump 是用
    空身分建的，結果是首次進房的人永遠收不到定向問題，且畫面上毫無異狀。
    """
    app, client = await _make(tmp_path, "q_resub")
    async with client:
        async with app.router.lifespan_context(app):
            room_id, people, bots = await _setup(client)
            await client.post(
                f"/api/rooms/{room_id}/questions",
                json={"prompt": "身分補上之後才該看到我"},
                headers={"X-Participant-Id": bots[0]["participant_id"]},
            )

            from starlette.testclient import TestClient
            with TestClient(app) as tc:
                with tc.websocket_connect("/ws") as ws:
                    # 第一次：還沒 join，沒有身分
                    ws.send_json({"type": "subscribe", "room_id": room_id})
                    ws.send_json({"type": "ping"})
                    first = []
                    for _ in range(3):
                        first.append(ws.receive_json())
                        if first[-1]["type"] == "pong":
                            break
                    assert "questions" not in [e["type"] for e in first]

                    # 第二次：身分就緒後補送
                    ws.send_json({
                        "type": "subscribe", "room_id": room_id,
                        "participant_id": people[0]["participant_id"],
                    })
                    got = None
                    for _ in range(5):
                        event = ws.receive_json()
                        if event["type"] == "questions":
                            got = event
                            break
                    assert got is not None, "補送的 subscribe 被忽略了"
                    assert got["questions"][0]["prompt"] == "身分補上之後才該看到我"
