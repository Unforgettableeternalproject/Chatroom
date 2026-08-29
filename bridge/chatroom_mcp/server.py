"""Chatroom MCP Bridge（stdio）。

薄殼：把 Hub 的 REST API 包成 MCP 工具，不含任何業務邏輯。

設定來源（環境變數）：
    CHATROOM_URL          Hub 位址，預設 http://127.0.0.1:8787
    CHATROOM_TOKEN        API token（Hub 未設 token 時可省略）
    CHATROOM_SESSION_KEY  本 agent 的 session 識別。顯式設定＝固定人格身分
                          （特殊部署用）；未設定時優先取 agent 平台的
                          session id（Claude Code 的 CLAUDE_CODE_SESSION_ID），
                          再退回每進程各自生成（多開 session 各自獨立）
    CHATROOM_AGENT_KIND   claude / codex / human / other，預設 other
    CHATROOM_DEFAULT_NAME join 未帶 preferred_name 時的預設代稱；
                          房內重名由 Hub 自動編號（Novia → Novia-2）
    CHATROOM_STATE_PATH   身分與游標狀態檔位置；預設跟著 session_key 走
                          （~/.chatroom/state-<key>.json），並發 session 不互踩

所有工具都回傳字典，成功時含 ``"ok": true``，失敗時為
``{"ok": false, "reason": "<繁體中文說明>"}``——agent 永遠不會看到 HTTP 堆疊。
失敗若源自房間身分失效，另含 ``"need_rejoin": true``。

participant_id 是「每房間」的身分：join 後由 bridge 寫入本機狀態檔，
工具呼叫時依 room_id 自動帶上，bridge 重啟後仍然有效。
"""

from __future__ import annotations

import functools
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable

from mcp.server.mcpserver import MCPServer

# MCP 設定常以「python server.py」直接執行本檔，此時沒有套件上下文，
# 相對匯入會炸 ImportError——補上父目錄與 __package__ 讓兩種啟動方式都能用
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "chatroom_mcp"

from . import identity  # noqa: E402
from .envfile import load_env_file  # noqa: E402
from .hub import HubClient, HubError  # noqa: E402
from .state import BridgeState  # noqa: E402

# 環境變數缺席時以 .env 補缺（真實環境變數優先）。必須在讀取任何
# CHATROOM_* 之前執行——bridge 的設定都在 import 期就固定下來
load_env_file()

AGENT_KIND = os.environ.get("CHATROOM_AGENT_KIND", "other")
# join 未指定 preferred_name 時的預設代稱；房內重名由 Hub 自動加 -2 編號
DEFAULT_NAME = os.environ.get("CHATROOM_DEFAULT_NAME", "")


def _session_key() -> str:
    """本 bridge 進程的 session 識別。解析邏輯見 identity.session_key。"""
    return identity.session_key(AGENT_KIND)


SESSION_KEY = _session_key()


def _state_filename(session_key: str) -> str:
    """session_key → 安全的 state 檔名。見 identity.state_filename。"""
    return identity.state_filename(session_key)

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
        if os.environ.get("CHATROOM_STATE_PATH"):
            _state = BridgeState()  # 顯式路徑（測試/特殊部署）
        else:
            # state 檔跟著 session_key 走：並發 session 各寫各的，不互踩
            _state = BridgeState(
                Path.home() / ".chatroom" / _state_filename(SESSION_KEY)
            )
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


def _presence_params() -> dict[str, str]:
    """帶 session_key 的查詢參數，順便向 Hub 自報 kind 與代稱。

    Hub 據此維護 session 名錄（指派 UI 的掃描來源）；label 用
    CHATROOM_DEFAULT_NAME，讓使用者在清單上認得出這個 session 是誰。
    """
    params = {"session_key": SESSION_KEY, "kind": AGENT_KIND}
    if DEFAULT_NAME:
        params["label"] = DEFAULT_NAME
    return params


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


