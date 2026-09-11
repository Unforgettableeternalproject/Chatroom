"""主機控制台按下去的腳本，必須真的在 kit 裡。

這條守的是一個開發機上完全看不見的落差：App 的 `HostActions` 用
`_script('x.py')` 組路徑，而 kit 裡有沒有那支檔案由 `host-kit/build.py`
的複製清單決定。**開發機上 repo 的 `scripts/` 什麼都有**，所以在這台
機器上按每一顆按鈕都會成功；主持人拿到的那包少了一支，按下去才發現。

兩邊的清單沒有任何機制把它們綁在一起——除了這個測試。
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HOST_ACTIONS = REPO / "app" / "lib" / "state" / "host_actions.dart"
BUILD_PY = REPO / "host-kit" / "build.py"


def scripts_called_by_app() -> set[str]:
    """App 端 `_script('...')` 用到的檔名。"""
    text = HOST_ACTIONS.read_text(encoding="utf-8")
    return set(re.findall(r"_script\(\s*'([^']+)'\s*\)", text))


def scripts_packed_by_build() -> set[str]:
    """`build.py` 複製進 `stage/scripts/` 的檔名。

    直接解析 AST 而不是 import——build.py 在 import 時會去讀 git，
    而測試不該依賴工作區的 git 狀態。
    """
    tree = ast.parse(BUILD_PY.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if not isinstance(node, ast.For):
            continue
        if not (isinstance(node.target, ast.Name) and node.target.id == "name"):
            continue
        if not isinstance(node.iter, (ast.Tuple, ast.List)):
            continue
        names = {
            e.value
            for e in node.iter.elts
            if isinstance(e, ast.Constant) and isinstance(e.value, str)
        }
        if names:
            return names
    raise AssertionError("在 build.py 裡找不到 scripts 的複製清單")


def test_every_script_the_app_calls_is_packed():
    missing = scripts_called_by_app() - scripts_packed_by_build()
    assert not missing, (
        f"這些腳本 App 會呼叫，但 host-kit/build.py 沒有打包進去：{sorted(missing)}。"
        "開發機上按得動、主持人的 kit 按下去會找不到檔案"
    )


def test_every_packed_script_exists_in_the_repo():
    """清單裡寫了但 repo 裡沒有的話，打包當場就會炸——寧可在這裡先紅。"""
    missing = [
        name for name in scripts_packed_by_build()
        if not (REPO / "scripts" / name).exists()
    ]
    assert not missing, f"build.py 要打包但 scripts/ 裡沒有：{sorted(missing)}"


def test_the_app_does_not_call_the_system_python():
    """kit 的依賴裝在自帶的 venv 裡，走系統 python 會 ModuleNotFoundError。

    這條是防回歸：`Process.run('python', ...)` 在開發機上多半也能跑
    （開發機什麼都裝了），所以它不會在這裡被發現。
    """
    text = HOST_ACTIONS.read_text(encoding="utf-8")
    assert "Process.run(\n        'python'" not in text
    assert ".venv" in text, "應該用 kit 自帶的 .venv 直譯器"
