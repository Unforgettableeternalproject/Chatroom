"""板的公開／私人，以及 BOARDS 分頁上「誰看得到什麼」。

艾斯維爾 2026-09-03 的規則，翻成可判定的形式：

- **owner 永遠有完整權限**，與掛接狀態、在不在房裡都無關
- 其餘人的資格**完全動態**：以現存（未封存）掛接房的 active 成員為準
- BOARDS 分頁常駐 ＝ 自己 owner 的板 ∪ 別人的**公開**板（且我在某個現存
  掛接房裡）。別人的**私人板永不進分頁**，只能從聊天室路徑進
- 私人板只能掛進**私人房**（「只能放在自己開的私人聊天室」；「自己開的」
  那一半由既有的房管理者檢查擔，這裡不重複）

🚨 這份檔案守的是**兩個死欄位被喚醒**的那一刻：`board.visibility` 與
`board.owner_actor_key` schema 裡都早就有，卻從來沒有被讀過。死欄位一旦
開始生效，語意錯了不會有任何地方報錯——只會有人的板從畫面上消失。
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


async def _room(client, name="房", who="claude-a", visibility="public"):
    return (await client.post("/api/rooms", json={
        "name": name, "session_key": who,
        "visibility": visibility})).json()["id"]


async def _join(client, rid, who, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": who,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"],
            "X-Session-Key": who}


async def _board(client, hdr, name="板", visibility="public", room=""):
    body = {"name": name, "visibility": visibility}
    if room:
        body["origin_room_id"] = room
    r = await client.post("/api/boards", json=body, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _library(client, hdr):
    r = await client.get("/api/boards", headers=hdr)
    assert r.status_code == 200, r.text
    return {b["id"] for b in r.json()["boards"]}


async def test_the_owner_keeps_full_rights_without_any_room(tmp_path):
    """owner 永遠是 owner——換 session、板沒掛房、他不在任何房裡都一樣。

    🚨 `board.owner_actor_key` 一直是**死欄位**（只寫不讀），owner 的權限
    完全靠 `board_member` 那一列。而 board_member 綁 actor_key ⇒ owner 換一
    個 session 就對不上 ⇒ 落到房內身分退路 ⇒ **降級成 editor**；板要是沒掛
    房，退路也沒有來源 ⇒ **對自己的板完全沒權限**
    （@開發Novia (除錯) 2026-09-03）。

    而「BOARDS 分頁開一塊板」建出來的板本來就沒掛任何房——這條路徑天天走。
    """
    app, client = await _client(tmp_path, "owner-always")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client)
            me = await _join(client, rid, "claude-a", "A")
            bid = await _board(client, me)          # 不掛任何房

            body = await client.get(f"/api/boards/{bid}", headers=me)
            assert body.status_code == 200
            assert body.json()["my_role"] == "owner"

            # 離開唯一那間房——板本來就沒掛它，權限不該有任何變化
            await client.post(f"/api/rooms/{rid}/leave", headers=me)
            after = await client.get(f"/api/boards/{bid}",
                                     headers={"X-Session-Key": "claude-a"})
            assert after.status_code == 200
            assert after.json()["my_role"] == "owner"
            assert bid in await _library(client,
                                         {"X-Session-Key": "claude-a"})


async def test_the_library_shows_my_boards_and_other_peoples_public_ones(
        tmp_path):
    """分頁常駐 ＝ 自己的板 ∪ 別人的公開板（且我在某個現存掛接房裡）。"""
    app, client = await _client(tmp_path, "library-source")
    async with client:
        async with app.router.lifespan_context(app):
            rid = await _room(client, who="claude-a")
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")

            mine = await _board(client, b, "B 自己的")
            shared = await _board(client, a, "公開板", room=rid)
            secret = await _board(client, a, "私人板", visibility="private")

            seen = await _library(client, b)
            assert mine in seen, "自己 owner 的板不在分頁上"
            assert shared in seen, "同房的公開板看不到"
            assert secret not in seen, "別人的私人板出現在分頁上了"

            # 離開房 ⇒ 別人的公開板從分頁消失，自己的留著
            await client.post(f"/api/rooms/{rid}/leave", headers=b)
            seen = await _library(client, {"X-Session-Key": "claude-b"})
            assert shared not in seen
            assert mine in seen


async def test_a_private_board_is_still_reachable_from_the_room(tmp_path):
    """私人板不進分頁，但**房裡的人進得去**——不可見不等於沒有權限。"""
    app, client = await _client(tmp_path, "private-via-room")
    async with client:
        async with app.router.lifespan_context(app):
            # 先公開讓人進來再鎖起來——私人房本來就不能自行加入，
            # 而這條測的是「已經在裡面的人」看不看得到
            rid = await _room(client, who="claude-a")
            a = await _join(client, rid, "claude-a", "A")
            b = await _join(client, rid, "claude-b", "B")
            lock = await client.post(f"/api/rooms/{rid}/visibility",
                                     json={"visibility": "private"}, headers=a)
            assert lock.status_code == 200, lock.text
            bid = await _board(client, a, "私人板", visibility="private")
            r = await client.post(f"/api/boards/{bid}/rooms/{rid}", headers=a)
            assert r.status_code == 200, r.text

            assert bid not in await _library(client, b)
            got = await client.get(f"/api/boards/{bid}", headers=b)
            assert got.status_code == 200, "房裡的人連私人板都進不去"
            assert got.json()["my_role"] == "editor"


async def test_a_private_board_only_goes_into_a_private_room(tmp_path):
    """私人板只能掛進私人房。

    「自己開的」那一半由既有的房管理者檢查擔（`attach_board` 已經要求
    是房的建立者），這裡守的是**剩下那一半**：自己開的**公開**房也不行。
    """
    app, client = await _client(tmp_path, "private-needs-private-room")
    async with client:
        async with app.router.lifespan_context(app):
            open_room = await _room(client, "公開房", "claude-a", "public")
            a = await _join(client, open_room, "claude-a", "A")
            bid = await _board(client, a, "私人板", visibility="private")

            no = await client.post(f"/api/boards/{bid}/rooms/{open_room}",
                                   headers=a)
            assert no.status_code == 409
            assert no.json()["detail"]["code"] == "private_board_public_room"

            # 公開板掛公開房沒問題
            pub = await _board(client, a, "公開板")
            ok = await client.post(f"/api/boards/{pub}/rooms/{open_room}",
                                   headers=a)
            assert ok.status_code == 200, ok.text


async def test_boards_from_before_this_feature_are_public(tmp_path):
    """存量板一律遷成 `public`（艾斯維爾 2026-09-03：「現有的板都是以公開為主」）。

    🚨 欄位的 schema 預設是 `private`，而**它到今天為止都沒有作用** ⇒ 現有
    的板在資料庫裡真的存著 `private`（活庫實查確認）。功能一開那個值立刻
    生效 ⇒ 所有既有的板從所有人的分頁消失，只剩建立者看得到，而且沒有任何
    地方會報錯。
    """
    from chatroom_server.db import open_db

    path = str(tmp_path / "legacy.db")
    db = await open_db(path)
    await db.execute(
        "INSERT INTO board (id, name, description, status, visibility,"
        " owner_actor_key, board_seq, created_at, updated_at)"
        " VALUES ('old','舊板','','active','private','claude-a',0,'t','t')")
    # 倒回功能上線之前的版次——這塊板就是那時候建的
    await db.execute("PRAGMA user_version=0")
    await db.commit()
    await db.close()

    # 再開一次＝升級一次。遷移要把它改成 public，而且**冪等**
    for _ in range(2):
        db = await open_db(path)
        row = await (await db.execute(
            "SELECT visibility FROM board WHERE id='old'")).fetchone()
        assert row["visibility"] == "public"
        await db.close()
