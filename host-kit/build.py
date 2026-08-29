"""打包 host kit → dist/chatroom-hub-kit.zip（交付給要自架 Hub 的人）。

    python host-kit/build.py

內容：install.py + README.md + server/（原始碼，不含 .env / db / 快取）
　　　+ scripts/（run-hub.cmd、hub-service.ps1、run-tunnel.cmd、tunnel.py）。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

KIT_DIR = Path(__file__).resolve().parent
REPO = KIT_DIR.parent
DIST = REPO / "dist"

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


def _stamp_build(stage: Path) -> dict:
    """把 commit 與打包時間寫進產物。

    交付包裡沒有 `.git`，所以 `version.py` 在對方機器上問不到 git——**版本
    資訊只有在打包這一刻抓得到**，錯過就永遠是 unknown。這正是這次事故的
    形狀：測試人員手上的產物比程式碼舊 16 小時，而畫面上沒有任何線索。

    工作樹髒就標 `-dirty`：那份產物對不回任何一個 commit，收到的人有權知道。
    """
    commit = _git("rev-parse", "--short=12", "HEAD") or ""
    if commit and _git("status", "--porcelain"):
        commit += "-dirty"
    info = {
        "version": _app_version(),
        "commit": commit,
        "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    (stage / "server" / "chatroom_server" / "_build.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2) + chr(10), encoding="utf-8"
    )
    return info


def _app_version() -> str:
    """從 version.py 讀語意版本，不在兩個地方各寫一份。"""
    text = (REPO / "server" / "chatroom_server" / "version.py").read_text(
        encoding="utf-8"
    )
    for line in text.splitlines():
        if line.startswith("APP_VERSION"):
            return line.split("=", 1)[1].strip().strip("\"'")
    return "0.0.0"


def _git(*args: str) -> str:
    try:
        out = subprocess.run(["git", *args], cwd=REPO, capture_output=True,
                             text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def main() -> None:
    stage = DIST / "chatroom-hub-kit"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    shutil.copy2(KIT_DIR / "install.py", stage / "install.py")
    shutil.copy2(KIT_DIR / "README.md", stage / "README.md")
    shutil.copytree(REPO / "server", stage / "server", ignore=SERVER_IGNORE)
    (stage / "scripts").mkdir()
    for name in ("run-hub.cmd", "hub-service.ps1", "run-tunnel.cmd", "tunnel.py"):
        shutil.copy2(REPO / "scripts" / name, stage / "scripts" / name)

    info = _stamp_build(stage)

    zip_path = DIST / "chatroom-hub-kit.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(stage.rglob("*")):
            if f.is_file():
                zf.write(f, f.relative_to(DIST))
    size_kb = zip_path.stat().st_size // 1024
    print(f"✅ {zip_path}（{size_kb} KB）")
    print(f"   版本 {info['version']}+{info['commit'] or 'unknown'}"
          f" · 打包於 {info['built_at']}")
    if info["commit"].endswith("-dirty"):
        print("   ⚠️ 工作樹有未提交的變更——這份產物對不回任何一個 commit")
    elif not info["commit"]:
        print("   ⚠️ 抓不到 commit（不在 git 工作樹裡？）"
              "——收到的人無法判斷這是哪一份程式碼")


if __name__ == "__main__":
    main()
