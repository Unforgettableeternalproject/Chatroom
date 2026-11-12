"""有效認領者可以改自己認領的那張卡的內容（v1.2.8-hotfix1）。

實測：認領者改不了自己那張卡的描述，拿到 `not_board_editor`，只能請監督
代寫。規則：目前有效認領（`claim_state='held'` 且認領身分對得上）該卡的人，
可以改它的 title／description／priority 與 depends_on；階段、週期的編輯
權限不變，改 affects（等於改別人的卡）仍須有權改對方的卡，認領失效即失去。
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
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _setup(client):
    """人類建週期與階段；maker 建兩張卡，claimer 認領第一張。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": "human-a"})).json()["id"]
    owner = await _join(client, rid, "human-a", "艾斯維爾", role="human")
    maker = await _join(client, rid, "agent-b", "諾薇亞")
    claimer = await _join(client, rid, "agent-c", "米勒")
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期"},
                             headers=owner)).json()["id"]
    stage = (await client.post(f"/api/board/objectives/{oid}/checklists",
                               json={"title": "階段"},
                               headers=owner)).json()["id"]
    card = (await client.post(f"/api/board/checklists/{stage}/tasks",
                              json={"title": "卡"},
                              headers=maker)).json()["id"]
    other = (await client.post(f"/api/board/checklists/{stage}/tasks",
                               json={"title": "別人的卡"},
                               headers=maker)).json()["id"]
    r = await client.post(f"/api/board/tasks/{card}/claim", headers=claimer)
    assert r.status_code == 200, r.text
    return rid, owner, maker, claimer, stage, card, other


async def _desc(client, card, hdr, text="認領者補的敘述"):
    return await client.patch(f"/api/board/tasks/{card}",
                              json={"description": text}, headers=hdr)


async def test_claimant_can_edit_own_claimed_card(tmp_path):
    """🔴 原失敗情境：認領者改自己卡的描述 ⇒ 403 not_board_editor。"""
    app, client = await _client(tmp_path, "claimant")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, _, card, _ = await _setup(client)
        r = await _desc(client, card, claimer)
        assert r.status_code == 200, r.text
        r = await client.patch(f"/api/board/tasks/{card}",
                               json={"title": "新標題", "priority": "high"},
                               headers=claimer)
        assert r.status_code == 200, r.text


async def test_claimant_can_edit_depends_on_of_own_card(tmp_path):
    app, client = await _client(tmp_path, "claimant-deps")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, _, card, other = await _setup(client)
        r = await client.patch(f"/api/board/tasks/{card}",
                               json={"depends_on": [other]}, headers=claimer)
        assert r.status_code == 200, r.text


async def test_non_claimant_is_still_refused(tmp_path):
    app, client = await _client(tmp_path, "non-claimant")
    async with app.router.lifespan_context(app), client:
        rid, _, _, _, _, card, _ = await _setup(client)
        stranger = await _join(client, rid, "stranger", "路人")
        r = await _desc(client, card, stranger)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_released_claim_loses_the_right(tmp_path):
    app, client = await _client(tmp_path, "released")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, _, card, _ = await _setup(client)
        assert (await _desc(client, card, claimer)).status_code == 200
        r = await client.post(f"/api/board/tasks/{card}/release",
                              headers=claimer)
        assert r.status_code == 200, r.text
        r = await _desc(client, card, claimer, "釋放後")
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_orphaned_claim_loses_the_right(tmp_path):
    app, client = await _client(tmp_path, "orphaned")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, _, card, _ = await _setup(client)
        db = app.state.db
        await db.execute("UPDATE board_task SET claim_state='orphaned'"
                         " WHERE id=?", (card,))
        await db.commit()
        r = await _desc(client, card, claimer)
        assert r.status_code == 403, r.text


async def test_claimant_cannot_edit_the_stage(tmp_path):
    """範圍只到卡：認領者不能改所屬階段。"""
    app, client = await _client(tmp_path, "stage")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, stage, _, _ = await _setup(client)
        r = await client.patch(f"/api/board/checklists/{stage}",
                               json={"title": "認領者改階段"}, headers=claimer)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_claimant_cannot_edit_affects_onto_others_card(tmp_path):
    """改 affects ＝改別人卡的依賴，仍須有權改對方的卡。"""
    app, client = await _client(tmp_path, "affects")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, _, card, other = await _setup(client)
        r = await client.patch(f"/api/board/tasks/{card}",
                               json={"affects": [other]}, headers=claimer)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_board_editor"


async def test_claimant_cannot_reorder_or_reassign(tmp_path):
    """放寬只給內容欄位；排序等其餘欄位仍走原本三軸。"""
    app, client = await _client(tmp_path, "order")
    async with app.router.lifespan_context(app), client:
        _, _, _, claimer, _, card, _ = await _setup(client)
        r = await client.patch(f"/api/board/tasks/{card}",
                               json={"order_index": 5}, headers=claimer)
        assert r.status_code == 403, r.text
