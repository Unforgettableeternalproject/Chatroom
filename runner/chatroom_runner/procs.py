"""起子進程時的共用旗標。

執行器由排程工作用 ``pythonw.exe`` 拉起 —— 那個進程**沒有 console**。
沒有 console 的父進程去起一個 console 程式（git、gpg、claude、taskkill），
Windows 會替它**各開一個新的黑窗**，於是畫面上就是一直閃的 cmd 視窗。
``CREATE_NO_WINDOW`` 是「不要給它 console」，跟 ``CREATE_NEW_CONSOLE``
相反；沒有它，pythonw 底下的每一次 git fetch 都看得見。

非 Windows 回空 dict：那個旗標在別的平台不存在，傳下去會直接炸。
"""

from __future__ import annotations

import subprocess
import sys


def no_window_kwargs() -> dict:
    """回傳要展開進 ``subprocess`` / ``asyncio`` 起進程呼叫的關鍵字。"""
    if sys.platform == "win32":
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}
