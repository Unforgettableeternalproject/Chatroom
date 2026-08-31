"""打包時把「這是哪一份程式碼」寫進產物。

兩個 kit（host-kit / install-kit）共用。抽出來不是為了少寫幾行，而是為了
**兩份產物的版本語意必須一致**——一邊標 `-dirty` 一邊不標的話，交叉比對
Hub 與 bridge 的版本就失去意義，而那正是這套東西唯一的用途。

交付包裡沒有 `.git`：版本資訊只有在打包這一刻抓得到，錯過就永遠是 unknown。
"""

from __future__ import annotations

import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def stamp(repo: Path, target: Path, version: str) -> dict:
    """在 ``target`` 寫下 `_build.json`，回傳寫進去的內容。

    ``commit`` 帶 `-dirty` 後綴表示打包時工作樹有未提交的變更——那份產物
    對不回任何一個 commit，收到的人有權知道。
    """
    commit = git(repo, "rev-parse", "--short=12", "HEAD") or ""
    if commit and git(repo, "status", "--porcelain"):
        commit += "-dirty"
    info = {
        "version": version,
        "commit": commit,
        "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    target.write_text(
        json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return info


def read_app_version(version_py: Path) -> str:
    """從 version.py 讀語意版本，不在兩個地方各寫一份。"""
    try:
        text = version_py.read_text(encoding="utf-8")
    except OSError:
        return "0.0.0"
    for line in text.splitlines():
        if line.startswith("APP_VERSION"):
            return line.split("=", 1)[1].strip().strip("\"'")
    return "0.0.0"


def report(info: dict) -> None:
    """把版本印在打包輸出裡。

    ⚠️ 警告要印在**最後**：打包腳本的輸出常常只被看最後幾行，夾在中間的
    警告會被滑過去——今天那個 `LNK1104` 就是這樣淹掉的，害 exe 十六小時
    沒更新卻沒人發現。
    """
    print(f"   版本 {info['version']}+{info['commit'] or 'unknown'}"
          f" · 打包於 {info['built_at']}")
    if info["commit"].endswith("-dirty"):
        print("   ⚠️ 工作樹有未提交的變更——這份產物對不回任何一個 commit")
    elif not info["commit"]:
        print("   ⚠️ 抓不到 commit（不在 git 工作樹裡？）"
              "——收到的人無法判斷這是哪一份程式碼")


def dart_default_version(build_info: Path) -> str | None:
    """`build_info.dart` 裡 `CHATROOM_VERSION` 的 defaultValue。

    不硬編在這裡：那個值一旦與 Dart 側漂移，下面的檢查就會安靜地失去意義
    ——而它正是用來抓「安靜失去意義」的。
    """
    try:
        text = build_info.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(
        r"CHATROOM_VERSION'\s*,\s*defaultValue:\s*'([^']+)'", text, re.S
    )
    return m.group(1) if m else None


def verify_embedded(blob: bytes, version: str, commit: str,
                    fallback: str | None) -> list[str]:
    """產物裡真的有那些值嗎？回傳問題清單，空清單＝通過。

    **這支存在的理由**：build 腳本結尾印的是「它打算編進去的值」，不是產物
    裡真的有的東西。2026-08-31 有一份 App 印著 `✓ 1.1.5+<hash>`，而 app.so
    裡是 `1.0.0`——`--dart-define` 沒生效（實際上是被另一個不帶 define 的
    直接 build 蓋掉），沒有任何地方報錯，直到有人去讀畫面右上角。

    `fallback` 仍在，是最強的訊號：它代表 Dart 端走了 defaultValue 那條路。
    """
    problems: list[str] = []
    if version and blob.count(version.encode()) == 0:
        problems.append(f"版本字串 {version!r} 不在產物裡")
    if commit and blob.count(commit.encode()) == 0:
        problems.append(f"commit {commit!r} 不在產物裡")
    if fallback and fallback != version and blob.count(fallback.encode()):
        problems.append(
            f"產物含 build_info 的 defaultValue {fallback!r}"
            "——表示 --dart-define 沒有生效"
        )
    return problems


def git(repo: Path, *args: str) -> str:
    """跑 git 並回傳 stdout。失敗一律回空字串——打包不該因為問不到版本而中斷，
    但也不該假裝問到了。"""
    try:
        out = subprocess.run(["git", *args], cwd=repo, capture_output=True,
                             text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""
