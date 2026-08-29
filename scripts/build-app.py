"""Build Windows App，並把「這是哪一份程式碼」編進產物。

**一定要走這支，不要直接 `flutter build windows`。** 少帶 `--dart-define`
的話 App 講不出自己是哪一份，而那正是這次事故的成因——版本資訊在 build
當下抓得到，錯過就永遠是 unknown。

兩個這次真的踩到的坑，都在這裡擋掉：

1. **App 開著時 build 會失敗，而失敗看起來像成功。** linker 寫不進被佔用的
   exe（LNK1104），但 `flutter build` 結尾只印一行 `Build process failed`，
   前面那行錯誤淹在輸出裡，而舊產物完好地留在原地。這支會先檢查行程。
2. **exe 的時間戳不代表 Dart 程式碼有沒有更新。** 純 Dart 變更不會重寫
   `chatroom_app.exe`（那是 C++ runner 殼），更新的是 `data/app.so`。
   照 exe 判會誤報成「沒 rebuild」——這次就是這樣判的。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Windows 主控台預設 CP950，訊息裡的 ✓ ⚠️ ✕ 會讓 print 直接拋
# UnicodeEncodeError——build 明明成功卻以例外收場，看起來像失敗。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
VERSION = "1.0.0"
# 這台機器的 SDK 位置；PATH 與 FLUTTER_ROOT 都沒有時的最後退路
_FALLBACK_SDK = r"C:\Users\Bernie\dev\flutter"


def git(*args: str) -> str:
    try:
        out = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def flutter_cmd() -> str:
    """找得到 flutter 才動手。

    Flutter SDK 不在 PATH 上是這台機器的常態（要先 export 才用得了），而
    subprocess 不會繼承那個 export。找不到就直接說清楚——否則會炸在
    `FileNotFoundError: [WinError 2]`，訊息完全看不出少了什麼。
    """
    found = shutil.which("flutter")
    if found:
        return found
    for candidate in (os.environ.get("FLUTTER_ROOT", ""), _FALLBACK_SDK):
        if not candidate:
            continue
        name = "flutter.bat" if os.name == "nt" else "flutter"
        exe = Path(candidate) / "bin" / name
        if exe.exists():
            return str(exe)
    raise SystemExit(
        "✕ 找不到 flutter。把 SDK 的 bin 加進 PATH，"
        "或設 FLUTTER_ROOT 指向 SDK 根目錄。"
    )


def running_app_pids() -> list[str]:
    """回傳佔用輸出檔的 chatroom_app 行程。"""
    if sys.platform != "win32":
        return []
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Get-Process chatroom_app -ErrorAction SilentlyContinue"
         " | Select-Object -ExpandProperty Id"],
        capture_output=True, text=True,
    )
    return [line.strip() for line in out.stdout.splitlines() if line.strip()]


def main() -> int:
    pids = running_app_pids()
    if pids:
        print(f"✕ chatroom_app 正在執行（PID {', '.join(pids)}）。", file=sys.stderr)
        print("  linker 寫不進被佔用的 exe，而失敗會留下一個看起來成功的現場——",
              file=sys.stderr)
        print("  舊產物完好地待在原地。請先關閉 App 再重跑。", file=sys.stderr)
        return 1

    commit = git("rev-parse", "--short=12", "HEAD")
    if not commit:
        print("⚠️ 抓不到 commit（不在 git 工作樹？）。", file=sys.stderr)
        print("  這份產物將無法對帳版本，Hub 比對會顯示「無法確認」。", file=sys.stderr)
    elif git("status", "--porcelain"):
        commit += "-dirty"
        print(f"⚠️ 工作樹有未提交的變更——這份產物對不回任何一個 commit（{commit}）。",
              file=sys.stderr)

    built_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    cmd = [
        flutter_cmd(), "build", "windows", "--release",
        f"--dart-define=CHATROOM_VERSION={VERSION}",
        f"--dart-define=CHATROOM_COMMIT={commit}",
        f"--dart-define=CHATROOM_BUILT_AT={built_at}",
    ]
    print(f"→ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=APP)
    if result.returncode != 0:
        return result.returncode

    # 檢查的是 app.so 而不是 exe：純 Dart 變更不會重寫 exe
    app_so = APP / "build/windows/x64/runner/Release/data/app.so"
    if app_so.exists():
        stamp = datetime.fromtimestamp(app_so.stat().st_mtime).isoformat(
            timespec="seconds")
        print(f"✓ {VERSION}+{commit or 'unknown'} · Dart 產物 {stamp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
