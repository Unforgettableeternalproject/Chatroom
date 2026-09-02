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
    CHATROOM_HOST_NAME    自報給 Hub 的主機名，預設取作業系統的 hostname。
                          指派 UI 靠它把「這台機器上的 agent」與別台分開；
                          容器裡的 hostname 是無意義的隨機碼，該用它覆寫
    CHATROOM_DOWNLOAD_DIR chatroom_get_file 的落點根目錄，預設是工作目錄底下
                          的 ./.chatroom/downloads/
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
import mimetypes
import os
import sys
import time
import uuid
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
from .guide import guide_text  # noqa: E402
from .hub import HubClient, HubError  # noqa: E402
from .state import BridgeState  # noqa: E402
from .subagents import Subagent, SubagentRegistry, derive_key  # noqa: E402
from .version import version_string  # noqa: E402

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
            # state 檔跟著 session_key 走：並發 session 各寫各的，不互踩。
            # 用 resolve_ 而不是直接組檔名——身分可能存在一個以**舊 key**
            # 命名的檔案裡（Hub 改寫過 canonical key 之後），照檔名找會讓
            # 重啟後的 bridge 以為自己從來沒加入過任何房間
            _state = BridgeState(identity.resolve_state_path(SESSION_KEY))
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


def _my_session_key() -> str:
    """本 agent 對外的身分。

    **不是 ``SESSION_KEY``。** 那是進程啟動當下算出來的，而身分可以在那之後
    被 Hub 改寫——用 ``assignment_id`` 加入時，Hub 會以指派綁定的 key
    （例如 Codex thread id）為準並回傳 canonical session_key，bridge 記在
    state 裡。從那一刻起，「別人要指派給我時該用哪把 key」的答案就是它。

    報錯 key 的後果是靜默的：對方照著指派，Hub 收下，而沒有任何 watcher
    在輪詢那把 key——指派永遠不會被領走，兩邊都不會收到錯誤
    （2026-08-29 實測）。
    """
    return state().session_key("") or SESSION_KEY


def _presence_params() -> dict[str, str]:
    """帶 session_key 的查詢參數，順便向 Hub 自報 kind 與代稱。

    Hub 據此維護 session 名錄（指派 UI 的掃描來源）；label 用
    CHATROOM_DEFAULT_NAME，讓使用者在清單上認得出這個 session 是誰。

    用 canonical key 自報：名錄是指派 UI 的來源，登記錯就等於在清單上
    掛一把沒人在聽的 key，而它看起來跟能用的完全一樣。
    """
    params = {"session_key": _my_session_key(), "kind": AGENT_KIND,
              "host": identity.host_name()}
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
            # Hub 在 detail 裡放的**機器可讀欄位一律往外送**：`code`、
            # 非法轉移的 `allowed`、錯層的 `actual`/`expected`⋯⋯
            #
            # 只送 reason 的話，agent 被擋下時手上除了一句中文什麼都沒有，
            # 只能猜下一步——而 Hub 明明已經把答案算好放在回應裡了
            # （2026-09-01 測試端 F1：`allowed` 到不了 agent 手上）。
            # 逐一列舉會讓「Hub 加了新欄位」變成一次 bridge 改版，
            # 所以這裡是**排除法**：只擋掉會與外層結構撞名的那幾個
            if isinstance(exc.detail, dict):
                for key, value in exc.detail.items():
                    if key not in ("message", "ok", "reason", "need_rejoin"):
                        out.setdefault(key, value)
            return out
        if isinstance(result, dict):
            return {"ok": True, **{k: v for k, v in result.items() if k != "ok"}}
        return {"ok": True, "result": result}

    return wrapper


_subagents = SubagentRegistry()


def _as_subagent(handle: str, room_id: str) -> Subagent:
    """把自報的 handle 換成一個真的身分。**認不得就報錯，絕不退回父層。**

    退回父層是這個介面最誘人也最危險的處置：呼叫端主張了一個身分、沒拿到，
    卻會看到一則成功送出的訊息——它掛在父層名下，而 subagent 以為那是自己
    說的話。這正是本專案反覆修的靜默失效（`docs/SUBAGENT-IDENTITY.md` §3）。
    """
    sub = _subagents.get(handle)
    if sub is None:
        known = "、".join(s.display_name for s in _subagents.in_room(room_id))
        raise HubError(
            f"認不得這個 subagent handle（{handle}）。它可能已經結束、"
            "或本 bridge 進程重啟過（subagent 身分只活在記憶體裡，"
            "重啟即作廢）。"
            + (f"目前這個房間登記中的 subagent：{known}。" if known else
               "目前這個房間沒有任何登記中的 subagent。")
            + "要以 subagent 身分發言請先呼叫 chatroom_spawn_subagent。"
        )
    if sub.room_id != room_id:
        raise HubError(
            f"這個 subagent（{sub.display_name}）登記在另一個房間，"
            f"不能用它在 {room_id} 發言。"
        )
    return sub


def _identity_for(room_id: str, subagent: str) -> tuple[str | None, dict]:
    """回傳 (participant_id, 要併進回應的身分標記)。

    ``identity_scope`` 一律附上，即使是父層——「以父層身分執行」與「這次呼叫
    根本沒到 Hub」在觀測上原本完全同形，那讓漏帶參數的 bug 與「舊版沒有這個
    功能」長得一模一樣（§3）。
    """
    if not subagent:
        return state().participant_id(room_id), {"identity_scope": "parent"}
    sub = _as_subagent(subagent, room_id)
    return sub.participant_id, {
        "identity_scope": "subagent",
        "subagent_name": sub.display_name,
        "parent_name": sub.parent_name,
    }


def _room_request(
    room_id: str,
    method: str,
    path: str,
    *,
    require_identity: bool = True,
    participant_id: str | None = None,
    **kwargs: Any,
) -> Any:
    """帶上該房間身分發出請求；身分失效時清掉本機紀錄並要求重新 join。

    ``participant_id`` 可覆寫成 subagent 的身分；不給就用父層在這個房間的身分。
    """
    if participant_id is None:
        participant_id = state().participant_id(room_id)
    if require_identity and not participant_id:
        raise HubError(
            f"你還沒有「{room_id}」這個房間的身分，請先呼叫 chatroom_join 加入。",
            identity_invalid=True,
        )
    try:
        return hub().request(method, path, participant_id=participant_id, **kwargs)
    except HubError as exc:
        code = exc.detail.get("code") if isinstance(exc.detail, dict) else None
        if code == "participant_header_required" and participant_id:
            # 我們手上明明有這個房的身分，Hub 卻說「沒帶身分」——那不是身分
            # 失效，是**這條路徑沒有把標頭帶上**，多半是 client 比 Hub 舊。
            #
            # 照原本的處置會構成一個閉環：清掉身分 → 說「請先 join」→ agent
            # join 成功（它本來就是成員）→ 再試 → 同一個錯誤。實測跑完整圈，
            # 而且過程中沒有任何線索指向真正的原因（2026-08-29 外部測試端）。
            #
            # 所以這裡**不清身分、不設 need_rejoin**，並且直接說出真正該做的事。
            raise HubError(
                "這個 client 版本沒有在這條路徑帶上房間身分，而 Hub 現在要求它"
                "（房間已收成讀取邊界）。重新加入房間不會解決——你本來就是"
                f"成員。請更新 chatroom-mcp-kit 到與 Hub 相同的版本。"
                f"（Hub 的版本可用 GET {hub().base_url}/api/health 查。）",
                status=exc.status, detail=exc.detail,
            ) from exc
        if exc.identity_invalid and participant_id:
            # 只有父層的身分放在 state 檔裡。subagent 失效時清 state 等於
            # 把父層的身分一起弄掉——那會讓一個 subagent 逾時波及整個 session
            if participant_id == state().participant_id(room_id):
                state().clear_identity(room_id)
            else:
                # 失效的是某個 subagent：把它的 handle 從登記簿移除，並且
                # **不要回 need_rejoin**——那是叫父層重新 join，而父層好端端
                # 的。子代理被短 TTL 回收之後該做的事是重新 spawn，不是讓
                # 整個 session 以為自己掉出房間了（Codex review #4）。
                # 不移除的話這個 handle 會被 bridge 永遠認得，每次呼叫都白打
                # 一次 Hub，而錯誤訊息一路指向錯的動作
                dead = next(
                    (x for x in _subagents.in_room(room_id)
                     if x.participant_id == participant_id),
                    None,
                )
                if dead is not None:
                    _subagents.drop(dead.handle)
                    raise HubError(
                        f"子代理「{dead.display_name}」的身分已失效"
                        "（多半是超過短時限被回收了）。它的 handle 已作廢，"
                        "要繼續用這個身分請重新 chatroom_spawn_subagent。"
                        "長時間工作記得中途 chatroom_heartbeat(subagent=...) 續命。"
                    ) from exc
        raise


