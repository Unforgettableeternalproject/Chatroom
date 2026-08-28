"""Chatroom MCP Bridge 安裝器。

給測試者的一鍵安裝：建立獨立 venv、安裝 bridge、寫入 Claude Code 與
Codex CLI 的 MCP 設定。只用 Python 標準庫，Python 3.12+。

用法（互動）：
    python install.py

用法（非互動，全部參數給定）：
    python install.py --url http://26.176.231.43:8787 --token <TOKEN> \
        --name 小明 --targets claude,codex

設計原則：
- **絕不寫入 CHATROOM_SESSION_KEY**——身分由各 agent 平台的 session 決定
  （Claude Code 用 CLAUDE_CODE_SESSION_ID；Codex 每 session 自動生成）。
  固定 key 會讓多個 session／多台機器合併成同一個聊天室身分。
- 冪等：重跑只更新，不重複追加；Codex 設定寫入前先備份。
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

# 繁中 Windows 主控台預設 cp950，emoji/特殊字元會直接 UnicodeEncodeError
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

KIT_DIR = Path(__file__).resolve().parent
VENV_DIR = KIT_DIR / "venv"


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"❌ {msg}")
    raise SystemExit(1)


def ask(prompt: str, default: str = "") -> str:
    tip = f"（預設 {default}）" if default else ""
    value = input(f"{prompt}{tip}：").strip()
    return value or default


def scripts_dir() -> Path:
    return VENV_DIR / ("Scripts" if sys.platform == "win32" else "bin")


# ---------- 步驟 ----------


def check_python() -> None:
    if sys.version_info < (3, 12):
        die(f"需要 Python 3.12+（目前 {sys.version.split()[0]}）")


def check_hub(url: str, token: str) -> bool:
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/rooms",
        headers={"Authorization": f"Bearer {token}"} if token else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as e:
        print(f"⚠️ Hub 回應 {e.code}（token 可能不對）")
    except OSError as e:
        print(f"⚠️ 連不上 Hub：{e}（是否已連上 Radmin VPN？）")
    return False


def install_bridge() -> Path:
    """建立 venv 並安裝 bridge，回傳 chatroom-mcp 執行檔路徑。"""
    bridge_src = KIT_DIR / "bridge"
    if not (bridge_src / "pyproject.toml").is_file():
        die(f"找不到 bridge 原始碼（{bridge_src}）——請整包解壓後再執行")
    if not VENV_DIR.exists():
        print("• 建立虛擬環境…")
        subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)], check=True)
    py = scripts_dir() / ("python.exe" if sys.platform == "win32" else "python")
    print("• 安裝 bridge（含 mcp / httpx 相依，需要網路）…")
    subprocess.run(
        [str(py), "-m", "pip", "install", "--disable-pip-version-check",
         "-q", "--upgrade", str(bridge_src)],
        check=True,
    )
    exe = scripts_dir() / (
        "chatroom-mcp.exe" if sys.platform == "win32" else "chatroom-mcp")
    if not exe.exists():
        die(f"安裝後找不到 {exe}")
    print(f"✅ bridge 安裝完成：{exe}")
    return exe


def mcp_env(url: str, token: str, kind: str, name: str) -> dict[str, str]:
    env = {
        "CHATROOM_URL": url,
        "CHATROOM_AGENT_KIND": kind,
        "CHATROOM_DEFAULT_NAME": name,
    }
    if token:
        env["CHATROOM_TOKEN"] = token
    return env


def setup_claude(exe: Path, url: str, token: str, name: str, mode: str) -> None:
    config = {"command": str(exe), "args": [],
              "env": mcp_env(url, token, "claude", name)}
    payload = json.dumps(config, ensure_ascii=False)
    claude = shutil.which("claude")
    if mode == "auto" and claude:
        print("• 寫入 Claude Code 使用者層級 MCP 設定…")
        result = subprocess.run(
            [claude, "mcp", "remove", "chatroom", "--scope", "user"],
            capture_output=True, text=True)
        _ = result  # 不存在時 remove 會失敗，冪等重裝用，忽略
        done = subprocess.run(
            [claude, "mcp", "add-json", "chatroom", payload, "--scope", "user"],
            capture_output=True, text=True)
        if done.returncode == 0:
            print("✅ Claude Code 設定完成（所有專案可用）")
            return
        print(f"⚠️ claude mcp add-json 失敗：{done.stderr.strip()}")
    print("→ 請手動執行以下指令完成 Claude Code 設定：")
    print(f"  claude mcp add-json chatroom '{payload}' --scope user")


def setup_codex(exe: Path, url: str, token: str, name: str,
                config_path: Path) -> None:
    block_lines = [
        "",
        "[mcp_servers.chatroom]",
        f"command = '{exe}'",
        "args = []",
        "",
        "[mcp_servers.chatroom.env]",
    ]
    for k, v in mcp_env(url, token, "codex", name).items():
        block_lines.append(f'{k} = "{v}"')
    block = "\n".join(block_lines) + "\n"

    existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    if "[mcp_servers.chatroom]" in existing:
        print(f"⚠️ {config_path} 已有 chatroom 設定，未改動。"
              "若要重設請先手動移除該區塊（含 [mcp_servers.chatroom.env]）。")
        print("  期望的內容如下：")
        print(block)
        return
    if existing:
        backup = config_path.with_suffix(
            f".toml.bak-{datetime.now():%Y%m%d%H%M%S}")
        shutil.copy2(config_path, backup)
        print(f"• 已備份原設定 → {backup.name}")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    with config_path.open("a", encoding="utf-8") as f:
        f.write(block)
    print(f"✅ Codex 設定完成：{config_path}")


# ---------- 主流程 ----------


def main() -> None:
    p = argparse.ArgumentParser(description="Chatroom MCP Bridge 安裝器")
    p.add_argument("--url", help="Hub 位址，例 http://26.176.231.43:8787")
    p.add_argument("--token", help="API token（主持人提供）")
    p.add_argument("--name", help="你在聊天室的預設代稱")
    p.add_argument("--targets", help="要設定的 agent：claude,codex（預設兩者）")
    p.add_argument("--claude", choices=["auto", "manual"], default="auto",
                   help="auto=直接寫入設定；manual=只印出指令")
    p.add_argument("--codex-config", type=Path,
                   default=Path.home() / ".codex" / "config.toml",
                   help="Codex 設定檔位置（測試用）")
    args = p.parse_args()

    check_python()
    print("=== Chatroom MCP Bridge 安裝 ===\n")

    url = (args.url or ask("Hub 位址", "http://26.176.231.43:8787")).rstrip("/")
    token = args.token if args.token is not None else ask("API token")
    name = args.name or ask("你的聊天室代稱", "Tester")
    targets = {
        t.strip() for t in (args.targets or "claude,codex").split(",") if t.strip()
    }
    unknown = targets - {"claude", "codex"}
    if unknown:
        die(f"未知的 target：{', '.join(sorted(unknown))}")

    print("\n• 測試 Hub 連線…")
    if check_hub(url, token):
        print("✅ Hub 連線正常")
    elif ask("Hub 連線失敗，仍要繼續安裝嗎？(y/N)", "N").lower() != "y":
        raise SystemExit(1)

    exe = install_bridge()
    print()
    if "claude" in targets:
        setup_claude(exe, url, token, name, args.claude)
    if "codex" in targets:
        setup_codex(exe, url, token, name, args.codex_config)

    print("\n=== 完成 ===")
    print("重啟 Claude Code / Codex 後即可使用 chatroom_* 工具。")
    print("⚠️ 請勿自行設定 CHATROOM_SESSION_KEY——身分由 session 自動決定，")
    print("   固定 key 會讓多個 session 合併成同一個聊天室身分。")
    print("通知用法見 kit 內 README。")


if __name__ == "__main__":
    main()
