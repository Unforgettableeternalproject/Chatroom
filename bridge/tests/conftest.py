"""bridge 單元測試共用夾具。

一律以 ``httpx.MockTransport`` 模擬 Hub，不需要真的啟動伺服器；
狀態檔導到 tmp_path，不碰使用者家目錄。
"""

import os

# 必須在 import chatroom_mcp.server 之前設定：模組載入時會決定 SESSION_KEY，
# 未設定時會在真實家目錄產生 session_key 檔
os.environ.setdefault("CHATROOM_SESSION_KEY", "test-session")
os.environ.setdefault("CHATROOM_AGENT_KIND", "claude")
os.environ.setdefault("CHATROOM_URL", "http://hub.test")

import httpx  # noqa: E402
import pytest  # noqa: E402

from chatroom_mcp import server as srv  # noqa: E402
from chatroom_mcp.hub import HubClient  # noqa: E402
from chatroom_mcp.state import BridgeState  # noqa: E402


class FakeHub:
    """以 (method, path) 註冊回應的極簡假 Hub。"""

    def __init__(self) -> None:
        self.routes: dict[tuple[str, str], object] = {}
        self.calls: list[httpx.Request] = []

    def on(self, method: str, path: str, response) -> None:
        """response 可以是 httpx.Response、可呼叫物件，或會被丟出的例外。"""
        self.routes[(method.upper(), path)] = response

    def json(self, method: str, path: str, payload: dict, status: int = 200) -> None:
        self.on(method, path, httpx.Response(status, json=payload))

    def error(self, method: str, path: str, status: int, detail) -> None:
        self.on(method, path, httpx.Response(status, json={"detail": detail}))

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        key = (request.method, request.url.path)
        route = self.routes.get(key)
        if route is None:
            return httpx.Response(404, json={"detail": "route not registered"})
        if isinstance(route, Exception):
            raise route
        if callable(route):
            return route(request)
        return route

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)


@pytest.fixture
def fake_hub(tmp_path):
    """建立假 Hub 並把 bridge 的相依物件指向它與暫存狀態檔。"""
    hub = FakeHub()
    srv.configure(
        hub_client=HubClient(
            base_url="http://hub.test", token="", transport=hub.transport
        ),
        bridge_state=BridgeState(tmp_path / "state.json"),
    )
    yield hub
    srv.configure(
        hub_client=HubClient(base_url="http://hub.test", token=""),
        bridge_state=BridgeState(tmp_path / "reset.json"),
    )


@pytest.fixture
def bridge_state():
    """取得目前綁定的狀態物件。"""
    return srv.state()
