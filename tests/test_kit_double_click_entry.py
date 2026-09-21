"""三包的雙擊入口：`install.bat` 與它帶起來的互動提問。

交付對象是**不會開終端機的人**。所以這裡守的不是「程式跑得起來」，而是
「雙擊下去那個視窗裡看到的東西是對的」：

1. **`install.bat` 必須純 ASCII、不帶 BOM。** 這不是風格偏好，是 2026-09-20
   在這台 Windows 11 上實測的結果：把中文寫進 bat 並加上 UTF-8 BOM 之後，
   走到 `goto` 那一刻 cmd.exe 依**位元組位置**重新定位，落在一行的中間，
   把剩下半句當成命令執行——畫面上是一整片紅字，而且 `@echo off` 也失效了
   （BOM 黏在第一行前面），於是整支腳本開始回顯。
   中文改放 `install-help.txt`（cmd 不解析它，只是 `type` 出來）與
   `install.py`（Python 3 自己就是 UTF-8）。同 `scripts/*.cmd` 的規則，
   見 `tests/test_cmd_scripts_encoding.py`。

2. **`chcp 65001` 要在跑 install.py 之前。** 繁中主控台預設 cp950，不切的話
   安裝器印的每一句中文都是亂碼——而那是使用者唯一的說明。

3. **提問不合法要重問，不可以丟例外。** 雙擊進來的人看到 traceback 只會
   把視窗關掉，而他多半只是埠號打錯一個字。

4. **打包要帶上它們。** 開發機的 kit 目錄什麼都有，zip 裡少一支是在別人的
   機器上才會發現的事。
"""

from __future__ import annotations

import builtins
import importlib.util
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
KITS = ("host-kit", "install-kit", "runner-kit")


def load(path: Path, name: str):
    """載入一支 install.py。三包都只用標準庫、import 時不做事。"""
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# ---------- install.bat 本身 ----------


@pytest.mark.parametrize("kit", KITS)
def test_every_kit_has_a_double_click_entry(kit: str):
    assert (REPO / kit / "install.bat").is_file(), f"{kit} 少了 install.bat"
    assert (REPO / kit / "install-help.txt").is_file(), (
        f"{kit} 少了 install-help.txt——bat 找不到 Python 時會 type 它，"
        "檔案不在的話使用者只會看到 'The system cannot find the file'")


@pytest.mark.parametrize("kit", KITS)
def test_bat_is_pure_ascii_without_bom(kit: str):
    """非 ASCII 會讓 cmd 在 goto 之後落在一行的中間；BOM 會殺掉第一行。"""
    raw = (REPO / kit / "install.bat").read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf"), (
        f"{kit}/install.bat 帶 UTF-8 BOM。那三個位元組會黏在 @echo off 前面"
        "讓它失效，整支腳本開始回顯（2026-09-20 實測）。")
    try:
        raw.decode("ascii")
    except UnicodeDecodeError as exc:
        line_no = raw[:exc.start].count(b"\n") + 1
        line = raw.split(b"\n")[line_no - 1].decode("utf-8", errors="replace")
        pytest.fail(
            f"{kit}/install.bat 第 {line_no} 行有非 ASCII 位元組：\n"
            f"    {line.strip()}\n"
            "cmd.exe 依位元組位置重新定位，多位元組的行會讓它落在一行中間"
            "並把殘餘當命令執行。中文請寫在 install-help.txt 或 install.py。")


@pytest.mark.parametrize("kit", KITS)
def test_bat_switches_the_code_page_before_running_python(kit: str):
    """順序錯了照樣「成功」——只是每一句中文都是亂碼。"""
    text = (REPO / kit / "install.bat").read_text(encoding="ascii")
    assert "chcp 65001" in text
    # 比的是**執行那一行**的位置，不是檔案裡第一次出現 install.py 的地方
    # ——開頭的註解就提到它，用 index("install.py") 會量到註解上
    run_at = text.index('%PYCMD% "%~dp0install.py"')
    assert text.index("chcp 65001") < run_at, (
        "chcp 要在跑 install.py 之前，否則安裝器的中文輸出會是亂碼")


@pytest.mark.parametrize("kit", KITS)
def test_bat_looks_for_python_in_the_documented_order(kit: str):
    """py -3.12 → py -3 → python。順序寫反會挑到不合用的那個。"""
    text = (REPO / kit / "install.bat").read_text(encoding="ascii")
    probes = [ln.strip() for ln in text.splitlines()
              if ln.strip().startswith("call :probe")]
    assert probes == ["call :probe py -3.12", "call :probe py -3",
                      "call :probe python"], probes


