"""執行器對 Hub 的 REST 客戶端（REMOTE-OPS-PLAN §4.3／§5.1）。

憑證有**兩把**，位置與 bridge 一致：

- ``Authorization: Bearer <CHATROOM_TOKEN>``：Hub 的 agent 憑證，所有請求都帶。
- ``X-Runner-Token: <runner_token>``：註冊那一次 Hub 回的執行器專屬 token，
  之後 heartbeat／claim／report 一律要帶。它存在本機狀態檔，不進版控、不印進
  log——那把 token 等於「我就是那台執行器」。

錯誤一律收斂成 :class:`HubError`（帶 ``code``），由呼叫端決定怎麼處置。
沿用 bridge 的判準：**以機器可讀的 ``code`` 為準**，不比對訊息字串。
"""

from __future__ import annotations

import json
import logging
import os
import stat
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

DEFAULT_TIMEOUT = 30.0

log = logging.getLogger(__name__)


class HubError(Exception):
    def __init__(self, reason: str, *, status: int | None = None,
                 code: str = "", detail: Any = None) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status = status
        self.code = code
        self.detail = detail


@dataclass
class RunnerIdentity:
    """本機狀態檔的內容：我是哪一台、我的 token 是什麼。"""

    runner_id: str = ""
    runner_token: str = ""
    # 這台執行器現在手上有哪幾筆 run。**進程死了它們還在檔案裡**——啟動對帳
    # 靠的就是這份清單：Hub 上還是 running、本機卻沒有對應進程的，就是上一次
    # 崩潰留下的孤兒。沒有它，那筆 run 會永遠停在 running 而沒有人收
    active_run_ids: list[str] = field(default_factory=list)
    # 最後一次做維護窗重啟的**本地日期**（``YYYY-MM-DD``）。一定要落地：只記在
    # 記憶體裡的話，維護窗重啟回來的進程看到的是一張白紙，於是「現在還在維護
    # 窗裡」→ 再退一次，整個小時每分鐘被排程工作拉起來一次
    last_maintenance_day: str = ""

    def to_dict(self) -> dict:
        return {"runner_id": self.runner_id, "runner_token": self.runner_token,
                "active_run_ids": list(self.active_run_ids),
                "last_maintenance_day": self.last_maintenance_day}


def load_identity(path: Path) -> RunnerIdentity:
    if not path.is_file():
        return RunnerIdentity()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return RunnerIdentity()
    return RunnerIdentity(
        runner_id=raw.get("runner_id", "") or "",
        runner_token=raw.get("runner_token", "") or "",
        active_run_ids=[str(x) for x in raw.get("active_run_ids", []) if x],
        last_maintenance_day=str(raw.get("last_maintenance_day", "") or ""))


