"""零依賴的 .env 載入器。

從指定目錄（預設 cwd）往上找 `.env`，把**尚未設定**的鍵補進 os.environ。
真實環境變數永遠優先——.env 只補缺，不覆寫，因此 shell 裡臨時 override
一個值來測試仍然有效。
"""

from __future__ import annotations

import os
from pathlib import Path

# 往上搜尋最多幾層（涵蓋 `cd server && python -m chatroom_server` 的情境）
_MAX_DEPTH = 3


def load_env_file(start: Path | None = None) -> Path | None:
    """載入最近的 .env，回傳實際使用的檔案路徑（找不到時回 None）。

    搜尋順序：start（預設 cwd）往上 _MAX_DEPTH 層 → server/ 套件目錄 →
    repo 根目錄。後兩者讓「.env 放在 server/ 內」不受啟動時的 cwd 影響。
    """
    base = (start or Path.cwd()).resolve()
    package_dir = Path(__file__).resolve().parents[1]  # server/
    candidates = [
        base,
        *list(base.parents)[:_MAX_DEPTH],
        package_dir,
        package_dir.parent,  # repo 根目錄
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
