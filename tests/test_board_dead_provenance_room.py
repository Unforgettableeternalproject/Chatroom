"""板物件的 provenance room（`room_id`）已被刪除時，其餘路徑也不能出錯。

`tests/test_board_seq_dead_room.py` 只守「領號」。同一類問題還有：把卡的
`room_id` 當成「有效、存在的房」去 post 系統訊息、驗 assignee、叫醒 long-poll、
找孤兒、排序、彙整摘要。卡屬於板，不屬於房；需要「一間房」時要用該板目前
active 的掛接房。

基底：房 A 建板與週期／階段／卡 → 房 B 掛同一塊板 → A 封存並真的刪除
（走 `DELETE /api/rooms/{id}`，即 `_purge_room`，FK 全程開著）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.events import RoomEvents

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 log_dir=str(tmp_path / "logs"), **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, key, name, role="agent"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _world(client, app, stage_file=False):
    """回傳 dict：A（已刪）、B（活著），以及板上的 id 與各身分的 header。"""
    w: dict = {}
    a = (await client.post("/api/rooms", json={
        "name": "舊房", "session_key": "human-boss"})).json()["id"]
    boss_a = await _join(client, a, "human-boss", "老闆", "human")
    w["a"] = a
    o1 = (await client.post(f"/api/rooms/{a}/board/objectives",
                            json={"title": "週期一"},
                            headers=boss_a)).json()["id"]
    o2 = (await client.post(f"/api/rooms/{a}/board/objectives",
                            json={"title": "週期二"},
                            headers=boss_a)).json()["id"]
    c1 = (await client.post(f"/api/board/objectives/{o1}/checklists",
                            json={"title": "階段一"},
                            headers=boss_a)).json()["id"]
    c2 = (await client.post(f"/api/board/objectives/{o1}/checklists",
                            json={"title": "階段二"},
                            headers=boss_a)).json()["id"]
    t1 = (await client.post(f"/api/board/checklists/{c1}/tasks",
                            json={"title": "卡一"},
                            headers=boss_a)).json()["id"]
    t2 = (await client.post(f"/api/board/checklists/{c1}/tasks",
                            json={"title": "卡二"},
                            headers=boss_a)).json()["id"]
    bid = (await client.get(f"/api/rooms/{a}/board",
                            headers=boss_a)).json()["board_id"]
    w.update(o1=o1, o2=o2, c1=c1, c2=c2, t1=t1, t2=t2, bid=bid)

    b = (await client.post("/api/rooms", json={
        "name": "新房", "session_key": "human-boss"})).json()["id"]
    w["b"] = b
    w["boss"] = await _join(client, b, "human-boss", "老闆", "human")
    w["human2"] = await _join(client, b, "human-two", "二號人類", "human")
    w["worker"] = await _join(client, b, "agent-worker", "Worker")
    w["buddy"] = await _join(client, b, "agent-buddy", "Buddy")
    w["pid"] = {k: w[k]["X-Participant-Id"]
                for k in ("boss", "human2", "worker", "buddy")}
    r = await client.post(f"/api/boards/{bid}/rooms/{b}",
                          params={"import_members": "true"}, headers=boss_a)
    assert r.status_code == 200, r.text

    if stage_file:
        up = await client.post(
            f"/api/rooms/{a}/attachments",
            files={"file": ("a.png", b"x", "image/png")},
            headers={"X-Participant-Id": boss_a["X-Participant-Id"]})
        assert up.status_code == 200, up.text
        r = await client.post(
            f"/api/boards/{bid}/checklists/{c1}/files",
            json={"attachment_id": up.json()["id"], "note": "n"},
            headers=boss_a)
        assert r.status_code == 200, r.text

    # 真的刪房：封存 → DELETE（`_purge_room`），FK 全程開著
    r = await client.post(f"/api/rooms/{a}/archive", headers=boss_a)
    assert r.status_code == 200, r.text
    r = await client.delete(f"/api/rooms/{a}", headers=boss_a)
    assert r.status_code == 200, r.text
    gone = await (await app.state.db.execute(
        "SELECT 1 FROM room WHERE id=?", (a,))).fetchone()
    assert gone is None
    # 前提：板物件的 provenance 確實指向已刪的房
    row = await (await app.state.db.execute(
        "SELECT room_id FROM board_checklist WHERE id=?", (c1,))).fetchone()
    assert row["room_id"] == a
    return w


async def _msgs(client, rid, hdr, event):
    body = (await client.get(f"/api/rooms/{rid}/messages",
                             headers=hdr)).json()["messages"]
    return [m for m in body if m["system_event"] == event]


@pytest.fixture
def notified(monkeypatch):
    calls: list[str] = []
    orig = RoomEvents.notify

    async def rec(self, room_id):
        calls.append(room_id)
        return await orig(self, room_id)

    monkeypatch.setattr(RoomEvents, "notify", rec)
    return calls


async def test_create_checklist_announces_and_wakes_the_live_room(
        tmp_path, notified):
    """人類在 B 房對「死房建的週期」開階段：B 房的 agent 要收到派工訊號、
    B 房的 long-poll 要被叫醒；新階段的 provenance 不再指向死房。"""
    app, client = await _client(tmp_path, "dp_checklist")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        notified.clear()
        r = await client.post(f"/api/board/objectives/{w['o1']}/checklists",
                              json={"title": "新階段"}, headers=w["boss"])
        assert r.status_code == 200, r.text
        assert w["b"] in notified, "B 房沒被叫醒"
        got = await _msgs(client, w["b"], w["boss"],
                          "board_checklist_created")
        assert got, "B 房的 agent 沒收到人類開新階段的派工訊號"
        row = await (await app.state.db.execute(
            "SELECT room_id FROM board_checklist WHERE id=?",
            (r.json()["id"],))).fetchone()
        assert row["room_id"] == w["b"]


async def test_create_and_patch_task_assignee_in_live_room(tmp_path, notified):
    """assignee 在 B 房、階段／卡的 provenance 是死房：不能被判成
    `assignee_not_in_room`；B 房要被叫醒。"""
    app, client = await _client(tmp_path, "dp_assignee")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        notified.clear()
        r = await client.post(
            f"/api/board/checklists/{w['c1']}/tasks",
            json={"title": "指給 Worker",
                  "assignee_participant_id": w["pid"]["worker"]},
            headers=w["boss"])
        assert r.status_code == 200, r.text
        assert w["b"] in notified
        row = await (await app.state.db.execute(
            "SELECT room_id, assignee_participant_id FROM board_task"
            " WHERE id=?", (r.json()["id"],))).fetchone()
        assert row["assignee_participant_id"] == w["pid"]["worker"]
        assert row["room_id"] == w["b"]

        r = await client.patch(
            f"/api/board/tasks/{w['t1']}",
            json={"assignee_participant_id": w["pid"]["buddy"]},
            headers=w["boss"])
        assert r.status_code == 200, r.text


async def test_direct_assign_wakes_the_live_room(
        tmp_path, notified):
    app, client = await _client(tmp_path, "dp_assign")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        notified.clear()
        r = await client.post(
            f"/api/board/tasks/{w['t1']}/assign",
            json={"target_participant_id": w["pid"]["worker"]},
            headers=w["boss"])
        assert r.status_code == 200, r.text
        assert r.json()["assigned"] is True
        assert w["b"] in notified, "直接指派沒叫醒 B 房"


async def test_assign_request_posts_in_live_room_and_resolve_wakes_it(
        tmp_path, notified):
    """非管理員的指派請求要把訊息發到 B（不是死房：message.room_id 有 FK，
    發過去是 500）；對方回應後要叫醒 B。"""
    app, client = await _client(tmp_path, "dp_assign_req")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        r = await client.post(
            f"/api/board/tasks/{w['t2']}/assign",
            json={"target_participant_id": w["pid"]["buddy"],
                  "note": "麻煩了"},
            headers=w["worker"])
        assert r.status_code == 200, r.text
        assert r.json()["assigned"] is False
        got = await _msgs(client, w["b"], w["boss"], "board_task_requested")
        assert len(got) == 1 and got[0]["mentions"] == ["Buddy"]

        notified.clear()
        r = await client.post(
            f"/api/board/task-requests/{r.json()['request']['id']}/resolve",
            json={"accept": True}, headers=w["buddy"])
        assert r.status_code == 200, r.text
        assert w["b"] in notified, "回應請求沒叫醒 B 房"


async def test_task_done_leaves_a_trace_in_the_live_room(tmp_path):
    """來源房已刪：完成留痕發到板現在的掛接房，不是整則消失。"""
    app, client = await _client(tmp_path, "dp_task_done")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        assert (await client.post(f"/api/board/tasks/{w['t1']}/claim",
                                  headers=w["worker"])).status_code == 200
        for st in ("in_progress", "done"):
            r = await client.post(f"/api/board/tasks/{w['t1']}/status",
                                  json={"status": st}, headers=w["worker"])
            assert r.status_code == 200, r.text
        got = await _msgs(client, w["b"], w["boss"], "board_task_done")
        assert len(got) == 1


async def test_notification_room_points_at_a_live_room(tmp_path):
    """通知的 room_id 不能是已刪的房（點進去只會 404）。"""
    app, client = await _client(tmp_path, "dp_notice")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        r = await client.post(f"/api/board/tasks/{w['t1']}/status",
                              json={"status": "in_progress"},
                              headers=w["human2"])
        assert r.status_code == 200, r.text
        rows = await (await app.state.db.execute(
            "SELECT room_id FROM notification WHERE recipient_key=?",
            ("human-boss",))).fetchall()
        assert rows, "建立者沒收到通知"
        assert {x["room_id"] for x in rows} == {w["b"]}


async def test_objective_lifecycle_after_the_origin_room_is_gone(tmp_path):
    """階段收尾 → 送審 → 確認 → 完成：不 500，留痕發到 B，通知指向 B。"""
    app, client = await _client(tmp_path, "dp_lifecycle")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        for t in (w["t1"], w["t2"]):
            assert (await client.post(f"/api/board/tasks/{t}/claim",
                                      headers=w["worker"])).status_code == 200
            r = await client.post(f"/api/board/tasks/{t}/status",
                                  json={"status": "done"},
                                  headers=w["worker"])
            assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/checklists/{w['c1']}/status",
                              json={"status": "done"}, headers=w["worker"])
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/checklists/{w['c2']}/status",
                              json={"status": "cancelled"},
                              headers=w["boss"])
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/objectives/{w['o1']}/review",
                              headers=w["worker"])
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/objectives/{w['o1']}/verify",
                              headers=w["boss"])
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/objectives/{w['o1']}/complete",
                              headers=w["boss"])
        assert r.status_code == 200, r.text
        assert await _msgs(client, w["b"], w["boss"], "board_objective_done")
        rows = await (await app.state.db.execute(
            "SELECT DISTINCT room_id FROM notification"
            " WHERE kind='objective_done'")).fetchall()
        assert rows and {x["room_id"] for x in rows} == {w["b"]}


async def test_move_checklist_and_stage_ops_after_the_origin_room_is_gone(
        tmp_path):
    app, client = await _client(tmp_path, "dp_move")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        r = await client.post(f"/api/board/checklists/{w['c2']}/move",
                              json={"objective_id": w["o2"]},
                              headers=w["boss"])
        assert r.status_code == 200, r.text
        r = await client.patch(f"/api/board/checklists/{w['c1']}",
                               json={"title": "改名"}, headers=w["boss"])
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/tasks/{w['t1']}/claim",
                              headers=w["worker"])
        assert r.status_code == 200, r.text
        r = await client.post(f"/api/board/tasks/{w['t1']}/release",
                              headers=w["worker"])
        assert r.status_code == 200, r.text
        r = await client.delete(f"/api/board/tasks/{w['t2']}",
                                headers=w["boss"])
        assert r.status_code == 200, r.text


async def test_leaving_the_live_room_orphans_a_claim_on_a_dead_room_card(
        tmp_path):
    """卡的 `t.room_id` 是死房：持有者離開 B 房，卡仍要被孤兒化。"""
    app, client = await _client(tmp_path, "dp_orphan")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        assert (await client.post(f"/api/board/tasks/{w['t2']}/claim",
                                  headers=w["worker"])).status_code == 200
        r = await client.post(f"/api/rooms/{w['b']}/leave",
                              headers=w["worker"])
        assert r.status_code == 200, r.text
        row = await (await app.state.db.execute(
            "SELECT claim_state FROM board_task WHERE id=?",
            (w["t2"],))).fetchone()
        assert row["claim_state"] == "orphaned"


async def test_v1_reorder_from_the_live_room_covers_dead_room_cards(tmp_path):
    """v1 排序的母體要跟 v1 讀取同一個範圍（板），不是 `room_id=B`。"""
    app, client = await _client(tmp_path, "dp_reorder")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        r = await client.post(
            f"/api/rooms/{w['b']}/board/reorder",
            json={"kind": "checklist",
                  "items": [{"id": w["c2"], "order_index": 0},
                            {"id": w["c1"], "order_index": 1}]},
            headers=w["boss"])
        assert r.status_code == 200, r.text


async def test_digest_sees_changes_to_dead_room_cards(tmp_path):
    """supervisor 在 B：死房建的卡有變動，摘要也要彙整到。"""
    app, client = await _client(tmp_path, "dp_digest",
                                board_digest_interval=0.0,
                                sweep_interval=3600)
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app)
        r = await client.post(f"/api/rooms/{w['b']}/board/supervisor",
                              json={"session_key": "agent-buddy"},
                              headers=w["boss"])
        assert r.status_code == 200, r.text
        r = await client.patch(f"/api/board/tasks/{w['t1']}",
                               json={"title": "改了"}, headers=w["boss"])
        assert r.status_code == 200, r.text
        await app.state.sweep_once()
        got = await _msgs(client, w["b"], w["boss"], "board_digest")
        assert got and "任務" in got[0]["content"]


async def test_purge_survives_a_stage_file_from_the_purged_room(tmp_path):
    """階段素材的附件屬於被刪的房：刪房不能因此失敗，板讀取也不能 500。"""
    app, client = await _client(tmp_path, "dp_stage_file")
    async with client, app.router.lifespan_context(app):
        w = await _world(client, app, stage_file=True)
        r = await client.get(f"/api/boards/{w['bid']}", headers=w["boss"])
        assert r.status_code == 200, r.text
