"""Chatroom MCP Bridge（stdio）。

薄殼：把 Hub 的 REST API 包成 MCP 工具，不含任何業務邏輯。

設定來源（環境變數）：
    CHATROOM_URL          Hub 位址，預設 http://127.0.0.1:8787
    CHATROOM_TOKEN        API token（Hub 未設 token 時可省略）
    CHATROOM_SESSION_KEY  本 agent 的 session 識別；未設定時自動生成並
                          存於 ~/.chatroom/session_key 以求跨次穩定
    CHATROOM_AGENT_KIND   claude / codex / human / other，預設 other
    CHATROOM_STATE_PATH   身分與游標狀態檔位置，預設 ~/.chatroom/state.json

所有工具都回傳字典，成功時含 ``"ok": true``，失敗時為
``{"ok": false, "reason": "<繁體中文說明>"}``——agent 永遠不會看到 HTTP 堆疊。
失敗若源自房間身分失效，另含 ``"need_rejoin": true``。

participant_id 是「每房間」的身分：join 後由 bridge 寫入本機狀態檔，
工具呼叫時依 room_id 自動帶上，bridge 重啟後仍然有效。
"""

from __future__ import annotations

import functools
import os
import uuid
from pathlib import Path
from typing import Any, Callable

from mcp.server.mcpserver import MCPServer

from .hub import HubClient, HubError
from .state import BridgeState


def _session_key() -> str:
    env = os.environ.get("CHATROOM_SESSION_KEY")
    if env:
        return env
    keyfile = Path.home() / ".chatroom" / "session_key"
    if keyfile.exists():
        existing = keyfile.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    keyfile.parent.mkdir(parents=True, exist_ok=True)
    key = uuid.uuid4().hex
    keyfile.write_text(key, encoding="utf-8")
    return key


SESSION_KEY = _session_key()
AGENT_KIND = os.environ.get("CHATROOM_AGENT_KIND", "other")

mcp = MCPServer("chatroom")

# ---------- 相依物件（延後建立，方便測試注入） ----------

_hub: HubClient | None = None
_state: BridgeState | None = None


def hub() -> HubClient:
    global _hub
    if _hub is None:
        _hub = HubClient()
    return _hub


def state() -> BridgeState:
    global _state
    if _state is None:
        _state = BridgeState()
    return _state


def configure(
    *, hub_client: HubClient | None = None, bridge_state: BridgeState | None = None
) -> None:
    """覆寫 bridge 的相依物件。測試以 MockTransport 注入時使用。"""
    global _hub, _state
    if hub_client is not None:
        _hub = hub_client
    if bridge_state is not None:
        _state = bridge_state


# ---------- 共用請求包裝 ----------


def _guard(fn: Callable[..., Any]) -> Callable[..., dict]:
    """把工具函式的回傳統一成結構化結果，並攔下所有 HubError。"""

    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> dict:
        try:
            result = fn(*args, **kwargs)
        except HubError as exc:
            out: dict[str, Any] = {"ok": False, "reason": exc.reason}
            if exc.identity_invalid:
                out["need_rejoin"] = True
            return out
        if isinstance(result, dict):
            return {"ok": True, **{k: v for k, v in result.items() if k != "ok"}}
        return {"ok": True, "result": result}

    return wrapper


def _room_request(
    room_id: str,
    method: str,
    path: str,
    *,
    require_identity: bool = True,
    **kwargs: Any,
) -> Any:
    """帶上該房間身分發出請求；身分失效時清掉本機紀錄並要求重新 join。"""
    participant_id = state().participant_id(room_id)
    if require_identity and not participant_id:
        raise HubError(
            f"你還沒有「{room_id}」這個房間的身分，請先呼叫 chatroom_join 加入。",
            identity_invalid=True,
        )
    try:
        return hub().request(method, path, participant_id=participant_id, **kwargs)
    except HubError as exc:
        if exc.identity_invalid and participant_id:
            state().clear_identity(room_id)
        raise


# ---------- 房間與成員 ----------


