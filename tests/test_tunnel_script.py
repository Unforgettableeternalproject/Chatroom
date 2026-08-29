"""tunnel.py 的純函式：轉發目標解析與 token 守門。

隧道腳本不進 CI 的執行路徑，但它的判斷錯了會以「502／連不上」的形式出現，
看起來像網路問題——那種誤導很貴，值得把判斷本身釘住。
"""

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "tunnel_script", ROOT / "scripts" / "tunnel.py"
)
tunnel = importlib.util.module_from_spec(_spec)
sys.modules["tunnel_script"] = tunnel
_spec.loader.exec_module(tunnel)


@pytest.mark.parametrize("host,expected", [
    # 綁所有介面：loopback 一定通，用它最安全
    ("0.0.0.0", "127.0.0.1"),
    ("::", "127.0.0.1"),
    ("", "127.0.0.1"),
    # 綁特定介面（hub-kit 建議的 VPN IP 設定）：Hub 不監聽 loopback，
    # 轉去 127.0.0.1 就是死路，而症狀只是一個 502
    ("26.176.231.43", "26.176.231.43"),
    ("192.168.1.10", "192.168.1.10"),
])
def test_origin_host_follows_where_hub_actually_listens(host, expected):
    assert tunnel.origin_host({"CHATROOM_HOST": host}, None) == expected


def test_explicit_target_wins():
    assert tunnel.origin_host({"CHATROOM_HOST": "0.0.0.0"}, "10.0.0.5") == "10.0.0.5"


@pytest.mark.parametrize("token", ["", "dev", "secret", "short", "dev-secret-0827"])
def test_weak_tokens_are_refused(token):
    """隧道一開，token 就是公網上唯一的門。"""
    with pytest.raises(SystemExit):
        tunnel.check_token(token)


def test_strong_token_passes():
    tunnel.check_token("JvWdI64LH_IYkZBaUxryuHB1rttr2ZVh")


def test_isolation_args_cover_both_leftovers():
    """只隔離 config.yml 不夠——cert.pem 由 --origincert 決定（實測踩過）。"""
    args = tunnel.isolation_args()
    assert "--config" in args
    assert "--origincert" in args


def test_env_vars_win_over_dotenv(monkeypatch):
    """Hub 啟動時真實環境變數優先、.env 只補缺——隧道必須用同一套語意。

    否則「用環境變數啟動 Hub」這條合法路徑上，Hub 聽在 A、隧道轉到 B，
    而兩邊各自看起來都正常。
    """
    monkeypatch.setenv("CHATROOM_HOST", "10.1.2.3")
    assert tunnel.origin_host({"CHATROOM_HOST": "0.0.0.0"}, None) == "10.1.2.3"
    monkeypatch.setenv("CHATROOM_PORT", "9999")
    assert tunnel.setting({"CHATROOM_PORT": "8787"}, "CHATROOM_PORT") == "9999"


def test_dotenv_used_when_env_var_absent(monkeypatch):
    monkeypatch.delenv("CHATROOM_HOST", raising=False)
    assert tunnel.origin_host({"CHATROOM_HOST": "26.0.0.1"}, None) == "26.0.0.1"