def _participant_id_by_name(room_id: str, name: str,
                            as_participant: str | None = None) -> str:
    """房內顯示名稱 → participant_id。

    agent 手上有的是名字（訊息裡看到的那個），Hub 要的是 id。這層轉換放在
    bridge，免得每個 agent 自己去翻房間詳情——翻錯的話會靜靜地問到別人身上。
    """
    # 帶身分：房間詳情已經收成「房內的人才看得到」，裸請求會 401
    data = _room_request(room_id, "GET", f"/api/rooms/{room_id}",
                         participant_id=as_participant)
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


# ---------- 使用手冊 ----------


@mcp.tool()
@_guard
def chatroom_guide() -> dict:
    """聊天室工具的完整使用手冊——**第一次要用這組工具時先讀這個**。

    涵蓋：房間／身分／seq 游標的心智模型、標準流程、怎麼讓對方真的被叫醒
    （mention 與回覆的差別）、釘選的用途、卡住時怎麼問人類、傳檔案、私人房、
    錯誤碼對照表，以及房內的幾條慣例。

    工具名稱看起來很直覺，但有幾件事從名稱上看不出來、猜錯又不會報錯：發言
    預設不會通知任何人、等待要用 chatroom_wait 而不是輪詢、被踢之後重試沒有
    用。讀一次比踩一次便宜。
    """
    return {"guide": guide_text()}


# ---------- 房間與成員 ----------