def save_identity(path: Path, identity: RunnerIdentity) -> None:
    """寫狀態檔，權限收到只剩擁有者。

    ⚠️ 先寫暫存再 ``replace``：直接覆寫的話，寫到一半斷電會留下一個合法 JSON
    以外的東西，而下次啟動只會看到「沒有 token」然後去重新註冊——那時 Hub
    會用 403 擋下來（`runner_token_required`），人在遠端看到的是一台再也註冊
    不回去的執行器。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(identity.to_dict(), ensure_ascii=False,
                              indent=2), encoding="utf-8")
    try:
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:  # pragma: no cover - 平台不支援就算了，內容照寫
        pass
    tmp.replace(path)


def _detail_of(response: httpx.Response) -> Any:
    try:
        body = response.json()
    except ValueError:
        return response.text
    return body.get("detail") if isinstance(body, dict) else body


def translate(status: int, detail: Any) -> HubError:
    code = detail.get("code") if isinstance(detail, dict) else ""
    msg = (detail.get("message") if isinstance(detail, dict)
           else str(detail or ""))
    if status == 401:
        return HubError(
            "Hub 拒絕了這次請求（token 無效或未設定）。確認設定檔的"
            " agent_token 與 Hub 的 CHATROOM_TOKEN 一致。",
            status=status, code=code or "invalid_token", detail=detail)
    if status == 403 and code == "runner_token_required":
        return HubError(
            "這台主機與 label 已經註冊過，重註冊要帶原本的 runner_token。"
            "本機狀態檔可能被刪了——請主持人在 Hub 端 rotate 一次。",
            status=status, code=code, detail=detail)
    if status == 403 and code == "runner_token_invalid":
        return HubError(
            "runner_token 不被接受：這台執行器的憑證已失效或被換掉了。",
            status=status, code=code, detail=detail)
    return HubError(msg or f"Hub 回傳 HTTP {status}",
                    status=status, code=code or "", detail=detail)


def bad_transition_from(exc: HubError) -> str | None:
    """這個錯誤是 409 ``run_bad_transition`` 嗎；是的話 Hub 現在在哪一格。

    回 ``None`` 表示「不是這種錯」。Hub 一定會帶 ``from_status``（兩條 raise
    都帶），但**帶不到時回空字串而不是 None**：那時只知道被狀態機擋下，不
    知道擋在哪裡，由呼叫端當成「不可判斷」處理。
    """
    if exc.status != 409 or exc.code != "run_bad_transition":
        return None
    detail = exc.detail if isinstance(exc.detail, dict) else {}
    return str(detail.get("from_status") or "")


class RunnerHub:
    """薄客戶端。``client`` 供測試注入 in-process ASGI transport。"""

    def __init__(self, base_url: str, token: str,
                 identity: RunnerIdentity | None = None,
                 client: httpx.AsyncClient | None = None,
                 timeout: float = DEFAULT_TIMEOUT) -> None:
        self.base_url = base_url
        self.token = token
        self.identity = identity or RunnerIdentity()
        self.timeout = timeout
        self._client = client
        self._owns_client = client is None

    async def __aenter__(self) -> "RunnerHub":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        if self._owns_client and self._client is not None:
            await self._client.aclose()
            self._client = None

    def _ensure(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(base_url=self.base_url,
                                             timeout=self.timeout)
        return self._client

    def _headers(self, *, with_runner_token: bool = True) -> dict[str, str]:
        headers: dict[str, str] = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if with_runner_token and self.identity.runner_token:
            headers["X-Runner-Token"] = self.identity.runner_token
        return headers

    async def _request(self, method: str, path: str, *,
                       json_body: dict | None = None,
                       with_runner_token: bool = True) -> httpx.Response:
        client = self._ensure()
        try:
            return await client.request(method, path, json=json_body,
                                        headers=self._headers(
                                            with_runner_token=with_runner_token))
        except httpx.TimeoutException as exc:
            raise HubError(f"連線 Hub（{self.base_url}）逾時。",
                           code="timeout") from exc
        except httpx.HTTPError as exc:
            raise HubError(
                f"無法連線到 Hub（{self.base_url}）："
                f"{exc.__class__.__name__}。", code="unreachable") from exc

    async def _json(self, method: str, path: str, *,
                    json_body: dict | None = None,
                    with_runner_token: bool = True) -> Any:
        resp = await self._request(method, path, json_body=json_body,
                                   with_runner_token=with_runner_token)
        if resp.status_code >= 400:
            raise translate(resp.status_code, _detail_of(resp))
        if resp.status_code == 204 or not resp.content:
            return None
        try:
            return resp.json()
        except ValueError as exc:
            raise HubError("Hub 回應不是合法的 JSON，版本可能不相容。",
                           code="bad_json") from exc

    # ---------- 端點 ----------

    async def register(self, host: str, label: str, projects: list[str],
                       max_parallel: int, version: str,
                       private_projects: list[str] | None = None) -> dict:
        """註冊。同 host+label 冪等；Hub 只在**建立那一次**回 ``runner_token``。

        🚨 跨界：``projects`` 是 **Hub 語意**的專案白名單，內容是本機的
        **工作區 key**（見 `config.public_project_keys`）。Hub／DB／bridge
        的欄位名沒有跟著本機改名，這裡送的形狀不變。

        ``private_projects`` 是沒標公開的工作區 key，形狀與 ``projects``
        一樣、內容互斥。私人工作區只能被私人房派工，那條規則在 Hub——本機
        照樣執行收到的每一筆派工，不重複判斷。

        回來若帶 token 就存進本機狀態檔——下一次啟動沒有它就註冊不回去。
        """
        body = await self._json(
            "POST", "/api/runners/register",
            json_body={"host": host, "label": label, "projects": projects,
                       "private_projects": list(private_projects or []),
                       "max_parallel": max_parallel, "version": version})
        runner = body["runner"]
        self.identity.runner_id = runner["id"]
        token = body.get("runner_token") or ""
        if token:
            self.identity.runner_token = token
        return body

    async def heartbeat(self, status: str, running_count: int,
                        dashboard: dict, usage_window: dict,
                        limited_until: str | None = None,
                        limit_reason: str = "",
                        command_acks: list[dict] | None = None,
                        private_projects: list[str] | None = None) -> dict:
        """心跳。``command_acks`` 是上一輪取走的命令生效了沒（§5.7）。

        ``private_projects`` 跟著每一次心跳送：私人工作區只能被私人房派工，
        規則在 Hub，這裡只負責把清單講清楚。公開清單仍只在 register 送
        （形狀不變），reload 之後靠重新註冊補報。
        """
        return await self._json(
            "POST", f"/api/runners/{self.identity.runner_id}/heartbeat",
            json_body={"status": status, "running_count": running_count,
                       "limited_until": limited_until,
                       "limit_reason": limit_reason,
                       "dashboard_json": dashboard,
                       "usage_window_json": usage_window,
                       "private_projects": list(private_projects or []),
                       "command_acks": list(command_acks or [])})

    async def get_run(self, run_id: str) -> dict | None:
        """查一筆 run 的現況（啟動對帳用）。查不到／讀不到權限回 ``None``。

        `GET /api/runs/{id}` 的門檻是「房內成員或主持人視角」，而執行器不是
        任何一間房的成員——所以要帶 `X-Host-View: 1`。那個標頭只有配上 Hub
        的主 token 才成立（見 `app.host_view`），token 不對就是 403，這裡把它
        當成「這次對不了帳」而不是錯誤：對不到帳比啟動不了好。
        """
        client = self._ensure()
        headers = self._headers(with_runner_token=False)
        headers["X-Host-View"] = "1"
        try:
            resp = await client.request("GET", f"/api/runs/{run_id}",
                                        headers=headers)
        except httpx.HTTPError as exc:
            raise HubError(f"查 run {run_id} 失敗：{exc.__class__.__name__}",
                           code="unreachable") from exc
        if resp.status_code in (403, 404):
            return None
        if resp.status_code >= 400:
            raise translate(resp.status_code, _detail_of(resp))
        try:
            return resp.json().get("run")
        except ValueError as exc:
            raise HubError("Hub 回應不是合法的 JSON，版本可能不相容。",
                           code="bad_json") from exc

    async def claim(self) -> dict | None:
        """領一筆單。沒單可領 Hub 回 204 ⇒ 這裡回 ``None``。"""
        body = await self._json(
            "POST", f"/api/runners/{self.identity.runner_id}/claim")
        return body["run"] if body else None

    async def _post_report(self, run_id: str, status: str, *,
                           result: str = "", reason: str = "",
                           claude_session_id: str = "",
                           usage: dict | None = None,
                           stalled_seconds: int = 0,
                           git: dict | None = None) -> dict | None:
        payload: dict = {"status": status, "runner_id": self.identity.runner_id,
                         "result": result, "reason": reason,
                         "claude_session_id": claude_session_id}
        # 同狀態回報（stalled）用；其餘回報送 0，Hub 忽略它。舊 Hub 收到
        # 多出來的欄位不會炸（pydantic 預設忽略未知欄位）
        if stalled_seconds:
            payload["stalled_seconds"] = stalled_seconds
        if usage is not None:
            payload["usage_json"] = usage
        # 結構化的 git 欄位（契約 C3）。**沒有 repo 的 run 不送這一鍵**：
        # 送一組空字串進去，Hub 會把它當成「這一輪什麼都沒動」寫進欄位，
        # 而那與「這筆 run 根本沒有 repo」不是同一件事。舊 Hub 收到多出來
        # 的欄位不會炸（pydantic 預設忽略未知欄位）
        if git:
            payload["git"] = git
        return await self._json("POST", f"/api/runs/{run_id}/report",
                                json_body=payload)

    async def report(self, run_id: str, status: str, *, result: str = "",
                     reason: str = "", claude_session_id: str = "",
                     usage: dict | None = None,
                     stalled_seconds: int = 0,
                     git: dict | None = None) -> dict | None:
        """回報狀態轉移。``runner_id`` 是**必填**（Hub 契約 09/16 修正）。

        409 ``run_bad_transition`` 有三種，**不能混成同一種**（審查 09/22）：

        1. ``from_status == status``：Hub 已經在我們要報的那一格 ⇒ 這是遲到
           或重送的回報，當成「已套用」回 ``None``。把它當失敗重試會變成無限
           迴圈，而那台執行器在重試期間什麼單都不領。
        2. ``from_status == "claimed"`` 而我們要報的不是 ``running``：中間那
           一步（``claimed → running``）在斷線期間重試耗盡掉了，Hub 於是擋下
           終局回報。**先補送一次 ``running`` 再重送原本的回報**，只補一次、
           不遞迴。全部當成冪等成功的話，這筆 run 會永遠停在 claimed，而這一
           輪的結果沒有任何地方留得下來。
        3. 其他：真正的非法轉移（例如 Hub 那邊已經 cancelled）。往上丟，讓
           呼叫端的重試與落地機制接手——吞掉它等於把結果丟進黑洞。

        補送用的理由是 ``resumed``：Hub 真的已經在 running 時，那是同狀態回報
        的白名單理由，不會再撞一次 409。
        """
        kwargs = {"result": result, "reason": reason,
                  "claude_session_id": claude_session_id, "usage": usage,
                  "stalled_seconds": stalled_seconds, "git": git}
        try:
            return await self._post_report(run_id, status, **kwargs)
        except HubError as exc:
            from_status = bad_transition_from(exc)
            if from_status is None:
                raise
            if from_status == status:
                log.warning("回報被 Hub 擋下（409 run_bad_transition）："
                            "run %s 想報 %s，Hub 已經在 %s ⇒ 當成已套用",
                            run_id, status, from_status)
                return None
            if from_status != "claimed" or status == "running":
                log.error("回報被 Hub 擋下（409 run_bad_transition）："
                          "run %s 想報 %s，Hub 說 %s ⇒ 這是真的非法轉移，"
                          "往上丟給重試／落地", run_id, status, from_status)
                raise
        # claimed → 終局：先補上漏掉的 running 那一步，再重送一次原回報
        log.warning("run %s 要報 %s，但 Hub 還停在 claimed："
                    "`claimed → running` 那一次回報掉了，先補送一次 running",
                    run_id, status)
        await self._post_report(
            run_id, "running", reason="resumed",
            claude_session_id=claude_session_id,
            result="執行器補送：`claimed → running` 的回報在斷線期間掉了，"
                   "這一筆是為了讓終局回報接得上。")
        try:
            return await self._post_report(run_id, status, **kwargs)
        except HubError as exc:
            from_status = bad_transition_from(exc)
            if from_status is not None and from_status == status:
                log.warning("run %s 補送 running 後重送 %s：Hub 已經在 %s",
                            run_id, status, from_status)
                return None
            raise
