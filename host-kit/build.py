"""打包 host kit → dist/chatroom-hub-kit.zip（交付給要自架 Hub 的人）。

    python host-kit/build.py

內容：install.py + README.md + server/（原始碼，不含 .env / db / 快取）
　　　+ scripts/（run-hub.cmd、hub-service.ps1、run-tunnel.cmd、tunnel.py）。
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


def main() -> None:
    stage = DIST / "chatroom-hub-kit"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    shutil.copy2(KIT_DIR / "install.py", stage / "install.py")
    shutil.copy2(KIT_DIR / "README.md", stage / "README.md")
    shutil.copytree(
        REPO / "server", stage / "server",
        # ⚠️ 這裡漏掉任何一項，主持人的**實際聊天內容**就會被打包發出去。
        # attachments 是實測踩到的：Hub 在 server/ 底下跑時，使用者上傳的
        # 截圖、log、報告全部落在 server/attachments/，跟著 copytree 進了
        # 交付包。db 有排除、附件沒有——而附件往往比訊息更敏感。
        # `.tunnel-url` 則會外流一個當下還活著的公網入口。
        ignore=shutil.ignore_patterns(
            "__pycache__", "*.egg-info", ".env", ".env.*", "chatroom.db*",
            "logs", "attachments", ".tunnel-url",
        ),
    )
    (stage / "scripts").mkdir()
    for name in ("run-hub.cmd", "hub-service.ps1", "run-tunnel.cmd", "tunnel.py"):
        shutil.copy2(REPO / "scripts" / name, stage / "scripts" / name)

    zip_path = DIST / "chatroom-hub-kit.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(stage.rglob("*")):
            if f.is_file():
                zf.write(f, f.relative_to(DIST))
    size_kb = zip_path.stat().st_size // 1024
    print(f"✅ {zip_path}（{size_kb} KB）")


if __name__ == "__main__":
    main()
