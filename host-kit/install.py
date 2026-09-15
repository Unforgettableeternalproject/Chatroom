"""Chatroom Hub 安裝器（host 端）。

    python install.py                 # 互動式：host / port / token
    python install.py --yes           # 全用預設值（token 自動生成）

做五件事：
1. 在包內建立獨立 venv 並安裝 Hub 相依（不污染系統 Python）
2. 產生 server/.env（host / port / token；token 預設自動生成高熵值）
3. 要對外協作的話，順手把 cloudflared 抓下來備妥（之後開隧道就是一鍵）
4. 寫下註冊檔 ~/.chatroom/host-kit.json，讓桌面 App 找得到這包
5. 印出啟動方式與要發給成員的連線資訊

之後：前景試跑用 scripts\\run-hub.cmd；要開機/登入自啟用
`pwsh -File scripts/hub-service.ps1 install`；要讓內網外的 agent 連進來用
scripts\\run-tunnel.cmd（詳見 README）。
"""

from __future__ import annotations

import argparse
import json
import secrets
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

KIT = Path(__file__).resolve().parent
VENV = KIT / ".venv"
ENV_FILE = KIT / "server" / ".env"
DEPS = ["fastapi", "uvicorn[standard]", "aiosqlite", "python-multipart"]

# 桌面 App 靠這份檔案知道「這台機器上有一包 Hub，它在哪裡」。
#
# ⚠️ **它只是一個指路牌，不是設定檔。** 真相仍在 server/.env 與實際跑著的
# 進程裡——App 讀這裡拿到路徑，其餘一律現查。寫成第二份設定的話，兩邊
# 遲早不一樣，而使用者會看到一個講得很篤定卻是錯的畫面。
REGISTRY = Path.home() / ".chatroom" / "host-kit.json"



def ask(prompt: str, default: str = "") -> str:
    tip = f"（預設 {default}）" if default else ""
    value = input(f"{prompt}{tip}: ").strip()
    return value or default


def venv_python() -> Path:
    sub = "Scripts/python.exe" if sys.platform == "win32" else "bin/python"
    return VENV / sub


def ensure_venv() -> None:
    if not venv_python().exists():
        print("建立 venv…")
        subprocess.run([sys.executable, "-m", "venv", str(VENV)], check=True)
    print("安裝相依套件…")
    subprocess.run(
        [str(venv_python()), "-m", "pip", "install", "--quiet", *DEPS], check=True
    )


def read_env() -> dict[str, str]:
    """現有的 `.env`。不存在就是空的。

    解析規則與 server 端 `config.py`、`scripts/backup.py` 一致：忽略空行與
    `#` 開頭，只切第一個 `=`（token 是 urlsafe base64，值裡可能還有 `=`）。
    """
    values: dict[str, str] = {}
    if not ENV_FILE.exists():
        return values
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        at = text.find("=")
        if at <= 0:
            continue
        values[text[:at].strip()] = text[at + 1:].strip()
    return values


def update_env(updates: dict[str, str]) -> None:
    """**只改指定的那幾個鍵，其餘原樣保留。**

    🔴 這裡原本是整份覆寫（只寫 HOST/PORT/TOKEN 三行）。後果是主持人自己
    加進 `.env` 的任何設定——`CHATROOM_PURGE_ARCHIVED_DAYS`、
    `CHATROOM_IDLE_TIMEOUT`、附件目錄——**重跑一次安裝器就全部消失**，
    而安裝器從頭到尾顯示成功。

    它咬人的時機特別惡劣：重跑安裝器多半是因為「有什麼壞了想重裝看看」，
    那時被清掉的設定正是可能與問題有關的那些。

    註解與排列順序都保留：`.env` 是人會去讀、去改的檔案，把它重排一次
    等於把使用者寫給自己的說明洗掉。
    """
    remaining = dict(updates)
    out: list[str] = []

    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines(keepends=True):
            stripped = line.strip()
            newline = "\n" if line.endswith("\n") else ""
            key = ""
            if stripped and not stripped.startswith("#"):
                at = stripped.find("=")
                if at > 0:
                    key = stripped[:at].strip()
            if key and key in remaining:
                out.append(f"{key}={remaining.pop(key)}{newline}")
            else:
                out.append(line)

    # 原本沒有的鍵補在檔尾。⚠️ 前一行沒有換行時要先補一個，否則兩個設定
    # 會黏成 `CHATROOM_PORT=8787CHATROOM_TOKEN=...`——兩個同時失效，
    # 而檔案看起來還是有內容的
    if remaining:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        for key, value in remaining.items():
            out.append(f"{key}={value}\n")

    # 寫暫存檔再換上：直接 open(..,"w") 在寫到一半失敗時留下 0 位元組的
    # `.env`，那時 Hub 起不來，而本來只是想重裝
    tmp = ENV_FILE.with_name(ENV_FILE.name + ".tmp")
    tmp.write_text("".join(out), encoding="utf-8")
    tmp.replace(ENV_FILE)
    print(f"已寫入 {ENV_FILE}")