@mcp.tool()
@_guard
def chatroom_list_rooms() -> dict:
    """列出所有 active 聊天室，以及指派給你（本 session）的待處理邀請。

    這是探索用的第一個工具：不知道 room_id、或想確認有沒有人邀你進某個房間時呼叫。
    回傳 ``rooms``（含 name / topic / member_count）與 ``pending_assignments``
    （含 room_name / room_topic / note，說明邀你進去做什麼）。
    已加入過的房間會附上 ``you_joined_as``，也就是你在該房的顯示名稱。
    """
    data = hub().request("GET", "/api/rooms", params={"session_key": SESSION_KEY})
    # /api/rooms 的 pending_assignments 只有原始欄位；/api/assignments 有 join 房名，
    # 對 agent 更可讀，取得成功就用它替換
    try:
        richer = hub().request(
            "GET", "/api/assignments", params={"session_key": SESSION_KEY}
        )
        data["pending_assignments"] = richer.get("assignments", [])
    except HubError:
        pass
    for room in data.get("rooms", []):
        name = state().display_name(room.get("id", ""))
        if name:
            room["you_joined_as"] = name
    return data


@mcp.tool()
@_guard
def chatroom_join(room_id: str, preferred_name: str = "") -> dict:
    """加入聊天室，取得該房間的身分。

    發言、釘選、heartbeat 之前都必須先加入。可提供 ``preferred_name`` 作為偏好名稱，
    房內重名時 Hub 會自動調整；回傳實際被指派的 ``display_name``。
    同一個 session 重複加入同一房間是冪等的（回傳 ``rejoined: true``）。
    身分會寫入本機狀態檔，bridge 重啟後不需要重新加入。
    """
    data = hub().request(
        "POST",
        f"/api/rooms/{room_id}/join",
        json={
            "kind": AGENT_KIND,
            "session_key": SESSION_KEY,
            "preferred_name": preferred_name or None,
            "role": "agent",
        },
    )
    state().set_identity(room_id, data["participant_id"], data.get("display_name"))
    return data


@mcp.tool()
@_guard
def chatroom_leave(room_id: str) -> dict:
    """離開聊天室。

    任務結束、或不再需要關注這個房間時呼叫；房內會留下一則系統訊息。
    離開後本機身分即失效，之後要再發言必須重新 chatroom_join。
    注意：房內最後一個 agent 離開後，Hub 會自動封存該房間。
    """
    data = _room_request(room_id, "POST", f"/api/rooms/{room_id}/leave")
    state().clear_identity(room_id)
    return data


@mcp.tool()
@_guard
def chatroom_heartbeat(room_id: str) -> dict:
    """回報你仍在線，刷新該房間身分的 last_seen_at。

    Hub 的 presence sweeper 會把閒置逾時的 agent 移出房間，房內沒有 agent 時
    房間還會被自動封存。若你要離開工作區去做一件長時間的事（跑測試、長編譯），
    中途呼叫這個工具就能保住身分。
    正常讀寫訊息本來就會刷新 last_seen_at，因此**不必**在每次對話後都呼叫。
    """
    return _room_request(room_id, "POST", f"/api/rooms/{room_id}/heartbeat")


# ---------- 訊息 ----------


@mcp.tool()
@_guard
def chatroom_read(
    room_id: str,
    after_seq: int | None = None,
    limit: int = 100,
    pinned_only: bool = False,
) -> dict:
    """讀取聊天室訊息（增量）。

    ``after_seq`` 省略時自動沿用本機記住的讀取游標，連續呼叫不重複也不遺漏；
    想重讀歷史時明確傳 0。``pinned_only=true`` 只看釘選訊息，這種讀取**不會**
    推進游標（否則會跳過未釘選的訊息）。
    回傳 ``messages`` 與 ``next_after_seq``（下次可用的游標位置）。
    """
    effective = state().last_seq(room_id) if after_seq is None else after_seq
    data = _room_request(
        room_id,
        "GET",
        f"/api/rooms/{room_id}/messages",
        require_identity=False,
        params={"after_seq": effective, "limit": limit, "pinned_only": pinned_only},
    )
    messages = data.get("messages", [])
    if messages and not pinned_only:
        # P1-06 後 Hub 回傳權威 next_after_seq；缺欄位時（舊版 Hub）退回自算
        state().set_last_seq(room_id, data.get("next_after_seq", messages[-1]["seq"]))
    data["after_seq"] = effective
    data["next_after_seq"] = state().last_seq(room_id) if not pinned_only else effective
    return data


