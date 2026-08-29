"""bridge 的版本識別。

與 Hub 那支（`chatroom_server/version.py`）刻意保持同樣的三段來源與同樣的
欄位名：**兩邊的版本要能放在一起比對**，而不是各說各話。今天的事故裡最花
時間的一段，就是沒有人能同時說出「Hub 是哪一版」與「我手上的 kit 是哪一版」。

kit 解開之後沒有 `.git`，所以 `_build.json` 是部署現場唯一可靠的來源。
"""

from __future__ import annotations

import json
import subprocess
from functools import lru_cache
from pathlib import Path

APP_VERSION = "1.0.0"

_BUILD_FILE = Path(__file__).with_name("_build.json")


@lru_cache(maxsize=1)
def build_info() -> dict[str, str]:
    """{version, commit, built_at, source}。"""
    packed = _from_build_file()
    if packed is not None:
        return packed
    from_git = _from_git()
    if from_git is not None:
        return from_git
    # 不偽造：「不知道自己是哪一版」與「是 1.0.0 版」是完全不同的兩件事
    return {"version": APP_VERSION, "commit": "", "built_at": "",
            "source": "unknown"}


def version_string() -> str:
    info = build_info()
    return f"{info['version']}+{info['commit'] or 'unknown'} ({info['source']})"


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
    if _git(root, "status", "--porcelain") != "":
        commit += "-dirty"
    return {"version": APP_VERSION, "commit": commit, "built_at": "",
            "source": "git"}


def _git(root: Path, *args: str) -> str | None:
    try:
        out = subprocess.run(["git", *args], cwd=root, capture_output=True,
                             text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()
