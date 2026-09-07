"""App 產物的 `-dirty` 只該由 `app/` 決定。

2026-09-07：`build-app.py` 印出 `1.2.1+eded43899c03-dirty`，而 `app/` 當時是
乾淨的——髒的是另一個 session 手上的 `server/chatroom_server/app.py` 與三個
未追蹤的 `tests/` 檔，與這份產物一個字都無關。

`install-kit` / `host-kit` 早就改成按 scope 判（各自只問 `bridge/` /
`server/`，見 `buildstamp.stamp` 的 `scope` 參數與那段註解），**App 這支沒跟
上，還在問整棵樹**。三個人同時開發時它幾乎恆為 `-dirty`，而恆真的警告沒有人
看——那正是 `buildstamp.report` 上面那段事故的下一步。

`buildstamp.py` 開頭那句「兩份產物的版本語意必須一致」在這裡失守：一邊標
`-dirty` 一邊不標的話，交叉比對就失去意義。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
BUILD_APP = REPO / "scripts" / "build-app.py"


@pytest.fixture(scope="module")
def build_app():
    sys.path.insert(0, str(REPO / "scripts"))
    spec = importlib.util.spec_from_file_location("build_app_script", BUILD_APP)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _fake_git(module, monkeypatch, *, head: str, dirty_for: dict[str, str]):
    """假的 git：依查詢的路徑回不同的 porcelain 結果。

    key 是被問到的 pathspec（`git status --porcelain -- <path>` 的 path），
    空字串代表「問整棵樹」。
    """
    calls: list[tuple[str, ...]] = []

    def fake(*args: str) -> str:
        calls.append(args)
        if args[:1] == ("rev-parse",):
            return head
        if args[:1] == ("status",):
            scope = args[3] if len(args) > 3 else ""
            return dirty_for.get(scope, "")
        return ""

    monkeypatch.setattr(module, "git", fake)
    return calls


def test_server_side_changes_do_not_dirty_the_app_build(build_app, monkeypatch):
    """別人在改 server/、tests/ 時，App 產物仍然對得回一個 commit。"""
    _fake_git(
        build_app, monkeypatch,
        head="eded43899c03",
        dirty_for={
            "": " M server/chatroom_server/app.py\n?? tests/conftest.py",
            "app": "",
        },
    )
    assert build_app.commit_stamp() == "eded43899c03"


def test_app_side_changes_still_dirty_the_build(build_app, monkeypatch):
    """`app/` 自己髒掉時照樣要標——這道警告不是拿掉，是收窄。"""
    _fake_git(
        build_app, monkeypatch,
        head="eded43899c03",
        dirty_for={
            "": " M app/lib/main.dart",
            "app": " M app/lib/main.dart",
        },
    )
    assert build_app.commit_stamp() == "eded43899c03-dirty"


def test_the_scope_is_actually_passed_to_git(build_app, monkeypatch):
    """釘住「有問 pathspec」這件事本身。

    只斷言結果的話，把 scope 寫錯成一個不存在的路徑也會過（永遠乾淨）。
    """
    calls = _fake_git(
        build_app, monkeypatch, head="abc123456789", dirty_for={})
    build_app.commit_stamp()
    status_calls = [c for c in calls if c[:1] == ("status",)]
    assert status_calls, "沒有問過 git status"
    assert all("--" in c and "app" in c for c in status_calls), status_calls


def test_no_commit_means_no_stamp(build_app, monkeypatch):
    """抓不到 commit 時不要憑空生一個 `-dirty` 出來。"""
    _fake_git(build_app, monkeypatch, head="", dirty_for={"": " M x", "app": " M x"})
    assert build_app.commit_stamp() == ""
