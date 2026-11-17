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
import zipfile
from datetime import datetime, timezone
from pathlib import Path

# 在 zip 裡要帶執行位元（0o755）的副檔名。kit 是單包跨平台（同時含 .bat 與
# .sh），解壓到 macOS／Linux 後 install.sh 等要能直接執行
EXECUTABLE_SUFFIXES = (".sh",)
# 這些副檔名的檔案進 zip 前一律轉成 LF：Windows 上 git autocrlf 會把工作樹
# 檢出成 CRLF，shebang 行尾帶著 CR 的腳本在 macOS／Linux 上直接跑不起來
LF_ONLY_SUFFIXES = (".sh",)


def write_zip(zip_path: Path, stage: Path, base: Path) -> None:
    """把 ``stage`` 底下的檔案打成 zip，路徑相對於 ``base``。

    與逐檔 `zf.write` 的差別只有一件事：每個檔案的 Unix 權限是**明確設定**的
    （`*.sh` 為 0o755，其餘 0o644），而且 `create_system` 標成 Unix，否則在
    Windows 上打出來的包會被 macOS／Linux 的解壓縮程式當成沒有權限資訊。
    """
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(stage.rglob("*")):
            if not f.is_file():
                continue
            data = f.read_bytes()
            if f.suffix in LF_ONLY_SUFFIXES:
                data = data.replace(b"\r\n", b"\n")
            info = zipfile.ZipInfo.from_file(f, f.relative_to(base).as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # Unix：external_attr 的高 16 位才會被採用
            mode = 0o755 if f.suffix in EXECUTABLE_SUFFIXES else 0o644
            info.external_attr = (0o100000 | mode) << 16
            zf.writestr(info, data)


def stamp(repo: Path, target: Path, version: str,
          scope: tuple[str, ...] = ()) -> dict:
    """在 ``target`` 寫下 `_build.json`，回傳寫進去的內容。

    ``commit`` 帶 `-dirty` 後綴表示打包時工作樹有未提交的變更——那份產物
    對不回任何一個 commit，收到的人有權知道。

    ``scope`` 是**這份產物實際收錄的路徑**（相對 repo 根）。給了就只問這些
    路徑髒不髒：兩個 kit 從同一棵樹打包，但 host-kit 收 `server/`、
    install-kit 收 `bridge/`——一邊在改的時候，另一邊沒有理由被標成
    「對不回任何 commit」。scope 開成整棵樹會讓警告幾乎恆真，而恆真的
    警告沒有人看（那正是 `report()` 上面那段事故的下一步）。

    ⚠️ scope **內**的 untracked 仍然算髒：新檔案沒 commit，一樣對不回去。
    留空 = 問整棵樹，維持舊行為。
    """
    commit = git(repo, "rev-parse", "--short=12", "HEAD") or ""
    status_args = ("status", "--porcelain")
    if scope:
        status_args += ("--", *scope)
    if commit and git(repo, *status_args):
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


def require_commit(repo: Path, expected: str) -> str:
    """打包前確認 HEAD 真的是要打的那個 commit；不符就中止。

    在隔離 worktree 上打包解掉了「工作樹髒」那個失效，但換來一個更安靜的：
    **checkout 沒做、做錯、或半途失敗**，而版號已經抬上去了——產物就是
    「版號是新的、commit 是舊的」。`-dirty` 會自己喊出來，這個不會：它對得
    回一個真實存在的 commit，只是錯的那個，`_build.json` 內部完全一致，
    收件端驗不出來（測試端 2026-09-06 指出）。

    所以期望值必須來自**打包指令**，不能來自被檢查的那棵樹——後者只能驗出
    自我一致，而自我一致在上面那個情境裡照樣成立。

    ⚠️ 問不出 HEAD 也是失敗。「查不到」與「相符」是兩件事，把前者當後者
    等於在最需要這道閘的情況（不是 git 工作樹、git 壞了）下自動打開它。
    """
    head = git(repo, "rev-parse", "--short=12", "HEAD") or ""
    if not expected:
        return head  # 沒給期望值就照舊：這道閘是可選的
    if not head:
        raise SystemExit(
            f"❌ 問不出 {repo} 的 HEAD，無法確認要打的是不是 {expected}。"
            "打包中止——查不到不等於相符。")
    if not (head.startswith(expected) or expected.startswith(head)):
        raise SystemExit(
            f"❌ 打包中止：worktree 的 HEAD 是 {head}，但指定要打的是 "
            f"{expected}。checkout 是不是沒做或做錯了？")
    return head


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
