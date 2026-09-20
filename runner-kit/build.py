"""打包 runner kit → dist/chatroom-runner-kit.zip（交付給要跑執行器的人）。

    python runner-kit/build.py

內容：install.bat（雙擊入口）+ install-help.txt + install.py + README.md + runner/（原始碼、install-task.ps1、
　　　config.example.json，不含 tests／快取）+ bridge/（執行器起 run 時
　　　掛給 claude 的 MCP 伺服器，`run.py` 預設找 kit 根目錄下的 bridge/）。

為什麼要帶 bridge：`ChatRun` 組 `mcp.json` 時用的是
`cfg.bridge_path or <run.py 的 parents[2]>/bridge`——kit 形態下那個
parents[2] 就是這一包的根目錄。少帶這個目錄的話執行器照樣領得到單、
也起得了 claude，只是那個 claude **連不上聊天室**（No module named
chatroom_mcp），而失敗只出現在 run 的 stream log 裡。
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import zipfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    # 中止訊息走 stderr，而 Windows 主控台預設 cp950——不設這行，打包被擋下
    # 的那句話會變成一串亂碼，等於白擋
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

KIT_DIR = Path(__file__).resolve().parent
REPO = KIT_DIR.parent
DIST = REPO / "dist"

sys.path.insert(0, str(REPO / "scripts"))
from buildstamp import (  # noqa: E402
    read_app_version, report, require_commit, stamp,
)

# ⚠️ 這裡漏掉任何一項，開發機的**實際派工現場**就會被打包發出去：
# `state_dir` 預設在 `%LOCALAPPDATA%` 而不在 repo 裡，但 `logs/`、
# `state.json`、`usage.db`、run 暫存都可能被人手動指到 runner/ 底下（README
# 的自檢段就是在 repo 內跑的），而那些檔案含房間 id、run brief 與 token。
# `.env*` 同 host-kit：token 不進交付包。
RUNNER_IGNORE = shutil.ignore_patterns(
    "__pycache__", "*.egg-info", ".env", ".env.*",
    "tests", "logs", "runs", "*.db", "*.db-*", "state.json", "usage.db",
    # 上一次打包留下的版本戳記：一定要重寫，不能沿用
    "_build.json",
)

# bridge 側沿用 install-kit/build.py 的排除清單，兩包裡的 bridge 才是同一份
BRIDGE_IGNORE = shutil.ignore_patterns(
    "__pycache__", "tests", "*.egg-info", ".env", ".env.*", "_build.json",
)

# config.example.json 裡是**開發機的現場**：本機絕對路徑、機器名、還有幾個
# 私有 repo 的名字與位置。那份檔案對 repo 內的使用者剛好合用（照著改就好），
# 但交付出去等於把一台不相干機器的目錄結構發給收件人。
#
# 不是改原檔：repo 內那份的具體範例有它的用處（README 指著它講欄位）。
# 只在**打包這一刻**把機器相關的欄位換成占位值。
SANITIZED = {
    "host": "this-machine",
    "label": "runner",
    "claude_config_dir": "",
    "state_dir": "",
    "token_env_file": "",
    # 新舊鍵都清：樣板換成 `workspaces` 之後，舊鍵留著也一樣不該外流
    "workspaces": {},
    "projects": {},
}
EXAMPLE_NOTE = (
    "安裝器（install.py）會依這份樣板產生 "
    "%LOCALAPPDATA%/UEP/Chatroom/runner/config.json。"
    "工作區（workspaces）安裝時留空，裝完再用 App 的執行器分頁或手動加。"
)


def _sanitize_example(src: Path, dst: Path) -> None:
    """把樣板設定寫成不含任何一台特定機器細節的版本。"""
    raw = json.loads(src.read_text(encoding="utf-8"))
    for key in list(raw):
        if key.startswith("_"):
            raw[key] = EXAMPLE_NOTE
    raw.update({k: v for k, v in SANITIZED.items() if k in raw})
    dst.write_text(json.dumps(raw, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")


def _expected_commit(argv: list[str] | None = None) -> str:
    """`--expect <commit>`：打包指令說出「我要打的是哪個 commit」。

    在隔離 worktree 上打包時 checkout 沒做／做錯不會有任何症狀（見
    `buildstamp.require_commit`），期望值必須從外面帶進來。
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--expect", default="",
        help="預期的 HEAD commit（短 hash 即可）；不符就中止，不產出 zip")
    return parser.parse_args(argv).expect


def build(dist: Path, expect: str = "") -> tuple[Path, dict, str]:
    """打包到 ``dist``，回傳 (zip 路徑, `_build.json` 內容, worktree HEAD)。

    ``dist`` 可換掉是為了讓測試打一份完整的包來驗內容，而不會覆蓋開發機
    `dist/` 裡那份正在發的產物。
    """
    # 打包前先確認打的是要打的那個 commit——這道閘要在刪 stage 之前，
    # 中止時不該留下半個產物目錄
    head = require_commit(REPO, expect)
    stage = dist / "chatroom-runner-kit"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    shutil.copy2(KIT_DIR / "install.py", stage / "install.py")
    # 雙擊入口：install.bat 找 Python、跑 install.py；找不到 Python 時印的
    # 中文說明在 install-help.txt（bat 本身必須純 ASCII，見它開頭的註解）。
    # 漏掉任何一支，拿到包的人就只剩「用命令列跑 install.py」這條路
    shutil.copy2(KIT_DIR / "install.bat", stage / "install.bat")
    shutil.copy2(KIT_DIR / "install-help.txt", stage / "install-help.txt")
    shutil.copy2(KIT_DIR / "README.md", stage / "README.md")
    shutil.copytree(REPO / "runner", stage / "runner", ignore=RUNNER_IGNORE)
    _sanitize_example(REPO / "runner" / "config.example.json",
                      stage / "runner" / "config.example.json")
    shutil.copytree(REPO / "bridge", stage / "bridge", ignore=BRIDGE_IGNORE)

    # 交付包裡沒有 .git，版本只有在打包這一刻抓得到
    info = stamp(
        REPO,
        stage / "runner" / "chatroom_runner" / "_build.json",
        read_app_version(REPO / "bridge" / "chatroom_mcp" / "version.py"),
        scope=("runner/", "bridge/", "runner-kit/"),
    )
    # 同一份戳記也放進 bridge：`chatroom_mcp.version` 讀的是它自己套件底下
    # 那份，沒有的話這包裡的 bridge 會對外報 unknown commit——而它與執行器
    # 是同一次打包出去的，版本理當一致
    shutil.copy2(stage / "runner" / "chatroom_runner" / "_build.json",
                 stage / "bridge" / "chatroom_mcp" / "_build.json")

    zip_path = dist / "chatroom-runner-kit.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(stage.rglob("*")):
            if f.is_file():
                zf.write(f, f.relative_to(dist))
    return zip_path, info, head


def main() -> None:
    zip_path, info, head = build(DIST, _expected_commit())
    size_kb = zip_path.stat().st_size // 1024
    print(f"✅ {zip_path}（{size_kb} KB）")
    report(info)
    print(f"   worktree HEAD {head or '未知'}")


if __name__ == "__main__":
    main()
