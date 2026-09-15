"""`.cmd` 批次檔不可以含非 ASCII 字元。

## 為什麼是一條測試而不是一條慣例

`cmd.exe` 用**系統 ANSI 碼頁**讀批次檔，不是 UTF-8。中文註解在 cp950／cp932
底下變成亂碼，而亂碼會把 `rem` 這三個字母吃掉——剩下的內容就不再是註解，
是**命令**。2026-09-11 實際發生的兩行：

    rem …PowerShell 的 *>> 會把 stderr 包成…   →  殘餘含 `*` 與 `>>`，被當成重導向
    rem 日誌按日分檔：logs\\hub-YYYYMMDD.log      →  殘餘被當成要執行的路徑

使用者看到的是兩行紅字，而 Hub 照樣起得來（後面每一行都用 `%~dp0` 絕對路徑，
不受影響）——**所以它不影響功能，只是讓每個第一次架 Hub 的人以為失敗了**。

## 為什麼不是「加 BOM」或「轉成 cp950」

兩條都實測過：

- **加 UTF-8 BOM** → 更糟。BOM 的三個位元組黏在 `@echo off` 前面，那一行整個
  失效，於是**整支腳本開始回顯**，畫面比原本更難看。
- **轉成 cp950** → 這台乾淨了，但那是台灣的碼頁。日文或英文 Windows 讀同一個
  檔案會再變一次亂碼。kit 是要交付給別人的東西，不能綁在某一個地區設定上。

**ASCII 是唯一在所有語系都成立的。** 中文說明搬去 `host-kit/README.md`，
那是 UTF-8 而且沒有人拿 cmd.exe 去解析它。

⚠️ 這條只管 `.cmd`。`.ps1` 不受限——PowerShell 認 BOM，`hub-service.ps1`
就是帶 BOM 的 UTF-8，它的中文註解是安全的。`.py` 同理（Python 3 預設 UTF-8）。
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
CMD_FILES = sorted((REPO / "scripts").glob("*.cmd"))
# `.vbs` 同一個病：wscript 也是用系統 ANSI 碼頁讀檔，不是 UTF-8
VBS_FILES = sorted((REPO / "scripts").glob("*.vbs"))


def test_there_are_cmd_files_to_check():
    """先證明樣本存在。

    這個目錄哪天被搬走的話，底下那條會「全部通過」——而 0 個檔案全部通過
    與真的沒問題，在測試報告上長得一模一樣。
    """
    assert CMD_FILES, "scripts/ 底下找不到任何 .cmd，這條測試等於沒在測"


@pytest.mark.parametrize("path", CMD_FILES, ids=lambda p: p.name)
def test_cmd_file_is_pure_ascii(path: Path):
    raw = path.read_bytes()
    try:
        raw.decode("ascii")
    except UnicodeDecodeError as exc:
        bad = raw[exc.start:exc.end]
        # 把出問題的那一行指出來，不然只有一個位元組偏移量，沒人找得到
        line_no = raw[:exc.start].count(b"\n") + 1
        line = raw.split(b"\n")[line_no - 1].decode("utf-8", errors="replace")
        pytest.fail(
            f"{path.name} 第 {line_no} 行有非 ASCII 位元組 {bad!r}：\n"
            f"    {line.strip()}\n"
            "cmd.exe 用系統 ANSI 碼頁讀 .cmd，中文會變亂碼並把 rem 吃掉，"
            "殘餘內容會被當成命令執行。請改成英文註解。"
        )


@pytest.mark.parametrize("path", CMD_FILES, ids=lambda p: p.name)
def test_cmd_file_has_no_bom(path: Path):
    """BOM 會讓第一行失效（實測：`@echo off` 整個不生效，全腳本開始回顯）。"""
    assert not path.read_bytes().startswith(b"\xef\xbb\xbf"), (
        f"{path.name} 帶 UTF-8 BOM。cmd.exe 不認它，那三個位元組會黏在"
        "第一行前面讓那一行失效。"
    )


def test_there_are_vbs_files_to_check():
    """同樣先證明樣本存在——0 個檔案「全部通過」與真的沒問題長得一樣。"""
    assert VBS_FILES, "scripts/ 底下找不到任何 .vbs，這條測試等於沒在測"


@pytest.mark.parametrize("path", VBS_FILES, ids=lambda p: p.name)
def test_vbs_file_is_pure_ascii(path: Path):
    """`.vbs` 與 `.cmd` 同一個病：wscript 用系統 ANSI 碼頁讀檔。

    差別只在後果的形狀——`.cmd` 的亂碼會被當成命令執行（看得到紅字），
    `.vbs` 的亂碼多半直接是語法錯誤，而它跑在隱藏視窗裡，
    **使用者只會看到「按了啟動 Hub 但什麼都沒發生」**，連錯誤訊息都沒有。
    """
    raw = path.read_bytes()
    try:
        raw.decode("ascii")
    except UnicodeDecodeError as exc:
        line_no = raw[:exc.start].count(b"\n") + 1
        line = raw.split(b"\n")[line_no - 1].decode("utf-8", errors="replace")
        pytest.fail(
            f"{path.name} 第 {line_no} 行有非 ASCII 位元組 {raw[exc.start:exc.end]!r}：\n"
            f"    {line.strip()}\n"
            "wscript 用系統 ANSI 碼頁讀 .vbs，非 ASCII 會變亂碼。"
            "而它跑在隱藏視窗裡，壞掉時使用者看不到任何錯誤。"
        )
