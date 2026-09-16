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


def main(argv: list[str]) -> int:
    scenario = os.environ.get("FAKE_CLAUDE_SCENARIO", "success")
    resuming = "--resume" in argv
    if "--version" in argv:
        print("2.1.273 (fake)")
        return 0
    emit({"type": "system", "subtype": "init", "session_id": SESSION_ID,
          "cwd": os.getcwd()})

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
