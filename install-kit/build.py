"""打包 install kit → dist/chatroom-mcp-kit.zip（交付給測試者的完整包）。

    python install-kit/build.py

內容：install.py + README.md + bridge/（原始碼與 pyproject，不含測試與快取）。
"""

from __future__ import annotations

import shutil
import sys
import zipfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

KIT_DIR = Path(__file__).resolve().parent
REPO = KIT_DIR.parent
DIST = REPO / "dist"

sys.path.insert(0, str(REPO / "scripts"))
from buildstamp import read_app_version, report, stamp  # noqa: E402


def main() -> None:
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


if __name__ == "__main__":
    main()
