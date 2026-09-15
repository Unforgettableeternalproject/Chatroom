"""邀請人進 Hub 的存取 token。

權限範圍與主 token 相同——token 是信任邊界，房間不是。這張表買到的是
**可撤銷**與**可追溯**，不是隔離。測試要釘住的正是這兩件事，以及發放權
不會外流（否則撤銷形同虛設）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

ROOT = "root-secret"


async def _make(tmp_path, name, token=ROOT):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=token)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_issued_token_works_like_the_root_token(tmp_path):
    app, client = await _make(tmp_path, "issue")
    async with app.router.lifespan_context(app), client:
        r = await client.post("/api/tokens", json={"label": "戴爾"}, headers=_auth(ROOT))
        assert r.status_code == 200, r.text
        guest = r.json()["token"]

        # 發出去的 token 就是能用；範圍與主 token 相同是刻意的設計
        r = await client.get("/api/rooms", headers=_auth(guest))
        assert r.status_code == 200


@pytest.mark.asyncio
async def test_revoked_token_stops_working_but_others_keep_working(tmp_path):
    """單獨撤銷是這整張表存在的理由——不必換掉所有人的 token。"""
    app, client = await _make(tmp_path, "revoke")
    async with app.router.lifespan_context(app), client:
        a = (await client.post("/api/tokens", json={"label": "a"},
                               headers=_auth(ROOT))).json()["token"]
        b = (await client.post("/api/tokens", json={"label": "b"},
                               headers=_auth(ROOT))).json()["token"]

        assert (await client.delete(f"/api/tokens/{a}", headers=_auth(ROOT))).status_code == 200

        assert (await client.get("/api/rooms", headers=_auth(a))).status_code == 401
        assert (await client.get("/api/rooms", headers=_auth(b))).status_code == 200
        assert (await client.get("/api/rooms", headers=_auth(ROOT))).status_code == 200


@pytest.mark.asyncio
async def test_revoke_keeps_the_record(tmp_path):
    """刪掉列就查不到「這個人曾經有權限」，而那正是事後要回答的問題。"""
    app, client = await _make(tmp_path, "record")
    async with app.router.lifespan_context(app), client:
        t = (await client.post("/api/tokens", json={"label": "米勒"},
                               headers=_auth(ROOT))).json()["token"]
        await client.delete(f"/api/tokens/{t}", headers=_auth(ROOT))

        r = await client.get("/api/tokens", headers=_auth(ROOT))
        assert r.json()["tokens"] == []

        r = await client.get("/api/tokens", params={"include_revoked": True},
                             headers=_auth(ROOT))
        row = next(x for x in r.json()["tokens"] if x["token"] == t)
        assert row["revoked"] is True
        assert row["label"] == "米勒"


@pytest.mark.asyncio
async def test_guest_token_cannot_mint_or_revoke(tmp_path):
    """任何 token 都能再發 token 的話，撤銷就形同虛設——被撤掉的人早就
    自己發了一張新的。"""
    app, client = await _make(tmp_path, "mint")
    async with app.router.lifespan_context(app), client:
        guest = (await client.post("/api/tokens", json={"label": "g"},
                                   headers=_auth(ROOT))).json()["token"]

        r = await client.post("/api/tokens", json={"label": "偷發的"},
                              headers=_auth(guest))
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "root_token_required"

        r = await client.delete(f"/api/tokens/{guest}", headers=_auth(guest))
        assert r.status_code == 403

        # 列出也要擋：那等於把所有人的 token 明碼交出去
        assert (await client.get("/api/tokens", headers=_auth(guest))).status_code == 403


@pytest.mark.asyncio
async def test_last_used_at_is_recorded(tmp_path):
    """主持人要看得出哪張還在用、哪張可以收掉。"""
    app, client = await _make(tmp_path, "lastused")
    async with app.router.lifespan_context(app), client:
        t = (await client.post("/api/tokens", json={"label": "x"},
                               headers=_auth(ROOT))).json()["token"]
        row = (await client.get("/api/tokens", headers=_auth(ROOT))).json()["tokens"][0]
        assert row["last_used_at"] is None

        await client.get("/api/rooms", headers=_auth(t))
        row = (await client.get("/api/tokens", headers=_auth(ROOT))).json()["tokens"][0]
        assert row["last_used_at"] is not None


@pytest.mark.asyncio
async def test_bad_token_is_still_401(tmp_path):
    app, client = await _make(tmp_path, "bad")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/rooms", headers=_auth("nope-not-a-real-token"))
        assert r.status_code == 401
        assert r.json()["detail"]["code"] == "invalid_token"


@pytest.mark.asyncio
async def test_open_hub_refuses_to_issue_invites(tmp_path):
    """沒設主 token 時整台 Hub 本來就沒有門，再發邀請只是製造安全感。"""
    app, client = await _make(tmp_path, "open", token="")
    async with app.router.lifespan_context(app), client:
        r = await client.post("/api/tokens", json={"label": "x"})
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "auth_disabled"


@pytest.mark.asyncio
async def test_revoke_twice_is_404(tmp_path):
    app, client = await _make(tmp_path, "twice")
    async with app.router.lifespan_context(app), client:
        t = (await client.post("/api/tokens", json={"label": "x"},
                               headers=_auth(ROOT))).json()["token"]
        assert (await client.delete(f"/api/tokens/{t}", headers=_auth(ROOT))).status_code == 200
        assert (await client.delete(f"/api/tokens/{t}", headers=_auth(ROOT))).status_code == 404


@pytest.mark.asyncio
async def test_root_token_is_never_listed_or_revocable(tmp_path):
    """主 token 是主持人自己的鑰匙，弄丟了整台 Hub 就進不去。"""
    app, client = await _make(tmp_path, "root")
    async with app.router.lifespan_context(app), client:
        r = await client.get("/api/tokens", params={"include_revoked": True},
                             headers=_auth(ROOT))
        assert all(x["token"] != ROOT for x in r.json()["tokens"])

        assert (await client.delete(f"/api/tokens/{ROOT}",
                                    headers=_auth(ROOT))).status_code == 404
        assert (await client.get("/api/rooms", headers=_auth(ROOT))).status_code == 200
