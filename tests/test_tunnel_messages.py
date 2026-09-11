"""給人看的訊息，不可以叫他用一個不存在的旗標。

2026-09-11 測試端實測撞到：遮蔽系統 cloudflared 後跑 `--no-download`，
腳本回「加 `--download` 讓本腳本自動抓官方執行檔」——**而 `--download`
從來不存在**（下載是預設行為，只有關閉它的 `--no-download`）。

照著做的人會拿到 `unrecognized arguments`，然後開始懷疑是不是自己裝錯了。
這種錯誤有兩層惡劣：訊息本身錯，而且它把使用者推向一條走不通的路——
**一個沒有訊息的失敗，反而比一個指錯方向的訊息容易查。**

這條測試把「訊息裡提到的旗標必須真的存在」變成機器可驗的。
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = sorted(
    p for p in (REPO / "scripts").glob("*.py") if not p.name.startswith("_")
)

FLAG_RE = re.compile(r"--[a-z][a-z0-9-]+")

# 只看**講給人聽**的字串。
#
# 第一版掃了所有字串常數，於是把 `git --porcelain`、`flutter --dart-define`
# 這些傳給外部程式的參數也算進來——那要靠一份越補越長的白名單才壓得住，
# 而白名單每長一條就少守一點。改成從呼叫的位置判斷：錯誤訊息與提示才算。
MESSAGE_CALLS = {"SystemExit", "print", "error", "fail", "RuntimeError",
                 "ValueError", "FileNotFoundError"}

# 訊息裡合理提到的**外部程式**旗標。
#
# 縮到只看訊息之後仍有這一種：`build-app.py` 的錯誤訊息說「常見原因：另一個
# 不帶 --dart-define 的 flutter build 蓋掉了它」——那是在講 flutter 的旗標，
# 不是叫使用者對這支腳本用它。這種訊息是對的，不該被擋。
#
# ⚠️ **這份清單每長一條就少守一點**，所以加之前先問：這個旗標真的屬於別人家
# 的程式，還是我正要放行一個打錯的自家旗標？
FOREIGN_FLAGS = {"--dart-define"}


def declared_flags(tree: ast.AST) -> set[str]:
    """這支腳本用 argparse 宣告了哪些旗標。"""
    flags: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if not (isinstance(func, ast.Attribute) and func.attr == "add_argument"):
            continue
        # ⚠️ **`--no-x` 不會自動帶出 `--x`。**
        #
        # 這裡第一版寫了「`--no-x` 的 argparse 對應項也算宣告過」，於是
        # `--no-download` 讓 `--download` 變成已宣告——而 `--download` 正是
        # 這條測試要抓的那個不存在的旗標。**測試因此對它唯一的目標失明，
        # 而且照樣全綠。** 實測：把 bug 放回去，12 passed。
        #
        # `action="store_false"` 只產生 `--no-download` 一個旗標。會自動
        # 成對的是 `argparse.BooleanOptionalAction`，這個 repo 沒有用。
        # 哪天用了，那時要在這裡加判斷，而不是無條件補對應項。
        for arg in node.args:
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                if arg.value.startswith("--"):
                    flags.add(arg.value)
    return flags


def _call_name(node: ast.Call) -> str:
    func = node.func
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return ""


def flags_mentioned_in_messages(tree: ast.AST) -> set[str]:
    """給人看的訊息裡提到的旗標。

    「給人看」＝ 出現在 `SystemExit(...)` / `print(...)` / `parser.error(...)`
    這類呼叫的引數裡。組給外部程式的參數（`["git", "status", "--porcelain"]`）
    不算——那不是講給人聽的話。
    """
    found: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or _call_name(node) not in MESSAGE_CALLS:
            continue
        for arg in ast.walk(node):
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                found.update(FLAG_RE.findall(arg.value))
    return found


@pytest.mark.parametrize("path", SCRIPTS, ids=lambda p: p.name)
def test_messages_only_mention_flags_that_exist(path: Path):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    declared = declared_flags(tree)
    mentioned = flags_mentioned_in_messages(tree)

    unknown = mentioned - declared - FOREIGN_FLAGS
    assert not unknown, (
        f"{path.name} 的字串裡提到這些旗標，但 argparse 沒有宣告："
        f"{sorted(unknown)}。照著做的人會拿到 unrecognized arguments，"
        "然後去懷疑是不是自己裝錯了。"
    )


def test_there_are_scripts_to_check():
    """先證明樣本存在——0 個檔案「全部通過」與真的沒問題長得一樣。"""
    assert SCRIPTS, "scripts/ 底下找不到任何 .py"
