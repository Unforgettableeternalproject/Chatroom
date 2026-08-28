"""Chatroom 通知 watcher（常駐進程）。

把 Hub 的更新變成「每行一個事件」的 stdout 串流，讓外部機制接手通知：

- **Claude Code**：用 Monitor 掛載（persistent），每行輸出即時變成一次通知，
  agent 不必卡在 chatroom_wait 也能被喚醒，且可反覆觸發::

      Monitor(command=".venv/Scripts/python.exe bridge/chatroom_mcp/watch.py --room <id>",
              persistent=true, description="chatroom 通知")

- **Codex**：沒有自掛機制，改由 watcher 反向推——`--codex-thread <uuid>` 把
  每個事件經 `codex queue` 注入既有 session（閒置 session 會立即處理，
  2026-08-28 實測）。也可前景執行 --max-events 1 當同步 wait。

事件格式（一行一個 JSON 物件）：

    {"event": "message", "room_id": ..., "seq": ..., "sender": ...,
     "preview": ..., "mentioned": true/false, "pinned": ..., "deleted": ...}
    {"event": "assignment", "assignment_id": ..., "room_id": ...,
     "room_name": ..., "note": ...}
    {"event": "watch_ended", "reason": "..."}    # 之後進程退出

預設行為刻意收斂雜訊：**自己發的訊息**與**system 訊息**（加入/離開）不發事件
——每個事件都會喚醒 agent 一次，喚醒必須值得。

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
import time
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "chatroom_mcp"

from . import identity  # noqa: E402
from .envfile import load_env_file  # noqa: E402
from .hub import HubClient, HubError  # noqa: E402

# Windows 主控台預設 cp950，事件含中文或特殊字元會直接 UnicodeEncodeError
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PREVIEW_LEN = 160
TRANSIENT_RETRY_SECS = 5.0


def _emit(event: dict[str, Any]) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


def _log(msg: str) -> None:
    print(f"[watch] {msg}", file=sys.stderr, flush=True)


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


def _read_bridge_state(session_key: str, room_id: str) -> tuple[str | None, str | None, int]:
    """從 bridge state 檔讀 (participant_id, display_name, last_seq)。唯讀。"""
    path = identity.state_path(session_key)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        entry = raw.get("rooms", {}).get(room_id, {})
        pid = entry.get("participant_id")
        name = entry.get("display_name")
        seq = entry.get("last_seq", 0)
        return (
            pid if isinstance(pid, str) else None,
            name if isinstance(name, str) else None,
            seq if isinstance(seq, int) and not isinstance(seq, bool) else 0,
        )
    except (OSError, ValueError):
        return None, None, 0


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
        # Codex 沒有 Monitor 那種自掛機制，只能反向推：事件經 codex queue
        # 注入其 session（前提：該 thread 已有至少一輪對話，否則 queue 讀不到）
        self.codex_argv = _resolve_codex_argv() if args.codex_thread else None

    # ---------- 各事件來源 ----------

    def poll_room(self) -> None:
        assert self.room_id
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
        for m in data.get("messages", []):
            if m.get("kind") == "system" and not self.args.include_system:
                continue
            if m.get("sender_id") and m["sender_id"] == self.participant_id:
                continue  # 自己發的不用叫醒自己
            mentioned = bool(
                self.display_name and self.display_name in (m.get("mentions") or [])
            )
            if self.args.mentions_only and not mentioned:
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
        data = self.hub.request(
            "GET", "/api/assignments", params={"session_key": self.session_key}
        )
        for a in data.get("assignments", []):
            aid = a.get("id")
            if not aid or aid in self.seen_assignments:
                continue
            self.seen_assignments.add(aid)
            self.emit(
                {
                    "event": "assignment",
                    "assignment_id": aid,
                    "room_id": a.get("room_id"),
                    "room_name": a.get("room_name"),
                    "note": _preview(a.get("note") or ""),
                }
            )

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
            # 身分失效（被踢/房間封存）不值得讓 watcher 死掉——訊息還讀得到
            _log(f"heartbeat 失敗：{exc.reason}")
            if exc.identity_invalid:
                self.participant_id = None

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

    def run(self) -> int:
        target = self.room_id or "（僅指派）"
        _log(
            f"session_key={self.session_key} room={target} after_seq={self.after_seq}"
        )
        while True:
            try:
                if self.room_id:
                    self.poll_room()  # long-poll 本身就是節奏來源
                if self.args.assignments:
                    self.poll_assignments()
                if not self.room_id:
                    time.sleep(self.args.idle_interval)
                self.maybe_heartbeat()
            except HubError as exc:
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
        "--mentions-only", action="store_true",
        help="只在被 @mention 時發事件（需要已 join 過、state 檔有 display_name）",
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
    return p


def main(argv: list[str] | None = None) -> int:
    load_env_file()
    args = build_parser().parse_args(argv)
    return Watcher(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
