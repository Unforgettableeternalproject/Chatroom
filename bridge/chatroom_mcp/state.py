"""Bridge 的本機持久化狀態（P2-03）。

bridge 是 stdio 程序，agent 每次重啟就換一個進程。若身分（participant_id）與
讀取游標（last_seq）只活在記憶體裡，重啟後 agent 就得重新 join、並且無從得知
自己上次讀到哪裡。這裡把兩者落在 ``~/.chatroom/state.json``。

檔案格式（version 1）::

    {
      "version": 1,
      "session_key": "...",
      "rooms": {
        "<room_id>": {
          "participant_id": "...",
          "display_name": "...",
          "last_seq": 42,
          "session_key": "..."
        }
      }
    }

設計取捨：
- **損毀即重建**：任何無法解析／結構不符的情況都退回空狀態，並把原檔改名保留為
  ``state.json.corrupt`` 供事後檢查。狀態是可重建的快取，不值得讓 bridge 崩潰。
- **原子寫入**：先寫暫存檔再 ``os.replace``，避免寫到一半被中斷而產生半截檔。
- **執行緒安全**：bridge 的工具是同步 ``def``，FastMCP 丟 threadpool 執行，
  所以兩個工具呼叫是**真的同時**在跑。沒有鎖的話有兩個洞：``json.dumps``
  正在走訪 ``_rooms`` 時另一條執行緒改它會直接炸；兩條執行緒又會寫同一個
  ``.tmp`` 檔，``os.replace`` 保住的只是「不會有半截檔」，保不住「內容是
  完整的那一份」。單一身分槽的時代碰不到，多 subagent 平行呼叫是常態
  （見 ``docs/SUBAGENT-IDENTITY.md`` §5）。
"""

from __future__ import annotations

import json
import os
import threading
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
        # 可重入：set_identity 之類的寫入路徑會在持鎖時再呼叫 save()
        self._lock = threading.RLock()
        self._session_key: str | None = None
        self._rooms: dict[str, dict[str, Any]] = {}
        self.load()

    # ---------- 讀寫 ----------

    def load(self) -> None:
        """讀取狀態檔；任何異常都安全重建為空狀態。"""
        with self._lock:
            self._load_locked()

    def _load_locked(self) -> None:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self._session_key = None
            self._rooms = {}
            return
        except (OSError, ValueError):
            self._quarantine()
            self._session_key = None
            self._rooms = {}
            return

        rooms = raw.get("rooms") if isinstance(raw, dict) else None
        if not isinstance(rooms, dict):
            self._quarantine()
            self._session_key = None
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
                "session_key": (
                    entry.get("session_key")
                    if isinstance(entry.get("session_key"), str)
                    else None
                ),
            }
        self._rooms = clean
        canonical = raw.get("session_key")
        if isinstance(canonical, str) and canonical:
            self._session_key = canonical
        else:
            # 相容已寫入 per-room canonical key 的舊檔。單一 bridge 應只對應
            # 一個 agent session；若舊檔異常混有多把 key，就安全退回未綁定。
            known = {e["session_key"] for e in clean.values() if e["session_key"]}
            self._session_key = next(iter(known)) if len(known) == 1 else None

    def save(self) -> None:
        """原子寫回狀態檔；寫入失敗不視為致命錯誤（狀態可重建）。

        序列化與寫檔都在鎖內：``json.dumps`` 會走訪 ``_rooms``，另一條執行緒
        在那當下改它就直接炸；而兩條執行緒也會寫同一個 ``.tmp``，
        ``os.replace`` 保得住「不是半截檔」，保不住「是完整的那一份」。
        """
        with self._lock:
            payload = {
                "version": STATE_VERSION,
                "session_key": self._session_key,
                "rooms": json.loads(json.dumps(self._rooms)),
            }
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                # tmp 檔名帶執行緒識別：共用一個 .tmp 的話，兩條執行緒即使
                # 各自持鎖也可能在不同時刻互相覆蓋對方尚未 replace 的暫存檔
                tmp = self.path.with_suffix(
                    f"{self.path.suffix}.{threading.get_ident():x}.tmp"
                )
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
        # 呼叫端一律已持鎖（RLock 可重入），這裡不再取一次
        return self._rooms.setdefault(
            room_id,
            {
                "participant_id": None,
                "display_name": None,
                "last_seq": 0,
                "session_key": None,
                "board_seq": 0,
            },
        )

    def participant_id(self, room_id: str) -> str | None:
        return self._rooms.get(room_id, {}).get("participant_id")

    def display_name(self, room_id: str) -> str | None:
        return self._rooms.get(room_id, {}).get("display_name")

    def session_key(self, room_id: str) -> str | None:
        """Hub 綁定的 canonical key；學到後同一 bridge 的所有房間共用。"""
        return self._session_key or self._rooms.get(room_id, {}).get("session_key")

    def set_identity(
        self,
        room_id: str,
        participant_id: str,
        display_name: str | None,
        session_key: str | None = None,
    ) -> None:
        with self._lock:
            entry = self._entry(room_id)
            # 換身分等同換一段對話歷史的立足點，但訊息序號是房間層級的，
            # 游標保留即可
            entry["participant_id"] = participant_id
            entry["display_name"] = display_name
            if session_key:
                self._session_key = session_key
                entry["session_key"] = session_key
            self.save()

    def clear_identity(self, room_id: str) -> None:
        """身分失效（leave 或被 sweeper 移除）時清掉，但保留讀取游標。"""
        with self._lock:
            if room_id in self._rooms:
                self._rooms[room_id]["participant_id"] = None
                self._rooms[room_id]["display_name"] = None
                self.save()

    # ---------- 讀取游標 ----------

    def last_seq(self, room_id: str) -> int:
        return self._rooms.get(room_id, {}).get("last_seq", 0)

    def set_last_seq(self, room_id: str, seq: int) -> None:
        """游標只前進不後退，避免亂序回寫造成重讀。"""
        with self._lock:
            entry = self._entry(room_id)
            if seq > entry["last_seq"]:
                entry["last_seq"] = seq
                self.save()

    # ---------- Board 水位 ----------
    #
    # 與訊息游標**完全分開**：Hub 那側 board 用的是 room.board_seq，另一個
    # 計數器（共用的話，人看到的訊息編號會被 board 的變動量推著跳號，而
    # reply_to_seq 是畫在 UI 上給人看的）。混用會讓兩邊互相把對方的位置
    # 沖掉，而且不會有任何地方報錯——只是安靜地漏訊息或漏 board 變動。

    def board_seq(self, room_id: str) -> int:
        return self._rooms.get(room_id, {}).get("board_seq", 0)

    def set_board_seq(self, room_id: str, seq: int) -> None:
        """水位只前進不後退，同 :meth:`set_last_seq`。"""
        with self._lock:
            entry = self._entry(room_id)
            if seq > entry.get("board_seq", 0):
                entry["board_seq"] = seq
                self.save()

    def reset_cursor(self, room_id: str, seq: int = 0) -> None:
        """明確把游標倒回指定位置（agent 想重讀歷史時用）。"""
        with self._lock:
            self._entry(room_id)["last_seq"] = seq
            self.save()

    def rooms(self) -> dict[str, dict[str, Any]]:
        with self._lock:
            return {rid: dict(entry) for rid, entry in self._rooms.items()}
