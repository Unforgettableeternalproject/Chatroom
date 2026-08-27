"""Bridge 的本機持久化狀態（P2-03）。

bridge 是 stdio 程序，agent 每次重啟就換一個進程。若身分（participant_id）與
讀取游標（last_seq）只活在記憶體裡，重啟後 agent 就得重新 join、並且無從得知
自己上次讀到哪裡。這裡把兩者落在 ``~/.chatroom/state.json``。

檔案格式（version 1）::

    {
      "version": 1,
      "rooms": {
        "<room_id>": {
          "participant_id": "...",
          "display_name": "...",
          "last_seq": 42
        }
      }
    }

設計取捨：
- **損毀即重建**：任何無法解析／結構不符的情況都退回空狀態，並把原檔改名保留為
  ``state.json.corrupt`` 供事後檢查。狀態是可重建的快取，不值得讓 bridge 崩潰。
- **原子寫入**：先寫暫存檔再 ``os.replace``，避免寫到一半被中斷而產生半截檔。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

STATE_VERSION = 1


def default_state_path() -> Path:
    """狀態檔預設位置；可用 ``CHATROOM_STATE_PATH`` 覆寫（測試與多實例用）。"""
    override = os.environ.get("CHATROOM_STATE_PATH")
    if override:
        return Path(override)
    return Path.home() / ".chatroom" / "state.json"


class BridgeState:
    """room_id → (participant_id, display_name, last_seq) 的持久化對照表。"""

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path is not None else default_state_path()
        self._rooms: dict[str, dict[str, Any]] = {}
        self.load()

    # ---------- 讀寫 ----------

    def load(self) -> None:
        """讀取狀態檔；任何異常都安全重建為空狀態。"""
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self._rooms = {}
            return
        except (OSError, ValueError):
            self._quarantine()
            self._rooms = {}
            return

        rooms = raw.get("rooms") if isinstance(raw, dict) else None
        if not isinstance(rooms, dict):
            self._quarantine()
            self._rooms = {}
            return

        # 逐房驗證，壞掉的單一房間跳過即可，不必整份丟棄
        clean: dict[str, dict[str, Any]] = {}
        for room_id, entry in rooms.items():
            if not isinstance(room_id, str) or not isinstance(entry, dict):
                continue
            pid = entry.get("participant_id")
            name = entry.get("display_name")
            seq = entry.get("last_seq", 0)
            clean[room_id] = {
                "participant_id": pid if isinstance(pid, str) else None,
                "display_name": name if isinstance(name, str) else None,
                "last_seq": seq if isinstance(seq, int) and not isinstance(seq, bool) else 0,
            }
        self._rooms = clean

    def save(self) -> None:
        """原子寫回狀態檔；寫入失敗不視為致命錯誤（狀態可重建）。"""
        payload = {"version": STATE_VERSION, "rooms": self._rooms}
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            tmp.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            os.replace(tmp, self.path)
        except OSError:
            pass

    def _quarantine(self) -> None:
        """把無法解析的狀態檔改名保留，避免下次啟動又踩同一顆地雷。"""
        try:
            self.path.replace(self.path.with_suffix(self.path.suffix + ".corrupt"))
        except OSError:
            pass

    # ---------- 房間身分 ----------

    def _entry(self, room_id: str) -> dict[str, Any]:
        return self._rooms.setdefault(
            room_id, {"participant_id": None, "display_name": None, "last_seq": 0}
        )

    def participant_id(self, room_id: str) -> str | None:
        return self._rooms.get(room_id, {}).get("participant_id")

    def display_name(self, room_id: str) -> str | None:
        return self._rooms.get(room_id, {}).get("display_name")

    def set_identity(self, room_id: str, participant_id: str, display_name: str | None) -> None:
        entry = self._entry(room_id)
        # 換身分等同換一段對話歷史的立足點，但訊息序號是房間層級的，游標保留即可
        entry["participant_id"] = participant_id
        entry["display_name"] = display_name
        self.save()

    def clear_identity(self, room_id: str) -> None:
        """身分失效（leave 或被 sweeper 移除）時清掉，但保留讀取游標。"""
        if room_id in self._rooms:
            self._rooms[room_id]["participant_id"] = None
            self._rooms[room_id]["display_name"] = None
            self.save()

    # ---------- 讀取游標 ----------

    def last_seq(self, room_id: str) -> int:
        return self._rooms.get(room_id, {}).get("last_seq", 0)

    def set_last_seq(self, room_id: str, seq: int) -> None:
        """游標只前進不後退，避免亂序回寫造成重讀。"""
        entry = self._entry(room_id)
        if seq > entry["last_seq"]:
            entry["last_seq"] = seq
            self.save()

    def reset_cursor(self, room_id: str, seq: int = 0) -> None:
        """明確把游標倒回指定位置（agent 想重讀歷史時用）。"""
        self._entry(room_id)["last_seq"] = seq
        self.save()

    def rooms(self) -> dict[str, dict[str, Any]]:
        return {rid: dict(entry) for rid, entry in self._rooms.items()}
