"""Subagent 身分登記簿——**只活在記憶體裡**。

為什麼不落地（與 `state.py` 的作法刻意相反）：

- subagent 是父層進程裡的臨時分身。進程死了，那些身分就該作廢——落地只會
  讓下一次啟動撿到一堆對應不到任何執行中工作的殭屍 handle
- `BridgeState.save()` 是整檔覆寫，而多個 subagent 平行呼叫工具是**真併發**
  （bridge 的工具是同步 `def`，FastMCP 丟 threadpool 執行）。把 subagent 身分
  也塞進那個檔，等於把一個既有的 lost update 缺陷放大成常態
  （見 `docs/SUBAGENT-IDENTITY.md` §5）

記憶體這份仍然要鎖：同一個父層平行派兩個 subagent 時，兩條執行緒會同時寫
這個 dict。
"""

from __future__ import annotations

import re
import threading
import uuid
from dataclasses import dataclass


@dataclass(frozen=True)
class Subagent:
    """一個已登記的 subagent 身分。handle 是 agent 之後用來自報的憑據。"""

    handle: str
    room_id: str
    participant_id: str
    display_name: str
    session_key: str
    parent_participant_id: str
    parent_name: str


def derive_key(parent_key: str, name: str) -> str:
    """派生 session_key：``<父key>#<名字slug>-<8碼隨機>``。

    隨機段不是裝飾。少了它，同一個父層平行派兩個同名 subagent（``tester``
    兩份）就會算出同一把 key——Hub 那邊會擋下來（回 409），但擋下來的意思是
    第二個 subagent **根本進不了房**。隨機段讓它們天生就是不同的身分。

    slug 只為了人眼辨識，唯一性完全由隨機段負責。
    """
    slug = re.sub(r"[^0-9A-Za-z_-]+", "", name)[:24] or "sub"
    return f"{parent_key}#{slug}-{uuid.uuid4().hex[:8]}"


class SubagentRegistry:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._by_handle: dict[str, Subagent] = {}

    def add(self, sub: Subagent) -> None:
        with self._lock:
            self._by_handle[sub.handle] = sub

    def get(self, handle: str) -> Subagent | None:
        with self._lock:
            return self._by_handle.get(handle)

    def drop(self, handle: str) -> Subagent | None:
        with self._lock:
            return self._by_handle.pop(handle, None)

    def in_room(self, room_id: str) -> list[Subagent]:
        with self._lock:
            return [s for s in self._by_handle.values() if s.room_id == room_id]

    def new_handle(self) -> str:
        return f"sub-{uuid.uuid4().hex[:12]}"
