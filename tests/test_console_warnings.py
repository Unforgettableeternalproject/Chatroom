"""警告要落在人盯著的地方（`ccd538ec`）。

2026-09-06 測試端指出 `debug_endpoints_enabled` 的 WARNING 只落 `hub.jsonl`。
追下去發現那不是單一則訊息的落點問題：`chatroom` logger 只掛
`RotatingFileHandler`，沒有任何 `StreamHandler`；`propagate=True` 但 root
沒有 handler（uvicorn 的 dictConfig 只設 `uvicorn.*`，不碰 root）。

**所以這個 logger 的每一則 WARNING 在真進程主控台都是看不見的。**

這條為什麼要緊，`config.py` 自己寫過答案——`purge_archived_days` 的註解
說「所以 Hub 啟動時會把這件事印出來，拉了新版起來的人不該在房間開始消失
之後才知道有這個設定」。那個意圖失效了：永久刪除房間的預告只寫進了 jsonl。

警告有寫、沒人看得到、而且不會有任何跡象告訴你它沒被看到。

⚠️ **只收 WARNING 以上。** INFO 全上主控台會把它洗成噪音，而噪音等於沒有
警告——那正是這條想解決的問題的另一種形狀。
"""

import logging
import sys

import pytest

from chatroom_server.app import create_app
from chatroom_server.config import Config


@pytest.fixture
def app(tmp_path):
    return create_app(Config(db_path=str(tmp_path / "c.db"), api_token="t",
                             log_dir=str(tmp_path / "logs")))


def _console_handlers(logger):
    """掛在這個 logger 上、寫到主控台的 handler。

    檔案 handler 是 StreamHandler 的子類別，所以不能只用 isinstance 判——
    要看它的 stream 是不是 stdout／stderr。
    """
    out = []
    for h in logger.handlers:
        if isinstance(h, logging.StreamHandler) and not isinstance(
                h, logging.FileHandler):
            if getattr(h, "stream", None) in (sys.stdout, sys.stderr):
                out.append(h)
    return out


def test_warnings_reach_the_console(app):
    """`chatroom` logger 要有一個寫主控台的 handler。"""
    assert _console_handlers(logging.getLogger("chatroom"))


def test_it_is_warning_and_above_only(app):
    """門檻是 WARNING——INFO 全上會把警告洗掉。"""
    handlers = _console_handlers(logging.getLogger("chatroom"))
    assert handlers
    assert all(h.level == logging.WARNING for h in handlers)


def test_it_goes_to_stderr_not_stdout(app):
    """走 stderr：stdout 是 Hub 的正常輸出，警告不該混進去被管線吃掉。"""
    for h in _console_handlers(logging.getLogger("chatroom")):
        assert h.stream is sys.stderr


def test_repeated_create_app_does_not_stack_handlers(tmp_path):
    """反覆 `create_app` 只該有一個——疊上去的話每則警告會印 N 次。

    檔案 handler 已經處理過這件事（測試會反覆建 app），主控台那個同理。
    """
    for i in range(3):
        create_app(Config(db_path=str(tmp_path / f"{i}.db"), api_token="t",
                          log_dir=str(tmp_path / f"logs{i}")))
    assert len(_console_handlers(logging.getLogger("chatroom"))) == 1
