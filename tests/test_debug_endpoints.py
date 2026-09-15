"""除錯端點閘門（`/api/_debug/boom`）。

存在的理由：H16 的「未攔截例外回 500 帶 `error_id`、traceback 落 hub.jsonl」
到今天為止**只有單元測試背書**——而那些測試跑的是 in-process ASGI，量到的
是測試環境的特權，不是「回報問題的人手上看到什麼」。要在真進程上從外部驗
它，就需要一條**已知會炸**的路徑。

`tests/test_unhandled_exception.py` 是在測試裡臨時掛一個 `/api/_boom` 上去，
那條路徑正式進程裡並不存在，所以那份測試永遠驗不到真 Hub。

所以這裡的閘門要守兩件事：

1. **預設關**——沒設環境變數的 Hub 上，那個端點就是不存在（404），
   不是「存在但拒絕」（那會洩漏它的存在）
2. **開了也要 token**——它是刻意留下的洞，不該比其他端點更好進
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"
BOOM = "/api/_debug/boom"


def _cfg(tmp_path, name, **kw):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                  log_dir=str(tmp_path / f"logs-{name}"), **kw)


def _client(app, *, token=ROOT):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    # ⚠️ raise_app_exceptions=False——要驗的正是 HTTP 那一端看到什麼
    return AsyncClient(
        transport=ASGITransport(app=app, raise_app_exceptions=False),
        base_url="http://test", headers=headers)


async def test_the_debug_endpoint_does_not_exist_by_default(tmp_path):
    """預設組態下那條路徑不存在——404，不是 403。

    「存在但拒絕」會告訴打的人這裡有東西，而預設關的意思是連這個都不說。
    """
    cfg = _cfg(tmp_path, "off")
    assert cfg.debug_endpoints is False
    app = create_app(cfg)
    async with _client(app) as client, app.router.lifespan_context(app):
        r = await client.get(BOOM)
    assert r.status_code == 404


async def test_the_gate_opens_only_by_explicit_config(tmp_path):
    """閘門打開後，那條路徑回 500 `internal_error` 且帶 `error_id`。"""
    app = create_app(_cfg(tmp_path, "on", debug_endpoints=True))
    async with _client(app) as client, app.router.lifespan_context(app):
        r = await client.get(BOOM)
    assert r.status_code == 500
    detail = r.json()["detail"]
    assert detail["code"] == "internal_error"
    assert detail["error_id"]
    # 例外訊息不進回應：那道邊界是 H16 的重點，開了除錯端點也不鬆
    assert "測試" not in detail["message"]


async def test_that_same_error_id_reaches_the_log_with_a_traceback(tmp_path):
    """端點炸出來的 `error_id` 在 `hub.jsonl` 裡查得到，而且帶 traceback。

    這是這張卡真正要的東西：一條外部打得到、且兩端串得起來的正向路徑。
    """
    cfg = _cfg(tmp_path, "log", debug_endpoints=True)
    app = create_app(cfg)
    async with _client(app) as client, app.router.lifespan_context(app):
        r = await client.get(BOOM)
    error_id = r.json()["detail"]["error_id"]

    lines = (tmp_path / "logs-log" / "hub.jsonl").read_text(
        encoding="utf-8").splitlines()
    hit = [json.loads(x) for x in lines if error_id in x]
    assert hit, f"hub.jsonl 裡找不到 {error_id}"
    rec = hit[0]
    assert rec["event"] == "unhandled_exception"
    assert rec["path"] == BOOM
    assert "Traceback" in rec.get("exc_info", "") or "Traceback" in json.dumps(
        rec, ensure_ascii=False)


async def test_the_gate_is_not_a_way_around_the_token(tmp_path):
    """開了閘門也還是要 token——它是刻意留的洞，不該比別的端點好進。"""
    app = create_app(_cfg(tmp_path, "auth", debug_endpoints=True))
    async with _client(app, token="") as client, app.router.lifespan_context(app):
        r = await client.get(BOOM)
    assert r.status_code in (401, 403)
