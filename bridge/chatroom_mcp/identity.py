"""Session 身分解析（server.py 與 watch.py 共用）。

session_key 決定「你是誰」：Hub 的 join 冪等、assignment 指派、
state 檔命名全都掛在這把 key 上。解析邏輯只能有一份——
bridge 主體與 watcher 若各自實作，一旦歧異就會變成兩個身分。
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import re
import uuid
from pathlib import Path


def agent_kind() -> str:
    return os.environ.get("CHATROOM_AGENT_KIND", "other")


# kind → 該平台提供原生 session 身分的環境變數，依優先序。
#
# **只查自己這個 kind 的那幾個**——這張表的形狀本身就是那條隔離規則：
# 想加一個變數就得先決定它屬於哪個 kind，沒有「順便也看一下別人的」這種寫法。
_PLATFORM_SESSION_VARS: dict[str, tuple[tuple[str, str], ...]] = {
    "claude": (("claude", "CLAUDE_CODE_SESSION_ID"),),
    # thread id 優先：App 的 dispatcher 掃的 writer lock 用的是它，兩邊必須
    # 對齊，否則指派路由不到（G1 的實際病灶）
    "codex": (("codex", "CODEX_THREAD_ID"), ("codex", "CODEX_SESSION_ID")),
}


def session_key(kind: str | None = None) -> str:
    """解析本進程的 session 識別。

    優先序：
    1. 顯式 ``CHATROOM_SESSION_KEY``——固定人格身分（特殊部署／測試用）。
       注意這是進程層級的設定：寫進專案 `.mcp.json` 會讓同專案所有 session
       共用同一把 key，因 join 冪等而合併成同一個 participant，訊息混流。
    2. agent 平台的 session id——**每個 kind 只認自己的那個變數**：

       - Claude Code 把 ``CLAUDE_CODE_SESSION_ID`` 傳進 MCP 進程環境
         （2026-08-28 實測）
       - Codex 提供 ``CODEX_THREAD_ID``（與 App 掃到的 writer lock 同值），
         ``CODEX_SESSION_ID`` 作為次選（2026-08-31 在 Codex 實例上實證）

       以它當識別符，同一個 session 重連時身分與游標延續，新 session 天然
       是新 participant。

       **跨 kind 一律不採用。** 從 Claude session 的 shell 拉起的 Codex 會
       「繼承」到母 session 的 ``CLAUDE_CODE_SESSION_ID``，反方向同理；
       不設防的話兩個進程撞同一把 key，而 join 冪等會把它們合併成同一個
       participant——訊息混流，兩邊都不會報錯。
    3. 每進程各自生成——最後防線。多開 session 必須是不同的 participant；
       若沿用機器層級共用 keyfile，多個 session 會因 join 冪等合併成同一身分。

       ⚠️ 但**落到這一層就是 G1 那個病**：進程重啟換一把新 key，於是指派送到
       舊 key 上、監看掛在新 key 上，永遠不會醒且沒有任何錯誤訊息。它只該是
       「這個平台沒有提供原生身分」時的退路，不該是常態。
    """
    if kind is None:
        kind = agent_kind()
    env = os.environ.get("CHATROOM_SESSION_KEY")
    if env:
        return env
    for allowed_kind, var in _PLATFORM_SESSION_VARS.get(kind, ()):
        platform_sid = os.environ.get(var)
        if platform_sid:
            return f"{allowed_kind}-{platform_sid}"
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


def host_name() -> str:
    """這台機器的名字，自報給 Hub 用。

    指派 UI 靠它把「我這台機器上的 agent」與「別人機器上的」分開——指派是
    私人房的入場券，把別人的 agent 指派進來，等於把房裡的內容送出去。
    可用 CHATROOM_HOST_NAME 覆寫（容器裡的 hostname 多半是無意義的隨機碼）。

    ⚠️ 這是**自報**的值，僅供辨識與分組，不是授權依據。信任邊界仍是 token。
    """
    override = os.environ.get("CHATROOM_HOST_NAME", "").strip()
    if override:
        return override[:200]
    try:
        return (socket.gethostname() or "")[:200]
    except OSError:
        # 取不到就留空。空值在 UI 上是「未知裝置」——不能當成本機，那會讓
        # 每一台取不到主機名的機器都混進本機清單
        return ""
