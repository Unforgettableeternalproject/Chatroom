"""`PreToolUse` hook：硬限制的執行點（REMOTE-OPS-PLAN §6.4）。

由 run 專用的 ``settings.json`` 以 ``python <這個檔案>`` 呼叫，matcher 是
``Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit``。

- exit 0：放行，順手把這次呼叫寫進 run 的 ``tool.log``。
- exit 2：擋下來，stderr 的內容會**原樣回給模型**
  （形狀是 ``PreToolUse:<Tool> hook error: [<hook>]: <stderr>``）。

兩種擋法：``handoff.flag`` 存在（context 到頂，要交接）與規則不允許。
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

from chatroom_runner.guard import GuardContext, check_tool  # noqa: E402

HANDOFF_MESSAGE = (
    "context 已達上限，這是系統限制：請立刻把已做／未做／下一步寫到卡、"
    "釋放認領，然後結束，不要再做任何其他事。"
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


def main(argv: list[str] | None = None) -> int:
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
        return 0
    _append_tool_log(run_dir, tool_name, tool_input, decision.rule)
    sys.stderr.write(decision.reason)
    return 2


if __name__ == "__main__":  # pragma: no cover - 由 Claude Code 呼叫
    sys.exit(main())
