"""Chatroom 通知 watcher（常駐進程）。

把 Hub 的更新變成「每行一個事件」的 stdout 串流，讓外部機制接手通知：

- **Claude Code**：用 Monitor 掛載（persistent），每行輸出即時變成一次通知，
  agent 不必卡在 chatroom_wait 也能被喚醒，且可反覆觸發::

      Monitor(command=".venv/Scripts/python.exe bridge/chatroom_mcp/watch.py --kind claude --room <id>",
              persistent=true, description="chatroom 通知")

- **Codex**：沒有自掛機制，改由 watcher 反向推——`--codex-thread <uuid>` 把
  每個事件經 `codex queue` 注入既有 session（閒置 session 會立即處理，
  2026-08-28 實測）。也可前景執行 --max-events 1 當同步 wait::

      watch.py --kind codex --codex-thread <uuid>

`--kind` 決定身分怎麼解析，**必須由呼叫端顯式給**，不能靠共用的 .env 補：
一份檔只填得下一個 kind，填 claude 時同機的 Codex watcher 會沿用
CLAUDE_CODE_SESSION_ID，直接與母 Claude session 撞成同一個 participant。

事件格式（一行一個 JSON 物件）：

    {"event": "message", "room_id": ..., "seq": ..., "sender": ...,
     "preview": ..., "mentioned": true/false, "pinned": ..., "deleted": ...}
    {"event": "assignment", "assignment_id": ..., "room_id": ...,
     "room_name": ..., "note": ...}
    {"event": "member_joined", "room_id": ..., "seq": ..., "who": ...}
    {"event": "member_left", "room_id": ..., "seq": ..., "who": ...,
     "reason": "left|kicked|idle_removed"}
    {"event": "departure", "room_id": ..., "reason": "kicked|idle|left|archived",
     "message": ..., "rejoinable": true/false}   # 之後進程退出
    {"event": "watch_ended", "reason": "..."}    # 之後進程退出

``departure`` 是「這個房間對你已經結束了」的明確訊號：被管理員踢出、閒置逾時
被移除、或房間封存。agent 收到後應該停掉這個房間的監看——沒有它的話 watcher
只會以一句含糊的 watch_ended 收場，agent 分不出是自己該退場還是 Hub 出問題，
於是監看常常就一直掛著空轉。``rejoinable`` 直接說明能不能自己加回去
（被踢是人為決定，不該自己推翻）。

預設行為刻意收斂雜訊——每個事件都會喚醒 agent 一次，喚醒必須值得：

- **只有被 @mention 的訊息**才發 message 事件（指派事件不受此限）；
  其餘訊息留給 agent 用 chatroom_read / chatroom_wait 自己撈（游標保證不漏）
- **system 訊息**不發 message 事件；但**有人進出**會發獨立的
  ``member_joined`` / ``member_left``（誰在房裡是該知道的事，且一個房間不會
  一直有人進出，不構成噪音）。不想要就加 ``--no-join-events``

  離場一定要跟進場成對。只推進場的話，每個 agent 心裡的成員名單只增不減，
  越待越失真——然後就會 @ 到一個已經不在的人，而那個 mention 不會有人收到
  （2026-08-29 實測：房內兩次離場，旁觀者一次都沒被告知）
- **自己發的訊息**不發事件
- **既有訊息的狀態變更**（釘選/軟刪除）不發事件——釘選牆是「額外可撈」
  的東西（chatroom_read pinned_only），不是喚醒的理由

要每則訊息都喚醒（舊行為）用 ``--all-messages``。

身分解析與 bridge 主體共用（identity.session_key）：同一個 session 的
watcher 與 MCP bridge 是同一把 session_key，指派與 mention 才對得上人。
讀 bridge 的 state 檔取得 participant_id 與游標，但**絕不寫入**——
游標推進是 chatroom_read/chatroom_wait 的職責，watcher 搶著推會讓 agent 漏讀。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "chatroom_mcp"

from . import identity  # noqa: E402
from .envfile import load_env_file  # noqa: E402
from .hub import HubClient, HubError  # noqa: E402

# Windows 主控台預設 cp950，事件含中文或特殊字元會直接 UnicodeEncodeError。
# stderr 一併處理——所有 [watch] 診斷訊息都是中文，只轉 stdout 的話那些訊息
# 會以 cp950 寫出，emoji 退化成 \uXXXX 字面，讀 log 的人看到的是亂碼。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

PREVIEW_LEN = 160
TRANSIENT_RETRY_SECS = 5.0

# 離場原因 → 能不能自己加回去。被踢是人為決定，agent 自己 rejoin 等於推翻它。
REJOINABLE = {"idle": True, "left": True, "kicked": False, "archived": False}

# Hub 的 system_event → 對外的離場理由。
# 看 system_event 欄位而不是比對中文內容：內容改一個字就會無聲失效，而那種
# 失效在這裡完全看不出來（事件單純不再發出，沒有錯誤）。
DEPARTURE_EVENTS = {
    "leave": "left",
    "kick": "kicked",
    "idle_removed": "idle_removed",
}

# 指派輪詢與 long-poll 分屬兩條執行緒，輸出要串行化才不會交錯成半行 JSON
_emit_lock = threading.Lock()


def _emit(event: dict[str, Any]) -> None:
    line = json.dumps(event, ensure_ascii=False)
    with _emit_lock:
        print(line, flush=True)


def _log(msg: str) -> None:
    print(f"[watch] {msg}", file=sys.stderr, flush=True)


def _who_joined(content: str) -> str:
    """從加入訊息取出名字。只在 sender_name 缺席（舊版 Hub）時的退路。"""
    name, _, tail = content.partition(" 加入了")
    return name if tail else content


def _who_left(sender_name: Any, content: str) -> str:
    """從離場訊息取出名字。

    離場的三種 system 訊息（leave / kick / idle_removed）在 Hub 都以
    ``sender_id=None`` 發出，所以 ``sender_name`` 是空的，只能從內容取。

    但**不比對整句措辭**——那三句話各不相同（「離開了」「已被管理員移出」
    「因閒置逾時被移出」），逐句比對等於把三份中文文案變成契約，改一個字
    就無聲失效。這裡只依賴一個假設：**名字在最前面，後面接一個空白**。
    三句話共用這個形狀，未來新增第四種離場也多半照樣成立。
    """
    if isinstance(sender_name, str) and sender_name:
        return sender_name
    head = content.split(" ", 1)[0]
    return head or content


def _preview(content: str) -> str:
    flat = " ".join(content.split())
    if len(flat) > PREVIEW_LEN:
        return flat[: PREVIEW_LEN - 1] + "…"
    return flat


def _resolve_codex_argv() -> list[str]:
    """找出可直接 spawn 的 codex 呼叫方式（不經過 shell）。

    Windows 上 `codex` 是 npm shim（.cmd），子進程執行 .cmd 必須經過 cmd.exe，
    而事件內容（聊天訊息）是不可信輸入，經 cmd 轉義等於開命令注入面。
    改抓 shim 同目錄的 node.exe + codex.js 直接執行，全程 argv 傳遞、零 shell。
    """
    exe = shutil.which("codex")
    if not exe:
        raise SystemExit("[watch] 找不到 codex CLI，--codex-thread 無法使用")
    path = Path(exe)
    if os.name == "nt" and path.suffix.lower() != ".exe":
        base = path.parent
        js = base / "node_modules" / "@openai" / "codex" / "bin" / "codex.js"
        if js.exists():
            node = base / "node.exe"
            return [str(node) if node.exists() else "node", str(js)]
    return [str(path)]


def _state_candidates(session_key: str) -> list[Path]:
    """可能存放本 session 身分的 state 檔，依可信度排序。

    第一順位是「照 key 算出來的檔名」，其餘是同目錄的其他 state 檔——因為
    **檔名不是權威**，內容裡的 ``session_key`` 才是。
    """
    mine = identity.state_path(session_key)
    paths = [mine]
    for folder in {mine.parent, Path.home() / ".chatroom"}:
        try:
            paths.extend(sorted(folder.glob("state-*.json")))
        except OSError:
            continue
    seen: set[Path] = set()
    ordered: list[Path] = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            ordered.append(path)
    return ordered


def _entry_of(path: Path, room_id: str) -> tuple[str | None, dict]:
    """讀一個 state 檔，回傳 (檔案自報的 session_key, 該房的 entry)。"""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None, {}
    if not isinstance(raw, dict):
        return None, {}
    key = raw.get("session_key")
    entry = (raw.get("rooms") or {}).get(room_id) or {}
    return (key if isinstance(key, str) else None,
            entry if isinstance(entry, dict) else {})


def _read_bridge_state(session_key: str, room_id: str) -> tuple[str | None, str | None, int]:
    """從 bridge state 檔讀 (participant_id, display_name, last_seq)。唯讀。

    **依內容而不是依檔名認檔。** 檔名由 bridge 進程啟動當下的 key 決定，但
    房內身分可以在那之後被改寫：用 ``assignment_id`` 加入時，Hub 會回一把
    canonical session_key，bridge 把它寫進檔案內容，檔名卻還是舊的
    （2026-08-29 實測）。照檔名去找的人於是撲空——讀不到 display_name 就
    判不出訊息有沒有 @ 到自己，**一則 mention 事件都不會發，而且不報錯**。
    """
    for path in _state_candidates(session_key):
        key, entry = _entry_of(path, room_id)
        # 別的 key 的檔案：那是別人的身分，不能撿來用
        if key is not None and key != session_key:
            continue
        pid = entry.get("participant_id")
        if not isinstance(pid, str):
            continue
        name = entry.get("display_name")
        seq = entry.get("last_seq", 0)
        return (
            pid,
            name if isinstance(name, str) else None,
            seq if isinstance(seq, int) and not isinstance(seq, bool) else 0,
        )
    return None, None, 0


def _sibling_states(session_key: str, room_id: str) -> list[tuple[str, str]]:
    """同機**其他** session_key 的 state 檔中，在指定房間持有身分的那些。

    這是身分分裂的精確證據：別把 key 在這個房有 participant_id、我這把沒有。
    分裂的成因是 bridge 與 watcher 拿到不同的 session id——`/clear` 會換掉
    ``CLAUDE_CODE_SESSION_ID``，而 MCP bridge 是既有進程、沿用舊值，Monitor
    新拉的 watcher 則拿到新值，兩邊從此分家（2026-08-29 實測）。
    """
    mine = identity.state_path(session_key)
    found: list[tuple[str, str]] = []
    for path in _state_candidates(session_key):
        if path == mine:
            continue
        key, entry = _entry_of(path, room_id)
        # 自報 key 與我相同的檔案不是「別把 key」——那是同一個身分寫在另一個
        # 檔名底下（_read_bridge_state 已經會撿它），列進來會把「檔案位置對不上」
        # 誤報成「身分分裂」，而兩者的處置完全不同
        if key == session_key:
            continue
        if entry.get("participant_id"):
            found.append((str(key or path.name),
                          str(entry.get("display_name") or "（無名稱）")))
    return found


class Watcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.session_key = identity.session_key()
        self.hub = HubClient()
        self.room_id: str | None = args.room
        self.participant_id: str | None = None
        self.display_name: str | None = None
        self.after_seq = 0
        if self.room_id:
            pid, name, state_seq = _read_bridge_state(self.session_key, self.room_id)
            self.participant_id, self.display_name = pid, name
            self.after_seq = args.after_seq if args.after_seq is not None else state_seq
        self.seen_assignments: set[str] = set()
        self.last_heartbeat = 0.0
        self.emitted = 0
        self.departed = False
        self._stop = threading.Event()
        self._warned_no_name = False
        # Codex 沒有 Monitor 那種自掛機制，只能反向推：事件經 codex queue
        # 注入其 session（前提：該 thread 已有至少一輪對話，否則 queue 讀不到）
        self.codex_argv = _resolve_codex_argv() if args.codex_thread else None

    # ---------- 各事件來源 ----------

    def poll_room(self) -> None:
        assert self.room_id
        if self.participant_id is None or self.display_name is None:
            # bridge 可能在 watcher 啟動後才 join——每輪補讀身分（游標不動，
            # 起始游標在 __init__ 已定案，中途改會漏或重看）
            pid, name, _ = _read_bridge_state(self.session_key, self.room_id)
            self.participant_id = self.participant_id or pid
            self.display_name = self.display_name or name
        prev = self.after_seq
        data = self.hub.request(
            "GET",
            f"/api/rooms/{self.room_id}/updates",
            participant_id=self.participant_id,
            params={"after_seq": self.after_seq, "timeout": self.args.poll_timeout},
            timeout=self.args.poll_timeout + 10.0,
        )
        last = data.get("last_seq")
        if isinstance(last, int):
            self.after_seq = max(self.after_seq, last)
        # 封存不會讓成員身分失效（封存房仍可讀），所以不看這個欄位的話
        # watcher 會對著一個已經結束的房間空轉到天荒地老
        status = data.get("room_status")
        if isinstance(status, str) and status != "active":
            self.depart("archived", f"聊天室已{'封存' if status == 'archived' else status}")
            return
        for m in data.get("messages", []):
            seq = m.get("seq")
            if isinstance(seq, int) and seq <= prev:
                # 既有訊息的狀態變更（釘選/軟刪除領 update_seq 重新入流）
                # 不喚醒——釘選牆用 chatroom_read(pinned_only) 主動撈
                continue
            if m.get("sender_id") and m["sender_id"] == self.participant_id:
                continue  # 自己發的不用叫醒自己（加入通知也掛著發送者）
            if m.get("kind") == "system":
                # 型別看 system_event 欄位，不比對中文內容——內容改一個字
                # 就會無聲失效，而那種失效在這裡完全看不出來
                event = m.get("system_event")
                if event == "join" and self.args.join_events:
                    self.emit({
                        "event": "member_joined",
                        "room_id": self.room_id,
                        "seq": m.get("seq"),
                        "who": m.get("sender_name") or _who_joined(
                            m.get("content", "")
                        ),
                    })
                elif event in DEPARTURE_EVENTS and self.args.join_events:
                    # 與 member_joined 共用 --no-join-events：進出是同一件事的
                    # 兩面，只關掉一邊會留下比完全不通知更糟的狀態——名單看起來
                    # 在維護，實際上只增不減
                    self.emit({
                        "event": "member_left",
                        "room_id": self.room_id,
                        "seq": m.get("seq"),
                        "who": _who_left(m.get("sender_name"),
                                         m.get("content", "")),
                        "reason": DEPARTURE_EVENTS[event],
                    })
                if not self.args.include_system:
                    continue
            mentioned = bool(
                self.display_name and self.display_name in (m.get("mentions") or [])
            )
            if not self.args.all_messages and not mentioned:
                if self.display_name is None and not self._warned_no_name:
                    # 為什麼沒有名字，preflight 已經查過並講清楚了；這裡只補上
                    # 「所以現在會怎樣」，不要再猜一次原因誤導排查方向
                    _log(
                        "state 無 display_name——判不出訊息有沒有 @ 到自己，"
                        "因此不會發出任何訊息事件（原因見啟動時的自檢結果）。"
                        "想全收可加 --all-messages"
                    )
                    self._warned_no_name = True
                continue
            self.emit(
                {
                    "event": "message",
                    "room_id": self.room_id,
                    "seq": m.get("seq"),
                    "sender": m.get("sender_name"),
                    "preview": _preview(m.get("content", "")),
                    "mentioned": mentioned,
                    "pinned": m.get("pinned", False),
                    "deleted": m.get("deleted", False),
                }
            )

    def poll_assignments(self) -> None:
        # kind/label 一併自報：這條輪詢是 Hub session 名錄（指派 UI 掃描
        # 來源）的主要心跳，watcher 掛著時 session 就會顯示為 active
        params = {"session_key": self.session_key, "kind": identity.agent_kind()}
        label = os.environ.get("CHATROOM_DEFAULT_NAME", "")
        if label:
            params["label"] = label
        data = self.hub.request("GET", "/api/assignments", params=params)
        for a in data.get("assignments", []):
            aid = a.get("id")
            if not aid or aid in self.seen_assignments:
                continue
            self.seen_assignments.add(aid)
            event = {
                "event": "assignment",
                "assignment_id": aid,
                "room_id": a.get("room_id"),
                "room_name": a.get("room_name"),
                "note": _preview(a.get("note") or ""),
            }
            if a.get("assigned_name"):
                event["assigned_name"] = a["assigned_name"]
            self.emit(event)

    def maybe_heartbeat(self) -> None:
        """掛著聽卻被 presence sweeper 當閒置踢出去就本末倒置了——定期報平安。"""
        if not (self.room_id and self.participant_id and self.args.heartbeat > 0):
            return
        now = time.monotonic()
        if now - self.last_heartbeat < self.args.heartbeat:
            return
        try:
            self.hub.request(
                "POST",
                f"/api/rooms/{self.room_id}/heartbeat",
                participant_id=self.participant_id,
            )
            self.last_heartbeat = now
        except HubError as exc:
            _log(f"heartbeat 失敗：{exc.reason}")
            if exc.departure:
                # 這裡常是最早看到離場的地方——heartbeat 週期通常比 long-poll
                # 的一輪還短。吞掉的話要等下一次 poll_room 才發得出事件。
                self.depart(exc.departure, exc.reason)
            elif exc.identity_invalid:
                # 身分失效但原因不明（舊版 Hub）：訊息還讀得到，不讓 watcher 死掉
                self.participant_id = None

    def preflight(self) -> None:
        """啟動自檢：分不出「還沒 join」與「身分分裂」的話，排查會走進死路。

        兩者症狀完全一樣（收不到任何訊息事件），處置卻相反：前者等 bridge join
        就好，後者不論等多久都不會好。舊版只印「尚未 join？」，照它去查的人會
        確認「有 join 啊」然後卡死——而分裂時 bridge 確實 join 成功了，只是寫
        進了另一把 key 的 state 檔。
        """
        if not self.room_id or self.participant_id:
            return
        others = _sibling_states(self.session_key, self.room_id)
        if not others:
            _log(
                "本 watcher 在該房尚無身分。bridge 還沒 join 的話這是正常的，"
                "join 之後會自動生效。"
            )
            return
        listed = "、".join(f"{key}（{name}）" for key, name in others)
        _log(
            "⚠️ session 身分分裂：這個房間的身分掛在另一把 key 底下——\n"
            f"         本 watcher：{self.session_key}\n"
            f"         房內身分在：{listed}\n"
            "         指派與 @mention 都不會觸發，而且不會有任何錯誤訊息。\n"
            "         成因通常是 /clear 或 /resume 換掉了 CLAUDE_CODE_SESSION_ID，"
            "而 MCP bridge 是既有進程、仍持有舊值。\n"
            "         處置：重啟 MCP 讓 bridge 換到新 key（重啟後房內身分會失效，"
            "需重新 chatroom_join），或改用顯式的 CHATROOM_SESSION_KEY 固定兩邊。\n"
            "         注意舊身分會以殭屍成員留在房裡，直到 presence sweeper 清掉。"
        )

    def depart(self, reason: str, message: str) -> None:
        """發出離場事件並標記結束——這個房間對本 watcher 已經沒有事情要做了。"""
        self.emit(
            {
                "event": "departure",
                "room_id": self.room_id,
                "reason": reason,
                "message": message,
                "rejoinable": REJOINABLE.get(reason, True),
            }
        )
        self.departed = True

    def emit(self, event: dict[str, Any]) -> None:
        _emit(event)
        self.emitted += 1
        if self.codex_argv:
            self.dispatch_codex(event)

    def dispatch_codex(self, event: dict[str, Any]) -> None:
        """把事件排入 Codex session 的佇列（外部喚醒，2026-08-28 實測閒置 session
        會立即處理）。失敗只記 stderr 不中斷——通知丟一則不該讓 watcher 死掉。"""
        text = "[chatroom 通知] " + json.dumps(event, ensure_ascii=False)
        argv = [
            *self.codex_argv, "queue",
            "--thread", self.args.codex_thread, "--message", text,
        ]
        try:
            done = subprocess.run(
                argv, capture_output=True, text=True, timeout=30,
                encoding="utf-8", errors="replace",
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            _log(f"codex queue 失敗：{exc}")
            return
        if done.returncode != 0:
            _log(f"codex queue 失敗（exit {done.returncode}）：{done.stderr.strip()}")
        else:
            _log(f"codex queue OK：{done.stdout.strip()}")

    # ---------- 主迴圈 ----------

    def assignment_loop(self) -> None:
        """指派輪詢的獨立執行緒。

        為什麼不留在主迴圈：帶 ``--room`` 時主迴圈是 long-poll，一次掛最多 50 秒，
        指派輪詢排在它後面就得等它回來——房裡越安靜延遲越久，而「剛派完、房裡
        還沒人講話」正是最常見的情境。實測有人因此以為自己派錯了人。
        """
        while not self._stop.is_set():
            try:
                self.poll_assignments()
            except HubError as exc:
                _log(f"指派輪詢暫時失敗，稍後重試：{exc.reason}")
            except Exception:  # 這條執行緒死掉會靜默失去所有指派通知
                _log("指派輪詢發生未預期錯誤，稍後重試")
            self._stop.wait(self.args.idle_interval)

    def run(self) -> int:
        target = self.room_id or "（僅指派）"
        _log(
            f"session_key={self.session_key} room={target} after_seq={self.after_seq}"
        )
        # kind 沒解析出來 = 身分退回隨機 key，與 bridge 分裂成兩個 session：
        # 指派對不上人、讀不到 state 檔就判不出 mention，結果是一個事件都不發。
        # 這種失效完全靜默，不主動喊出來就只能靠人盯著上面那行自己看出異常。
        if identity.agent_kind() == "other" and not os.environ.get(
            "CHATROOM_SESSION_KEY"
        ):
            _log(
                "⚠️ kind=other——身分是隨機 key，與 bridge 對不上，"
                "指派與 @mention 都不會觸發。請補 --kind claude|codex"
            )
        self.preflight()
        # 有 room 時指派輪詢自己一條執行緒，不被 long-poll 擋住
        assignment_thread: threading.Thread | None = None
        if self.args.assignments and self.room_id:
            assignment_thread = threading.Thread(
                target=self.assignment_loop, daemon=True, name="assignments"
            )
            assignment_thread.start()
        try:
            return self._loop()
        finally:
            self._stop.set()
            if assignment_thread:
                assignment_thread.join(timeout=2.0)

    def _loop(self) -> int:
        while True:
            try:
                if self.room_id:
                    self.poll_room()  # long-poll 本身就是節奏來源
                    if self.departed:
                        return 0
                elif self.args.assignments:
                    # 沒有 room 可 long-poll，指派輪詢就是主迴圈本身
                    self.poll_assignments()
                    time.sleep(self.args.idle_interval)
                else:
                    time.sleep(self.args.idle_interval)
                self.maybe_heartbeat()
            except HubError as exc:
                if exc.departure and self.room_id:
                    self.depart(exc.departure, exc.reason)
                    return 0
                if exc.identity_invalid or "找不到" in exc.reason:
                    _emit({"event": "watch_ended", "reason": exc.reason})
                    return 0
                # 暫時性失敗（Hub 重啟、斷網）：stderr 記錄後重試，不發事件
                _log(f"暫時性錯誤，{TRANSIENT_RETRY_SECS:.0f}s 後重試：{exc.reason}")
                time.sleep(TRANSIENT_RETRY_SECS)
            except KeyboardInterrupt:
                return 0
            if self.args.max_events and self.emitted >= self.args.max_events:
                _emit({"event": "watch_ended", "reason": "已達 max-events 上限"})
                return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Chatroom 通知 watcher（常駐）")
    p.add_argument("--room", help="要監看的 room_id；省略時只監看指派")
    p.add_argument(
        "--after-seq", type=int, default=None,
        help="起始游標；預設沿用 bridge state 的讀取游標（唯讀）",
    )
    p.add_argument(
        "--all-messages", action="store_true",
        help="每則訊息都發事件（舊行為）；預設只在被 @mention 時發，"
             "其餘訊息由 agent 用 chatroom_read 自行讀取",
    )
    p.add_argument(
        "--no-join-events", dest="join_events", action="store_false",
        help="有人加入房間時不發 member_joined 事件（預設會發）",
    )
    p.add_argument(
        "--include-system", action="store_true",
        help="連 system 訊息（加入/離開）也發事件；預設略過",
    )
    p.add_argument(
        "--no-assignments", dest="assignments", action="store_false",
        help="不監看指派（預設會一併監看）",
    )
    p.add_argument(
        "--codex-thread",
        help="把每個事件經 `codex queue` 排入指定的 Codex session（外部喚醒）。"
             "該 thread 需已有至少一輪對話。⚠️ Codex 的 session key 已動態化，"
             "此模式無法辨識 Codex 自己的發言（可能被自己喚醒）——app 開著時"
             "優先用 app 內建的 Codex 轉送（有 kind 過濾防迴圈），這裡是備援",
    )
    p.add_argument(
        "--max-events", type=int, default=0,
        help="發出 N 個事件後結束進程（0=不限；Codex 同步等待用 1）",
    )
    p.add_argument(
        "--poll-timeout", type=float, default=50.0,
        help="單次 long-poll 秒數（Hub 上限 55）",
    )
    p.add_argument(
        "--idle-interval", type=float, default=15.0,
        help="沒有 room 可 long-poll 時，指派輪詢的間隔秒數",
    )
    p.add_argument(
        "--heartbeat", type=float, default=600.0,
        help="每 N 秒替已 join 的房間刷 heartbeat（0=關閉）",
    )
    p.add_argument(
        "--kind", choices=["claude", "codex"],
        help="本 watcher 服務的 agent 種類（決定 session 身分怎麼解析）。"
             "省略時取環境變數 CHATROOM_AGENT_KIND。⚠️ 不要靠共用的 .env 補"
             "這個值——一份檔只能填一個 kind，另一種 agent 的 watcher 就會"
             "頂著錯的身分跑（填 claude 時 Codex watcher 會沿用"
             "CLAUDE_CODE_SESSION_ID，直接與母 Claude session 撞 key）",
    )
    p.add_argument(
        "--label",
        help="指派掃描清單上顯示的名稱；省略時取 CHATROOM_DEFAULT_NAME",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    load_env_file()  # 只補缺，不覆寫——所以命令列的顯式值要在它之後才蓋得掉
    args = build_parser().parse_args(argv)
    if args.kind:
        os.environ["CHATROOM_AGENT_KIND"] = args.kind
    if args.label:
        os.environ["CHATROOM_DEFAULT_NAME"] = args.label
    return Watcher(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
