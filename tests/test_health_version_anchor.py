"""`/api/health` 回的 build 必須凍在**啟動當下**，不跟著工作樹跑。

2026-09-05：8787 的 health 回 `fbcc174559c2`（乾淨），而同一時刻工作樹是
`fbcc174` + 4 個髒檔——正確，但那份正確**沒有任何測試守著**。

機制是隱式的：`build_info()` 有 `lru_cache`，而 `create_app` 的 lifespan
裡那句 `info = build_info()` 剛好是啟動後第一個呼叫它的地方，於是版本被凍在
啟動當下。拿掉那一句，health 就變成「現查 git HEAD」——一台跑著舊碼的 Hub
會回報新 commit，**而且不會有任何地方報錯**。

⚠️ 這條測試釘的是那個隱式保證，不是 `lru_cache` 本身。驗證方式（2026-09-05
實跑）：不經 `lifespan_context` 直接打 health，拿到的就是「啟動後才變的」那個
值 ⇒ 斷言失敗。也就是說，啟動時那次呼叫一旦消失，這裡必紅。
"""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server import version as V
from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
AT_STARTUP = "1111aaaa2222"
AFTER_THE_TREE_MOVED = "9999zzzz8888"


def _git_says(commit: str) -> dict[str, str]:
    return {"version": "1.1.5", "commit": commit, "built_at": "",
            "source": "git"}


@pytest.fixture(autouse=True)
def _fresh_process():
    """每條測試都從「全新進程」開始，並且不把快取留給別人。"""
    V.build_info.cache_clear()
    yield
    V.build_info.cache_clear()


async def test_health_build_is_frozen_at_startup(tmp_path, monkeypatch):
    # 啟動前的樹
    monkeypatch.setattr(V, "_from_git", lambda: _git_says(AT_STARTUP))
    monkeypatch.setattr(V, "_from_build_file", lambda: None)

    cfg = Config(db_path=str(tmp_path / "anchor.db"), api_token=ROOT)
    app = create_app(cfg)
    client = AsyncClient(transport=ASGITransport(app=app),
                         base_url="http://test",
                         headers={"Authorization": f"Bearer {ROOT}"})

    async with app.router.lifespan_context(app), client:
        # 進程沒重啟，但工作樹前進了（有人 commit、有人改檔）
        monkeypatch.setattr(V, "_from_git",
                            lambda: _git_says(AFTER_THE_TREE_MOVED))

        body = (await client.get("/api/health")).json()

    assert body["build"]["commit"] == AT_STARTUP, (
        "health 跟著工作樹跑了——啟動時那次 build_info() 呼叫可能被拿掉了，"
        "而那一句是 health 版本定錨的唯一來源"
    )
