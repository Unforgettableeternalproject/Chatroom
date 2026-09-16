"""`--output-format stream-json` 的逐行解析（REMOTE-OPS-PLAN §5.3）。

三件事在這裡定案：

1. **context 估算**：外部沒有任何方式讀 Claude Code 的 context 百分比，只能
   自己從每則 assistant 訊息的 ``usage`` 累計
   （``input + cache_read + cache_creation``）。超過軟閾值就立 ``handoff.flag``
   ——這是唯一能在自動壓縮之前逼 agent 交接的路徑。
2. **rate limit**：``system/api_retry`` 且 ``error == "rate_limit"`` 計數；
   達門檻即把執行器標 limited。既有的 run 讓 CLI 自己重試。
3. **成敗**：看 exit code 與 ``is_error``，**不是只看 ``subtype``**。
   實測（2.1.273）加 ``--bare`` 未登入時 ``result.subtype`` 照樣是 ``success``，
   而那一輪什麼都沒做。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Callable

# 週／月上限的終端錯誤字串。**不自動重試**——重試只是把同一句話再撞一次
WEEKLY_LIMIT_PATTERNS = (
    "weekly limit",
    "monthly limit",
    "usage limit reached",
    "limit will reset",
)
_WEEKLY_RE = re.compile("|".join(re.escape(p) for p in WEEKLY_LIMIT_PATTERNS),
                        re.IGNORECASE)


def looks_like_weekly_limit(text: str) -> bool:
    return bool(text) and bool(_WEEKLY_RE.search(text))


def parse_line(line: str) -> dict | None:
    """一行一事件。**不合法的行安靜略過**。

    stream 裡混進非 JSON 的行（CLI 的警告、被別的東西污染的 stdout）時，
    炸掉整個 run 的代價遠大於漏讀一行：那一行本來就不是我們要的資料。
    """
    line = line.strip()
    if not line or not line.startswith("{"):
        return None
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return None
    return event if isinstance(event, dict) else None


def context_tokens_of(usage: dict) -> int:
    """一則 assistant 訊息的 usage ⇒ 當下的 context 大小估算。

    ``output_tokens`` 不算：它是這一則的產出，下一輪才會變成輸入的一部分，
    而那時它會出現在 ``input_tokens`` 裡——現在加等於算兩次。
    """
    if not isinstance(usage, dict):
        return 0
    return (int(usage.get("input_tokens", 0) or 0)
            + int(usage.get("cache_read_input_tokens", 0) or 0)
            + int(usage.get("cache_creation_input_tokens", 0) or 0))


@dataclass
class StreamState:
    """一輪 claude 子進程看下來的結果。"""

    session_id: str = ""
    context_tokens: int = 0
    peak_context_tokens: int = 0
    rate_limit_retries: int = 0
    assistant_messages: int = 0
    num_turns: int = 0
    total_cost_usd: float = 0.0
    usage: dict = field(default_factory=dict)
    subtype: str = ""
    is_error: bool = False
    result_text: str = ""
    weekly_limit: bool = False
    soft_limit_hit: bool = False
    saw_result: bool = False
    texts: list[str] = field(default_factory=list)

    def total_tokens(self) -> int:
        u = self.usage or {}
        return (int(u.get("input_tokens", 0) or 0)
                + int(u.get("output_tokens", 0) or 0)
                + int(u.get("cache_read_input_tokens", 0) or 0)
                + int(u.get("cache_creation_input_tokens", 0) or 0))


class StreamWatcher:
    """把事件餵進來，狀態自己長。

    ``on_soft_limit`` 只會被呼叫**一次**：立旗標是個不可逆的動作，重複呼叫會
    讓房裡出現一串一模一樣的「請交接」。
    """

    def __init__(self, soft_limit_tokens: int,
                 on_soft_limit: Callable[[int], None] | None = None,
                 rate_limit_threshold: int = 3) -> None:
        self.soft_limit_tokens = soft_limit_tokens
        self.on_soft_limit = on_soft_limit
        self.rate_limit_threshold = rate_limit_threshold
        self.state = StreamState()

    @property
    def rate_limited(self) -> bool:
        return (self.rate_limit_threshold > 0
                and self.state.rate_limit_retries >= self.rate_limit_threshold)

    def feed_line(self, line: str) -> dict | None:
        event = parse_line(line)
        if event is not None:
            self.feed(event)
        return event

    def feed(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "system":
            self._system(event)
        elif kind == "assistant":
            self._assistant(event)
        elif kind == "result":
            self._result(event)
        if not event.get("session_id"):
            return
        self.state.session_id = event["session_id"]

    def _system(self, event: dict) -> None:
        err = str(event.get("error") or "")
        if event.get("subtype") == "api_retry" and err == "rate_limit":
            self.state.rate_limit_retries += 1
        if looks_like_weekly_limit(str(event.get("message") or err)):
            self.state.weekly_limit = True

    def _assistant(self, event: dict) -> None:
        msg = event.get("message") or {}
        self.state.assistant_messages += 1
        tokens = context_tokens_of(msg.get("usage") or {})
        if tokens:
            self.state.context_tokens = tokens
            self.state.peak_context_tokens = max(
                self.state.peak_context_tokens, tokens)
        # 🚨 **只看 `error` 欄位，不掃一般文字**（審查 09/16）：agent 在摘要裡
        # 寫一句「這次沒有撞到 weekly limit」就會被判成撞牆，整台執行器停收，
        # 而房裡看到的是一個沒有理由的 limited。撞牆的權威來源是 result／
        # system 事件與這裡的 error 欄位
        err = str(event.get("error") or msg.get("error") or "")
        if looks_like_weekly_limit(err):
            self.state.weekly_limit = True
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                self.state.texts.append(str(block.get("text") or ""))
        if (self.soft_limit_tokens > 0
                and self.state.context_tokens >= self.soft_limit_tokens
                and not self.state.soft_limit_hit):
            self.state.soft_limit_hit = True
            if self.on_soft_limit is not None:
                self.on_soft_limit(self.state.context_tokens)

    def _result(self, event: dict) -> None:
        st = self.state
        st.saw_result = True
        st.subtype = str(event.get("subtype") or "")
        st.is_error = bool(event.get("is_error"))
        st.num_turns = int(event.get("num_turns", 0) or 0)
        st.total_cost_usd = float(event.get("total_cost_usd", 0.0) or 0.0)
        if isinstance(event.get("usage"), dict):
            st.usage = event["usage"]
        st.result_text = str(event.get("result") or "")
        if looks_like_weekly_limit(st.result_text):
            st.weekly_limit = True
