"""附件：內容存磁碟、DB 只放 metadata，且房間邊界不得被繞過。

附件的來源包含外部 agent，所以「檔名」是不可信輸入——它只能被顯示，
絕不能參與組路徑。
"""

import asyncio
import hashlib

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, session_key, name):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key,
              "preferred_name": name, "role": "agent"},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _room(client, name="房"):
    return (
        await client.post("/api/rooms", json={"name": name, "session_key": "admin"})
    ).json()["id"]


async def _upload(client, room_id, pid, content: bytes, filename="a.png",
                  mime="image/png"):
    return await client.post(
        f"/api/rooms/{room_id}/attachments",
        files={"file": (filename, content, mime)},
        headers={"X-Participant-Id": pid},
    )


@pytest.mark.asyncio
async def test_upload_attach_and_download_roundtrip(tmp_path):
    app, client = await _make(tmp_path, "att_round")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            blob = b"\x89PNG fake image bytes"

            r = await _upload(client, room_id, me["participant_id"], blob)
            assert r.status_code == 200, r.text
            aid = r.json()["id"]
            assert r.json()["sha256"] == hashlib.sha256(blob).hexdigest()

            r = await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "這是截圖", "attachment_ids": [aid]},
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.status_code == 200

            msgs = (
                await client.get(f"/api/rooms/{room_id}/messages",
                                 headers={"X-Participant-Id": me["participant_id"]})
            ).json()["messages"]
            attached = [m for m in msgs if m["attachments"]]
            assert len(attached) == 1
            meta = attached[0]["attachments"][0]
            assert meta["filename"] == "a.png"
            assert meta["is_image"] is True
            assert meta["size"] == len(blob)

            r = await client.get(f"/api/attachments/{aid}",
                                 headers={"X-Participant-Id": me["participant_id"]})
            assert r.status_code == 200
            assert r.content == blob


@pytest.mark.asyncio
async def test_identical_content_is_stored_once(tmp_path):
    """內容定址：同一份檔案被不同人上傳多次，磁碟上只該有一份。"""
    app, client = await _make(tmp_path, "att_dedup")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            a = await _join(client, room_id, "k1", "甲")
            b = await _join(client, room_id, "k2", "乙")
            blob = b"same bytes"
            r1 = await _upload(client, room_id, a["participant_id"], blob, "x.txt")
            r2 = await _upload(client, room_id, b["participant_id"], blob, "y.txt")
            assert r1.json()["id"] != r2.json()["id"], "兩筆各自的 metadata"
            assert r1.json()["sha256"] == r2.json()["sha256"]

            root = tmp_path / "attachments"
            blobs = [p for p in root.rglob("*") if p.is_file()]
            assert len(blobs) == 1, "實體只該有一份"
            # 兩筆 metadata 都下載得到，各自帶回自己的檔名
            for r, name in ((r1, "x.txt"), (r2, "y.txt")):
                got = await client.get(f"/api/attachments/{r.json()['id']}",
                                 headers={"X-Participant-Id": a["participant_id"]})
                assert got.content == blob
                assert name in got.headers.get("content-disposition", "")


@pytest.mark.asyncio
async def test_oversized_upload_is_refused(tmp_path):
    app, client = await _make(tmp_path, "att_big", max_attachment_bytes=64)
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            r = await _upload(client, room_id, me["participant_id"], b"x" * 200)
            assert r.status_code == 413
            assert r.json()["detail"]["code"] == "attachment_too_large"
            # 超限的內容不得留在磁碟上
            root = tmp_path / "attachments"
            leftovers = [p for p in root.rglob("*") if p.is_file()] if root.exists() else []
            assert leftovers == []


@pytest.mark.asyncio
async def test_empty_upload_is_refused(tmp_path):
    app, client = await _make(tmp_path, "att_empty")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            r = await _upload(client, room_id, me["participant_id"], b"")
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "empty_attachment"


