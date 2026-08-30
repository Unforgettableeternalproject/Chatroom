"""刪除聊天室：整個 Hub 唯一不可復原的動作。

守三件事：只有建立者刪得掉、刪乾淨、以及**別把還有人在用的附件實體一起帶走**
（附件是內容定址的，同一份檔案多房共用一份實體）。
"""

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config


async def _make(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="", **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _room(client, name="房", session_key="admin"):
    r = await client.post(
        "/api/rooms", json={"name": name, "session_key": session_key}
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _join(client, room_id, session_key="s1", name="Novia"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _upload(client, room_id, pid, content=b"hello", filename="a.txt"):
    r = await client.post(
        f"/api/rooms/{room_id}/attachments",
        headers={"X-Participant-Id": pid},
        files={"file": (filename, content, "text/plain")},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_only_the_creator_can_delete(tmp_path):
    app, client = await _make(tmp_path, "del_admin")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            r = await client.delete(
                f"/api/rooms/{room['id']}",
                headers={"X-Session-Key": "someone-else"},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_admin"
            assert "刪除" in r.json()["detail"]["message"]

            r = await client.delete(
                f"/api/rooms/{room['id']}", headers={"X-Session-Key": "admin"}
            )
            assert r.status_code == 200, r.text
            assert r.json()["ok"] is True


@pytest.mark.asyncio
async def test_delete_removes_everything_and_the_room_is_gone(tmp_path):
    app, client = await _make(tmp_path, "del_all")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            me = await _join(client, room["id"])
            pid = me["participant_id"]
            await _upload(client, room["id"], pid)
            await client.post(
                f"/api/rooms/{room['id']}/messages",
                headers={"X-Participant-Id": pid}, json={"content": "留下點東西"},
            )

            r = await client.delete(
                f"/api/rooms/{room['id']}", headers={"X-Session-Key": "admin"}
            )
            counts = r.json()["deleted"]
            assert counts["room"] == 1
            assert counts["message"] >= 1
            assert counts["participant"] == 1
            assert counts["attachment"] == 1

            db = app.state.db
            for table in ("message", "participant", "attachment", "assignment",
                          "question"):
                row = await (
                    await db.execute(
                        f"SELECT COUNT(*) AS n FROM {table} WHERE room_id=?",
                        (room["id"],),
                    )
                ).fetchone()
                assert row["n"] == 0, f"{table} 還有殘留"

            # 房間真的不見了：拿舊身分去讀會撞 404，不是 403
            r = await client.get(
                f"/api/rooms/{room['id']}/messages",
                headers={"X-Participant-Id": pid},
            )
            assert r.status_code == 404
            assert r.json()["detail"]["code"] == "room_not_found"


@pytest.mark.asyncio
async def test_archived_rooms_can_be_deleted(tmp_path):
    """封存房才是主要用途——不能因為唯讀就連刪都不給刪。"""
    app, client = await _make(tmp_path, "del_archived")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            await client.post(f"/api/rooms/{room['id']}/archive")
            r = await client.delete(
                f"/api/rooms/{room['id']}", headers={"X-Session-Key": "admin"}
            )
            assert r.status_code == 200, r.text


@pytest.mark.asyncio
async def test_shared_attachment_blob_survives_when_one_room_is_deleted(tmp_path):
    """**最重要的一條**：附件是內容定址的，同一份檔案多房共用一份實體。

    刪房時順手刪檔的話，刪掉的是所有引用它的房間的附件——另一個房間的訊息
    上會留著一筆指向空氣的附件，而且是在很久以後才被發現。
    """
    app, client = await _make(tmp_path, "del_blob")
    async with client:
        async with app.router.lifespan_context(app):
            same = b"two rooms, one blob"
            a = await _room(client, "甲")
            b = await _room(client, "乙")
            pa = (await _join(client, a["id"], "sa"))["participant_id"]
            pb = (await _join(client, b["id"], "sb"))["participant_id"]
            up_a = await _upload(client, a["id"], pa, same)
            up_b = await _upload(client, b["id"], pb, same)

            await client.delete(
                f"/api/rooms/{a['id']}", headers={"X-Session-Key": "admin"}
            )
            await app.state.sweep_once()

            # 乙房的附件還下載得到
            r = await client.get(
                f"/api/attachments/{up_b['id']}",
                headers={"X-Participant-Id": pb},
            )
            assert r.status_code == 200, "共用的實體被刪房順手帶走了"
            assert r.content == same
            # 甲房的那筆 row 確實不見了
            r = await client.get(
                f"/api/attachments/{up_a['id']}/meta",
                headers={"X-Participant-Id": pb},
            )
            assert r.status_code == 404


@pytest.mark.asyncio
async def test_orphan_blob_is_reclaimed_after_the_grace(tmp_path):
    app, client = await _make(tmp_path, "del_orphan", orphan_blob_grace=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            pid = (await _join(client, room["id"]))["participant_id"]
            up = await _upload(client, room["id"], pid, b"lonely")
            await client.delete(
                f"/api/rooms/{room['id']}", headers={"X-Session-Key": "admin"}
            )
            await app.state.sweep_once()

            root = app.state.db  # noqa: F841 - 只是為了讓錯誤訊息好讀
            from chatroom_server.config import Config as _C  # noqa: F401
            from pathlib import Path
            attach_root = Path(str(tmp_path / "del_orphan.db")).parent / "attachments"
            blobs = [p for sub in attach_root.iterdir() if sub.is_dir()
                     for p in sub.iterdir() if p.is_file()]
            assert blobs == [], f"沒人引用的實體應該被回收，還留著：{blobs} ({up['id']})"


@pytest.mark.asyncio
async def test_fresh_blob_is_kept_during_the_grace(tmp_path):
    """寬限期內不動：上傳是先寫檔再寫 row，中間那段時間檔案看起來就是孤兒。

    沒有寬限的話，sweeper 會刪掉正在上傳中的附件，而那個上傳仍會成功——
    留下一筆指向空氣的 row。
    """
    app, client = await _make(tmp_path, "del_grace", orphan_blob_grace=3600.0)
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            pid = (await _join(client, room["id"]))["participant_id"]
            await _upload(client, room["id"], pid, b"just uploaded")
            await client.delete(
                f"/api/rooms/{room['id']}", headers={"X-Session-Key": "admin"}
            )
            await app.state.sweep_once()

            from pathlib import Path
            attach_root = Path(str(tmp_path / "del_grace.db")).parent / "attachments"
            blobs = [p for sub in attach_root.iterdir() if sub.is_dir()
                     for p in sub.iterdir() if p.is_file()]
            assert len(blobs) == 1, "寬限期內的實體不該被回收"


@pytest.mark.asyncio
async def test_sweeper_purges_rooms_archived_long_enough(tmp_path):
    app, client = await _make(tmp_path, "purge_on", purge_archived_days=1.0)
    async with client:
        async with app.router.lifespan_context(app):
            keep = await _room(client, "剛封存")
            old = await _room(client, "封存很久")
            for r in (keep, old):
                await client.post(f"/api/rooms/{r['id']}/archive")
            # 把其中一間的封存時間往回撥
            await app.state.db.execute(
                "UPDATE room SET archived_at=? WHERE id=?",
                ("2020-01-01T00:00:00+00:00", old["id"]),
            )
            await app.state.db.commit()

            await app.state.sweep_once()

            r = await client.get("/api/rooms", params={"status": "archived"})
            ids = [x["id"] for x in r.json()["rooms"]]
            assert old["id"] not in ids, "封存夠久的房應該被清掉"
            assert keep["id"] in ids, "剛封存的房不該被碰"


@pytest.mark.asyncio
async def test_archived_without_a_timestamp_is_never_purged(tmp_path):
    """`archived_at` 是 NULL 的舊資料沒有倒數起點——不可復原的動作不用猜的時間。"""
    app, client = await _make(tmp_path, "purge_null", purge_archived_days=1.0)
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            await client.post(f"/api/rooms/{room['id']}/archive")
            await app.state.db.execute(
                "UPDATE room SET archived_at=NULL WHERE id=?", (room["id"],)
            )
            await app.state.db.commit()

            await app.state.sweep_once()

            r = await client.get("/api/rooms", params={"status": "archived"})
            assert room["id"] in [x["id"] for x in r.json()["rooms"]]


@pytest.mark.asyncio
async def test_purge_can_be_switched_off(tmp_path):
    app, client = await _make(tmp_path, "purge_off", purge_archived_days=0.0)
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            await client.post(f"/api/rooms/{room['id']}/archive")
            await app.state.db.execute(
                "UPDATE room SET archived_at=? WHERE id=?",
                ("2020-01-01T00:00:00+00:00", room["id"]),
            )
            await app.state.db.commit()

            await app.state.sweep_once()

            r = await client.get("/api/rooms", params={"status": "archived"})
            assert room["id"] in [x["id"] for x in r.json()["rooms"]]


@pytest.mark.asyncio
async def test_long_poll_wakes_up_when_the_room_is_deleted(tmp_path):
    """掛在被刪房間上的 client 要醒過來，而不是掛到逾時才發現房不見了。"""
    app, client = await _make(tmp_path, "del_wake")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            pid = (await _join(client, room["id"]))["participant_id"]

            async def _poll():
                return await client.get(
                    f"/api/rooms/{room['id']}/updates",
                    params={"after_seq": 99, "timeout": 20},
                    headers={"X-Participant-Id": pid},
                )

            task = asyncio.create_task(_poll())
            await asyncio.sleep(0.2)
            await client.delete(
                f"/api/rooms/{room['id']}", headers={"X-Session-Key": "admin"}
            )
            res = await asyncio.wait_for(task, timeout=5)
            # 醒過來就好——房間沒了，回什麼都算「別再掛著」
            assert res.status_code in (200, 404)
