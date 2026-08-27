"""房間事件通知——long-poll 與 WebSocket 共用的 in-process pub/sub。

每個房間一個 asyncio.Condition；訊息落庫後 notify_all，
掛在 wait() 上的 long-poll / WS 推播被喚醒後各自去 DB 撈增量。
不在記憶體裡存訊息本體，DB 永遠是唯一真相來源。
"""

import asyncio
from collections import defaultdict


class RoomEvents:
    def __init__(self) -> None:
        self._conds: dict[str, asyncio.Condition] = defaultdict(asyncio.Condition)

    def _cond(self, room_id: str) -> asyncio.Condition:
        return self._conds[room_id]

    async def notify(self, room_id: str) -> None:
        cond = self._cond(room_id)
        async with cond:
            cond.notify_all()

    async def wait(self, room_id: str, timeout: float) -> bool:
        """等待房間有新事件；逾時回傳 False。"""
        cond = self._cond(room_id)
        async with cond:
            try:
                await asyncio.wait_for(cond.wait(), timeout=timeout)
                return True
            except asyncio.TimeoutError:
                return False
