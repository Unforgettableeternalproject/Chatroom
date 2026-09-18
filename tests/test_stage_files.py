"""階段素材（stage files，艾斯維爾 2026-09-17 契約）。

附件掛在**階段**上，那個階段的所有卡與 run 共用。守的是三件事：

- 素材跟著階段一起被讀到（agent 讀板就看得到，不必為一個計數再打一次 API）
- 附件的房必須是這塊板的掛接房之一——不驗的話，房間邊界從這裡整條漏掉
- 階段刪了，素材跟著消失：留著的那幾列會對一個不存在的階段說話
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


async def _room(client, name="房", session_key="human-a"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": session_key})).json()["id"]


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    assert r.status_code == 200, r.text
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": session_key}


async def _upload(client, rid, hdr, content=b"screenshot", name="a.png"):
    r = await client.post(f"/api/rooms/{rid}/attachments",
                          files={"file": (name, content, "image/png")},
                          headers={"X-Participant-Id": hdr["X-Participant-Id"]})
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _stage(client, rid, hdr):
    """建第一張卡（順便長出板與「未分類」階段），回 (board_id, checklist_id)。"""
    r = await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": "第一張卡"}, headers=hdr)
    assert r.status_code == 200, r.text
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    body = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
    return bid, body["checklists"][0]["id"]


async def test_add_list_and_read_through_the_board(tmp_path):
    """掛上去之後：files 端點看得到，讀板的 checklist 也帶著它。"""
    app, client = await _client(tmp_path, "stage_add")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        aid = await _upload(client, rid, hdr)

        r = await client.post(
            f"/api/boards/{bid}/checklists/{cid}/files",
            json={"attachment_id": aid, "note": "登入頁的截圖"}, headers=hdr)
        assert r.status_code == 200, r.text
        item = r.json()["file"]
        assert item["filename"] == "a.png"
        assert item["note"] == "登入頁的截圖"
        assert item["added_by"] == "human-a"
        assert item["added_by_name"] == "艾斯維爾"

        listed = (await client.get(f"/api/boards/{bid}/checklists/{cid}/files",
                                   headers=hdr)).json()["files"]
        assert [f["id"] for f in listed] == [item["id"]]

        board = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
        stage = [c for c in board["checklists"] if c["id"] == cid][0]
        assert [f["attachment_id"] for f in stage["files"]] == [aid]

        # 重複掛回 409，而且不會多出第二列
        dup = await client.post(f"/api/boards/{bid}/checklists/{cid}/files",
                                json={"attachment_id": aid}, headers=hdr)
        assert dup.status_code == 409, dup.text
        assert dup.json()["detail"]["code"] == "stage_file_exists"


async def test_attachment_must_belong_to_an_attached_room(tmp_path):
    """別間房的附件掛不上來——URL 上的 board_id 不是房間邊界的替代品。"""
    app, client = await _client(tmp_path, "stage_room")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)

        other = await _room(client, name="別間", session_key="human-b")
        ohdr = await _join(client, other, "human-b", "別人", role="human")
        alien = await _upload(client, other, ohdr, name="b.png")

        r = await client.post(f"/api/boards/{bid}/checklists/{cid}/files",
                              json={"attachment_id": alien}, headers=hdr)
        assert r.status_code == 400, r.text
        assert r.json()["detail"]["code"] == "stage_file_room_mismatch"

        missing = await client.post(f"/api/boards/{bid}/checklists/{cid}/files",
                                    json={"attachment_id": "nope"}, headers=hdr)
        assert missing.status_code == 404, missing.text


async def test_agent_cannot_remove_someone_elses_file(tmp_path):
    """agent 卸不掉別人掛的；自己掛的可以，人類誰的都可以。"""
    app, client = await _client(tmp_path, "stage_remove")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        ahdr = await _join(client, rid, "claude-n", "Novia")

        mine = (await client.post(
            f"/api/boards/{bid}/checklists/{cid}/files",
            json={"attachment_id": await _upload(client, rid, hdr)},
            headers=hdr)).json()["file"]
        theirs = (await client.post(
            f"/api/boards/{bid}/checklists/{cid}/files",
            json={"attachment_id": await _upload(
                client, rid, ahdr, content=b"other", name="c.png")},
            headers=ahdr)).json()["file"]

        base = f"/api/boards/{bid}/checklists/{cid}/files"
        blocked = await client.delete(f"{base}/{mine['id']}", headers=ahdr)
        assert blocked.status_code == 403, blocked.text
        assert blocked.json()["detail"]["code"] == "human_only"

        ok = await client.delete(f"{base}/{theirs['id']}", headers=ahdr)
        assert ok.status_code == 200 and ok.json() == {"removed": True}

        ok2 = await client.delete(f"{base}/{mine['id']}", headers=hdr)
        assert ok2.status_code == 200
        assert (await client.get(base, headers=hdr)).json()["files"] == []


async def test_deleting_the_stage_takes_its_files(tmp_path):
    """階段刪了，素材跟著走——附件本身留著（它可能還掛在訊息上）。"""
    app, client = await _client(tmp_path, "stage_cascade")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        aid = await _upload(client, rid, hdr)
        await client.post(f"/api/boards/{bid}/checklists/{cid}/files",
                          json={"attachment_id": aid}, headers=hdr)

        r = await client.delete(f"/api/board/checklists/{cid}", headers=hdr)
        assert r.status_code == 200, r.text
        left = await (await app.state.db.execute(
            "SELECT COUNT(*) AS n FROM board_checklist_file WHERE checklist_id=?",
            (cid,))).fetchone()
        assert left["n"] == 0
        still = await (await app.state.db.execute(
            "SELECT COUNT(*) AS n FROM attachment WHERE id=?",
            (aid,))).fetchone()
        assert still["n"] == 1, "連附件本體都刪掉了"


async def test_board_member_can_read_the_attachment_by_session_key(tmp_path):
    """板軸開板的人下載得到素材——列得出來卻打不開，等於沒有掛上去。"""
    app, client = await _client(tmp_path, "stage_download")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        aid = await _upload(client, rid, hdr)
        await client.post(f"/api/boards/{bid}/checklists/{cid}/files",
                          json={"attachment_id": aid}, headers=hdr)

        # 只有 session key，沒有 participant id（Board Library 那條路）
        only_key = {"X-Session-Key": "human-a"}
        r = await client.get(f"/api/attachments/{aid}", headers=only_key)
        assert r.status_code == 200, r.text
        assert r.content == b"screenshot"
        meta = await client.get(f"/api/attachments/{aid}/meta", headers=only_key)
        assert meta.status_code == 200, meta.text

        # 既不是房內成員也不是板成員的人照樣擋著
        stranger = {"X-Session-Key": "claude-stranger"}
        blocked = await client.get(f"/api/attachments/{aid}", headers=stranger)
        # 房那條路先擋（沒有 participant id ⇒ 401），板那條路也不認他，
        # 於是原本的拒絕原樣往上拋——擴的是放行，不是把拒絕換一種說法
        assert blocked.status_code == 401, blocked.text
        assert blocked.json()["detail"]["code"] == "participant_header_required"


async def test_incremental_board_read_surfaces_a_newly_attached_stage_file(tmp_path):
    """agent 已經讀過一次板（拿到 board_seq），人類才把素材掛上去——
    agent 接著用 after_board_seq 做增量讀取，仍然要看得到這份素材。

    根因假設：`add_stage_file` 只寫 `board_checklist_file`，沒有替
    `board_checklist` 領新的 board_seq；增量讀取只挑 `board_seq>after` 的
    checklist 列，於是這個階段不會再出現在 diff 裡，`files` 也跟著消失。
    """
    app, client = await _client(tmp_path, "stage_incremental")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)

        # agent 先讀一次板，記下水位
        first = (await client.get(f"/api/boards/{bid}", headers=hdr)).json()
        seq = first["board_seq"]

        aid = await _upload(client, rid, hdr)
        r = await client.post(f"/api/boards/{bid}/checklists/{cid}/files",
                              json={"attachment_id": aid, "note": "追加的截圖"},
                              headers=hdr)
        assert r.status_code == 200, r.text

        # agent 用上次記下的水位做增量讀取
        incremental = (await client.get(
            f"/api/boards/{bid}", params={"after_board_seq": seq},
            headers=hdr)).json()
        stage = [c for c in incremental["checklists"] if c["id"] == cid]
        assert stage, (
            "增量讀取沒有再帶出這個階段——新掛的素材因此對 agent 不可見")
        assert [f["attachment_id"] for f in stage[0]["files"]] == [aid]


async def test_note_can_be_edited_in_place(tmp_path):
    """備註改得動，而且這個階段會領到新的 board_seq——只做增量讀取的
    agent 讀到的必須是改過的那句，不是原本那句。"""
    app, client = await _client(tmp_path, "stage_note_edit")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        aid = await _upload(client, rid, hdr)
        base = f"/api/boards/{bid}/checklists/{cid}/files"
        fid = (await client.post(base, json={
            "attachment_id": aid, "note": "寫錯的那句"},
            headers=hdr)).json()["file"]["id"]

        seq = (await client.get(f"/api/boards/{bid}",
                                headers=hdr)).json()["board_seq"]

        r = await client.patch(f"{base}/{fid}",
                               json={"note": "  改成這句  "}, headers=hdr)
        assert r.status_code == 200, r.text
        assert r.json()["file"]["note"] == "改成這句"

        listed = (await client.get(base, headers=hdr)).json()["files"]
        assert [f["note"] for f in listed] == ["改成這句"]

        # 增量讀取要再帶出這個階段，否則改過的備註對 agent 不存在
        incremental = (await client.get(
            f"/api/boards/{bid}", params={"after_board_seq": seq},
            headers=hdr)).json()
        stage = [c for c in incremental["checklists"] if c["id"] == cid]
        assert stage, "改備註沒有推進 board_seq——增量讀取看不到這個階段"
        assert [f["note"] for f in stage[0]["files"]] == ["改成這句"]

        # 空字串是「把備註清掉」，不是沒帶
        cleared = await client.patch(f"{base}/{fid}", json={"note": ""},
                                     headers=hdr)
        assert cleared.status_code == 200, cleared.text
        assert cleared.json()["file"]["note"] == ""

        missing = await client.patch(f"{base}/nope", json={"note": "x"},
                                     headers=hdr)
        assert missing.status_code == 404, missing.text
        assert missing.json()["detail"]["code"] == "stage_file_not_found"


async def test_agent_cannot_edit_someone_elses_note(tmp_path):
    """判準與卸除同源：agent 改不動別人掛的，自己掛的可以。"""
    app, client = await _client(tmp_path, "stage_note_perm")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        ahdr = await _join(client, rid, "claude-n", "Novia")
        base = f"/api/boards/{bid}/checklists/{cid}/files"

        mine = (await client.post(base, json={
            "attachment_id": await _upload(client, rid, hdr)},
            headers=hdr)).json()["file"]
        theirs = (await client.post(base, json={
            "attachment_id": await _upload(
                client, rid, ahdr, content=b"other", name="c.png")},
            headers=ahdr)).json()["file"]

        blocked = await client.patch(f"{base}/{mine['id']}",
                                     json={"note": "偷改"}, headers=ahdr)
        assert blocked.status_code == 403, blocked.text
        assert blocked.json()["detail"]["code"] == "human_only"

        ok = await client.patch(f"{base}/{theirs['id']}",
                                json={"note": "自己掛的"}, headers=ahdr)
        assert ok.status_code == 200, ok.text

        # 人類誰的都改得動
        ok2 = await client.patch(f"{base}/{theirs['id']}",
                                 json={"note": "人類改的"}, headers=hdr)
        assert ok2.status_code == 200, ok2.text


async def test_note_too_long_is_rejected(tmp_path):
    """上限與 `StageFileAdd.note` 同一個數字（500）。"""
    app, client = await _client(tmp_path, "stage_note_len")
    async with client, app.router.lifespan_context(app):
        rid = await _room(client)
        hdr = await _join(client, rid, "human-a", "艾斯維爾", role="human")
        bid, cid = await _stage(client, rid, hdr)
        base = f"/api/boards/{bid}/checklists/{cid}/files"
        fid = (await client.post(base, json={
            "attachment_id": await _upload(client, rid, hdr)},
            headers=hdr)).json()["file"]["id"]

        r = await client.patch(f"{base}/{fid}", json={"note": "字" * 501},
                               headers=hdr)
        assert r.status_code == 422, r.text

        ok = await client.patch(f"{base}/{fid}", json={"note": "字" * 500},
                                headers=hdr)
        assert ok.status_code == 200, ok.text
