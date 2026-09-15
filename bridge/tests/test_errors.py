"""P2-02：錯誤轉譯——agent 只會看到繁體中文說明，不會看到 traceback。"""

import httpx
import pytest

from chatroom_mcp.hub import HubClient, HubError, translate_status


def _reason(status: int, detail) -> str:
    return translate_status(status, detail, "http://hub.test").reason


def test_invalid_token_mentions_token_setting():
    err = translate_status(401, "invalid token", "http://hub.test")
    assert "token" in err.reason.lower()
    assert "CHATROOM_TOKEN" in err.reason
    assert err.identity_invalid is False


def test_missing_participant_header_asks_to_join():
    err = translate_status(401, "X-Participant-Id header required", "http://hub.test")
    assert "chatroom_join" in err.reason
    assert err.identity_invalid is True


def test_participant_not_active_asks_to_rejoin():
    err = translate_status(403, "participant not active", "http://hub.test")
    assert "身分已失效" in err.reason
    assert "chatroom_join" in err.reason
    assert err.identity_invalid is True


def test_cross_room_participant_has_distinct_message():
    err = translate_status(
        403, "participant does not belong to this room", "http://hub.test"
    )
    assert "不屬於" in err.reason
    assert err.identity_invalid is True


def test_archived_room_is_readonly_message():
    err = translate_status(409, "room is archived", "http://hub.test")
    assert "封存" in err.reason
    assert err.identity_invalid is False


@pytest.mark.parametrize(
    "detail,expected",
    [
        ("room not found", "找不到這個聊天室"),
        ("message not found", "找不到這則訊息"),
        ("assignment not found or already resolved", "找不到這筆指派"),
    ],
)
def test_404_variants(detail, expected):
    assert expected in _reason(404, detail)


def test_422_flattens_validation_detail():
    detail = [{"loc": ["body", "content"], "msg": "field required"}]
    reason = _reason(422, detail)
    assert "body.content" in reason
    assert "field required" in reason


def test_500_points_at_hub_logs():
    assert "Hub 內部發生錯誤" in _reason(500, "boom")


def test_connection_failure_is_readable():
    def handler(request):
        raise httpx.ConnectError("connection refused", request=request)

    client = HubClient(
        base_url="http://hub.test", token="", transport=httpx.MockTransport(handler)
    )
    with pytest.raises(HubError) as exc:
        client.request("GET", "/api/rooms")
    assert "無法連線到 Chatroom Hub" in exc.value.reason
    assert "http://hub.test" in exc.value.reason
    assert exc.value.status is None


def test_timeout_is_readable():
    def handler(request):
        raise httpx.ReadTimeout("too slow", request=request)

    client = HubClient(
        base_url="http://hub.test", token="", transport=httpx.MockTransport(handler)
    )
    with pytest.raises(HubError) as exc:
        client.request("GET", "/api/rooms")
    assert "逾時" in exc.value.reason


def test_non_json_body_is_handled():
    client = HubClient(
        base_url="http://hub.test",
        token="",
        transport=httpx.MockTransport(lambda r: httpx.Response(200, text="<html>")),
    )
    with pytest.raises(HubError) as exc:
        client.request("GET", "/api/rooms")
    assert "JSON" in exc.value.reason


def test_error_body_without_json_still_translates():
    client = HubClient(
        base_url="http://hub.test",
        token="",
        transport=httpx.MockTransport(lambda r: httpx.Response(502, text="bad gateway")),
    )
    with pytest.raises(HubError) as exc:
        client.request("GET", "/api/rooms")
    assert exc.value.status == 502


def test_token_is_sent_as_bearer():
    seen = {}

    def handler(request):
        seen["auth"] = request.headers.get("Authorization")
        seen["pid"] = request.headers.get("X-Participant-Id")
        return httpx.Response(200, json={"ok": True})

    client = HubClient(
        base_url="http://hub.test", token="s3cret", transport=httpx.MockTransport(handler)
    )
    client.request("GET", "/api/rooms", participant_id="pid-1")
    assert seen["auth"] == "Bearer s3cret"
    assert seen["pid"] == "pid-1"


# ---------- 403 不等於身分失效 ----------
#
# 2026-08-30 實測（測試端）：Hub 對私人房回 403 room_is_private 並附正確的
# 中文說明，bridge 卻翻成「你的房間身分已失效，請重新呼叫 chatroom_join」。
# 那個 agent 從沒加入過該房，而被建議去做的正是它剛剛被拒絕的那個呼叫。


def test_private_room_is_not_an_identity_problem():
    err = translate_status(
        403, {"code": "room_is_private", "message": "這是一個私人對話…"},
        "http://hub.test",
    )
    assert err.identity_invalid is False, "重新 join 不會讓私人房變得可加入"
    assert "邀請" in err.reason
    assert "身分已失效" not in err.reason


def test_kicked_from_join_says_do_not_come_back_by_yourself():
    err = translate_status(
        403, {"code": "kicked", "message": "你已被管理員移出此聊天室…"},
        "http://hub.test",
    )
    # 手上的身分沒有失效——是 Hub 根本不讓你取得新的
    assert err.identity_invalid is False
    assert err.departure == "kicked"
    assert "管理員" in err.reason


def test_not_admin_passes_the_hub_message_through():
    err = translate_status(
        403, {"code": "not_admin", "message": "只有聊天室建立者可以變更說話方式"},
        "http://hub.test",
    )
    assert err.identity_invalid is False
    assert "說話方式" in err.reason


def test_unknown_403_stays_conservative_for_rolling_upgrades():
    """沒見過的 code 仍算身分失效——這條**不能**跟著上面幾個一起放寬。

    修 room_is_private 那次差點把 fallback 一起改掉。滾動升級時舊 bridge
    不認得新 Hub 的新 code，只要它仍落在 identity_invalid 這條路徑，舊
    watcher 就會結束進程；放寬的話它會變成退不掉又一直打 Hub 的殭屍。
    誤判一次 agent 的處置，遠比放生一隻殭屍便宜。
    """
    err = translate_status(
        403, {"code": "some_future_rule", "message": "這個房間目前不接受新訊息"},
        "http://hub.test",
    )
    assert err.identity_invalid is True
    assert err.departure is None, "不認得的 code 不得亂猜離場原因"


def test_hub_message_that_already_ends_a_sentence_is_not_double_punctuated():
    """Hub 的 message 自帶句號時，bridge 不要再補一個。

    純外觀，但那兩個點會出現在 agent 讀到的每一則 422／5xx 說明裡
    （2026-09-01 測試端在 board_item_wrong_kind 上看到「要換的是層別。。」）。
    """
    err = translate_status(422, {
        "code": "board_item_wrong_kind",
        "message": "這是 checklist 不是 task，要換的是層別。",
    }, "http://hub.test")
    assert "。。" not in err.reason
    assert err.reason.endswith("層別。")


def test_message_without_punctuation_still_gets_one():
    err = translate_status(422, {"code": "x", "message": "欄位 title 不可為空"},
                           "http://hub.test")
    assert err.reason.endswith("不可為空。")
