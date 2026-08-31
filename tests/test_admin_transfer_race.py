"""管理權移交不能有兩個贏家。

`transfer_admin` 先讀舊 admin 驗權限，再無條件 `UPDATE room ... WHERE id=?`。
兩個同時抵達的請求會各自通過那道檢查、各自成功、各自發一則系統訊息，最後
一筆蓋掉前一筆——房裡於是有兩則「管理權已移交」的紀錄，而實際 admin 只有
後寫入的那個。看紀錄的人無從知道哪一則是真的。

修法：`UPDATE` 帶上舊的 `creator_session_key` 當條件，靠 rowcount 判斷自己
是不是那個贏家。**檢查與寫入必須是同一個動作**，分成兩步就會有窗口。

（審核用 Codex F7，2026-08-31）
"""

import ast
import asyncio
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

import chatroom_server.app as app_module
from chatroom_server.app import create_app
from chatroom_server.config import Config

# 這個檔案混了 async 與同步測試（靜態守衛是同步的），所以不下模組層的
# `pytestmark = pytest.mark.asyncio`——它會套到同步測試上並發出警告。
# pytest.ini 是 `asyncio_mode = auto`，async 測試不標也會跑


def _cfg(tmp_path, name):
    return Config(db_path=str(tmp_path / f"{name}.db"), api_token="")


async def _make(tmp_path, name):
    app = create_app(_cfg(tmp_path, name))
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _join(client, room_id, key, name):
    return (await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "human", "session_key": key,
              "preferred_name": name, "role": "human"},
    )).json()


def _pid(p):
    return {"X-Participant-Id": p["participant_id"]}


async def test_two_simultaneous_transfers_produce_one_winner(tmp_path):
    app, client = await _make(tmp_path, "race")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        admin = await _join(client, room_id, "owner", "Xavier")
        a = await _join(client, room_id, "s-a", "Alpha")
        b = await _join(client, room_id, "s-b", "Beta")

        async def hand_to(target):
            return await client.post(
                f"/api/rooms/{room_id}/admin",
                json={"target_participant_id": target["participant_id"]},
                headers=_pid(admin),
            )

        r1, r2 = await asyncio.gather(hand_to(a), hand_to(b))
        wins = [r for r in (r1, r2) if r.status_code == 200]

        # 兩個都成功＝房裡有兩則「管理權已移交」，而只有一個是真的
        assert len(wins) == 1, [r.status_code for r in (r1, r2)]

        # 輸的那個要說得出為什麼，不是 500
        lost = [r for r in (r1, r2) if r.status_code != 200][0]
        assert lost.status_code in (403, 409), lost.text

        # 實際 admin 與那個贏家一致
        winner_id = wins[0].json()["admin_participant_id"]
        detail = (await client.get(f"/api/rooms/{room_id}",
                                   headers=_pid(a))).json()
        admins = [p["display_name"] for p in detail["participants"]
                  if p.get("is_admin")]
        winner_name = next(p["display_name"] for p in detail["participants"]
                           if p["id"] == winner_id)
        assert admins == [winner_name], admins


def test_no_request_path_rolls_back_the_shared_connection():
    """請求路徑不得呼叫 `rollback()`。

    整個 App 共用同一條 aiosqlite 連線，所以 `rollback()` 撤的是那條連線上
    **所有**未提交的資料——包含另一個 coroutine 剛寫入還沒 commit 的。對方
    之後照樣 commit、照樣回 200，而東西已經不在了：一次成功的寫入無聲消失
    （審核用 Codex F11）。

    **這條是靜態守衛，不是行為測試，而那是刻意的。** 我原本寫的是併發行為
    測試（同時丟多筆寫入，斷言它們都還在）——把 rollback 加回去之後**它照樣
    全綠**，跑四次都是。ASGITransport 底下的交錯不夠真實，構造不出那個窗口。
    前後都綠的測試守不住任何東西，所以換成掃得到的形式。

    真的需要交易隔離時，要的是 per-request 交易或連線池，不是在共用連線上
    rollback——那時再回來鬆綁這條。
    """
    tree = ast.parse(Path(app_module.__file__).read_text(encoding="utf-8"))
    offenders = [
        f"app.py:{n.lineno}"
        for n in ast.walk(tree)
        if isinstance(n, ast.Call)
        and isinstance(n.func, ast.Attribute)
        and n.func.attr == "rollback"
    ]
    assert not offenders, (
        "共用連線上的 rollback 會撤掉別的請求剛寫入、還沒 commit 的資料，"
        "而對方會回報成功：\n  " + "\n  ".join(offenders)
    )


async def test_a_single_transfer_still_works(tmp_path):
    """反向錨點：加了條件之後，正常的移交不能跟著壞掉。"""
    app, client = await _make(tmp_path, "single")
    async with app.router.lifespan_context(app), client:
        room_id = (await client.post(
            "/api/rooms", json={"name": "房", "session_key": "owner"})).json()["id"]
        admin = await _join(client, room_id, "owner", "Xavier")
        heir = await _join(client, room_id, "s-h", "Heir")

        r = await client.post(
            f"/api/rooms/{room_id}/admin",
            json={"target_participant_id": heir["participant_id"]},
            headers=_pid(admin),
        )
        assert r.status_code == 200, r.text
