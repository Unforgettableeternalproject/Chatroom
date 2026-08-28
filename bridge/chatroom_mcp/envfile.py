"""零依賴的 .env 載入器（bridge 版）。

真實環境變數永遠優先——.env 只補缺，不覆寫。這讓 `.mcp.json` 的
`${CHATROOM_TOKEN}` 展開為空字串時，bridge 仍能從 .env 撈到 token，
不必為了補環境變數重啟整個 agent。
"""

from __future__ import annotations

import os
from pathlib import Path

_MAX_DEPTH = 3


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
    seen: set[Path] = set()
    for folder in candidates:
        if folder in seen:
            continue
        seen.add(folder)
        candidate = folder / ".env"
        if candidate.is_file():
            _apply(candidate)
            return candidate
    return None


def _apply(path: Path) -> None:
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value
