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
- 冪等：重跑只更新，不重複追加；Codex 設定寫入前先備份，既有 chatroom 區塊
  移除後重寫（換機重裝時舊機器的路徑不能留著，見 setup_codex）。
- 除了 MCP 設定，另外寫一份 kit 根目錄 `.env` 給 watcher——它是獨立進程，
  讀不到 MCP client 傳給 bridge 的 env（見 write_env_file）。
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


ENV_FILE_HEADER = """\
# 由 install.py 產生——**watcher 專用的連線資訊**。
#
# watch.py 是 Monitor／排程拉起的獨立進程，繼承的是 agent 主進程的環境，
# 拿不到 MCP client 設定裡的 env（那份只給 bridge 進程）。缺了這些值，
# watcher 會退回預設 Hub 位址，而且**不會報錯**——只是安靜地什麼通知
# 都不發。載入器是「真實環境變數優先、只補缺不覆寫」，所以這個檔對
# 已有 env 的 bridge 進程沒有任何影響。
#
# ⚠️ 這裡只放跨 agent 共用的連線資訊。**身分相關的值不要寫進來**：
#    - CHATROOM_AGENT_KIND：一份共用檔只能填一個 kind，另一種 agent 的
#      watcher 就會頂著錯誤身分跑。填 claude 時，同機的 Codex 備援
#      watcher（--codex-thread）會沿用 CLAUDE_CODE_SESSION_ID，直接與
#      母 Claude session 撞成同一個 participant。改用 watch.py --kind。
#    - CHATROOM_DEFAULT_NAME：同理，用 watch.py --label。
#    - CHATROOM_SESSION_KEY：身分由 session 決定，寫死會讓多個 session
#      合併成同一個聊天室身分。
#
# ⚠️ 內含 token，請勿提交版控或轉傳。
"""


def write_env_file(url: str, token: str) -> Path:
    """在 kit 根目錄寫一份 .env 給 watcher 用（只放 URL/TOKEN）。

    位置必須是 kit 根目錄（bridge/ 的上一層）——envfile.load_env_file 的
    候選清單裡有「bridge 套件的 repo 根」，解壓後的 kit 剛好落在那個位置。

    kind 與 name 刻意不寫：它們是 per-agent 的身分資訊，塞進共用檔就得在
    claude 與 codex 之間二選一，選哪個都會讓另一種 watcher 頂著錯誤身分跑
    （詳見 ENV_FILE_HEADER）。那兩個值由 watch.py 的 --kind / --label 給。
    """
    path = KIT_DIR / ".env"
    values = {"CHATROOM_URL": url}
    if token:
        values["CHATROOM_TOKEN"] = token
    body = "".join(f"{k}={v}\n" for k, v in values.items())
    content = ENV_FILE_HEADER + body
    if path.is_file() and path.read_text(encoding="utf-8-sig") == content:
        print(f"• watcher 用 .env 已是最新：{path}")
        return path
    if path.is_file():
        backup = path.with_name(f".env.bak-{datetime.now():%Y%m%d%H%M%S}")
        shutil.copy2(path, backup)
        print(f"• 已備份原 .env → {backup.name}")
    path.write_text(content, encoding="utf-8")
    if sys.platform != "win32":
        path.chmod(0o600)
    print(f"✅ watcher 用 .env 已寫入：{path}")
    return path


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


CODEX_TABLE = "mcp_servers.chatroom"


def strip_codex_block(text: str) -> tuple[str, bool]:
    """移除既有的 ``[mcp_servers.chatroom]`` 及其子表，回傳 (剩餘內容, 是否移除)。

    只認裸寫的表頭（``[mcp_servers.chatroom]`` / ``[mcp_servers.chatroom.env]``）。
    引號形式（``[mcp_servers."chatroom"]``）不處理——TOML 合法但沒人手寫，
    為它引進一個 TOML parser 不划算；真遇到會在寫入後由 Codex 自己報重複表頭。
    """
    out: list[str] = []
    removed = False
    skipping = False
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            table = stripped[1:-1].strip()
            if table == CODEX_TABLE or table.startswith(f"{CODEX_TABLE}."):
                skipping = True
                removed = True
                continue
            skipping = False
        if not skipping:
            out.append(line)
    return "".join(out), removed


def setup_codex(exe: Path, url: str, token: str, name: str,
                config_path: Path) -> None:
    block_lines = [
        "",
        f"[{CODEX_TABLE}]",
        f"command = '{exe}'",
        "args = []",
        "",
        f"[{CODEX_TABLE}.env]",
    ]
    for k, v in mcp_env(url, token, "codex", name).items():
        block_lines.append(f'{k} = "{v}"')
    block = "\n".join(block_lines) + "\n"

    existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    # 舊行為是「偵測到既有區塊就只印警告」，但換機重裝正是本 kit 的主要情境：
    # 帳號同步過來的設定往往指向舊機器不存在的路徑，跳過就等於裝出一個壞環境，
    # 而主流程照樣印「完成」。改成比照 setup_claude 走 remove → add 的冪等路徑。
    remainder, removed = strip_codex_block(existing)
    if existing:
        backup = config_path.with_suffix(
            f".toml.bak-{datetime.now():%Y%m%d%H%M%S}")
        shutil.copy2(config_path, backup)
        print(f"• 已備份原設定 → {backup.name}")
    if removed:
        print("• 偵測到既有 chatroom 區塊（可能指向舊機器路徑）——移除後重寫")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    head = remainder.rstrip("\n")
    config_path.write_text(
        (head + "\n" if head else "") + block, encoding="utf-8")
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

    print()
    # watcher（Monitor 拉起的獨立進程）拿不到 MCP 設定裡的 env，只能靠這份。
    # 兩種 target 都需要：Codex 的 --codex-thread 備援模式同樣是獨立進程。
    write_env_file(url, token)

    print("\n=== 完成 ===")
    print("重啟 Claude Code / Codex 後即可使用 chatroom_* 工具。")
    print("⚠️ 請勿自行設定 CHATROOM_SESSION_KEY——身分由 session 自動決定，")
    print("   固定 key 會讓多個 session 合併成同一個聊天室身分。")
    print("通知用法見 kit 內 README。")


if __name__ == "__main__":
    main()
