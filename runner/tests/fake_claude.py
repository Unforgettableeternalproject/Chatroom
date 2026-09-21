"""假的 `claude`，吐 stream-json（REMOTE-OPS-PLAN §8 P2 驗收）。

測試**一律**用這個，不起真的 claude：真的那個要登入、要花錢、而且它的行為
不是這一層要驗的東西。要驗的是「執行器看到這串事件時判成什麼」。

情境由環境變數 `FAKE_CLAUDE_SCENARIO` 決定：

| 值 | 吐什麼 | exit |
|---|---|---|
| `success`（預設） | 一則 assistant + result success | 0 |
| `max_turns` | result error_max_turns、is_error | 1 |
| `rate_limit` | 三次 api_retry(rate_limit) + error_during_execution | 1 |
| `rate_limit_then_ok` | 同上，但帶 `--resume` 時直接成功 | 1／0 |
| `weekly` | assistant 講 weekly limit + error_during_execution | 1 |
| `context` | 連續 assistant，usage 一路衝過閾值 | 0 |
| `long` | 印一則就長睡，等著被殺 | 0 |
| `env_dump` | 把 `GIT_*` 環境變數寫進 run 目錄的 `env.json` | 0 |
| `not_logged_in` | result subtype=success 但 is_error、exit 1（實測形狀） | 1 |
| `big_line` | 一行 300 KB 的 tool_result（模擬 Read 一張圖） | 0 |
| `mcp_pending` | init 裡 chatroom 是 pending，然後長睡等著被殺 | 0 |
| `mcp_pending_noisy` | init 裡 chatroom 是 pending，接著**持續吐事件**直到被殺——驗「殺了就不再長」，不是「殺了它剛好也在睡」 | 0 |
| `mcp_pending_then_ok` | 前 N-1 次 pending，第 N 次 connected 並成功 | 0 |
| `mcp_connected` | init 裡 chatroom 是 connected，正常成功 | 0 |

`mcp_pending_then_ok` 第幾次才連上由 `FAKE_CLAUDE_MCP_OK_AT` 決定
（預設 3），次數記在 run 目錄的 `mcp_attempts`——跨進程的計數只能落檔。
"""

from __future__ import annotations

import json
import os
import sys
import time

SESSION_ID = "fake-session-0001"

