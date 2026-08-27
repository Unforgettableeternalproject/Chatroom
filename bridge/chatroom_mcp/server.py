"""Chatroom MCP Bridge（stdio）。

薄殼：把 Hub 的 REST API 包成 MCP 工具，不含任何業務邏輯。
設定來源（環境變數）：
    CHATROOM_URL          Hub 位址，預設 http://127.0.0.1:8787
    CHATROOM_TOKEN        API token（Hub 未設 token 時可省略）
    CHATROOM_SESSION_KEY  本 agent 的 session 識別；未設定時自動生成並
                          存於 ~/.chatroom/session_key 以求跨次穩定

participant_id 是「每房間」的身分：join 後由 bridge 記在記憶體，
工具呼叫時依 room_id 自動帶上。
"""

import os
import uuid
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP

HUB_URL = os.environ.get("CHATROOM_URL", "http://127.0.0.1:8787")
TOKEN = os.environ.get("CHATROOM_TOKEN", "")


def _session_key() -> str:
    env = os.environ.get("CHATROOM_SESSION_KEY")
    if env:
        return env
    keyfile = Path.home() / ".chatroom" / "session_key"
    if keyfile.exists():
        return keyfile.read_text().strip()
    keyfile.parent.mkdir(parents=True, exist_ok=True)
    key = uuid.uuid4().hex
    keyfile.write_text(key)
    return key


SESSION_KEY = _session_key()
AGENT_KIND = os.environ.get("CHATROOM_AGENT_KIND", "other")

mcp = FastMCP("chatroom")
# room_id -> participant_id（本進程生命週期內的房間身分）
_identities: dict[str, str] = {}


def _client(room_id: str | None = None) -> httpx.Client:
    headers = {}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if room_id and room_id in _identities:
        headers["X-Participant-Id"] = _identities[room_id]
    return httpx.Client(base_url=HUB_URL, headers=headers, timeout=60.0)


@mcp.tool()
def chatroom_list_rooms() -> dict:
    """列出所有 active 聊天室，以及指派給你（本 session）的 pending 邀請。"""
    with _client() as c:
        r = c.get("/api/rooms", params={"session_key": SESSION_KEY})
        r.raise_for_status()
        return r.json()


@mcp.tool()
def chatroom_join(room_id: str, preferred_name: str = "") -> dict:
    """加入聊天室。可提供偏好名稱；房內重名時會自動調整。回傳你被指派的名字。"""
    with _client() as c:
        r = c.post(
            f"/api/rooms/{room_id}/join",
            json={
                "kind": AGENT_KIND,
                "session_key": SESSION_KEY,
                "preferred_name": preferred_name or None,
                "role": "agent",
            },
        )
        r.raise_for_status()
        data = r.json()
        _identities[room_id] = data["participant_id"]
        return data


@mcp.tool()
def chatroom_leave(room_id: str) -> dict:
    """離開聊天室。"""
    with _client(room_id) as c:
        r = c.post(f"/api/rooms/{room_id}/leave")
        r.raise_for_status()
        _identities.pop(room_id, None)
        return r.json()


@mcp.tool()
def chatroom_read(room_id: str, after_seq: int = 0, limit: int = 100,
                  pinned_only: bool = False) -> dict:
    """讀取聊天室訊息。after_seq 是上次讀到的序號（增量讀取）；pinned_only 只看釘選。"""
    with _client(room_id) as c:
        r = c.get(
            f"/api/rooms/{room_id}/messages",
            params={"after_seq": after_seq, "limit": limit, "pinned_only": pinned_only},
        )
        r.raise_for_status()
        return r.json()


@mcp.tool()
def chatroom_post(room_id: str, content: str, mentions: list[str] | None = None,
                  reply_to: str = "") -> dict:
    """發布訊息。mentions 填 display_name 列表可 ping 指定成員；reply_to 填要回覆的訊息 id。"""
    with _client(room_id) as c:
        r = c.post(
            f"/api/rooms/{room_id}/messages",
            json={"content": content, "mentions": mentions or [],
                  "reply_to": reply_to or None},
        )
        r.raise_for_status()
        return r.json()


@mcp.tool()
def chatroom_wait(room_id: str, after_seq: int, timeout: float = 25.0) -> dict:
    """等待新訊息（long-poll）。有新訊息立即返回；you_were_mentioned 表示有人 ping 你。"""
    with _client(room_id) as c:
        r = c.get(
            f"/api/rooms/{room_id}/updates",
            params={"after_seq": after_seq, "timeout": timeout},
        )
        r.raise_for_status()
        return r.json()


@mcp.tool()
def chatroom_pin(room_id: str, message_id: str) -> dict:
    """釘選一則訊息。"""
    with _client(room_id) as c:
        r = c.post(f"/api/messages/{message_id}/pin")
        r.raise_for_status()
        return r.json()


@mcp.tool()
def chatroom_unpin(room_id: str, message_id: str) -> dict:
    """取消釘選。"""
    with _client(room_id) as c:
        r = c.delete(f"/api/messages/{message_id}/pin")
        r.raise_for_status()
        return r.json()


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
