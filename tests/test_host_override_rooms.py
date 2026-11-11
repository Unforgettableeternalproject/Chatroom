"""主持人 override 所有管理操作（艾斯維爾 2026-11-11）：房間層。

推翻 2026-09-23 的「主持人不豁免房間設定」：主持人（X-Host-View 加人類／主
憑證）可以直接封存、解封、改名與所有房間設定、踢人、刪訊息、處理封存請求、
撤回邀請、掛接板、工作區綁定。**不開放**的只有編輯他人訊息與以他人身分發言。

每一類都有對照組：沒帶主持人標頭的路人照舊被擋——放寬的是主持人，不是所有人。
操作可帶 `reason`（body；DELETE 用 query），寫進 system 訊息與通知。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HOST = {"X-Host-View": "1", "X-Session-Key": "host-device"}
OWNER = "owner-key"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, key, name, role="human"):
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human" if role == "human" else "claude", "role": role,
        "session_key": key, "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": key}


async def _room(client, kind="chat"):
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": OWNER, "kind": kind})).json()["id"]
    owner = await _join(client, rid, OWNER, "房主")
    return rid, owner


async def _msgs(client, rid, hdr, event):
    out = (await client.get(f"/api/rooms/{rid}/messages",
                            headers=hdr)).json()["messages"]
    return [m for m in out if m["system_event"] == event]


async def _inbox(client, key, **params):
    r = await client.get("/api/notifications", params=params,
                         headers={"X-Session-Key": key})
    assert r.status_code == 200, r.text
    return r.json()


# ── 封存／解封 ────────────────────────────────────────────────────────

async def test_host_archives_directly_and_records_who_and_why(tmp_path):
    app, client = await _client(tmp_path, "arch")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        # 對照組：路人（非成員）沒有主持人標頭，封存不了
        r = await client.post(f"/api/rooms/{rid}/archive",
                              headers={"X-Session-Key": "stranger"})
        assert r.status_code in (401, 403), r.text

        r = await client.post(f"/api/rooms/{rid}/archive", headers=HOST,
                              json={"reason": "內容違規"})
        assert r.status_code == 200, r.text
        # 直接封存（走 `_archive`），不是變成提案
        assert r.json()["archived"] is True and r.json()["by_host"] is True

        row = await (await app.state.db.execute(
            "SELECT status, archived_by_host, archive_reason FROM room"
            " WHERE id=?", (rid,))).fetchone()
        assert row["status"] == "archived"
        assert row["archived_by_host"] == 1
        assert row["archive_reason"] == "內容違規"
        # 理由寫進 system 訊息
        sysmsg = await _msgs(client, rid, owner, "archive")
        assert "內容違規" in sysmsg[-1]["content"]
        assert "主持人" in sysmsg[-1]["content"]
        # 房主收到 host_room_archived，附理由與來源
        n = (await _inbox(client, OWNER))["notifications"]
        mine = [x for x in n if x["kind"] == "host_room_archived"]
        assert len(mine) == 1
        assert mine[0]["reason"] == "內容違規"
        assert mine[0]["actor_kind"] == "host"
        assert mine[0]["room_id"] == rid and mine[0]["room_name"] == "房"
        assert "主持人" in mine[0]["summary"] and "封存" in mine[0]["summary"]


async def test_creator_may_unarchive_a_host_archived_room_and_host_is_told(tmp_path):
    app, client = await _client(tmp_path, "unarch")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/archive", headers=HOST,
                          json={"reason": "先停一下"})

        r = await client.post(f"/api/rooms/{rid}/unarchive", headers=owner,
                              json={"reason": "已經處理好了"})
        assert r.status_code == 200, r.text
        row = await (await app.state.db.execute(
            "SELECT status, archived_by_host, archive_reason FROM room"
            " WHERE id=?", (rid,))).fetchone()
        assert row["status"] == "active"
        assert row["archived_by_host"] == 0 and row["archive_reason"] == ""

        # 寄全域主持人收件匣：任何持人類憑證的連線都讀得到，附建立者的理由
        inbox = await _inbox(client, "host-device")
        hit = [x for x in inbox["notifications"]
               if x["kind"] == "room_unarchived_by_creator"]
        assert len(hit) == 1
        assert hit[0]["for_host"] is True
        assert hit[0]["reason"] == "已經處理好了"
        assert hit[0]["room_id"] == rid
        assert hit[0]["actor_name"] == "房主"
        # 一般人封的房被解封：不寄主持人收件匣（對照組）
        await client.post(f"/api/rooms/{rid}/archive", headers=owner)
        before = len((await _inbox(client, "host-device"))["notifications"])
        await client.post(f"/api/rooms/{rid}/unarchive", headers=owner)
        after = len((await _inbox(client, "host-device"))["notifications"])
        assert after == before


async def test_host_unarchive_notifies_the_creator(tmp_path):
    app, client = await _client(tmp_path, "unarch-host")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/archive", headers=owner)
        r = await client.post(f"/api/rooms/{rid}/unarchive", headers=HOST,
                              json={"reason": "誤封"})
        assert r.status_code == 200, r.text
        assert "誤封" in (await _msgs(client, rid, owner, "unarchive"))[-1][
            "content"]
        kinds = [x["kind"] for x in (await _inbox(client, OWNER))[
            "notifications"]]
        assert "host_room_unarchived" in kinds


# ── 房間設定 ──────────────────────────────────────────────────────────

async def test_host_changes_every_room_setting_with_reason(tmp_path):
    app, client = await _client(tmp_path, "settings")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        calls = [
            ("patch", f"/api/rooms/{rid}", {"name": "新名字"}, "rename"),
            ("post", f"/api/rooms/{rid}/topic", {"topic": "新主題"}, "topic"),
            ("post", f"/api/rooms/{rid}/visibility",
             {"visibility": "private"}, "visibility"),
            ("post", f"/api/rooms/{rid}/auto-archive", {"enabled": False},
             "auto_archive"),
            ("post", f"/api/rooms/{rid}/style", {"style": "concise"},
             "style"),
        ]
        for method, url, body, event in calls:
            # 對照組：路人 403
            r = await getattr(client, method)(
                url, json=body, headers={"X-Session-Key": "stranger"})
            assert r.status_code == 403, (url, r.text)
            r = await getattr(client, method)(
                url, json={**body, "reason": f"理由-{event}"}, headers=HOST)
            assert r.status_code == 200, (url, r.text)
            sysmsg = await _msgs(client, rid, owner, event)
            assert f"理由-{event}" in sysmsg[-1]["content"], event
        notes = [x for x in (await _inbox(client, OWNER))["notifications"]
                 if x["kind"].startswith("host_room_")]
        assert {x["kind"] for x in notes} == {"host_room_renamed",
                                              "host_room_settings"}
        # 理由與署名跟著通知
        assert all(x["actor_kind"] == "host" for x in notes)
        assert all(x["reason"].startswith("理由-") for x in notes)


async def test_reason_longer_than_500_is_rejected_in_models(tmp_path):
    app, client = await _client(tmp_path, "toolong")
    async with app.router.lifespan_context(app), client:
        rid, _ = await _room(client)
        r = await client.patch(f"/api/rooms/{rid}", headers=HOST,
                               json={"name": "x", "reason": "字" * 501})
        assert r.status_code == 422, r.text
        # 另一半：剛好 500 字要收（這一半在舊版會紅，因為舊的 forbid 模型
        # 不認識 reason 欄位）
        r = await client.patch(f"/api/rooms/{rid}", headers=HOST,
                               json={"name": "x", "reason": "字" * 500})
        assert r.status_code == 200, r.text


# ── 踢人／刪訊息／封存請求／邀請 ──────────────────────────────────────

async def test_host_kicks_with_reason_and_target_is_told(tmp_path):
    app, client = await _client(tmp_path, "kick")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        other = await _join(client, rid, "member-key", "路人甲")
        pid = other["X-Participant-Id"]
        # 對照組：沒有主持人標頭的非房主踢不了
        r = await client.post(f"/api/rooms/{rid}/participants/{pid}/kick",
                              headers=other)
        assert r.status_code == 403
        r = await client.post(f"/api/rooms/{rid}/participants/{pid}/kick",
                              headers=HOST, json={"reason": "洗版"})
        assert r.status_code == 200, r.text
        assert "洗版" in (await _msgs(client, rid, owner, "kick"))[-1][
            "content"]
        hit = [x for x in (await _inbox(client, "member-key"))[
            "notifications"] if x["kind"] == "host_kicked"]
        assert len(hit) == 1 and hit[0]["reason"] == "洗版"
        assert hit[0]["room_id"] == rid


async def test_host_deletes_someone_elses_message_but_cannot_edit_it(tmp_path):
    app, client = await _client(tmp_path, "msg")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        other = await _join(client, rid, "member-key", "路人甲")
        mid = (await client.post(f"/api/rooms/{rid}/messages",
                                 json={"content": "原文"},
                                 headers=other)).json()["id"]
        # 編輯他人訊息：主持人也不行（明確不開放）
        r = await client.patch(f"/api/messages/{mid}",
                               json={"content": "被改了"}, headers=HOST)
        assert r.status_code in (401, 403), r.text
        # 發言：主持人視角不給「代言」——沒有自己的成員身分就不能說話
        r = await client.post(f"/api/rooms/{rid}/messages",
                              json={"content": "我是主持人"}, headers=HOST)
        assert r.status_code in (401, 403), r.text
        # 主持人就算也是房內成員、又開著主持人模式，編輯別人的訊息依舊 403
        me = await _join(client, rid, "host-device", "主持人本人")
        r = await client.patch(f"/api/messages/{mid}",
                               json={"content": "被改了"},
                               headers={**HOST, **me})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_message_author"
        shown = (await client.get(f"/api/rooms/{rid}/messages",
                                  headers=owner)).json()["messages"]
        assert [m for m in shown if m["id"] == mid][0]["content"] == "原文"

        # 對照組：路人刪不了
        r = await client.delete(f"/api/messages/{mid}",
                                headers={"X-Session-Key": "stranger"})
        assert r.status_code in (401, 403)
        r = await client.delete(f"/api/messages/{mid}", headers=HOST,
                                params={"reason": "違規內容"})
        assert r.status_code == 200, r.text
        hit = [x for x in (await _inbox(client, "member-key"))[
            "notifications"] if x["kind"] == "host_message_deleted"]
        assert len(hit) == 1 and hit[0]["reason"] == "違規內容"


async def test_host_handles_archive_requests(tmp_path):
    app, client = await _client(tmp_path, "arch-req")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        other = await _join(client, rid, "member-key", "路人甲")
        req = (await client.post(f"/api/rooms/{rid}/archive", headers=other,
                                 json={"reason": "做完了"})).json()["request"]
        # 對照組：成員不能處理
        r = await client.post(f"/api/archive-requests/{req['id']}/resolve",
                              json={"approve": False}, headers=other)
        assert r.status_code == 403
        # 主持人婉拒
        r = await client.post(f"/api/archive-requests/{req['id']}/resolve",
                              json={"approve": False, "reason": "還要用"},
                              headers=HOST)
        assert r.status_code == 200, r.text
        # 再提一次，主持人取消（不是提案者本人）
        req2 = (await client.post(f"/api/rooms/{rid}/archive",
                                  headers=other)).json()["request"]
        r = await client.delete(f"/api/archive-requests/{req2['id']}",
                                headers=HOST)
        assert r.status_code == 200, r.text
        # 再提一次，主持人核准 → 直接封存且記為主持人封存
        req3 = (await client.post(f"/api/rooms/{rid}/archive",
                                  headers=other)).json()["request"]
        r = await client.post(f"/api/archive-requests/{req3['id']}/resolve",
                              json={"approve": True, "reason": "同意"},
                              headers=HOST)
        assert r.status_code == 200, r.text
        row = await (await app.state.db.execute(
            "SELECT status, archived_by_host FROM room WHERE id=?",
            (rid,))).fetchone()
        assert row["status"] == "archived" and row["archived_by_host"] == 1


async def test_host_revokes_an_invitation(tmp_path):
    app, client = await _client(tmp_path, "invite")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        aid = (await client.post(f"/api/rooms/{rid}/assignments", json={
            "target_session_key": "agent-x"}, headers=owner)).json()["id"]
        # 對照組：路人撤不了
        r = await client.delete(f"/api/assignments/{aid}",
                                headers={"X-Session-Key": "stranger"})
        assert r.status_code in (401, 403), r.text
        r = await client.delete(f"/api/assignments/{aid}", headers=HOST)
        assert r.status_code == 200, r.text


# ── 刪房／掛板／工作區 ────────────────────────────────────────────────

async def test_host_deletes_an_archived_room_and_the_notice_outlives_it(tmp_path):
    app, client = await _client(tmp_path, "delroom")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        # 刪房仍須先封存，主持人也一樣
        r = await client.delete(f"/api/rooms/{rid}", headers=HOST)
        assert r.status_code == 409
        await client.post(f"/api/rooms/{rid}/archive", headers=owner)
        r = await client.delete(f"/api/rooms/{rid}", headers=HOST,
                                params={"reason": "清理"})
        assert r.status_code == 200, r.text
        hit = [x for x in (await _inbox(client, OWNER))["notifications"]
               if x["kind"] == "host_room_deleted"]
        assert len(hit) == 1
        assert hit[0]["reason"] == "清理"
        # 房已經不在，名稱用快照
        assert hit[0]["room_name"] == "房"


async def test_host_creates_and_attaches_boards(tmp_path):
    app, client = await _client(tmp_path, "boards")
    async with app.router.lifespan_context(app), client:
        rid, _ = await _room(client)
        bid = (await client.post("/api/boards", json={
            "name": "板", "origin_room_id": rid}, headers=HOST)).json()
        assert bid.get("id"), bid
        rid2, _ = await _room(client)
        r = await client.post(f"/api/boards/{bid['id']}/rooms/{rid2}",
                              headers=HOST)
        assert r.status_code == 200, r.text
        # 對照組：沒帶標頭的人建板掛別人的房
        r = await client.post("/api/boards", json={
            "name": "板2", "origin_room_id": rid2},
            headers={"X-Session-Key": "stranger"})
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_room_admin"


async def test_host_binds_workspace_and_toggles_single_writer(tmp_path):
    app, client = await _client(tmp_path, "ws")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client, kind="ops")
        # 對照組
        r = await client.patch(f"/api/rooms/{rid}/single-writer",
                               json={"enabled": False},
                               headers={"X-Session-Key": "stranger"})
        assert r.status_code == 403
        r = await client.patch(f"/api/rooms/{rid}/single-writer",
                               json={"enabled": False, "reason": "要併行"},
                               headers=HOST)
        assert r.status_code == 200, r.text
        assert "要併行" in (await _msgs(
            client, rid, owner, "single_writer_changed"))[-1]["content"]
        # 綁定工作區：沒有執行器服務該 key 時業務規則 409，但不是 403
        r = await client.post(f"/api/rooms/{rid}/workspace",
                              json={"workspace_key": "ai-website"},
                              headers=HOST)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "project_not_served"


# ── 房主換人 → 封存請求清空 ───────────────────────────────────────────

async def test_pending_archive_requests_are_cancelled_when_admin_changes(tmp_path):
    app, client = await _client(tmp_path, "admin-chg")
    async with app.router.lifespan_context(app), client:
        async def setup(name):
            rid = (await client.post("/api/rooms", json={
                "name": name, "session_key": OWNER})).json()["id"]
            owner = await _join(client, rid, OWNER, "房主")
            heir = await _join(client, rid, "heir-key", "繼任者")
            req = (await client.post(f"/api/rooms/{rid}/archive",
                                     headers=heir)).json()["request"]
            return rid, owner, heir, req

        async def status_of(req_id):
            row = await (await app.state.db.execute(
                "SELECT status FROM archive_request WHERE id=?",
                (req_id,))).fetchone()
            return row["status"]

        # ① 移交：新房主正是提案者
        rid, owner, heir, req = await setup("移交")
        assert await status_of(req["id"]) == "pending"
        r = await client.post(f"/api/rooms/{rid}/admin", headers=owner,
                              json={"target_participant_id":
                                    heir["X-Participant-Id"]})
        assert r.status_code == 200, r.text
        assert await status_of(req["id"]) == "cancelled"
        # App 讀得到的待處理請求消失
        detail = (await client.get(f"/api/rooms/{rid}", headers=heir)).json()
        assert detail["archive_request"] is None

        # ② 主持人接管
        rid, owner, heir, req = await setup("接管")
        r = await client.post(f"/api/rooms/{rid}/admin/claim", headers=HOST)
        assert r.status_code == 200, r.text
        assert await status_of(req["id"]) == "cancelled"

        # ③ 房主離開 → 自動移交
        rid, owner, heir, req = await setup("離開")
        r = await client.post(f"/api/rooms/{rid}/leave", headers=owner)
        assert r.status_code == 200, r.text
        assert r.json()["admin_transferred_to"] is not None
        assert await status_of(req["id"]) == "cancelled"
