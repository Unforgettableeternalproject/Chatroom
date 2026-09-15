"""踢出要連著撤銷對方的邀請 token。

起因是一次實測：被踢的人**換一個 session_key 就能大搖大擺走回來**。
`join` 的 kicked 檢查綁 session_key，而人類的 session_key 是 App 自產的
`human-<uuid4>`，設定畫面還有「重新產生」按鈕——**封鎖的識別握在被封鎖者
手上，那個封鎖就不存在**。

真正握在主持人手上的識別只有 access token。這裡釘住的就是這條：
踢出 → token 失效 → 換幾把 session_key 都沒有用。

同時釘住誠實回報：對方若是拿主 token 進來的，主 token 不可撤銷（撤了所有人
一起斷），踢出**擋不住他回來**——回應必須說出來，不能讓管理員以為安全了。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

ROOT = "root-secret"
pytestmark = pytest.mark.asyncio


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


async def _join(client, room_id, token, session_key, name):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        headers=_auth(token),
        json={"kind": "human", "session_key": session_key,
              "preferred_name": name, "role": "human"},
    )
    return r


async def _room_with_admin(client):
    room_id = (await client.post(
        "/api/rooms", headers=_auth(ROOT),
        json={"name": "房", "session_key": "admin-key"})).json()["id"]
    admin = (await _join(client, room_id, ROOT, "admin-key", "Xavier")).json()
    return room_id, admin


async def test_kick_revokes_the_invite_token(tmp_path):
    app, client = await _make(tmp_path, "revoke")
    async with app.router.lifespan_context(app), client:
        room_id, admin = await _room_with_admin(client)
        guest_token = (await client.post(
            "/api/tokens", headers=_auth(ROOT),
            json={"label": "訪客"})).json()["token"]
        guest = (await _join(client, room_id, guest_token,
                             "human-aaa", "Guest")).json()

        r = await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers={**_auth(ROOT), "X-Participant-Id": admin["participant_id"]},
        )
        assert r.status_code == 200, r.text
        assert r.json()["revoked_token_label"] == "訪客"
        # 這張 token 撤得掉，所以存取真的斷了
        assert r.json()["access_still_open"] is False

        # 換一把全新的 session_key——被踢者唯一握在手上的變數
        r = await _join(client, room_id, guest_token, "human-bbb", "Guest2")
        assert r.status_code == 401, r.text
        assert r.json()["detail"]["code"] == "invalid_token"

        # 連讀都不行了：撤的是進 Hub 的權限，不只是這個房
        assert (await client.get("/api/rooms",
                                 headers=_auth(guest_token))).status_code == 401


async def test_kicking_a_root_token_holder_says_access_is_still_open(tmp_path):
    """主 token 不可撤銷，所以這種踢出擋不住人。回應要誠實。"""
    app, client = await _make(tmp_path, "root")
    async with app.router.lifespan_context(app), client:
        room_id, admin = await _room_with_admin(client)
        guest = (await _join(client, room_id, ROOT,
                             "human-aaa", "Guest")).json()

        r = await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers={**_auth(ROOT), "X-Participant-Id": admin["participant_id"]},
        )
        assert r.status_code == 200
        assert r.json()["revoked_token_label"] == ""
        assert r.json()["access_still_open"] is True

        # 而且這不是假警報——他換一把 session_key 真的回得來
        r = await _join(client, room_id, ROOT, "human-bbb", "Guest2")
        assert r.status_code == 200


async def test_other_guests_keep_their_access(tmp_path):
    """撤銷只打到被踢的那一張，不是連坐。"""
    app, client = await _make(tmp_path, "others")
    async with app.router.lifespan_context(app), client:
        room_id, admin = await _room_with_admin(client)
        tok_a = (await client.post("/api/tokens", headers=_auth(ROOT),
                                   json={"label": "a"})).json()["token"]
        tok_b = (await client.post("/api/tokens", headers=_auth(ROOT),
                                   json={"label": "b"})).json()["token"]
        a = (await _join(client, room_id, tok_a, "human-a", "A")).json()
        await _join(client, room_id, tok_b, "human-b", "B")

        await client.post(
            f"/api/rooms/{room_id}/participants/{a['participant_id']}/kick",
            headers={**_auth(ROOT), "X-Participant-Id": admin["participant_id"]},
        )
        assert (await client.get("/api/rooms", headers=_auth(tok_b))).status_code == 200
        assert (await client.get("/api/rooms", headers=_auth(tok_a))).status_code == 401
