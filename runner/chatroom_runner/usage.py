"""用量視窗（REMOTE-OPS-PLAN §4.4／§6.4 的軟上限）。

存在本機 sqlite：執行器重啟不該把「近 5 小時用掉多少」忘掉——忘掉的那一刻
軟上限就等於不存在，而它本來就是自我約束而非真實額度（§10）。

⚠️ 這裡的數字是**估算**：Hub 不知道帳號真實剩餘額度，任何地方都讀不到。
面板上要照這個語意寫，不要讓人以為那是官方的剩餘量。
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

_SCHEMA = """
CREATE TABLE IF NOT EXISTS run_usage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_run_usage_at ON run_usage(at);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class UsageWindow:
    hours: float
    tokens: int
    cost_usd: float
    soft_cap_tokens: int
    soft_cap_usd: float

    @property
    def over_soft_cap(self) -> bool:
        if self.soft_cap_tokens > 0 and self.tokens >= self.soft_cap_tokens:
            return True
        return self.soft_cap_usd > 0 and self.cost_usd >= self.soft_cap_usd

    def to_dict(self) -> dict:
        return {"window_hours": self.hours, "tokens": self.tokens,
                "cost_usd": round(self.cost_usd, 4),
                "soft_cap_tokens": self.soft_cap_tokens,
                "soft_cap_usd": self.soft_cap_usd,
                "over_soft_cap": self.over_soft_cap,
                "remaining_tokens": max(0, self.soft_cap_tokens - self.tokens)
                if self.soft_cap_tokens > 0 else None}


class UsageStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(path))
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def record(self, run_id: str, tokens: int, cost_usd: float,
               at: str | None = None) -> None:
        self._conn.execute(
            "INSERT INTO run_usage (run_id, at, tokens, cost_usd)"
            " VALUES (?,?,?,?)", (run_id, at or _now(), int(tokens),
                                  float(cost_usd)))
        self._conn.commit()

    def totals(self, hours: float) -> tuple[int, float]:
        since = (datetime.now(timezone.utc)
                 - timedelta(hours=hours)).isoformat()
        row = self._conn.execute(
            "SELECT COALESCE(SUM(tokens),0) AS t, COALESCE(SUM(cost_usd),0)"
            " AS c FROM run_usage WHERE at >= ?", (since,)).fetchone()
        return int(row["t"]), float(row["c"])

    def window(self, hours: float, soft_cap_tokens: int = 0,
               soft_cap_usd: float = 0.0) -> UsageWindow:
        tokens, cost = self.totals(hours)
        return UsageWindow(hours, tokens, cost, soft_cap_tokens, soft_cap_usd)

    def prune(self, keep_days: float = 14.0) -> None:
        cutoff = (datetime.now(timezone.utc)
                  - timedelta(days=keep_days)).isoformat()
        self._conn.execute("DELETE FROM run_usage WHERE at < ?", (cutoff,))
        self._conn.commit()
