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


class InboxBus:
    """通知收件匣的即時通道（`/ws/inbox`）。

    與 `RoomEvents`／`ReactionBus` 分開：收件匣跨房、綁收件人（session_key
    或 `__host__`），不屬於任何一間房。payload 只放「哪個收件人有動靜」，
    訂閱端自己去 DB 算未讀數（DB 仍是唯一真相）。
    """

    def __init__(self) -> None:
        self._subs: dict[str, set[asyncio.Queue]] = defaultdict(set)

    def subscribe(self, keys: set[str]) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        for k in keys:
            self._subs[k].add(q)
        return q

    def unsubscribe(self, keys: set[str], q: asyncio.Queue) -> None:
        for k in keys:
            subs = self._subs.get(k)
            if subs is not None:
                subs.discard(q)
                if not subs:
                    self._subs.pop(k, None)

    def publish(self, recipient_key: str, latest_id: int | None) -> None:
        for q in list(self._subs.get(recipient_key, ())):
            q.put_nowait((recipient_key, latest_id))


class ReactionBus:
    """表情回應的即時通道，**刻意與 RoomEvents 分開**。

    RoomEvents 的 notify 會喚醒 long-poll 與 watcher；表情回應不是訊息，
    不能叫醒任何 agent。這裡只有 WS 連線訂閱，payload 是被動到的 message_id，
    訂閱端自己去 DB 重算彙總（DB 仍是唯一真相）。
    """

    def __init__(self) -> None:
        self._subs: dict[str, set[asyncio.Queue]] = defaultdict(set)

    def subscribe(self, room_id: str) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        self._subs[room_id].add(q)
        return q

    def unsubscribe(self, room_id: str, q: asyncio.Queue) -> None:
        subs = self._subs.get(room_id)
        if subs is not None:
            subs.discard(q)
            if not subs:
                self._subs.pop(room_id, None)

    def publish(self, room_id: str, message_id: str) -> None:
        for q in list(self._subs.get(room_id, ())):
            q.put_nowait(message_id)
