"""語意版本寫在三個地方，這裡守著它們一致。

Hub、bridge、App 各自帶版本，而使用者回報問題時講的是「我是 1.2.2」——
三邊漂移的話那句話就沒有意義了，而漂移**不會有任何東西報錯**：各自都是
合法的字串，各自的 build 都會成功。

（`build_info.dart` 的 `CHATROOM_VERSION` defaultValue 刻意**不在**這份
名單裡：它是「--dart-define 沒生效」的哨兵值，跟著 bump 就失去作用了。）
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _app_version_py(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("APP_VERSION"):
            return line.split("=", 1)[1].strip().strip("\"'")
    raise AssertionError(f"{path} 裡找不到 APP_VERSION")


def _pubspec_version(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("version:"):
            # `1.2.2+1` → `1.2.2`；build number 由 commit 短碼擔任
            return line.split(":", 1)[1].strip().split("+", 1)[0]
    raise AssertionError(f"{path} 裡找不到 version:")


def test_hub_bridge_and_app_report_the_same_version():
    hub = _app_version_py(ROOT / "server" / "chatroom_server" / "version.py")
    bridge = _app_version_py(ROOT / "bridge" / "chatroom_mcp" / "version.py")
    app = _pubspec_version(ROOT / "app" / "pubspec.yaml")
    assert hub == bridge == app, (
        f"版本漂移了：Hub={hub} bridge={bridge} App={app}。"
        "bump 版本時三個地方都要改。"
    )


def test_version_looks_like_a_semver():
    hub = _app_version_py(ROOT / "server" / "chatroom_server" / "version.py")
    assert re.fullmatch(r"\d+\.\d+\.\d+", hub), f"版本格式怪怪的：{hub}"


def test_dart_sentinel_is_not_bumped_along():
    """`build_info.dart` 的 defaultValue 是哨兵，不是版本。

    它的用途是讓 buildstamp 抓出「--dart-define 沒生效」——2026-08-31 有一份
    App 印著 1.1.5 而產物裡是 1.0.0，就是靠這個值抓到的。跟著 bump 的話，
    產物裡是預設值還是真的版本就分不出來了。
    """
    text = (ROOT / "app" / "lib" / "core" / "config" / "build_info.dart").read_text(
        encoding="utf-8")
    m = re.search(r"CHATROOM_VERSION'\s*,\s*defaultValue:\s*'([^']+)'", text, re.S)
    assert m, "build_info.dart 裡找不到 CHATROOM_VERSION 的 defaultValue"
    current = _app_version_py(ROOT / "server" / "chatroom_server" / "version.py")
    assert m.group(1) != current, (
        "哨兵值與真實版本相同了——那樣就分不出「產物裡是預設值」與"
        "「--dart-define 有生效」"
    )
