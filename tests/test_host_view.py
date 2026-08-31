"""Hub 主持人視角（`X-Host-View` + 主 token）。

彌補的是封存收成建立者專屬之後留下的代價：建立者不在或換了 deviceKey，
那個房就永遠唯讀。主持人握有 `.env`，而握有 `.env` 就握有 `chatroom.db`——
給他 UI 不是新開權限，是把既有能力變得可用。

**兩個條件缺一不可**，這份測試的重點有一半在「缺一不可」那邊：
只有主 token 而不明示 → 維持原樣（這是「明確切換」的實作，不是 UI 幻覺）；
明示但不是主 token → 一律擋掉（這是不讓標頭變成後門）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HOST = {"Authorization": f"Bearer {ROOT}", "X-Host-View": "1"}
ROOT_ONLY = {"Authorization": f"Bearer {ROOT}"}


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _private_room_of_someone_else(client):
    """別人開的私人房，主持人完全沒份。"""
    rid = (await client.post("/api/rooms", json={
        "name": "別人的私人房", "session_key": "someone-else",
        "visibility": "private"})).json()["id"]
    me = (await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": "someone-else",
        "preferred_name": "Owner"})).json()
    await client.post(f"/api/rooms/{rid}/messages", json={
        "content": "祕密"}, headers={"X-Participant-Id": me["participant_id"]})
    return rid


# ---------- 缺一不可 ----------

async def test_root_token_alone_changes_nothing(tmp_path):
    """只有主 token、沒帶 X-Host-View → 行為與現在**完全一樣**。

    這條是「明確切換」的實作證明。少了它，主持人會在沒意識到的情況下
    一直看著別人的私人房，而 UI 上分不出他看到的是哪一種列表。
    """
    app, client = await _client(tmp_path, "no-header")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _private_room_of_someone_else(client)
            rooms = (await client.get("/api/rooms")).json()
            assert all(r["id"] != rid for r in rooms["rooms"])
            assert rooms["host_view"] is False
            # 但 you_are_host 要是 True——開關必須在被打開之前就看得到
            assert rooms["you_are_host"] is True
            r = await client.get(f"/api/rooms/{rid}")
            assert r.status_code in (401, 403)


async def test_header_without_root_token_is_ignored(tmp_path):
    """帶了 X-Host-View 但不是主 token → 一律擋。標頭不是後門。"""
    app, client = await _client(tmp_path, "fake-header")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _private_room_of_someone_else(client)
            # 先發一張真的 access_token，模擬「合法但不是主持人」的人
            tok = (await client.post("/api/tokens", json={"label": "guest"},
                                     headers=ROOT_ONLY)).json()["token"]
            guest = {"Authorization": f"Bearer {tok}", "X-Host-View": "1"}
            rooms = (await client.get("/api/rooms", headers=guest)).json()
            assert all(r["id"] != rid for r in rooms["rooms"])
            assert rooms["you_are_host"] is False
            assert rooms["host_view"] is False
            r = await client.get(f"/api/rooms/{rid}", headers=guest)
            assert r.status_code in (401, 403)
            r = await client.get(f"/api/rooms/{rid}/messages", headers=guest)
            assert r.status_code in (401, 403)


# ---------- 開起來之後 ----------

async def test_host_view_sees_and_reads_everything(tmp_path):
    """兩個條件都成立 → 看得到也讀得到（艾斯維爾 08/31 裁決的範圍）。"""
    app, client = await _client(tmp_path, "full")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _private_room_of_someone_else(client)
            rooms = (await client.get("/api/rooms", headers=HOST)).json()
            assert any(r["id"] == rid for r in rooms["rooms"])
            assert rooms["host_view"] is True
            det = await client.get(f"/api/rooms/{rid}", headers=HOST)
            assert det.status_code == 200
            msgs = (await client.get(f"/api/rooms/{rid}/messages",
                                     headers=HOST)).json()
            assert any(m["content"] == "祕密" for m in msgs["messages"])


async def test_host_can_rescue_an_ownerless_archived_room(tmp_path):
    """**這條是整個功能的理由**：沒有建立者紀錄的房被封存後，原本永遠解不開。

    `_admin_or_403` 對這種房回 409 room_has_no_admin——那個 409 擋在 host
    判定前面的話，唯一的救援路徑就被關在門外了。
    """
    app, client = await _client(tmp_path, "rescue")
    async with client:
        async with app.router.lifespan_context(app):
            # 沒帶 session_key 建房＝沒有建立者紀錄（舊房就長這樣）
            rid = (await client.post(
                "/api/rooms", json={"name": "沒人管的房"})).json()["id"]
            # 對照組：一般身分連封存都做不到
            nobody = await client.post(f"/api/rooms/{rid}/archive")
            assert nobody.status_code in (401, 403, 409)

            assert (await client.post(f"/api/rooms/{rid}/archive",
                                      headers=HOST)).status_code == 200
            det = (await client.get(f"/api/rooms/{rid}",
                                    headers=HOST)).json()
            assert det["room"]["status"] == "archived"

            # 沒有主持人視角就解不開——這正是那個「已知代價」
            stuck = await client.post(f"/api/rooms/{rid}/unarchive")
            assert stuck.status_code in (401, 403, 409)
            # 有了就解得開
            assert (await client.post(f"/api/rooms/{rid}/unarchive",
                                      headers=HOST)).status_code == 200
            det = (await client.get(f"/api/rooms/{rid}", headers=HOST)).json()
            assert det["room"]["status"] == "active"


async def test_host_archive_is_direct_not_a_request(tmp_path):
    """主持人按封存是**直接封**，不是提案。

    走提案那條路的話，提案會掛在一個永遠不會出現的建立者身上——那正是
    這個房需要被救援的原因。
    """
    app, client = await _client(tmp_path, "direct")
    async with client:
        async with app.router.lifespan_context(app):
            rid = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "someone-else"})).json()["id"]
            r = (await client.post(f"/api/rooms/{rid}/archive",
                                   headers=HOST)).json()
            assert r["archived"] is True
            assert "request" not in r


# ---------- 成員列表的 host badge ----------

async def test_joined_as_host_is_recorded_and_exposed(tmp_path):
    """拿主 token 進來的人在成員列表上標得出來，與 is_admin 分開。"""
    app, client = await _client(tmp_path, "badge")
    async with client:
        async with app.router.lifespan_context(app):
            # 房是別人開的 → 主持人不是這個房的 admin，但仍是 Hub 的 host
            rid = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "someone-else"})).json()["id"]
            tok = (await client.post("/api/tokens", json={"label": "guest"},
                                     headers=ROOT_ONLY)).json()["token"]
            await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "guest-key",
                "preferred_name": "Guest"},
                headers={"Authorization": f"Bearer {tok}"})
            await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human", "session_key": "host-key",
                "preferred_name": "Host"})
            det = (await client.get(f"/api/rooms/{rid}", headers=HOST)).json()
            by_name = {p["display_name"]: p for p in det["participants"]}
            assert by_name["Host"]["is_host"] is True
            # 用發出去的 token 進來的不是主持人
            assert by_name["Guest"]["is_host"] is False
            # host 與 admin 是兩件事：這個房不是主持人開的
            assert by_name["Host"]["is_admin"] is False


# ---------- 不擴權 ----------

async def test_host_view_does_not_grant_write(tmp_path):
    """視角只給**讀取與封存**，不給發言。

    範圍愈小愈好：主持人要說話就正常加入。悄悄以非成員身分發言會在房裡
    留下一個沒有人記得他何時進來的發話者。
    """
    app, client = await _client(tmp_path, "readonly")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _private_room_of_someone_else(client)
            r = await client.post(f"/api/rooms/{rid}/messages",
                                  json={"content": "插話"}, headers=HOST)
            assert r.status_code in (401, 403)
