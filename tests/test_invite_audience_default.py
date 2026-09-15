"""App 發出的邀請碼進不了任何房間（09/12 艾斯維爾實測）。

症狀：拿別人 Hub 的邀請碼連上，房間列表看得到公開房、也收得到邀請，
但點進去一律「你不是這個聊天室的成員」。換成主持人那把 token 就正常。

要害：**發放端不帶 audience，而 server 的預設是 agent**，而 App 進房
一律 `role=human`。分離期的 Hub 於是把每一張 App 發出的邀請碼都擋在
進門那一刻——發的人以為自己給了一把鑰匙，實際上給的是一把進不了任何
房間的鑰匙，而兩者在畫面上完全一樣。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"


async def _split_hub(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 human_api_token=HUMAN)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {HUMAN}"})


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def test_an_invite_without_audience_is_still_an_agent_credential(tmp_path):
    """**server 這一端的保守預設不動**，這條釘住它。

    修的是 App（`tokens_api.dart` 現在明講 `audience: "human"`）。反過來把
    server 預設改成 human 才是真正危險的：那會讓每一個沒帶這個欄位的舊
    client 發出的邀請都變成人類憑證，而沒有人會看見這件事發生。
    """
    app, host = await _split_hub(tmp_path, "invite-default-agent")
    async with app.router.lifespan_context(app), host:
        r = await host.post("/api/tokens", json={"label": "沒講對象"})
        assert r.json()["audience"] == "agent"


async def test_app_issued_invite_can_join_a_public_room(tmp_path):
    """App 的 InviteManager 現在明講這張發給人（`tokens_api.dart`）。"""
    app, host = await _split_hub(tmp_path, "invite-default")
    async with app.router.lifespan_context(app), host:
        rid = (await host.post("/api/rooms", json={
            "name": "公開房", "session_key": "human-host",
            "visibility": "public"})).json()["id"]
        # 主持人在 App 上按「發邀請」——UI 沒有 audience 這個概念
        invite = (await host.post(
            "/api/tokens",
            json={"label": "給艾斯維爾", "audience": "human"})).json()["token"]

        # 受邀者貼上邀請碼，App 進房一律 role=human
        r = await host.post(f"/api/rooms/{rid}/join",
                            headers=_auth(invite),
                            json={"kind": "human", "role": "human",
                                  "session_key": "human-guest",
                                  "preferred_name": "Xavier"})
        assert r.status_code == 200, r.text


async def test_app_issued_invite_reaches_the_board(tmp_path):
    """板的成員來自掛接房的 active 成員——進不了房就沾不到板。"""
    app, host = await _split_hub(tmp_path, "invite-board")
    async with app.router.lifespan_context(app), host:
        rid = (await host.post("/api/rooms", json={
            "name": "公開房", "session_key": "human-host",
            "visibility": "public"})).json()["id"]
        invite = (await host.post(
            "/api/tokens",
            json={"label": "給艾斯維爾", "audience": "human"})).json()["token"]
        j = await host.post(f"/api/rooms/{rid}/join",
                            headers=_auth(invite),
                            json={"kind": "human", "role": "human",
                                  "session_key": "human-guest"})
        assert j.status_code == 200, j.text
        r = await host.get("/api/boards", headers={
            **_auth(invite), "X-Session-Key": "human-guest"})
        assert r.status_code == 200, r.text
