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


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """把 CHATROOM_* 從真實環境清掉，讓每個案例從已知狀態出發。

    `setting()` 刻意讓真實環境變數贏過傳進來的 dict——那是正確的產品語意
    （Hub 用環境變數啟動時，隧道必須跟著真實值走）。代價是這些測試會受
    「這個 pytest 進程的環境長什麼樣」影響，而那不是它們想驗的東西。

    實際踩到的情況：任何測試只要 import 過 chatroom_mcp.server，該模組在
    **import 當下**就會呼叫 load_env_file() 把 server/.env 灌進 os.environ，
    於是 CHATROOM_HOST 變成開發機的實際值，這裡的參數化案例全數失真——
    而單獨跑這個檔案又完全正常，只有整輪跑才會炸（2026-08-29）。
    """
    for key in ("CHATROOM_HOST", "CHATROOM_PORT", "CHATROOM_TOKEN",
                "CHATROOM_URL"):
        monkeypatch.delenv(key, raising=False)


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


# ---------- 授權範圍警示（人工驗收只證明「今天這次看得到」） ----------

# 這些片語各自對應一條實測出來的暴露面。少任何一條，使用者對授權範圍的
# 理解就會與實際不符——而他正要把網址發給別人。
REQUIRED_PHRASES = [
    "所有房間",        # 不限他加入的那個
    "成員清單",        # room detail 會連 status 一起洩露
    "沒有加入",        # 未加入的房間也讀得到
    "已經封存",        # 封存的舊房間照樣可讀，這是暴露面質變的部分
    "不需要是任何房間的成員",
    "不是隔離邊界",
    "不同 Hub 實例",   # 真正的隔離手段
]


@pytest.mark.parametrize("phrase", REQUIRED_PHRASES)
def test_security_warning_states_the_full_scope(phrase):
    assert phrase in tunnel.SECURITY_WARNING


@pytest.mark.parametrize("phrase", REQUIRED_PHRASES)
def test_banner_carries_the_same_warning(phrase):
    """banner 與 --check 必須共用同一份文案，否則兩處會各自漂移。"""
    banner = tunnel.banner("https://x.trycloudflare.com", "TOK", "8787", "127.0.0.1")
    assert phrase in banner


def test_warning_comes_before_the_url_and_token():
    """網址與 token 一出現，人的下一個動作就是複製貼給對方。

    警示排在它們後面，等於在他已經送出之後才講。
    """
    banner = tunnel.banner("https://x.trycloudflare.com", "TOK-VALUE", "8787", "127.0.0.1")
    warning_at = banner.index("不是隔離邊界")
    assert warning_at < banner.index("TOK-VALUE")
    assert warning_at < banner.index("https://x.trycloudflare.com")
    assert warning_at < banner.index("發給"), "也要在任何『發出去』的指示之前"


def test_banner_asks_for_acknowledgement_before_sharing():
    banner = tunnel.banner("https://x.trycloudflare.com", "TOK", "8787", "127.0.0.1")
    assert "確認接受" in banner


def test_banner_shows_the_actual_forward_target():
    """綁 VPN IP 時 banner 若還印 127.0.0.1，排查的人會被帶往錯的方向。"""
    banner = tunnel.banner("https://x.trycloudflare.com", "TOK", "8787", "26.176.231.43")
    assert "26.176.231.43:8787" in banner
