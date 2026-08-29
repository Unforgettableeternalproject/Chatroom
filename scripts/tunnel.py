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
import os
import platform
import re
import shutil
import signal
import subprocess
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


def isolated_config() -> Path:
    """產生一份專用設定檔，擋掉 cloudflared 對使用者既有設定的自動載入。

    cloudflared 沒給 --config 時會自動讀 ``~/.cloudflared/config.yml``。那台機器
    若為別的用途建過 named tunnel（本專案的 PM 架構就是），該檔的
    ``credentials-file`` / ``tunnel`` 會被一併帶進來——**它照樣跟 Cloudflare 要到
    一個 trycloudflare 網址並印出來，實際連線卻掛在別人的隧道憑證上**。
    症狀是網址看似正常、公網請求穩定 404，origin 一個請求也收不到，
    而全程沒有任何錯誤訊息。2026-08-29 實測踩到。
    """
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    path = BIN_DIR / "quick-tunnel.yml"
    # 內容刻意只有無害的一行——重點是「有指定 --config」，讓自動載入不生效
    path.write_text("no-autoupdate: true\n", encoding="utf-8")
    return path


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


def verify(url: str, port: str) -> None:
    """確認隧道真的接到本機 Hub——網址印得出來不代表它通。

    判準是**比對回應內容**，不只比狀態碼：隧道沒接上時 Cloudflare 自己回 404，
    而 origin 對未知路徑往往也回 404，只比狀態碼的話這兩者一模一樣。內容則不會
    ——一邊是 Cloudflare 的錯誤頁，一邊是 Hub 的回應。
    """
    local_code, local_body = probe(f"http://127.0.0.1:{port}", timeout=5.0)
    if local_code == 0:
        print(
            f"⚠️ 本機 {port} 沒有回應——Hub 還沒啟動嗎？"
            "隧道會照常掛著，但對方連進來只會拿到錯誤。",
            file=sys.stderr, flush=True,
        )
        return
    # quick tunnel 剛建立時 edge 需要幾秒收斂，失敗不立刻定罪
    remote_code, remote_body = 0, b""
    for delay in (0, 5, 10):
        if delay:
            time.sleep(delay)
        remote_code, remote_body = probe(url)
        if remote_code == local_code and remote_body == local_body:
            print(f"✅ 隧道連通確認（/api/health → HTTP {remote_code}）", flush=True)
            return
    print(
        f"""
❌ 隧道沒有接到本機 Hub：直連本機回 HTTP {local_code}，經隧道回 HTTP {remote_code}
   （回應內容{'相同但狀態碼不同' if remote_body == local_body else '不一致'}）。

  網址印得出來**不代表**隧道可用。最常見的成因是 cloudflared 讀到了這台機器
  既有的 ~/.cloudflared/config.yml（為別的用途建過 named tunnel），
  於是連線掛在別人的隧道憑證上。本腳本已用 --config 隔離，若仍出現，
  請檢查是否有其他 cloudflared 進程佔用，或改用 named tunnel。
""",
        file=sys.stderr, flush=True,
    )


def pump(proc: subprocess.Popen, token: str, port: str) -> None:
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
            print(banner(url, token, port), flush=True)
            # 驗證要另起執行緒——這裡還在讀 cloudflared 的 stderr，
            # 卡住它等於把隧道自己的日誌塞死
            threading.Thread(target=verify, args=(url, port), daemon=True).start()
        else:
            print(f"[cloudflared] {line}", file=sys.stderr, flush=True)


def banner(url: str, token: str, port: str) -> str:
    return f"""
════════════════════════════════════════════════════════════════
✅ 隧道已開通——把下面兩行發給要協作的人

  Hub 位址：{url}
  Token   ：{token}

對方用 chatroom-mcp-kit 安裝時填這兩個值即可（不必在同一個內網）。
已裝好的人改 kit 根目錄 `.env` 的 CHATROOM_URL，然後重開 agent。
────────────────────────────────────────────────────────────────
本機 Hub： http://127.0.0.1:{port}　（隧道只是轉發，Hub 仍要跑著）
網址副本： {URL_FILE}
⚠️ 這個網址是臨時的——本視窗一關就失效，重開會拿到不一樣的網址。
════════════════════════════════════════════════════════════════
"""


def main() -> int:
    p = argparse.ArgumentParser(description="把本機 Hub 轉發到 Cloudflare Quick Tunnel")
    p.add_argument("--port", help="Hub 埠號；省略時讀 server/.env，再退回 8787")
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
    port = args.port or env.get("CHATROOM_PORT") or "8787"
    token = os.environ.get("CHATROOM_TOKEN") or env.get("CHATROOM_TOKEN", "")
    if not args.i_know_its_public:
        check_token(token)

    exe = find_cloudflared(args.download)
    print(f"cloudflared：{exe}")
    if args.check:
        print("✅ 就緒——可以執行 scripts/tunnel.py 開隧道")
        return 0

    # cloudflared 把包含網址的橫幅寫在 stderr，stdout 幾乎沒東西
    proc = subprocess.Popen(
        [
            exe, "--config", str(isolated_config()),
            "tunnel", "--url", f"http://127.0.0.1:{port}", "--no-autoupdate",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    reader = threading.Thread(target=pump, args=(proc, token, port), daemon=True)
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
