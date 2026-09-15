"""Hub 回答「外面的人要連哪個位址」（2026-09-12 艾斯維爾實測）。

邀請碼裡的位址原本取自**發邀請那個人自己的 App 設定**。他就在 Hub 那台
機器上，填的是 `127.0.0.1`——對他完全正常，對收到邀請的人是一個永遠連不上
的位址，而且**兩邊都不會看到任何錯誤**：對方貼進 App 之後，所有請求靜靜地
連到他自己的電腦。

「主持人怎麼連」與「別人怎麼連」從來沒有被分開過。隧道網址其實一直被寫在
`server/.tunnel-url`（`scripts/tunnel.py` 開隧道時寫、關掉時刪），只是沒有
人讀它。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

TUNNEL = "https://mae-sensitive-roads-cleared.trycloudflare.com"


async def _client(tmp_path):
    cfg = Config(db_path=str(tmp_path / "chatroom.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test"), cfg


async def _public_url(client):
    r = await client.get("/api/health")
    assert r.status_code == 200, r.text
    return r.json()["public_url"]


async def test_no_tunnel_means_no_public_url(tmp_path):
    app, client, _ = await _client(tmp_path)
    async with app.router.lifespan_context(app), client:
        assert await _public_url(client) == ""


async def test_the_tunnel_url_file_is_reported(tmp_path):
    """檔案就在 DB 旁邊——tunnel.py 寫 `server/.tunnel-url`，而 DB 預設也在
    `server/`。兩邊要對得起來，所以位置跟著 db_path 走。"""
    app, client, cfg = await _client(tmp_path)
    cfg.tunnel_url_file.write_text(TUNNEL + "\n", encoding="utf-8")
    async with app.router.lifespan_context(app), client:
        assert await _public_url(client) == TUNNEL


async def test_it_is_read_fresh_every_time(tmp_path):
    """🚨 **不可以快取。**

    quick tunnel 每次重啟都換網址，而 Hub 不會跟著重啟。快取住的話它會很有
    自信地報一個已經死掉的位址——那比沒有值更糟，因為拿到它的人會照著發
    邀請，而錯誤要等對方連不上才浮現。
    """
    app, client, cfg = await _client(tmp_path)
    async with app.router.lifespan_context(app), client:
        assert await _public_url(client) == ""
        cfg.tunnel_url_file.write_text(TUNNEL, encoding="utf-8")
        assert await _public_url(client) == TUNNEL
        # 隧道關掉：tunnel.py / stop-tunnel.py 都會刪掉這個檔
        cfg.tunnel_url_file.unlink()
        assert await _public_url(client) == ""


async def test_garbage_in_the_file_is_not_handed_out(tmp_path):
    """那個檔是**別的進程**寫的，而這個值會被 App 直接拿去當連線位址。"""
    app, client, cfg = await _client(tmp_path)
    async with app.router.lifespan_context(app), client:
        for junk in ("", "   ", "錯誤訊息：cloudflared 起不來",
                     "javascript:alert(1)"):
            cfg.tunnel_url_file.write_text(junk, encoding="utf-8")
            assert await _public_url(client) == ""
