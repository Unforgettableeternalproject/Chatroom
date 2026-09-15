"""版本識別與結構化日誌。

起因：測試人員手上的產物比程式碼舊 16 小時、中間隔著 17 個 commit，而畫面上
沒有任何線索能發現這件事——版本字串是專案初始化留下的預設值，從沒動過。
最後是靠 exe 的檔案修改日期對不上才起疑的。

這裡釘住三件事：
1. 版本問不到時要**明說 unknown**，不能退回一個好看的預設值
2. Hub 啟動與 /api/health 都要講得出自己是哪一份程式碼
3. 關鍵事件（授權失敗、加入、踢出）要落檔，而且**絕不寫 token 明碼**
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server import version as version_mod
from chatroom_server.app import create_app
from chatroom_server.config import Config
from chatroom_server.logging_setup import token_hint

ROOT = "root-secret"
# ⚠️ **這裡刻意沒有 module 級的 `pytestmark = pytest.mark.asyncio`。**
# `pytest.ini` 已經是 `asyncio_mode = auto`，async 測試會自動被收成 asyncio，
# 那行是多餘的；而它是 module 級的，會連**同步**測試一起標上去，於是每跑一次
# 全套就噴三個 PytestWarning。警告本身無害（那兩條同步測試照樣執行、照樣
# PASSED），但長期掛著的雜訊會讓人看不見真的警告
# （@開發Novia (除錯) 2026-09-03 提出，實測確認不是「被略過」）。


def _cfg(tmp_path, name, token=ROOT):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token=token,
                  log_dir=str(tmp_path / "logs"))


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _log_events(tmp_path):
    """讀回落檔的日誌，一行一個事件。"""
    path = tmp_path / "logs" / "hub.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in
            path.read_text(encoding="utf-8").splitlines() if line.strip()]


def test_unknown_version_says_unknown(tmp_path, monkeypatch):
    """問不到就說問不到。

    「不知道自己是哪一版」與「是 1.0.0 版」是完全不同的兩件事，把前者顯示成
    後者正是這次事故的成因——所以這條測試釘的是「不准偽造」。
    """
    version_mod.build_info.cache_clear()
    monkeypatch.setattr(version_mod, "_from_build_file", lambda: None)
    monkeypatch.setattr(version_mod, "_from_git", lambda: None)
    info = version_mod.build_info()
    assert info["source"] == "unknown"
    assert info["commit"] == ""
    assert "unknown" in version_mod.version_string()
    version_mod.build_info.cache_clear()


def test_build_file_wins_over_git(tmp_path, monkeypatch):
    """交付包裡沒有 .git，版本只能靠打包時寫進去的那份。"""
    version_mod.build_info.cache_clear()
    monkeypatch.setattr(
        version_mod, "_from_build_file",
        lambda: {"version": "1.2.3", "commit": "abcdef123456",
                 "built_at": "2026-08-29T00:00:00+00:00", "source": "build"},
    )
    monkeypatch.setattr(
        version_mod, "_from_git",
        lambda: {"version": "9.9.9", "commit": "zzz", "built_at": "",
                 "source": "git"},
    )
    info = version_mod.build_info()
    assert info["source"] == "build" and info["commit"] == "abcdef123456"
    version_mod.build_info.cache_clear()


async def test_health_reports_which_code_this_is(tmp_path):
    app = create_app(_cfg(tmp_path, "health"))
    async with app.router.lifespan_context(app), AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        build = (await client.get("/api/health")).json()["build"]
        # 欄位齊全比欄位有值重要：App 端要靠它比對，缺欄位就比不了
        assert set(build) == {"version", "commit", "built_at", "source"}


async def test_startup_logs_the_version_first(tmp_path):
    """日誌從哪裡開始看，都要能立刻回答「這是哪一份程式碼」。"""
    app = create_app(_cfg(tmp_path, "startup"))
    async with app.router.lifespan_context(app):
        pass
    events = _log_events(tmp_path)
    startup = [e for e in events if e.get("event") == "startup"]
    assert startup, events
    assert {"version", "commit", "version_source"} <= set(startup[0])


async def test_kick_is_recorded_without_leaking_the_token(tmp_path):
    """🚨 這條是安全條款：日誌會被複製、貼進聊天室、附在 issue 上。"""
    app = create_app(_cfg(tmp_path, "kicklog"))
    async with app.router.lifespan_context(app), AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        guest_token = (await client.post(
            "/api/tokens", headers=_auth(ROOT), json={"label": "訪客"}
        )).json()["token"]
        room_id = (await client.post(
            "/api/rooms", headers=_auth(ROOT),
            json={"name": "房", "session_key": "admin-key"})).json()["id"]
        admin = (await client.post(
            f"/api/rooms/{room_id}/join", headers=_auth(ROOT),
            json={"kind": "human", "session_key": "admin-key",
                  "preferred_name": "Xavier", "role": "human"})).json()
        guest = (await client.post(
            f"/api/rooms/{room_id}/join", headers=_auth(guest_token),
            json={"kind": "human", "session_key": "guest-key",
                  "preferred_name": "Guest", "role": "human"})).json()
        await client.post(
            f"/api/rooms/{room_id}/participants/{guest['participant_id']}/kick",
            headers={**_auth(ROOT), "X-Participant-Id": admin["participant_id"]},
        )
        # 用被撤掉的 token 再打一次 → 授權失敗也要留紀錄
        await client.get("/api/rooms", headers=_auth(guest_token))

    events = _log_events(tmp_path)
    kicks = [e for e in events if e.get("event") == "kick"]
    assert len(kicks) == 1
    assert kicks[0]["display_name"] == "Guest"
    assert kicks[0]["by"] == "Xavier"
    assert kicks[0]["revoked_token_hint"] == token_hint(guest_token)
    assert kicks[0]["access_still_open"] is False

    assert any(e.get("event") == "auth_failed" for e in events)
    assert any(e.get("event") == "join" for e in events)

    # 🚨 整份日誌不得出現任何一張 token 的明碼
    raw = (tmp_path / "logs" / "hub.jsonl").read_text(encoding="utf-8")
    assert guest_token not in raw
    assert ROOT not in raw
    # 但要留得下足以對照 /api/tokens 認出是哪一張的線索
    assert token_hint(guest_token) in raw