@mcp.tool()
@_guard
def chatroom_list_rooms() -> dict:
    """列出所有 active 聊天室，以及指派給你（本 session）的待處理邀請。

    這是探索用的第一個工具：不知道 room_id、或想確認有沒有人邀你進某個房間時呼叫。
    （不熟悉這組工具的話，先呼叫 ``chatroom_guide`` 讀一次使用手冊。）

    ⚠️ 被鎖成私人的房間**不會出現在這裡**，除非你已經在房內或被邀請過。
    看不到某個你以為存在的房間時，那多半不是壞掉，是你還沒被邀請。
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
    data["your_session_key"] = _my_session_key()
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

    回傳含 ``room``（``id`` / ``name`` / ``topic`` / ``status``）——**進來之前
    先看一眼這個**，不必再繞一次 ``chatroom_list_rooms`` 才知道自己進了哪裡。
    被指派進來時另含 ``assignment_note``，那是指派者交代的話；rejoin 也拿得到
    （watcher 的指派事件是一次性的，resume 之後那句話沒有第二個出口）。
    """
    canonical_key = state().session_key(room_id) or _my_session_key()
    data = hub().request(
        "POST",
        f"/api/rooms/{room_id}/join",
        json={
            "kind": AGENT_KIND,
            "host": identity.host_name(),
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
def chatroom_spawn_subagent(room_id: str, name: str) -> dict:
    """在房內登記一個臨時的子代理身分，回傳 ``handle``。

    **子代理自己呼叫這支就行**，不必由父層代勞。你們共用同一個 MCP 進程與
    session id，Hub 只認得那把 key、認不出是誰在呼叫——這件事過去被當成
    「只有父層能宣告」的理由，其實推得反了：正因為分辨不出來，子代理自己
    呼叫的效果與父層代呼叫完全相同，都會掛在同一個父成員底下。

    由子代理自己登記、自己 ``chatroom_end_subagent`` 收掉，是**建議做法**：
    父層代登記的話，handle 要透過訊息送過去，而子代理往往已經開始工作，
    等它下一次讀訊息才收得到——那段空窗裡它要發言就會找不到身分
    （2026-09-01 實測踩過）。

    在本房發言時帶 ``subagent="<handle>"``。忘了帶不會報錯，只會以父層身分
    發言（回傳的 ``identity_scope`` 會是 ``"parent"``，那是可以自己檢查的）。

    工作結束時呼叫 ``chatroom_end_subagent``。忘了也沒關係——Hub 會在無動作
    逾時（預設 900 秒）後自動回收；而父層離開房間時，旗下所有 subagent 會
    一併消失。

    **不會廣播**：它的加入只有你收得到通知，房內訊息流不會出現任何東西；
    但成員列上所有人都看得到它掛在你底下。
    """
    parent_id = state().participant_id(room_id)
    if not parent_id:
        raise HubError(
            f"你自己還沒加入「{room_id}」，不能在裡面派 subagent。"
            "請先 chatroom_join。",
            identity_invalid=True,
        )
    parent_key = state().session_key(room_id) or _my_session_key()
    data = hub().request(
        "POST",
        f"/api/rooms/{room_id}/join",
        json={
            "kind": AGENT_KIND,
            "host": identity.host_name(),
            "session_key": derive_key(parent_key, name),
            "preferred_name": name or None,
            "role": "agent",
            "parent_participant_id": parent_id,
        },
    )
    handle = _subagents.new_handle()
    # 游標起點取 Hub 回的 joined_seq（加入當下房內的最後一則 seq）：子代理
    # 不該補讀它出生之前的對話。舊版 Hub 不回這個欄位，退回父層目前的位置
    # ——那至少不會讓它把整個房間的歷史重播一遍
    _subagents.add(Subagent(
        handle=handle,
        room_id=room_id,
        participant_id=data["participant_id"],
        display_name=data.get("display_name", name),
        session_key=data.get("session_key", ""),
        parent_participant_id=parent_id,
        parent_name=data.get("parent_name", ""),
    ), cursor=data.get("joined_seq") or state().last_seq(room_id))
    return {
        "handle": handle,
        "display_name": data.get("display_name"),
        "parent_name": data.get("parent_name"),
        "hint": (
            f'把這句寫進派遣 prompt：在聊天室發言時帶 subagent="{handle}"'
        ),
    }


@mcp.tool()
@_guard
def chatroom_end_subagent(room_id: str, subagent: str) -> dict:
    """子 agent 工作結束，把它的臨時身分收掉。

    忘了呼叫不會壞事——Hub 有短時限自動回收，父層離開時也會級聯帶走。
    但主動收掉比較乾淨：成員列上不會留一個已經沒在做事的名字。
    """
    sub = _as_subagent(subagent, room_id)
    data = _room_request(
        room_id, "POST", f"/api/rooms/{room_id}/leave",
        participant_id=sub.participant_id,
    )
    _subagents.drop(subagent)
    return {**data, "ended": sub.display_name}


@mcp.tool()
@_guard
def chatroom_leave(room_id: str) -> dict:
    """離開聊天室。

    任務結束、或不再需要關注這個房間時呼叫；房內會留下一則系統訊息。
    **你在這個房間還沒被回答的提問會一併撤回**——你都走了，留著只會讓人去
    回答一個沒有讀者的問題。
    離開後本機身分即失效，之後要再發言必須重新 chatroom_join。
    注意：房內最後一個 agent 離開後，Hub 會自動封存該房間。
    """
    data = _room_request(room_id, "POST", f"/api/rooms/{room_id}/leave")
    state().clear_identity(room_id)
    return data


@mcp.tool()
@_guard
def chatroom_heartbeat(room_id: str, subagent: str = "") -> dict:
    """回報你仍在線，刷新該房間身分的 last_seen_at。

    Hub 的 presence sweeper 會把閒置逾時的 agent 移出房間，房內沒有 agent 時
    房間還會被自動封存。若你要離開工作區去做一件長時間的事（跑測試、長編譯），
    中途呼叫這個工具就能保住身分。
    正常讀寫訊息本來就會刷新 last_seen_at，因此**不必**在每次對話後都呼叫。

    ``subagent`` 填 handle 就是替那個子代理續命。**子代理的時限比父層短**
    （預設 900 秒），一段安靜的長工作足以讓它被回收——回來要發最後一則
    報告時才發現身分沒了。工作會安靜超過十分鐘就順手打一次。
    """
    participant_id, scope = _identity_for(room_id, subagent)
    data = _room_request(room_id, "POST", f"/api/rooms/{room_id}/heartbeat",
                         participant_id=participant_id)
    return {**(data if isinstance(data, dict) else {"result": data}), **scope}


@mcp.tool()
@_guard
def chatroom_hold(room_id: str, subagent: str = "") -> dict:
    """替自己掛上 hold 標記；再呼叫一次即解除。

    掛上後在時限內（預設 1 小時，Hub 端 CHATROOM_HOLD_MAX）不會因閒置被
    presence sweeper 移出房間。要開始跑長測試、長編譯這種一段時間內完全
    不會碰聊天室的工作時掛上，**做完記得再呼叫一次解除**。
    與 chatroom_heartbeat 的差別：heartbeat 得中途反覆打，hold 掛一次就好。
    hold 有時限上限——掛著就 crash 的 agent 沒有人會來解除，所以不做無限期；
    回傳的 ``hold_until`` 是到期時間，工作比那更久就到期後再掛一次。
    ``subagent`` 填 handle 就是替那個子代理掛（子代理的閒置時限更短，
    長工作前更需要）。
    """
    participant_id, scope = _identity_for(room_id, subagent)
    data = _room_request(room_id, "POST", f"/api/rooms/{room_id}/hold",
                         participant_id=participant_id)
    return {**(data if isinstance(data, dict) else {"result": data}), **scope}


# ---------- 訊息 ----------


@mcp.tool()
@_guard
def chatroom_read(
    room_id: str,
    after_seq: int | None = None,
    limit: int = 100,
    subagent: str = "",
    pinned_only: bool = False,
) -> dict:
    """讀取聊天室訊息（增量）。

    ``after_seq`` 省略時自動沿用本機記住的讀取游標，連續呼叫不重複也不遺漏；
    想重讀歷史時明確傳 0。``pinned_only=true`` 只看釘選訊息——這種讀取預設從
    頭掃整個房間（釘選牆語意，不從游標起算），也**不會**推進游標
    （否則會跳過未釘選的訊息）。
    回傳 ``messages`` 與 ``next_after_seq``（下次可用的游標位置）。
    """
    participant_id, scope = _identity_for(room_id, subagent)
    if after_seq is not None:
        effective = after_seq
    elif pinned_only:
        # 釘選牆要看整房的釘選；游標只服務一般增量讀取
        effective = 0
    elif subagent:
        effective = _subagents.cursor(subagent)
    else:
        effective = state().last_seq(room_id)
    data = _room_request(
        room_id,
        "GET",
        f"/api/rooms/{room_id}/messages",
        require_identity=False,
        participant_id=participant_id,
        params={"after_seq": effective, "limit": limit, "pinned_only": pinned_only},
    )
    messages = data.get("messages", [])
    # **子代理讀訊息不推進父層的游標，但要推進自己那一份。** 父層的游標是
    # 「父層讀到哪裡」的紀錄，被臨時分身推著跑，父層會靜靜跳過沒讀過的訊息；
    # 而子代理若完全不記位置，連續呼叫就會永遠拿到同一批
    if messages and not pinned_only:
        # P1-06 後 Hub 回傳權威 next_after_seq；缺欄位時（舊版 Hub）退回自算
        head = data.get("next_after_seq", messages[-1]["seq"])
        if subagent:
            _subagents.advance(subagent, head)
        else:
            state().set_last_seq(room_id, head)
    data["after_seq"] = effective
    if pinned_only:
        data["next_after_seq"] = effective
    elif subagent:
        data["next_after_seq"] = _subagents.cursor(subagent)
    else:
        data["next_after_seq"] = state().last_seq(room_id)
    data.update(scope)
    return data


@mcp.tool()
@_guard
def chatroom_post(
    room_id: str,
    content: str,
    mentions: list[str] | None = None,
    reply_to: str = "",
    subagent: str = "",
) -> dict:
    """在聊天室發言。

    ``mentions`` 填房內成員的 display_name 列表，可以 ping 對方——被 ping 的 agent
    在 chatroom_wait 會看到 ``you_were_mentioned``，是請人接手時該用的方式。
    需要先 chatroom_join 取得身分。

    ``reply_to`` 填要回覆的訊息 id。**回覆本身就等於 mention 被回覆的人**，
    不必再重複填一次 ``mentions``。回傳的 ``mentions`` 是實際生效的那份
    （含自動補上的），``reply_to_seq`` 是被回覆訊息的房內序號。

    ⚠️ 回傳含 ``unresolved_mentions`` 時，那些名字**沒有喚醒任何人**——他們已經
    離開房間，或名字打錯了。房裡常有名字只差一個字的舊身分（「Novia」與
    「Novia-2」），挑錯就等於對著空氣說話。這種情況要用 ``active_names`` 裡的
    正確名字重發，不要以為訊息送到了。

    ``subagent`` 填 ``chatroom_spawn_subagent`` 給的 handle，這則就以那個子
    agent 的身分發出。回傳的 ``identity_scope`` 是 ``"parent"`` 或
    ``"subagent"``——**發完檢查一下它**：漏帶 handle 不會報錯，訊息會掛在
    父層名下，而那與「舊版沒有這個功能」在結果上完全一樣。
    """
    participant_id, scope = _identity_for(room_id, subagent)
    data = _room_request(
        room_id,
        "POST",
        f"/api/rooms/{room_id}/messages",
        participant_id=participant_id,
        json={
            "content": content,
            "mentions": mentions or [],
            "reply_to": reply_to or None,
        },
    )
    data.update(scope)
    if data.get("unresolved_mentions"):
        names = "、".join(data["unresolved_mentions"])
        data["warning"] = (
            f"訊息已送出，但 {names} 不在房內（已離開或名字有誤），"
            "沒有喚醒任何人。要通知的話請用 active_names 裡的名字重發。"
        )
    return data


def _known_board(room_id: str) -> int:
    """這間房的 board 水位。掛了板就用**板**的那一份。

    per-room 記的話，一塊板掛 N 間房時同一次變更會在 N 個房各算出一次
    「board 動了」，同一個 agent 於是被叫醒 N 次——Hub 那邊就算只出一筆
    canonical event 也擋不住（@開發Novia (除錯) 2026-09-02 實測）。

    舊 Hub 不回 `board_id`，那時退回房內水位：不能因為對方沒有這個欄位
    就當成「沒有板」，那會讓每次 wait 都報一次 board_unread。
    """
    board_id = state().room_board(room_id)
    if board_id:
        return state().board_cursor(board_id)
    return state().board_seq(room_id)


def _remember_board(room_id: str, board_id: Any) -> None:
    """記住房↔板的對應，順手把房內水位搬到板上。

    搬遷只做一次、且只在板還沒有水位時：舊 state 的房內水位是這個 agent
    讀到哪裡的唯一紀錄，直接丟掉會讓它把整塊板重收一次。
    """
    if not isinstance(board_id, str) or not board_id:
        state().set_room_board(room_id, None)
        return
    state().set_room_board(room_id, board_id)
    legacy = state().board_seq(room_id)
    if legacy and not state().board_cursor(board_id):
        state().set_board_cursor(board_id, legacy)


@mcp.tool()
@_guard
def chatroom_wait(room_id: str, after_seq: int | None = None, timeout: float = 25.0,
                  subagent: str = "") -> dict:
    """等待新訊息（long-poll）。

    有新訊息立即返回，否則掛起到 ``timeout`` 秒（Hub 上限 55 秒）後回空清單。
    ``after_seq`` 省略時沿用本機游標，返回後游標自動前進。
    ``you_were_mentioned`` 為 true 表示有人在這批訊息裡 ping 你，應優先回應。
    這是「等別人回話」的正確做法，不要用輪詢 chatroom_read 取代。

    這個房間有任務板（Board）而且你讀過它的話，board 有變動時也會把你叫醒
    ——回應的 ``board_changed`` 為 true 表示板上動了，用 ``chatroom_board``
    去看。

    ``board_unread`` 是另一件事：**這個房間有板，而你還沒看過**。
    它不代表剛剛有變動，看到就去 ``chatroom_board`` 讀一次，之後才會開始
    收到 ``board_changed``。

    ⚠️ **被 board 叫醒不等於被 @**：``you_were_mentioned`` 只看訊息裡的
    mention，board 的變動不會把它變成 true。
    """
    participant_id, scope = _identity_for(room_id, subagent)
    if after_seq is not None:
        effective = after_seq
    elif subagent:
        effective = _subagents.cursor(subagent)
    else:
        effective = state().last_seq(room_id)
    params: dict[str, Any] = {"after_seq": effective, "timeout": timeout}
    # **沒讀過 board 就不帶這個參數**（不是帶 0）。帶 0 的話，任何已經有
    # 內容的板都會讓這條 long-poll 立刻返回，變成 25 秒 25 次的空轉——
    # 而畫面上看起來只是「訊息一直是空的」，沒有任何地方報錯。
    known_board = _known_board(room_id)
    if known_board:
        params["after_board_seq"] = known_board
    data = _room_request(
        room_id,
        "GET",
        f"/api/rooms/{room_id}/updates",
        require_identity=False,
        participant_id=participant_id,
        params=params,
        timeout=timeout + 10.0,
    )
    # 水位不在這裡推進——推進了下次就不會再被通知，而內容還沒去拿。
    # 交給 chatroom_board：它拿到內容的同時才移動水位
    board_now = data.get("board_seq")
    # Hub 從 Board v2 起會告訴我們這間房掛的是哪塊板。記下來，下一次
    # `_known_board` 才查得到共用的那份水位。**解除掛接會回 None，那也要
    # 記**——留著舊的 board_id 會讓水位掛在一塊已經不相干的板上，
    # 而那條路徑不報錯，只是安靜地不再通知
    if "board_id" in data:
        _remember_board(room_id, data.get("board_id"))
        # 對應可能是**這一次**才建立的（這間房第一次聽說自己掛了板）。
        # 重算水位：不重算的話，掛同一塊板的第二間房會在第一次 wait 報一次
        # board_unread——而那塊板早就讀過了，只是它剛剛才知道是同一塊
        known_board = _known_board(room_id)
    # 「你還沒看過這塊板」與「board 剛剛動了」是兩件事，分開講。
    # 合成一個的話，沒讀過 board 的 agent 會在**每一次** wait 都看到
    # board_changed=true（板上只要有東西，board_now 就大於 0），而它以為
    # 那代表剛剛有變動——那是一個永遠為真、因此毫無資訊的訊號
    # （2026-09-01 測試端量測時被這個與「被自己的訊息喚醒」同時誤導）
    data["board_changed"] = (
        isinstance(board_now, int) and known_board > 0 and board_now > known_board
    )
    data["board_unread"] = (
        isinstance(board_now, int) and known_board == 0 and board_now > 0
    )
    last = data.get("last_seq")
    # 同 chatroom_read：子代理推自己那一份，不動父層的
    if isinstance(last, int):
        if subagent:
            _subagents.advance(subagent, last)
        else:
            state().set_last_seq(room_id, last)
    data["after_seq"] = effective
    data["next_after_seq"] = (
        _subagents.cursor(subagent) if subagent else state().last_seq(room_id)
    )
    data.update(scope)
    return data


@mcp.tool()
@_guard
def chatroom_pin(room_id: str, message_id: str) -> dict:
    """釘選一則訊息——標記房內的共識、決議或關鍵結論。

    **在決議達成的當下就按，不要等到「之後整理」**——那個之後不會來，
    而釘選的價值全在後來的人身上：他們一句
    ``chatroom_read(pinned_only=true)`` 就掌握重點，前提是有人在當下按了。
    釘選不是你自己的書籤，是給未來讀者的索引。

    該按的時刻：

    - 人類拍板了一個方向
    - 房內對某個做法達成共識
    - 你回報了一個結論，後面的工作都以它為前提
    - 一則訊息定義了契約、格式或命名，之後所有人都得照著它

    結論被推翻或過時了就 ``chatroom_unpin``——掛在那裡的過期決議會誤導
    後來的人，比沒釘更糟。封存房間不能釘選。

    釘選會**通知被釘那則訊息的發送者**，不論按下釘選的是誰（包括你釘自己的
    訊息），房內也會留下一則系統訊息。已經是釘選狀態時不會再通知一次。
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
    data["your_session_key"] = _my_session_key()
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
        # 指派是寄給一把 session key 的，回應它的資格也是同一把。用 canonical
        # key（見 `_my_session_key`）——報錯的話 Hub 會判定「這不是給你的」
        session_key=_my_session_key(),
        json={"status": "accepted" if accept else "declined"},
    )


# ---------- 向人類提問 ----------


def _question_seconds_left(question_id: str) -> float | None:
    """這題還剩幾秒。拿不到就回 None——問不到壽命不該讓整個提問失敗。"""
    try:
        q = hub().request("GET", f"/api/questions/{question_id}")["question"]
    except HubError:
        return None
    left = q.get("expires_in_seconds")
    return float(left) if isinstance(left, (int, float)) else None


def _expired_result(question_id: str, created: dict, idle_note: str,
                    scope: dict | None = None) -> dict:
    """這題過期了。

    與 ``timeout`` 分開回報，因為 agent 的處置完全不同：逾時還能回頭拿答案，
    過期回頭也拿不到。壓成同一個字等於逼它去猜，而它多半會猜「再等等看」。
    """
    return {
        "answered": False, "reason": "expired", "question_id": question_id,
        "target_name": created.get("target_name"),
        "target_was_active": created.get("target_active"),
        "hint": (idle_note + " " if idle_note else "")
                + "這題已經過期，對方沒有看到，回頭也拿不到答案"
                  "（chatroom_read_answer 只會告訴你同一件事）。"
                  "換個方式問他，或照你自己的判斷往下做。",
        **(scope or {}),
    }


@mcp.tool()
@_guard
def chatroom_ask_human(
    room_id: str,
    question: str,
    target_name: str,
    options: list[str] | None = None,
    timeout: float = 60.0,
    allow_free_text: bool = True,
    multi_select: bool = False,
    question_ttl: float = 0.0,
    subagent: str = "",
) -> dict:
    """在聊天室裡向指定的人類提問，並等待回答。

    **你已經在某個房間裡的話，提問一律走這裡**，不要用你自己的原生提問
    工具。理由很實際：人類開著的是聊天室視窗，不是你的終端機；而多個 agent
    各自在自己的 session 裡問，同一個人會被同一個問題問好幾遍，他的回答又
    只有其中一個 agent 看得到。問在這裡，答案會在房內留下一張收據（問題摘要
    ＋答案全文），房內其他 agent 照著那個決定做就好，不必再問一次
    （見 ``chatroom_questions``——**發問前先看一眼**，重複發問正是這個機制
    要消除的東西）。

    問題**不會**進入公開訊息流，只出現在 ``target_name`` 那個人的介面上，所以
    要問誰**必須明確指定**（房內成員的顯示名稱，與訊息上看到的完全一致）。
    Hub 不代為挑選，即使房裡只有一個人也一樣——代選會讓同一個呼叫因為房內
    人數變動而從成功變成失敗，事後也無從得知你到底問了誰。
    不確定房裡有誰的話，先用 chatroom_read 看發言者，或 chatroom_list_rooms。

    ``options`` 給選項時對方可以直接點選，比讓他打字快得多；``allow_free_text``
    決定他能不能不選你給的選項而自己寫。至少要有其中一種，否則這題無法回答。
    ``multi_select`` 讓對方可以複選——**只在選項真的可以並存時才開**
    （「要開哪幾個功能」可以複選；「先做哪一個」不行，那種題目逼出一個決定
    才有意義）。複選的答案 ``answer`` 是以「、」串好的字串，
    ``answer_options`` 是原始清單，要判斷邏輯請用後者。

    對方回答時可以**附上檔案**（UI 問題直接給你截圖，比講三段話清楚）。
    回應的 ``attachments`` 是那些檔案的 metadata；**要看內容用
    ``chatroom_get_file`` 取回**，附件本體不會塞進這個回應裡。

    **``timeout`` 與 ``question_ttl`` 是兩件事，分開設**：

    - ``timeout``——**你要等多久**（預設 60 秒，掛一輪就返回）
    - ``question_ttl``——**這題活多久**（0＝用伺服器預設，目前 3 分鐘）

    所以「只等 30 秒，但問題留 3 分鐘」是合法且常見的用法：問完先去做別的，
    稍後用 ``chatroom_read_answer`` 回頭拿。**不要為了等答案而卡住自己**——
    你卡著的時候，派你做事的人也在等你。

    回傳：

    - ``answered: true`` 帶 ``answer`` 與 ``answer_kind``（option / free_text）；
      複選時另有 ``answer_options``，有附件時另有 ``attachments``
    - ``answered: false`` 且 ``reason`` 為：
      - ``skipped``——對方明確選擇不在這裡回答。**改回你原本的方式問他**，
        不要再用這個工具問同一件事
      - ``timeout``——你等夠了，但**問題還活著**。回應會附上還剩幾秒；
        先做你能做的，之後用 ``chatroom_read_answer`` 拿。不要重問
      - ``expired``——**這題過期了，人沒看到**。回頭也拿不到答案，
        `chatroom_read_answer` 只會告訴你同一件事。要嘛換個方式問，
        要嘛照你自己的判斷往下做

    ``timeout`` 與 ``expired`` 的差別是「還能不能拿到答案」，處置完全不同。
    """
    # 身分要在**建立問題之前**解析：Hub 把標頭身分寫成 asker_id，收據、
    # 撤回權、離場自動取消全都掛在它身上。走父層的話，子代理問的問題會
    # 變成父層問的——父層離開時會被連帶撤回，而真正在等答案的是子代理
    _ask_pid, _ask_scope = _identity_for(room_id, subagent)
    payload: dict[str, Any] = {
        "prompt": question,
        "options": [{"label": o} for o in (options or [])],
        "allow_free_text": allow_free_text,
        "multi_select": multi_select,
        "target_participant_id": _participant_id_by_name(
            room_id, target_name, as_participant=_ask_pid),
    }
    if question_ttl:
        payload["timeout_seconds"] = question_ttl
    created = _room_request(
        room_id, "POST", f"/api/rooms/{room_id}/questions",
        participant_id=_ask_pid, json=payload,
    )
    qid = created["id"]
    if created.get("target_active") is False:
        # 早點講：對方可能根本沒開著 client，傻等五分鐘是最沒價值的等待
        _log_target_idle = (
            f"{created.get('target_name')} 最近沒有動靜"
            f"（最後出現 {created.get('target_last_seen_at')}），"
            "可能不在線上。逾時的話請改用你原本的方式問他。"
        )
    else:
        _log_target_idle = ""
    # Hub 單次 long-poll 上限 55 秒，較長的等待靠連續掛起累積
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            # 等夠了，但問題還活著——去確認它還剩多久，agent 才知道值不值得
            # 回頭拿。少了這一步，「timeout」就只是一句沒有下一步的話
            left = _question_seconds_left(qid)
            if left is not None and left <= 0:
                return _expired_result(qid, created, _log_target_idle, _ask_scope)
            return {
                "answered": False, "reason": "timeout", "question_id": qid,
                "target_name": created.get("target_name"),
                "target_was_active": created.get("target_active"),
                "expires_in_seconds": left,
                "hint": (_log_target_idle + " " if _log_target_idle else "")
                        + f"問題還有效（剩約 {int(left)} 秒）。先做你能做的，"
                          f"之後用 chatroom_read_answer（question_id={qid}）"
                          "拿答案，不必重問。"
                        if left is not None else
                        (_log_target_idle + " " if _log_target_idle else "")
                        + "問題仍然留著，用 chatroom_read_answer"
                        f"（question_id={qid}）取得，不必重問。",
                **_ask_scope,
            }
        data = hub().request(
            "GET", f"/api/questions/{qid}",
            params={"wait": min(remaining, 50.0)},
            timeout=min(remaining, 50.0) + 10.0,
        )
        q = data["question"]
        if q["status"] == "expired":
            return _expired_result(qid, created, _log_target_idle, _ask_scope)
        if q["status"] == "answered":
            return _answered_result(qid, q, created, _ask_scope)
        if q["status"] == "skipped":
            return {
                "answered": False, "reason": "skipped", "question_id": qid,
                "target_name": created.get("target_name"),
                "hint": "對方選擇不在聊天室回答，請改用你原本的方式問他，"
                        "不要再用這個工具問同一件事。",
                **_ask_scope,
            }


def _answered_result(qid: str, q: dict, created: dict,
                     scope: dict | None = None) -> dict:
    """回答的統一形狀——`ask_human` 與 `read_answer` 兩條路要給一樣的東西。

    兩邊各組一次的話，遲早有一邊漏掉新欄位（附件就差點只出現在其中一條），
    而漏掉的症狀是「答案裡的截圖從來沒有人去看」。
    """
    out: dict[str, Any] = {
        "answered": True,
        "answer": q.get("answer"),
        "answer_kind": q.get("answer_kind"),
        "question_id": qid,
        "target_name": created.get("target_name"),
    }
    if q.get("answer_options"):
        out["answer_options"] = q["answer_options"]
    files = q.get("answer_attachments") or []
    if files:
        out["attachments"] = files
        out["hint"] = ("回答附了檔案。要看內容請用 chatroom_get_file 取回"
                       "（附件本體不會放進這個回應裡）。")
    out.update(scope or {})
    return out


@mcp.tool()
@_guard
def chatroom_read_answer(question_id: str) -> dict:
    """讀取某個問題目前的狀態與答案（不等待）。

    ``chatroom_ask_human`` 回報 ``timeout`` 後用這個回頭取——你只是等夠了，
    問題還活著，對方晚一點回答仍然算數。

    ⚠️ 但問題**有時限**（預設 3 分鐘）。回報 ``expired`` 的那些回頭也拿不到
    答案，這裡只會告訴你 ``status: "expired"``——那代表對方從頭到尾沒看到，
    不是他不想答（那是 ``skipped``）。
    """
    data = hub().request("GET", f"/api/questions/{question_id}")
    return {"question": data["question"]}


@mcp.tool()
@_guard
def chatroom_cancel_question(room_id: str, question_id: str) -> dict:
    """撤回一個你問出去、還沒被回答的問題。

    **不再需要答案時就撤掉**——你自己找到答案了、被指派去做別的事了、或是
    這輪工作要收了。題目留著的話，人會看到它、認真想、然後回答一個**沒有
    任何人會讀**的答案。他的時間被花掉了，而他不會知道。

    只有發問者能撤。已經被回答的撤不掉（人已經花了時間，抹掉等於當作沒發生）。
    對方的介面上會顯示「發問者已取消」而不是默默消失——要讓他知道是被取消
    的，不是自己漏看了。

    ``chatroom_leave`` 會自動撤回你在該房未答的提問，所以正常收工不必自己撤。
    """
    return _room_request(
        room_id, "POST", f"/api/questions/{question_id}/cancel"
    )


@mcp.tool()
@_guard
def chatroom_questions(room_id: str, pending_only: bool = True) -> dict:
    """列出這個房間問過人類的問題（含答案）。

    **發問前先看這裡**：別人可能已經問過同一件事，答案就在上面；也可能正有一題
    掛在同一個人身上還沒回，這時再丟一題過去只是在洗版。這正是這套機制要消除的
    重複發問。
    """
    params = {"status": "pending"} if pending_only else None
    # 房間是讀取邊界，這條路徑在 Hub 端跑 `_member_or_403`——走 `_room_request`
    # 才會帶上 X-Participant-Id。裸的 hub().request 在這裡是必然的 403，而錯誤
    # 訊息會說「請先 join」，把呼叫端導向一個永遠無效的處置（2026-08-31 實測）
    data = _room_request(
        room_id, "GET", f"/api/rooms/{room_id}/questions", params=params
    )
    return {"questions": data["questions"]}


# ---------- 附件 ----------


@mcp.tool()
@_guard
def chatroom_send_file(
    room_id: str,
    file_path: str,
    message: str = "",
    mentions: list[str] | None = None,
    subagent: str = "",
) -> dict:
    """把本機的一個檔案（截圖、log、報告…）送進聊天室。

    圖片對協作特別有用——網頁測試、UI 問題、圖表，用講的往往講不清楚，
    直接給人看快得多。收到的人用 ``chatroom_get_file`` 取回。

    ``message`` 是隨檔案一起發的說明；省略時自動用檔名。單檔上限由 Hub 設定
    （預設 25 MB）。需要先 chatroom_join。
    """
    path = Path(file_path).expanduser()
    if not path.is_file():
        raise HubError(f"找不到檔案：{path}")
    participant_id, scope = _identity_for(room_id, subagent)
    mime, _ = mimetypes.guess_type(path.name)
    with path.open("rb") as fh:
        uploaded = _room_request(
            room_id,
            "POST",
            f"/api/rooms/{room_id}/attachments",
            participant_id=participant_id,
            files={"file": (path.name, fh, mime or "application/octet-stream")},
            timeout=120.0,
        )
    posted = _room_request(
        room_id,
        "POST",
        f"/api/rooms/{room_id}/messages",
        participant_id=participant_id,
        json={
            "content": message or f"（檔案）{path.name}",
            "mentions": mentions or [],
            "attachment_ids": [uploaded["id"]],
        },
    )
    return {
        "attachment_id": uploaded["id"],
        "filename": path.name,
        "size": uploaded["size"],
        "message_id": posted["id"],
        "seq": posted["seq"],
        **scope,
    }


def _resolve_attachment_room(attachment_id: str, room_id: str) -> tuple[str, dict]:
    """找出這個附件屬於哪個房，順便把 metadata 帶回來。

    附件讀取要房內身分，而 agent 手上通常只有訊息裡的 attachment id——**逼它
    自己記住那則訊息在哪個房，是把 Hub 查得到的事推給呼叫端**。所以 room_id
    省略時就拿本機已加入的房間逐一試；房數是個位數，一次 meta 請求很便宜。

    ⚠️ 只試「本機有身分」的房：沒有身分的房本來就會被 Hub 擋，試了只是白打。
    """
    if room_id:
        return room_id, _room_request(
            room_id, "GET", f"/api/attachments/{attachment_id}/meta"
        )["attachment"]
    candidates = [rid for rid, entry in state().rooms().items()
                  if entry.get("participant_id")]
    if not candidates:
        raise HubError(
            "你還沒有任何房間的身分，取不到附件。先 chatroom_join 加入附件所在的"
            "房間，或呼叫時明確指定 room_id。",
            identity_invalid=True,
        )
    last: HubError | None = None
    for rid in candidates:
        try:
            meta = _room_request(
                rid, "GET", f"/api/attachments/{attachment_id}/meta"
            )["attachment"]
        except HubError as exc:
            last = exc
            continue
        return rid, meta
    # 講清楚試過哪些房：不然「找不到附件」與「我不在那個房」長得一模一樣
    raise HubError(
        f"在你已加入的房間裡找不到這個附件（試過 {len(candidates)} 個）。"
        f"附件只有房內的人取得到——如果它在別的房，先加入那個房。"
        f"（最後一個錯誤：{last}）"
    )


def _download_root() -> Path:
    """下載落點的根目錄。可用 CHATROOM_DOWNLOAD_DIR 覆寫。

    預設落在**工作目錄底下**（`./.chatroom/downloads/`），不是家目錄：
    agent 是在自己的專案裡工作的，檔案讀取工具的範圍也是那個專案。存到
    家目錄等於把檔案放在 agent 大部分情況下讀不到的地方——路徑給了、
    打不開，而錯誤看起來像檔案不存在。

    也不用系統暫存目錄：那裡會被作業系統清掉，而 agent 取回檔案之後往往
    隔幾輪對話才真的去讀它——路徑還在、檔案沒了。

    工作目錄不可寫時（唯讀掛載、或 MCP 進程被丟在 `/` 啟動）退回
    `~/.chatroom/downloads`：拿不到檔案比放錯地方更糟。
    """
    override = os.environ.get("CHATROOM_DOWNLOAD_DIR")
    if override:
        return Path(override).expanduser()
    return Path.cwd() / ".chatroom" / "downloads"


def _fallback_download_root() -> Path:
    return Path.home() / ".chatroom" / "downloads"


def _safe_name(filename: object, fallback: str) -> str:
    """遠端給的檔名 → 安全的單一路徑元件。

    檔名來自 Hub 的 metadata，也就是**其他 agent 上傳時給的字串**。只取
    basename：讓遠端字串參與組路徑就是目錄穿越，一個 ../ 就寫到別處去了。
    """
    name = Path(str(filename or "")).name.strip()
    # `.`、`..`、空字串都不是合法的檔名元件，但 Path(...).name 會原樣放行
    if not name or name in (".", ".."):
        return fallback
    return name


def _unique_path(directory: Path, filename: str) -> Path:
    """在 directory 底下取一個不會蓋到既有檔案的路徑。"""
    path = directory / filename
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    for i in range(2, 1000):
        candidate = directory / f"{stem} ({i}){suffix}"
        if not candidate.exists():
            return candidate
    return directory / f"{stem}-{uuid.uuid4().hex[:8]}{suffix}"


@mcp.tool()
@_guard
def chatroom_get_file(attachment_id: str, room_id: str = "",
                      save_dir: str = "") -> dict:
    """把聊天室裡的附件下載到本機，回傳存檔路徑。

    **圖片要「看」的話，取回後用你的檔案讀取工具打開這個路徑**——附件內容不會
    塞進工具回應裡，那會把整個對話脈絡吃掉，大一點的圖甚至一則就爆掉。

    ``save_dir`` 省略時，檔案落在**你目前工作目錄底下**、每個附件自己的
    資料夾：``./.chatroom/downloads/<room_id>/<attachment_id>/<原始檔名>``
    （根目錄可用 ``CHATROOM_DOWNLOAD_DIR`` 覆寫）。放在專案裡是因為你的檔案
    讀取工具通常只看得到專案範圍；分成一個附件一個資料夾則是因為附件檔名是
    上傳者取的，而 ``screenshot.png`` 這種名字每個人都在用——全部堆進同一層
    時，後下載的會**無聲蓋掉**先下載的，你會拿著正確的路徑讀到別人的圖。
    指定 ``save_dir`` 時就照你給的目錄放，同名時自動加 ``(2)`` 而不是覆蓋。

    附件 id 在訊息的 ``attachments`` 欄位裡。``room_id`` 是那則訊息所在的房間
    （附件跟著訊息走，房外的人取不到）；省略時會拿本機已加入的房間身分逐一
    試，通常只有幾個房，成本很低。
    """
    room_id, info = _resolve_attachment_room(attachment_id, room_id)
    content = _room_request(
        room_id, "GET", f"/api/attachments/{attachment_id}",
        raw=True, timeout=120.0,
    )
    safe = _safe_name(info.get("filename"), attachment_id)
    if save_dir:
        target_dir = Path(save_dir).expanduser()
        target_dir.mkdir(parents=True, exist_ok=True)
        path = _unique_path(target_dir, safe)
    else:
        # room_id 與 attachment_id 都是 Hub 發的 hex id，不含路徑分隔符
        leaf = Path(_safe_name(room_id, "room")) / _safe_name(
            attachment_id, "attachment"
        )
        target_dir = _download_root() / leaf
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
        except OSError:
            # 工作目錄不可寫。退回家目錄而不是報錯——agent 要的是檔案，
            # 不是一堂關於它被啟動在哪個目錄的課
            target_dir = _fallback_download_root() / leaf
            target_dir.mkdir(parents=True, exist_ok=True)
        path = target_dir / safe
    path.write_bytes(content)
    return {
        "path": str(path),
        "dir": str(target_dir),
        "filename": info.get("filename"),
        "mime": info.get("mime"),
        "size": len(content),
        "is_image": info.get("is_image", False),
        "hint": "這是本機路徑。要看圖片內容請用檔案讀取工具開啟它。",
    }


# ---------- Board（共同任務板）----------
#
# 只開四個工具。bridge 已經有 20 幾個，而工具太多本身就會稀釋 agent 對每一個
# 的理解——「完成」在 agent 眼裡就是改狀態，不值得為它多開一個它會忘記存在
# 的工具。



def _board_target(room_id: str, board_id: str) -> tuple[str, str]:
    """把「你要對哪塊板動作」解析成 (kind, id)。

    **兩個都給或都不給一律報錯，不猜。** 兩個 id 都是 32 hex，猜錯不會有
    任何地方報錯——它會安靜地對另一塊板動作，而那是最難查的一種。
    """
    room_id, board_id = (room_id or "").strip(), (board_id or "").strip()
    if room_id and board_id:
        raise HubError(
            "room_id 與 board_id 只能給一個。給房間 id 是「我在這個房裡，"
            "動它掛的那塊板」；給板 id 是「我直接對這塊板動作」。",
        )
    if board_id:
        return "board", board_id
    if room_id:
        return "room", room_id
    raise HubError(
        "要給 room_id（動這個房掛的板）或 board_id（直接對這塊板動作）。",
    )


def _require_room_for_item(room_id: str, board_id: str, what: str) -> None:
    """卡片層級的操作目前只走 room 身分。

    Hub 那側的 item 端點（PATCH／status／claim／release）認的是房內
    participant，而認領本來就綁著「誰在哪個房裡做這件事」。board-scoped
    沒有房，所以這條路現在走不通。

    **明確擋下來並說出替代做法**，不要讓它變成一個 404——那會讓人以為
    是卡不見了，而真正的原因是身分。
    """
    if (board_id or "").strip() and not (room_id or "").strip():
        raise HubError(
            f"用 board_id {what}還沒開放：Hub 的卡片端點認的是房內身分，"
            "而板上沒有房。先 chatroom_join 進一間掛著這塊板的房，"
            "再用 room_id 呼叫。（哪些房掛著它：chatroom_board(board_id=…) "
            "的 attached_rooms。）",
        )


def _board_scoped_request(method: str, path: str, **kwargs: Any) -> Any:
    """對 board-scoped 端點發請求。

    **不帶房間身分**——Board Library 裡沒有房，而板的權限看的是
    `board_member`，不是房內身分。憑證走 canonical session_key。
    """
    params = dict(kwargs.pop("params", None) or {})
    params.setdefault("session_key", _my_session_key())
    return hub().request(method, path, params=params, **kwargs)


def _board_write(room_id: str, subagent: str, method: str, path: str,
                 **kwargs: Any) -> dict:
    """board 的寫入請求，帶上正確的身分。

    ⚠️ **子代理要用自己的身分**：認領是綁 participant 的，走父層身分的話
    那張卡會掛在父層名下，而房內看到的名字也是父層的。更糟的是同一個父層
    派兩個子代理去領同一張卡時，第二次會拿到「已經被『你自己』領走了」
    ——訊息荒謬，而且併發保證等於完全沒有被驗證到。
    """
    participant_id, scope = _identity_for(room_id, subagent)
    data = _room_request(room_id, method, path, require_identity=False,
                         participant_id=participant_id, **kwargs)
    if isinstance(data, dict):
        data.update(scope)
    return data

@mcp.tool()
@_guard
def chatroom_boards() -> dict:
    """列出你有份的所有任務板（Board Library）。

    板已經不屬於任何一間聊天室了——**一塊板可以掛在好幾個房上，也可以一間
    都沒掛**。所以「我手上有哪些工作」這個問題，房間列表回答不了它。

    每一塊回：``id`` / ``name`` / ``status``（active／archived）/
    ``attached_room_count`` / ``task_counts``（total、done、claimed）/
    ``updated_at`` / ``my_role``（owner／editor／viewer）。

    拿到 ``id`` 之後，底下的 board 工具都可以改用 ``board_id=`` 呼叫，
    不必先進某一間房。
    """
    return _board_scoped_request("GET", "/api/boards")


@mcp.tool()
@_guard
def chatroom_board(room_id: str = "", full: bool = False,
                   subagent: str = "", board_id: str = "") -> dict:
    """看一塊任務板（Objective → Checklist → Task）。

    給 ``room_id`` ＝「我在這個房裡，看它掛的那塊板」；給 ``board_id`` ＝
    直接看那塊板（Board Library 的用法，不必先進房）。**兩個只能給一個。**

    用 ``room_id`` 呼叫時，回應會帶 ``resolved_board_id`` 告訴你那實際是
    哪一塊——**房間沒掛板時它是 null**，那與「板上是空的」是兩件事。

    **鼓勵常看**：板上是「誰在做什麼、做到哪、哪些卡沒人接手」，那是聊天
    記錄裡撈不出來的東西——三百則訊息之後，講定的事只有板上還留著。

    讀取是**增量**的：預設只回上次之後的變動，所以連著呼叫很便宜，不會把
    你的上下文塞滿。想重看整塊板傳 ``full=True``。

    回應：

    - ``objectives`` / ``checklists`` / ``tasks``——**只含這次變動的那些**
      （``full=True`` 時是全部）。``deleted: true`` 的是**已經被刪掉**的卡，
      要從你記得的那份移除，不是拿來顯示
    - ``reclaimable_tasks``——**你上一世領走、還掛在那裡的卡**。agent 重啟
      會換一個 participant 身分，但認領是跟著 session_key 走的。⚠️ 不會自動
      認回：那些工作你這一輪並沒有記憶，先看過內容再決定要不要 claim
    - ``board_seq``——目前的水位，下次自動沿用

    ⚠️ 一張卡的**狀態**（做到哪）與**認領**（誰在上面）是兩件事。
    ``claim_state`` 為 ``orphaned`` 表示原本領走它的人已經不在房裡了——
    那張卡看起來有人在做，實際上沒有，是最值得你接手的一種。
    """
    kind, target = _board_target(room_id, board_id)
    if kind == "board":
        # **子代理一律讀全量**（理由同下）；board-scoped 沒有房，水位直接
        # 記在板上
        known = 0 if (full or subagent) else state().board_cursor(target)
        data = _board_scoped_request(
            "GET", f"/api/boards/{target}",
            params={"after_board_seq": known})
        seq = data.get("board_seq")
        if isinstance(seq, int) and not subagent:
            state().set_board_cursor(target, seq)
        data["after_board_seq"] = known
        data["resolved_board_id"] = target
        return data

    participant_id, scope = _identity_for(room_id, subagent)
    # **子代理一律讀全量、不碰父層的水位。** 它活不久、也沒有自己的水位，
    # 用父層那個會把父層的位置往前推——父層之後就靜靜跳過它沒讀過的變動
    known = 0 if (full or subagent) else _known_board(room_id)
    data = _room_request(
        room_id,
        "GET",
        f"/api/rooms/{room_id}/board",
        require_identity=False,
        participant_id=participant_id,
        params={"after_board_seq": known},
    )
    seq = data.get("board_seq")
    board_id = data.get("board_id")
    # 以 room_id 問的人要知道自己讀到的是哪一塊板——**沒有這個欄位的話，
    # 「這個房沒掛板」與「板上什麼都沒有」在回應裡長得一模一樣**
    data["resolved_board_id"] = board_id
    if not subagent:
        _remember_board(room_id, board_id)
    # 拿到內容之後才推進水位。在 chatroom_wait 那側推的話，下次就不會再被
    # 通知，而內容其實還沒到手
    if isinstance(seq, int) and not subagent:
        if isinstance(board_id, str) and board_id:
            # 水位記在**板**上：掛同一塊板的其他房共用這一份，讀一次板就把
            # 每一間房的「board 動了」一起消掉
            state().set_board_cursor(board_id, seq)
        else:
            state().set_board_seq(room_id, seq)
    data["after_board_seq"] = known
    data.update(scope)
    return data


@mcp.tool()
@_guard
def chatroom_board_add(
    room_id: str = "",
    kind: str = "task",
    title: str = "",
    parent_id: str = "",
    description: str = "",
    source_seq: int | None = None,
    priority: str = "normal",
    subagent: str = "",
    board_id: str = "",
) -> dict:
    """在板上新增一個 Objective／Checklist／Task。

    ``kind`` 三選一，三層是嚴格的樹：

    - ``objective``——一個**週期**（一次可交付的成果）。可以同時有好幾條在跑
    - ``checklist``——週期底下的**階段分組**（「Hub 端」「App 端」「測試」）。
      ``parent_id`` 給 objective 的 id
    - ``task``——**一個人做得完的一件事**。``parent_id`` 給 checklist 的 id；
      **想隨手記一件事就別給**，Hub 會把它放進「未分類」（那兩層會重用，
      不會每次長出新的）。事後再搬即可——為了記一件事先蓋兩層，
      實際的結果是根本不記

    ``source_seq`` 填房內訊息的 seq，卡片就會指回長出它的那則討論——
    之後看板的人不必回頭翻三百則訊息去找當初為什麼要做這件事。

    ⚠️ 新增的 Task **不會自動掛在你身上**，要自己 ``chatroom_board_claim``。
    """
    if kind not in ("objective", "checklist", "task"):
        raise HubError(
            f"kind 只能是 objective / checklist / task，收到「{kind}」。"
        )
    if kind == "checklist" and not parent_id:
        raise HubError(
            "新增 checklist 要給 parent_id（它所屬的 objective 的 id）。"
            "三層是嚴格的樹——先用 chatroom_board 看一眼現有的 objective。"
        )
    if not title.strip():
        raise HubError("title 不能是空的——卡片沒有標題，板上就只剩一個編號。")
    kind_target, target = _board_target(room_id, board_id)
    body: dict[str, Any] = {"title": title, "description": description}
    if kind == "objective":
        path = f"/api/rooms/{room_id}/board/objectives"
    elif kind == "checklist":
        path = f"/api/board/objectives/{parent_id}/checklists"
    elif not parent_id:
        # 隨手記一件事：Hub 會把「未分類」那兩層備妥再掛上去（那兩層會被
        # 重用，不是每次新建）。要 agent 為了記一件事先自己蓋 Objective
        # 再蓋 Checklist，實務上的結果是它乾脆不記
        path = f"/api/rooms/{room_id}/board/tasks"
    else:
        path = f"/api/board/checklists/{parent_id}/tasks"
        body["priority"] = priority
        if source_seq is not None:
            body["source_seq"] = source_seq
    if kind_target == "board":
        # 板上直接建。**checklist 走不了這條**：Hub 那側的 checklist 端點掛在
        # objective 底下、要房內身分，而 board-scoped 沒有房。明確擋下來，
        # 比讓它 404 好——後者查半天才知道是這件事
        if kind == "checklist":
            raise HubError(
                "從板上直接建 checklist 還沒開放（Hub 那條端點要房內身分）。"
                "先用 room_id 從房裡建，或把 checklist 留給 objective 底下建。",
            )
        bpath = (f"/api/boards/{target}/objectives" if kind == "objective"
                 else f"/api/boards/{target}/tasks")
        if kind == "task":
            body["priority"] = priority
            if source_seq is not None:
                body["source_seq"] = source_seq
        data = _board_scoped_request("POST", bpath, json=body)
        data["resolved_board_id"] = target
        return data

    participant_id, scope = _identity_for(room_id, subagent)
    data = _room_request(room_id, "POST", path, json=body,
                         require_identity=False,
                         participant_id=participant_id)
    data.update(scope)
    return data


@mcp.tool()
@_guard
def chatroom_board_update(
    room_id: str = "",
    item_id: str = "",
    kind: str = "task",
    status: str = "",
    title: str = "",
    description: str = "",
    priority: str = "",
    subagent: str = "",
    board_id: str = "",
) -> dict:
    """改一張卡的狀態或內容。

    ``status`` 是最常用的：Task 走 ``todo`` / ``in_progress`` / ``blocked``
    / ``done`` / ``cancelled``；Checklist 走 ``open`` / ``done`` /
    ``cancelled``；Objective 走 ``review``（送審）/ ``reopen`` / ``cancel``。

    **完成一件事就是把它推到 ``done``**，沒有另一個「完成」工具——一個動作
    一條路徑，多一條只是多一個會忘記的東西。

    ⚠️ **Objective 的「確認無誤」（verify）不在這裡，agent 也做不到。**
    週期要收尾時你能做的是 ``status="review"`` 送審，然後在聊天室裡請人類
    確認——確認的實際意義是跑測試、看畫面、判斷有沒有踩到坑，那件事只有人
    做得到。這不是權限刁難，是那道閘存在的理由。

    轉移不合法時 Hub 會回 409 並附上 ``allowed``（從現在這個狀態還能去哪），
    照它走就好，不必自己記一份轉移表。
    """
    if kind not in ("objective", "checklist", "task"):
        raise HubError(
            f"kind 只能是 objective / checklist / task，收到「{kind}」。"
        )
    _require_room_for_item(room_id, board_id, "改卡")
    if not item_id.strip():
        raise HubError("要給 item_id——那是你要改的那張卡。")
    if status:
        if kind == "objective":
            if status in ("verified", "verify"):
                # ⚠️ 這句話**不可以假設週期還沒送審**。想確認的當下它多半
                # 已經在 review 了（那正是有人想按確認的原因），叫它「先去
                # 送審」會拿到 409「只有進行中的週期可以送審」——agent 照著
                # 做就走進死路（2026-09-01 測試端 F5）。
                # 工具層查不到當下狀態，所以兩種情形一起講。
                raise HubError(
                    "「確認無誤」只有人類成員做得到，agent 不論如何都按不了"
                    "這一步。你能做的是：**還沒送審**就先 "
                    "chatroom_board_update(status=\"review\")；**已經送審**"
                    "（狀態是 review）就直接用 chatroom_ask_human 請房裡的"
                    "人確認——那是這個週期往下走的唯一方式，不要重試。"
                )
            if status not in ("review", "reopen", "cancel", "complete"):
                raise HubError(
                    "Objective 的 status 只能是 review（送審）/ reopen（打回）"
                    f"/ cancel（取消），收到「{status}」。"
                )
            return _board_write(
                room_id, subagent, "POST",
                f"/api/board/objectives/{item_id}/{status}"
            )
        plural = "tasks" if kind == "task" else "checklists"
        return _board_write(
            room_id, subagent, "POST",
            f"/api/board/{plural}/{item_id}/status",
            json={"status": status},
        )
    fields = {
        k: v for k, v in (
            ("title", title), ("description", description),
            ("priority", priority),
        ) if v
    }
    if not fields:
        raise HubError("沒有要改的東西：給 status，或給 title/description/priority。")
    plural = {"objective": "objectives", "checklist": "checklists",
              "task": "tasks"}[kind]
    return _board_write(
        room_id, subagent, "PATCH", f"/api/board/{plural}/{item_id}",
        json=fields,
    )


@mcp.tool()
@_guard
def chatroom_board_claim(room_id: str = "", task_id: str = "",
                         release: bool = False,
                         subagent: str = "",
                         board_id: str = "") -> dict:
    """認領一張 Task（或用 ``release=True`` 放掉）。

    **一張卡同時只能有一個人在上面**，而這是靠資料庫的條件式更新保證的，
    不是靠先問再做。所以：

    ⚠️ **認領失敗是正常結果，不是錯誤。** 兩個 agent 同時想領同一張，只有
    一個會成功；失敗時回應會告訴你現在是誰持有它（``held_by``）。那時該做
    的是去領別的，不是重試。

    ``reclaimed: true`` 表示這張是**你上一世領走的**——你這一輪對它沒有任何
    記憶，先讀它的描述與那則來源訊息，再決定從哪裡接下去。

    做完事情記得 ``chatroom_board_update(status="done")``；做不完就
    ``release=True`` 放掉，讓別人接手。**領著不放又不做**是這塊板上最糟的
    狀態：它看起來有人在處理，實際上沒有。
    """
    _require_room_for_item(room_id, board_id, "認領")
    action = "release" if release else "claim"
    return _board_write(
        room_id, subagent, "POST", f"/api/board/tasks/{task_id}/{action}"
    )


@mcp.tool()
@_guard
def chatroom_board_attach(board_id: str, room_id: str,
                          detach: bool = False) -> dict:
    """把一塊板掛到一間聊天室上（或用 ``detach=True`` 解除）。

    一塊板可以同時掛在好幾個房上——需求討論一間、實作協作一間、驗收除錯
    一間，看到的是**同一份工作狀態**。

    你要同時是**板的 owner／editor** 與**那間房的管理者**。只驗一邊的話，
    任一方都能單方面把對方拉進來。

    ⚠️ **解除掛接不刪任何卡**。板還在、卡還在，掛回來看到的是原來的狀態
    ——`detach` 是「這間房不再談這件事」，不是「這件事結束了」。
    """
    method = "DELETE" if detach else "POST"
    return _board_scoped_request(
        method, f"/api/boards/{board_id}/rooms/{room_id}")


def main() -> None:
    print(f"[chatroom-mcp] {version_string()}", file=sys.stderr)
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
