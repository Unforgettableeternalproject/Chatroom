"""零依賴的 .env 載入器（bridge 版）。

真實環境變數永遠優先——.env 只補缺，不覆寫。這讓 `.mcp.json` 的
`${CHATROOM_TOKEN}` 展開為空字串時，bridge 仍能從 .env 撈到 token，
不必為了補環境變數重啟整個 agent。
"""

from __future__ import annotations

import os
from pathlib import Path

_MAX_DEPTH = 3

# bridge 自己會讀的鍵。**只在載入 Hub 的 `server/.env` 時當白名單用。**
#
# 那個檔是**Hub 的**設定，不是 bridge 的——它裡面有 Hub 專屬的東西，而
# 2026-09-07 起那包括 `CHATROOM_HUMAN_TOKEN`（人類憑證，`role=human`／
# 主持人視角／發放邀請三處只認它）。整份灌進 bridge 進程的話，**每一個
# agent 的環境裡都躺著一把它不該有的鑰匙**：Hub 那三道閘擋得住冒充，擋不住
# 「client 自己手上就有」。
#
# ⚠️ 實測（@測試Novia 提，2026-09-07 在開發端驗）：bridge 確實讀得到那把
# token，但送出的 Authorization 用的是 agent token——**沒有被用，不等於
# 不在**。這裡收的是「不在」。
#
# 白名單只套在 Hub 的 .env 上：bridge 自己目錄下的 .env 是給 bridge 的，
# 全載照舊。這是同一個形狀第三次（8/29 的 AGENT_KIND 撞 key、今天的測試
# 進程），而前兩次的結論都一樣——**共用檔的粒度不對**。
_BRIDGE_KEYS = frozenset({
    "CHATROOM_URL",
    "CHATROOM_TOKEN",
    "CHATROOM_AGENT_KIND",
    "CHATROOM_DEFAULT_NAME",
    "CHATROOM_SESSION_KEY",
    "CHATROOM_HOST_NAME",
    "CHATROOM_DOWNLOAD_DIR",
    "CHATROOM_STATE_PATH",
    "CHATROOM_STATE_TTL_DAYS",
    "CHATROOM_HOLD_MAX",
})


def load_env_file(start: Path | None = None) -> Path | None:
    """載入最近的 .env，回傳實際使用的檔案路徑（找不到時回 None）。

    搜尋順序：start（預設 cwd）往上 _MAX_DEPTH 層 → bridge/ 目錄 →
    repo 根目錄 → server/（Hub 的 .env 是 token 的單一真相來源）。
    """
    base = (start or Path.cwd()).resolve()
    package_dir = Path(__file__).resolve().parents[1]  # bridge/
    repo_root = package_dir.parent
    candidates = [
        base,
        *list(base.parents)[:_MAX_DEPTH],
        package_dir,
        repo_root,
        repo_root / "server",
    ]
    hub_dir = repo_root / "server"
    seen: set[Path] = set()
    for folder in candidates:
        if folder in seen:
            continue
        seen.add(folder)
        candidate = folder / ".env"
        if candidate.is_file():
            # Hub 的 .env 只補 bridge 自己要的那幾個鍵，見 `_BRIDGE_KEYS`
            _apply(candidate, only=_BRIDGE_KEYS if folder == hub_dir else None)
            return candidate
    return None


def _apply(path: Path, only: frozenset[str] | None = None) -> None:
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if only is not None and key not in only:
            continue
        if key and key not in os.environ:
            os.environ[key] = value
