"""關閉隧道的回歸測試。

這支腳本的全部難處是**不要殺錯**。原本的設計刻意不做這顆按鈕，理由寫在
`host_console_screen.dart`：「做一顆按鈕去殺別人的進程，會在殺錯的時候完全
看不出來。」

所以這裡守的重點不是「關得掉」，是**「在該收手的時候真的收手」**——
尤其 PID 被系統重用那一條：那時 `.tunnel-pid` 記的號碼仍然對應一個活著的
進程，只是它已經是別人了。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
STOP_PY = REPO / "scripts" / "stop-tunnel.py"


def load_stop(tmp_path: Path):
    """載入腳本並把它的路徑常數指到 tmp。

    腳本用模組層級常數算路徑（`ROOT / "server" / ...`），所以要在載入後改寫
    ——不改的話這些測試會去讀**真的** server/ 目錄，而那裡可能真的有一條
    隧道在跑。
    """
    spec = importlib.util.spec_from_file_location("chatroom_stop_tunnel", STOP_PY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["chatroom_stop_tunnel"] = module
    spec.loader.exec_module(module)
    server = tmp_path / "server"
    server.mkdir(exist_ok=True)
    module.ROOT = tmp_path
    module.URL_FILE = server / ".tunnel-url"
    module.PID_FILE = server / ".tunnel-pid"
    return module


def write_state(mod, pid: int, target: str = "http://127.0.0.1:8787"):
    mod.PID_FILE.write_text(
        json.dumps({"cloudflared": pid, "launcher": 1, "target": target}),
        encoding="utf-8",
    )


def test_refuses_when_pid_was_reused(tmp_path: Path, monkeypatch):
    """🔴 最重要的一條：PID 還在，但跑的已經是別人 → 絕不動手。

    這條紅起來的樣子：使用者按「關閉隧道」，某個剛好接到同一個號碼的
    無關進程被殺掉，而畫面顯示成功。
    """
    mod = load_stop(tmp_path)
    write_state(mod, 4242)
    killed: list[int] = []
    monkeypatch.setattr(
        mod, "command_line",
        lambda pid: r"C:\Windows\system32\notepad.exe some-unrelated-file.txt")
    monkeypatch.setattr(mod, "terminate", lambda pid: killed.append(pid) or True)

    result = mod.stop()

    assert killed == [], "命令列對不上還是動手了"
    assert result["ok"] is False
    assert result["reason"] == "pid_reused"
    assert "notepad" in result["detail"], "要把看到的東西講出來，不能靜靜放棄"
    # 記錄不可以被清掉——它是下次判斷的依據，而這次什麼都沒做
    assert mod.PID_FILE.exists()


def test_refuses_when_target_does_not_match(tmp_path: Path, monkeypatch):
    """是 cloudflared，但轉發的是別的東西——那是別人的隧道。"""
    mod = load_stop(tmp_path)
    write_state(mod, 4242, target="http://127.0.0.1:8787")
    killed: list[int] = []
    monkeypatch.setattr(
        mod, "command_line",
        lambda pid: "cloudflared.exe tunnel --url http://127.0.0.1:9999")
    monkeypatch.setattr(mod, "terminate", lambda pid: killed.append(pid) or True)

    result = mod.stop()

    assert killed == []
    assert result["reason"] == "pid_reused"


def test_stops_when_everything_matches(tmp_path: Path, monkeypatch):
    mod = load_stop(tmp_path)
    write_state(mod, 4242)
    mod.URL_FILE.write_text("https://x.trycloudflare.com\n", encoding="utf-8")
    killed: list[int] = []
    monkeypatch.setattr(
        mod, "command_line",
        lambda pid: "cloudflared.exe tunnel --url http://127.0.0.1:8787 --no-autoupdate")
    monkeypatch.setattr(mod, "terminate", lambda pid: killed.append(pid) or True)

    result = mod.stop()

    assert killed == [4242]
    assert result["ok"] is True and result["stopped"] is True
    # 關掉之後那個網址就失效了，留著會被人發出去
    assert not mod.URL_FILE.exists()
    assert not mod.PID_FILE.exists()


def test_no_record_is_a_normal_result_not_a_failure(tmp_path: Path):
    """「沒有隧道可關」不是錯誤。

    當成錯誤的話，UI 會對一個什麼都沒做錯的使用者顯示紅字。
    """
    mod = load_stop(tmp_path)
    result = mod.stop()
    assert result["ok"] is True
    assert result["stopped"] is False
    assert result["reason"] == "no_record"


def test_stale_url_is_cleared_when_there_is_no_record(tmp_path: Path):
    """隧道被強制關掉時 `finally` 不會執行，`.tunnel-url` 會殘留。

    那個網址早就失效，留著只會讓人把它發給成員——這支既然來了就順手清掉。
    """
    mod = load_stop(tmp_path)
    mod.URL_FILE.write_text("https://dead.trycloudflare.com\n", encoding="utf-8")

    result = mod.stop()

    assert result["cleared_stale_url"] is True
    assert not mod.URL_FILE.exists()


def test_already_gone_cleans_up(tmp_path: Path, monkeypatch):
    """進程不在了（自己結束、當機、斷電）——清掉紀錄，不報錯。"""
    mod = load_stop(tmp_path)
    write_state(mod, 4242)
    mod.URL_FILE.write_text("https://x.trycloudflare.com\n", encoding="utf-8")
    monkeypatch.setattr(mod, "command_line", lambda pid: None)

    result = mod.stop()

    assert result["ok"] is True
    assert result["reason"] == "already_gone"
    assert not mod.URL_FILE.exists()
    assert not mod.PID_FILE.exists()


def test_corrupt_record_does_not_become_a_kill(tmp_path: Path, monkeypatch):
    """壞掉的 PID 檔要當成「沒有可靠對象」，不是拿裡面的殘值去殺。"""
    mod = load_stop(tmp_path)
    mod.PID_FILE.write_text("{ 這不是 JSON", encoding="utf-8")
    killed: list[int] = []
    monkeypatch.setattr(mod, "terminate", lambda pid: killed.append(pid) or True)

    result = mod.stop()

    assert killed == []
    assert result["reason"] == "no_record"


def test_looks_like_our_tunnel_needs_both_conditions(tmp_path: Path):
    """光是「是 cloudflared」不夠——這台機器上可能有別人的隧道。"""
    mod = load_stop(tmp_path)
    target = "http://127.0.0.1:8787"
    assert mod.looks_like_our_tunnel(
        f"cloudflared tunnel --url {target}", target)
    assert not mod.looks_like_our_tunnel(
        "cloudflared tunnel --url http://127.0.0.1:1234", target)
    assert not mod.looks_like_our_tunnel(f"python serve.py {target}", target)
    # 空 target 不可以變成「什麼都符合」
    assert not mod.looks_like_our_tunnel("cloudflared tunnel --url x", "")


@pytest.fixture(autouse=True)
def _no_real_processes(monkeypatch):
    """保險絲：任何一條測試漏了 monkeypatch 也不會真的殺到進程。"""
    import subprocess

    def explode(*args, **kwargs):  # noqa: ANN002, ANN003
        raise AssertionError("測試不該真的去動系統進程")

    monkeypatch.setattr(subprocess, "run", explode)
