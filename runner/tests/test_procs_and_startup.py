"""pythonw 底下跑得起來的三個前提。

2026-09-17：排程工作的動作是 `python.exe -m chatroom_runner`，工作目錄是
repo root，而 `runner\\` 從來沒有被放進 `sys.path`——腳本註解說「用
PYTHONPATH」，但**排程工作設不了環境變數**。結果是每次啟動都
`No module named chatroom_runner`、退出碼 1，再被重啟設定每分鐘拉一次，
畫面上就是一直閃的 cmd 視窗。

這裡守三件事：子進程不開視窗的旗標、`sys.stderr is None` 時 logging 不炸、
安裝腳本確實寫 `.pth` 並用 `pythonw`。
"""

from __future__ import annotations

import logging
import subprocess
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

from chatroom_runner import procs
from chatroom_runner.__main__ import _setup_logging

RUNNER_DIR = Path(__file__).resolve().parents[1]


def test_no_window_kwargs_on_windows(monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")
    assert procs.no_window_kwargs() == {
        "creationflags": subprocess.CREATE_NO_WINDOW}


def test_no_window_kwargs_elsewhere(monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    assert procs.no_window_kwargs() == {}


def test_setup_logging_survives_missing_stderr(monkeypatch, tmp_path):
    """pythonw 沒有 console，`sys.stderr` 是 None。

    掛上去的 StreamHandler 不會當場炸（logging 吞掉 AttributeError），
    所以驗的是它根本沒被掛上，同時確認檔案那條路仍然寫得進去。
    """
    monkeypatch.setattr(sys, "stderr", None)
    root = logging.getLogger()
    before = list(root.handlers)
    try:
        _setup_logging(tmp_path / "logs")
        added = [h for h in root.handlers if h not in before]
        logging.getLogger("chatroom_runner.test").info("寫得進去")
    finally:
        for h in list(root.handlers):
            if h not in before:
                root.removeHandler(h)
                h.close()
    # 掛一個 stream 是 None 的 handler 不會拋（logging 自己吞掉 AttributeError），
    # 所以這條驗的是「根本沒掛上去」，不是「沒炸」
    assert all(not isinstance(h, logging.StreamHandler)
               or isinstance(h, RotatingFileHandler) for h in added), added
    assert (tmp_path / "logs" / "runner.log").read_text(
        encoding="utf-8").strip().endswith("寫得進去")


def test_install_task_writes_pth_and_uses_pythonw():
    """安裝腳本的守門：兩個機制都在，而且沒有留下「用 PYTHONPATH」的假說明。"""
    text = (RUNNER_DIR / "install-task.ps1").read_text(encoding="utf-8")
    assert "chatroom_runner.pth" in text
    assert "sysconfig.get_paths()['purelib']" in text
    assert "pythonw.exe" in text
    # 註冊完要當場驗，不然「工作建好了」與「它跑得起來」是兩件事
    assert 'import chatroom_runner' in text
