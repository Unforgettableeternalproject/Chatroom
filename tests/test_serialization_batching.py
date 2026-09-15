"""訊息序列化不能是 message-level N+1。

`_message_rows_to_json` 對**每一則**訊息各查一次 sender、再各查一次 reply 原文。
一般讀取每次上限 100 則所以不明顯，但匯出會跨過整個房間：一萬則就是額外的
一兩萬次查詢，而它們全走同一條 aiosqlite 連線——long-poll 與即時推播也在那條
連線上，匯出一個大房會把整個房間的即時性拖住。

這裡量的是**查詢次數的成長方式**，不是絕對耗時：耗時會隨機器浮動，次數不會。

（審核用 Codex F8，2026-08-31）
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio


class _CountingDb:
    """數 execute 次數的薄包裝，其餘原樣轉發。"""

    def __init__(self, inner):
        self._inner = inner
        self.queries = 0

    async def execute(self, *args, **kwargs):
        self.queries += 1
        return await self._inner.execute(*args, **kwargs)

    def __getattr__(self, name):
        return getattr(self._inner, name)


def _cfg(tmp_path, name):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token="")


async def _make(tmp_path, name):
    app = create_app(_cfg(tmp_path, name))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _seed(client, room_id, headers, count):
    """每則都回覆前一則——reply preview 是第二條 N+1 的來源。"""
    previous = None
    for i in range(count):
        body = {"content": f"m{i}"}
        if previous:
            body["reply_to"] = previous
        previous = (await client.post(f"/api/rooms/{room_id}/messages",
                                      json=body, headers=headers)).json()["id"]


async def test_export_query_count_does_not_grow_per_message(tmp_path):
    app, client = await _make(tmp_path, "batch")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = (await client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "human", "session_key": "owner",
                  "preferred_name": "Xavier", "role": "human"},
        )).json()
        headers = {"X-Participant-Id": me["participant_id"]}
        await _seed(client, room_id, headers, 40)

        counter = _CountingDb(app.state.db)
        app.state.db = counter
        try:
            r = await client.get(f"/api/rooms/{room_id}/export", headers=headers)
        finally:
            app.state.db = counter._inner

        assert r.status_code == 200, r.text
        lines = [ln for ln in r.text.splitlines() if ln.strip()]
        assert len(lines) >= 40, "沒有真的匯出，下面的次數比較就沒有意義"

        # 批次化之後每批是固定幾次查詢（訊息、附件、sender、reply…）。
        # 逐則查的話 40 則至少 80 次——這個界線刻意寬鬆，抓的是「有沒有隨
        # 則數線性成長」，不是精確次數
        assert counter.queries < 20, (
            f"匯出 {len(lines)} 則用了 {counter.queries} 次查詢，"
            "看起來仍是 message-level N+1"
        )


async def test_reply_previews_survive_the_batching(tmp_path):
    """反向錨點：省查詢不能把內容省掉。

    preload 最容易出的錯是「查了但對不回去」，而那在計數測試上完全看不出來
    ——次數漂亮，內容是空的。
    """
    app, client = await _make(tmp_path, "content")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        me = (await client.post(
            f"/api/rooms/{room_id}/join",
            json={"kind": "human", "session_key": "owner",
                  "preferred_name": "Xavier", "role": "human"},
        )).json()
        headers = {"X-Participant-Id": me["participant_id"]}

        first = (await client.post(f"/api/rooms/{room_id}/messages",
                                   json={"content": "原文"},
                                   headers=headers)).json()["id"]
        await client.post(f"/api/rooms/{room_id}/messages",
                          json={"content": "回覆", "reply_to": first},
                          headers=headers)

        msgs = (await client.get(f"/api/rooms/{room_id}/messages",
                                 headers=headers)).json()["messages"]
        reply = next(m for m in msgs if m["content"] == "回覆")
        assert reply["reply_preview"]["excerpt"] == "原文"
        assert reply["reply_preview"]["sender_name"] == "Xavier"
        assert reply["sender_name"] == "Xavier"
