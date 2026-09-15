"""啟動修復（`_heal_settled_orphans`）碰上零掛接房的卡。

D9 的同型問題，但**後果嚴重一級**：D9 是一個端點回 500，這條在 `lifespan`
裡跑，炸掉就是**整台 Hub 起不來**——而且資料庫裡只要留著那樣一列，
每次啟動都會再炸一次，重啟救不回來。

形狀與 D9 一模一樣：`_next_board_seq(room_id)` 沒帶 `board_id`，而零掛接房
建的卡 `room_id` 是空字串。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT,
                 log_dir=str(tmp_path / "logs"))
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def test_startup_survives_a_settled_orphan_on_a_board_with_no_room(tmp_path):
    """零掛接房的板上有一張「已收尾的孤兒卡」時，Hub 仍然起得來。

    那張卡是啟動修復要清的目標（F6），而清它的第一步是領號——領號拿到的
    `room_id` 是空字串，那正是 D9 的洞。
    """
    app, client = await _client(tmp_path, "heal_noroom")
    key = {"X-Session-Key": "claude-a"}

    async with client:
        async with app.router.lifespan_context(app):
            bid = (await client.post("/api/boards", json={"name": "還沒掛房的板"},
                                     headers=key)).json()["id"]
            tid = (await client.post(f"/api/boards/{bid}/tasks",
                                     json={"title": "收尾了但掛著孤兒旗標"},
                                     headers=key)).json()["id"]
            # 正常路徑產不出這個組合（F6 修的就是它），直接造出存量的形狀
            await app.state.db.execute(
                "UPDATE board_task SET status='done', claim_state='orphaned'"
                " WHERE id=?", (tid,))
            await app.state.db.commit()
            # 前提要成立：這張卡的 room_id 真的是空的，否則這條測試在驗別的東西
            row = await (await app.state.db.execute(
                "SELECT room_id FROM board_task WHERE id=?", (tid,))).fetchone()
            assert row["room_id"] == ""

        # 🚨 重新啟動——`_heal_settled_orphans` 會在這裡撈到那一列
        async with app.router.lifespan_context(app):
            body = (await client.get(f"/api/boards/{bid}", headers=key)).json()
            got = [t for t in body["tasks"] if t["id"] == tid][0]
            # 修復本身也要真的做完：孤兒旗標清掉（沒人持有 ⇒ 清成空字串）
            assert got["claim_state"] == ""
