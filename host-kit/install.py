"""Chatroom Hub 安裝器（host 端）。

    python install.py                 # 互動式：host / port / token
    python install.py --yes           # 全用預設值（token 自動生成）

做三件事：
1. 在包內建立獨立 venv 並安裝 Hub 相依（不污染系統 Python）
2. 產生 server/.env（host / port / token；token 預設自動生成高熵值）
3. 印出啟動方式與要發給成員的連線資訊

之後：前景試跑用 scripts\\run-hub.cmd；要開機/登入自啟用
`pwsh -File scripts/hub-service.ps1 install`（詳見 README）。
"""

from __future__ import annotations

import argparse
import secrets
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

KIT = Path(__file__).resolve().parent
VENV = KIT / ".venv"
ENV_FILE = KIT / "server" / ".env"
DEPS = ["fastapi", "uvicorn[standard]", "aiosqlite"]


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


def write_env(host: str, port: str, token: str) -> None:
    ENV_FILE.write_text(
        f"CHATROOM_HOST={host}\n"
        f"CHATROOM_PORT={port}\n"
        f"CHATROOM_TOKEN={token}\n",
        encoding="utf-8",
    )
    print(f"已寫入 {ENV_FILE}")


def main() -> None:
    p = argparse.ArgumentParser(description="Chatroom Hub 安裝器")
    p.add_argument("--host", help="綁定位址（0.0.0.0 = 所有介面；建議填 VPN 介面 IP）")
    p.add_argument("--port", help="埠號，預設 8787")
    p.add_argument("--token", help="API token；省略時自動生成")
    p.add_argument("--yes", action="store_true", help="不互動，全用預設/參數值")
    args = p.parse_args()

    if sys.version_info < (3, 12):
        raise SystemExit(f"需要 Python 3.12+（目前 {sys.version.split()[0]}）")

    print("=== Chatroom Hub 安裝 ===\n")

    default_token = secrets.token_urlsafe(24)
    if args.yes:
        host = args.host or "0.0.0.0"
        port = args.port or "8787"
        token = args.token or default_token
    else:
        host = args.host or ask("綁定位址（VPN 介面 IP 或 0.0.0.0）", "0.0.0.0")
        port = args.port or ask("埠號", "8787")
        token = args.token or ask("API token（直接 Enter 用自動生成值）", default_token)

    if ENV_FILE.exists() and not args.yes:
        keep = ask(f"{ENV_FILE.name} 已存在，要覆寫嗎？(y/N)", "N")
        if keep.lower() != "y":
            raise SystemExit("保留既有設定，安裝中止。重跑時加 --yes 可強制覆寫。")

    ensure_venv()
    write_env(host, port, token)

    shown = host if host != "0.0.0.0" else "<這台機器的 IP>"
    print(
        f"""
✅ 安裝完成。

前景啟動（試跑）：  scripts\\run-hub.cmd
開機/登入自啟：    pwsh -File scripts/hub-service.ps1 install
健康檢查：         curl http://{shown}:{port}/api/health

發給成員的連線資訊（搭配 chatroom-mcp-kit 安裝）：
  Hub 位址：http://{shown}:{port}
  Token   ：{token}

注意：
- Windows 防火牆需放行 TCP {port}（第一次啟動時同意跳窗，或手動加入規則）
- token 等同全權限，只給信任的成員；換 token 改 server/.env 後重啟 Hub
- 資料庫檔 chatroom.db 會出現在 server/ 內，備份帶著它走
"""
    )


if __name__ == "__main__":
    main()
