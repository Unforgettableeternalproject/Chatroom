"""週期收尾的**留痕與通知打不打得到**——四個缺口（09/08 週期）。

09/06 補的 `_settlement_notices` 解決了「收件人從誰在房裡算」那一半，
但留痕與收件人兩軸都還各缺兩塊：

1. **reopen 什麼都不做**。送審／確認／完成三個轉折都有 system 訊息，
   唯獨打回沒有——而它正是「你做的東西被退回來了」，最該讓人知道的那一個。
2. **cancel 同樣什麼都不做**（Hub 盤點於 09/08 補開的卡）。
3. **system 訊息只發到 `row["room_id"]`**，也就是週期建立時所在那一間房。
   板可以掛好幾間房，而那一間**可能已經封存**——那時整個週期的收尾在所有
   還活著的房裡看不到任何痕跡。留痕存在的理由就是給後來的人看，發在一間
   沒有人會再打開的房裡等於沒發。
4. **supervisor 不在收件人裡**。他是這塊板上唯一「負責看」的那個人，卻因為
   沒有親手認領任何一張卡而落在 `_settlement_notices` 的集合之外。

四條都是靜默失效：沒有任何地方會報錯，只是該知道的人不知道。
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


async def _join(client, rid, key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": key,
        "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _room(client, name, key):
    r = await client.post("/api/rooms", json={"name": name, "session_key": key})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _notices(client, key):
    r = await client.get("/api/board/notices", params={"unread_only": True},
                         headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text
    return r.json()["notices"]


async def _events(client, rid, hdr):
    """房內所有 system 訊息的 system_event 清單。"""
    r = await client.get(f"/api/rooms/{rid}/messages",
                         params={"after_seq": 0, "limit": 200}, headers=hdr)
    assert r.status_code == 200, r.text
    return [m["system_event"] for m in r.json()["messages"]
            if m["kind"] == "system"]


async def _cycle(client, rid, human, worker, title="一個週期"):
    """在 rid 開一個週期，agent 接一張卡做完，清單收尾。回 objective_id。"""
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": title},
                             headers=human)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "Server 端"},
                             headers=human)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "一張卡"},
                             headers=human)).json()["id"]
    assert (await client.post(f"/api/board/tasks/{tid}/claim",
                              headers=worker)).status_code == 200
    assert (await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"},
                              headers=worker)).status_code == 200
    assert (await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"},
                              headers=human)).status_code == 200
    return oid


async def test_reopen_leaves_a_trace(tmp_path):
    """打回要留痕——「你做完的東西被退回來了」是最該說出口的那一個轉折。"""
    app, client = await _client(tmp_path, "reopen_trace")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, rid, "agent-worker", "做事的人")
        oid = await _cycle(client, rid, human, worker)

        assert (await client.post(f"/api/board/objectives/{oid}/review",
                                  headers=worker)).status_code == 200
        assert (await client.post(f"/api/board/objectives/{oid}/reopen",
                                  headers=human)).status_code == 200

        assert "board_objective_reopened" in await _events(client, rid, human), (
            "週期被打回，房裡沒有任何痕跡——送審／確認／完成都有，就這個沒有"
        )
        got = {n["event_type"] for n in await _notices(client, "agent-worker")}
        assert "objective_reopened" in got, (
            f"做過事的人不知道自己的週期被打回了（收到：{got}）"
        )


async def test_cancel_leaves_a_trace(tmp_path):
    """取消與打回同一條路徑上的缺口，一起收。"""
    app, client = await _client(tmp_path, "cancel_trace")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, rid, "agent-worker", "做事的人")
        oid = await _cycle(client, rid, human, worker)

        assert (await client.post(f"/api/board/objectives/{oid}/cancel",
                                  headers=human)).status_code == 200

        assert "board_objective_cancelled" in await _events(client, rid, human), (
            "週期被取消，房裡沒有任何痕跡"
        )
        got = {n["event_type"] for n in await _notices(client, "agent-worker")}
        assert "objective_cancelled" in got, (
            f"做過事的人不知道週期被取消了（收到：{got}）"
        )


async def test_the_trace_reaches_every_active_attached_room(tmp_path):
    """留痕要發到**所有 active 掛接房**，而不是週期出生的那一間。

    A 房建週期、封存；B 房也掛著同一塊板。收尾之後：A 房不發（封存了，
    沒有人會再打開），B 房必須有——否則這個週期的收尾在所有還活著的房裡
    一點痕跡都沒有。
    """
    app, client = await _client(tmp_path, "trace_reach")
    async with app.router.lifespan_context(app), client:
        ra = await _room(client, "A房", "human-1")
        human_a = await _join(client, ra, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, ra, "agent-worker", "做事的人")
        oid = await _cycle(client, ra, human_a, worker)
        bid = (await client.get(f"/api/rooms/{ra}/board",
                                headers=human_a)).json()["board_id"]

        rb = await _room(client, "B房", "human-1")
        human_b = await _join(client, rb, "human-1", "艾斯維爾", role="human")
        assert (await client.post(f"/api/boards/{bid}/rooms/{rb}",
                                  headers=human_b)).status_code == 200

        assert (await client.post(f"/api/board/objectives/{oid}/review",
                                  headers=worker)).status_code == 200
        for step in ("verify", "complete"):
            r = await client.post(f"/api/board/objectives/{oid}/{step}",
                                  headers=human_a)
            assert r.status_code == 200, f"{step}: {r.text}"

        assert "board_objective_done" in await _events(client, rb, human_b), (
            "另一間掛接房完全看不到這個週期收尾了——留痕只發在週期出生的那一間"
        )

        # 封存的房不發：B 房封存後再打回，B 房不該多出新的週期留痕
        # （封存本身會留下一則 `archive`，那是它自己的事，不算在內）
        def _cycle_traces(events):
            return [e for e in events if e.startswith("board_objective_")]

        before = _cycle_traces(await _events(client, rb, human_b))
        assert (await client.post(f"/api/rooms/{rb}/archive",
                                  headers=human_b)).status_code == 200
        assert (await client.post(f"/api/board/objectives/{oid}/reopen",
                                  headers=human_a)).status_code == 200
        after = _cycle_traces(await _events(client, rb, human_b))
        assert after == before, "已封存的房收到了新的週期留痕"
        # ⚠️ 上面那條單獨看會**假通過**：打回整個沒發訊息時它也是綠的。
        # 還活著的 A 房必須確實收到，才證明擋掉的是「封存」而不是全部
        assert "board_objective_reopened" in await _events(client, ra, human_a), (
            "打回根本沒發任何留痕——上一條斷言驗到的是空的"
        )


async def test_the_supervisor_hears_about_it_without_touching_a_card(tmp_path):
    """supervisor 沒認領任何卡，但他是負責看的那個人——收尾要通知他。"""
    app, client = await _client(tmp_path, "sup_notice")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, "工作房", "human-1")
        human = await _join(client, rid, "human-1", "艾斯維爾", role="human")
        worker = await _join(client, rid, "agent-worker", "做事的人")
        await _join(client, rid, "agent-sup", "監督者")
        assert (await client.post(f"/api/rooms/{rid}/board/supervisor",
                                  json={"session_key": "agent-sup"},
                                  headers=human)).status_code == 200

        oid = await _cycle(client, rid, human, worker)
        assert (await client.post(f"/api/board/objectives/{oid}/review",
                                  headers=worker)).status_code == 200
        for step in ("verify", "complete"):
            r = await client.post(f"/api/board/objectives/{oid}/{step}",
                                  headers=human)
            assert r.status_code == 200, f"{step}: {r.text}"

        got = {n["event_type"] for n in await _notices(client, "agent-sup")}
        assert "objective_done" in got, (
            f"supervisor 一個收尾通知都沒有——他一張卡都沒認領，"
            f"所以落在「做過事的人」之外（收到：{got}）"
        )