def _participant_id_by_name(room_id: str, name: str) -> str:
    """房內顯示名稱 → participant_id。

    agent 手上有的是名字（訊息裡看到的那個），Hub 要的是 id。這層轉換放在
    bridge，免得每個 agent 自己去翻房間詳情——翻錯的話會靜靜地問到別人身上。
    """
    data = hub().request("GET", f"/api/rooms/{room_id}")
    actives = [
        p for p in data.get("participants", [])
        if p.get("status") == "active"
    ]
    for p in actives:
        if p.get("display_name") == name:
            return p["id"]
    available = "、".join(
        p["display_name"] for p in actives if p.get("role") == "human"
    ) or "（房裡沒有人類）"
    raise HubError(
        f"房裡沒有名為「{name}」的成員。目前在房內的人類：{available}。"
        "名字要與訊息中顯示的完全一致。"
    )


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
    data = hub().request("GET", "/api/rooms", params=_presence_params())
    # /api/rooms 的 pending_assignments 只有原始欄位；/api/assignments 有 join 房名，
    # 對 agent 更可讀，取得成功就用它替換
    try:
        richer = hub().request(
            "GET", "/api/assignments", params=_presence_params()
        )
        data["pending_assignments"] = richer.get("assignments", [])
    except HubError:
        pass
    for room in data.get("rooms", []):
        name = state().display_name(room.get("id", ""))
        if name:
            room["you_joined_as"] = name
    # key 是動態的（session id 或每進程生成），要讓使用者能指派就得先讓
    # agent 說得出自己是哪一把 key
    data["your_session_key"] = SESSION_KEY
    return data


@mcp.tool()
@_guard
def chatroom_join(
    room_id: str,
    preferred_name: str = "",
    assignment_id: str = "",
) -> dict:
    """加入聊天室，取得該房間的身分。

    發言、釘選、heartbeat 之前都必須先加入。可提供 ``preferred_name`` 作為偏好名稱，
    房內重名時 Hub 會自動調整；回傳實際被指派的 ``display_name``。
    收到 App 經 Codex queue 送來的指派時，請把通知內的 ``assignment_id`` 傳入；
    Hub 會以該指派綁定的 Codex thread id 作為正式 session 身分，不會使用 MCP
    臨時生成的 key。若指派者已幫你取名，會以那個名字為準
    （回傳含 ``name_from_assignment: true``），不必覺得奇怪。
    同一個 session 重複加入同一房間是冪等的（回傳 ``rejoined: true``）。
    身分會寫入本機狀態檔，bridge 重啟後不需要重新加入。
    """
    canonical_key = state().session_key(room_id) or SESSION_KEY
    data = hub().request(
        "POST",
        f"/api/rooms/{room_id}/join",
        json={
            "kind": AGENT_KIND,
            "session_key": canonical_key,
            "assignment_id": assignment_id or None,
            "preferred_name": preferred_name or DEFAULT_NAME or None,
            "role": "agent",
        },
    )
    state().set_identity(
        room_id,
        data["participant_id"],
        data.get("display_name"),
        data.get("session_key", canonical_key),
    )
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
    想重讀歷史時明確傳 0。``pinned_only=true`` 只看釘選訊息——這種讀取預設從
    頭掃整個房間（釘選牆語意，不從游標起算），也**不會**推進游標
    （否則會跳過未釘選的訊息）。
    回傳 ``messages`` 與 ``next_after_seq``（下次可用的游標位置）。
    """
    if after_seq is not None:
        effective = after_seq
    else:
        # 釘選牆要看整房的釘選；游標只服務一般增量讀取
        effective = 0 if pinned_only else state().last_seq(room_id)
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
    指派若帶 ``assigned_name``，表示指派者已幫你取好房內名稱，
    加入該房間時 Hub 會以它命名（優先於你自己的 preferred_name）。
    回傳另含 ``your_session_key``——想請人指派工作給你時，把這把 key 告訴對方。
    """
    data = hub().request(
        "GET", "/api/assignments", params=_presence_params()
    )
    data["your_session_key"] = SESSION_KEY
    return data


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


# ---------- 向人類提問 ----------


