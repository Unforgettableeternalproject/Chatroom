"""Hub client 的憑證與錯誤語意（契約修正 09/16）。

四條契約，每一條都對應一個「看起來正常、實際上錯」的狀態：

1. 註冊回的 `runner_token` 要落地，之後每個請求都帶 `X-Runner-Token`。
2. `report` 的 `runner_id` 必填——沒帶的話 Hub 認不出是誰在收工。
3. claim 的 204 是「沒事做」，不是錯誤。
4. `run_bad_transition` 是「這一步已經套用過」，不是要重試的失敗。
"""

from __future__ import annotations

import json

import httpx
import pytest

from chatroom_runner.hub import (HubError, RunnerHub, RunnerIdentity,
                                 load_identity, save_identity)


def _hub(handler, identity=None):
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler),
                               base_url="http://hub")
    return RunnerHub("http://hub", "agent-token", identity=identity,
                     client=client)


async def test_register_stores_the_runner_token_and_sends_it_afterwards():
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(dict(request.headers))
        if request.url.path == "/api/runners/register":
            return httpx.Response(200, json={"runner": {"id": "run-1"},
                                             "runner_token": "secret-1",
                                             "created": True})
        return httpx.Response(200, json={"runner_id": "run-1",
                                         "commands": [],
                                         "cancel_requested_run_ids": []})

    hub = _hub(handler)
    await hub.register("host", "label", ["ai-website"], 3, "0.1")
    assert hub.identity.runner_id == "run-1"
    assert hub.identity.runner_token == "secret-1"
    assert "x-runner-token" not in seen[0], "第一次註冊還沒有 token 可帶"

    await hub.heartbeat("online", 0, {}, {})
    assert seen[1]["x-runner-token"] == "secret-1"
    await hub.aclose()


async def test_report_always_carries_runner_id():
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json={"run": {}, "child_run": None})

    hub = _hub(handler, RunnerIdentity("run-1", "secret-1"))
    await hub.report("r-1", "done", result="好了")
    assert bodies[0]["runner_id"] == "run-1"
    await hub.aclose()


async def test_claim_204_means_nothing_to_do():
    hub = _hub(lambda request: httpx.Response(204),
               RunnerIdentity("run-1", "secret-1"))
    assert await hub.claim() is None
    await hub.aclose()


async def test_bad_transition_on_report_is_treated_as_already_applied():
    """🚨 遲到的回報不是錯誤。

    重試那一步只會再撞一次同一個 409，而執行器在重試迴圈裡的那段時間
    什麼單都不領——一個已經成功的回報就這樣把整台機器停住。
    """
    hub = _hub(lambda request: httpx.Response(
        409, json={"detail": {"code": "run_bad_transition",
                              "message": "派工不能從 done 變成 done。"}}),
        RunnerIdentity("run-1", "secret-1"))
    assert await hub.report("r-1", "done") is None
    await hub.aclose()


async def test_other_errors_still_raise():
    hub = _hub(lambda request: httpx.Response(
        403, json={"detail": {"code": "runner_token_invalid",
                              "message": "憑證不對"}}),
        RunnerIdentity("run-1", "bad"))
    with pytest.raises(HubError) as exc:
        await hub.report("r-1", "done")
    assert exc.value.code == "runner_token_invalid"
    await hub.aclose()


def test_identity_round_trip_and_atomic_write(tmp_path):
    path = tmp_path / "state.json"
    assert load_identity(path) == RunnerIdentity()
    save_identity(path, RunnerIdentity("run-1", "secret-1"))
    assert load_identity(path).runner_token == "secret-1"
    # 壞掉的狀態檔不該讓執行器炸在啟動的第一行
    path.write_text("{ 這不是 JSON", encoding="utf-8")
    assert load_identity(path) == RunnerIdentity()


async def test_unreachable_hub_becomes_a_hub_error():
    def handler(request):
        raise httpx.ConnectError("boom", request=request)

    hub = _hub(handler, RunnerIdentity("run-1", "t"))
    with pytest.raises(HubError) as exc:
        await hub.heartbeat("online", 0, {}, {})
    assert exc.value.code == "unreachable"
    await hub.aclose()
