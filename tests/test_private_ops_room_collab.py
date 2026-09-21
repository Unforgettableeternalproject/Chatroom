"""合併前驗一條容易被忽略的路：私人工作房裡，房主邀請第二個人類與一個
agent 一起用板、派工、進 run，而沒被邀請的人進不來、被邀請的人動不了工作區。

這份檔案不是新規則的測試，是把既有規則串成一條真實會發生的鏈路：

1. 房主建私人工作房，綁工作區（含私人工作區的版本）。
2. 房主邀請第二個人類、邀請一個 agent，兩者都靠 `POST /rooms/{id}/assignments`
   建立的指派進房（`_invited_to_private` 的第四種算數）。
3. 被邀請的人類在板上建卡、認領、改狀態、派工。
4. 被邀請的 agent 讀板、建卡、認領；被設成 Supervisor 後自派工，非 Supervisor
   時 403。
5. 執行器 claim 到 run，`claude-run-<id>` 進這個私人房（09/21 修的豁免）。
6. 反向：沒被邀請的人進不來；被邀請者（非房主）動不了工作區。
7. 公開工作房對照：同樣流程不需要邀請就能進。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
OWNER = "human-owner"
GUEST = "human-guest"
OUTSIDER_HUMAN = "human-outsider"
AGENT = "claude-agent"
OUTSIDER_AGENT = "claude-outsider"
PROJECT = "ai-website"
PRIVATE_PROJECT = "secret-repo"


async def _client(tmp_path, name, **cfg_kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **cfg_kw)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})
    client.hub_app = app
    return app, client


async def _room(client, kind="ops", key=OWNER, name="工作房",
                visibility="public"):
    r = await client.post("/api/rooms",
                          json={"name": name, "kind": kind,
                                "session_key": key,
                                "visibility": visibility})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _join(client, rid, key, name, kind="human", role="human",
               expect=200):
    r = await client.post(f"/api/rooms/{rid}/join",
                          json={"kind": kind, "role": role,
                                "session_key": key, "preferred_name": name})
    assert r.status_code == expect, r.text
    if expect != 200:
        return r
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


class _Runner(str):
    token: str

    @property
    def headers(self) -> dict:
        return {"X-Runner-Token": self.token}


async def _register_runner(client, projects=(PROJECT,), label="ex1",
                           private_projects=None):
    body = {"host": "esvel-pc", "label": label, "projects": list(projects),
            "max_parallel": 3, "version": "0.1"}
    if private_projects is not None:
        body["private_projects"] = list(private_projects)
    r = await client.post("/api/runners/register", json=body)
    assert r.status_code == 200, r.text
    runner = _Runner(r.json()["runner"]["id"])
    runner.token = r.json()["runner_token"]
    return runner


async def _bind(client, rid, key, owner_hdr):
    return await client.post(f"/api/rooms/{rid}/workspace",
                             json={"workspace_key": key},
                             headers=owner_hdr)


async def _invite(client, rid, target_session_key, assigned_name=""):
    r = await client.post(f"/api/rooms/{rid}/assignments",
                          json={"target_session_key": target_session_key,
                                "assigned_name": assigned_name})
    assert r.status_code == 200, r.text
    return r.json()


async def _board_id(client, rid, hdr):
    r = await client.get(f"/api/rooms/{rid}/board", headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["board_id"]


# ---------------------------------------------------------------------------
# 主流程：私人工作房，房主邀請第二人類與一個 agent
# ---------------------------------------------------------------------------

async def test_private_ops_room_full_collaboration_flow(tmp_path):
    app, client = await _client(tmp_path, "private-collab")
    async with app.router.lifespan_context(app), client:
        # ---- 1. 房主建私人工作房，邀請進來之前先綁工作區 ----
        rid = await _room(client, visibility="private")
        owner = await _join(client, rid, OWNER, "艾斯維爾")

        runner = await _register_runner(client)
        r = await _bind(client, rid, PROJECT, owner)
        assert r.status_code == 200, r.text
        assert r.json()["room"]["workspace_key"] == PROJECT
        assert r.json()["room"]["workspace_served"] is True

        # ---- 2a. 邀請第二個人類，加入成功 ----
        inv = await _invite(client, rid, GUEST, assigned_name="Guest")
        assert inv["target_known"] is False
        guest = await _join(client, rid, GUEST, "Guest")

        # ---- 2b. 邀請一個 agent，加入成功 ----
        await _invite(client, rid, AGENT, assigned_name="Nova")
        agent = await _join(client, rid, AGENT, "Nova", kind="claude",
                            role="agent")

        # ---- 3. 被邀請的人類：建卡、認領、改狀態、派工 ----
        r = await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "客人建的卡"}, headers=guest)
        assert r.status_code == 200, r.text
        task_id = r.json()["id"]

        r = await client.post(f"/api/board/tasks/{task_id}/claim",
                              headers=guest)
        assert r.status_code == 200, r.text
        assert r.json()["reclaimed"] is False

        r = await client.post(f"/api/board/tasks/{task_id}/status",
                              json={"status": "in_progress"}, headers=guest)
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "in_progress"

        r = await client.post(f"/api/rooms/{rid}/attachments",
                              files={"file": ("note.txt", b"hi",
                                             "text/plain")},
                              headers=guest)
        assert r.status_code == 200, r.text
        assert r.json()["size"] == 2

        r = await client.post(f"/api/rooms/{rid}/runs",
                              json={"kind": "investigate", "project": PROJECT,
                                    "ref": task_id, "brief": "客人派的工"},
                              headers=guest)
        assert r.status_code == 200, r.text
        run_id = r.json()["run"]["id"]
        assert r.json()["run"]["status"] == "queued"

        # ---- 4. 被邀請的 agent：讀板、建卡、認領、更新 ----
        r = await client.get(f"/api/rooms/{rid}/board", headers=agent)
        assert r.status_code == 200, r.text
        board_id = r.json()["board_id"]
        assert board_id is not None

        r = await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "agent 建的卡"}, headers=agent)
        assert r.status_code == 200, r.text
        agent_task_id = r.json()["id"]

        r = await client.post(f"/api/board/tasks/{agent_task_id}/claim",
                              headers=agent)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/tasks/{agent_task_id}/status",
                              json={"status": "in_progress"}, headers=agent)
        assert r.status_code == 200, r.text

        # 非 Supervisor 時派工 403
        r = await client.post(f"/api/rooms/{rid}/runs",
                              json={"kind": "investigate", "project": PROJECT,
                                    "ref": agent_task_id, "brief": "agent 想派工",
                                    "board_id": board_id},
                              headers=agent)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_actor_required_for_run"

        # 房主設 agent 為這間房的 Supervisor
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": AGENT}, headers=owner)
        assert r.status_code == 200, r.text
        assert r.json()["in_room"] is True

        # 現在 Supervisor 自派工成功
        r = await client.post(f"/api/rooms/{rid}/runs",
                              json={"kind": "investigate", "project": PROJECT,
                                    "ref": agent_task_id,
                                    "brief": "supervisor 派工",
                                    "board_id": board_id},
                              headers=agent)
        assert r.status_code == 200, r.text
        sup_run_id = r.json()["run"]["id"]
        assert r.json()["run"]["status"] == "queued"

        # ---- 5. 執行器 claim 到 run，claude-run-<id> 進這個私人房 ----
        r = await client.post(f"/api/runners/{runner}/claim",
                              headers=runner.headers)
        assert r.status_code == 200, r.text
        claimed_id = r.json()["run"]["id"]
        assert claimed_id in (run_id, sup_run_id)

        r = await client.post(f"/api/runs/{claimed_id}/report",
                              json={"status": "running", "runner_id": runner},
                              headers=runner.headers)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/rooms/{rid}/join",
                              json={"kind": "claude", "role": "agent",
                                    "session_key": f"claude-run-{claimed_id}",
                                    "preferred_name": "Runner"})
        assert r.status_code == 200, r.text
        assert r.json()["room"]["id"] == rid
        run_participant_id = r.json()["participant_id"]
        prow = await (await app.state.db.execute(
            "SELECT run_id FROM participant WHERE id=?",
            (run_participant_id,))).fetchone()
        assert prow["run_id"] == claimed_id

        # ---- 6a. 反向：沒被邀請的人類、agent 進不來 ----
        r = await _join(client, rid, OUTSIDER_HUMAN, "路人",
                        kind="human", role="human", expect=403)
        assert r.json()["detail"]["code"] == "room_is_private"

        r = await _join(client, rid, OUTSIDER_AGENT, "路過的agent",
                        kind="claude", role="agent", expect=403)
        assert r.json()["detail"]["code"] == "room_is_private"

        # ---- 6b. 被邀請者（非房主）動不了工作區 ----
        r = await client.post(f"/api/rooms/{rid}/workspace",
                              json={"workspace_key": PROJECT}, headers=guest)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "room_owner_required"

        # 房主自己重綁也擋（已經綁過）
        r = await client.post(f"/api/rooms/{rid}/workspace",
                              json={"workspace_key": PROJECT}, headers=owner)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "workspace_already_bound"
        assert r.json()["detail"]["workspace_key"] == PROJECT

        # ---- 6c. 被踢的人 join 403 ----
        r = await client.post(
            f"/api/rooms/{rid}/participants/{guest['X-Participant-Id']}/kick",
            headers=owner)
        assert r.status_code == 200, r.text

        r = await _join(client, rid, GUEST, "Guest", expect=403)
        assert r.json()["detail"]["code"] == "kicked"


async def test_private_workspace_key_binds_only_to_private_room(tmp_path):
    """私人工作區只能綁到私人房——`workspace_private_room_required` 這條路。"""
    app, client = await _client(tmp_path, "private-workspace")
    async with app.router.lifespan_context(app), client:
        rid_private = await _room(client, key=OWNER, visibility="private")
        owner_private = await _join(client, rid_private, OWNER, "艾斯維爾")

        rid_public = await _room(client, key=OWNER, visibility="public",
                                 name="公開工作房")
        owner_public = await _join(client, rid_public, OWNER, "艾斯維爾2")

        await _register_runner(client, projects=(),
                               private_projects=(PRIVATE_PROJECT,))

        # 公開房綁私人工作區 ⇒ 409 workspace_private_room_required
        r = await _bind(client, rid_public, PRIVATE_PROJECT, owner_public)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "workspace_private_room_required"

        # 私人房綁得上
        r = await _bind(client, rid_private, PRIVATE_PROJECT, owner_private)
        assert r.status_code == 200, r.text
        assert r.json()["room"]["workspace_key"] == PRIVATE_PROJECT


async def test_public_ops_room_needs_no_invitation(tmp_path):
    """公開工作房對照：同樣流程不需要邀請就能進。"""
    app, client = await _client(tmp_path, "public-collab")
    async with app.router.lifespan_context(app), client:
        rid = await _room(client, visibility="public")
        owner = await _join(client, rid, OWNER, "艾斯維爾")
        await _register_runner(client)
        r = await _bind(client, rid, PROJECT, owner)
        assert r.status_code == 200, r.text

        # 沒有邀請，直接 join 成功
        guest = await _join(client, rid, GUEST, "路過的人類")
        agent = await _join(client, rid, AGENT, "路過的agent",
                            kind="claude", role="agent")

        r = await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": "公開房的卡"}, headers=guest)
        assert r.status_code == 200, r.text
        task_id = r.json()["id"]

        r = await client.post(f"/api/board/tasks/{task_id}/claim",
                              headers=agent)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/rooms/{rid}/runs",
                              json={"kind": "investigate", "project": PROJECT,
                                    "ref": task_id, "brief": "公開房派工"},
                              headers=guest)
        assert r.status_code == 200, r.text
