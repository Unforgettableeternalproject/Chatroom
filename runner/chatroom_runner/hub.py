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

    def to_dict(self) -> dict:
        return {"runner_id": self.runner_id, "runner_token": self.runner_token,
                "active_run_ids": list(self.active_run_ids)}


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
        active_run_ids=[str(x) for x in raw.get("active_run_ids", []) if x])


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
                       max_parallel: int, version: str) -> dict:
        """註冊。同 host+label 冪等；Hub 只在**建立那一次**回 ``runner_token``。

        回來若帶 token 就存進本機狀態檔——下一次啟動沒有它就註冊不回去。
        """
        body = await self._json(
            "POST", "/api/runners/register",
            json_body={"host": host, "label": label, "projects": projects,
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
                        command_acks: list[dict] | None = None) -> dict:
        """心跳。``command_acks`` 是上一輪取走的命令生效了沒（§5.7）。"""
        return await self._json(
            "POST", f"/api/runners/{self.identity.runner_id}/heartbeat",
            json_body={"status": status, "running_count": running_count,
                       "limited_until": limited_until,
                       "limit_reason": limit_reason,
                       "dashboard_json": dashboard,
                       "usage_window_json": usage_window,
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

    async def report(self, run_id: str, status: str, *, result: str = "",
                     reason: str = "", claude_session_id: str = "",
                     usage: dict | None = None) -> dict | None:
        """回報狀態轉移。``runner_id`` 是**必填**（Hub 契約 09/16 修正）。

        🚨 409 ``run_bad_transition`` 當成「這一步已經套用過」而不是錯誤：
        回報遲到或重送時，Hub 那邊的狀態早就是我們要的那個了，把它當失敗
        重試會變成無限迴圈，而那台執行器同時什麼單都不領。
        """
        payload: dict = {"status": status, "runner_id": self.identity.runner_id,
                         "result": result, "reason": reason,
                         "claude_session_id": claude_session_id}
        if usage is not None:
            payload["usage_json"] = usage
        try:
            return await self._json("POST", f"/api/runs/{run_id}/report",
                                    json_body=payload)
        except HubError as exc:
            if exc.status == 409 and exc.code == "run_bad_transition":
                detail = exc.detail if isinstance(exc.detail, dict) else {}
                # 回傳值照舊（當成已套用），但**要留痕**：真正的非法轉移與
                # 「遲到的重送」長得一模一樣，無聲吞掉的話只剩 Hub 上一個停住
                # 的狀態，沒有任何線索指向是哪一步被擋掉
                log.warning("回報被 Hub 擋下（409 run_bad_transition）："
                            "run %s 想報 %s，Hub 說 %s → %s",
                            run_id, status, detail.get("from_status"),
                            detail.get("to_status"))
                return None
            raise
