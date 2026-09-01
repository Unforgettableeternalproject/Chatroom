"""WebSocket 要推 board 水位。

`/updates`（agent 走的 long-poll）早就帶 board 水位，**WS 這條沒跟上** ——
於是 agent 改了板，App 的畫面到死都不會動。而 `board_providers.dart` 的
註解寫著「由 /updates 或 WebSocket 捎回的 board_seq 觸發」，那是意圖不是
實作：規格寫了、沒做、沒有任何測試會紅。

**推獨立事件而不是夾在 `messages` 裡**：board 變動不產生訊息，夾帶只在
「剛好同時有訊息」時才送得出去，而那正是最不需要它的時候。

只推水位不推內容——client 拿到號碼自己去做增量讀取，與 `/updates` 同一個
契約，兩條線不會各自演化出一份不同的 board 表示法。
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient
from starlette.testclient import TestClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

ROOT = "root-token"


@pytest.fixture
def app(tmp_path):
    return create_app(Config(db_path=str(tmp_path / "wsboard.db"), api_token=ROOT))


async def _setup(app):
    """建房 + 加入，回傳 (room_id, participant_id)。"""
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://t",
                           headers={"Authorization": f"Bearer {ROOT}"}) as c:
        async with app.router.lifespan_context(app):
            rid = (await c.post("/api/rooms", json={
                "name": "板子房", "session_key": "owner"})).json()["id"]
            pid = (await c.post(f"/api/rooms/{rid}/join", json={
                "kind": "claude", "role": "agent", "session_key": "agent-1",
                "preferred_name": "Novia"})).json()["participant_id"]
            return rid, pid


def _read_until(ws, wanted: str, tries: int = 12) -> dict | None:
    """讀到指定型別的事件為止。

    ⚠️ **退化時這裡會卡住而不是斷言失敗**（`receive_text` 是阻塞的，而
    board 事件不存在時就沒有下一則可讀）。實測把推送那段換成 `if False:`
    的結果是整個檔案 timeout——CI 上仍然是紅的，但症狀是逾時不是斷言。
    看到這個檔案卡住，先去看 WS 的 board 推送還在不在。
    """
    for _ in range(tries):
        msg = json.loads(ws.receive_text())
        if msg.get("type") == wanted:
            return msg
    return None


@pytest.mark.asyncio
async def test_subscribe_pushes_the_current_watermark(app):
    """訂閱後第一輪就要推一次目前水位。

    client 要先知道「這條線是通的、我現在在哪裡」，之後才有得比對。
    用 0 當初始值的話，空板永遠不會收到第一則，看起來與「沒接上」一樣。
    """
    rid, pid = await _setup(app)
    with TestClient(app) as tc:
        with tc.websocket_connect(f"/ws?token={ROOT}") as ws:
            ws.send_text(json.dumps({
                "type": "subscribe", "room_id": rid,
                "after_seq": 0, "participant_id": pid}))
            msg = _read_until(ws, "board")
            assert msg is not None, "訂閱後沒有收到 board 事件"
            assert msg["room_id"] == rid
            assert msg["board_seq"] == 0


@pytest.mark.asyncio
async def test_board_change_is_pushed_without_any_message(app):
    """board 變動不進訊息流——夾在 messages 裡的話這一則永遠送不出去。"""
    rid, pid = await _setup(app)
    with TestClient(app) as tc:
        with tc.websocket_connect(f"/ws?token={ROOT}") as ws:
            ws.send_text(json.dumps({
                "type": "subscribe", "room_id": rid,
                "after_seq": 0, "participant_id": pid}))
            first = _read_until(ws, "board")
            assert first["board_seq"] == 0

            r = tc.post(f"/api/rooms/{rid}/board/objectives",
                        json={"title": "週期一"},
                        headers={"Authorization": f"Bearer {ROOT}",
                                 "X-Participant-Id": pid})
            assert r.status_code == 200, r.text

            nxt = _read_until(ws, "board")
            assert nxt is not None, "board 變動沒有被推出去"
            assert nxt["board_seq"] > first["board_seq"]


@pytest.mark.asyncio
async def test_board_event_carries_only_the_watermark(app):
    """只推水位不推內容——內容由 client 拿號碼去做增量讀取。

    推內容的話 WS 與 /updates 會各自演化出一份 board 表示法，而它們遲早
    會不一致；不一致的那一天沒有任何地方會報錯。
    """
    rid, pid = await _setup(app)
    with TestClient(app) as tc:
        with tc.websocket_connect(f"/ws?token={ROOT}") as ws:
            ws.send_text(json.dumps({
                "type": "subscribe", "room_id": rid,
                "after_seq": 0, "participant_id": pid}))
            msg = _read_until(ws, "board")
            assert set(msg) == {"type", "room_id", "board_seq"}
