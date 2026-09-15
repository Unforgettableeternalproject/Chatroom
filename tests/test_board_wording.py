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


async def _second_room(client):
    """另一間聊天室，用來製造「這個身分不屬於這裡」。"""
    rid = (await client.post("/api/rooms", json={
        "name": "隔壁", "session_key": "owner-2"})).json()["id"]
    return rid


async def test_wrong_room_error_says_chatroom(tmp_path):
    """A 組：同一個東西不能一下叫「房間」一下叫「聊天室」。

    `app.py:1332` 曾經在**同一句**裡兩種都用：「你不是這個聊天室的成員（這個
    身分不屬於這個房間）」。這不是分散在不同檔案漂移出來的，是寫的當下就不
    一致，所以守門要雙向——只斷言「含聊天室」的話，混詞的句子照樣通過。
    """
    app, client = await _client(tmp_path, "wording-room")
    async with app.router.lifespan_context(app), client:
        _rid, hdr, _oid, _cid = await _setup(client)
        other = await _second_room(client)
        r = await client.get(f"/api/rooms/{other}/messages", headers=hdr)
        assert r.status_code == 403, r.text
        message = r.json()["detail"]["message"]
        assert "房間" not in message, message
        assert "聊天室" in message, message


async def test_card_ref_without_board_says_chatroom(tmp_path):
    """沒掛板時那則 422 也要說「聊天室」。"""
    app, client = await _client(tmp_path, "wording-noboard")
    async with app.router.lifespan_context(app), client:
        bare = (await client.post("/api/rooms", json={
            "name": "沒板的房", "session_key": "owner-3"})).json()["id"]
        j = await client.post(f"/api/rooms/{bare}/join", json={
            "kind": "human", "role": "human", "session_key": "human-3",
            "preferred_name": "艾斯維爾"})
        hdr = {"X-Participant-Id": j.json()["participant_id"]}
        r = await client.post(f"/api/rooms/{bare}/messages", headers=hdr,
                              json={"content": "指 #[不存在的卡]",
                                    "card_refs": ["whatever"]})
        assert r.status_code == 422, r.text
        message = r.json()["detail"]["message"]
        assert "房間" not in message, message
        assert "聊天室" in message, message


async def test_supervisor_notice_says_task_board(tmp_path):
    """B 組：supervisor 的通知說「任務板」，不說「板子」。

    工具說明那層本來就叫「任務板」，而 system 訊息叫「板子」——同一個東西
    在 agent 讀的說明與人讀的訊息裡名字不同。
    """
    app, client = await _client(tmp_path, "wording-board")
    async with app.router.lifespan_context(app), client:
        # 指定監督者限建立者，所以建房與加入要用同一把 session_key
        rid = (await client.post("/api/rooms", json={
            "name": "板子房", "session_key": "human-1"})).json()["id"]
        j = await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "human", "role": "human", "session_key": "human-1",
            "preferred_name": "艾斯維爾"})
        hdr = {"X-Participant-Id": j.json()["participant_id"],
               "X-Session-Key": "human-1"}
        await client.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": "agent-1",
            "preferred_name": "諾薇亞"})
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              headers=hdr, json={"session_key": "agent-1"})
        assert r.status_code == 200, r.text
        msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                 headers=hdr)).json()["messages"]
        notice = [m for m in msgs
                  if m["system_event"] == "board_supervisor_set"]
        assert len(notice) == 1, notice
        content = notice[0]["content"]
        assert "板子" not in content, content
        assert "任務板" in content, content
