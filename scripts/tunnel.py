"""把本機 Hub 經 Cloudflare Quick Tunnel 轉發到公網（給外部 agent 協作用）。

    python scripts/tunnel.py              # 讀 server/.env 的 port，起隧道
    python scripts/tunnel.py --port 8787  # 指定埠
    python scripts/tunnel.py --check      # 只檢查 cloudflared 是否就緒

Quick Tunnel 不需要 Cloudflare 帳號、不需要網域、不需要任何設定——起來就給一個
`https://<隨機>.trycloudflare.com` 網址，關掉就沒了。代價是**每次重啟網址都會變**，
所以成員的 `CHATROOM_URL` 每次都要重發。要固定網址請改用 named tunnel（見 README）。

cloudflared 找不到時會自動下載官方單檔執行檔到 kit 內的 `bin/`，不動系統環境。

⚠️ 隧道一開，Hub 就在公網上，唯一的門是 `CHATROOM_TOKEN`。弱 token 等於沒有門，
本腳本會在起隧道前擋下明顯過弱的值。
"""

from __future__ import annotations

import argparse
import http.client
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / "server" / ".env"
BIN_DIR = ROOT / "bin"
URL_FILE = ROOT / "server" / ".tunnel-url"

# 官方 release 的固定下載點（latest 永遠指向最新穩定版）
RELEASE = "https://github.com/cloudflare/cloudflared/releases/latest/download"
ASSETS = {
    ("Windows", "AMD64"): "cloudflared-windows-amd64.exe",
    ("Windows", "ARM64"): "cloudflared-windows-arm64.exe",
    ("Linux", "x86_64"): "cloudflared-linux-amd64",
    ("Linux", "aarch64"): "cloudflared-linux-arm64",
}

QUICK_URL_RE = re.compile(r"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com")

# 明顯是佔位／開發用的 token——公網上等同無防護，一律擋下
WEAK_TOKENS = {"", "dev", "test", "token", "secret", "changeme", "password"}
MIN_TOKEN_LEN = 16


def read_env() -> dict[str, str]:
    """讀 server/.env（不覆寫已存在的環境變數，與 server 端載入器同語意）。"""
    values: dict[str, str] = {}
    if not ENV_FILE.exists():
        return values
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def setting(env: dict[str, str], key: str, default: str = "") -> str:
    """讀一個 Hub 設定值，語意與 Hub 啟動時一致：**真實環境變數優先，.env 只補缺**。

    只讀 .env 會在「用環境變數啟動 Hub」這條合法路徑上算出錯的位址與埠——
    Hub 聽在 A，隧道轉到 B，而兩邊各自看起來都沒問題。
    """
    return os.environ.get(key) or env.get(key, "") or default


def origin_host(env: dict[str, str], override: str | None) -> str:
    """隧道要轉發到哪個位址。

    不能寫死 127.0.0.1——hub-kit 明確支援（也建議）把 Hub 綁在 VPN 介面 IP，
    例如 CHATROOM_HOST=26.176.231.43。那種設定下 Hub **不會**監聽 loopback，
    轉到 127.0.0.1 就是連不上，而 cloudflared 只會回 502，看起來像隧道壞了。
    只有 0.0.0.0 / :: （所有介面）才保證 loopback 也通。
    """
    if override:
        return override
    host = setting(env, "CHATROOM_HOST").strip()
    if not host or host in ("0.0.0.0", "::", "*"):
        return "127.0.0.1"
    return host


def check_token(token: str) -> None:
    """公網暴露前的最後一道檢查：token 夠不夠格當唯一的門。"""
    lowered = token.strip().lower()
    weak = (
        lowered in WEAK_TOKENS
        or len(token.strip()) < MIN_TOKEN_LEN
        or lowered.startswith("dev-")
    )
    if not weak:
        return
    raise SystemExit(
        f"""
❌ CHATROOM_TOKEN 太弱，拒絕開啟公網隧道。

  目前值長度 {len(token.strip())}，隧道一開任何人都能嘗試連上這個 Hub，
  而 token 是唯一的門——弱 token 等於沒有門。

  換一個高熵值後重試：
    python -c "import secrets; print(secrets.token_urlsafe(24))"
  寫進 {ENV_FILE} 的 CHATROOM_TOKEN=，重啟 Hub，並把新 token 發給成員。

  （只在完全隔離的內網測試時，可用 --i-know-its-public 跳過這道檢查）
"""
    )


