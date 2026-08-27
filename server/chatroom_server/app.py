"""Chatroom Hub — FastAPI 應用本體。

Phase 0 涵蓋：房間 CRUD、加入/退出（唯一命名）、訊息發布/讀取、
釘選、heartbeat、long-poll 通知、指派、presence sweeper 與自動封存。
WebSocket 通道留待 Phase 1（UI 開工前）。
"""

import asyncio
import contextlib
import json
import logging
import uuid
from datetime import datetime, timezone, timedelta

from fastapi import (
    Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect,
)
from pydantic import BaseModel, Field

from .config import Config
from .db import open_db
from .events import RoomEvents
from .naming import generate_name


logger = logging.getLogger("chatroom")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _uid() -> str:
    return uuid.uuid4().hex


def _err(status: int, code: str, message: str) -> HTTPException:
    """機器可讀錯誤：detail 為 {"code", "message"}，code 是穩定契約，
    message 僅供人讀——client 不得對 message 做字串比對。"""
    return HTTPException(status, {"code": code, "message": message})


# ---------- 請求模型 ----------

class RoomCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    topic: str = ""


class JoinRequest(BaseModel):
    kind: str = Field(pattern="^(claude|codex|human|other)$")
    session_key: str = Field(min_length=1, max_length=128)
    preferred_name: str | None = None
    role: str = Field(default="agent", pattern="^(agent|human)$")


class MessagePost(BaseModel):
    content: str = Field(min_length=1, max_length=32768)
    mentions: list[str] = []
    reply_to: str | None = None


class AssignmentCreate(BaseModel):
    target_session_key: str
    note: str = ""


class AssignmentResolve(BaseModel):
    status: str = Field(pattern="^(accepted|declined)$")


# ---------- 應用工廠 ----------

