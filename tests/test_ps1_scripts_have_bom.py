"""含非 ASCII 的 `.ps1` 必須帶 UTF-8 BOM。

Windows PowerShell 5.1 讀無 BOM 的腳本時用系統 ANSI 碼頁（台灣是 cp950），
不是 UTF-8。中文註解與字串會變亂碼，輕則字串壞掉，重則吃掉引號或換行造成
ParserError——2026-11 的 `runner/install-task.ps1` 就是這樣在第 48 行附近
解析失敗，排程註冊整個沒做。

與 `.cmd` 相反（見 test_cmd_scripts_encoding.py）：PowerShell 認 BOM，
所以 `.ps1` 的解法是加 BOM，不是改成 ASCII。純 ASCII 的 `.ps1` 不受影響。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
BOM = b"\xef\xbb\xbf"


def _tracked_ps1() -> list[str]:
    out = subprocess.run(["git", "ls-files", "*.ps1"], cwd=str(REPO),
                         capture_output=True, text=True, encoding="utf-8",
                         check=True).stdout
    return sorted(line.strip() for line in out.splitlines() if line.strip())


PS1_FILES = _tracked_ps1()


def test_there_are_ps1_files_to_check():
    """先證明樣本存在：0 個檔案「全部通過」與真的沒問題長得一樣。"""
    assert PS1_FILES, "git ls-files 找不到任何 .ps1，這條測試等於沒在測"


@pytest.mark.parametrize("rel", PS1_FILES)
def test_ps1_with_non_ascii_has_utf8_bom(rel: str):
    raw = (REPO / rel).read_bytes()
    if raw.isascii():
        return
    assert raw.startswith(BOM), (
        f"{rel} 含非 ASCII 位元組但沒有 UTF-8 BOM。Windows PowerShell 5.1 "
        "會用系統碼頁（cp950）解碼，中文變亂碼甚至 ParserError。"
        "請把檔案存成 UTF-8 with BOM。"
    )