def prepare_tunnel() -> bool:
    """把 cloudflared 先抓下來，讓之後開隧道不必等下載。失敗不中斷安裝。"""
    script = KIT / "scripts" / "tunnel.py"
    if not script.exists():
        print("⚠️ 找不到 scripts/tunnel.py，略過隧道準備")
        return False
    print("準備隧道工具（cloudflared）…")
    done = subprocess.run(
        [str(venv_python()), str(script), "--check", "--i-know-its-public"]
    )
    if done.returncode != 0:
        # 下載失敗不該讓整個安裝白跑——Hub 本身已經可用，隧道之後補即可
        print("⚠️ 隧道工具準備失敗，之後可單獨執行 scripts\\run-tunnel.cmd 重試")
        return False
    return True


def write_registry(host: str, port: str) -> None:
    """寫下指路牌，讓桌面 App 認得這台機器上的 Hub。

    **失敗不中止安裝**：沒有它只是 App 少一個分頁，Hub 本身照跑——
    而 `install.py` 走到這裡時伺服器已經可以用了，為了一個便利設施把整個
    安裝判成失敗，會讓人以為 Hub 沒裝好。
    """
    payload = {
        "version": 1,
        # App 需要的是**這一包在哪**，其餘（token、實際 host/port）它自己去
        # 讀 server/.env——那份會被人手改，而改完不會有人回來更新這裡
        "kit_root": str(KIT),
        "env_file": str(ENV_FILE),
        "installed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        # 只是給人看的線索，App 不可以拿它當現況——Hub 可能根本沒在跑
        "installed_host": host,
        "installed_port": port,
    }
    try:
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        # 先寫暫存再換名：中途失敗時留下的是舊的那份，不是半個 JSON。
        # 一個解析不了的指路牌會讓 App 每次啟動都當成「壞了」而不是「沒有」
        tmp = REGISTRY.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        tmp.replace(REGISTRY)
    except OSError as exc:
        print(f"⚠️ 註冊檔寫不進去（{exc}）——桌面 App 會找不到這包 Hub，"
              f"但 Hub 本身不受影響。手動建立：{REGISTRY}")


