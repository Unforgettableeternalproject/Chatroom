"""打包 install kit → dist/chatroom-mcp-kit.zip（交付給測試者的完整包）。

    python install-kit/build.py

內容：install.py + README.md + bridge/（原始碼與 pyproject，不含測試與快取）。
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
    stage = DIST / "chatroom-mcp-kit"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    shutil.copy2(KIT_DIR / "install.py", stage / "install.py")
    shutil.copy2(KIT_DIR / "README.md", stage / "README.md")
    shutil.copytree(
        REPO / "bridge", stage / "bridge",
        # _build.json：上一次打包留下的版本戳記一定要重寫，不能沿用
        ignore=shutil.ignore_patterns("__pycache__", "tests", "*.egg-info",
                                      ".env", "_build.json"),
    )
    info = stamp(
        REPO,
        stage / "bridge" / "chatroom_mcp" / "_build.json",
        read_app_version(REPO / "bridge" / "chatroom_mcp" / "version.py"),
        scope=("bridge/", "install-kit/"),
    )

    zip_path = DIST / "chatroom-mcp-kit.zip"
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
