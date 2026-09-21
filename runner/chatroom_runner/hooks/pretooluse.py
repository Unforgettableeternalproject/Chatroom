"""`PreToolUse` hook：硬限制的執行點（REMOTE-OPS-PLAN §6.4）。

由 run 專用的 ``settings.json`` 以 ``python <這個檔案>`` 呼叫，matcher 是
``Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit``。

- exit 0：放行，順手把這次呼叫寫進 run 的 ``tool.log``。
- exit 2：擋下來，stderr 的內容會**原樣回給模型**
  （形狀是 ``PreToolUse:<Tool> hook error: [<hook>]: <stderr>``）。

三種擋法：``handoff.flag`` 存在（context 到頂，要交接）、``soft_stop.flag``
存在（房裡請它收尾）與規則不允許。

放行時還有一條**不中斷**的路：``inject.jsonl`` 裡沒消費過的行（房裡 @ 這筆
run 的訊息）會用 JSON 輸出的
``hookSpecificOutput.additionalContext`` 附給模型——官方文件把它定義成
「Extra context to show Claude about the tool call」，是 PreToolUse 底下唯一
不必 deny 就能讓文字進到模型 context 的欄位（``permissionDecisionReason``
只在 deny 時才回給模型）。**不帶 `permissionDecision`**：放行與否仍由既有的
權限流程決定，這個 hook 只是搭一段話上去。
理由一律講「這是系統限制」並指出替代路徑——實測模型被擋之後會換個工具再試
一次然後放棄，不講清楚它只會在那裡繞。

這個殼**不做判斷**：規則全在 ``chatroom_runner.guard``，因為那裡才測得到。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# 以腳本身分被呼叫時 package 不在路徑上。往上兩層就是 `runner/`
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from chatroom_runner.config import (INJECT_CURSOR_NAME,  # noqa: E402
                                    INJECT_FILE_NAME, SOFT_STOP_FLAG_NAME)
from chatroom_runner.guard import GuardContext, check_tool  # noqa: E402

HANDOFF_MESSAGE = (
    "context 已達上限，這是系統限制：請立刻把已做／未做／下一步寫到卡、"
    "釋放認領，然後結束，不要再做任何其他事。"
)
SOFT_STOP_MESSAGE = (
    "房裡請你收尾：請在目前步驟收尾，寫收工摘要後結束，不要再開新工作。"
)


def _run_dir() -> Path:
    return Path(os.environ.get("CHATROOM_RUNNER_RUN_DIR", "."))


def _append_tool_log(run_dir: Path, tool_name: str, payload: dict,
                     verdict: str) -> None:
    """放行也要留痕（§6.4「允許但記錄」）。log 寫不成功不能影響放行。"""
    try:
        line = json.dumps({"tool": tool_name, "verdict": verdict,
                           "input": payload}, ensure_ascii=False)
        with (run_dir / "tool.log").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def pending_injections(run_dir: Path) -> tuple[list[dict], int]:
    """``inject.jsonl`` 裡還沒送進模型的行，與這次要寫回的游標。

    游標是**行數**（``inject.cursor``），不是刪檔：那份 jsonl 是事後唯一
    說得出「房裡跟它講過什麼」的東西，消費掉就把它丟了的話，一筆做錯事的
    run 事後查不出它到底收到過哪一句。
    """
    path = run_dir / INJECT_FILE_NAME
    if not path.is_file():
        return [], 0
    try:
        lines = [ln for ln in path.read_text(encoding="utf-8").splitlines()
                 if ln.strip()]
    except OSError:
        return [], 0
    try:
        done = int((run_dir / INJECT_CURSOR_NAME)
                   .read_text(encoding="utf-8").strip() or 0)
    except (OSError, ValueError):
        done = 0
    done = max(0, min(done, len(lines)))
    items: list[dict] = []
    for raw in lines[done:]:
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            items.append(item)
    return items, len(lines)


def injection_text(items: list[dict]) -> str:
    """把轉達的訊息排成一段給模型看的文字。"""
    head = (f"房裡有 {len(items)} 則訊息指名給你（在這次工具呼叫之前送到）。"
            "看完照它說的調整，需要回話就用 `chatroom_post`：")
    body = [f"- #{it.get('seq', '?')} {it.get('from', '？')}："
            f"{it.get('text', '')}" for it in items]
    return "\n".join([head, *body])


def main(argv: list[str] | None = None) -> int:
    # Claude Code 把 hook 的 stdout／stderr 當 UTF-8 讀，而 Windows 上 Python 的
    # 預設是 CP950：不設這兩行，additionalContext 與交接／收尾的提示到模型手上
    # 全是亂碼（2026-09-18 模擬輪次實測，模型回報「Big5 被當 UTF-8 讀」）
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, OSError, ValueError):
            pass
    run_dir = _run_dir()
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        raw = ""
    try:
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        event = {}
    tool_name = str(event.get("tool_name") or "")
    tool_input = event.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    if (run_dir / "handoff.flag").exists():
        _append_tool_log(run_dir, tool_name, tool_input, "handoff")
        sys.stderr.write(HANDOFF_MESSAGE)
        return 2

    if (run_dir / SOFT_STOP_FLAG_NAME).exists():
        # 收尾請求**排在守衛之前**：這一刻要停的是「再開新工作」，而不是
        # 只擋那些本來就違規的呼叫
        _append_tool_log(run_dir, tool_name, tool_input, "soft_stop")
        sys.stderr.write(SOFT_STOP_MESSAGE)
        return 2

    guard_file = run_dir / "guard.json"
    if not guard_file.is_file():
        # 守衛設定不見了就**擋下來**。找不到規則時放行等於整個 §6.4 靜默失效，
        # 而那件事在 log 上與「這次沒有違規」長得一模一樣
        sys.stderr.write(
            "這是系統限制：執行器的守衛設定讀不到，這一輪不放行任何工具呼叫。"
            "請把目前進度寫進卡裡並結束，由人類檢查執行器狀態。")
        return 2
    ctx = GuardContext.from_dict(
        json.loads(guard_file.read_text(encoding="utf-8")))

    decision = check_tool(tool_name, tool_input, ctx)
    if decision.allowed:
        _append_tool_log(run_dir, tool_name, tool_input, "allow")
        # 被擋下來的那條路**不消費**轉達訊息：那次呼叫的回饋是 deny 的理由，
        # 附上去的話模型看到的是一段跟拒絕理由混在一起的話，而它已經被消費了
        items, cursor = pending_injections(run_dir)
        if items:
            try:
                (run_dir / INJECT_CURSOR_NAME).write_text(
                    str(cursor), encoding="utf-8")
            except OSError:
                # 游標寫不進去就**不送**：送了而沒記下來的話，下一次呼叫會
                # 把同一段話再講一次，而模型分不出那是新的還是舊的
                return 0
            sys.stdout.write(json.dumps(
                {"hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": injection_text(items)}},
                ensure_ascii=False))
        return 0
    _append_tool_log(run_dir, tool_name, tool_input, decision.rule)
    sys.stderr.write(decision.reason)
    return 2


if __name__ == "__main__":  # pragma: no cover - 由 Claude Code 呼叫
    sys.exit(main())