@pytest.mark.parametrize("kit", KITS)
def test_bat_pauses_and_passes_the_exit_code_through(kit: str):
    """沒有 pause 的話，雙擊開的視窗會在失敗訊息印完的瞬間關掉。"""
    text = (REPO / kit / "install.bat").read_text(encoding="ascii")
    assert "\npause\n" in text, "成功與失敗兩條路都要停下來讓人讀"
    assert "exit /b %RC%" in text, "install.py 的退出碼要原樣傳出去"
    assert '%PYCMD% "%~dp0install.py" %*' in text, (
        "要用找到的那個 Python 跑同目錄的 install.py，而且參數原樣轉傳")


@pytest.mark.parametrize("kit", KITS)
def test_help_text_is_utf8_chinese_and_says_where_to_get_python(kit: str):
    raw = (REPO / kit / "install-help.txt").read_bytes()
    text = raw.decode("utf-8")       # 不是 UTF-8 就直接在這裡紅
    assert "Python 3.12" in text
    assert "python.org" in text
    assert "Add python.exe to PATH" in text, (
        "沒勾這一格是最常見的安裝失敗原因，訊息裡要指名它")


# ---------- 打包 ----------


def test_hub_kit_zip_ships_the_double_click_entry(tmp_path, monkeypatch):
    """host-kit 沒有既有的打包測試，這裡真的打一包來看 zip 裡有什麼。"""
    build = load(REPO / "host-kit" / "build.py", "hub_kit_build_entry")
    monkeypatch.setattr(build, "DIST", tmp_path)
    monkeypatch.setattr(sys, "argv", ["build.py"])
    build.main()
    with zipfile.ZipFile(tmp_path / "chatroom-hub-kit.zip") as zf:
        rel = {n.split("/", 1)[1] for n in zf.namelist() if "/" in n}
    assert "install.bat" in rel, f"包裡沒有 install.bat：{sorted(rel)[:10]}"
    assert "install-help.txt" in rel


# ---------- 互動提問 ----------


@pytest.fixture(params=KITS)
def installer(request):
    return load(REPO / request.param / "install.py",
                f"kit_prompt_{request.param.replace('-', '_')}")


def feed(monkeypatch, answers: list[str]) -> list[str]:
    """把 `input()` 換成照順序吐答案，並記下實際問出去的提示字。"""
    asked: list[str] = []
    queue = list(answers)

    def fake_input(prompt: str = "") -> str:
        asked.append(prompt)
        assert queue, f"問太多次了：{prompt!r}"
        return queue.pop(0)

    monkeypatch.setattr(builtins, "input", fake_input)
    return asked


def test_enter_takes_the_default_and_shows_it(installer, monkeypatch):
    """預設值要**看得到**：`問題 [預設值]: `，直接 Enter 就用它。"""
    asked = feed(monkeypatch, [""])
    assert installer.ask("Hub 位址", "http://127.0.0.1:8787") == \
        "http://127.0.0.1:8787"
    assert asked == ["Hub 位址 [http://127.0.0.1:8787]: "]


def test_a_bad_answer_is_asked_again_instead_of_raising(installer, monkeypatch):
    """不合法就重問。丟例外的話，雙擊進來的人看到的是 traceback。"""
    def check(value: str) -> str:
        return "" if value.isdigit() else "要填數字。"

    asked = feed(monkeypatch, ["八七八七", "8787"])
    assert installer.ask("埠號", "", check) == "8787"
    assert len(asked) == 2, "第一次答錯之後應該再問一次"


def test_empty_stdin_falls_back_to_the_default(installer, monkeypatch):
    """stdin 是空管道時吃 EOF——那不該變成 traceback。"""
    def eof(prompt: str = "") -> str:
        raise EOFError

    monkeypatch.setattr(builtins, "input", eof)
    assert installer.ask("埠號", "8787") == "8787"


def test_yes_no_reasks_on_gibberish(installer, monkeypatch):
    """看不懂的回答不可以默默當成「否」——那會靜靜跳過一整個步驟。"""
    asked = feed(monkeypatch, ["嗯", "n"])
    assert installer.ask_yes_no("要開隧道嗎？", True) is False
    assert len(asked) == 2
    assert "（Y/n）" in asked[0], asked[0]


def test_host_kit_rejects_an_impossible_port(monkeypatch):
    """埠號的檢查要真的擋得住——0 與 70000 都不是能綁的埠。"""
    inst = load(REPO / "host-kit" / "install.py", "host_kit_port_check")
    assert inst.check_port("0")
    assert inst.check_port("70000")
    assert inst.check_port("八七八七")
    assert inst.check_port("8787") == ""


def test_mcp_kit_url_may_be_empty_but_not_malformed():
    """留空是合法的（之後填進 .env）；少了 scheme 才是打錯。"""
    inst = load(REPO / "install-kit" / "install.py", "mcp_kit_url_check")
    assert inst.check_url("") == ""
    assert inst.check_url("http://192.0.2.10:8787") == ""
    assert inst.check_url("192.0.2.10:8787"), "少了 http:// 要擋下來"
