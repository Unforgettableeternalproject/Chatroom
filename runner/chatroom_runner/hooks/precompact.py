"""`PreCompact` hook：留一個「這個 run 被壓縮過」的標記。

**擋不住壓縮**（官方文件字面：PreCompact 不能取消）。它唯一的用途是事後判定
——一個被壓過的 run，收工摘要裡對「前面做了什麼」的敘述是二手的，人類讀的
時候需要知道這件事。真正要在壓縮前逼交接的機制是 ``handoff.flag``（§5.3）。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    run_dir = Path(os.environ.get("CHATROOM_RUNNER_RUN_DIR", "."))
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        raw = ""
    try:
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        event = {}
    try:
        with (run_dir / "compacted").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"trigger": event.get("trigger", "")},
                                ensure_ascii=False) + "\n")
    except OSError:
        pass
    return 0


if __name__ == "__main__":  # pragma: no cover - 由 Claude Code 呼叫
    sys.exit(main())
