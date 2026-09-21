"""Hub client 的憑證與錯誤語意（契約修正 09/16）。

四條契約，每一條都對應一個「看起來正常、實際上錯」的狀態：

1. 註冊回的 `runner_token` 要落地，之後每個請求都帶 `X-Runner-Token`。
2. `report` 的 `runner_id` 必填——沒帶的話 Hub 認不出是誰在收工。
3. claim 的 204 是「沒事做」，不是錯誤。
4. `run_bad_transition` 有三種，不能混成同一種（審查 09/22）：Hub 已經在
   我們要報的那一格＝已套用；卡在 `claimed`＝中間那一步掉了，補送再重送；
   其餘是真的非法轉移，要往上丟。
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


async def test_register_and_heartbeat_carry_the_private_project_list():
    """私人工作區走 `private_projects`，**不進 `projects`**。

    兩份清單互斥：混在一起的話 Hub 沒辦法擋「公開房派私人工作區」，而
    那個錯誤在派工對話框上看起來完全正常。
    """
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        if request.url.path == "/api/runners/register":
            return httpx.Response(200, json={"runner": {"id": "run-1"},
                                             "created": True})
        return httpx.Response(200, json={"runner_id": "run-1",
                                         "commands": [],
                                         "cancel_requested_run_ids": []})

    hub = _hub(handler, RunnerIdentity("run-1", "secret-1"))
    await hub.register("host", "label", ["open"], 3, "0.1",
                       private_projects=["secret"])
    assert bodies[0]["projects"] == ["open"]
    assert bodies[0]["private_projects"] == ["secret"]

    await hub.heartbeat("online", 0, {}, {}, private_projects=["secret"])
    assert bodies[1]["private_projects"] == ["secret"]
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


def _bad_transition(from_status: str, to_status: str) -> httpx.Response:
    return httpx.Response(
        409, json={"detail": {"code": "run_bad_transition",
                              "message": f"派工不能從 {from_status} 變成"
                                         f" {to_status}。",
                              "from_status": from_status,
                              "to_status": to_status}})


async def test_bad_transition_on_report_is_treated_as_already_applied():
    """🚨 遲到的回報不是錯誤——**但只有 Hub 已經在那一格時才是**。

    重試那一步只會再撞一次同一個 409，而執行器在重試迴圈裡的那段時間
    什麼單都不領——一個已經成功的回報就這樣把整台機器停住。
    """
    hub = _hub(lambda request: _bad_transition("done", "done"),
               RunnerIdentity("run-1", "secret-1"))
    assert await hub.report("r-1", "done") is None
    await hub.aclose()


async def test_stuck_at_claimed_resends_running_then_the_final_report():
    """🚨 卡在 `claimed` 的終局回報要補一步，不能當成冪等成功。

    `claimed → running` 那次回報在斷線期間重試耗盡掉了，於是 Hub 擋下
    `claimed → done`。把它吞成「已套用」的話，這筆 run 永遠停在 claimed，
    而這一輪的結果沒有任何地方留得下來。
    """
    sent: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        sent.append(body)
        if body["status"] == "running":
            return httpx.Response(200, json={"run": {"status": "running"},
                                             "child_run": None})
        if len([b for b in sent if b["status"] == "running"]) == 0:
            return _bad_transition("claimed", body["status"])
        return httpx.Response(200, json={"run": {"status": body["status"]},
                                         "child_run": None})

    hub = _hub(handler, RunnerIdentity("run-1", "secret-1"))

    body = await hub.report("r-1", "done", result="做完了")

    assert body is not None, "補送之後的重送結果被丟掉了"
    assert [b["status"] for b in sent] == ["done", "running", "done"]
    # 補送的那一筆用 `resumed`：Hub 真的已經在 running 時那是同狀態白名單
    assert sent[1]["reason"] == "resumed"
    # 原本的回報內容要原樣重送，不能只補一個空殼
    assert sent[2]["result"] == "做完了"
    await hub.aclose()


async def test_bad_transition_from_another_status_still_raises():
    """其他來源狀態＝真的非法轉移：往上丟，讓重試與落地機制接手。

    吞掉它等於把這一輪的結果丟進黑洞——落地檔是最後一道防線。
    """
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(json.loads(request.content)["status"])
        return _bad_transition("cancelled", "done")

    hub = _hub(handler, RunnerIdentity("run-1", "secret-1"))
    with pytest.raises(HubError) as exc:
        await hub.report("r-1", "done")
    assert exc.value.code == "run_bad_transition"
    assert calls == ["done"], "非法轉移不該再補送 running"
    await hub.aclose()


async def test_claimed_recovery_gives_up_after_one_retry():
    """補送只補一次。第二次還是被擋就往上丟，不遞迴。"""
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        status = json.loads(request.content)["status"]
        calls.append(status)
        if status == "running":
            return httpx.Response(200, json={"run": {"status": "running"},
                                             "child_run": None})
        if calls.count("done") == 1:
            return _bad_transition("claimed", status)
        # 補送之後那筆 run 已經被人類取消了：第二次擋下就是真的走不通
        return _bad_transition("cancelled", status)

    hub = _hub(handler, RunnerIdentity("run-1", "secret-1"))
    with pytest.raises(HubError):
        await hub.report("r-1", "done")
    assert calls == ["done", "running", "done"]
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
