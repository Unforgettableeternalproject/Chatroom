"""同一個人的第二台裝置：他自己建的私人房不該進不去（艾斯維爾裁 2026-09-12）。

人類在 App 裡的身分是本機產的 `deviceKey`，**每台裝置一把**。私人房的可見度
判的是建立者的 session_key 與成員紀錄，所以同一個人在筆電上建的私人房，
在桌機上既看不到也加入不了——而那是同一個人的東西。

判準是群（見 [tests/test_party_boundary.py]）：貼同一張邀請碼的兩台裝置
本來就是同一個人。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
HUMAN = "human-token"


async def _hub(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 human_api_token=HUMAN)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {HUMAN}"})


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def _invite(host, label):
    r = await host.post("/api/tokens", json={"label": label,
                                             "audience": "human"})
    assert r.status_code == 200, r.text
    return r.json()["token"]


async def _rooms(client, token, key):
    """列房間。順帶讓這台裝置的 session 進名錄（那是心跳點之一）。"""
    r = await client.get("/api/rooms", headers={
        **_auth(token), "X-Session-Key": key}, params={"kind": "human"})
    assert r.status_code == 200, r.text
    return {x["id"] for x in r.json()["rooms"]}


async def test_my_other_device_sees_and_joins_my_private_room(tmp_path):
    app, host = await _hub(tmp_path, "party-private")
    async with app.router.lifespan_context(app), host:
        code = await _invite(host, "艾斯維爾")
        # 兩台裝置貼同一張碼，各自產自己的 deviceKey
        await _rooms(host, code, "human-laptop")
        await _rooms(host, code, "human-desktop")

        rid = (await host.post("/api/rooms", headers={
            **_auth(code), "X-Session-Key": "human-laptop"},
            json={"name": "我的私人房", "visibility": "private",
                  "session_key": "human-laptop"})).json()["id"]

        assert rid in await _rooms(host, code, "human-desktop")
        j = await host.post(f"/api/rooms/{rid}/join", headers={
            **_auth(code), "X-Session-Key": "human-desktop"},
            json={"kind": "human", "role": "human",
                  "session_key": "human-desktop"})
        assert j.status_code == 200, j.text


async def test_sharing_the_root_token_does_not_make_you_the_same_person(tmp_path):
    """🚨 **主 token 那一群不算「同一個人」。**

    legacy 模式下 `.env` 的主 token 是所有人共用的那一把（每個 bridge、每個
    還沒拿到邀請的人都用它）。把它當成一個人的話，拿到它的每一個人——**包含
    被踢出去的**——都會看見所有私人房，kick 就此失效。

    指派那一側則相反：`.env` 的兩把就是「這台機器上的我和我的 agent」，
    那正是要放行的。同一個群 id，兩種用途，刻意不同（見 `HOST_PARTY`）。
    """
    app, host = await _hub(tmp_path, "party-root-shared")
    async with app.router.lifespan_context(app), host:
        # 兩個人都拿主 token（legacy 模式的實況）
        await _rooms(host, ROOT, "human-one")
        await _rooms(host, ROOT, "human-two")

        rid = (await host.post("/api/rooms", headers={
            **_auth(ROOT), "X-Session-Key": "human-one"},
            json={"name": "私人", "visibility": "private",
                  "session_key": "human-one"})).json()["id"]

        assert rid not in await _rooms(host, ROOT, "human-two")


async def test_someone_elses_private_room_stays_invisible(tmp_path):
    """放寬的是「同一個人」，不是「同一台 Hub 上的所有人」。"""
    app, host = await _hub(tmp_path, "party-private-other")
    async with app.router.lifespan_context(app), host:
        mine = await _invite(host, "我")
        theirs = await _invite(host, "別人")
        await _rooms(host, mine, "human-mine")
        await _rooms(host, theirs, "human-theirs")

        rid = (await host.post("/api/rooms", headers={
            **_auth(mine), "X-Session-Key": "human-mine"},
            json={"name": "私人", "visibility": "private",
                  "session_key": "human-mine"})).json()["id"]

        assert rid not in await _rooms(host, theirs, "human-theirs")
        j = await host.post(f"/api/rooms/{rid}/join", headers={
            **_auth(theirs), "X-Session-Key": "human-theirs"},
            json={"kind": "human", "role": "human",
                  "session_key": "human-theirs"})
        assert j.status_code == 403, j.text
        assert j.json()["detail"]["code"] == "room_is_private"
