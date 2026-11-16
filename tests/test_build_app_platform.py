"""`build-app.py` 的多平台行為：資產名、產物位置、打包內容。

資產名是跟 App 自更新的約定（`app_update_posix.dart` 的 `appAssetSuffixFor`），
名字對不上的話 release 上有檔案、App 卻找不到——而且不會報錯。
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tarfile
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
BUILD_APP = REPO / "scripts" / "build-app.py"
UPDATE_POSIX = REPO / "app" / "lib" / "state" / "app_update_posix.dart"


@pytest.fixture(scope="module")
def build_app():
    sys.path.insert(0, str(REPO / "scripts"))
    spec = importlib.util.spec_from_file_location("build_app_script", BUILD_APP)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_asset_names_follow_the_updater_contract(build_app):
    assert build_app.asset_name("v1.2.9", "windows") == \
        "chatroom-app-v1.2.9-windows-x64.zip"
    assert build_app.asset_name("v1.2.9", "macos") == \
        "chatroom-app-v1.2.9-macos-universal.zip"
    assert build_app.asset_name("v1.2.9-hotfix1", "linux") == \
        "chatroom-app-v1.2.9-hotfix1-linux-x64.tar.gz"


def test_asset_suffixes_match_the_dart_side(build_app):
    """Dart 端的尾巴改了而這裡沒跟，就會是靜默的「找不到資產」。"""
    dart = UPDATE_POSIX.read_text(encoding="utf-8")
    for platform in build_app.PLATFORMS:
        suffix = build_app.asset_name("TAG", platform).removeprefix(
            "chatroom-app-TAG")
        assert f"'{suffix}'" in dart, f"{platform} 的尾巴 {suffix} 不在 Dart 端"


@pytest.mark.parametrize(
    ("plat", "expected"),
    [("win32", "windows"), ("darwin", "macos"), ("linux", "linux")],
)
def test_host_platform(build_app, monkeypatch, plat, expected):
    monkeypatch.setattr(build_app.sys, "platform", plat)
    assert build_app.host_platform() == expected


def test_aot_blob_locations(build_app):
    assert build_app.aot_blob_path("windows").as_posix().endswith(
        "Release/data/app.so")
    assert build_app.aot_blob_path("linux").as_posix().endswith(
        "bundle/lib/libapp.so")
    assert build_app.aot_blob_path("macos").as_posix().endswith(
        "Chatroom.app/Contents/Frameworks/App.framework/Versions/A/App")


def test_flutter_fallback_sdk_is_windows_only(build_app, monkeypatch):
    """寫死的機器路徑不能擴散到 macOS／Linux。"""
    seen: list[str] = []
    monkeypatch.setattr(build_app.shutil, "which", lambda _: None)
    monkeypatch.delenv("FLUTTER_ROOT", raising=False)
    monkeypatch.setattr(build_app.sys, "platform", "linux")
    monkeypatch.setattr(Path, "exists", lambda self: seen.append(str(self)) or False)
    with pytest.raises(SystemExit):
        build_app.flutter_cmd()
    assert not any("Bernie" in s for s in seen)


def test_cross_platform_build_is_refused(build_app, monkeypatch, capsys):
    monkeypatch.setattr(build_app, "host_platform", lambda: "linux")
    assert build_app.main(["--platform", "macos"]) == 1
    assert "macos" in capsys.readouterr().err


def test_package_requires_a_tag(build_app, monkeypatch, capsys):
    monkeypatch.setattr(build_app, "host_platform", lambda: "linux")
    monkeypatch.delenv("CHATROOM_RELEASE_TAG", raising=False)
    assert build_app.main(["--platform", "linux", "--package"]) == 1
    assert "CHATROOM_RELEASE_TAG" in capsys.readouterr().err


def _fake_linux_bundle(app: Path, *, exe_mode: int = 0o755) -> Path:
    bundle = app / build_bundle_rel()
    (bundle / "lib").mkdir(parents=True)
    (bundle / "data").mkdir()
    exe = bundle / "chatroom"
    exe.write_bytes(b"\x7fELF")
    exe.chmod(exe_mode)
    (bundle / "lib" / "libapp.so").write_bytes(b"aot")
    (bundle / "data" / "icudtl.dat").write_bytes(b"icu")
    return bundle


def build_bundle_rel() -> Path:
    return Path("build/linux/x64/release/bundle")


@pytest.mark.skipif(os.name == "nt", reason="Windows 沒有 POSIX 執行位元")
def test_linux_package_layout_and_exec_bit(build_app, monkeypatch, tmp_path):
    monkeypatch.setattr(build_app, "APP", tmp_path / "app")
    _fake_linux_bundle(tmp_path / "app")
    out = build_app.package_app("linux", "v1.2.9", dist=tmp_path / "dist")

    assert out.name == "chatroom-app-v1.2.9-linux-x64.tar.gz"
    with tarfile.open(out) as tf:
        names = set(tf.getnames())
        # 內容在根目錄，不多包一層 bundle/
        assert {"chatroom", "lib/libapp.so", "data/icudtl.dat"} <= names
        assert not any(n.startswith(("bundle", "./", "/")) for n in names)
        assert tf.getmember("chatroom").mode & 0o111


@pytest.mark.skipif(os.name == "nt", reason="Windows 沒有 POSIX 執行位元")
def test_linux_package_refuses_non_executable(build_app, monkeypatch, tmp_path):
    monkeypatch.setattr(build_app, "APP", tmp_path / "app")
    _fake_linux_bundle(tmp_path / "app", exe_mode=0o644)
    with pytest.raises(SystemExit):
        build_app.package_app("linux", "v1.2.9", dist=tmp_path / "dist")


def test_windows_package_has_exe_at_root(build_app, monkeypatch, tmp_path):
    monkeypatch.setattr(build_app, "APP", tmp_path / "app")
    rel = tmp_path / "app" / build_app.WINDOWS_RELEASE
    (rel / "data").mkdir(parents=True)
    (rel / "Chatroom.exe").write_bytes(b"MZ")
    (rel / "data" / "app.so").write_bytes(b"aot")
    out = build_app.package_app("windows", "v1.2.9", dist=tmp_path / "dist")

    assert out.name == "chatroom-app-v1.2.9-windows-x64.zip"
    with zipfile.ZipFile(out) as zf:
        assert {"Chatroom.exe", "data/app.so"} <= set(zf.namelist())
