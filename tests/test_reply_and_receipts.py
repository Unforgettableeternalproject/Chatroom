"""回覆＝mention、釘選通知發送者、提問答案在時間軸留下收據。

這三件事共用一個主題：**房內發生的事要有人知道**。在此之前，回覆送出去對方
不會醒、訊息被釘只有釘的人知道、問題的答案只活在 question 表裡沒有人看得到。
"""

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


async def _post(client, room_id, pid, content, **body):
    r = await client.post(
        f"/api/rooms/{room_id}/messages",
        json={"content": content, **body},
        headers={"X-Participant-Id": pid},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _messages(client, room_id, pid):
    r = await client.get(
        f"/api/rooms/{room_id}/messages", headers={"X-Participant-Id": pid}
    )
    assert r.status_code == 200, r.text
    return r.json()["messages"]


# ---------- 回覆＝mention，並帶回覆目標的 seq ----------


@pytest.mark.asyncio
async def test_reply_mentions_the_author_and_carries_seq(tmp_path):
    app, client = await _make(tmp_path, "reply_mention")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            b = await _join(client, room_id, "sess-b", "Echo")
            first = await _post(client, room_id, a["participant_id"], "原始訊息")

            # 沒填任何 mentions，只填 reply_to
            replied = await _post(
                client, room_id, b["participant_id"], "我回你",
                reply_to=first["id"],
            )
            assert replied["mentions"] == ["Nova"]
            assert replied["reply_to_seq"] == first["seq"]

            # 被回覆的人 long-poll 時要被標記成「有人 ping 你」
            r = await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": replied["seq"] - 1, "timeout": 1},
                headers={"X-Participant-Id": a["participant_id"]},
            )
            assert r.json()["you_were_mentioned"] is True

            msg = [m for m in await _messages(client, room_id, a["participant_id"])
                   if m["id"] == replied["id"]][0]
            assert msg["reply_to_seq"] == first["seq"]
            assert msg["reply_preview"]["seq"] == first["seq"]


@pytest.mark.asyncio
async def test_reply_keeps_explicit_mentions_and_does_not_duplicate(tmp_path):
    app, client = await _make(tmp_path, "reply_dedup")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            b = await _join(client, room_id, "sess-b", "Echo")
            c = await _join(client, room_id, "sess-c", "Quill")
            first = await _post(client, room_id, a["participant_id"], "原始")

            replied = await _post(
                client, room_id, b["participant_id"], "回覆並額外 ping",
                reply_to=first["id"], mentions=["Quill", "Nova"],
            )
            # 已經在名單裡就不重複加；順序維持呼叫端給的
            assert replied["mentions"] == ["Quill", "Nova"]
            assert c  # 房內第三人只是用來確認 mentions 不會被吃掉


@pytest.mark.asyncio
async def test_replying_to_self_does_not_ping_self(tmp_path):
    app, client = await _make(tmp_path, "reply_self")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            first = await _post(client, room_id, a["participant_id"], "自言自語")
            replied = await _post(
                client, room_id, a["participant_id"], "補充",
                reply_to=first["id"],
            )
            assert replied["mentions"] == []
            assert replied["reply_to_seq"] == first["seq"]


@pytest.mark.asyncio
async def test_reply_to_departed_author_is_reported_as_unresolved(tmp_path):
    """回覆一個已經離開的人：訊息照發，但要講出來沒人會被叫醒。"""
    app, client = await _make(tmp_path, "reply_gone")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            b = await _join(client, room_id, "sess-b", "Echo")
            first = await _post(client, room_id, a["participant_id"], "原始")
            await client.post(
                f"/api/rooms/{room_id}/leave",
                headers={"X-Participant-Id": a["participant_id"]},
            )
            replied = await _post(
                client, room_id, b["participant_id"], "回覆",
                reply_to=first["id"],
            )
            assert replied["unresolved_mentions"] == ["Nova"]


@pytest.mark.asyncio
async def test_reply_to_system_message_pings_nobody(tmp_path):
    app, client = await _make(tmp_path, "reply_system")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            msgs = await _messages(client, room_id, a["participant_id"])
            system = [m for m in msgs if m["kind"] == "system"][0]
            replied = await _post(
                client, room_id, a["participant_id"], "回系統訊息",
                reply_to=system["id"],
            )
            assert replied["mentions"] == []
            assert replied["reply_to_seq"] == system["seq"]


# ---------- 釘選一律通知被釘訊息的發送者 ----------