def main() -> None:
    p = argparse.ArgumentParser(description="Chatroom Hub 安裝器")
    p.add_argument("--host", help="綁定位址（0.0.0.0 = 所有介面；建議填 VPN 介面 IP）")
    p.add_argument("--port", help="埠號，預設 8787")
    p.add_argument("--token", help="API token；省略時自動生成")
    p.add_argument(
        "--tunnel", action=argparse.BooleanOptionalAction, default=None,
        help="是否備妥公網隧道工具（--no-tunnel 明確跳過）；省略時互動詢問",
    )
    p.add_argument("--yes", action="store_true", help="不互動，全用預設/參數值")
    args = p.parse_args()

    if sys.version_info < (3, 12):
        raise SystemExit(f"需要 Python 3.12+（目前 {sys.version.split()[0]}）")

    print("=== Chatroom Hub 安裝 ===\n")

    # 🔴 **既有的值優先於新生成的。**
    #
    # 原本每次重跑都產一把新 token 當預設——而重跑安裝器是很常見的動作
    # （升級、修東西、換設定）。照著按 Enter 就換掉了 token，**當場踢掉
    # 所有成員與 agent**，而畫面上完全看不出剛剛發生了這件事。
    #
    # 要換 token 有專門的工具（`scripts/rotate-token.py`），它會備份舊值、
    # 並講明每個人都要重拿。那才是換 token 該走的路。
    existing = read_env()
    default_token = existing.get("CHATROOM_TOKEN") or secrets.token_urlsafe(24)
    default_host = existing.get("CHATROOM_HOST") or "0.0.0.0"
    default_port = existing.get("CHATROOM_PORT") or "8787"
    reusing_token = bool(existing.get("CHATROOM_TOKEN"))

    if args.yes:
        host = args.host or default_host
        port = args.port or default_port
        token = args.token or default_token
    else:
        if existing:
            print(f"偵測到既有的 {ENV_FILE.name}——沒有動到的設定都會原樣保留。\n")
        host = args.host or ask("綁定位址（VPN 介面 IP 或 0.0.0.0）", default_host)
        port = args.port or ask("埠號", default_port)
        token = args.token or ask(
            "Agent token" + ("（直接 Enter 沿用現有的）" if reusing_token
                             else "（直接 Enter 用自動生成值）"),
            default_token)

    if args.tunnel is not None:
        want_tunnel = args.tunnel
    elif args.yes:
        want_tunnel = True
    else:
        want_tunnel = ask(
            "要讓內網以外的 agent 也能連進來嗎？（會備妥 cloudflared，約 40 MB）(Y/n)",
            "Y",
        ).lower() != "n"

    # 🔑 **人類主持人自己的鑰匙。**
    #
    # 沒有這一把的 Hub 是 `credential_mode: legacy`——整套憑證分離做好了
    # 卻沒有啟用，因為安裝器從來沒產生過它。那等於它只對「知道有這個環境
    # 變數的人」存在，而交付給外部人的包裡它不存在。
    #
    # 既有的優先：升級時補上新的那把，不動已經在用的那把。
    human_token = existing.get("CHATROOM_HUMAN_TOKEN") or secrets.token_urlsafe(24)
    newly_split = not existing.get("CHATROOM_HUMAN_TOKEN")

    ensure_venv()
    update_env({
        "CHATROOM_HOST": host,
        "CHATROOM_PORT": port,
        "CHATROOM_TOKEN": token,
        "CHATROOM_HUMAN_TOKEN": human_token,
    })
    write_registry(host, port)
    tunnel_ready = prepare_tunnel() if want_tunnel else False

    shown = host if host != "0.0.0.0" else "<這台機器的 IP>"
    tunnel_hint = (
        "對外協作（公網）：  scripts\\run-tunnel.cmd　← 起隧道後會印出要發的網址\n"
        if tunnel_ready
        else "對外協作（公網）：  scripts\\run-tunnel.cmd　← 首次執行會下載 cloudflared\n"
    )
    # 升級到分離模式的那一刻要當場講。只寫進 README 的話，看到症狀的人
    # 不會知道那是自己剛做的事造成的——他會以為升級把功能弄壞了
    split_notice = "" if not newly_split else f"""
⚠️ 這次安裝**啟用了憑證分離**（這台 Hub 原本沒有人類憑證）。

   舊的那把 token 從現在起是 **agent 專用**——你自己的 App 若還填著它，
   會失去「主持人模式」與「發邀請」的能力，錯誤訊息是 root_token_required。
   **那不是故障，是換了鑰匙。** 請把 App 設定裡的 token 換成上面那把人類憑證。
"""
    print(
        f"""
✅ 安裝完成。

前景啟動（試跑）：  scripts\\run-hub.cmd
開機/登入自啟：    pwsh -File scripts/hub-service.ps1 install
{tunnel_hint}健康檢查：         curl http://{shown}:{port}/api/health

Hub 位址：http://{shown}:{port}

🔑 這台 Hub 有**兩把鑰匙，給的對象不同**：

  給人（你自己的 App，以及其他用 App 的人）：
    {human_token}
    這一把才能開主持人模式、才能發邀請。

  給 agent（裝 chatroom-mcp-kit 的那些）：
    {token}
    它做得了 agent 該做的一切，但**宣稱不了自己是人**。

  ⚠️ 兩把都等同全權限讀取，只給信任的對象。**不要把人類那把發給 agent**
  ——那等於把主持人的權力交出去。
{split_notice}
注意：
- Windows 防火牆需放行 TCP {port}（第一次啟動時同意跳窗，或手動加入規則）
- 要換 token 用 scripts\\rotate-token.py（會備份舊值並講明誰要重拿），
  不要重跑這個安裝器——它現在會沿用既有的 token，不再每次換一把
- 資料庫檔 chatroom.db 會出現在 server/ 內，備份用 scripts\\backup.py
  （它連 attachments 一起收；直接複製 chatroom.db 會拿到缺資料的空殼）
- 隧道要 Hub 已經跑著才有意義（它只是轉發），且**網址每次重開都會變**，
  要固定網址請照 README 改用 named tunnel
"""
    )


if __name__ == "__main__":
    main()