def asset_name() -> str:
    key = (platform.system(), platform.machine())
    if key in ASSETS:
        return ASSETS[key]
    raise SystemExit(
        f"沒有對應 {key[0]}/{key[1]} 的 cloudflared 自動下載來源。\n"
        "請自行安裝後重試（macOS：brew install cloudflared）。"
    )


def local_binary() -> Path:
    name = "cloudflared.exe" if os.name == "nt" else "cloudflared"
    return BIN_DIR / name


def find_cloudflared(auto_download: bool) -> str:
    """回傳可執行的 cloudflared 路徑：系統已裝優先，否則抓到 kit 的 bin/。"""
    found = shutil.which("cloudflared")
    if found:
        return found
    local = local_binary()
    if local.exists():
        return str(local)
    if not auto_download:
        raise SystemExit(
            "找不到 cloudflared。加 --download 讓本腳本自動抓官方執行檔，"
            "或自行安裝後重試。"
        )
    url = f"{RELEASE}/{asset_name()}"
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    print(f"下載 cloudflared…（{url}）")
    tmp = local.with_suffix(local.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as resp, tmp.open("wb") as fh:
            shutil.copyfileobj(resp, fh)
    except OSError as exc:
        tmp.unlink(missing_ok=True)  # 半截檔留著會讓下次誤判為已下載
        raise SystemExit(f"下載失敗：{exc}") from exc
    tmp.replace(local)
    if os.name != "nt":
        local.chmod(0o755)
    print(f"已存到 {local}")
    return str(local)


def isolation_args() -> list[str]:
    """把 quick tunnel 與這台機器上既有的 cloudflared 設定完全隔開。

    這台機器若為別的用途用過 cloudflared（本專案的 PM 架構就建過 named
    tunnel），quick tunnel 會被那些殘留設定污染。**兩者都會讓 cloudflared
    照樣跟 Cloudflare 要到 trycloudflare 網址並印出來，實際隧道卻沒建立**：

    - ``~/.cloudflared/config.yml``：沒給 ``--config`` 時自動載入，別人的
      ``credentials-file`` / ``tunnel`` 被一併帶進來
    - ``~/.cloudflared/cert.pem``：**登入過帳號就會留下**，而 ``--config``
      擋不掉它——它由 ``--origincert`` 決定，預設就指到家目錄那份

    症狀是網址看起來完全正常，公網請求卻 404 或連 DNS 都解不出來，origin
    一個請求也收不到，全程零錯誤訊息。2026-08-29 實測：只給 ``--config``
    仍然不通，補上 ``--origincert`` 指向不存在的檔案後立刻 200。

    quick tunnel 本來就不需要帳號憑證，指向不存在的路徑是安全的。
    """
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    config = BIN_DIR / "quick-tunnel.yml"
    # 內容刻意只有無害的一行——重點是「有指定 --config」，讓自動載入不生效
    config.write_text("no-autoupdate: true\n", encoding="utf-8")
    # 這個檔刻意不建立：存在與否不影響 quick tunnel，只要不是帳號那份就好
    no_account = BIN_DIR / "no-account.pem"
    return ["--config", str(config), "--origincert", str(no_account)]


def probe(url: str, timeout: float = 15.0) -> tuple[int, bytes]:
    """打一次 /api/health，回傳 (狀態碼, 回應內容前 512 bytes)；連不上回 (0, b"")。"""
    req = urllib.request.Request(f"{url}/api/health", method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(512)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(512)
    except OSError:
        return 0, b""


def probe_family(host: str, family: int, timeout: float = 15.0) -> tuple[int, bytes]:
    """指定 IPv4 或 IPv6 打一次 /api/health。

    兩族都要試：實測過一台機器 IPv6 比 IPv4 快十倍，也遇過本機只解得到 AAAA
    而沒有 IPv6 出口的情況——只測一邊會把好的隧道判成壞的。
    """
    try:
        infos = socket.getaddrinfo(host, 443, family, socket.SOCK_STREAM)
    except OSError:
        return 0, b""
    if not infos:
        return 0, b""
    ip = infos[0][4][0]
    conn = http.client.HTTPSConnection(
        host, 443, timeout=timeout, context=ssl.create_default_context()
    )
    # 連線走指定的那個 IP，但 SNI 與 Host 仍是主機名——等同 curl --resolve，
    # 藉此繞過本機 DNS 的偏好順序，各族分別驗證
    conn._create_connection = (  # type: ignore[method-assign]
        lambda address, tmo, source: socket.create_connection((ip, 443), tmo)
    )
    try:
        conn.request("GET", "/api/health", headers={"Host": host})
        resp = conn.getresponse()
        return resp.status, resp.read(512)
    except OSError:
        return 0, b""
    finally:
        conn.close()


def verify(url: str, port: str, target: str = "127.0.0.1") -> None:
    """盡力自我檢查，但**不宣告自己證明不了的事**。

    這個檢查是從跑 cloudflared 的那台機器上打自己的公網網址，那條路徑與真實
    使用者的不一樣，會被三種與隧道無關的本機因素打斷：本機 DNS 的族別偏好、
    路由器不支援 hairpin 回流、本機代理或 hosts。實測踩過——隧道從外部完全
    正常，本機卻怎麼打都不通，於是白等了十幾分鐘「冷卻」去修一個不存在的問題。

    所以失敗一律只說「本機自檢未通過」，並請人從外部確認；能斷言的只有成功
    那一側。反過來說，本機通也不代表外面通——origin 本機是最不可能失敗的
    視角，它是下限而非保證。

    判準用回應內容而不只是狀態碼：隧道沒接上時 Cloudflare 自己回 404，而
    origin 對未知路徑往往也回 404，只比狀態碼的話兩者一模一樣。
    """
    local_code, local_body = probe(f"http://{target}:{port}", timeout=5.0)
    if local_code == 0:
        print(
            f"⚠️ {target}:{port} 沒有回應——Hub 還沒啟動，或它綁在別的位址上？"
            "隧道會照常掛著，但對方連進來只會拿到錯誤。",
            file=sys.stderr, flush=True,
        )
        return
    host = url.split("://", 1)[-1]
    # quick tunnel 剛建立時 edge 需要幾秒收斂，失敗不立刻定罪
    remote_code, remote_body = 0, b""
    # 邊緣收斂實測要數十秒，窗口太短會在隧道其實正常時就先喊失敗
    for delay in (0, 5, 10, 20):
        if delay:
            time.sleep(delay)
        attempts = [
            probe(url),
            probe_family(host, socket.AF_INET),
            probe_family(host, socket.AF_INET6),
        ]
        for remote_code, remote_body in attempts:
            if remote_code == local_code and remote_body == local_body:
                print(
                    f"✅ 隧道連通確認（/api/health → HTTP {remote_code}）", flush=True
                )
                return
        remote_code, remote_body = attempts[0]
    # 兩種形狀的下一步完全不同，混在一起講會把人帶往錯的方向
    if remote_code == 0:
        diagnosis = """  本機連不到這個網址（IPv4 與 IPv6 都試過了）。**這多半是本機的事，不是隧道的事**
  ——從自己的機器繞回自己的公網網址常常走不通（路由器不支援 hairpin 回流、
  本機 DNS 只解到沒有出口的那一族、代理或 hosts 攔截）。實測遇過隧道從外部
  完全正常、本機卻怎麼打都不通的情況。

  → 請找一台**別的機器或手機的行動網路**打一次：
       curl <上面那個網址>/api/health
     回得出 Hub 的 JSON 就是通的，本訊息可以無視。"""
    else:
        diagnosis = """  網址連得上，但回應不是本機 Hub 的——隧道接到了別的東西。通常是 cloudflared
  沾到這台機器既有的設定（~/.cloudflared 的 config.yml 或 cert.pem），於是
  連線掛在別人的隧道上。本腳本已用 --config + --origincert 隔離，若仍出現，
  請確認沒有其他 cloudflared 進程佔用同一份憑證。"""
    print(
        f"""
⚠️ 本機自檢未通過：直連 {target}:{port} 回 HTTP {local_code}，經隧道回 HTTP {remote_code}。

{diagnosis}

  隧道**照常運作中**，網址仍然有效。這個檢查只證明得了「我這台打不通」，
  證明不了「隧道壞了」——發出去之前請由外部確認一次。
""",
        file=sys.stderr, flush=True,
    )


def pump(proc: subprocess.Popen, token: str, port: str, target: str) -> None:
    """轉印 cloudflared 的輸出，並在網址出現時把連線資訊攤開給使用者。"""
    announced = False
    assert proc.stderr is not None
    for raw in proc.stderr:
        line = raw.rstrip()
        match = QUICK_URL_RE.search(line)
        if match and not announced:
            announced = True
            url = match.group(0)
            URL_FILE.write_text(url + "\n", encoding="utf-8")
            print(banner(url, token, port, target), flush=True)
            # 驗證要另起執行緒——這裡還在讀 cloudflared 的 stderr，
            # 卡住它等於把隧道自己的日誌塞死
            threading.Thread(
                target=verify, args=(url, port, target), daemon=True
            ).start()
        else:
            print(f"[cloudflared] {line}", file=sys.stderr, flush=True)


# 授權範圍的唯一文案來源。banner 與 --check 共用同一份，避免兩處漂移
# ——先前分散在四個地方，其中兩個漏掉了「已封存房間」與「成員清單」。
SECURITY_WARNING = """🔐 開之前先確認你接受這個授權範圍：

  token 是 Hub 的**唯一**守門。持有它的人可以讀取**所有房間**的
  成員清單（含誰被移出）、訊息與附件——**包含他沒有加入的房間，
  以及已經封存的房間**。他不需要是任何房間的成員。

  房間是組織方式，**不是隔離邊界**。不要把不該給對方看的東西放進
  別的房間就當作隔開了；已封存的舊房間也一樣讀得到。

  需要真正隔離，請開不同 Hub 實例（各自的 port / token / db）。"""


def banner(url: str, token: str, port: str, target: str) -> str:
    """隧道開通後的輸出。

    警示刻意排在網址與 token **之前**：那兩行一出現，人的下一個動作就是複製
    貼給對方，警示放在後面等於在他已經送出之後才講。
    """
    return f"""
════════════════════════════════════════════════════════════════
✅ 隧道已開通

{SECURITY_WARNING}
────────────────────────────────────────────────────────────────
確認接受以上範圍後，把下面兩行發給要協作的人：

  Hub 位址：{url}
  Token   ：{token}

對方用 chatroom-mcp-kit 安裝時填這兩個值即可（不必在同一個內網）。
已裝好的人改 kit 根目錄 `.env` 的 CHATROOM_URL，然後重開 agent。
────────────────────────────────────────────────────────────────
本機 Hub： http://{target}:{port}　（隧道只是轉發，Hub 仍要跑著）
網址副本： {URL_FILE}
⚠️ 這個網址是臨時的——本視窗一關就失效，重開會拿到不一樣的網址。
   用完請把這個視窗關掉。
════════════════════════════════════════════════════════════════
"""


def main() -> int:
    p = argparse.ArgumentParser(description="把本機 Hub 轉發到 Cloudflare Quick Tunnel")
    p.add_argument("--port", help="Hub 埠號；省略時讀 server/.env，再退回 8787")
    p.add_argument(
        "--target-host",
        help="隧道要轉發到的位址；省略時讀 server/.env 的 CHATROOM_HOST"
             "（綁 0.0.0.0 時用 127.0.0.1）",
    )
    p.add_argument(
        "--no-download", dest="download", action="store_false",
        help="找不到 cloudflared 時直接失敗，不自動下載",
    )
    p.add_argument(
        "--check", action="store_true",
        help="只檢查 cloudflared 與 token 是否就緒，不起隧道",
    )
    p.add_argument(
        "--i-know-its-public", action="store_true",
        help="跳過 token 強度檢查（只在完全隔離的測試環境用）",
    )
    args = p.parse_args()

    env = read_env()
    port = args.port or setting(env, "CHATROOM_PORT", "8787")
    target = origin_host(env, args.target_host)
    token = setting(env, "CHATROOM_TOKEN")
    if not args.i_know_its_public:
        check_token(token)

    exe = find_cloudflared(args.download)
    print(f"cloudflared：{exe}")
    if args.check:
        print("✅ 就緒——可以執行 scripts/tunnel.py 開隧道\n")
        print(SECURITY_WARNING)
        return 0
    print(f"轉發目標：http://{target}:{port}")

    # cloudflared 把包含網址的橫幅寫在 stderr，stdout 幾乎沒東西
    proc = subprocess.Popen(
        [
            exe, *isolation_args(),
            "tunnel", "--url", f"http://{target}:{port}", "--no-autoupdate",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    reader = threading.Thread(
        target=pump, args=(proc, token, port, target), daemon=True
    )
    reader.start()
    print("隧道啟動中…（網址出現前 Hub 就該已經在跑，否則對方連上會拿到 502）")
    try:
        return proc.wait()
    except KeyboardInterrupt:
        # Ctrl+C 已經送到整個 process group，這裡只負責等它收乾淨
        try:
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()
        print("\n隧道已關閉。網址已失效，重開會是新的網址。")
        return 0
    finally:
        URL_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
