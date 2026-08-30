"""Chatroom Hub — FastAPI 應用本體。

Phase 0 涵蓋：房間 CRUD、加入/退出（唯一命名）、訊息發布/讀取、
釘選、heartbeat、long-poll 通知、指派、presence sweeper 與自動封存。
WebSocket 通道留待 Phase 1（UI 開工前）。
"""

import asyncio
import contextlib
import hashlib
import json
import logging
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path

from fastapi import (
    Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile,
    WebSocket, WebSocketDisconnect,
)
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_validator

from .config import Config
from .db import open_db
from .events import RoomEvents
from .logging_setup import setup_file_logging, token_hint
from .naming import generate_name
from .version import APP_VERSION, build_info, version_string


logger = logging.getLogger("chatroom")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _uid() -> str:
    return uuid.uuid4().hex


def _err(status: int, code: str, message: str) -> HTTPException:
    """機器可讀錯誤：detail 為 {"code", "message"}，code 是穩定契約，
    message 僅供人讀——client 不得對 message 做字串比對。"""
    return HTTPException(status, {"code": code, "message": message})


# ---------- 說話方式 ----------

# agent 的預設回話方式是「任務回報」：長篇 Markdown、程式碼整段貼、每個步驟
# 都交代一次。那在工單系統裡是對的，在聊天室裡多半是噪音——房裡還有別人在
# 講話，一則回覆佔掉整個畫面，其他人就別想聊了。
#
# 風格文字**寫在 server**，不是寫在 client 或 bridge：房間的說話方式是房間的
# 屬性，所有進來的 agent 必須拿到同一份定義。放在 bridge 就會變成「不同版本
# 的 bridge 對同一個房間有不同的理解」。
#
# 每個風格兩份文字：`prompt` 在加入房間時給一次（完整指示），`hint` 每次讀
# 訊息時附帶（一行，防止長對話裡風格慢慢飄回預設）。
ROOM_STYLES: dict[str, dict[str, str]] = {
    "verbose": {
        "label": "詳細",
        "prompt": (
            "本房的說話方式是【詳細】：完整交付。任務結果、程式碼、結構化的"
            " Markdown 報告都可以直接貼在房裡，篇幅不設限——這個房間同時是"
            "工作紀錄，寫下來的東西之後有人會回頭翻。"
        ),
        "hint": "本房風格：詳細（完整交付，篇幅不限）",
    },
    "concise": {
        "label": "精確",
        "prompt": (
            "本房的說話方式是【精確】：用最少的篇幅把話講完。結論先講，理由"
            "一句話；要點用短列表。**不要貼程式碼，不要交付長篇 Markdown"
            "文件**——細節先留在你手上，需要的人會開口要，那時再給。"
            "把「我做了什麼」壓成一行，把「結果是什麼」講清楚。"
        ),
        "hint": "本房風格：精確（重點為主，不貼程式碼與長篇文件）",
    },
    "casual": {
        "label": "親和",
        "prompt": (
            "本房的說話方式是【親和】：像人一樣說話。用自然的句子，不要標題、"
            "不要條列、不要進度回報的格式。不主動交代工作階段與任務狀態——"
            "有結果就講結果，有問題就問，該閒聊就閒聊。這裡是聊天室，"
            "不是工單系統。"
        ),
        "hint": "本房風格：親和（自然語言，像人一樣說話）",
    },
}

# 自訂風格的指示由建立者自己寫，Hub 不加工——加了就會變成兩個人的話疊在
# 一起，而使用者無從得知自己的那句被改成什麼樣子
CUSTOM_STYLE = "custom"
STYLE_PATTERN = "^(verbose|concise|casual|custom)$"


def _style_texts(style: str, instructions: str) -> tuple[str, str]:
    """(完整指示, 一行提醒)。未知的 style 一律退回 verbose。

    退回而不是報錯：舊 client 或手動改過的資料庫都可能塞進沒見過的值，
    而說話方式出錯不該讓整個房間讀不出來。
    """
    if style == CUSTOM_STYLE:
        text = instructions.strip()
        if text:
            # 壓成一行：自訂指示可能是多行的，提醒只有一行的位置
            head = " ".join(text.split())[:60]
            return text, f"本房風格：自訂——{head}"
        # custom 但沒有內容：建立時已擋掉，這裡是資料層面的縱深防禦
        style = "verbose"
    spec = ROOM_STYLES.get(style) or ROOM_STYLES["verbose"]
    return spec["prompt"], spec["hint"]


# ---------- 請求模型 ----------

class RoomCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    topic: str = ""
    # 建立者的 session（管理員身分：可移出成員、可改鎖定狀態）。
    # 省略時房間沒有管理員
    session_key: str | None = Field(default=None, max_length=128)
    # public / private。private 的房不出現在別人的房間列表，也不能自行加入
    visibility: str = Field(default="public", pattern="^(public|private)$")
    # 房內 agent 的說話方式。custom 時 style_instructions 必填
    style: str = Field(default="verbose", pattern=STYLE_PATTERN)
    style_instructions: str = Field(default="", max_length=2000)


class RoomVisibility(BaseModel):
    visibility: str = Field(pattern="^(public|private)$")


class RoomStyle(BaseModel):
    style: str = Field(pattern=STYLE_PATTERN)
    style_instructions: str = Field(default="", max_length=2000)


class JoinRequest(BaseModel):
    kind: str = Field(pattern="^(claude|codex|human|other)$")
    session_key: str = Field(min_length=1, max_length=128)
    # App 可把 Codex thread id 當成指派目標；MCP bridge 本身拿不到 thread id，
    # 因此以 assignment_id 兌換 Hub 已知的 canonical session_key。
    assignment_id: str | None = Field(default=None, max_length=128)
    preferred_name: str | None = None
    role: str = Field(default="agent", pattern="^(agent|human)$")
    # 自報的主機名，指派 UI 用來分辨「這是我這台機器上的 agent 嗎」
    host: str | None = Field(default=None, max_length=200)


class MessagePost(BaseModel):
    content: str = Field(min_length=1, max_length=32768)
    mentions: list[str] = []
    reply_to: str | None = None

    @field_validator("reply_to", mode="before")
    @classmethod
    def _blank_reply_is_none(cls, v):
        """空字串等同「沒有回覆對象」。

        直接打 REST 的 client 很自然會送 ""，而它會被當成一個不存在的訊息 id
        擋下來。我們自己的 bridge 有處理，但隧道的用途正是讓別人的 client
        連進來，那些不會用我們的 bridge。
        """
        return v or None
    # 先上傳拿到 id，再隨訊息帶上——分兩步是為了讓上傳可以重試而不會重複發言
    attachment_ids: list[str] = Field(default_factory=list, max_length=10)


class AssignmentCreate(BaseModel):
    target_session_key: str
    note: str = ""
    # 指派者預先取的名字：agent 依此指派加入房間時，優先於自取名與名字池
    assigned_name: str = Field(default="", max_length=32)


class TokenCreate(BaseModel):
    # 這張發給誰。純標註，用來認出「這張還要不要留著」
    label: str = Field(default="", max_length=64)


class AssignmentResolve(BaseModel):
    status: str = Field(pattern="^(accepted|declined)$")


class QuestionOption(BaseModel):
    label: str = Field(min_length=1, max_length=80)
    description: str = Field(default="", max_length=280)