@mcp.tool()
@_guard
def chatroom_ask_human(
    room_id: str,
    question: str,
    options: list[str] | None = None,
    target_name: str = "",
    timeout: float = 300.0,
    allow_free_text: bool = True,
) -> dict:
    """在聊天室裡向指定的人類提問，並等待回答。

    **房裡有人類時，這是問問題的首選方式**，優先於在自己的 session 裡問。
    理由很實際：多個 agent 各自在自己的 session 裡問，同一個人會被同一個問題
    問好幾遍，而且他的回答只有其中一個 agent 看得到。問在這裡，答案留在房裡，
    其他 agent 查得到（見 ``chatroom_questions``）。

    問題**不會**進入公開訊息流，只出現在指定那個人的介面上——所以要問誰必須
    明確。房裡只有一位人類時可以省略 ``target_name``；有多位時省略會被要求指定，
    因為「誰該回答」不是 Hub 該替人猜的事。

    ``options`` 給選項時對方可以直接點選，比讓他打字快得多；``allow_free_text``
    決定他能不能不選你給的選項而自己寫。至少要有其中一種，否則這題無法回答。

    這個呼叫會**阻塞**到對方回答或 ``timeout`` 秒（預設 5 分鐘）。回傳：

    - ``answered: true`` 帶 ``answer`` 與 ``answer_kind``（option / free_text）
    - ``answered: false`` 且 ``reason`` 為：
      - ``skipped``——對方明確選擇不在這裡回答。**改回你原本的方式問他**，
        不要再用這個工具問同一件事
      - ``timeout``——他沒看到。問題仍然留著，他晚點回答時你用
        ``chatroom_read_answer`` 拿得到；不要因為逾時就重問一次

    人沒空或不在時不要卡著等——把 timeout 設短一點，拿不到答案就先做你能做的。
    """
    payload: dict[str, Any] = {
        "prompt": question,
        "options": [{"label": o} for o in (options or [])],
        "allow_free_text": allow_free_text,
    }
    if target_name:
        payload["target_participant_id"] = _participant_id_by_name(room_id, target_name)
    created = _room_request(
        room_id, "POST", f"/api/rooms/{room_id}/questions", json=payload
    )
    qid = created["id"]
    # Hub 單次 long-poll 上限 55 秒，較長的等待靠連續掛起累積
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return {
                "answered": False, "reason": "timeout", "question_id": qid,
                "target_name": created.get("target_name"),
                "hint": "問題仍然留著。對方晚點回答的話，用 chatroom_read_answer"
                        f"（question_id={qid}）取得，不必重問。",
            }
        data = hub().request(
            "GET", f"/api/questions/{qid}",
            params={"wait": min(remaining, 50.0)},
            timeout=min(remaining, 50.0) + 10.0,
        )
        q = data["question"]
        if q["status"] == "answered":
            return {"answered": True, "answer": q["answer"],
                    "answer_kind": q["answer_kind"], "question_id": qid,
                    "target_name": created.get("target_name")}
        if q["status"] == "skipped":
            return {
                "answered": False, "reason": "skipped", "question_id": qid,
                "target_name": created.get("target_name"),
                "hint": "對方選擇不在聊天室回答，請改用你原本的方式問他，"
                        "不要再用這個工具問同一件事。",
            }


@mcp.tool()
@_guard
def chatroom_read_answer(question_id: str) -> dict:
    """讀取某個問題目前的狀態與答案（不等待）。

    ``chatroom_ask_human`` 逾時後用這個回頭取——對方晚一點回答仍然算數，
    逾時只代表「當下沒等到」，不代表問題作廢。
    """
    data = hub().request("GET", f"/api/questions/{question_id}")
    return {"question": data["question"]}


@mcp.tool()
@_guard
def chatroom_questions(room_id: str, pending_only: bool = True) -> dict:
    """列出這個房間問過人類的問題（含答案）。

    **發問前先看這裡**：別人可能已經問過同一件事，答案就在上面；也可能正有一題
    掛在同一個人身上還沒回，這時再丟一題過去只是在洗版。這正是這套機制要消除的
    重複發問。
    """
    params = {"status": "pending"} if pending_only else None
    data = hub().request(
        "GET", f"/api/rooms/{room_id}/questions", params=params
    )
    return {"questions": data["questions"]}


def main() -> None:
    # token 缺席時每次呼叫才報 401 會讓人誤以為 Hub 或指派壞了——啟動就把話說清楚
    if not os.environ.get("CHATROOM_TOKEN"):
        print(
            "[chatroom-mcp] CHATROOM_TOKEN 未設定：若 Hub 有啟用 token，"
            "所有工具呼叫都會被拒絕。請在啟動 agent 前於 shell 設定該環境變數。",
            file=sys.stderr,
        )
    mcp.run()


if __name__ == "__main__":
    main()
