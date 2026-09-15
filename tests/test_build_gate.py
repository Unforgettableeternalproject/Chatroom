# -*- coding: utf-8 -*-
"""`scripts/build-app.py` 的「App 還開著就不要 build」那道閘。

這道閘的**正常狀態是什麼都不做**——App 沒開時它靜靜放行，改對改錯在畫面上
完全一樣。所以它需要測試：打錯進程名、判斷寫反、只查了新名漏掉舊名，三種
都「看起來正常」，直到某天真的有人開著 App 打包，而那時它已經不擋了
（測試Novia 09/14）。

⚠️ 四格都要驗，**包含「都沒開 ⇒ 放行」**：只驗擋的那三格的話，一個
「永遠回 True」的壞閘也會全綠，而它會擋住每一次正常的 build。
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "build-app.py"


def _load():
    """檔名帶連字號，import 不進來，只能走 spec。"""
    spec = importlib.util.spec_from_file_location("build_app_under_test", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    # buildstamp 與它同目錄
    sys.path.insert(0, str(_SCRIPT.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


@pytest.fixture()
def build_app():
    return _load()


def _run_main(module, running):
    """打樁偵測結果，跑 main()，回 (return code, stderr)。"""
    module.running_app_pids = lambda: running
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = module.main()
    return rc, err.getvalue()


@pytest.mark.parametrize(
    "running, expect_in_message",
    [
        ([("Chatroom", "1111")], "Chatroom"),
        # 改名過渡期：使用者手上跑的還是舊版
        ([("chatroom_app", "2222")], "chatroom_app"),
        ([("Chatroom", "1111"), ("chatroom_app", "2222")], "chatroom_app"),
    ],
)
def test_blocks_when_app_is_running(build_app, running, expect_in_message):
    rc, err = _run_main(build_app, running)
    assert rc == 1, "偵測到了卻沒擋——linker 會寫不進被佔用的 exe"
    assert "正在執行" in err
    assert expect_in_message in err
    assert str(running[0][1]) in err, "要講得出 PID，不然使用者不知道關哪一個"


def test_names_cover_old_and_new(build_app):
    """新舊名都要查——改名那一輪正是舊 exe 最可能還開著的時候。"""
    assert "Chatroom" in build_app.APP_PROCESS_NAMES
    assert "chatroom_app" in build_app.APP_PROCESS_NAMES


def test_old_name_gets_an_extra_hint(build_app):
    """舊名的視窗標題也是 Chatroom，不講的話他在工作管理員裡找不到。"""
    _, err = _run_main(build_app, [("chatroom_app", "2222")])
    assert "改名前的舊版" in err


def test_passes_the_gate_when_nothing_is_running(build_app):
    """🔴 第四格：都沒開的時候**要放行**。

    只驗擋的那三格，一個「永遠擋」的壞閘也會全綠——而它會讓每一次正常的
    build 都失敗。這裡讓閘之後的第一步立刻拋，用「有沒有走到那裡」證明
    它確實放行了，而不必真的跑一次 build。
    """
    module = build_app
    sentinel = RuntimeError("走過閘了")

    def _boom():
        raise sentinel

    module.app_version = _boom

    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        with pytest.raises(RuntimeError) as caught:
            _run_main(module, [])

    assert caught.value is sentinel
    assert "正在執行" not in err.getvalue(), "沒有東西開著卻擋下來了"