class QuestionCreate(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    options: list[QuestionOption] = Field(default_factory=list, max_length=8)
    # **必填**。曾經允許「房內只有一個人類時自動代選」，但那讓同一個請求會
    # 因為房內人數變動而從成功變成失敗，而且事後無法證明發問方到底選了誰。
    # 少打一個參數的便利，不值得換掉行為的穩定性。
    target_participant_id: str = Field(min_length=1)
    allow_free_text: bool = True
    # 這題的有效秒數；0＝用伺服器預設。上限刻意只有一小時——發問方是卡在
    # 那裡等的，能等更久的事情本來就不該用「提問」這個機制
    timeout_seconds: float = Field(default=0, ge=0, le=3600)


class QuestionAnswer(BaseModel):
    # skip = 人類明確選擇不在這裡回答（改回 session 內問），與逾時是兩回事
    kind: str = Field(pattern="^(option|free_text|skip)$")
    answer: str = Field(default="", max_length=4000)


# ---------- 應用工廠 ----------

def create_app(config: Config | None = None) -> FastAPI:
    cfg = config or Config()
    logger.setLevel(cfg.log_level.upper())
    log_dir = cfg.log_dir or str(Path(cfg.db_path).resolve().parent / "logs")
    log_path = setup_file_logging(
        logger, log_dir,
        max_bytes=cfg.log_max_bytes, backup_count=cfg.log_backup_count,
    )

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI):
        # 第一則就是版本：日誌從哪裡開始看，都要能立刻回答「這是哪一份程式碼」
        info = build_info()
        logger.info(
            "Hub 啟動 %s", version_string(),
            extra={"event": "startup", "version": info["version"],
                   "commit": info["commit"], "built_at": info["built_at"],
                   "version_source": info["source"], "db": cfg.db_path,
                   "log_file": str(log_path) if log_path else ""},
        )
        if info["source"] == "unknown":
            # 這正是這次事故的形狀：手上跑的是哪一份程式碼，沒有人答得出來
            logger.warning(
                "這份 Hub 沒有版本資訊（既非打包產物也不在 git 工作樹裡）"
                "——出事時無法對照是哪一份程式碼",
                extra={"event": "version_unknown"},
            )
        if not cfg.api_token:
            logger.warning("未設定 CHATROOM_TOKEN，API 驗證停用——僅限本機開發使用",
                           extra={"event": "auth_disabled"})
        app.state.db = await open_db(cfg.db_path)
        sweeper = asyncio.create_task(_sweeper())
        app.state.sweeper_task = sweeper
        try:
            yield
        finally:
            sweeper.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await sweeper
            await app.state.db.close()

    app = FastAPI(title="Chatroom Hub", version=APP_VERSION, lifespan=lifespan)
    events = RoomEvents()

    def _bearer(authorization: str | None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            return ""
        return authorization[len("Bearer "):]

    async def require_auth(
        request: Request, authorization: str | None = Header(default=None)
    ) -> None:
        """驗 token，並把「是誰」記在 request.state 上。

        兩種來源：`.env` 的主 token（主持人自己的鑰匙，不可撤銷），以及
        access_token 表裡發給別人的那些（可標註、可單獨撤銷）。

        兩者權限相同——token 是信任邊界，房間不是。多 token 買到的是可撤銷
        與可追溯，不是隔離；要真隔離請開不同的 Hub 實例。
        """
        request.state.is_root_token = False
        request.state.token_label = ""
        # 這次請求用的是哪張發出去的 token（主 token 與開放模式留空字串）。
        # 踢出要連著撤銷它——只封 session_key 擋不住任何人，那把鑰匙是被踢者
        # 自己在本機產的，換一把就是全新的人
        request.state.access_token = ""
        if not cfg.api_token:
            # 未設 token＝完全開放（本機開發）。這時人人都是主持人，否則
            # 連發邀請都做不到
            request.state.is_root_token = True
            return
        token = _bearer(authorization)
        if token and token == cfg.api_token:
            request.state.is_root_token = True
            return
        row = None
        if token:
            request.state.access_token = token
            row = await (
                await app.state.db.execute(
                    "SELECT * FROM access_token WHERE token=? AND revoked_at IS NULL",
                    (token,),
                )
            ).fetchone()
        if row is None:
            logger.warning(
                "token 驗證失敗", extra={
                    "event": "auth_failed", "path": request.url.path,
                    # 只記前 8 碼：日誌會被複製、貼上、附進 issue，
                    # 每次都是一份新的外洩機會
                    "token_hint": token_hint(token),
                    "ip": _client_ip(request),
                },
            )
            raise _err(401, "invalid_token", "token 無效或未提供")
        request.state.token_label = row["label"]
        # 最後使用時間讓主持人看得出哪張還在用、哪張可以收掉
        await app.state.db.execute(
            "UPDATE access_token SET last_used_at=? WHERE token=?", (_now(), token)
        )
        await app.state.db.commit()

    def require_root(request: Request) -> None:
        """發放與撤銷 token 限主 token。

        任何 token 都能再發 token 的話，撤銷就形同虛設——被撤掉的人早就自己
        發了一張新的。發放權留在 `.env` 那把（也就是主持人這台）。
        """
        if not getattr(request.state, "is_root_token", False):
            raise _err(403, "root_token_required",
                       "只有 Hub 主持人（.env 的主 token）能發放或撤銷邀請")

    def _client_ip(request: Request) -> str | None:
        """來源位址。**僅供辨識顯示，不可用於任何授權判斷。**

        `X-Forwarded-For` 是客戶端可自行填寫的標頭；隧道後面要靠它才拿得到
        真實來源（直接看 peer 只會看到 cloudflared 的本機位址），但也因此
        它可以被偽造。拿它當「這是誰」的提示可以，拿它當門禁不行。
        """
        cf = request.headers.get("cf-connecting-ip")
        if cf:
            return cf.strip()
        xff = request.headers.get("x-forwarded-for")
        if xff:
            return xff.split(",")[0].strip()
        return request.client.host if request.client else None

    # ---------- 內部工具 ----------

    async def _room_or_404(room_id: str, allow_archived: bool = False):
        db = app.state.db
        row = await (await db.execute("SELECT * FROM room WHERE id=?", (room_id,))).fetchone()
        if row is None:
            raise _err(404, "room_not_found", "找不到這個聊天室")
        if not allow_archived and row["status"] != "active":
            raise _err(409, "room_archived", "聊天室已封存，唯讀")
        return row

    def _room_public(row) -> dict:
        """room row → 對外回應；管理員 session key 不外流。"""
        d = dict(row)
        d.pop("creator_session_key", None)
        return d

    async def _participant(participant_id: str | None, room_id: str | None = None):
        if not participant_id:
            raise _err(401, "participant_header_required",
                       "此端點需要 X-Participant-Id 標頭")
        db = app.state.db
        row = await (
            await db.execute(
                "SELECT * FROM participant WHERE id=? AND status='active'", (participant_id,)
            )
        ).fetchone()
        if row is None:
            # 為什麼失效，呼叫端的處置完全不同：閒置移除該重新加入，被踢則
            # 不該再回來。壓成同一個 code 會逼 agent 用中文訊息猜，也讓
            # watcher 無法決定要不要收掉這個房的監看。
            gone = await (
                await db.execute(
                    "SELECT status FROM participant WHERE id=?", (participant_id,)
                )
            ).fetchone()
            status = gone["status"] if gone else None
            if status == "kicked":
                raise _err(403, "participant_kicked",
                           "你已被管理員移出這個聊天室，無法再加入")
            if status == "removed":
                raise _err(403, "participant_removed_idle",
                           "你因閒置逾時被移出聊天室，需要時可重新加入")
            if status == "left":
                raise _err(403, "participant_left",
                           "這個身分已離開聊天室，需要時可重新加入")
            raise _err(403, "participant_not_active",
                       "身分已失效（可能因閒置被移出房間），請重新加入")
        # participant 是房間層級身分，不可跨房使用
        if room_id is not None and row["room_id"] != room_id:
            raise _err(403, "participant_wrong_room", "此身分不屬於這個房間")
        await db.execute(
            "UPDATE participant SET last_seen_at=? WHERE id=?", (_now(), participant_id)
        )
        await db.commit()
        return row

    async def _creator_or_member(
        room, participant_id: str | None, session_key: str | None
    ):
        """房主視角的門檻：建立者本人，或房內成員。

        建房到 join 之間有一段空窗（指派 UI 正開在那個空窗上——「邀請別人
        進來」本來就發生在自己還沒進去的時候），要求先成為成員會讓房主連
        自己的房都打不開。`you_are_admin` 本來就用同一個 header 判定。

        被踢的人不會是建立者（kick 擋掉了踢自己），所以這不是繞道。
        """
        if room["creator_session_key"] and session_key == room["creator_session_key"]:
            return None
        return await _member_or_403(room["id"], participant_id)

    async def _member_or_403(room_id: str, participant_id: str | None):
        """讀取房內內容的門檻：必須**曾經**是這個房的成員，且不是被踢出的。

        沒有這道門檻時，「踢出」在使用者眼中就是沒有生效——被踢的人照樣讀得到
        全部歷史與即時訊息，只是不能發言。房間必須是真的邊界，不能只是名冊。

        ⚠️ 刻意**不**要求 `status='active'`：自己離開、或閒置逾時被移出的人，
        回頭讀當時的歷史是正當的（封存房唯讀瀏覽本來就這樣用）。要求 active
        會讓「離開房間」變成「銷毀自己的紀錄」，那不是離開的意思。
        **被踢是唯一的例外**——那是一個「不要再看到這裡」的人為決定。

        也刻意不更新 `last_seen_at`：讀取不是活躍證明，拿它當心跳會讓掛著
        長輪詢的 agent 永遠掃不掉。即時通道（updates）另外要求 active 身分。
        """
        if not participant_id:
            # 「你沒說你是誰」與「你不是成員」必須是兩句不同的話——它們把人
            # 導向完全不同的處置（前者去找身分怎麼掉的，後者去找誰把我踢了）。
            # 舊 client 沒帶標頭時最容易在這裡被誤導成「我被踢了嗎」
            raise _err(401, "participant_header_required",
                       "請求沒有帶 X-Participant-Id。這不是「你不是成員」，"
                       "而是「還不知道你是誰」——先加入房間取得身分再讀。")
        row = await (
            await app.state.db.execute(
                "SELECT status FROM participant WHERE id=? AND room_id=?",
                (participant_id, room_id),
            )
        ).fetchone()
        if row is None:
            # 不分「查無此身分」與「身分屬於別的房間」：對非成員來說，
            # 這個房間的存在與否本來就不該從錯誤碼推得出來
            raise _err(403, "not_a_member",
                       "你不是這個聊天室的成員（這個身分不屬於這個房間）")
        if row["status"] == "kicked":
            raise _err(403, "participant_kicked",
                       "你已被管理員移出這個聊天室，看不到房內的內容")
        return row

    async def _invited_to_private(room, session_key: str | None) -> bool:
        """這個 session 能不能看到／進入這個私人房。

        三種算數：建立者本人、房內既有紀錄（含已離開的——他當時在場過，
        房間不該從他的列表上憑空消失）、以及一筆還算數的指派（邀請）。

        ⚠️ 這是**可見性**，不是安全邊界。拿得到 token 的人本來就能對任何房
        建立指派（見 `POST /api/rooms/{id}/assignments`，它只驗 token）——
        token 才是這個系統的信任邊界，房間不是（與 access_token 的設計一致）。
        私人房擋掉的是「在列表上被逛到」與「不請自來」，不是有心人。
        真要隔離請開不同的 Hub 實例。
        """
        if not session_key:
            return False
        if room["creator_session_key"] and session_key == room["creator_session_key"]:
            return True
        db = app.state.db
        # 被踢的人不算成員——那是一個「不要再看到這裡」的決定。要回來得靠
        # 踢出**之後**新建的指派，那筆會在下面的 EXISTS 命中
        member = await (
            await db.execute(
                "SELECT 1 FROM participant WHERE room_id=? AND session_key=?"
                " AND status!='kicked'",
                (room["id"], session_key),
            )
        ).fetchone()
        if member is not None:
            return True
        invited = await (
            await db.execute(
                "SELECT 1 FROM assignment WHERE room_id=? AND target_session_key=?"
                " AND status IN ('pending','accepted')",
                (room["id"], session_key),
            )
        ).fetchone()
        return invited is not None

    async def _admin_or_403(room, participant_id: str | None,
                            session_key: str | None, what: str = "鎖定狀態"):
        """管理員（建立者）門檻。

        接受兩種自報方式：X-Session-Key（建立者可能還沒加入自己的房，
        指派 UI 正開在那個空窗上），或 X-Participant-Id 反查 session_key。

        ``what`` 只進錯誤訊息——同一道門現在管兩件事（鎖定狀態、說話方式），
        訊息寫死其中一件會讓另一件的失敗看起來像叫錯了端點。
        """
        creator = room["creator_session_key"]
        if not creator:
            raise _err(409, "room_has_no_admin",
                       "這個聊天室沒有建立者紀錄（建立時沒帶 session_key），"
                       f"沒有人可以變更它的{what}")
        if session_key and session_key == creator:
            return
        if participant_id:
            me = await (
                await app.state.db.execute(
                    "SELECT session_key FROM participant WHERE id=? AND room_id=?",
                    (participant_id, room["id"]),
                )
            ).fetchone()
            if me is not None and me["session_key"] == creator:
                return
        raise _err(403, "not_admin", f"只有聊天室建立者可以變更{what}")

    async def _touch_session(
        session_key: str,
        kind: str | None = None,
        label: str | None = None,
        ip: str | None = None,
        host: str | None = None,
    ) -> None:
        """upsert session 名錄。kind/label 只在帶到非空值時覆寫既有紀錄——
        舊版 bridge 不帶這兩個參數，不能因此把已知的 kind 洗回 other。"""
        db = app.state.db
        if not kind:
            # 舊版 bridge 不自報 kind，但 identity.py 生成的 key 天生帶
            # kind 前綴（claude-xxx / codex-xxx）——從前綴推斷，之後
            # caller 真的自報時仍會覆寫
            prefix = session_key.split("-", 1)[0]
            if prefix in ("claude", "codex", "human"):
                kind = prefix
        now = _now()
        await db.execute(
            "INSERT INTO session (session_key, kind, label, first_seen_at,"
            " last_seen_at, last_ip, host) VALUES (?,?,?,?,?,?,?)"
            " ON CONFLICT(session_key) DO UPDATE SET"
            " last_seen_at=excluded.last_seen_at,"
            " kind=CASE WHEN excluded.kind!='' THEN excluded.kind ELSE session.kind END,"
            " label=CASE WHEN excluded.label!='' THEN excluded.label ELSE session.label END,"
            " last_ip=COALESCE(excluded.last_ip, session.last_ip),"
            # host 同 kind/label：只在帶到非空值時覆寫。舊 bridge 不自報，
            # 不能因為它呼叫了一次就把已知的主機名洗掉
            " host=CASE WHEN excluded.host!='' THEN excluded.host ELSE session.host END",
            (session_key, kind or "", label or "", now, now, ip, host or ""),
        )
        # 首次插入時 kind 空字串會落庫，補回預設值
        await db.execute(
            "UPDATE session SET kind='other' WHERE session_key=? AND kind=''",
            (session_key,),
        )
        await db.commit()

    async def _post_message(
        room_id: str,
        sender_id: str | None,
        content: str,
        kind: str = "chat",
        mentions: list[str] | None = None,
        reply_to: str | None = None,
        system_event: str = "",
    ) -> dict:
        db = app.state.db
        effective = list(mentions or [])
        reply_to_seq = None
        # reply 目標必須存在且屬於同一房間，否則會把他房的內容洩進本房時間軸
        if reply_to is not None:
            target = await (
                await db.execute(
                    "SELECT m.seq, m.sender_id, p.display_name FROM message m"
                    " LEFT JOIN participant p ON p.id=m.sender_id"
                    " WHERE m.id=? AND m.room_id=?",
                    (reply_to, room_id),
                )
            ).fetchone()
            if target is None:
                raise _err(422, "reply_target_not_found",
                           "reply_to 指向的訊息不存在或不在這個房間")
            reply_to_seq = target["seq"]
            # 回覆＝mention 對方。「我回你了」與「我 @ 你」在使用者眼裡是同
            # 一件事，但在此之前只有後者會喚醒對方——回覆送出去、看起來成功、
            # 對方永遠不知道。要求發話方自己補一個 mentions 參數才會通知，
            # 等於把一個沒人會記得的步驟塞進最常用的路徑。
            #
            # 自己回自己不算：那只會把 agent 自己叫醒一次。
            # 回系統訊息也不算：沒有發送者可以通知。
            if target["sender_id"] and target["sender_id"] != sender_id:
                name = target["display_name"]
                if name and name not in effective:
                    effective.append(name)
        # 以 room.next_seq 發放房內序號（單一寫入者事務內遞增，避免併發重號）
        cur = await db.execute(
            "UPDATE room SET next_seq = next_seq + 1 WHERE id=? RETURNING next_seq - 1",
            (room_id,),
        )
        seq = (await cur.fetchone())[0]
        msg_id = _uid()
        await db.execute(
            "INSERT INTO message (id, room_id, seq, sender_id, kind, content,"
            " mentions, reply_to, reply_to_seq, system_event, created_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (msg_id, room_id, seq, sender_id, kind, content,
             json.dumps(effective), reply_to, reply_to_seq, system_event, _now()),
        )
        await db.commit()
        await events.notify(room_id)
        # mentions 回傳「實際落庫的那份」（含回覆自動補上的），呼叫端的
        # 未解析檢查才不會漏掉自動加的那個名字
        return {"id": msg_id, "seq": seq, "mentions": effective,
                "reply_to_seq": reply_to_seq}

    async def _message_rows_to_json(rows, db) -> list[dict]:
        out = []
        attachments = await _attachments_for([r["id"] for r in rows], db)
        for r in rows:
            sender_name = None
            if r["sender_id"]:
                p = await (
                    await db.execute(
                        "SELECT display_name FROM participant WHERE id=?", (r["sender_id"],)
                    )
                ).fetchone()
                sender_name = p["display_name"] if p else None
            reply_preview = None
            reply_to_seq = r["reply_to_seq"]
            if r["reply_to"]:
                orig = await (
                    await db.execute(
                        "SELECT m.seq, m.content, m.deleted, p.display_name FROM message m"
                        " LEFT JOIN participant p ON p.id=m.sender_id"
                        " WHERE m.id=? AND m.room_id=?",  # 寫入已驗同房，這裡是縱深防禦
                        (r["reply_to"], r["room_id"]),
                    )
                ).fetchone()
                if orig:
                    reply_preview = {
                        "seq": orig["seq"],
                        "sender_name": orig["display_name"],
                        "excerpt": "" if orig["deleted"] else orig["content"][:80],
                        "deleted": bool(orig["deleted"]),
                    }
                    # 這個欄位是後來才加的，之前的回覆訊息落庫時沒有它。
                    # 現查補上，舊訊息才不會在 UI 上獨獨少一個「#12」
                    if reply_to_seq is None:
                        reply_to_seq = orig["seq"]
            out.append({
                "id": r["id"], "seq": r["seq"], "update_seq": r["update_seq"],
                "kind": r["kind"],
                # system 訊息的機器可讀型別；client 要精確過濾（例如只在
                # 有人加入時通知）就不必去比對中文內容
                "system_event": r["system_event"] or None,
                "sender_id": r["sender_id"], "sender_name": sender_name,
                "content": "" if r["deleted"] else r["content"],
                "mentions": json.loads(r["mentions"]),
                "reply_to": r["reply_to"], "reply_to_seq": reply_to_seq,
                "reply_preview": reply_preview,
                "pinned": bool(r["pinned"]), "deleted": bool(r["deleted"]),
                "attachments": [] if r["deleted"] else attachments.get(r["id"], []),
                "created_at": r["created_at"],
            })
        return out

    async def _touch_message(message_id: str, room_id: str) -> None:
        """訊息狀態變更（釘選/刪除）時領新序號，讓增量 cursor 能掃到並推播。"""
        db = app.state.db
        cur = await db.execute(
            "UPDATE room SET next_seq = next_seq + 1 WHERE id=? RETURNING next_seq - 1",
            (room_id,),
        )
        useq = (await cur.fetchone())[0]
        await db.execute(
            "UPDATE message SET update_seq=? WHERE id=?", (useq, message_id)
        )
        await db.commit()
        await events.notify(room_id)

    # ---------- 房間 ----------

    @app.post("/api/rooms", dependencies=[Depends(require_auth)])
    async def create_room(body: RoomCreate):
        db = app.state.db
        room_id = _uid()
        now = _now()
        # custom 沒有內容就沒有風格可言——落庫之後每個進來的 agent 都會拿到
        # 一個空指示，而它看起來與「沒設定」一模一樣，沒有人查得出哪裡不對
        if body.style == CUSTOM_STYLE and not body.style_instructions.strip():
            raise _err(422, "style_instructions_required",
                       "選擇自訂說話方式時必須寫下指示內容")
        instructions = (body.style_instructions.strip()
                        if body.style == CUSTOM_STYLE else "")
        await db.execute(
            "INSERT INTO room (id, name, topic, created_at, activated_at,"
            " creator_session_key, visibility, style, style_instructions)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (room_id, body.name, body.topic, now, now, body.session_key,
             body.visibility, body.style, instructions),
        )
        await db.commit()
        return {"id": room_id, "name": body.name, "topic": body.topic,
                "status": "active", "visibility": body.visibility,
                "style": body.style, "style_instructions": instructions}

    @app.get("/api/rooms", dependencies=[Depends(require_auth)])
    async def list_rooms(
        request: Request,
        status: str = "active",
        session_key: str | None = None,
        kind: str | None = None,
        label: str | None = None,
        host: str | None = None,
    ):
        db = app.state.db
        if session_key:
            await _touch_session(session_key, kind, label, _client_ip(request),
                                 host)
        # 私人房只對「有份的人」出現：建立者、房內（含曾在房內）的成員、
        # 被邀請的 session。沒帶 session_key 就只看得到公開房——匿名的
        # 列表請求無從證明自己有份
        rows = await (
            await db.execute(
                "SELECT r.*,"
                " (SELECT COUNT(*) FROM participant p WHERE p.room_id=r.id"
                "  AND p.status='active') AS member_count,"
                " r.next_seq - 1 AS last_seq,"
                " (SELECT m.created_at FROM message m WHERE m.room_id=r.id"
                "  ORDER BY m.seq DESC LIMIT 1) AS last_activity_at"
                " FROM room r WHERE r.status=? AND ("
                "  r.visibility='public'"
                "  OR r.creator_session_key=?"
                "  OR EXISTS (SELECT 1 FROM participant p WHERE p.room_id=r.id"
                "             AND p.session_key=? AND p.status!='kicked')"
                "  OR EXISTS (SELECT 1 FROM assignment a WHERE a.room_id=r.id"
                "             AND a.target_session_key=?"
                "             AND a.status IN ('pending','accepted'))"
                " ) ORDER BY last_activity_at DESC",
                (status, session_key, session_key, session_key),
            )
        ).fetchall()
        rooms = [_room_public(r) for r in rows]
        pending = []
        if session_key:
            # 與 GET /api/assignments 同形（含房名），client 不必打兩個端點
            arows = await (
                await db.execute(
                    "SELECT a.*, r.name AS room_name, r.topic AS room_topic"
                    " FROM assignment a JOIN room r ON r.id=a.room_id"
                    " WHERE a.target_session_key=? AND a.status='pending'",
                    (session_key,),
                )
            ).fetchall()
            pending = [dict(a) for a in arows]
        return {"rooms": rooms, "pending_assignments": pending}

    @app.get("/api/rooms/{room_id}", dependencies=[Depends(require_auth)])
    async def get_room(
        room_id: str,
        x_session_key: str | None = Header(default=None, alias="X-Session-Key"),
        x_participant_id: str | None = Header(default=None),
    ):
        room = await _room_or_404(room_id, allow_archived=True)
        # 成員名冊與 session_key、來源 IP 都在這個回應裡，非成員不該看得到
        await _creator_or_member(room, x_participant_id, x_session_key)
        db = app.state.db
        rows = await (
            await db.execute(
                "SELECT id, kind, display_name, role, status, joined_at,"
                " last_seen_at, session_key, join_ip"
                " FROM participant WHERE room_id=? ORDER BY joined_at",
                (room_id,),
            )
        ).fetchall()
        # 同一 session 多筆紀錄（離開後換名重進）只回代表列：active 優先、
        # 否則取最後一筆。最近一個不同的舊名放 previous_name，舊列 id 收進
        # alias_ids 讓 client 仍能對回歷史訊息的 kind。session_key 不外流。
        grouped: dict[str, list] = {}
        for r in rows:
            grouped.setdefault(r["session_key"], []).append(r)
        participants = []
        for group in grouped.values():
            rep = next((g for g in group if g["status"] == "active"), group[-1])
            others = [g for g in group if g["id"] != rep["id"]]
            entry = {
                k: rep[k]
                for k in (
                    "id", "kind", "display_name", "role", "status",
                    "joined_at", "last_seen_at",
                )
            }
            prev = next(
                (
                    g["display_name"]
                    for g in reversed(others)
                    if g["display_name"] != rep["display_name"]
                ),
                None,
            )
            if prev:
                entry["previous_name"] = prev
            if others:
                entry["alias_ids"] = [g["id"] for g in others]
            participants.append((entry, rep))
        participants.sort(key=lambda pair: pair[0]["joined_at"])
        # 名稱唯一性只約束 active 成員；active 與已離開之間仍可能重名。
        # 重名時附消歧提示：人類給來源 IP、agent 給 session 片段。
        # 取「尾」8 碼不取頭——固定身分 key 慣用共同前綴（codex-main / codex-dev），
        # 頭碼會撞在一起；也不外洩整把 key（它同時是指派目標）
        name_counts: dict[str, int] = {}
        for entry, _ in participants:
            name_counts[entry["display_name"]] = (
                name_counts.get(entry["display_name"], 0) + 1
            )
        for entry, rep in participants:
            if name_counts[entry["display_name"]] > 1:
                if rep["role"] == "human" and rep["join_ip"]:
                    entry["distinct_hint"] = rep["join_ip"]
                else:
                    entry["distinct_hint"] = rep["session_key"][-8:]
        # 管理員判定走 X-Session-Key 標頭，不把 creator key 丟給所有成員比對
        is_admin = bool(room["creator_session_key"]) and (
            x_session_key == room["creator_session_key"]
        )
        return {
            "room": _room_public(room),
            "participants": [e for e, _ in participants],
            "you_are_admin": is_admin,
            # UI 要據此算「還有多久被移出」。不給的話 client 只能寫死一個
            # 數字，而它與伺服器實際設定不一致時會顯示一個假的倒數——
            # 看起來像壞掉，實際上是猜的
            "server": {
                "idle_timeout_seconds": cfg.idle_timeout,
                "archive_grace_seconds": cfg.archive_grace,
                "max_attachment_bytes": cfg.max_attachment_bytes,
            },
        }

    async def _archive(room_id: str, reason: str) -> None:
        db = app.state.db
        # 先留時間軸標記再封存（封存房唯讀，之後就寫不進去了）
        await _post_message(room_id, None, reason, kind="system",
                            system_event="archive")
        await db.execute(
            "UPDATE room SET status='archived', archived_at=?,"
            " archive_pending_since=NULL WHERE id=?",
            (_now(), room_id),
        )
        await db.commit()
        await events.notify(room_id)

    @app.post("/api/rooms/{room_id}/archive", dependencies=[Depends(require_auth)])
    async def archive_room(room_id: str):
        await _room_or_404(room_id)
        await _archive(room_id, "聊天室已被手動封存")
        return {"ok": True}

    @app.post("/api/rooms/{room_id}/unarchive", dependencies=[Depends(require_auth)])
    async def unarchive_room(room_id: str):
        room = await _room_or_404(room_id, allow_archived=True)
        if room["status"] == "active":
            return {"ok": True, "already_active": True}
        db = app.state.db
        # 更新 activated_at：sweeper 只看解封後才加入的 agent，避免解封立即被封回
        await db.execute(
            "UPDATE room SET status='active', archived_at=NULL, activated_at=?,"
            " archive_pending_since=NULL WHERE id=?",
            (_now(), room_id),
        )
        await db.commit()
        await _post_message(room_id, None, "聊天室已解除封存", kind="system",
                            system_event="unarchive")
        return {"ok": True, "already_active": False}

    @app.post("/api/rooms/{room_id}/visibility", dependencies=[Depends(require_auth)])
    async def set_visibility(
        room_id: str,
        body: RoomVisibility,
        x_session_key: str | None = Header(default=None, alias="X-Session-Key"),
        x_participant_id: str | None = Header(default=None),
    ):
        """鎖定／解鎖對話。只有建立者能改。

        變更會在房內留下一則系統訊息：從公開變成私人，會影響其他人還找不找
        得到這個房間，那不該是一件只有管理員知道的事。
        """
        room = await _room_or_404(room_id)
        await _admin_or_403(room, x_participant_id, x_session_key)
        if room["visibility"] == body.visibility:
            return {"ok": True, "visibility": body.visibility, "changed": False}
        db = app.state.db
        await db.execute(
            "UPDATE room SET visibility=? WHERE id=?", (body.visibility, room_id)
        )
        await db.commit()
        logger.info(
            "變更鎖定狀態 %s → %s（%s）", room["visibility"], body.visibility, room_id,
            extra={"event": "visibility", "room_id": room_id,
                   "visibility": body.visibility},
        )
        await _post_message(
            room_id, None,
            ("這個對話已鎖定為私人：不會出現在其他人的對話列表，"
             "也必須受邀才能加入"
             if body.visibility == "private"
             else "這個對話已改為公開：所有連上 Hub 的人都看得到並可自行加入"),
            kind="system", system_event="visibility",
        )
        return {"ok": True, "visibility": body.visibility, "changed": True}

    @app.post("/api/rooms/{room_id}/style", dependencies=[Depends(require_auth)])
    async def set_style(
        room_id: str,
        body: RoomStyle,
        x_session_key: str | None = Header(default=None, alias="X-Session-Key"),
        x_participant_id: str | None = Header(default=None),
    ):
        """變更房內 agent 的說話方式。只有建立者能改。

        變更會在房內留下一則系統訊息：說話方式換了，房裡的人會看到彼此的
        語氣突然改變，那不該是一件沒有解釋的事。
        """
        room = await _room_or_404(room_id)
        await _admin_or_403(room, x_participant_id, x_session_key, "說話方式")
        if body.style == CUSTOM_STYLE and not body.style_instructions.strip():
            raise _err(422, "style_instructions_required",
                       "選擇自訂說話方式時必須寫下指示內容")
        instructions = (body.style_instructions.strip()
                        if body.style == CUSTOM_STYLE else "")
        if room["style"] == body.style and room["style_instructions"] == instructions:
            return {"ok": True, "style": body.style,
                    "style_instructions": instructions, "changed": False}
        db = app.state.db
        await db.execute(
            "UPDATE room SET style=?, style_instructions=? WHERE id=?",
            (body.style, instructions, room_id),
        )
        await db.commit()
        prompt, hint = _style_texts(body.style, instructions)
        logger.info(
            "變更說話方式 %s -> %s（%s）", room["style"], body.style, room_id,
            extra={"event": "style", "room_id": room_id, "style": body.style},
        )
        await _post_message(
            room_id, None, f"這個對話的說話方式已改為：{hint.split('：', 1)[-1]}",
            kind="system", system_event="style",
        )
        return {"ok": True, "style": body.style,
                "style_instructions": instructions,
                "style_prompt": prompt, "changed": True}

    # ---------- 成員 ----------

    @app.post("/api/rooms/{room_id}/join", dependencies=[Depends(require_auth)])
    async def join_room(room_id: str, body: JoinRequest, request: Request):
        room = await _room_or_404(room_id)
        db = app.state.db
        assignment = None
        session_key = body.session_key
        if body.assignment_id:
            assignment = await (
                await db.execute(
                    "SELECT * FROM assignment WHERE id=? AND room_id=?"
                    " AND status IN ('pending','accepted')",
                    (body.assignment_id, room_id),
                )
            ).fetchone()
            if assignment is None:
                raise _err(
                    404,
                    "assignment_not_joinable",
                    "找不到這筆可加入的指派，或它不屬於這個聊天室",
                )
            # 指派目標是權威身分。這讓 App 能以 Codex 自己的 thread id 指派，
            # 即使 MCP 進程只能帶臨時 bridge key，participant 仍綁到正確 session。
            session_key = assignment["target_session_key"]
        # 被管理員移出的 session 不得**自己**重新加入——否則 client 的斷線
        # 自癒（身分失效即自動 rejoin）會立刻把被踢的人加回來，等於踢不掉。
        #
        # 但管理員重新指派是另一回事：那是一個新的人為決定，必須放行，否則
        # 踢出就成了不可逆的死鎖，連指派 UI 都救不回來。分界線刻意不是
        # 「人類 vs agent」——agent 的自癒同樣會繞過，對 agent 一律放行就
        # 等於踢 agent 完全失效——而是「自己回來 vs 被重新邀請」。
        #
        # 舊指派在 kick 當下就被撤銷（見 kick endpoint），所以這裡放行的
        # 一定是踢出**之後**新建立的那筆。
        kicked = await (
            await db.execute(
                "SELECT 1 FROM participant WHERE room_id=? AND session_key=?"
                " AND status='kicked'",
                (room_id, session_key),
            )
        ).fetchone()
        if kicked and assignment is None:
            raise _err(403, "kicked",
                       "你已被管理員移出此聊天室，無法自行重新加入。"
                       "要回來需要管理員重新指派一次。")
        # 私人房：沒有邀請就進不來。放在 kicked 檢查之後——被踢的人即使
        # 手上有舊指派也已經在上面被擋掉了（kick 當下就撤銷了那些指派）
        if room["visibility"] == "private" and not await _invited_to_private(
            room, session_key
        ):
            raise _err(403, "room_is_private",
                       "這是一個私人對話，必須先被邀請才能加入。"
                       "請房內的成員從指派／邀請功能把你加進來。")
        # 同一 session 已在房內 → 冪等返回既有身分
        existing = await (
            await db.execute(
                "SELECT * FROM participant WHERE room_id=? AND session_key=? AND status='active'",
                (room_id, session_key),
            )
        ).fetchone()
        if existing:
            # 即使 session 已經在房內，使用 assignment token 重加也代表已接受
            # 該指派；否則 App 重啟後會再次投遞同一筆 pending assignment。
            if assignment is not None and assignment["status"] == "pending":
                await db.execute(
                    "UPDATE assignment SET status='accepted', resolved_at=? WHERE id=?",
                    (_now(), assignment["id"]),
                )
                await db.commit()
            await _touch_session(session_key, body.kind, ip=_client_ip(request),
                                 host=body.host)
            # rejoin 也給：閒置被移出後重新加入的多半是新的一輪對話，
            # 而上一輪讀到的風格早就滾出 context 了
            style_prompt, _ = _style_texts(room["style"], room["style_instructions"])
            return {
                "participant_id": existing["id"],
                "display_name": existing["display_name"],
                "rejoined": True,
                "session_key": session_key,
                "style": room["style"],
                "style_prompt": style_prompt,
            }

        taken_rows = await (
            await db.execute(
                "SELECT display_name FROM participant WHERE room_id=? AND status='active'",
                (room_id,),
            )
        ).fetchall()
        # 指派者預先取的名字優先於 agent 自取名與名字池（取最新一筆非空）
        if assignment is not None and assignment["assigned_name"]:
            assigned = assignment
        else:
            assigned = await (
                await db.execute(
                    "SELECT assigned_name FROM assignment WHERE room_id=?"
                    " AND target_session_key=? AND status='pending' AND assigned_name!=''"
                    " ORDER BY created_at DESC LIMIT 1",
                    (room_id, session_key),
                )
            ).fetchone()
        preferred = assigned["assigned_name"] if assigned else body.preferred_name
        name = generate_name({r["display_name"] for r in taken_rows}, preferred)
        pid = _uid()
        now = _now()
        join_ip = request.client.host if request.client else None
        await db.execute(
            "INSERT INTO participant (id, room_id, kind, session_key, display_name, role,"
            " joined_at, last_seen_at, join_ip, join_token) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (pid, room_id, body.kind, session_key, name, body.role, now, now,
             join_ip, getattr(request.state, "access_token", "")),
        )
        await db.commit()
        # 有 agent 加入時，若房間曾被指派給這個 session，順手標記完成
        await db.execute(
            "UPDATE assignment SET status='accepted', resolved_at=? WHERE room_id=?"
            " AND target_session_key=? AND status='pending'",
            (now, room_id, session_key),
        )
        await db.commit()
        await _touch_session(session_key, body.kind, ip=_client_ip(request),
                             host=body.host)
        # sender_id 掛上加入者本人：client 要過濾「自己加入」時就不必去解析
        # 中文內容比對名字（改一個字就無聲失效），也讓 UI 認得出是誰
        logger.info(
            "加入房間 %s（%s）", name, room_id, extra={
                "event": "join", "room_id": room_id, "participant_id": pid,
                "display_name": name, "session_key": session_key,
                "kind": body.kind, "role": body.role, "ip": join_ip,
                "token_hint": token_hint(getattr(request.state, "access_token", "")),
                "via_assignment": assignment is not None,
            },
        )
        joined = await _post_message(room_id, pid, f"{name} 加入了聊天室",
                                     kind="system", system_event="join")
        out = {
            "participant_id": pid,
            "display_name": name,
            "rejoined": False,
            "session_key": session_key,
            # 這則加入訊息在**回應送出之前**就已經 post 了，所以 client 首次
            # 跟房時 feed 可能已經含著它，然後把它當成歷史（首批快照只立
            # 基準線）而整個吃掉——正常首次進房就會走到，不是邊角案例。
            # 給出精確的 id/seq，client 才能只放行「就是這一筆」，不必靠
            # 時間窗去猜哪則加入算「剛剛發生」（那會被時鐘偏差打敗）。
            # 冪等 rejoin 不給：那次沒有產生新的加入訊息。
            "join_message_id": joined["id"],
            "join_seq": joined["seq"],
        }
        # 說話方式在**加入時就講清楚**，不是等他先講完一輪長篇再糾正——
        # 第一則發言就已經是別人要讀的東西了
        out["style"], out["style_prompt"] = (
            room["style"], _style_texts(room["style"], room["style_instructions"])[0]
        )
        if assigned:
            # 讓 agent 知道名字來自指派者，而非自己的 preferred_name
            out["name_from_assignment"] = True
        return out

    @app.post("/api/rooms/{room_id}/leave", dependencies=[Depends(require_auth)])
    async def leave_room(room_id: str, x_participant_id: str | None = Header(default=None)):
        # 封存房也允許離開（唯讀例外），故不檢查房間狀態
        p = await _participant(x_participant_id, room_id)
        db = app.state.db
        await db.execute(
            "UPDATE participant SET status='left', left_at=? WHERE id=?", (_now(), p["id"])
        )
        logger.info(
            "離開房間 %s（%s）", p["display_name"], room_id, extra={
                "event": "leave", "room_id": room_id, "participant_id": p["id"],
                "display_name": p["display_name"],
                "session_key": p["session_key"],
            },
        )
        await db.commit()
        await _post_message(room_id, None, f"{p['display_name']} 離開了聊天室",
                            kind="system", system_event="leave")
        return {"ok": True}

    @app.post(
        "/api/rooms/{room_id}/participants/{target_id}/kick",
        dependencies=[Depends(require_auth)],
    )
    async def kick_participant(
        room_id: str,
        target_id: str,
        x_participant_id: str | None = Header(default=None),
    ):
        """管理員（建立者）移出成員。被移出的 session 之後無法重新加入。"""
        room = await _room_or_404(room_id)
        me = await _participant(x_participant_id, room_id)
        if not room["creator_session_key"] or (
            me["session_key"] != room["creator_session_key"]
        ):
            raise _err(403, "not_admin", "只有聊天室建立者可以移出成員")
        if target_id == me["id"]:
            raise _err(422, "cannot_kick_self", "不能移出自己，請改用離開")
        db = app.state.db
        target = await (
            await db.execute(
                "SELECT * FROM participant WHERE id=? AND room_id=?"
                " AND status='active'",
                (target_id, room_id),
            )
        ).fetchone()
        if target is None:
            raise _err(404, "participant_not_found", "找不到這個成員，或已不在房內")
        now = _now()
        await db.execute(
            "UPDATE participant SET status='kicked', left_at=? WHERE id=?",
            (now, target_id),
        )
        # 移出等同撤銷授權。舊指派若留著 pending/accepted，被踢的 agent 拿它
        # 就能繞過重加限制——而那筆指派是踢出**之前**的決定，早已被推翻。
        # 要回來必須由管理員重新指派一次。
        await db.execute(
            "UPDATE assignment SET status='revoked', resolved_at=?"
            " WHERE room_id=? AND target_session_key=?"
            " AND status IN ('pending','accepted')",
            (now, room_id, target["session_key"]),
        )
        await db.commit()
        # 只把 session_key 標成 kicked 擋不住任何人：那把鑰匙是被踢者自己在
        # 本機產的（`human-<uuid4>`，設定畫面還有「重新產生」按鈕），換一把
        # 就能大搖大擺走回來。**封鎖的對象必須是被封鎖者無法自行更換的識別**，
        # 目前唯一符合的是主持人發出去的那張 access token。
        #
        # 一張 token 給多人共用時會一起斷——那是「一張發給一個人」的語意本來
        # 就有的後果，不是這裡的例外，所以回應要說清楚撤掉的是哪一張。
        revoked_token = ""
        if target["join_token"]:
            cur = await db.execute(
                "UPDATE access_token SET revoked_at=? WHERE token=?"
                " AND revoked_at IS NULL RETURNING label",
                (now, target["join_token"]),
            )
            hit = await cur.fetchone()
            if hit is not None:
                revoked_token = hit["label"] or target["join_token"][:8]
        await db.commit()
        logger.info(
            "移出成員 %s（%s）", target["display_name"], room_id, extra={
                "event": "kick", "room_id": room_id, "target_id": target_id,
                "display_name": target["display_name"],
                "target_session_key": target["session_key"],
                "by": me["display_name"], "by_participant_id": me["id"],
                "revoked_token_hint": token_hint(target["join_token"]),
                # 對方拿主 token 進來時撤不掉——這件事要進紀錄，
                # 事後才查得出「為什麼踢了還在」
                "access_still_open": not target["join_token"],
            },
        )
        await _post_message(
            room_id, None,
            f"{target['display_name']} 已被管理員移出聊天室", kind="system",
            system_event="kick",
        )
        return {
            "ok": True,
            # 撤掉了哪張邀請（空＝沒撤到）
            "revoked_token_label": revoked_token,
            # 對方是拿主 token（或在無 token 的開放模式下）進來的：主 token
            # 不可撤銷——撤了所有人一起斷——所以他換個 session_key 就能再進來。
            # 這件事必須講出來，不能讓管理員以為踢出等於切斷存取
            "access_still_open": not target["join_token"],
        }

    @app.post("/api/rooms/{room_id}/heartbeat", dependencies=[Depends(require_auth)])
    async def heartbeat(room_id: str, x_participant_id: str | None = Header(default=None)):
        await _participant(x_participant_id, room_id)
        return {"ok": True}

    # ---------- 訊息 ----------

    @app.post("/api/rooms/{room_id}/messages", dependencies=[Depends(require_auth)])
    async def post_message(
        room_id: str, body: MessagePost, x_participant_id: str | None = Header(default=None)
    ):
        """發言。mention 到不存在或已離開的名字時，在回應中明說。

        帶 ``reply_to`` 時，被回覆者會被**自動加進 mentions**——回覆與 @ 在
        使用者眼裡是同一件事，而在此之前只有後者會喚醒對方。回應的
        ``mentions`` 是實際落庫的那份（含自動補上的），``reply_to_seq``
        是被回覆訊息的房內序號。

        房裡可能同時有「Novia」（已離開的舊身分）與「Novia-2」（本人），名字
        只差一個字。挑錯的話訊息會安靜地送進一個永遠不會醒的身分——發出去了、
        沒有錯誤、也永遠等不到回應。mention 的用途就是喚醒對方，喚不到就是失敗，
        必須講出來。不擋下訊息本身：提及一個已離開的人有時是合理的敘述。
        """
        await _room_or_404(room_id)
        p = await _participant(x_participant_id, room_id)
        db = app.state.db
        if body.attachment_ids:
            # 只認「這個房間、還沒綁過訊息」的附件——否則可以把別房的附件
            # 掛到自己的訊息上，等於繞過房間邊界讀別人的檔案
            marks = ",".join("?" for _ in body.attachment_ids)
            rows = await (
                await db.execute(
                    f"SELECT id FROM attachment WHERE id IN ({marks})"
                    f" AND room_id=? AND message_id IS NULL",
                    [*body.attachment_ids, room_id],
                )
            ).fetchall()
            found = {r["id"] for r in rows}
            missing = [a for a in body.attachment_ids if a not in found]
            if missing:
                raise _err(422, "attachment_not_available",
                           "附件不存在、不屬於這個房間，或已經附在別的訊息上")
        result = await _post_message(
            room_id, p["id"], body.content, mentions=body.mentions, reply_to=body.reply_to
        )
        if body.attachment_ids:
            marks = ",".join("?" for _ in body.attachment_ids)
            await db.execute(
                f"UPDATE attachment SET message_id=? WHERE id IN ({marks})",
                [result["id"], *body.attachment_ids],
            )
            await db.commit()
        # 用實際落庫的 mentions 檢查，不是 body.mentions——回覆自動補上的那個
        # 名字同樣可能已經離開房間，而那正是最需要講出來的情況：你以為回覆
        # 就等於通知到人，對方其實早就不在了
        if result["mentions"]:
            rows = await (
                await db.execute(
                    "SELECT display_name FROM participant WHERE room_id=?"
                    " AND status='active'",
                    (room_id,),
                )
            ).fetchall()
            active_names = {r["display_name"] for r in rows}
            unresolved = [m for m in result["mentions"] if m not in active_names]
            if unresolved:
                result["unresolved_mentions"] = unresolved
                result["active_names"] = sorted(active_names)
        return result

    @app.get("/api/rooms/{room_id}/messages", dependencies=[Depends(require_auth)])
    async def read_messages(
        room_id: str,
        after_seq: int = 0,
        before_seq: int | None = None,
        limit: int = Query(default=100, ge=1, le=500),
        pinned_only: bool = False,
        x_participant_id: str | None = Header(default=None),
    ):
        """讀訊息。after_seq 正向翻頁（新訊息）、before_seq 反向翻頁（載入歷史），
        兩者互斥；回傳一律以 seq 遞增排列。"""
        room = await _room_or_404(room_id, allow_archived=True)
        await _member_or_403(room_id, x_participant_id)
        if before_seq is not None and after_seq:
            raise _err(422, "conflicting_cursors", "after_seq 與 before_seq 不可同時使用")
        db = app.state.db
        cond = "room_id=?"
        params: list = [room_id]
        if pinned_only:
            cond += " AND pinned=1"
        if before_seq is not None:
            cond += " AND seq<?"
            params.append(before_seq)
            sql = f"SELECT * FROM message WHERE {cond} ORDER BY seq DESC LIMIT ?"
        else:
            cond += " AND seq>?"
            params.append(after_seq)
            sql = f"SELECT * FROM message WHERE {cond} ORDER BY seq LIMIT ?"
        # 多取一筆判斷 has_more，避免第二次 COUNT 查詢
        rows = await (await db.execute(sql, (*params, limit + 1))).fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]
        if before_seq is not None:
            rows = list(reversed(rows))
        msgs = await _message_rows_to_json(rows, db)
        # 每次讀都帶一行風格提醒：加入時給過的完整指示會隨著對話變長而被
        # 稀釋，語氣接著一則一則飄回 agent 的預設。一行的成本幾乎為零
        out: dict = {"messages": msgs, "has_more": has_more,
                     "style_hint": _style_texts(room["style"],
                                                room["style_instructions"])[1]}
        if msgs:
            out["next_after_seq"] = msgs[-1]["seq"]
            out["next_before_seq"] = msgs[0]["seq"]
        return out

    @app.get("/api/rooms/{room_id}/updates", dependencies=[Depends(require_auth)])
    async def wait_updates(
        room_id: str,
        after_seq: int = 0,
        timeout: float = Query(default=25.0, le=55.0),
        x_participant_id: str | None = Header(default=None),
    ):
        """long-poll：有 seq > after_seq 的訊息立即返回，否則掛到 timeout。

        回應一律附上 ``room_status``——房間封存時成員身分不會失效（封存房仍可
        讀），所以 watcher 光靠錯誤碼看不出房間已經沒了，會一直空轉 long-poll。
        狀態在**返回前**重讀，等待期間才發生的封存也涵蓋得到。
        """
        room = await _room_or_404(room_id, allow_archived=True)
        style_hint = _style_texts(room["style"], room["style_instructions"])[1]
        db = app.state.db
        # 從選填改必填：這是取得即時訊息的通道，非成員掛在這裡等於被踢之後
        # 照樣旁聽整個房間。這裡要的是 **active** 身分（不是 _member_or_403
        # 那種「曾經是成員」）——已經離開的人不需要即時推送，讓他掛著只是
        # 白佔一條長輪詢
        me = await _participant(x_participant_id, room_id)

        async def _status() -> str:
            row = await (
                await db.execute("SELECT status FROM room WHERE id=?", (room_id,))
            ).fetchone()
            return row["status"] if row else "deleted"

        deadline = asyncio.get_event_loop().time() + min(timeout, cfg.max_poll_timeout)
        while True:
            # max(seq, update_seq)：新訊息與既有訊息的狀態變更（釘選/刪除）
            # 共用同一個 cursor，client 只要回傳 last_seq 就不會漏
            rows = await (
                await db.execute(
                    "SELECT * FROM message WHERE room_id=? AND MAX(seq, update_seq)>?"
                    " ORDER BY MAX(seq, update_seq) LIMIT ?",
                    (room_id, after_seq, cfg.updates_batch_limit),
                )
            ).fetchall()
            if rows:
                msgs = await _message_rows_to_json(rows, db)
                mentioned = bool(me) and any(
                    me["display_name"] in m["mentions"] for m in msgs
                )
                return {"messages": msgs, "you_were_mentioned": mentioned,
                        "last_seq": max(max(m["seq"], m["update_seq"]) for m in msgs),
                        "room_status": await _status(), "style_hint": style_hint}
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                return {"messages": [], "you_were_mentioned": False,
                        "last_seq": after_seq, "room_status": await _status(),
                        "style_hint": style_hint}
            await events.wait(room_id, remaining)

    async def _message_room(message_id: str) -> str:
        db = app.state.db
        row = await (
            await db.execute("SELECT room_id FROM message WHERE id=?", (message_id,))
        ).fetchone()
        if row is None:
            raise _err(404, "message_not_found", "找不到這則訊息")
        return row["room_id"]

    @app.post("/api/messages/{message_id}/pin", dependencies=[Depends(require_auth)])
    async def pin_message(message_id: str, x_participant_id: str | None = Header(default=None)):
        """釘選一則訊息，並通知它的發送者。

        通知的對象**一律是被釘訊息的發送者**，與誰按下釘選無關——包括自己
        釘自己的訊息。釘選是「這段話很重要，之後還要回來看」的宣告，而最該
        知道這件事的人就是說這段話的人；讓通知與釘選者的身分掛鉤，只會多出
        一堆「為什麼這次沒通知」的特例。

        被釘的若是系統訊息（沒有發送者）就沒有人可通知，但收據照樣留下——
        釘選本身是房內事件，不因為沒人可 ping 就變成靜默操作。
        """
        room_id = await _message_room(message_id)
        await _room_or_404(room_id)  # 封存房唯讀，禁止釘選
        p = await _participant(x_participant_id, room_id)
        db = app.state.db
        # 條件式 UPDATE：重複釘選一則已釘選的訊息不該再通知一次。
        # 「先 SELECT 判斷再 UPDATE」不行——兩者之間有空隙，並發的兩次釘選
        # 會雙雙通過檢查而發出兩張收據。把判斷寫進 UPDATE 的 WHERE 裡，
        # 由資料庫保證只有一次會命中
        cur = await db.execute(
            "UPDATE message SET pinned=1, pinned_by=? WHERE id=? AND pinned=0"
            " RETURNING seq, sender_id",
            (p["id"], message_id),
        )
        target = await cur.fetchone()
        if target is None:
            await db.commit()
            return {"ok": True, "already_pinned": True}
        seq, sender_id = target["seq"], target["sender_id"]
        await _touch_message(message_id, room_id)
        author_name = None
        if sender_id:
            author = await (
                await db.execute(
                    "SELECT display_name FROM participant WHERE id=?", (sender_id,)
                )
            ).fetchone()
            author_name = author["display_name"] if author else None
        if author_name:
            content = f"{p['display_name']} 釘選了 {author_name} 的訊息 #{seq}"
        else:
            content = f"{p['display_name']} 釘選了 #{seq}"
        await _post_message(
            room_id, None, content, kind="system", system_event="pin",
            mentions=[author_name] if author_name else None,
            reply_to=message_id,
        )
        return {"ok": True, "notified": author_name}

    @app.delete("/api/messages/{message_id}/pin", dependencies=[Depends(require_auth)])
    async def unpin_message(message_id: str, x_participant_id: str | None = Header(default=None)):
        room_id = await _message_room(message_id)
        await _room_or_404(room_id)  # 封存房唯讀，禁止取消釘選
        await _participant(x_participant_id, room_id)
        db = app.state.db
        await db.execute(
            "UPDATE message SET pinned=0, pinned_by=NULL WHERE id=?", (message_id,)
        )
        await _touch_message(message_id, room_id)
        return {"ok": True}

    @app.delete("/api/messages/{message_id}", dependencies=[Depends(require_auth)])
    async def delete_message(message_id: str):
        # 人類管控用的軟刪除；不驗證 participant，靠 API token
        room_id = await _message_room(message_id)
        db = app.state.db
        await db.execute("UPDATE message SET deleted=1 WHERE id=?", (message_id,))
        await _touch_message(message_id, room_id)
        return {"ok": True}

    # ---------- 指派 ----------

    @app.post("/api/rooms/{room_id}/assignments", dependencies=[Depends(require_auth)])
    async def create_assignment(room_id: str, body: AssignmentCreate):
        """建立指派，並回報目標 session 目前是不是活的。

        指派本身永遠成立（對方稍後上線仍收得到），但派給一把沒有 watcher 在
        輪詢的 key 時，外觀與「派錯人」完全一樣——都是丟出去毫無反應。這個
        情境比想像中常見：`/clear` 換掉 session id 之後，UI 上抄的舊 key 就
        再也沒人來領了。與其讓人乾等，不如在建立當下就講清楚。
        """
        await _room_or_404(room_id)
        db = app.state.db
        aid = _uid()
        await db.execute(
            "INSERT INTO assignment (id, room_id, target_session_key, note,"
            " assigned_name, created_at) VALUES (?,?,?,?,?,?)",
            (aid, room_id, body.target_session_key, body.note,
             body.assigned_name.strip(), _now()),
        )
        await db.commit()
        seen = await (
            await db.execute(
                "SELECT last_seen_at FROM session WHERE session_key=?",
                (body.target_session_key,),
            )
        ).fetchone()
        active_cutoff = (
            datetime.now(timezone.utc) - timedelta(seconds=cfg.session_active_window)
        ).isoformat()
        return {
            "id": aid,
            "target_known": seen is not None,
            "target_active": bool(seen and seen["last_seen_at"] >= active_cutoff),
            "target_last_seen_at": seen["last_seen_at"] if seen else None,
        }

    @app.get("/api/rooms/{room_id}/assignments", dependencies=[Depends(require_auth)])
    async def list_room_assignments(
        room_id: str,
        x_participant_id: str | None = Header(default=None),
        x_session_key: str | None = Header(default=None, alias="X-Session-Key"),
    ):
        """房間視角的指派列表（UI 檢視用，含所有狀態）。"""
        room = await _room_or_404(room_id, allow_archived=True)
        await _creator_or_member(room, x_participant_id, x_session_key)
        db = app.state.db
        rows = await (
            await db.execute(
                "SELECT * FROM assignment WHERE room_id=? ORDER BY created_at DESC",
                (room_id,),
            )
        ).fetchall()
        return {"assignments": [dict(r) for r in rows]}

    @app.get("/api/assignments", dependencies=[Depends(require_auth)])
    async def list_assignments(
        request: Request,
        session_key: str,
        kind: str | None = None,
        label: str | None = None,
        host: str | None = None,
    ):
        # 這是 watcher 的固定輪詢點——session 名錄的主要心跳來源
        await _touch_session(session_key, kind, label, _client_ip(request), host)
        db = app.state.db
        rows = await (
            await db.execute(
                "SELECT a.*, r.name AS room_name, r.topic AS room_topic FROM assignment a"
                " JOIN room r ON r.id=a.room_id"
                " WHERE a.target_session_key=? AND a.status='pending'",
                (session_key,),
            )
        ).fetchall()
        return {"assignments": [dict(r) for r in rows]}

    @app.post("/api/assignments/{assignment_id}/resolve", dependencies=[Depends(require_auth)])
    async def resolve_assignment(assignment_id: str, body: AssignmentResolve):
        db = app.state.db
        cur = await db.execute(
            "UPDATE assignment SET status=?, resolved_at=? WHERE id=? AND status='pending'"
            " RETURNING id",
            (body.status, _now(), assignment_id),
        )
        if await cur.fetchone() is None:
            raise _err(404, "assignment_not_found", "找不到這筆指派，或它已被處理")
        await db.commit()
        return {"ok": True}

    @app.delete("/api/assignments/{assignment_id}", dependencies=[Depends(require_auth)])
    async def cancel_assignment(assignment_id: str):
        """指派方收回一筆還沒被處理的指派。

        與 resolve 是相反方向的動作：resolve 是被指派方回應（接受／婉拒），
        這裡是指派方反悔。兩者都只對 pending 生效——已經被接受的指派對方
        可能已經開工了，單方面撤掉只會讓兩邊對「這件事還算不算數」有不同
        認知；那種情況該用講的，不是用一個按鈕。

        狀態獨立成 ``cancelled`` 而不是複用 ``declined``：後者是被指派方
        的判斷，事後看紀錄時分不出「他不想做」與「我不需要了」是兩件事。
        """
        db = app.state.db
        cur = await db.execute(
            "UPDATE assignment SET status='cancelled', resolved_at=?"
            " WHERE id=? AND status='pending' RETURNING id",
            (_now(), assignment_id),
        )
        if await cur.fetchone() is None:
            raise _err(404, "assignment_not_found",
                       "找不到這筆指派，或它已經被處理過了")
        await db.commit()
        return {"ok": True}

    # ---------- 附件 ----------

    def _attachment_root() -> Path:
        """附件實體的存放根目錄；預設放在資料庫檔旁邊，備份時一起帶走。"""
        if cfg.attachment_dir:
            root = Path(cfg.attachment_dir)
        else:
            root = Path(cfg.db_path).resolve().parent / "attachments"
        root.mkdir(parents=True, exist_ok=True)
        return root

    def _blob_path(sha: str) -> Path:
        """內容定址：同一份檔案重複上傳只存一份，且路徑完全由雜湊決定。

        絕不用使用者給的檔名組路徑——那是目錄穿越的標準入口，而附件的來源
        包含外部 agent。原始檔名只留在 DB 裡供顯示。
        """
        root = _attachment_root()
        sub = root / sha[:2]
        sub.mkdir(parents=True, exist_ok=True)
        return sub / sha

    async def _attachments_for(message_ids: list[str], db) -> dict[str, list[dict]]:
        if not message_ids:
            return {}
        marks = ",".join("?" for _ in message_ids)
        rows = await (
            await db.execute(
                f"SELECT id, message_id, filename, mime, size FROM attachment"
                f" WHERE message_id IN ({marks}) ORDER BY created_at",
                message_ids,
            )
        ).fetchall()
        out: dict[str, list[dict]] = {}
        for r in rows:
            out.setdefault(r["message_id"], []).append({
                "id": r["id"], "filename": r["filename"],
                "mime": r["mime"], "size": r["size"],
                "is_image": r["mime"].startswith("image/"),
            })
        return out

    @app.post("/api/rooms/{room_id}/attachments", dependencies=[Depends(require_auth)])
    async def upload_attachment(
        room_id: str,
        file: UploadFile = File(...),
        x_participant_id: str | None = Header(default=None),
    ):
        """上傳一個附件，回傳 id。要讓它出現在對話裡，再用 attachment_ids 發訊息。

        分兩步而不是一次做完：上傳可能因為檔案大而失敗或逾時，綁在發言裡的話
        重試就會重複發言。
        """
        await _room_or_404(room_id)
        p = await _participant(x_participant_id, room_id)
        digest = hashlib.sha256()
        size = 0
        # 邊讀邊寫暫存檔：整份讀進記憶體的話，幾個並發的大檔就能把 Hub 吃掉
        root = _attachment_root()
        tmp = root / f".upload-{_uid()}"
        try:
            with tmp.open("wb") as fh:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > cfg.max_attachment_bytes:
                        raise _err(
                            413, "attachment_too_large",
                            f"檔案超過上限 "
                            f"{cfg.max_attachment_bytes // (1024 * 1024)} MB",
                        )
                    digest.update(chunk)
                    fh.write(chunk)
            if size == 0:
                raise _err(422, "empty_attachment", "檔案是空的")
            sha = digest.hexdigest()
            target = _blob_path(sha)
            if target.exists():
                tmp.unlink()          # 內容已存在，共用同一份實體
            else:
                tmp.replace(target)
        finally:
            tmp.unlink(missing_ok=True)

        aid = _uid()
        db = app.state.db
        await db.execute(
            "INSERT INTO attachment (id, room_id, message_id, uploader_id,"
            " filename, mime, size, sha256, created_at)"
            " VALUES (?,?,NULL,?,?,?,?,?,?)",
            (aid, room_id, p["id"], Path(file.filename or "檔案").name,
             file.content_type or "application/octet-stream", size, sha, _now()),
        )
        await db.commit()
        return {"id": aid, "size": size, "sha256": sha,
                "mime": file.content_type or "application/octet-stream"}

    @app.get("/api/attachments/{attachment_id}/meta",
             dependencies=[Depends(require_auth)])
    async def attachment_meta(
        attachment_id: str, x_participant_id: str | None = Header(default=None)
    ):
        """附件的 metadata。下載端點回的是檔案本體，拿不到檔名與型別。"""
        db = app.state.db
        row = await (
            await db.execute(
                "SELECT a.id, a.room_id, a.message_id, a.filename, a.mime,"
                " a.size, a.created_at, p.display_name AS uploader_name"
                " FROM attachment a LEFT JOIN participant p ON p.id=a.uploader_id"
                " WHERE a.id=?",
                (attachment_id,),
            )
        ).fetchone()
        if row is None:
            raise _err(404, "attachment_not_found", "找不到這個附件")
        # 附件跟著訊息走，門檻就跟著訊息一樣：非成員讀不到房內的檔案
        await _member_or_403(row["room_id"], x_participant_id)
        meta = dict(row)
        meta["is_image"] = meta["mime"].startswith("image/")
        return {"attachment": meta}

    @app.get("/api/attachments/{attachment_id}", dependencies=[Depends(require_auth)])
    async def download_attachment(
        attachment_id: str, x_participant_id: str | None = Header(default=None)
    ):
        db = app.state.db
        row = await (
            await db.execute(
                "SELECT * FROM attachment WHERE id=?", (attachment_id,)
            )
        ).fetchone()
        if row is None:
            raise _err(404, "attachment_not_found", "找不到這個附件")
        await _member_or_403(row["room_id"], x_participant_id)
        path = _blob_path(row["sha256"])
        if not path.exists():
            # metadata 在、實體不在：備份只帶走 db 沒帶 attachments/ 就會這樣，
            # 講清楚比回一個空的 404 有用
            raise _err(410, "attachment_blob_missing",
                       "附件的內容已不在伺服器上（資料庫與附件目錄可能不同步）")
        return FileResponse(
            path, media_type=row["mime"], filename=row["filename"]
        )

    # ---------- 向人類提問 ----------

    def _seconds_left(expires_at: str | None) -> float | None:
        """距離到期還有幾秒；已過期為 0，沒有時限則 None（舊資料）。"""
        if not expires_at:
            return None
        try:
            deadline = datetime.fromisoformat(expires_at)
        except ValueError:
            return None
        return max(0.0, (deadline - datetime.now(timezone.utc)).total_seconds())

    def _question_public(row) -> dict:
        d = dict(row)
        try:
            d["options"] = json.loads(d.get("options") or "[]")
        except ValueError:
            d["options"] = []
        d["allow_free_text"] = bool(d.get("allow_free_text"))
        # 🔑 即時判定，不等 sweeper。sweeper 每輪之間最多 30 秒空窗，而那個
        # 誤差是**使用者看得到的**——卡片該消失卻還在，點下去才發現過期了。
        # 狀態以時間為準，sweeper 只負責把它寫死（見 _expire_questions）。
        left = _seconds_left(d.get("expires_at"))
        d["expires_in_seconds"] = left
        if d["status"] == "pending" and left is not None and left <= 0:
            d["status"] = "expired"
        return d

    async def _expire_questions() -> set[str]:
        """把過期的 pending 落庫成 expired，回傳受影響的房間 id。

        落庫是為了讓歷史查詢與統計看到一致的狀態；即時正確性由
        `_question_public` 保證，這裡晚幾秒不影響任何人看到的結果。
        """
        db = app.state.db
        now = _now()
        rows = await (
            await db.execute(
                "UPDATE question SET status='expired', resolved_at=?"
                " WHERE status='pending' AND expires_at IS NOT NULL"
                " AND expires_at <= ? RETURNING id, room_id, target_id",
                (now, now),
            )
        ).fetchall()
        if not rows:
            return set()
        await db.commit()
        for r in rows:
            logger.info(
                "問題逾時未作答 %s", r["id"], extra={
                    "event": "question_expired", "question_id": r["id"],
                    "room_id": r["room_id"], "target_id": r["target_id"],
                },
            )
        return {r["room_id"] for r in rows}

    async def _human_candidates(room_id: str) -> str:
        db = app.state.db
        rows = await (
            await db.execute(
                "SELECT display_name FROM participant WHERE room_id=?"
                " AND status='active' AND role='human' ORDER BY last_seen_at DESC",
                (room_id,),
            )
        ).fetchall()
        return "、".join(r["display_name"] for r in rows)

    async def _resolve_target(room_id: str, explicit: str):
        """決定這題要問誰。對象**必須明確指定，且必須是人類**。

        不代為挑選：房內人數一變，同一個請求就會從成功變成失敗，而且事後
        無法證明發問方選的是誰。誤指到 agent 則會讓問題永遠等不到答案，
        而症狀是靜默的——就是一直逾時，看不出是問錯了人。
        """
        db = app.state.db
        row = await (
            await db.execute(
                "SELECT * FROM participant WHERE id=? AND room_id=? AND status='active'",
                (explicit, room_id),
            )
        ).fetchone()
        if row is None:
            candidates = await _human_candidates(room_id)
            raise _err(404, "target_not_found",
                       "指定的對象不在這個房間裡。"
                       + (f"目前在房內的人類：{candidates}"
                          if candidates else "房裡目前沒有人類可以回答。"))
        if row["role"] != "human":
            raise _err(422, "target_not_human",
                       "只能向人類提問；這個機制的用意就是在有人在的時候問人")
        return row

    @app.post("/api/rooms/{room_id}/questions", dependencies=[Depends(require_auth)])
    async def create_question(
        room_id: str, body: QuestionCreate,
        x_participant_id: str | None = Header(default=None),
    ):
        await _room_or_404(room_id)
        asker = await _participant(x_participant_id, room_id)
        target = await _resolve_target(room_id, body.target_participant_id)
        if not body.options and not body.allow_free_text:
            raise _err(422, "unanswerable_question",
                       "沒有選項又不允許自由作答，這題無法回答")
        db = app.state.db
        qid = _uid()
        ttl = body.timeout_seconds or cfg.question_ttl
        expires_at = (
            datetime.now(timezone.utc) + timedelta(seconds=ttl)
        ).isoformat()
        await db.execute(
            "INSERT INTO question (id, room_id, asker_id, target_id, prompt,"
            " options, allow_free_text, created_at, expires_at)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (qid, room_id, asker["id"], target["id"], body.prompt,
             json.dumps([o.model_dump() for o in body.options], ensure_ascii=False),
             int(body.allow_free_text), _now(), expires_at),
        )
        await db.commit()
        await events.notify(room_id)
        # 對方最近有沒有動靜。送出成功只證明「Hub 收下了」——人的 client
        # 沒開、或版本舊到不會顯示問題時，發問方會傻等到逾時才發現。
        active_cutoff = (
            datetime.now(timezone.utc) - timedelta(seconds=cfg.session_active_window)
        ).isoformat()
        return {"id": qid, "target_id": target["id"],
                "target_name": target["display_name"],
                "target_active": target["last_seen_at"] >= active_cutoff,
                "target_last_seen_at": target["last_seen_at"],
                "expires_at": expires_at, "expires_in_seconds": ttl}

    @app.get("/api/rooms/{room_id}/questions", dependencies=[Depends(require_auth)])
    async def list_questions(
        room_id: str,
        status: str | None = None,
        target_id: str | None = None,
        x_participant_id: str | None = Header(default=None),
    ):
        """房內問題列表。

        agent 發問前可以先看這裡有沒有人問過同一件事——重複發問正是這個機制
        要消除的東西，所以問題對房內成員一律可見，只有 UI 顯示是定向的。
        """
        await _room_or_404(room_id, allow_archived=True)
        await _member_or_403(room_id, x_participant_id)
        db = app.state.db
        conds, params = ["q.room_id=?"], [room_id]
        if status == "pending":
            # 已過期但還沒被 sweeper 寫死的，不能算在 pending 裡——否則
            # 「還有幾題待答」這個數字會比實際多，而 UI 的徽章正是靠它
            conds.append("q.status='pending'")
            conds.append("(q.expires_at IS NULL OR q.expires_at > ?)")
            params.append(_now())
        elif status == "expired":
            # 反過來：時間到了就算 expired，不必等落庫
            conds.append("(q.status='expired' OR (q.status='pending'"
                         " AND q.expires_at IS NOT NULL AND q.expires_at <= ?))")
            params.append(_now())
        elif status:
            conds.append("q.status=?")
            params.append(status)
        if target_id:
            conds.append("q.target_id=?")
            params.append(target_id)
        rows = await (
            await db.execute(
                "SELECT q.*, p.display_name AS asker_name FROM question q"
                " LEFT JOIN participant p ON p.id=q.asker_id"
                f" WHERE {' AND '.join(conds)}"
                " ORDER BY q.created_at DESC",
                params,
            )
        ).fetchall()
        return {"questions": [_question_public(r) for r in rows]}

    @app.get("/api/questions/{question_id}", dependencies=[Depends(require_auth)])
    async def get_question(
        question_id: str, wait: float = Query(default=0.0, le=55.0)
    ):
        """讀一題；``wait`` > 0 時掛起直到有結果或逾時（發問方的阻塞等待）。

        逾時**不改狀態**——人類晚一點才看到仍然可以回答，那時 agent 用
        chatroom_read_answer 就拿得到。把它標成過期只是為了讓畫面好看，
        代價是把一個還有用的答案丟掉。
        """
        db = app.state.db

        async def _load():
            row = await (
                await db.execute(
                    "SELECT q.*, p.display_name AS asker_name FROM question q"
                    " LEFT JOIN participant p ON p.id=q.asker_id"
                    " WHERE q.id=?",
                    (question_id,),
                )
            ).fetchone()
            if row is None:
                raise _err(404, "question_not_found", "找不到這個問題")
            return row

        row = await _load()
        pub = _question_public(row)
        if pub["status"] != "pending" or wait <= 0:
            return {"question": pub}
        # 等待時間不超過這題的剩餘壽命：問題只剩 10 秒時掛滿 55 秒，等於讓
        # 發問方多卡 45 秒去等一個**已經確定不會來**的答案
        budget = min(wait, cfg.max_poll_timeout)
        left = pub["expires_in_seconds"]
        if left is not None:
            budget = min(budget, left)
        deadline = asyncio.get_event_loop().time() + budget
        while True:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                out = _question_public(await _load())
                # 分開講：timed_out 是「你這次等夠久了」，expired 是「這題
                # 沒了」。前者可以再等一次，後者再等也沒有用
                return {"question": out, "timed_out": True,
                        "expired": out["status"] == "expired"}
            await events.wait(row["room_id"], remaining)
            row = await _load()
            pub = _question_public(row)
            if pub["status"] != "pending":
                return {"question": pub, "expired": pub["status"] == "expired"}

    @app.post("/api/questions/{question_id}/answer", dependencies=[Depends(require_auth)])
    async def answer_question(
        question_id: str, body: QuestionAnswer,
        x_participant_id: str | None = Header(default=None),
    ):
        db = app.state.db
        row = await (
            await db.execute("SELECT * FROM question WHERE id=?", (question_id,))
        ).fetchone()
        if row is None:
            raise _err(404, "question_not_found", "找不到這個問題")
        # 只有被問的人能答——否則「定向提問」形同虛設，agent 也可能自問自答
        me = await _participant(x_participant_id, row["room_id"])
        if me["id"] != row["target_id"]:
            raise _err(403, "not_your_question", "這個問題不是問你的")
        if row["status"] != "pending":
            raise _err(409, "question_already_resolved", "這個問題已經處理過了")
        # 以時間為準，不是以 status 欄位為準：sweeper 還沒跑到的那幾秒裡，
        # DB 仍寫著 pending。放行的話發問方會在**已經放棄之後**收到答案，
        # 那比沒收到更難處理
        # ⚠️ 不可寫成 `(_seconds_left(...) or 1) <= 0`：剩餘 0.0 秒正是「已過期」
        # 的那個值，而 0.0 在 Python 裡是 falsy，會被 `or` 換成 1 而放行
        left = _seconds_left(row["expires_at"])
        if left is not None and left <= 0:
            raise _err(409, "question_expired",
                       "這題已經逾時了，答案沒有送出。發問方多半已經改走別的路"
                       "——需要的話請直接在聊天室裡告訴他。")
        if body.kind != "skip" and not body.answer.strip():
            raise _err(422, "empty_answer", "答案不能是空的")
        if body.kind == "free_text" and not row["allow_free_text"]:
            raise _err(422, "free_text_not_allowed", "這題只能從選項中選")
        if body.kind == "option":
            # 不驗的話 kind=option 只是個標籤，任何字串都能冒充成「他選了這個」，
            # 而 agent 會把 answer_kind=option 當成「從我給的清單裡選的」來信任
            try:
                labels = {o.get("label") for o in json.loads(row["options"] or "[]")}
            except ValueError:
                labels = set()
            if body.answer.strip() not in labels:
                raise _err(422, "unknown_option",
                           "這個選項不在題目提供的清單裡")
        status = "skipped" if body.kind == "skip" else "answered"
        # 條件放進 UPDATE 本身：先 SELECT 再 UPDATE 之間有空隙，兩個並發的
        # 回答會雙雙通過檢查，後到的直接覆寫先到的答案而且沒有任何人知道
        cur = await db.execute(
            "UPDATE question SET status=?, answer=?, answer_kind=?, resolved_at=?"
            " WHERE id=? AND status='pending' RETURNING id",
            (status, body.answer.strip(), body.kind, _now(), question_id),
        )
        if await cur.fetchone() is None:
            raise _err(409, "question_already_resolved", "這個問題已經處理過了")
        await db.commit()
        await events.notify(row["room_id"])
        receipt = await _post_answer_receipt(row, me, status, body.answer.strip())
        return {"ok": True, "status": status, "receipt_seq": receipt["seq"]}

    async def _post_answer_receipt(question, answerer, status: str, answer: str) -> dict:
        """在時間軸留下一張「這題已經有答案了」的收據。

        問題本身刻意不進時間軸（見 schema 註解：定向的東西灌進公開時間軸會
        變成噪音，也會讓其他人以為該由自己回答）。但**答案不一樣**：它是一個
        已經拍板的決定，房內其他 agent 照著做就對了。決定只活在 question 表
        裡的話，沒有人會知道它存在——除非每個 agent 都想到要去翻那張表，而
        它們不會。收據是那個決定唯一會被看見的地方，所以它留下來。

        收據也 mention 發問者。發問方多半正卡在 chatroom_read_answer 上等，
        那條路會自己收到答案；但**放棄等待之後才被回答**的那次不會——那時
        這個 mention 是它唯一會醒來的理由。
        """
        db = app.state.db
        asker = None
        if question["asker_id"]:
            asker = await (
                await db.execute(
                    "SELECT display_name FROM participant WHERE id=?",
                    (question["asker_id"],),
                )
            ).fetchone()
        asker_name = asker["display_name"] if asker else "（已離開的成員）"
        # 問題摘要 + 答案全文：摘要足以認出是哪一題，答案不截斷——被截斷的
        # 決定等於沒有決定，讀的人還是得回頭去查，收據就白留了
        prompt = question["prompt"].replace("\n", " ").strip()
        if len(prompt) > 120:
            prompt = prompt[:120] + "…"
        if status == "skipped":
            content = (
                f"{asker_name} 的提問「{prompt}」"
                f"—— {answerer['display_name']} 選擇不在聊天室裡回答"
            )
        else:
            content = (
                f"{asker_name} 的提問「{prompt}」"
                f"—— {answerer['display_name']} 回答：{answer}"
            )
        return await _post_message(
            question["room_id"], None, content, kind="system",
            system_event=("question_skipped" if status == "skipped"
                          else "question_answered"),
            mentions=[asker["display_name"]] if asker else None,
        )

    # ---------- Session 名錄 ----------

    @app.get("/api/sessions", dependencies=[Depends(require_auth)])
    async def list_sessions(include_human: bool = False):
        """列出 Hub 見過且仍在存活窗內的 session（指派 UI 的掃描來源）。

        status：last_seen 在 active window 內為 ``active``，否則 ``idle``；
        超過 session_ttl 的不列出。附上該 session 目前所在的房間與房內名稱，
        以及最近一次使用過的顯示名稱，讓使用者認得出「這是誰」。
        """
        db = app.state.db
        now = datetime.now(timezone.utc)
        ttl_cutoff = (now - timedelta(seconds=cfg.session_ttl)).isoformat()
        active_cutoff = (now - timedelta(seconds=cfg.session_active_window)).isoformat()
        cond = "last_seen_at >= ?"
        params: list = [ttl_cutoff]
        if not include_human:
            cond += " AND kind != 'human'"
        rows = await (
            await db.execute(
                f"SELECT * FROM session WHERE {cond} ORDER BY last_seen_at DESC",
                params,
            )
        ).fetchall()
        sessions = []
        for r in rows:
            # 目前活躍中的房間身分（display_name 就是這個 session 在房內的名字）
            proom = await (
                await db.execute(
                    "SELECT p.display_name, p.room_id, ro.name AS room_name"
                    " FROM participant p JOIN room ro ON ro.id=p.room_id"
                    " WHERE p.session_key=? AND p.status='active'"
                    " ORDER BY p.last_seen_at DESC",
                    (r["session_key"],),
                )
            ).fetchall()
            last_name = None
            if not proom:
                # 不在任何房內時，用最近一次的房內名稱幫助辨識
                prev = await (
                    await db.execute(
                        "SELECT display_name FROM participant WHERE session_key=?"
                        " ORDER BY last_seen_at DESC LIMIT 1",
                        (r["session_key"],),
                    )
                ).fetchone()
                last_name = prev["display_name"] if prev else None
            sessions.append({
                "session_key": r["session_key"],
                "kind": r["kind"],
                "label": r["label"],
                # 邀請 UI 靠它認人：共用一把 token 時 Hub 眼中所有人長得一樣。
                # **僅供辨識**——來源可能經 X-Forwarded-For 而來，不可拿來授權
                "last_ip": r["last_ip"],
                # 指派 UI 靠它分組（本機／其他裝置）。自報的值，僅供辨識
                "host": r["host"],
                "status": "active" if r["last_seen_at"] >= active_cutoff else "idle",
                "first_seen_at": r["first_seen_at"],
                "last_seen_at": r["last_seen_at"],
                "rooms": [
                    {"room_id": p["room_id"], "room_name": p["room_name"],
                     "display_name": p["display_name"]}
                    for p in proom
                ],
                "last_display_name": last_name,
            })
        return {"sessions": sessions}

    # ---------- 存取 token（邀請人進 Hub） ----------

    def _token_public(row) -> dict:
        d = dict(row)
        d["revoked"] = d.get("revoked_at") is not None
        return d

    @app.post("/api/tokens", dependencies=[Depends(require_auth)])
    async def create_token(body: TokenCreate, request: Request):
        """發一張新的存取 token，用來邀請一個人進這台 Hub。

        回傳的 token 明碼只在這裡與 GET /api/tokens 看得到——這是刻意的：
        邀請連結會過期（quick tunnel 每次重啟換網址），要能重新產生一份給
        對方，不然每次都得重發一張、舊的還得記得撤掉。
        """
        require_root(request)
        if not cfg.api_token:
            # 沒設主 token 時整台 Hub 本來就沒有門，再發邀請只是製造安全感
            raise _err(409, "auth_disabled",
                       "這台 Hub 未設定 token（完全開放），不需要也不能發邀請")
        token = uuid.uuid4().hex + uuid.uuid4().hex
        db = app.state.db
        await db.execute(
            "INSERT INTO access_token (token, label, created_at) VALUES (?,?,?)",
            (token, body.label.strip(), _now()),
        )
        await db.commit()
        return {"token": token, "label": body.label.strip()}

    @app.get("/api/tokens", dependencies=[Depends(require_auth)])
    async def list_tokens(request: Request, include_revoked: bool = False):
        """已發出的邀請 token。撤銷過的預設不列，但查得到——誰被收回權限
        是要留紀錄的事。"""
        require_root(request)
        db = app.state.db
        cond = "" if include_revoked else " WHERE revoked_at IS NULL"
        rows = await (
            await db.execute(
                f"SELECT * FROM access_token{cond} ORDER BY created_at DESC"
            )
        ).fetchall()
        return {"tokens": [_token_public(r) for r in rows]}

    @app.delete("/api/tokens/{token}", dependencies=[Depends(require_auth)])
    async def revoke_token(token: str, request: Request):
        """撤銷一張 token。

        不刪列而是標記 revoked_at：刪掉之後就查不到「這個人曾經有權限」，
        而那正是事後要回答的問題。
        """
        require_root(request)
        db = app.state.db
        cur = await db.execute(
            "UPDATE access_token SET revoked_at=? WHERE token=? AND revoked_at IS NULL"
            " RETURNING token",
            (_now(), token),
        )
        if await cur.fetchone() is None:
            raise _err(404, "token_not_found", "找不到這張 token，或它已經被撤銷")
        await db.commit()
        return {"ok": True}

    # ---------- WebSocket（UI 即時通道） ----------

    @app.websocket("/ws")
    async def ws_endpoint(ws: WebSocket):
        """UI 即時通道。

        客戶端指令（JSON）：
            {"type": "subscribe", "room_id": "...", "after_seq": 0,
             "participant_id": "..."}
            {"type": "unsubscribe", "room_id": "..."}
            {"type": "ping"}
        伺服器事件：
            {"type": "messages", "room_id", "room_status", "messages": [...]}
            {"type": "questions", "room_id", "questions": [...]}
            {"type": "pong"}

        ``participant_id`` 選填，帶了才會收到 ``questions``——提問是定向的，
        只推給被問的那個人。沒帶就只是個看訊息的連線。
        """
        if cfg.api_token and ws.query_params.get("token") != cfg.api_token:
            logger.info("ws: 拒絕連線（token 驗證失敗）")
            await ws.close(code=4401)
            return
        await ws.accept()
        logger.info("ws: 連線建立")
        db = app.state.db
        send_lock = asyncio.Lock()  # 多房間 pump 併發送出時避免交錯
        pumps: dict[str, asyncio.Task] = {}
        # room_id → 建立該 pump 時用的 participant_id，用來判斷 re-subscribe
        # 是不是換了身分（換了就要重建，見下方 subscribe 分支）
        pump_ids: dict[str, str] = {}

        async def push_questions(room_id: str, participant_id: str, seen: set) -> set:
            """把指派給這個人的待答問題推過去；集合沒變就不送，避免無謂重畫。"""
            rows = await (
                await db.execute(
                    "SELECT q.*, p.display_name AS asker_name FROM question q"
                    " LEFT JOIN participant p ON p.id=q.asker_id"
                    " WHERE q.room_id=? AND q.target_id=? AND q.status='pending'"
                    # 過期的不推：卡片要從 UI 上消失，而集合一變就會重送，
                    # 所以「不在這批裡」本身就是移除訊號
                    " AND (q.expires_at IS NULL OR q.expires_at > ?)"
                    " ORDER BY q.created_at",
                    (room_id, participant_id, _now()),
                )
            ).fetchall()
            current = {r["id"] for r in rows}
            if current == seen:
                return seen
            async with send_lock:
                await ws.send_json({
                    "type": "questions", "room_id": room_id,
                    "questions": [_question_public(r) for r in rows],
                })
            return current

        async def pump(room_id: str, after_seq: int, participant_id: str = "") -> None:
            last = after_seq
            seen_questions: set = set()
            if participant_id:
                # 訂閱當下就先送一次：問題可能在連線之前就問了，等下一個事件
                # 才推的話，重開 App 會看不到已經在等的問題
                seen_questions = await push_questions(
                    room_id, participant_id, {"__unset__"}
                )
            while True:
                if participant_id:
                    seen_questions = await push_questions(
                        room_id, participant_id, seen_questions
                    )
                rows = await (
                    await db.execute(
                        "SELECT * FROM message WHERE room_id=?"
                        " AND MAX(seq, update_seq)>?"
                        " ORDER BY MAX(seq, update_seq) LIMIT ?",
                        (room_id, last, cfg.updates_batch_limit),
                    )
                ).fetchall()
                if rows:
                    msgs = await _message_rows_to_json(rows, db)
                    last = max(max(m["seq"], m["update_seq"]) for m in msgs)
                    room = await (
                        await db.execute(
                            "SELECT status FROM room WHERE id=?", (room_id,)
                        )
                    ).fetchone()
                    async with send_lock:
                        await ws.send_json({
                            "type": "messages", "room_id": room_id,
                            "room_status": room["status"] if room else None,
                            "messages": msgs,
                        })
                else:
                    await events.wait(room_id, 30.0)

        try:
            while True:
                data = await ws.receive_json()
                kind = data.get("type")
                if kind == "subscribe":
                    rid = data["room_id"]
                    pid = str(data.get("participant_id") or "")
                    # 這條是 App 的主要讀取通道：REST 收緊了而這裡沒收，
                    # 被踢的人照樣即時收得到整個房間，等於白做
                    try:
                        await _member_or_403(rid, pid)
                    except HTTPException as exc:
                        detail = exc.detail
                        async with send_lock:
                            await ws.send_json({
                                "type": "error", "room_id": rid,
                                "code": detail.get("code") if isinstance(detail, dict)
                                        else "not_a_member",
                                "message": detail.get("message") if isinstance(detail, dict)
                                           else "你不是這個聊天室的成員",
                            })
                        # 身分失效時要把既有 pump 一起收掉——訂閱是在還有效的
                        # 時候建立的，被踢之後它會繼續推送
                        if rid in pumps:
                            pumps.pop(rid).cancel()
                            pump_ids.pop(rid, None)
                        continue
                    # 身分是 join 之後才拿得到的，client 因此會在同一個房間上
                    # 再 subscribe 一次來補帶 participant_id。只看「有沒有
                    # pump」的話那次會被整個忽略，而既有 pump 是用空身分建的
                    # ——結果就是首次進房的人永遠收不到定向問題，直到重連。
                    if rid in pumps and pump_ids.get(rid, "") != pid:
                        pumps.pop(rid).cancel()
                    if rid not in pumps:
                        pump_ids[rid] = pid
                        pumps[rid] = asyncio.create_task(
                            pump(rid, int(data.get("after_seq", 0)), pid)
                        )
                elif kind == "unsubscribe":
                    rid = data.get("room_id", "")
                    pump_ids.pop(rid, None)
                    task = pumps.pop(rid, None)
                    if task:
                        task.cancel()
                elif kind == "ping":
                    async with send_lock:
                        await ws.send_json({"type": "pong"})
        except WebSocketDisconnect:
            pass
        finally:
            logger.info("ws: 連線結束，清理 %d 個房間訂閱", len(pumps))
            for task in pumps.values():
                task.cancel()

    # ---------- Presence sweeper ----------

    async def _sweep_once() -> None:
        """單輪掃描：移除閒置 agent、過期 pending 指派與提問、封存無 agent 房間。"""
        db = app.state.db
        # 通知受影響的房間：client 靠這個把待答卡片收掉
        for rid in await _expire_questions():
            await events.notify(rid)
        now = datetime.now(timezone.utc)
        cutoff = (now - timedelta(seconds=cfg.idle_timeout)).isoformat()
        idle = await (
            await db.execute(
                # session_key 給日誌用：事後要回答「被移出的是哪一個 session」
                "SELECT id, room_id, display_name, session_key FROM participant"
                " WHERE status='active' AND role='agent' AND last_seen_at < ?",
                (cutoff,),
            )
        ).fetchall()
        for p in idle:
            await db.execute(
                "UPDATE participant SET status='removed', left_at=? WHERE id=?",
                (_now(), p["id"]),
            )
            await db.commit()
            logger.info(
                "sweep: 移除閒置 agent %s（room=%s）",
                p["display_name"], p["room_id"], extra={
                    "event": "idle_removed", "room_id": p["room_id"],
                    "participant_id": p["id"], "display_name": p["display_name"],
                    "session_key": p["session_key"],
                },
            )
            await _post_message(
                p["room_id"], None,
                f"{p['display_name']} 因閒置逾時被移出聊天室", kind="system",
                system_event="idle_removed",
            )
        # 過期 pending 指派
        a_cutoff = (now - timedelta(seconds=cfg.assignment_ttl)).isoformat()
        await db.execute(
            "UPDATE assignment SET status='expired', resolved_at=?"
            " WHERE status='pending' AND created_at < ?",
            (_now(), a_cutoff),
        )
        await db.commit()
        # 封存：active 房間中已無任何 active agent，且 active 人類不超過一人
        # ——兩個以上的人類仍在對話時，agent 離場不該把房間收走。
        # 只計入「本次 active 期間（activated_at 之後）」加入過的 agent，
        # 否則解封後會因舊成員紀錄被 sweeper 立刻封回去
        empty = await (
            await db.execute(
                "SELECT r.id, r.archive_pending_since FROM room r"
                " WHERE r.status='active'"
                " AND EXISTS (SELECT 1 FROM participant p WHERE p.room_id=r.id"
                "             AND p.role='agent'"
                "             AND p.joined_at >= COALESCE(r.activated_at, r.created_at))"
                " AND NOT EXISTS (SELECT 1 FROM participant p WHERE p.room_id=r.id"
                "                 AND p.role='agent' AND p.status='active')"
                " AND (SELECT COUNT(*) FROM participant p WHERE p.room_id=r.id"
                "      AND p.role='human' AND p.status='active') <= 1",
            )
        ).fetchall()
        # 封存走倒數而非立即執行：條件首次成立時起算，期間有人（agent）
        # 回來就取消。踢人、agent 短暫斷線都不該讓房間瞬間消失。
        matched_ids = set()
        for r in empty:
            matched_ids.add(r["id"])
            pending = r["archive_pending_since"]
            if pending is None:
                await db.execute(
                    "UPDATE room SET archive_pending_since=? WHERE id=?",
                    (now.isoformat(), r["id"]),
                )
                await db.commit()
                await _post_message(
                    r["id"], None,
                    f"聊天室內已無 agent，將於 {int(cfg.archive_grace)} 秒後自動封存",
                    kind="system", system_event="archive_pending",
                )
            elif (now - datetime.fromisoformat(pending)).total_seconds() >= (
                cfg.archive_grace
            ):
                logger.info("sweep: 自動封存房間 %s", r["id"])
                await _archive(r["id"], "聊天室內已無 agent，自動封存")
        # 條件已解除的房間取消倒數
        stale = await (
            await db.execute(
                "SELECT id FROM room WHERE status='active'"
                " AND archive_pending_since IS NOT NULL",
            )
        ).fetchall()
        for r in stale:
            if r["id"] not in matched_ids:
                await db.execute(
                    "UPDATE room SET archive_pending_since=NULL WHERE id=?",
                    (r["id"],),
                )
        await db.commit()

    async def _sweeper() -> None:
        while True:
            await asyncio.sleep(cfg.sweep_interval)
            try:
                await _sweep_once()
            except Exception:  # sweeper 絕不因單次錯誤而死
                logger.exception("sweeper 單輪執行失敗，下一輪續行")

    app.state.sweep_once = _sweep_once  # 測試可直接觸發單輪掃描

    @app.get("/api/health")
    async def health():
        # App 啟動時拿這裡的 build 與自己的比對：版本對不上要當場講出來，
        # 而不是等使用者發現「說好做完的功能不在畫面上」
        return {
            "ok": True, "version": app.version,
            "build": build_info(),
            "idle_timeout_seconds": cfg.idle_timeout,
            "max_attachment_bytes": cfg.max_attachment_bytes,
        }

    return app
