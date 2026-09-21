"""Hub 設定的 `CHATROOM_LOCALE` 要真的走到 join 的名字池。

單元測試只證得了 `generate_name(locale=...)` 自己挑對池子——設定有沒有從
`Config` 傳到那個呼叫點是另一半，而那一半斷掉的話畫面上只會看到「又是中文
名字」，沒有任何錯誤。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.naming import all_names

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, locale):
    cfg = Config(db_path=str(tmp_path / "locale.db"), api_token=ROOT,
                 locale=locale)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def test_join_without_preferred_name_uses_locale_pool(tmp_path):
    app, client = await _client(tmp_path, "en")
    async with app.router.lifespan_context(app), client:
        rid = (await client.post("/api/rooms", json={
            "name": "語言房", "session_key": "human-1"})).json()["id"]
        # 同一間房連進 10 個：混抽時代單抽一次是矇得過去的
        for i in range(10):
            r = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "claude", "session_key": f"agent-{i}"})
            assert r.status_code == 200, r.text
            assert r.json()["display_name"] in all_names("en")
