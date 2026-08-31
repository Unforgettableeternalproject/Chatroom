"""WebSocket 的 token 驗證。

`f097230`（08-27）寫這段時 Hub 只有一種 token（`.env` 的主 token），
那時 `token != cfg.api_token` 就拒絕是對的。`bc1d2ed`（08-29）引入可撤銷的
access_token，REST 的 `require_auth` 改成查表——**WS 那條路徑沒跟上**，
於是用邀請碼進來的人 REST 讀得到歷史，卻連不上即時通道。

沒被既有測試擋下的原因：WS 測試不是跑開放模式（`api_token=""`）就是用
「錯的 token」，**沒有一條用「合法但不是主 token」去連**。這份補的正是
那個縫。
"""

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.testclient import TestClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

ROOT = "root-token"


@pytest.fixture
def app(tmp_path):
    return create_app(Config(db_path=str(tmp_path / "ws.db"), api_token=ROOT))


async def _issue_token(app, label="guest") -> str:
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://t",
                           headers={"Authorization": f"Bearer {ROOT}"}) as c:
        async with app.router.lifespan_context(app):
            r = await c.post("/api/tokens", json={"label": label})
            return r.json()["token"]


async def _revoke(app, token: str) -> None:
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://t",
                           headers={"Authorization": f"Bearer {ROOT}"}) as c:
        async with app.router.lifespan_context(app):
            await c.delete(f"/api/tokens/{token}")


def _connects(app, query: str) -> bool:
    with TestClient(app) as tc:
        try:
            with tc.websocket_connect(f"/ws?{query}"):
                return True
        except Exception:
            return False


@pytest.mark.asyncio
async def test_access_token_can_connect(app):
    """發出去的邀請碼要連得上——否則那個人讀得到歷史卻收不到任何新訊息。

    在使用者眼中那不是「權限不足」，是「這個聊天室好像死了」。
    """
    tok = await _issue_token(app)
    assert _connects(app, f"token={tok}") is True


@pytest.mark.asyncio
async def test_revoked_token_cannot_connect(app):
    """撤銷要對 WS 生效。只擋 REST 的話，被撤銷的人照樣即時收得到整個房間
    ——那正是「踢出擋不住人」那次的形狀（08-29），不可以在這裡重演。"""
    tok = await _issue_token(app)
    await _revoke(app, tok)
    assert _connects(app, f"token={tok}") is False


@pytest.mark.asyncio
async def test_root_token_and_garbage(app):
    assert _connects(app, f"token={ROOT}") is True
    assert _connects(app, "token=nonsense") is False
    assert _connects(app, "") is False


@pytest.mark.asyncio
async def test_host_view_on_ws_requires_root_token(app):
    """🚨 主持人視角不可以被 access_token 打開。

    在 WS 只收主 token 的年代，`host_view=1` 靠「非主 token 根本連不上」
    才是安全的。放寬連線驗證的那一刻，那個假設就沒了——所以這兩件事必須
    在同一個 commit 裡改，中間不存在有洞的狀態。

    這裡驗的是：拿 access_token 帶 host_view=1 連上之後，訂閱一個自己
    沒份的房仍然被擋。
    """
    tok = await _issue_token(app)
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://t",
                           headers={"Authorization": f"Bearer {ROOT}"}) as c:
        async with app.router.lifespan_context(app):
            rid = (await c.post("/api/rooms", json={
                "name": "別人的房", "session_key": "someone-else"})).json()["id"]
            # 房裡要有東西可推。**完全空的房會讓 receive_json() 永遠等下去**
            # ——pump 沒有訊息可送就直接掛在 events.wait 上，那不是失敗，
            # 是測試本身寫錯了（我第一版就是這樣把自己掛住的）
            await c.post(f"/api/rooms/{rid}/join", json={
                "kind": "human", "role": "human",
                "session_key": "someone-else", "preferred_name": "Owner"})

    with TestClient(app) as tc:
        with tc.websocket_connect(f"/ws?token={tok}&host_view=1") as ws:
            ws.send_json({"type": "subscribe", "room_id": rid, "after_seq": 0})
            evt = ws.receive_json()
            assert evt["type"] == "error", evt
            assert evt["code"] in ("participant_header_required", "not_a_member")

    # 對照組：主 token 帶 host_view=1 訂得到
    with TestClient(app) as tc:
        with tc.websocket_connect(f"/ws?token={ROOT}&host_view=1") as ws:
            ws.send_json({"type": "subscribe", "room_id": rid, "after_seq": 0})
            evt = ws.receive_json()
            assert evt["type"] == "messages", evt
