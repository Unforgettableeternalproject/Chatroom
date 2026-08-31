"""Hub 的版本識別。

存在的理由是一次真實事故：測試端拿到的 App 是 16 小時前的產物，中間隔著
17 個 commit，而畫面上沒有任何資訊能分辨——連「我記得我 rebuild 過」都無從
查證，最後是靠 exe 的檔案修改日期對不上才起疑。

所以版本字串一定要帶 **commit hash**。語意版本號（`1.0.0`）只說得出「這是
哪一版設計」，說不出「這是哪一份程式碼」，而後者才是回報問題時真正要問的。

三段來源，由確定到不確定：

1. 同目錄的 ``_build.json``——打包時寫入。**部署現場唯一可靠的來源**，
   因為 kit 解開之後沒有 git，也沒有 `.git` 目錄可問
2. `git rev-parse`——開發機直接跑 source 時用
3. 都沒有 → ``commit`` 為空字串，且 ``source`` 明說是 unknown

⚠️ 第 3 種不要偽造成好看的預設值。「不知道自己是哪一版」與「是 0.1.0 版」
是完全不同的兩件事，把前者顯示成後者正是這次事故的成因。
"""

from __future__ import annotations

import json
import subprocess
from functools import lru_cache
from pathlib import Path

# 語意版本：人看的「這是哪一版設計」。改動契約時才動它。
APP_VERSION = "1.1.5"

_BUILD_FILE = Path(__file__).with_name("_build.json")


@lru_cache(maxsize=1)
def build_info() -> dict[str, str]:
    """{version, commit, built_at, source}。行程生命週期內只算一次。

    ``commit`` 帶 ``-dirty`` 後綴表示打包時工作樹有未提交的變更——那份產物
    對不回任何一個 commit，出事時要第一時間知道。
    """
    packed = _from_build_file()
    if packed is not None:
        return packed
    from_git = _from_git()
    if from_git is not None:
        return from_git
    return {
        "version": APP_VERSION,
        "commit": "",
        "built_at": "",
        "source": "unknown",
    }


def version_string() -> str:
    """單行摘要，給日誌開頭與 UI 角落用。"""
    info = build_info()
    commit = info["commit"] or "unknown"
    return f"{info['version']}+{commit} ({info['source']})"


def _from_build_file() -> dict[str, str] | None:
    try:
        raw = json.loads(_BUILD_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    return {
        "version": str(raw.get("version") or APP_VERSION),
        "commit": str(raw.get("commit") or ""),
        "built_at": str(raw.get("built_at") or ""),
        "source": "build",
    }


def _from_git() -> dict[str, str] | None:
    root = Path(__file__).resolve().parents[2]
    if not (root / ".git").exists():
        return None
    commit = _git(root, "rev-parse", "--short=12", "HEAD")
    if not commit:
        return None
    # 工作樹髒 = 這份執行中的程式碼對不回任何 commit
    if _git(root, "status", "--porcelain") != "":
        commit += "-dirty"
    return {
        "version": APP_VERSION,
        "commit": commit,
        # 直接跑 source 沒有「建置時間」這回事，留空比填一個假的好
        "built_at": "",
        "source": "git",
    }


def _git(root: Path, *args: str) -> str | None:
    """跑 git 並回傳 stdout（strip 過）。任何失敗一律回 None——版本查詢
    絕不能讓 Hub 起不來。"""
    try:
        out = subprocess.run(
            ["git", *args],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()
