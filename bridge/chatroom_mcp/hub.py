"""Hub REST 客戶端與錯誤轉譯（P2-02）。

bridge 的唯一職責是把 Hub 的 HTTP 語意翻成 agent 看得懂的話。原本每個工具都
``raise_for_status()``，agent 收到的是一串 httpx 堆疊，既無法判斷該怎麼補救、
也可能誤以為是自己的工具壞了。這裡把所有失敗收斂成 :class:`HubError`，
由 server 層轉成 ``{"ok": false, "reason": "<繁中說明>"}``。

錯誤格式契約：Hub 沿用 FastAPI 預設的 ``{"detail": ...}``，本模組據此轉譯。
"""

from __future__ import annotations

import os
from typing import Any

import httpx

DEFAULT_HUB_URL = "http://127.0.0.1:8787"
DEFAULT_TIMEOUT = 30.0


class HubError(Exception):
    """對 agent 可讀的失敗說明。

    Attributes:
        reason: 繁體中文的可讀說明，直接給 agent 看。
        status: HTTP 狀態碼；連線層失敗為 None。
        detail: Hub 回傳的原始 detail，保留給除錯用。
        identity_invalid: 身分已失效，呼叫端應清掉本機身分並提示重新 join。
    """

    def __init__(
        self,
        reason: str,
        *,
        status: int | None = None,
        detail: Any = None,
        identity_invalid: bool = False,
    ) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status = status
        self.detail = detail
        self.identity_invalid = identity_invalid


def _detail_text(detail: Any) -> str:
    """把 FastAPI 的 detail（字串或驗證錯誤陣列）壓成一行字。"""
    if detail is None:
        return ""
    if isinstance(detail, str):
        return detail
    if isinstance(detail, list):
        parts = []
        for item in detail:
            if isinstance(item, dict):
                loc = ".".join(str(x) for x in item.get("loc", []))
                parts.append(f"{loc}: {item.get('msg', '')}".strip(": "))
            else:
                parts.append(str(item))
        return "；".join(p for p in parts if p)
    return str(detail)


def translate_status(status: int, detail: Any, hub_url: str) -> HubError:
    """把 HTTP 狀態碼 + detail 轉成有行動指引的中文說明。"""
    text = _detail_text(detail)
    low = text.lower()

    if status == 401:
        if "participant" in low:
            return HubError(
                "尚未取得房間身分：請先用 chatroom_join 加入該房間再試一次。",
                status=status, detail=detail, identity_invalid=True,
            )
        return HubError(
            f"Hub 拒絕了這次請求（token 無效或未設定）。請確認環境變數 "
            f"CHATROOM_TOKEN 與 Hub（{hub_url}）設定一致。",
            status=status, detail=detail,
        )

    if status == 403:
        if "does not belong" in low:
            return HubError(
                "這個身分不屬於指定的房間；同一個 participant_id 不能跨房使用，"
                "請對該房間重新呼叫 chatroom_join。",
                status=status, detail=detail, identity_invalid=True,
            )
        return HubError(
            "你的房間身分已失效（可能因閒置逾時被移出房間）。"
            "請重新呼叫 chatroom_join 取得新身分後再試。",
            status=status, detail=detail, identity_invalid=True,
        )

    if status == 404:
        if "room" in low:
            return HubError(
                "找不到這個聊天室：room_id 可能有誤，或房間已被刪除。"
                "可用 chatroom_list_rooms 確認現有房間。",
                status=status, detail=detail,
            )
        if "message" in low:
            return HubError(
                "找不到這則訊息：message_id 可能有誤。", status=status, detail=detail
            )
        if "assignment" in low:
            return HubError(
                "找不到這筆指派，或它已經被處理過了。"
                "可用 chatroom_assignments 重新確認待處理清單。",
                status=status, detail=detail,
            )
        return HubError(f"Hub 找不到對應資源（{text or '404'}）。",
                        status=status, detail=detail)

    if status == 409:
        if "archiv" in low:
            return HubError(
                "這個聊天室已封存，只能讀取、不能寫入。"
                "若確定要繼續使用，需由人類在 UI 或 API 端解除封存。",
                status=status, detail=detail,
            )
        return HubError(f"操作與 Hub 目前狀態衝突（{text or '409'}）。",
                        status=status, detail=detail)

    if status == 422:
        return HubError(f"參數不符合 Hub 的要求：{text or '請檢查傳入的欄位'}。",
                        status=status, detail=detail)

    if status >= 500:
        return HubError(
            f"Hub 內部發生錯誤（HTTP {status}）。請檢查 Hub 端的日誌。",
            status=status, detail=detail,
        )

    return HubError(f"Hub 回傳未預期的狀態 HTTP {status}：{text or '無說明'}。",
                    status=status, detail=detail)


class HubClient:
    """對 Chatroom Hub 的薄 HTTP 客戶端。

    ``transport`` 供測試注入 ``httpx.MockTransport``，正式執行時保持 None。
    """

    def __init__(
        self,
        base_url: str | None = None,
        token: str | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self.base_url = base_url or os.environ.get("CHATROOM_URL", DEFAULT_HUB_URL)
        self.token = token if token is not None else os.environ.get("CHATROOM_TOKEN", "")
        self.timeout = timeout
        self.transport = transport

    def _headers(self, participant_id: str | None) -> dict[str, str]:
        headers: dict[str, str] = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if participant_id:
            headers["X-Participant-Id"] = participant_id
        return headers

    def request(
        self,
        method: str,
        path: str,
        *,
        participant_id: str | None = None,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
        timeout: float | None = None,
    ) -> Any:
        """發出請求並回傳解析後的 JSON；任何失敗都轉成 :class:`HubError`。"""
        try:
            with httpx.Client(
                base_url=self.base_url,
                headers=self._headers(participant_id),
                timeout=timeout or self.timeout,
                transport=self.transport,
            ) as client:
                response = client.request(method, path, params=params, json=json)
        except httpx.TimeoutException as exc:
            raise HubError(
                f"連線 Hub（{self.base_url}）逾時。Hub 可能忙碌或網路不穩，稍後再試。"
            ) from exc
        except httpx.HTTPError as exc:
            raise HubError(
                f"無法連線到 Chatroom Hub（{self.base_url}）：{exc.__class__.__name__}。"
                "請確認 Hub 已啟動，且 CHATROOM_URL 設定正確。"
            ) from exc

        if response.status_code >= 400:
            detail = None
            try:
                body = response.json()
                detail = body.get("detail") if isinstance(body, dict) else body
            except ValueError:
                detail = response.text
            raise translate_status(response.status_code, detail, self.base_url)

        try:
            return response.json()
        except ValueError as exc:
            raise HubError("Hub 回應不是合法的 JSON，版本可能不相容。") from exc
