"""使用者面向的字串裡，Checklist 那層一律叫「階段」（09/14 決策裁定）。

英文識別字本來就是 `checklist`，所以「清單」不是誰翻錯，是照著識別字直譯
出來的；「階段」則是在 UI 語境下長出來的說法。兩個都有來源，這也是它活這
麼久沒被發現的原因——而 Hub 這一端同時存在四種叫法（階段／清單／階段清單／
階段分組），連「同一份東西建立時叫階段、刪除摘要叫清單」都出現過。

⚠️ 這裡守的是**人看的字串**。識別字（`tasks_incomplete`、`container_settled`
等 code、`board_checklist_created` 等事件名、表名與欄位）一律不動——那是契
約層，bridge 與既有測試都咬著它。
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


async def _setup(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "owner"})).json()["id"]
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "human-1",
        "preferred_name": "艾斯維爾"})
    hdr = {"X-Participant-Id": r.json()["participant_id"]}
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "週期一"}, headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "階段一"}, headers=hdr)).json()["id"]
    return rid, hdr, oid, cid


async def test_incomplete_checklist_error_says_stage(tmp_path):
    """底下還有沒做完的卡時，那則 409 要說「階段」。"""
    app, client = await _client(tmp_path, "wording-cl")
    async with app.router.lifespan_context(app), client:
        _rid, hdr, _oid, cid = await _setup(client)
        await client.post(f"/api/board/checklists/{cid}/tasks",
                          json={"title": "還沒做"}, headers=hdr)
        r = await client.post(f"/api/board/checklists/{cid}/status",
                              json={"status": "done"}, headers=hdr)
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "tasks_incomplete", detail
        assert "清單" not in detail["message"], detail["message"]
        assert "階段" in detail["message"], detail["message"]


async def test_incomplete_objective_error_says_stage(tmp_path):
    """週期送審被擋時，提到底下那層也要說「階段」。"""
    app, client = await _client(tmp_path, "wording-obj")
    async with app.router.lifespan_context(app), client:
        _rid, hdr, oid, cid = await _setup(client)
        await client.post(f"/api/board/checklists/{cid}/tasks",
                          json={"title": "還沒做"}, headers=hdr)
        r = await client.post(f"/api/board/objectives/{oid}/review",
                              headers=hdr)
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "checklists_incomplete", detail
        assert "清單" not in detail["message"], detail["message"]
        assert "階段" in detail["message"], detail["message"]


async def test_wrong_kind_hint_says_stage(tmp_path):
    """拿階段的 id 去打任務端點時，型別提示要說「階段」不是「階段清單」。"""
    app, client = await _client(tmp_path, "wording-kind")
    async with app.router.lifespan_context(app), client:
        _rid, hdr, _oid, cid = await _setup(client)
        r = await client.post(f"/api/board/tasks/{cid}/status",
                              json={"status": "done"}, headers=hdr)
        assert r.status_code == 422, r.text
        message = r.json()["detail"]["message"]
        assert "階段清單" not in message, message
        assert "階段" in message, message


async def test_settled_stage_refusal_says_stage(tmp_path):
    """收尾的階段拒收新卡時說的也是「階段」（這條本來就對，釘住它）。"""
    app, client = await _client(tmp_path, "wording-settled")
    async with app.router.lifespan_context(app), client:
        _rid, hdr, _oid, cid = await _setup(client)
        tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                                 json={"title": "先做一件"},
                                 headers=hdr)).json()["id"]
        for target in ("in_progress", "done"):
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": target}, headers=hdr)
        await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=hdr)
        r = await client.post(f"/api/board/checklists/{cid}/tasks",
                              json={"title": "偷渡一張"}, headers=hdr)
        assert r.status_code == 409, r.text
        message = r.json()["detail"]["message"]
        assert "清單" not in message, message
        assert "階段" in message, message
