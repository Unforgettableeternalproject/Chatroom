"""Session 身分解析（server.py 與 watch.py 共用）。

session_key 決定「你是誰」：Hub 的 join 冪等、assignment 指派、
state 檔命名全都掛在這把 key 上。解析邏輯只能有一份——
bridge 主體與 watcher 若各自實作，一旦歧異就會變成兩個身分。
"""

from __future__ import annotations

import hashlib
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
    """state 檔位置：顯式 ``CHATROOM_STATE_PATH`` 優先，否則跟著 session_key 走。"""
    override = os.environ.get("CHATROOM_STATE_PATH")
    if override:
        return Path(override)
    return Path.home() / ".chatroom" / state_filename(session_key)
