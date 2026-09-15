"""向人類提問的逾時。

`chatroom_ask_human` 不是「留言給人類」——**發問的 agent 是卡在那裡等的**。
時限拉長不是比較寬容，是讓一條工作流癱瘓那麼久，所以預設只有 3 分鐘
（艾斯維爾定的，理由就是 background task 會卡住）。

逾時只標記狀態、不刪紀錄：人類仍看得到問過什麼，agent 也分得出
「沒看到」（expired）與「明確不想在這裡答」（skipped）——那兩者的後續處置
完全不同。

⚠️ 這裡的核心是**即時判定**：sweeper 每輪之間最多 30 秒空窗，而那個誤差是
使用者看得到的（卡片該消失卻還在，點下去才發現過期）。狀態以時間為準。
"""

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="",
                 log_dir=str(tmp_path / "logs"), **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test")


async def _setup(client):
    """一個房、一個 agent（發問）、一個人類（被問）。"""
    room_id = (await client.post(
        "/api/rooms", json={"name": "房", "session_key": "admin-key"})).json()["id"]
    human = (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human", "session_key": "h1", "preferred_name": "Xavier",
              "role": "human"})).json()
    bot = (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": "a1", "preferred_name": "Novia",
              "role": "agent"})).json()
    return room_id, human, bot


async def _ask(client, room_id, bot, human, **extra):
    r = await client.post(
        f"/api/rooms/{room_id}/questions",
        json={"prompt": "要用哪個方案？",
              "target_participant_id": human["participant_id"], **extra},
        headers={"X-Participant-Id": bot["participant_id"]},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_question_carries_its_deadline(tmp_path):
    """發問方要當場知道自己能等多久——不然它無法決定要不要等。"""
    app, client = await _make(tmp_path, "deadline", question_ttl=180)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        out = await _ask(client, room_id, bot, human)
        assert out["expires_at"]
        assert out["expires_in_seconds"] == 180


async def test_per_question_timeout_overrides_the_default(tmp_path):
    app, client = await _make(tmp_path, "override", question_ttl=180)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        out = await _ask(client, room_id, bot, human, timeout_seconds=30)
        assert out["expires_in_seconds"] == 30


async def test_expired_question_reads_as_expired_before_the_sweeper_runs(tmp_path):
    """🔑 即時判定：sweeper 還沒跑到，狀態就該是 expired。

    這是整條的重點——UI 靠讀取結果決定要不要顯示卡片，等 sweeper 就會有
    一段「該消失卻還在」的空窗，而使用者會在那段空窗裡點下去。
    """
    # sweep_interval 拉到很長，確保這條測到的一定是即時判定而不是 sweeper
    app, client = await _make(tmp_path, "instant", sweep_interval=9999)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        qid = (await _ask(client, room_id, bot, human,
                          timeout_seconds=0.4))["id"]
        await asyncio.sleep(0.6)

        q = (await client.get(f"/api/questions/{qid}")).json()["question"]
        assert q["status"] == "expired"
        assert q["expires_in_seconds"] == 0

        # 待答清單也要當場少一題，否則 UI 的未答數字會比實際多
        pending = (await client.get(
            f"/api/rooms/{room_id}/questions", params={"status": "pending"},
            headers={"X-Participant-Id": bot["participant_id"]},
        )).json()["questions"]
        assert pending == []
        # 反過來查 expired 也要查得到（同樣不等 sweeper）
        expired = (await client.get(
            f"/api/rooms/{room_id}/questions", params={"status": "expired"},
            headers={"X-Participant-Id": bot["participant_id"]},
        )).json()["questions"]
        assert [q["id"] for q in expired] == [qid]


async def test_answering_after_expiry_is_refused(tmp_path):
    """競態：卡片消失的那一瞬間人剛好按下去。

    放行的話發問方會在**已經放棄之後**收到答案，那比沒收到更難處理。
    """
    app, client = await _make(tmp_path, "race", sweep_interval=9999)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        qid = (await _ask(client, room_id, bot, human,
                          timeout_seconds=0.4))["id"]
        await asyncio.sleep(0.6)

        r = await client.post(
            f"/api/questions/{qid}/answer",
            json={"kind": "free_text", "answer": "來不及了"},
            headers={"X-Participant-Id": human["participant_id"]},
        )
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "question_expired"
        # 錯誤訊息要給出路：人還是想講的話，直接在聊天室講
        assert "聊天室" in r.json()["detail"]["message"]


async def test_wait_does_not_outlive_the_question(tmp_path):
    """問題只剩 0.4 秒時掛滿 5 秒，等於讓發問方多卡 4.6 秒等一個不會來的答案。"""
    app, client = await _make(tmp_path, "budget", sweep_interval=9999)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        qid = (await _ask(client, room_id, bot, human,
                          timeout_seconds=0.4))["id"]

        started = asyncio.get_event_loop().time()
        out = (await client.get(f"/api/questions/{qid}",
                                params={"wait": 5.0})).json()
        elapsed = asyncio.get_event_loop().time() - started

        assert elapsed < 2.0, "等待沒有被問題的剩餘壽命夾住"
        assert out["question"]["status"] == "expired"
        # timed_out 是「你這次等夠久了」，expired 是「這題沒了」——
        # 前者可以再等一次，後者再等也沒有用
        assert out["expired"] is True


async def test_sweeper_writes_the_status_down(tmp_path):
    """即時判定管畫面，落庫管歷史——兩者都要對。"""
    app, client = await _make(tmp_path, "sweep", sweep_interval=0.05)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        qid = (await _ask(client, room_id, bot, human,
                          timeout_seconds=0.2))["id"]
        for _ in range(40):
            await asyncio.sleep(0.05)
            row = await (await app.state.db.execute(
                "SELECT status, resolved_at FROM question WHERE id=?", (qid,)
            )).fetchone()
            if row["status"] == "expired":
                break
        assert row["status"] == "expired"
        assert row["resolved_at"], "落庫時要記下處理時間"


async def test_answered_in_time_still_wins(tmp_path):
    """逾時機制不該傷到正常路徑。"""
    app, client = await _make(tmp_path, "ok", question_ttl=180)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        qid = (await _ask(client, room_id, bot, human))["id"]
        r = await client.post(
            f"/api/questions/{qid}/answer",
            json={"kind": "free_text", "answer": "用 A"},
            headers={"X-Participant-Id": human["participant_id"]},
        )
        assert r.status_code == 200
        q = (await client.get(f"/api/questions/{qid}")).json()["question"]
        assert q["status"] == "answered" and q["answer"] == "用 A"


async def test_skipped_is_not_expired(tmp_path):
    """「我不想在這裡答」與「我沒看到」是兩件事，agent 的處置不同。"""
    app, client = await _make(tmp_path, "skip", question_ttl=180)
    async with app.router.lifespan_context(app), client:
        room_id, human, bot = await _setup(client)
        qid = (await _ask(client, room_id, bot, human))["id"]
        await client.post(
            f"/api/questions/{qid}/answer", json={"kind": "skip"},
            headers={"X-Participant-Id": human["participant_id"]},
        )
        q = (await client.get(f"/api/questions/{qid}")).json()["question"]
        assert q["status"] == "skipped"
