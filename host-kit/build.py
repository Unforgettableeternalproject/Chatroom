"""打包 host kit → dist/chatroom-hub-kit.zip（交付給要自架 Hub 的人）。

    python host-kit/build.py

內容：install.py + README.md + server/（原始碼，不含 .env / db / 快取）
　　　+ scripts/（run-hub.cmd、hub-service.ps1、run-tunnel.cmd、tunnel.py）。
"""

from __future__ import annotations

import argparse
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

# ⚠️ 這裡漏掉任何一項，主持人的**實際聊天內容**就會被打包發出去。
# attachments 是實測踩到的：Hub 在 server/ 底下跑時，使用者上傳的截圖、
# log、報告全部落在 server/attachments/，跟著 copytree 進了交付包。
# db 有排除、附件沒有——而附件往往比訊息更敏感。
# `.tunnel-url` 則會外流一個當下還活著的公網入口。
# 抽成模組層常數是為了讓測試能直接驗它，不必跑一次完整打包。
SERVER_IGNORE = shutil.ignore_patterns(
    "__pycache__", "*.egg-info", ".env", ".env.*", "chatroom.db*",
    "logs", "attachments", ".tunnel-url",
    # 上一次打包留下的版本戳記：一定要重寫，不能沿用
    "_build.json",
)


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


def main() -> None:
    # 打包前先確認打的是要打的那個 commit——這道閘要在刪 stage 之前，
    # 中止時不該留下半個產物目錄
    head = require_commit(REPO, _expected_commit())
    stage = DIST / "chatroom-hub-kit"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    shutil.copy2(KIT_DIR / "install.py", stage / "install.py")
    shutil.copy2(KIT_DIR / "README.md", stage / "README.md")
    shutil.copytree(REPO / "server", stage / "server", ignore=SERVER_IGNORE)
    (stage / "scripts").mkdir()
    for name in (
        "run-hub.cmd",
        "hub-service.ps1",
        "run-tunnel.cmd",
        "tunnel.py",
        # 主機控制台的「備份」與「換 token」呼叫的就是這兩支。漏掉它們的話
        # 開發機一切正常、主持人的 kit 按鈕按下去找不到檔案——而那是打包
        # 時完全看不出來的落差
        "backup.py",
        "rotate-token.py",
    ):
        shutil.copy2(REPO / "scripts" / name, stage / "scripts" / name)

    # 交付包裡沒有 .git，版本只有在打包這一刻抓得到
    info = stamp(
        REPO,
        stage / "server" / "chatroom_server" / "_build.json",
        read_app_version(REPO / "server" / "chatroom_server" / "version.py"),
        scope=("server/", "host-kit/", "scripts/"),
    )

    zip_path = DIST / "chatroom-hub-kit.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(stage.rglob("*")):
            if f.is_file():
                zf.write(f, f.relative_to(DIST))
    size_kb = zip_path.stat().st_size // 1024
    print(f"✅ {zip_path}（{size_kb} KB）")
    report(info)
    print(f"   worktree HEAD {head or '未知'}")


if __name__ == "__main__":
    main()
