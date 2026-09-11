"""關掉這個 kit 開的隧道。

    python scripts/stop-tunnel.py
    python scripts/stop-tunnel.py --json     # 給 App 解析用

🔴 **這支存在的全部難處是「不要殺錯」。**

`run-tunnel.cmd` 開的隧道活在自己的視窗裡，關掉視窗就等於關隧道——所以
最早的設計刻意不做這顆按鈕，理由寫在 `host_console_screen.dart`：

> 做一顆按鈕去殺別人的進程，會在殺錯的時候完全看不出來。

那個顧慮是對的，而它的解法不是「不做」，是**讓按鈕認得出自己殺的是誰**：
`tunnel.py` 起 cloudflared 之後把 PID 寫進 `server/.tunnel-pid`，這裡殺之前
**逐條驗證**那個 PID 現在真的是我們那條隧道。任何一條對不上就拒絕動手，
並講清楚看到了什麼——⚠️ **「找不到可以關的隧道」是一個正常結果，不是失敗**，
它就是「沒有隧道在跑」或「那條隧道不是這個 kit 開的」。

⚠️ **PID 會被重用。** 進程結束後系統會把號碼配給別人，所以光是「這個 PID
存在」完全不構成證據——必須連命令列一起比對。這是這支腳本唯一真正危險的
地方：驗證鬆一格，殺掉的就是某個剛好接到同一個號碼的無關進程。
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
URL_FILE = ROOT / "server" / ".tunnel-url"
PID_FILE = ROOT / "server" / ".tunnel-pid"


def read_state() -> dict[str, object] | None:
    """讀 `.tunnel-pid`。讀不到或壞掉都回 None——兩者對呼叫端意義相同
    （沒有可靠的關閉對象），而把壞檔當成「有隧道」會讓下一步去殺一個
    來歷不明的 PID。"""
    if not PID_FILE.exists():
        return None
    try:
        data = json.loads(PID_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def command_line(pid: int) -> str | None:
    """那個 PID 現在跑的是什麼。進程不存在時回 None。

    這是本腳本的安全核心：**只有命令列對得上才動手**。
    """
    if platform.system() == "Windows":
        try:
            result = subprocess.run(
                [
                    "powershell", "-NoProfile", "-Command",
                    f"(Get-CimInstance Win32_Process -Filter \"ProcessId={pid}\")"
                    ".CommandLine",
                ],
                capture_output=True, text=True, timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        line = result.stdout.strip()
        return line or None

    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "args="],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    line = result.stdout.strip()
    return line or None


def looks_like_our_tunnel(cmdline: str, target: str) -> bool:
    """這條命令列是不是我們開的那條隧道。

    兩個條件都要：是 cloudflared，而且轉發的是我們那個 target。
    只看前者的話，這台機器上任何別人的隧道都會被誤判成我們的。
    """
    lowered = cmdline.lower()
    if "cloudflared" not in lowered:
        return False
    # target 形如 http://127.0.0.1:8787；比對時不分大小寫，
    # 也容忍 cloudflared 把它印成不同的引號形式
    return bool(target) and target.lower() in lowered


def terminate(pid: int) -> bool:
    """先請它自己走，不走才強制。回傳是否真的結束了。"""
    try:
        if platform.system() == "Windows":
            # cloudflared 沒有主控台可以收 Ctrl+C（它是被 App detach 起來的），
            # taskkill 是這裡唯一可靠的途徑
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True, timeout=30,
            )
        else:
            os.kill(pid, signal.SIGTERM)
    except (OSError, subprocess.TimeoutExpired):
        return False

    # 給它一點時間退場再確認。不確認的話「關掉了」只是「送出了訊號」
    for _ in range(10):
        time.sleep(0.3)
        if command_line(pid) is None:
            return True
    return False


def stop() -> dict[str, object]:
    state = read_state()
    if state is None:
        # 沒有 PID 檔，但可能留著殘骸網址（tunnel.py 被強制關掉時 finally
        # 不會執行）。清掉它——那個網址早就失效，留著只會被人發出去
        had_stale_url = URL_FILE.exists()
        URL_FILE.unlink(missing_ok=True)
        return {
            "ok": True,
            "stopped": False,
            "reason": "no_record",
            "cleared_stale_url": had_stale_url,
            "detail": "沒有這個 kit 開著的隧道。"
            + ("（清掉了一個殘留的網址檔）" if had_stale_url else ""),
        }

    pid = state.get("cloudflared")
    target = str(state.get("target", ""))
    if not isinstance(pid, int):
        return {"ok": False, "stopped": False, "reason": "bad_record",
                "detail": f"{PID_FILE.name} 裡沒有可用的 PID，不動手。"}

    cmdline = command_line(pid)
    if cmdline is None:
        # 進程已經不在了——隧道自己結束但檔案沒清掉（強制關視窗、當機、斷電）
        URL_FILE.unlink(missing_ok=True)
        PID_FILE.unlink(missing_ok=True)
        return {
            "ok": True, "stopped": False, "reason": "already_gone",
            "detail": f"PID {pid} 已經不在了，隧道早就關了。已清掉殘留紀錄。",
        }

    if not looks_like_our_tunnel(cmdline, target):
        # 🔴 **這是這支腳本最重要的一條分支**：PID 被重用了，現在跑在那個
        # 號碼上的是別人。絕不動手，並且把看到的東西講出來——沉默地放棄
        # 與沉默地殺錯，在畫面上長得一樣
        return {
            "ok": False, "stopped": False, "reason": "pid_reused",
            "pid": pid,
            "detail": f"PID {pid} 現在跑的不是我們的隧道，不動手。"
                      f"（它是：{cmdline[:120]}）",
        }

    ok = terminate(pid)
    if ok:
        URL_FILE.unlink(missing_ok=True)
        PID_FILE.unlink(missing_ok=True)
        return {"ok": True, "stopped": True, "pid": pid,
                "detail": "隧道已關閉。那個網址已經失效，重開會是新的網址。"}

    return {"ok": False, "stopped": False, "reason": "still_running",
            "pid": pid,
            "detail": f"送出了關閉指令，但 PID {pid} 還在。"
                      "可能需要較高權限，或那個進程卡住了。"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="關掉這個 kit 開的隧道")
    parser.add_argument("--json", action="store_true", help="輸出 JSON（給 App 解析）")
    args = parser.parse_args(argv)

    try:
        result = stop()
    except Exception as exc:  # noqa: BLE001 — CLI 邊界，錯誤要講人話
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"關閉隧道失敗：{exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(result["detail"])
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