@pytest.mark.asyncio
async def test_pin_notifies_the_author_whoever_pinned(tmp_path):
    app, client = await _make(tmp_path, "pin_notify")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            b = await _join(client, room_id, "sess-b", "Echo")
            msg = await _post(client, room_id, a["participant_id"], "重要決策")

            r = await client.post(
                f"/api/messages/{msg['id']}/pin",
                headers={"X-Participant-Id": b["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["notified"] == "Nova"

            receipt = (await _messages(client, room_id, a["participant_id"]))[-1]
            assert receipt["system_event"] == "pin"
            assert receipt["mentions"] == ["Nova"]
            # 收據指回被釘的那則，UI 不必自己去猜是哪一條
            assert receipt["reply_to_seq"] == msg["seq"]

            r = await client.get(
                f"/api/rooms/{room_id}/updates",
                params={"after_seq": msg["seq"], "timeout": 1},
                headers={"X-Participant-Id": a["participant_id"]},
            )
            assert r.json()["you_were_mentioned"] is True


@pytest.mark.asyncio
async def test_self_pin_still_notifies(tmp_path):
    """「無論釘選者是誰」包含自己——規則不因身分而有特例。"""
    app, client = await _make(tmp_path, "pin_self")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            msg = await _post(client, room_id, a["participant_id"], "我自己的話")
            r = await client.post(
                f"/api/messages/{msg['id']}/pin",
                headers={"X-Participant-Id": a["participant_id"]},
            )
            assert r.json()["notified"] == "Nova"


@pytest.mark.asyncio
async def test_repeat_pin_does_not_send_a_second_receipt(tmp_path):
    app, client = await _make(tmp_path, "pin_repeat")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            msg = await _post(client, room_id, a["participant_id"], "訊息")
            pid = a["participant_id"]
            await client.post(f"/api/messages/{msg['id']}/pin",
                              headers={"X-Participant-Id": pid})
            r = await client.post(f"/api/messages/{msg['id']}/pin",
                                  headers={"X-Participant-Id": pid})
            assert r.json()["already_pinned"] is True
            receipts = [m for m in await _messages(client, room_id, pid)
                        if m["system_event"] == "pin"]
            assert len(receipts) == 1


@pytest.mark.asyncio
async def test_pinning_a_system_message_leaves_a_receipt_without_mentions(tmp_path):
    app, client = await _make(tmp_path, "pin_system")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "sess-a", "Nova")
            pid = a["participant_id"]
            joined = [m for m in await _messages(client, room_id, pid)
                      if m["system_event"] == "join"][0]
            # 加入訊息的 sender_id 是加入者本人，改用一則真正沒有發送者的：
            # 先讓另一個人離開
            b = await _join(client, room_id, "sess-b", "Echo")
            await client.post(f"/api/rooms/{room_id}/leave",
                              headers={"X-Participant-Id": b["participant_id"]})
            left = [m for m in await _messages(client, room_id, pid)
                    if m["system_event"] == "leave"][0]
            assert left["sender_id"] is None
            r = await client.post(f"/api/messages/{left['id']}/pin",
                                  headers={"X-Participant-Id": pid})
            assert r.status_code == 200, r.text
            assert r.json()["notified"] is None
            receipt = (await _messages(client, room_id, pid))[-1]
            assert receipt["system_event"] == "pin"
            assert receipt["mentions"] == []
            assert joined  # 上面取來確認加入訊息確實掛著發送者


# ---------- 提問被回答後留下收據 ----------


async def _ask(client, room_id, asker_pid, target_pid, prompt="要用哪個方案？",
               **body):
    r = await client.post(
        f"/api/rooms/{room_id}/questions",
        json={"prompt": prompt, "target_participant_id": target_pid, **body},
        headers={"X-Participant-Id": asker_pid},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_answering_leaves_a_receipt_with_the_full_answer(tmp_path):
    app, client = await _make(tmp_path, "receipt_answer")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            human = await _join(client, room_id, "sess-h", "Bernie",
                                kind="human", role="human")
            bot = await _join(client, room_id, "sess-a", "Nova")
            q = await _ask(client, room_id, bot["participant_id"],
                           human["participant_id"])
            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "走 v2，舊的別動"},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["receipt_seq"] > 0

            receipt = (await _messages(client, room_id,
                                       bot["participant_id"]))[-1]
            assert receipt["system_event"] == "question_answered"
            assert "要用哪個方案？" in receipt["content"]
            # 答案全文，不截斷——被截斷的決定等於沒有決定
            assert "走 v2，舊的別動" in receipt["content"]
            # 發問方被 mention：它可能早就放棄等待了
            assert receipt["mentions"] == ["Nova"]


@pytest.mark.asyncio
async def test_skipping_leaves_a_distinct_receipt(tmp_path):
    app, client = await _make(tmp_path, "receipt_skip")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            human = await _join(client, room_id, "sess-h", "Bernie",
                                kind="human", role="human")
            bot = await _join(client, room_id, "sess-a", "Nova")
            q = await _ask(client, room_id, bot["participant_id"],
                           human["participant_id"])
            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "skip", "answer": ""},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text
            receipt = (await _messages(client, room_id,
                                       bot["participant_id"]))[-1]
            assert receipt["system_event"] == "question_skipped"
            assert receipt["mentions"] == ["Nova"]


@pytest.mark.asyncio
async def test_long_prompt_is_summarised_in_the_receipt(tmp_path):
    app, client = await _make(tmp_path, "receipt_long")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            human = await _join(client, room_id, "sess-h", "Bernie",
                                kind="human", role="human")
            bot = await _join(client, room_id, "sess-a", "Nova")
            q = await _ask(client, room_id, bot["participant_id"],
                           human["participant_id"], prompt="長" * 400)
            await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "短答案"},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            receipt = (await _messages(client, room_id,
                                       bot["participant_id"]))[-1]
            assert "…" in receipt["content"]
            assert "短答案" in receipt["content"]
            assert len(receipt["content"]) < 300