@pytest.mark.asyncio
async def test_cannot_attach_another_rooms_file(tmp_path):
    """否則把別房的附件 id 掛到自己的訊息上，就繞過了房間邊界。"""
    app, client = await _make(tmp_path, "att_cross")
    async with client:
        async with app.router.lifespan_context(app):
            room_a = await _room(client, "A")
            room_b = await _room(client, "B")
            me_a = await _join(client, room_a, "k1", "甲")
            me_b = await _join(client, room_b, "k1b", "乙")
            r = await _upload(client, room_a, me_a["participant_id"], b"secret")
            aid = r.json()["id"]

            r = await client.post(
                f"/api/rooms/{room_b}/messages",
                json={"content": "偷渡", "attachment_ids": [aid]},
                headers={"X-Participant-Id": me_b["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "attachment_not_available"


@pytest.mark.asyncio
async def test_attachment_cannot_be_reused_on_a_second_message(tmp_path):
    app, client = await _make(tmp_path, "att_reuse")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            aid = (
                await _upload(client, room_id, me["participant_id"], b"once")
            ).json()["id"]
            for expected in (200, 422):
                r = await client.post(
                    f"/api/rooms/{room_id}/messages",
                    json={"content": "帶檔", "attachment_ids": [aid]},
                    headers={"X-Participant-Id": me["participant_id"]},
                )
                assert r.status_code == expected


@pytest.mark.asyncio
async def test_filename_never_becomes_a_path(tmp_path):
    """附件來自外部 agent。檔名參與組路徑就是目錄穿越。"""
    app, client = await _make(tmp_path, "att_traversal")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            evil = "../../../../etc/passwd"
            r = await _upload(client, room_id, me["participant_id"], b"x", evil)
            assert r.status_code == 200
            meta = (
                await client.get(f"/api/attachments/{r.json()['id']}/meta",
                                 headers={"X-Participant-Id": me["participant_id"]})
            ).json()["attachment"]
            assert "/" not in meta["filename"] and "\\" not in meta["filename"]
            # 實體檔一律落在 attachments/ 底下，且檔名就是內容雜湊
            root = tmp_path / "attachments"
            blobs = [p for p in root.rglob("*") if p.is_file()]
            assert len(blobs) == 1
            assert blobs[0].name == r.json()["sha256"]


@pytest.mark.asyncio
async def test_deleted_message_hides_its_attachments(tmp_path):
    """軟刪除已經清掉內容，附件還掛著等於刪了個寂寞。"""
    app, client = await _make(tmp_path, "att_deleted")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            aid = (
                await _upload(client, room_id, me["participant_id"], b"pic")
            ).json()["id"]
            mid = (await client.post(
                f"/api/rooms/{room_id}/messages",
                json={"content": "圖", "attachment_ids": [aid]},
                headers={"X-Participant-Id": me["participant_id"]},
            )).json()["id"]
            await client.delete(
                f"/api/messages/{mid}",
                headers={"X-Participant-Id": me["participant_id"]})

            msgs = (
                await client.get(f"/api/rooms/{room_id}/messages",
                                 headers={"X-Participant-Id": me["participant_id"]})
            ).json()["messages"]
            target = next(m for m in msgs if m["id"] == mid)
            assert target["deleted"] is True
            assert target["attachments"] == []


@pytest.mark.asyncio
async def test_missing_blob_reports_clearly(tmp_path):
    """只備份 db 沒帶 attachments/ 就會這樣——講清楚比回一個空 404 有用。"""
    app, client = await _make(tmp_path, "att_missing")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            r = await _upload(client, room_id, me["participant_id"], b"gone")
            aid, sha = r.json()["id"], r.json()["sha256"]
            (tmp_path / "attachments" / sha[:2] / sha).unlink()

            r = await client.get(f"/api/attachments/{aid}",
                                 headers={"X-Participant-Id": me["participant_id"]})
            assert r.status_code == 410
            assert r.json()["detail"]["code"] == "attachment_blob_missing"


@pytest.mark.asyncio
async def test_upload_requires_room_membership(tmp_path):
    app, client = await _make(tmp_path, "att_auth")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            r = await client.post(
                f"/api/rooms/{room_id}/attachments",
                files={"file": ("a.txt", b"x", "text/plain")},
            )
            assert r.status_code == 401


@pytest.mark.asyncio
async def test_concurrent_uploads_of_same_content(tmp_path):
    """內容定址靠 rename 收斂；兩個同時上傳同一份檔不該互相踩壞。"""
    app, client = await _make(tmp_path, "att_concurrent")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = await _room(client)
            me = await _join(client, room_id, "k1", "諾薇亞")
            blob = b"racing bytes" * 100
            results = await asyncio.gather(*[
                _upload(client, room_id, me["participant_id"], blob, f"{i}.bin")
                for i in range(4)
            ])
            assert all(r.status_code == 200 for r in results)
            shas = {r.json()["sha256"] for r in results}
            assert len(shas) == 1
            for r in results:
                got = await client.get(f"/api/attachments/{r.json()['id']}",
                                 headers={"X-Participant-Id": me["participant_id"]})
                assert got.content == blob