# 真的 claude 一律吐 UTF-8；這裡不強制的話，Windows 的 cp950 會把中文變成
# 亂碼，而那會讓「執行器有沒有把摘要帶回去」這件事測不到
sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def usage(tokens: int) -> dict:
    return {"input_tokens": tokens, "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 0, "output_tokens": 64}


def assistant(text: str, tokens: int = 1000) -> None:
    emit({"type": "assistant", "session_id": SESSION_ID,
          "message": {"role": "assistant", "usage": usage(tokens),
                      "content": [{"type": "text", "text": text}]}})


def result(subtype: str, is_error: bool, text: str, turns: int = 3,
           cost: float = 0.12) -> None:
    emit({"type": "result", "subtype": subtype, "is_error": is_error,
          "session_id": SESSION_ID, "num_turns": turns,
          "total_cost_usd": cost, "result": text,
          "usage": {"input_tokens": 4000, "output_tokens": 800,
                    "cache_read_input_tokens": 1000,
                    "cache_creation_input_tokens": 0}})


def init(mcp_servers: list[dict] | None = None) -> None:
    event = {"type": "system", "subtype": "init", "session_id": SESSION_ID,
             "cwd": os.getcwd()}
    if mcp_servers is not None:
        event["mcp_servers"] = mcp_servers
    emit(event)


def sleep_until_killed() -> None:
    """吐完 init 就等著被殺。真的 claude 在這裡會開始做事。"""
    deadline = time.time() + float(os.environ.get("FAKE_CLAUDE_SLEEP", "30"))
    while time.time() < deadline:
        time.sleep(0.1)


def keep_talking_until_killed() -> None:
    """吐完 pending 的 init 就不停講話，直到真的被殺。

    `sleep_until_killed` 驗的是「殺的時候它剛好在睡」；這個驗的是「殺的時候
    它正在動」——真的 claude 在 pending 之後不會乖乖睡著，它會繼續做事。
    只有持續吐東西才測得出「殺了之後 stream 真的不再長」，不是巧合地不長。
    """
    deadline = time.time() + float(os.environ.get("FAKE_CLAUDE_SLEEP", "30"))
    n = 0
    while time.time() < deadline:
        n += 1
        assistant(f"盲做第 {n} 步。", tokens=100)
        time.sleep(0.05)


def bump_attempt() -> int:
    """這是第幾次被起（跨進程，所以記在 run 目錄的檔案裡）。"""
    run_dir = os.environ.get("CHATROOM_RUNNER_RUN_DIR", ".")
    path = os.path.join(run_dir, "mcp_attempts")
    try:
        with open(path, encoding="utf-8") as fh:
            n = int(fh.read().strip() or 0)
    except (OSError, ValueError):
        n = 0
    n += 1
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(str(n))
    return n


def main(argv: list[str]) -> int:
    scenario = os.environ.get("FAKE_CLAUDE_SCENARIO", "success")
    resuming = "--resume" in argv
    if "--version" in argv:
        print("2.1.273 (fake)")
        return 0
    if scenario == "mcp_pending_noisy":
        init([{"name": "chatroom", "status": "pending"}])
        keep_talking_until_killed()
        result("success", False, "盲做了一輪。", turns=99)
        return 0
    if scenario in ("mcp_pending", "mcp_pending_then_ok", "mcp_connected"):
        ok_at = int(os.environ.get("FAKE_CLAUDE_MCP_OK_AT", "3"))
        attempt = bump_attempt()
        connected = (scenario == "mcp_connected"
                     or (scenario == "mcp_pending_then_ok"
                         and attempt >= ok_at))
        status = "connected" if connected else "pending"
        init([{"name": "chatroom", "status": status},
              {"name": "claude.ai Atlassian Rovo", "status": "connected"}])
        if not connected:
            sleep_until_killed()
            result("success", False, "盲做了一輪。", turns=3)
            return 0
        assistant("進房了，開始做。")
        result("success", False, "已完成：進房讀卡後動工。", turns=4)
        return 0
    init()

    if scenario == "success":
        assistant("我看過卡了，開始做。")
        result("success", False, "已完成：改了兩個檔，跑過既有測試。", turns=5)
        return 0
    if scenario == "max_turns":
        assistant("做到一半。")
        result("error_max_turns", True, "", turns=120)
        return 1
    if scenario in ("rate_limit", "rate_limit_then_ok"):
        if resuming and scenario == "rate_limit_then_ok":
            assistant("續跑成功。")
            result("success", False, "退避後把剩下的做完了。", turns=8)
            return 0
        for _ in range(3):
            emit({"type": "system", "subtype": "api_retry",
                  "error": "rate_limit", "retry_delay_ms": 1000})
        result("error_during_execution", True, "", turns=2)
        return 1
    if scenario == "weekly":
        assistant("You've hit your weekly limit. It will reset later.")
        result("error_during_execution", True,
               "You've hit your weekly limit", turns=1)
        return 1
    if scenario == "context":
        for tokens in (60_000, 120_000, 180_000):
            assistant(f"進度更新（{tokens}）", tokens=tokens)
        result("success", False, "已按要求把交接寫進卡裡。", turns=9)
        return 0
    if scenario == "long":
        assistant("開始長跑。")
        deadline = time.time() + float(os.environ.get("FAKE_CLAUDE_SLEEP",
                                                      "120"))
        while time.time() < deadline:
            time.sleep(0.2)
        result("success", False, "長跑跑完了。")
        return 0
    if scenario == "env_dump":
        # 憑證隔離要驗的是「環境變數真的到得了子進程」，所以由子進程自己寫
        run_dir = os.environ.get("CHATROOM_RUNNER_RUN_DIR", ".")
        seen = {k: v for k, v in os.environ.items() if k.startswith("GIT_")}
        with open(os.path.join(run_dir, "env.json"), "w",
                  encoding="utf-8") as fh:
            json.dump(seen, fh, ensure_ascii=False)
        assistant("環境已落檔。")
        result("success", False, "環境已落檔。", turns=1)
        return 0
    if scenario == "big_line":
        # 2026-09-17 事故的形狀：模型 Read 一張 141 KB 的 PNG，那一行
        # tool_result 帶著 base64 遠超 asyncio StreamReader 預設的 64 KiB 行
        # 上限，`readline()` 直接丟 ValueError。這裡吐得比那更大一點
        blob = "A" * 300_000
        emit({"type": "user", "session_id": SESSION_ID,
              "message": {"role": "user", "content": [
                  {"type": "tool_result", "tool_use_id": "t1",
                   "content": [{"type": "image", "source": {
                       "type": "base64", "media_type": "image/png",
                       "data": blob}}]}]}})
        assistant("圖我看過了。")
        result("success", False, "已完成：附件讀得進來。", turns=2)
        return 0
    if scenario == "not_logged_in":
        # 實測 2.1.273：加 --bare 未登入時 subtype 照樣是 success。
        # 只看 subtype 的執行器會把這一輪標成完成
        emit({"type": "assistant", "session_id": SESSION_ID,
              "message": {"role": "assistant", "usage": usage(10),
                          "content": [{"type": "text",
                                       "text": "Not logged in"}]},
              "is_error": True})
        result("success", True, "Not logged in", turns=0, cost=0.0)
        return 1
    print(f"unknown scenario: {scenario}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