def create_app(config: Config | None = None) -> FastAPI:
    cfg = config or Config()
    logger.setLevel(cfg.log_level.upper())

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI):
        if not cfg.api_token:
            logger.warning("未設定 CHATROOM_TOKEN，API 驗證停用——僅限本機開發使用")
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

    app = FastAPI(title="Chatroom Hub", version="0.1.0", lifespan=lifespan)
    events = RoomEvents()

    async def require_auth(authorization: str | None = Header(default=None)) -> None:
        if not cfg.api_token:
            return
        if authorization != f"Bearer {cfg.api_token}":
            raise _err(401, "invalid_token", "token 無效或未提供")

    # ---------- 內部工具 ----------

    async def _room_or_404(room_id: str, allow_archived: bool = False):
        db = app.state.db
        row = await (await db.execute("SELECT * FROM room WHERE id=?", (room_id,))).fetchone()
        if row is None:
            raise _err(404, "room_not_found", "找不到這個聊天室")
        if not allow_archived and row["status"] != "active":
            raise _err(409, "room_archived", "聊天室已封存，唯讀")
        return row

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

    async def _post_message(
        room_id: str,
        sender_id: str | None,
        content: str,
        kind: str = "chat",
        mentions: list[str] | None = None,
        reply_to: str | None = None,
    ) -> dict:
        db = app.state.db
        # reply 目標必須存在且屬於同一房間，否則會把他房的內容洩進本房時間軸
        if reply_to is not None:
            target = await (
                await db.execute(
                    "SELECT 1 FROM message WHERE id=? AND room_id=?", (reply_to, room_id)
                )
            ).fetchone()
            if target is None:
                raise _err(422, "reply_target_not_found",
                           "reply_to 指向的訊息不存在或不在這個房間")
        # 以 room.next_seq 發放房內序號（單一寫入者事務內遞增，避免併發重號）
        cur = await db.execute(
            "UPDATE room SET next_seq = next_seq + 1 WHERE id=? RETURNING next_seq - 1",
            (room_id,),
        )
        seq = (await cur.fetchone())[0]
        msg_id = _uid()
        await db.execute(
            "INSERT INTO message (id, room_id, seq, sender_id, kind, content, mentions,"
            " reply_to, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (msg_id, room_id, seq, sender_id, kind, content,
             json.dumps(mentions or []), reply_to, _now()),
        )
        await db.commit()
        await events.notify(room_id)
        return {"id": msg_id, "seq": seq}

    async def _message_rows_to_json(rows, db) -> list[dict]:
        out = []
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
            if r["reply_to"]:
                orig = await (
                    await db.execute(
                        "SELECT m.content, m.deleted, p.display_name FROM message m"
                        " LEFT JOIN participant p ON p.id=m.sender_id"
                        " WHERE m.id=? AND m.room_id=?",  # 寫入已驗同房，這裡是縱深防禦
                        (r["reply_to"], r["room_id"]),
                    )
                ).fetchone()
                if orig:
                    reply_preview = {
                        "sender_name": orig["display_name"],
                        "excerpt": "" if orig["deleted"] else orig["content"][:80],
                        "deleted": bool(orig["deleted"]),
                    }
            out.append({
                "id": r["id"], "seq": r["seq"], "update_seq": r["update_seq"],
                "kind": r["kind"],
                "sender_id": r["sender_id"], "sender_name": sender_name,
                "content": "" if r["deleted"] else r["content"],
                "mentions": json.loads(r["mentions"]),
                "reply_to": r["reply_to"], "reply_preview": reply_preview,
                "pinned": bool(r["pinned"]), "deleted": bool(r["deleted"]),
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
        await db.execute(
            "INSERT INTO room (id, name, topic, created_at, activated_at) VALUES (?,?,?,?,?)",
            (room_id, body.name, body.topic, now, now),
        )
        await db.commit()
        return {"id": room_id, "name": body.name, "topic": body.topic, "status": "active"}

    @app.get("/api/rooms", dependencies=[Depends(require_auth)])
    async def list_rooms(status: str = "active", session_key: str | None = None):
        db = app.state.db
        rows = await (
            await db.execute(
                "SELECT r.*,"
                " (SELECT COUNT(*) FROM participant p WHERE p.room_id=r.id"
                "  AND p.status='active') AS member_count,"
                " r.next_seq - 1 AS last_seq,"
                " (SELECT m.created_at FROM message m WHERE m.room_id=r.id"
                "  ORDER BY m.seq DESC LIMIT 1) AS last_activity_at"
                " FROM room r WHERE r.status=?"
                " ORDER BY last_activity_at DESC",
                (status,),
            )
        ).fetchall()
        rooms = [dict(r) for r in rows]
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
    async def get_room(room_id: str):
        room = await _room_or_404(room_id, allow_archived=True)
        db = app.state.db
        members = await (
            await db.execute(
                "SELECT id, kind, display_name, role, status, joined_at, last_seen_at"
                " FROM participant WHERE room_id=? ORDER BY joined_at",
                (room_id,),
            )
        ).fetchall()
        return {"room": dict(room), "participants": [dict(m) for m in members]}

    async def _archive(room_id: str, reason: str) -> None:
        db = app.state.db
        # 先留時間軸標記再封存（封存房唯讀，之後就寫不進去了）
        await _post_message(room_id, None, reason, kind="system")
        await db.execute(
            "UPDATE room SET status='archived', archived_at=? WHERE id=?", (_now(), room_id)
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
            "UPDATE room SET status='active', archived_at=NULL, activated_at=? WHERE id=?",
            (_now(), room_id),
        )
        await db.commit()
        await _post_message(room_id, None, "聊天室已解除封存", kind="system")
        return {"ok": True, "already_active": False}

    # ---------- 成員 ----------

    @app.post("/api/rooms/{room_id}/join", dependencies=[Depends(require_auth)])
    async def join_room(room_id: str, body: JoinRequest):
        await _room_or_404(room_id)
        db = app.state.db
        # 同一 session 已在房內 → 冪等返回既有身分
        existing = await (
            await db.execute(
                "SELECT * FROM participant WHERE room_id=? AND session_key=? AND status='active'",
                (room_id, body.session_key),
            )
        ).fetchone()
        if existing:
            return {"participant_id": existing["id"], "display_name": existing["display_name"],
                    "rejoined": True}

        taken_rows = await (
            await db.execute(
                "SELECT display_name FROM participant WHERE room_id=? AND status='active'",
                (room_id,),
            )
        ).fetchall()
        name = generate_name({r["display_name"] for r in taken_rows}, body.preferred_name)
        pid = _uid()
        now = _now()
        await db.execute(
            "INSERT INTO participant (id, room_id, kind, session_key, display_name, role,"
            " joined_at, last_seen_at) VALUES (?,?,?,?,?,?,?,?)",
            (pid, room_id, body.kind, body.session_key, name, body.role, now, now),
        )
        await db.commit()
        # 有 agent 加入時，若房間曾被指派給這個 session，順手標記完成
        await db.execute(
            "UPDATE assignment SET status='accepted', resolved_at=? WHERE room_id=?"
            " AND target_session_key=? AND status='pending'",
            (now, room_id, body.session_key),
        )
        await db.commit()
        await _post_message(room_id, None, f"{name} 加入了聊天室", kind="system")
        return {"participant_id": pid, "display_name": name, "rejoined": False}

    @app.post("/api/rooms/{room_id}/leave", dependencies=[Depends(require_auth)])
    async def leave_room(room_id: str, x_participant_id: str | None = Header(default=None)):
        # 封存房也允許離開（唯讀例外），故不檢查房間狀態
        p = await _participant(x_participant_id, room_id)
        db = app.state.db
        await db.execute(
            "UPDATE participant SET status='left', left_at=? WHERE id=?", (_now(), p["id"])
        )
        await db.commit()
        await _post_message(room_id, None, f"{p['display_name']} 離開了聊天室", kind="system")
        return {"ok": True}

    @app.post("/api/rooms/{room_id}/heartbeat", dependencies=[Depends(require_auth)])
    async def heartbeat(room_id: str, x_participant_id: str | None = Header(default=None)):
        await _participant(x_participant_id, room_id)
        return {"ok": True}

    # ---------- 訊息 ----------

    @app.post("/api/rooms/{room_id}/messages", dependencies=[Depends(require_auth)])
    async def post_message(
        room_id: str, body: MessagePost, x_participant_id: str | None = Header(default=None)
    ):
        await _room_or_404(room_id)
        p = await _participant(x_participant_id, room_id)
        return await _post_message(
            room_id, p["id"], body.content, mentions=body.mentions, reply_to=body.reply_to
        )

    @app.get("/api/rooms/{room_id}/messages", dependencies=[Depends(require_auth)])
    async def read_messages(
        room_id: str,
        after_seq: int = 0,
        before_seq: int | None = None,
        limit: int = Query(default=100, ge=1, le=500),
        pinned_only: bool = False,
    ):
        """讀訊息。after_seq 正向翻頁（新訊息）、before_seq 反向翻頁（載入歷史），
        兩者互斥；回傳一律以 seq 遞增排列。"""
        await _room_or_404(room_id, allow_archived=True)
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
        out: dict = {"messages": msgs, "has_more": has_more}
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
        """long-poll：有 seq > after_seq 的訊息立即返回，否則掛到 timeout。"""
        await _room_or_404(room_id, allow_archived=True)
        db = app.state.db
        me = None
        if x_participant_id:
            me = await _participant(x_participant_id, room_id)

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
                        "last_seq": max(max(m["seq"], m["update_seq"]) for m in msgs)}
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                return {"messages": [], "you_were_mentioned": False, "last_seq": after_seq}
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
        room_id = await _message_room(message_id)
        await _room_or_404(room_id)  # 封存房唯讀，禁止釘選
        p = await _participant(x_participant_id, room_id)
        db = app.state.db
        await db.execute(
            "UPDATE message SET pinned=1, pinned_by=? WHERE id=?", (p["id"], message_id)
        )
        await _touch_message(message_id, room_id)
        return {"ok": True}

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
        await _room_or_404(room_id)
        db = app.state.db
        aid = _uid()
        await db.execute(
            "INSERT INTO assignment (id, room_id, target_session_key, note, created_at)"
            " VALUES (?,?,?,?,?)",
            (aid, room_id, body.target_session_key, body.note, _now()),
        )
        await db.commit()
        return {"id": aid}

    @app.get("/api/rooms/{room_id}/assignments", dependencies=[Depends(require_auth)])
    async def list_room_assignments(room_id: str):
        """房間視角的指派列表（UI 檢視用，含所有狀態）。"""
        await _room_or_404(room_id, allow_archived=True)
        db = app.state.db
        rows = await (
            await db.execute(
                "SELECT * FROM assignment WHERE room_id=? ORDER BY created_at DESC",
                (room_id,),
            )
        ).fetchall()
        return {"assignments": [dict(r) for r in rows]}

    @app.get("/api/assignments", dependencies=[Depends(require_auth)])
    async def list_assignments(session_key: str):
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

    # ---------- WebSocket（UI 即時通道） ----------

    @app.websocket("/ws")
    async def ws_endpoint(ws: WebSocket):
        """UI 即時通道。

        客戶端指令（JSON）：
            {"type": "subscribe", "room_id": "...", "after_seq": 0}
            {"type": "unsubscribe", "room_id": "..."}
            {"type": "ping"}
        伺服器事件：
            {"type": "messages", "room_id", "room_status", "messages": [...]}
            {"type": "pong"}
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

        async def pump(room_id: str, after_seq: int) -> None:
            last = after_seq
            while True:
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
                    if rid not in pumps:
                        pumps[rid] = asyncio.create_task(
                            pump(rid, int(data.get("after_seq", 0)))
                        )
                elif kind == "unsubscribe":
                    task = pumps.pop(data.get("room_id", ""), None)
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
        """單輪掃描：移除閒置 agent、過期 pending 指派、封存無 agent 房間。"""
        db = app.state.db
        now = datetime.now(timezone.utc)
        cutoff = (now - timedelta(seconds=cfg.idle_timeout)).isoformat()
        idle = await (
            await db.execute(
                "SELECT id, room_id, display_name FROM participant"
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
            logger.info("sweep: 移除閒置 agent %s（room=%s）", p["display_name"], p["room_id"])
            await _post_message(
                p["room_id"], None,
                f"{p['display_name']} 因閒置逾時被移出聊天室", kind="system",
            )
        # 過期 pending 指派
        a_cutoff = (now - timedelta(seconds=cfg.assignment_ttl)).isoformat()
        await db.execute(
            "UPDATE assignment SET status='expired', resolved_at=?"
            " WHERE status='pending' AND created_at < ?",
            (_now(), a_cutoff),
        )
        await db.commit()
        # 封存：active 房間中已無任何 active agent。
        # 只計入「本次 active 期間（activated_at 之後）」加入過的 agent，
        # 否則解封後會因舊成員紀錄被 sweeper 立刻封回去
        empty = await (
            await db.execute(
                "SELECT r.id FROM room r WHERE r.status='active'"
                " AND EXISTS (SELECT 1 FROM participant p WHERE p.room_id=r.id"
                "             AND p.role='agent'"
                "             AND p.joined_at >= COALESCE(r.activated_at, r.created_at))"
                " AND NOT EXISTS (SELECT 1 FROM participant p WHERE p.room_id=r.id"
                "                 AND p.role='agent' AND p.status='active')",
            )
        ).fetchall()
        for r in empty:
            logger.info("sweep: 自動封存房間 %s", r["id"])
            await _archive(r["id"], "聊天室內已無 agent，自動封存")

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
        return {"ok": True, "version": app.version}

    return app
