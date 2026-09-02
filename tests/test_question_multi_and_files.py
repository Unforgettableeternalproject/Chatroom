"""提問的複選與附件。

複選：有些問題的選項本來就可以並存（要開哪幾個功能），逼人挑一個只會逼出
一個不完整的答案。附件：UI 問題用講的講不清楚，而回答正是最需要附圖的地方。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

PNG = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + b"0000"


async def _make(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token="")
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _setup(client):
    room = (await client.post("/api/rooms", json={"name": "房"})).json()
    agent = (await client.post(
        f"/api/rooms/{room['id']}/join",
        json={"kind": "claude", "session_key": "a1", "preferred_name": "Novia"},
    )).json()
    human = (await client.post(
        f"/api/rooms/{room['id']}/join",
        json={"kind": "human", "session_key": "h1", "preferred_name": "Bernie",
              "role": "human"},
    )).json()
    return room, agent, human


async def _ask(client, room, agent, human, **kw):
    body = {
        "prompt": "要開哪幾個？",
        "options": [{"label": "甲"}, {"label": "乙"}, {"label": "丙"}],
        "target_participant_id": human["participant_id"],
        **kw,
    }
    r = await client.post(
        f"/api/rooms/{room['id']}/questions", json=body,
        headers={"X-Participant-Id": agent["participant_id"]},
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_multi_select_keeps_both_a_string_and_a_list(tmp_path):
    """兩份都留：字串給轉述用，清單給判斷用。

    只留字串的話，要判斷「有沒有選丙」得自己拆分隔符，而分隔符遲早會出現
    在選項文字裡。
    """
    app, client = await _make(tmp_path, "q_multi")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human, multi_select=True)
            assert q["multi_select"] is True

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "option", "selected": ["甲", "丙"]},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["answer_options"] == ["甲", "丙"]

            r = await client.get(f"/api/questions/{q['id']}")
            got = r.json()["question"]
            assert got["answer_options"] == ["甲", "丙"]
            assert got["answer"] == "甲、丙"


@pytest.mark.asyncio
async def test_single_choice_refuses_multiple(tmp_path):
    """沒開複選就只能選一個——不然「逼出一個決定」這件事就沒了。"""
    app, client = await _make(tmp_path, "q_single")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human)
            assert q["multi_select"] is False
            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "option", "selected": ["甲", "乙"]},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "single_choice_only"


@pytest.mark.asyncio
async def test_multi_select_still_validates_the_labels(tmp_path):
    """複選不是放行——冒充的選項照樣擋，否則 answer_kind=option 就沒有意義。"""
    app, client = await _make(tmp_path, "q_multi_bad")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human, multi_select=True)
            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "option", "selected": ["甲", "丁"]},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "unknown_option"
            assert "丁" in r.json()["detail"]["message"]


@pytest.mark.asyncio
async def test_answer_can_carry_files_and_they_show_up_on_the_receipt(tmp_path):
    """附件要掛到收據上，房內其他人才看得到。

    只留在 question 表裡的話，只有發問的那個 agent 拿得到，而截圖多半是
    講給整個房間聽的。
    """
    app, client = await _make(tmp_path, "q_files")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human, allow_free_text=True)
            up = (await client.post(
                f"/api/rooms/{room['id']}/attachments",
                headers={"X-Participant-Id": human["participant_id"]},
                files={"file": ("shot.png", PNG, "image/png")},
            )).json()

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "長這樣",
                      "attachment_ids": [up["id"]]},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["answer_attachments"] == [up["id"]]

            # 讀回來時是完整 metadata，不是光禿禿的 id
            got = (await client.get(f"/api/questions/{q['id']}")).json()["question"]
            assert got["answer_attachments"][0]["filename"] == "shot.png"
            assert got["answer_attachments"][0]["is_image"] is True

            # 收據上掛著同一個附件，房內看得到
            msgs = (await client.get(
                f"/api/rooms/{room['id']}/messages",
                headers={"X-Participant-Id": agent["participant_id"]},
            )).json()["messages"]
            receipt = [m for m in msgs
                       if m["system_event"] == "question_answered"][0]
            assert [a["id"] for a in receipt["attachments"]] == [up["id"]]
            assert "附 1 個檔案" in receipt["content"]


@pytest.mark.asyncio
async def test_answer_cannot_smuggle_another_rooms_file(tmp_path):
    """附件必須屬於這個房間，否則回答可以把別房的檔案公開到這裡的時間軸上。"""
    app, client = await _make(tmp_path, "q_files_x")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human)
            other = (await client.post("/api/rooms", json={"name": "別房"})).json()
            op = (await client.post(
                f"/api/rooms/{other['id']}/join",
                json={"kind": "human", "session_key": "h2",
                      "preferred_name": "Someone", "role": "human"},
            )).json()
            up = (await client.post(
                f"/api/rooms/{other['id']}/attachments",
                headers={"X-Participant-Id": op["participant_id"]},
                files={"file": ("secret.txt", b"not yours", "text/plain")},
            )).json()

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "看這個",
                      "attachment_ids": [up["id"]]},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "attachment_not_in_room"


@pytest.mark.asyncio
async def test_labels_containing_the_separator_survive(tmp_path):
    """選項文字裡就有「、」時，answer 字串**還原不回原始選項**。

    2026-08-30 測試端實測引爆：三個選項、其中兩個含頓號，複選之後
    `answer` 變成一串無法可靠切開的文字。這正是 `answer_options` 存在的
    理由——判斷邏輯一律用它，不要去拆 `answer`。
    """
    app, client = await _make(tmp_path, "q_sep")
    async with client:
        async with app.router.lifespan_context(app):
            room = (await client.post("/api/rooms", json={"name": "房"})).json()
            agent = (await client.post(
                f"/api/rooms/{room['id']}/join",
                json={"kind": "claude", "session_key": "a1",
                      "preferred_name": "Novia"},
            )).json()
            human = (await client.post(
                f"/api/rooms/{room['id']}/join",
                json={"kind": "human", "session_key": "h1",
                      "preferred_name": "Bernie", "role": "human"},
            )).json()
            labels = ["BMP、PNG、WebP", "host 分組、網址可點", "沒有頓號的選項"]
            q = (await client.post(
                f"/api/rooms/{room['id']}/questions",
                json={"prompt": "挑幾個", "multi_select": True,
                      "options": [{"label": x} for x in labels],
                      "target_participant_id": human["participant_id"]},
                headers={"X-Participant-Id": agent["participant_id"]},
            )).json()

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "option", "selected": labels},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text

            got = (await client.get(f"/api/questions/{q['id']}")).json()["question"]
            # 結構化那份完好無損
            assert got["answer_options"] == labels
            # 而字串那份切開來就是錯的——這條斷言是刻意的：它證明
            # 「拆 answer」這個做法不可靠，而不是暗示它可行
            assert got["answer"].split("、") != labels
            assert len(got["answer"].split("、")) > len(labels)


@pytest.mark.asyncio
async def test_picking_options_and_adding_a_note(tmp_path):
    """選了選項**又想補一句**——兩者要能一起送（艾斯維爾 2026-09-02）。

    在此之前只能二選一：kind=option 會把自訂文字擋成 unknown_option，
    kind=free_text 則讓那幾張選擇靜靜消失。

    **刻意不放寬 unknown_option 的驗證**：`answer_options` 是給 agent 當
    「他從我給的清單裡選的」來信任的，把自訂文字混進去，那個保證就沒了。
    所以補充走獨立欄位，三種讀法各拿各的。
    """
    app, client = await _make(tmp_path, "extra")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human, multi_select=True)

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "option", "selected": ["甲", "丙"],
                      "extra": "丙那個先別動"},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text
            body = r.json()
            # 結構化那份**只有真選項**，agent 的信任保持
            assert body["answer_options"] == ["甲", "丙"]
            assert body["answer_extra"] == "丙那個先別動"

            got = (await client.get(
                f"/api/questions/{q['id']}")).json()["question"]
            assert got["answer_options"] == ["甲", "丙"]
            assert got["answer_extra"] == "丙那個先別動"
            # 人讀那份是完整的：不必為了看到補充而去拼兩個欄位
            assert "甲、丙" in got["answer"]
            assert "丙那個先別動" in got["answer"]


@pytest.mark.asyncio
async def test_extra_without_options_is_refused(tmp_path):
    """free_text 的補充**就是答案本身**。兩個欄位都填會讓「哪一份才算數」
    沒有答案——明確擋下來，比挑一個來用好。
    """
    app, client = await _make(tmp_path, "extra_alone")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human)

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "free_text", "answer": "都不要",
                      "extra": "另外還有一件事"},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 422
            assert r.json()["detail"]["code"] == "extra_needs_option"


@pytest.mark.asyncio
async def test_old_clients_that_never_send_extra_are_unchanged(tmp_path):
    """不送 `extra` 的 client 行為完全不變——那是這個欄位存在之前的樣子。"""
    app, client = await _make(tmp_path, "extra_absent")
    async with client:
        async with app.router.lifespan_context(app):
            room, agent, human = await _setup(client)
            q = await _ask(client, room, agent, human, multi_select=True)

            r = await client.post(
                f"/api/questions/{q['id']}/answer",
                json={"kind": "option", "selected": ["甲", "乙"]},
                headers={"X-Participant-Id": human["participant_id"]},
            )
            assert r.status_code == 200, r.text
            assert r.json()["answer_extra"] == ""
            got = (await client.get(
                f"/api/questions/{q['id']}")).json()["question"]
            assert got["answer"] == "甲、乙", "沒有補充時不該多出分隔符"
