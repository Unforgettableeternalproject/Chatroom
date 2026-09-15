"""打包前先確認「打的是不是要打的那個 commit」。

測試端（Clockwork-Community）2026-09-06 指出的失效形狀：kit 改成在隔離
worktree 上打包之後，舊的失效（工作樹髒 → `-dirty` 後綴）被換成了一個更
安靜的：**checkout 沒做、做錯、或半途失敗**，而版號已經抬上去了——打出來
就是「版號 1.2.0、commit 是舊那個」的包。

`-dirty` 會自己喊出來，這個不會：它安安靜靜地對得回一個真實存在的 commit，
只是錯的那個。`_build.json` 內部完全一致，收到的人驗不出來。

所以需要一個**外部期望值**：打包的人說出「我要打的是哪個 commit」，機器
去比對。這條防線的價值全在於期望值來自打包指令、而不是來自被檢查的那棵樹。
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from buildstamp import require_commit  # noqa: E402


@pytest.fixture
def head(monkeypatch):
    """讓 `require_commit` 看到我們指定的 HEAD。"""
    def _set(value):
        import buildstamp
        monkeypatch.setattr(buildstamp, "git", lambda repo, *a: value)
    return _set


def test_it_passes_when_head_is_what_you_said(head, tmp_path):
    head("abc123def456")
    assert require_commit(tmp_path, "abc123def456") == "abc123def456"


def test_a_short_prefix_is_enough(head, tmp_path):
    """人手上抄的往往是 7 碼短 hash，不該逼他去湊 12 碼。"""
    head("abc123def456")
    assert require_commit(tmp_path, "abc123d") == "abc123def456"


def test_it_stops_the_build_when_head_is_something_else(head, tmp_path):
    """不符就中止——這正是整條防線存在的理由。

    訊息裡兩個值都要有：只說「不符」的話，看的人還得自己去查現在是哪個。
    """
    head("ad360c7aaaaa")
    with pytest.raises(SystemExit) as e:
        require_commit(tmp_path, "9195c60")
    msg = str(e.value)
    assert "ad360c7aaaaa" in msg and "9195c60" in msg


def test_no_expectation_means_no_check(head, tmp_path):
    """沒給期望值就照舊——這道閘是可選的，不是強制的。"""
    head("abc123def456")
    assert require_commit(tmp_path, "") == "abc123def456"


def test_an_unreadable_head_is_a_failure_not_a_pass(head, tmp_path):
    """問不出 HEAD 的時候要中止，不是放行。

    「查不到」與「相符」是兩件事。把前者當後者，等於在最需要這道閘的情況
    （不是 git 工作樹、git 壞了）下自動打開它。
    """
    head("")
    with pytest.raises(SystemExit):
        require_commit(tmp_path, "9195c60")
