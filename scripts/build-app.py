"""Build App（Windows／macOS／Linux），並把「這是哪一份程式碼」編進產物。

**一定要走這支，不要直接 `flutter build windows`。** 少帶 `--dart-define`
的話 App 講不出自己是哪一份，而那正是這次事故的成因——版本資訊在 build
當下抓得到，錯過就永遠是 unknown。

兩個這次真的踩到的坑，都在這裡擋掉：

1. **App 開著時 build 會失敗，而失敗看起來像成功。** linker 寫不進被佔用的
   exe（LNK1104），但 `flutter build` 結尾只印一行 `Build process failed`，
   前面那行錯誤淹在輸出裡，而舊產物完好地留在原地。這支會先檢查行程。
2. **exe 的時間戳不代表 Dart 程式碼有沒有更新。** 純 Dart 變更不會重寫
   `Chatroom.exe`（那是 C++ runner 殼），更新的是 `data/app.so`。
   照 exe 判會誤報成「沒 rebuild」——這次就是這樣判的。
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from buildstamp import dart_default_version, verify_embedded

# Windows 主控台預設 CP950，訊息裡的 ✓ ⚠️ ✕ 會讓 print 直接拋
# UnicodeEncodeError——build 明明成功卻以例外收場，看起來像失敗。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
# 這台 Windows 開發機的 SDK 位置；PATH 與 FLUTTER_ROOT 都沒有時的最後退路。
# 只給 Windows 用——macOS／Linux（含 CI）一律靠 PATH 或 FLUTTER_ROOT。
_FALLBACK_SDK = r"C:\Users\Bernie\dev\flutter"

PLATFORMS = ("windows", "macos", "linux")
DIST = ROOT / "dist"

# 各平台 build 產物的位置，相對於 `app/`。
WINDOWS_RELEASE = Path("build/windows/x64/runner/Release")
LINUX_BUNDLE = Path("build/linux/x64/release/bundle")
MACOS_APP = Path("build/macos/Build/Products/Release/Chatroom.app")


def host_platform() -> str:
    """依 `sys.platform` 推斷預設目標平台。"""
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def asset_name(tag: str, platform: str) -> str:
    """Release 資產檔名；與 `app_update_posix.dart` 的 `appAssetSuffixFor` 對齊。"""
    suffix = {
        "windows": "windows-x64.zip",
        "macos": "macos-universal.zip",
        "linux": "linux-x64.tar.gz",
    }[platform]
    return f"chatroom-app-{tag}-{suffix}"


def aot_blob_path(platform: str) -> Path:
    """AOT 產物（Dart 程式碼編譯後的檔案）的位置；版本字串驗的是它。

    macOS 的 framework 版本目錄名不寫死，兩種佈局都找。
    """
    if platform == "windows":
        return APP / WINDOWS_RELEASE / "data/app.so"
    if platform == "linux":
        return APP / LINUX_BUNDLE / "lib/libapp.so"
    framework = APP / MACOS_APP / "Contents/Frameworks/App.framework"
    for candidate in (framework / "Versions/A/App", framework / "App"):
        if candidate.exists():
            return candidate
    return framework / "Versions/A/App"


def app_version() -> str:
    """App 的語意版本，唯一真相是 app/pubspec.yaml。

    這裡曾經是一行 `VERSION = "1.0.0"`，於是 pubspec 推到 1.1.0 之後，
    build 出來的 App 仍然自稱 1.0.0——而版本資訊在 build 當下編進產物，
    錯過就永遠是錯的，事後從產物完全看不出來。版本只寫在一個地方。
    """
    text = (APP / "pubspec.yaml").read_text(encoding="utf-8")
    for line in text.splitlines():
        if line.startswith("version:"):
            # `1.1.0+1` → `1.1.0`；build number 由 commit 短碼擔任
            return line.split(":", 1)[1].strip().split("+", 1)[0]
    raise SystemExit("✕ app/pubspec.yaml 裡找不到 version:——無法判定版本")


def hotfix_number(tag: str) -> int:
    """Release tag 的熱修序號：`v1.2.5-hotfix2` → 2，沒有後綴就是 0。

    熱修不動版號（見 release.yml 的版本一致性檢查），App 要另外知道自己是
    第幾個熱修，檢查更新時才分得出 `v1.2.5` 與 `v1.2.5-hotfix2`。
    """
    m = re.search(r"-hotfix(\d+)$", tag.strip())
    return int(m.group(1)) if m else 0


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
    candidates = [os.environ.get("FLUTTER_ROOT", "")]
    if sys.platform == "win32":
        candidates.append(_FALLBACK_SDK)
    for candidate in candidates:
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


# 這個 App 在工作管理員裡的名字。**進程名跟著 exe 檔名走**（`BINARY_NAME`），
# 所以改了 exe 名就要改這裡——而且這個閘不改也不會報錯，只會永遠抓不到。
#
# ⚠️ **舊名要留著。** 09/14 從 `chatroom_app.exe` 改名成 `Chatroom.exe`，
# 而**改名那一輪正是舊 exe 最可能還開著的時候**（使用者手上跑的就是舊版）。
# 只查新名的話，閘會在最需要它的那一次失明。
#
# 而且被鎖住的**不是 exe 本身**——新舊 exe 是兩個不同檔案，不衝突。真正會
# 被鎖的是同目錄的共享產物（`flutter_windows.dll`、`data\`），舊進程照樣
# 開著它們，於是 build 仍然會失敗，只是失敗的位置換了一個。
APP_PROCESS_NAMES = ("Chatroom", "chatroom_app")


def running_app_pids() -> list[tuple[str, str]]:
    """回傳還開著的 App 行程：`(進程名, PID)`。

    回傳名字而不只是 PID——過渡期同時查新舊兩個名，**訊息要講得出使用者
    該關掉哪一個**。只印 PID 的話，開著舊版的人會去工作管理員找一個叫
    `Chatroom` 的東西，而他手上那個叫 `chatroom_app`。
    """
    if sys.platform != "win32":
        return []
    names = ",".join(APP_PROCESS_NAMES)
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         f"Get-Process {names} -ErrorAction SilentlyContinue"
         " | ForEach-Object { \"$($_.ProcessName) $($_.Id)\" }"],
        capture_output=True, text=True,
    )
    found: list[tuple[str, str]] = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            found.append((parts[0], parts[1]))
    return found


# 這份產物實際收錄的路徑。**只問這裡髒不髒**——同一棵樹上另外兩個 kit 各自
# 只問 `bridge/` 與 `server/`（見 `buildstamp.stamp` 的 `scope`），App 沒有
# 理由因為別人在改 server 就被標成「對不回任何 commit」。
#
# 開成整棵樹的代價不是誤報一次而已：三個人同時開發時它幾乎恆為 `-dirty`，
# 而恆真的警告沒有人看——那時真的髒到 `app/` 也看不出來。
DIRTY_SCOPE = ("app",)


def commit_stamp() -> str:
    """要編進產物的 commit 短碼，髒了就帶 `-dirty`。

    抓不到 commit 時回空字串——那時**不**補 `-dirty`，因為沒有基準可以說它
    偏離了什麼。
    """
    commit = git("rev-parse", "--short=12", "HEAD")
    if not commit:
        return ""
    if git("status", "--porcelain", "--", *DIRTY_SCOPE):
        commit += "-dirty"
    return commit


def package_app(platform: str, tag: str, dist: Path = DIST) -> Path:
    """把 build 產物打成 Release 資產，回傳檔案路徑。

    資產名與內容是跟 App 自更新的約定（見 `app_update_posix.dart`）：
    - windows：`Release/` 目錄的內容（根目錄就是 `Chatroom.exe`）。
    - macos：`Chatroom.app` 本身在根目錄（等同 `ditto -c -k --keepParent`）。
    - linux：Flutter `bundle/` 的內容在根目錄，執行檔 `chatroom` 要保有執行位元。
    """
    dist.mkdir(parents=True, exist_ok=True)
    out = dist / asset_name(tag, platform)
    out.unlink(missing_ok=True)

    if platform == "windows":
        src = APP / WINDOWS_RELEASE
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            for path in sorted(src.rglob("*")):
                zf.write(path, path.relative_to(src).as_posix())
    elif platform == "macos":
        # ditto 保留 symlink 與簽章需要的屬性，zipfile 做不到
        subprocess.run(
            ["ditto", "-c", "-k", "--keepParent", str(APP / MACOS_APP), str(out)],
            check=True,
        )
    else:
        src = APP / LINUX_BUNDLE
        exe = src / "chatroom"
        if not exe.exists():
            raise SystemExit(f"✕ 找不到 {exe}——不打包。")
        if not os.access(exe, os.X_OK):
            raise SystemExit(f"✕ {exe} 沒有執行位元——解壓後會跑不起來。")
        with tarfile.open(out, "w:gz") as tf:
            for path in sorted(src.iterdir()):
                tf.add(path, arcname=path.name)
    return out


def main(argv: list[str] = ()) -> int:
    # 預設不讀 sys.argv：被當函式呼叫（測試、其他腳本）時不該吃到呼叫方的參數；
    # 命令列入口在檔尾明確傳 sys.argv[1:]
    parser = argparse.ArgumentParser(description="Build Chatroom App")
    parser.add_argument("--platform", choices=PLATFORMS, default=host_platform(),
                        help="目標平台（預設依本機）")
    parser.add_argument("--package", action="store_true",
                        help="build 後打成 Release 資產到 dist/"
                             "（tag 取自 CHATROOM_RELEASE_TAG）")
    parser.add_argument("--package-only", action="store_true",
                        help="不 build，只把既有產物打包（簽章之後用）")
    args = parser.parse_args(argv)
    platform = args.platform
    args.package = args.package or args.package_only

    if platform != host_platform():
        print(f"✕ flutter 無法在 {host_platform()} 上 build {platform}。",
              file=sys.stderr)
        return 1
    tag = os.environ.get("CHATROOM_RELEASE_TAG", "").strip()
    if args.package and not tag:
        print("✕ --package 需要 CHATROOM_RELEASE_TAG（資產名含 tag）。",
              file=sys.stderr)
        return 1

    if args.package_only:
        print(f"✓ 已打包 {package_app(platform, tag)}")
        return 0

    running = running_app_pids()
    if running:
        listed = "、".join(f"{name}（PID {pid}）" for name, pid in running)
        print(f"✕ {listed} 正在執行。", file=sys.stderr)
        print("  linker 寫不進被佔用的 exe，而失敗會留下一個看起來成功的現場——",
              file=sys.stderr)
        print("  舊產物完好地待在原地。請先關閉 App 再重跑。", file=sys.stderr)
        if any(name == "chatroom_app" for name, _ in running):
            # 改名過渡期：他手上那個視窗的標題已經是 Chatroom，但工作管理員
            # 裡的名字還是舊的。不講的話他會找不到要關哪一個
            print("  （`chatroom_app` 是改名前的舊版。視窗標題一樣是 Chatroom，",
                  file=sys.stderr)
            print("   但工作管理員裡叫舊名字。）", file=sys.stderr)
        return 1

    version = app_version()
    commit = commit_stamp()
    if not commit:
        print("⚠️ 抓不到 commit（不在 git 工作樹？）。", file=sys.stderr)
        print("  這份產物將無法對帳版本，Hub 比對會顯示「無法確認」。", file=sys.stderr)
    elif commit.endswith("-dirty"):
        print(f"⚠️ {'/'.join(DIRTY_SCOPE)} 有未提交的變更——"
              f"這份產物對不回任何一個 commit（{commit}）。", file=sys.stderr)

    built_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    # Release 流程帶進來的 tag；本機 build 沒設就是 0
    hotfix = hotfix_number(tag)
    cmd = [
        flutter_cmd(), "build", platform, "--release",
        f"--dart-define=CHATROOM_VERSION={version}",
        f"--dart-define=CHATROOM_COMMIT={commit}",
        f"--dart-define=CHATROOM_BUILT_AT={built_at}",
        f"--dart-define=CHATROOM_HOTFIX={hotfix}",
    ]
    print(f"→ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=APP)
    if result.returncode != 0:
        return result.returncode

    # 檢查的是 AOT 產物而不是外殼：純 Dart 變更不會重寫 exe
    app_so = aot_blob_path(platform)
    if not app_so.exists():
        print(f"✕ 找不到 {app_so.relative_to(APP).as_posix()}"
              "——build 回報成功卻沒有產物。", file=sys.stderr)
        return 1

    # **驗產物，不要只印自己打算做的事。** 上面那行 print 印的是「要編進去
    # 的值」，而 2026-08-31 有一份 App 印著 ✓ 1.1.5+<hash>、產物裡卻是
    # 1.0.0——沒有任何地方報錯，直到有人去讀畫面右上角（F15）
    problems = verify_embedded(
        app_so.read_bytes(), version, commit,
        dart_default_version(APP / "lib/core/config/build_info.dart"),
    )
    if problems:
        print("✕ 產物與這次 build 對不上：", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("  這份產物講不出自己是哪一版，不要拿去交付。"
              "常見原因：另一個不帶 --dart-define 的 flutter build 蓋掉了它。",
              file=sys.stderr)
        return 1

    stamp = datetime.fromtimestamp(app_so.stat().st_mtime).isoformat(
        timespec="seconds")
    print(f"✓ {version}+{commit or 'unknown'} · Dart 產物 {stamp}"
          f" · 版本字串已在產物中驗證")

    if args.package:
        print(f"✓ 已打包 {package_app(platform, tag)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