@mcp.tool()
@_guard
def chatroom_post(
    room_id: str,
    content: str,
    mentions: list[str] | None = None,
    reply_to: str = "",
) -> dict:
    """在聊天室發言。

    ``mentions`` 填房內成員的 display_name 列表，可以 ping 對方——被 ping 的 agent
    在 chatroom_wait 會看到 ``you_were_mentioned``，是請人接手時該用的方式。
    ``reply_to`` 填要回覆的訊息 id。需要先 chatroom_join 取得身分。
    """
    return _room_request(
        room_id,
        "POST",
        f"/api/rooms/{room_id}/messages",
        json={
            "content": content,
            "mentions": mentions or [],
            "reply_to": reply_to or None,
        },
    )


@mcp.tool()
@_guard
def chatroom_wait(room_id: str, after_seq: int | None = None, timeout: float = 25.0) -> dict:
    """等待新訊息（long-poll）。

    有新訊息立即返回，否則掛起到 ``timeout`` 秒（Hub 上限 55 秒）後回空清單。
    ``after_seq`` 省略時沿用本機游標，返回後游標自動前進。
    ``you_were_mentioned`` 為 true 表示有人在這批訊息裡 ping 你，應優先回應。
    這是「等別人回話」的正確做法，不要用輪詢 chatroom_read 取代。
    """
    effective = state().last_seq(room_id) if after_seq is None else after_seq
    data = _room_request(
        room_id,
        "GET",
        f"/api/rooms/{room_id}/updates",
        require_identity=False,
        params={"after_seq": effective, "timeout": timeout},
        timeout=timeout + 10.0,
    )
    last = data.get("last_seq")
    if isinstance(last, int):
        state().set_last_seq(room_id, last)
    data["after_seq"] = effective
    data["next_after_seq"] = state().last_seq(room_id)
    return data


@mcp.tool()
@_guard
def chatroom_pin(room_id: str, message_id: str) -> dict:
    """釘選一則訊息。

    用於標記房內的共識、決議或關鍵結論，讓後來加入的人能用
    ``chatroom_read(pinned_only=true)`` 快速掌握重點。封存房間不能釘選。
    """
    return _room_request(room_id, "POST", f"/api/messages/{message_id}/pin")


@mcp.tool()
@_guard
def chatroom_unpin(room_id: str, message_id: str) -> dict:
    """取消釘選一則訊息（結論被推翻或已過時時）。"""
    return _room_request(room_id, "DELETE", f"/api/messages/{message_id}/pin")


# ---------- 指派 ----------


@mcp.tool()
@_guard
def chatroom_assignments() -> dict:
    """查詢指派給你（本 session）的待處理邀請。

    人類可以指派某個 agent session 加入特定房間；這裡列出所有 ``pending`` 的邀請，
    含 ``id``（處理時要用）、``room_id``、``room_name``、``room_topic`` 與 ``note``
    （邀你進去做什麼）。開始新一輪工作前值得查一次。
    回應方式：chatroom_resolve_assignment，或直接 chatroom_join
    （加入該房間時 Hub 會自動把對應指派標記為 accepted）。
    """
    return hub().request("GET", "/api/assignments", params={"session_key": SESSION_KEY})


@mcp.tool()
@_guard
def chatroom_resolve_assignment(assignment_id: str, accept: bool) -> dict:
    """處理一筆指派：接受或婉拒。

    ``accept=true`` 標為 accepted，``accept=false`` 標為 declined。
    接受不會自動把你加進房間——判斷權在你——接受後仍需呼叫 chatroom_join。
    若手邊工作無法中斷，明確 decline 比放著不管好，人類才知道要另找人。
    已處理過的指派再次呼叫會回報找不到。
    """
    return hub().request(
        "POST",
        f"/api/assignments/{assignment_id}/resolve",
        json={"status": "accepted" if accept else "declined"},
    )


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
