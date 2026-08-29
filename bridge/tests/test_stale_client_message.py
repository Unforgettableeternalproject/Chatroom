"""client 比 Hub 舊時，錯誤訊息不可以把人送進無效迴圈。

外部測試端實測到的完整迴圈（2026-08-29，舊 kit × 新 Hub）：

    chatroom_get_file  → {"need_rejoin": true, "請先用 chatroom_join 加入"}
    chatroom_join      → {"ok": true, "rejoined": true}   ← 他本來就是成員
    chatroom_get_file  → 同一句錯誤訊息

Hub 那層講得很清楚（「不是你不是成員，是還不知道你是誰」），但 bridge 把它
翻譯成「請先 join」——而 join 完全不會解決問題，因為真正的原因是這條路徑
沒帶身分標頭，跟有沒有 join 無關。

**一個正確的診斷訊息，在往上傳遞的過程中被劣化成誤導訊息。** Hub 端修得
再好，只要中間層自己造一句話覆蓋它，使用者拿到的還是錯的。
"""

import pytest

from chatroom_mcp import server
from chatroom_mcp.hub import HubError
from chatroom_mcp.state import BridgeState

ROOM = "room-1"
HEADER_REQUIRED = {"code": "participant_header_required",
                   "message": "請求沒有帶 X-Participant-Id。"}


class _RaisingHub:
    base_url = "http://hub.test"

    def __init__(self, detail, status=401):
        self.detail = detail
        self.status = status
        self.calls = 0

    def request(self, *a, **kw):
        self.calls += 1
        raise HubError("原始訊息", status=self.status, detail=self.detail,
                       identity_invalid=True)


@pytest.fixture
def joined(tmp_path):
    """一個「已經是成員」的 bridge——迴圈只在這個前提下成立。"""
    st = BridgeState(tmp_path / "state.json")
    st.set_identity(ROOM, participant_id="p1", display_name="我")
    server.configure(bridge_state=st)
    yield st
    server.configure(bridge_state=None)


def _run(hub_stub):
    server._hub = hub_stub
    try:
        with pytest.raises(HubError) as caught:
            server._room_request(ROOM, "GET", "/api/whatever")
        return caught.value
    finally:
        server._hub = None


def test_does_not_tell_a_member_to_rejoin(joined):
    """「請先 join」對一個已經是成員的人是無效指令，照做一次就繞回原點。"""
    err = _run(_RaisingHub(HEADER_REQUIRED))

    assert "chatroom_join" not in err.reason
    assert not err.identity_invalid  # → 不會冒出 need_rejoin
    assert "不會解決" in err.reason


def test_says_the_actual_cause(joined):
    """訊息要指向真正該做的事：升級 kit。"""
    err = _run(_RaisingHub(HEADER_REQUIRED))

    assert "更新" in err.reason or "版本" in err.reason
    # 附上查 Hub 版本的方法——「我該升到哪一版」是下一個必然的問題
    assert "/api/health" in err.reason


def test_keeps_the_local_identity(joined):
    """清掉身分會讓下一次呼叫變成「你還沒有身分」，把版本問題偽裝成身分問題。"""
    _run(_RaisingHub(HEADER_REQUIRED))

    assert joined.participant_id(ROOM) == "p1"


def test_real_identity_failures_still_clear_and_ask_for_rejoin(joined):
    """修掉誤判不能順手把真陽性關掉：跨房盜用仍要清身分並要求重新 join。"""
    wrong_room = {"code": "participant_wrong_room", "message": "不屬於此房"}
    err = _run(_RaisingHub(wrong_room, status=403))

    assert err.identity_invalid
    assert joined.participant_id(ROOM) is None


def test_without_local_identity_the_join_advice_is_correct(tmp_path):
    """真的還沒 join 時，「請先 join」才是對的——那條路不可以被這次修正擋掉。"""
    st = BridgeState(tmp_path / "state.json")
    server.configure(bridge_state=st)
    try:
        with pytest.raises(HubError) as caught:
            server._room_request(ROOM, "GET", "/api/whatever")
        assert "chatroom_join" in caught.value.reason
        assert caught.value.identity_invalid
    finally:
        server.configure(bridge_state=None)
