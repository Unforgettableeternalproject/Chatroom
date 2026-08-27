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
