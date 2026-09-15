"""版本戳記的 dirty 判定必須 scope 到「實際進產物的路徑」。

存在的理由：Hub 的版本會因為**別人在改 Flutter** 而被標成 `-dirty`。
2026-09-05 實測，工作樹四個髒檔裡兩個在 `app/`、一個在 `server/`——
而 `app/` 那兩個一行都不會進 Hub 的交付包。版本字串要回答的是
「執行中的這份程式碼對得回哪個 commit」，scope 外的改動不改變那個答案，
卻會讓每一份產物都掛上「對不回任何 commit」的警告。警告一旦恆真就沒人看。

⚠️ scope **內**的 untracked 仍然算髒：新檔案沒 commit，一樣對不回去。
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]


def _load(path: Path):
    """直接載入單一 version.py，不經過 package __init__。"""
    spec = importlib.util.spec_from_file_location(f"ver_{path.parent.name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _fake_git(scope_prefix: str, calls: list):
    """假的 git：scope 外有髒檔，scope 內乾淨。

    帶了正確 scope 的實作看到的是「乾淨」；沒帶 scope 的實作看到
    scope 外那個髒檔，於是標上 `-dirty`——這正是要擋掉的行為。
    """
    def _git(root, *args):
        calls.append(args)
        if args[0] == "rev-parse":
            return "abcdef123456"
        if args[0] == "status":
            scoped = [a for a in args if a.startswith(scope_prefix)]
            return "" if scoped else " M somewhere/else.dart"
        return ""
    return _git


@pytest.mark.parametrize(
    ("version_py", "scope_prefix"),
    [
        (REPO / "server" / "chatroom_server" / "version.py", "server/"),
        (REPO / "bridge" / "chatroom_mcp" / "version.py", "bridge/"),
    ],
    ids=["hub", "bridge"],
)
def test_dirty_judgement_is_scoped_to_shipped_paths(version_py, scope_prefix,
                                                    monkeypatch):
    mod = _load(version_py)
    calls: list = []
    monkeypatch.setattr(mod, "_git", _fake_git(scope_prefix, calls))

    info = mod._from_git()

    assert info is not None, "開發機上跑 source 時應該問得出 git 版本"
    status_args = [a for a in calls if a and a[0] == "status"]
    assert status_args, "沒有問過工作樹髒不髒"
    assert any(a.startswith(scope_prefix) for a in status_args[0]), (
        f"dirty 判定沒有 scope 到 {scope_prefix}——"
        f"實際問的是 {status_args[0]}"
    )
    assert not info["commit"].endswith("-dirty"), (
        "scope 外的改動不該讓這份產物被標成 -dirty"
    )


def test_scope_internal_untracked_still_counts_dirty(monkeypatch):
    """scope 內的新檔案沒 commit，一樣對不回任何 commit。"""
    mod = _load(REPO / "server" / "chatroom_server" / "version.py")

    def _git(root, *args):
        if args[0] == "rev-parse":
            return "abcdef123456"
        if args[0] == "status":
            return "?? server/chatroom_server/brand_new.py"
        return ""

    monkeypatch.setattr(mod, "_git", _git)
    assert mod._from_git()["commit"].endswith("-dirty")


def _load_stamp(source: Path):
    """載入一份 buildstamp（可以是舊版），用來驗測試自己會不會紅。"""
    spec = importlib.util.spec_from_file_location("bs_probe", source)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _stamp_with_fake_git(mod, tmp_path, scope, monkeypatch):
    """跑 stamp()，git 假裝「scope 外髒、scope 內乾淨」。"""
    def _git(repo, *args):
        if args[0] == "rev-parse":
            return "abcdef123456"
        if args[0] == "status":
            scoped = [a for a in args if a in scope]
            return "" if scoped else " M app/lib/whatever.dart"
        return ""

    monkeypatch.setattr(mod, "git", _git)
    target = tmp_path / "_build.json"
    return mod.stamp(REPO, target, "9.9.9", scope=scope)


def test_stamp_scope_ignores_paths_outside_the_package(tmp_path, monkeypatch):
    """打包 install-kit 時，`app/` 有人在改不該讓這份 kit 標 -dirty。"""
    mod = _load_stamp(REPO / "scripts" / "buildstamp.py")
    info = _stamp_with_fake_git(mod, tmp_path, ("bridge/", "install-kit/"),
                                monkeypatch)
    assert not info["commit"].endswith("-dirty"), (
        "scope 外的改動污染了 kit 的版本戳記"
    )
