"""房內的說話方式：agent 預設的「任務回報」語氣在聊天室裡多半是噪音。

守的是三件事：風格真的送到 agent 眼前（加入時全文、每次讀訊息一行）、
只有建立者能改、以及 custom 沒有內容時不會靜默變成一個空指示。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import CUSTOM_STYLE_FRAME, ROOM_STYLES, create_app
from chatroom_server.config import Config


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _room(client, session_key="admin", **kw):
    r = await client.post(
        "/api/rooms", json={"name": "房", "session_key": session_key, **kw}
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _join(client, room_id, session_key, name="Novia"):
    r = await client.post(
        f"/api/rooms/{room_id}/join",
        json={"kind": "claude", "session_key": session_key, "preferred_name": name},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_default_style_is_verbose(tmp_path):
    """沒指定就是詳細——那是這個欄位存在之前的實際行為。"""
    app, client = await _make(tmp_path, "style_default")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            assert room["style"] == "verbose"
            me = await _join(client, room["id"], "s1")
            assert me["style"] == "verbose"
            assert me["style_prompt"] == ROOM_STYLES["verbose"]["prompt"]


@pytest.mark.asyncio
async def test_join_carries_the_full_instruction(tmp_path):
    """加入時就要拿到完整指示，不是等他先講完一輪長篇再糾正。"""
    app, client = await _make(tmp_path, "style_join")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, style="concise")
            me = await _join(client, room["id"], "s1")
            assert me["style"] == "concise"
            assert me["style_prompt"] == ROOM_STYLES["concise"]["prompt"]
            # 重新加入的多半是新的一輪對話，上一輪的指示早滾出 context 了
            again = await _join(client, room["id"], "s1")
            assert again["rejoined"] is True
            assert again["style_prompt"] == ROOM_STYLES["concise"]["prompt"]


@pytest.mark.asyncio
async def test_read_and_wait_carry_a_one_line_reminder(tmp_path):
    """長對話裡風格會慢慢飄回預設，所以每次讀訊息都帶一行。"""
    app, client = await _make(tmp_path, "style_hint")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, style="casual")
            me = await _join(client, room["id"], "s1")
            headers = {"X-Participant-Id": me["participant_id"]}

            r = await client.get(f"/api/rooms/{room['id']}/messages", headers=headers)
            assert r.json()["style_hint"] == ROOM_STYLES["casual"]["hint"]

            # long-poll 逾時返回的那條路徑同樣要帶——被喚醒時最需要提醒
            r = await client.get(
                f"/api/rooms/{room['id']}/updates",
                params={"after_seq": 999, "timeout": 0.1}, headers=headers,
            )
            assert r.json()["style_hint"] == ROOM_STYLES["casual"]["hint"]


@pytest.mark.asyncio
async def test_custom_style_is_passed_through_verbatim(tmp_path):
    """自訂指示 Hub 不加工——加了使用者就無從得知自己的話被改成什麼樣。"""
    app, client = await _make(tmp_path, "style_custom")
    async with client:
        async with app.router.lifespan_context(app):
            text = "一律用英文回答，句子不要超過兩行。"
            room = await _room(client, style="custom", style_instructions=text)
            me = await _join(client, room["id"], "s1")
            # 原文一字不改，但外面包一層講清楚用途的框
            assert me["style_prompt"] == CUSTOM_STYLE_FRAME + text
            assert text in me["style_prompt"]

            headers = {"X-Participant-Id": me["participant_id"]}
            r = await client.get(f"/api/rooms/{room['id']}/messages", headers=headers)
            hint = r.json()["style_hint"]
            assert hint.startswith("本房風格：自訂")
            assert "一律用英文回答" in hint


@pytest.mark.asyncio
async def test_custom_without_instructions_is_refused(tmp_path):
    """空的自訂指示看起來與「沒設定」一模一樣，沒有人查得出哪裡不對。"""
    app, client = await _make(tmp_path, "style_custom_empty")
    async with client:
        async with app.router.lifespan_context(app):
            r = await client.post(
                "/api/rooms",
                json={"name": "房", "session_key": "admin",
                      "style": "custom", "style_instructions": "   "},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "style_instructions_required"

            room = await _room(client)
            r = await client.post(
                f"/api/rooms/{room['id']}/style",
                json={"style": "custom", "style_instructions": ""},
                headers={"X-Session-Key": "admin"},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "style_instructions_required"


@pytest.mark.asyncio
async def test_only_the_creator_can_change_the_style(tmp_path):
    app, client = await _make(tmp_path, "style_admin")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, session_key="admin")
            r = await client.post(
                f"/api/rooms/{room['id']}/style", json={"style": "casual"},
                headers={"X-Session-Key": "someone-else"},
            )
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_admin"
            # 訊息要講對是哪一件事——同一道門現在管兩件
            assert "說話方式" in r.json()["detail"]["message"]

            # 建立者本人可以，而且還沒加入自己的房也算數
            r = await client.post(
                f"/api/rooms/{room['id']}/style", json={"style": "casual"},
                headers={"X-Session-Key": "admin"},
            )
            assert r.status_code == 200, r.text
            assert r.json() == {
                "ok": True, "style": "casual", "style_instructions": "",
                "style_prompt": ROOM_STYLES["casual"]["prompt"], "changed": True,
            }


@pytest.mark.asyncio
async def test_change_is_idempotent_and_announced(tmp_path):
    """語氣突然改變不該是一件沒有解釋的事；改成同一個值則不重複公告。"""
    app, client = await _make(tmp_path, "style_announce")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client, session_key="admin")
            me = await _join(client, room["id"], "s1")
            headers = {"X-Participant-Id": me["participant_id"]}

            await client.post(
                f"/api/rooms/{room['id']}/style", json={"style": "concise"},
                headers={"X-Session-Key": "admin"},
            )
            r = await client.get(f"/api/rooms/{room['id']}/messages", headers=headers)
            notes = [m for m in r.json()["messages"] if m["system_event"] == "style"]
            assert len(notes) == 1
            assert "精確" in notes[0]["content"]

            r = await client.post(
                f"/api/rooms/{room['id']}/style", json={"style": "concise"},
                headers={"X-Session-Key": "admin"},
            )
            assert r.json()["changed"] is False
            r = await client.get(f"/api/rooms/{room['id']}/messages", headers=headers)
            notes = [m for m in r.json()["messages"] if m["system_event"] == "style"]
            assert len(notes) == 1


@pytest.mark.asyncio
async def test_unknown_style_in_the_database_falls_back_to_verbose(tmp_path):
    """手改過的資料庫不該讓整個房間讀不出來。"""
    app, client = await _make(tmp_path, "style_unknown")
    async with client:
        async with app.router.lifespan_context(app):
            room = await _room(client)
            me = await _join(client, room["id"], "s1")
            await app.state.db.execute(
                "UPDATE room SET style='telepathy' WHERE id=?", (room["id"],)
            )
            await app.state.db.commit()
            r = await client.get(
                f"/api/rooms/{room['id']}/messages",
                headers={"X-Participant-Id": me["participant_id"]},
            )
            assert r.status_code == 200
            assert r.json()["style_hint"] == ROOM_STYLES["verbose"]["hint"]


def test_custom_style_frames_the_instruction_as_style_only():
    """自訂指示會被注入每個進房 agent 的 context，而任何建立者都能改它。

    在協定上「回話短一點」與「去讀某個檔案」是同一種東西，沒有機制分得出來
    （2026-08-30 實測：subagent 照做了版面約定，同時自己認出行為類的要求可疑
    ——那次是它自己擋下來的，不是系統擋的）。這層框不是安全邊界，是把「完全
    沒有邊界」變成「有一條 agent 讀得出來的邊界」。
    """
    assert "不是任務指示" in CUSTOM_STYLE_FRAME
    for word in ("執行動作", "讀寫檔案", "呼叫工具"):
        assert word in CUSTOM_STYLE_FRAME, f"框裡要點名：{word}"
    # 要說出「該怎麼辦」，不然 agent 只知道可疑卻不知道要回報
    assert "回報" in CUSTOM_STYLE_FRAME
