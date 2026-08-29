"""Session 身分解析（server.py 與 watch.py 共用）。

session_key 決定「你是誰」：Hub 的 join 冪等、assignment 指派、
state 檔命名全都掛在這把 key 上。解析邏輯只能有一份——
bridge 主體與 watcher 若各自實作，一旦歧異就會變成兩個身分。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from pathlib import Path


def agent_kind() -> str:
    return os.environ.get("CHATROOM_AGENT_KIND", "other")


def session_key(kind: str | None = None) -> str:
    """解析本進程的 session 識別。

    優先序：
    1. 顯式 ``CHATROOM_SESSION_KEY``——固定人格身分（特殊部署／測試用）。
       注意這是進程層級的設定：寫進專案 `.mcp.json` 會讓同專案所有 session
       共用同一把 key，因 join 冪等而合併成同一個 participant，訊息混流。
    2. agent 平台的 session id——Claude Code 會把 ``CLAUDE_CODE_SESSION_ID``
       傳進 MCP 進程環境（2026-08-28 實測）。以它當識別符，resume 同一個
       session 時身分與游標延續，新 session 天然是新 participant。
       僅在 kind=claude 時採用：從 Claude session 的 shell 拉起的 Codex
       會「繼承」到母 session 的這個變數，直接採用會與母 session 撞 key。
    3. 每進程各自生成——多開 session 必須是不同的 participant；若沿用
       機器層級共用 keyfile，多個 session 會因 join 冪等合併成同一身分。
    """
    if kind is None:
        kind = agent_kind()
    env = os.environ.get("CHATROOM_SESSION_KEY")
    if env:
        return env
    if kind == "claude":
        platform_sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
        if platform_sid:
            return f"claude-{platform_sid}"
    return f"{kind}-{uuid.uuid4().hex[:12]}"


def state_filename(session_key: str) -> str:
    """session_key → 安全的 state 檔名。

    直接拿 key 前綴當檔名有兩個洞：前綴相同的兩把固定 key 會共用同一個檔案、
    互相覆蓋身分與游標；key 含路徑分隔符或 Windows 非法字元時路徑直接壞掉。
    改成「可讀 slug + 全長雜湊」——slug 只為了人眼辨識，唯一性靠雜湊保證。
    """
    digest = hashlib.sha256(session_key.encode("utf-8")).hexdigest()[:16]
    slug = re.sub(r"[^A-Za-z0-9_-]+", "", session_key)[:24]
    if slug:
        return f"state-{slug}-{digest}.json"
    return f"state-{digest}.json"


def state_path(session_key: str) -> Path:
    """state 檔位置：顯式 ``CHATROOM_STATE_PATH`` 優先，否則跟著 session_key 走。

    這是「依 key 算出來的名字」，**不保證身分真的存在那裡**——身分可以在
    建檔之後被 Hub 改寫（見 resolve_state_path）。要讀既有身分請用那一支。
    """
    override = os.environ.get("CHATROOM_STATE_PATH")
    if override:
        return Path(override)
    return Path.home() / ".chatroom" / state_filename(session_key)


def resolve_state_path(session_key: str) -> Path:
    """找出**真的存放這把 key 的身分**的 state 檔。

    檔名由建檔當下的 key 決定，但那把 key 會變：用 ``assignment_id`` 加入
    房間時 Hub 會回一把 canonical session_key，bridge 把它寫進檔案內容；
    之後行程重啟拿到新的平台 session id，算出來的檔名就與實際存放位置對不
    上，身分看起來憑空消失（2026-08-29 實測，MCP 重連後房內身分全失）。

    **檔名不是權威，內容裡的 ``session_key`` 才是。** 依 key 算出的名字仍是
    第一順位；找不到時掃同目錄，取內容自報 key 等於自己的那一份。

    找到之後就地使用、不改名：改名要跟同時在讀這個檔的 watcher 搶，而搶輸
    的代價（身分再次消失）比檔名不好看嚴重得多。
    """
    preferred = state_path(session_key)
    if preferred.exists() or os.environ.get("CHATROOM_STATE_PATH"):
        return preferred
    try:
        candidates = sorted(preferred.parent.glob("state-*.json"))
    except OSError:
        return preferred
    for path in candidates:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(raw, dict) and raw.get("session_key") == session_key:
            return path
    return preferred
