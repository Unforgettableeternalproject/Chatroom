"""T-07：Supervisor。

三個要害：

1. **設定的當下對方多半還沒進房**——那正是要用指派把它叫進來的情形。
   所以退場判定只能接在離場路徑上，做成定期檢查的話設定完的下一輪掃描
   就會把它自己清掉，而且清得完全合乎規則。
2. **退場是標記不是清空**。清空連名字都不留，畫面上與「從來沒有指定過」
   一模一樣——連「本來有人在看」這件事都消失了。
3. **摘要不逐筆**。supervisor 也是一個會被塞滿的 agent。
"""

import json

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name, **kw):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT, **kw)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


async def _join(client, rid, session_key, name, role="agent"):
    kind = "human" if role == "human" else "claude"
    r = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": role, "session_key": session_key,
        "preferred_name": name})
    return {"X-Participant-Id": r.json()["participant_id"]}


async def _room(client):
    rid = (await client.post("/api/rooms", json={
        "name": "板子房", "session_key": "human-1"})).json()["id"]
    owner = await _join(client, rid, "human-1", "Bernie", role="human")
    return rid, owner


async def _events(client, rid, hdr, event):
    msgs = (await client.get(f"/api/rooms/{rid}/messages",
                             headers=hdr)).json()["messages"]
    return [m for m in msgs if m["system_event"] == event]


def _room_supervisor(board_body, room_id):
    """本房的 supervisor——房軸頂層那個鍵。

    09/05（卡 3a518cbe）型別從 v1 的 session_key 字串改成**物件**，與
    `attached_rooms[].supervisor` 同形。

    ⚠️ 這個鍵不能改成「從 attached_rooms 取本房那筆」：supervisor 是 room
    層級的設定，**房間還沒有板也能指定**（指派它進來正是最常見的情形），
    而 attached_rooms 是板的掛接清單，沒板時是空的。
    """
    return board_body["supervisor"]


async def test_can_appoint_someone_not_in_the_room_yet(tmp_path):
    """被指定的對象在設定當下多半還沒進房——那正是要指派它進來的情形。"""
    app, client = await _client(tmp_path, "not-yet")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "claude-not-here-yet"},
                              headers=owner)
        assert r.status_code == 200, r.text
        assert r.json()["in_room"] is False
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=owner)).json()
        sup = _room_supervisor(board, rid)
        assert sup is not None and sup["actor_key"] == "claude-not-here-yet"


async def test_only_the_creator_can_appoint(tmp_path):
    app, client = await _client(tmp_path, "perm")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        other = await _join(client, rid, "agent-1", "Novia")
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "agent-1"}, headers=other)
        assert r.status_code == 403
        assert r.json()["detail"]["code"] == "not_admin"


async def test_departure_marks_and_announces_but_does_not_erase(tmp_path):
    """清空會讓畫面與「從來沒有指定過」一模一樣，那是同一個病更嚴重的版本。"""
    app, client = await _client(tmp_path, "left")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)

        await client.post(f"/api/rooms/{rid}/leave", headers=sup)

        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=owner)).json()
        sup = _room_supervisor(board, rid)
        assert sup is not None and sup["actor_key"] == "agent-sup", "名字不能被抹掉"
        (msg,) = await _events(client, rid, owner, "board_supervisor_left")
        assert "Nova" in msg["content"]
        assert "重新指定" in msg["content"]


async def test_departure_is_announced_once_not_every_time(tmp_path):
    """已經標記過就不再公告——否則每次有人離開都會再喊一次同一件事。"""
    app, client = await _client(tmp_path, "once")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        other = await _join(client, rid, "agent-2", "Miller")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/leave", headers=sup)
        await client.post(f"/api/rooms/{rid}/leave", headers=other)
        assert len(await _events(client, rid, owner,
                                 "board_supervisor_left")) == 1


async def test_appointment_survives_a_restart_of_the_agent(tmp_path):
    """supervisor 是角色不是身分：換一個 participant 回來，角色還在。"""
    app, client = await _client(tmp_path, "role")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/leave", headers=sup)
        again = await _join(client, rid, "agent-sup", "Nova")
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=again)).json()
        sup = _room_supervisor(board, rid)
        assert sup is not None and sup["actor_key"] == "agent-sup"


async def test_cancelling_leaves_a_record(tmp_path):
    app, client = await _client(tmp_path, "cancel")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": ""}, headers=owner)
        assert r.status_code == 200
        assert r.json()["supervisor"] is None
        board = (await client.get(f"/api/rooms/{rid}/board",
                                  headers=owner)).json()
        assert _room_supervisor(board, rid) is None
        assert len(await _events(client, rid, owner,
                                 "board_supervisor_set")) == 2


async def test_digest_batches_changes_and_mentions_only_the_supervisor(tmp_path):
    """摘要不逐筆——supervisor 也是一個會被塞滿的 agent。"""
    app, client = await _client(tmp_path, "digest",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)

        for i in range(3):
            await client.post(f"/api/rooms/{rid}/board/objectives",
                              json={"title": f"週期{i}"}, headers=owner)

        await app.state.sweep_once()

        digests = await _events(client, rid, owner, "board_digest")
        assert len(digests) == 1, "三次變動應該收成一則"
        assert digests[0]["mentions"] == ["Nova"], "只叫醒 supervisor"
        assert "週期 3 項" in digests[0]["content"]


async def test_digest_does_not_repeat_what_it_already_reported(tmp_path):
    app, client = await _client(tmp_path, "digest-cursor",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        await app.state.sweep_once()
        await app.state.sweep_once()      # 沒有新變動 → 不該再發
        assert len(await _events(client, rid, owner, "board_digest")) == 1


async def test_no_supervisor_means_no_digest(tmp_path):
    app, client = await _client(tmp_path, "no-sup",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        await app.state.sweep_once()
        assert await _events(client, rid, owner, "board_digest") == []


async def test_a_departed_supervisor_stops_receiving_digests(tmp_path):
    """已經不在房內的人不該繼續被 mention——那個 mention 不會有人收到。"""
    app, client = await _client(tmp_path, "sup-gone",
                                board_digest_interval=0.0, sweep_interval=3600)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        sup = await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/leave", headers=sup)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)
        await app.state.sweep_once()
        assert await _events(client, rid, owner, "board_digest") == []


# ---------------------------------------------------------------------------
# 摘要的收件人（審核用 Codex 於 v1 驗收發現，重現兩次 mentions=[]）
# ---------------------------------------------------------------------------


async def _digest_recipients(app, rid):
    rows = await (await app.state.db.execute(
        "SELECT mentions FROM message WHERE room_id=?"
        " AND system_event='board_digest' ORDER BY seq", (rid,),
    )).fetchall()
    return [json.loads(r["mentions"] or "[]") for r in rows]


async def _digest_seq(app, rid):
    row = await (await app.state.db.execute(
        "SELECT board_seq, board_digest_seq FROM room WHERE id=?", (rid,),
    )).fetchone()
    return row["board_seq"], row["board_digest_seq"]


async def test_a_digest_is_held_until_the_supervisor_is_actually_in_the_room(tmp_path):
    """**收件人以 session_key 即時反查，不用設定當下的名字快照。**

    supervisor 常在被指定的當下還沒進房（上面那條測試守著這是允許的），
    此時快照是空字串 ⇒ mentions 為空 ⇒ 這則摘要不會叫醒任何人。而水位照樣
    前進，於是那段變動再也追不回來——**靜默失效，且一輪一輪地重演**。
    """
    app, client = await _client(tmp_path, "digest_wait", board_digest_interval=0.0)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "sup-1"}, headers=owner)
        oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                                 json={"title": "週期一"},
                                 headers=owner)).json()["id"]
        assert oid

        await app.state.sweep_once()
        assert await _digest_recipients(app, rid) == [], "人還沒進房就發了"
        board_seq, digest_seq = await _digest_seq(app, rid)
        assert board_seq > digest_seq, (
            "水位不該前進——推了的話這段變動就再也追不回來了"
        )

        # 他進房了：同一段變動仍要送得到
        await _join(client, rid, "sup-1", "監督者")
        await app.state.sweep_once()
        recipients = await _digest_recipients(app, rid)
        assert len(recipients) == 1, f"進房後應該補送一則：{recipients}"
        assert "監督者" in recipients[0], f"沒 mention 到人：{recipients[0]}"
        board_seq, digest_seq = await _digest_seq(app, rid)
        assert board_seq == digest_seq, "送出之後水位才該跟上"

        # 另一半：進房時補上名字快照。摘要的收件人不靠它（即時反查），
        # 但畫面要說得出「本來是誰在看」——他離場之後就只剩這一份
        row = await (await app.state.db.execute(
            "SELECT board_supervisor_name, board_supervisor_kind FROM room"
            " WHERE id=?", (rid,),
        )).fetchone()
        assert row["board_supervisor_name"] == "監督者", "進房沒有回填名字快照"
        assert row["board_supervisor_kind"] == "claude"


async def test_a_digest_still_goes_out_when_the_supervisor_is_present(tmp_path):
    """錨點：擋掉「把摘要整個關掉」也會過的寫法。"""
    app, client = await _client(tmp_path, "digest_ok", board_digest_interval=0.0)
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await _join(client, rid, "sup-1", "監督者")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "sup-1"}, headers=owner)
        await client.post(f"/api/rooms/{rid}/board/objectives",
                          json={"title": "週期一"}, headers=owner)

        await app.state.sweep_once()
        recipients = await _digest_recipients(app, rid)
        assert len(recipients) == 1 and "監督者" in recipients[0]


# ── 指派得做得出來：UI 手上只有 participant_id ──────────────────────

async def test_appointing_by_participant_id_because_session_keys_never_leave(
        tmp_path):
    """指派要收得下 `participant_id`。

    🚨 這條測的是一個**做不出介面**的契約缺口，不是壞掉的行為：這支端點
    只收 `session_key`，而 `GET /api/rooms/{id}` 刻意不外流成員的
    `session_key`（隱私）。⇒ UI 手上沒有任何可以送出去的值，指派選單
    **根本做不出來**，於是那個對話框只能是唯讀的
    （艾斯維爾 2026-09-03：「我無法指派 Supervisor」）。

    換掉的動作在 server 做：session_key 維持不外流。
    """
    app, client = await _client(tmp_path, "appoint-by-pid")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        bot = await _join(client, rid, "claude-bot", "諾薇亞")
        pid = bot["X-Participant-Id"]

        # 前提：房間詳情確實不給 session_key，所以 UI 只有 participant_id
        room = (await client.get(f"/api/rooms/{rid}", headers=owner)).json()
        assert all("session_key" not in p for p in room["participants"])

        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"participant_id": pid}, headers=owner)
        assert r.status_code == 200, r.text
        assert r.json()["display_name"] == "諾薇亞"
        assert r.json()["in_room"] is True

        # 別間房指不了他：participant_id 是**房內**身分，跨房就不是同一個人。
        # 少了房的比對，任何管理者都能拿一個外面撿到的 id 指自己的房
        other = (await client.post("/api/rooms", json={
            "name": "別間", "session_key": "human-1"})).json()["id"]
        bad = await client.post(f"/api/rooms/{other}/board/supervisor",
                                json={"participant_id": pid},
                                headers={"X-Session-Key": "human-1"})
        assert bad.status_code == 404
        assert bad.json()["detail"]["code"] == "participant_not_found"


async def test_each_attached_room_carries_its_own_supervisor(tmp_path):
    """v2 的板要回**每一間掛接房各自的** supervisor。

    艾斯維爾 2026-09-03：「每個聊天室綁的 supervisor 可以不同，這是每個
    room 範疇的」。板的回應只給 board-scoped 那一個的話，指派成功了膠囊
    也不會亮——設定寫進去了、畫面看不出來，又是一次沒有人會報錯的失敗。
    """
    app, client = await _client(tmp_path, "per-room-sup")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        bot = await _join(client, rid, "claude-bot", "諾薇亞")
        bid = (await client.post("/api/boards",
                                 json={"name": "板", "origin_room_id": rid},
                                 headers=owner)).json()["id"]
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"participant_id": bot["X-Participant-Id"]},
                          headers=owner)

        body = (await client.get(f"/api/boards/{bid}", headers=owner)).json()
        room_entry = next(a for a in body["attached_rooms"] if a["id"] == rid)
        assert room_entry["supervisor"] is not None
        assert room_entry["supervisor"]["display_name"] == "諾薇亞"


async def test_a_room_supervisor_may_send_directives(tmp_path):
    """掛接房的 supervisor 送得出 directive。

    授權只看 `board.supervisor_actor_key` 的話，per-room 指派完的人**還是
    送不出判斷**——被指派了、卻做不了那件事，而 403 的訊息會說他不是
    supervisor，那句話在他眼裡是錯的。

    板掛多間房、每間房各有 supervisor 時，三個人都送得出：directive 是對
    整塊板說的，沒有房的維度（諾薇亞 2026-09-03，艾斯維爾未反對）。
    """
    app, client = await _client(tmp_path, "room-sup-directive")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        bot = await _join(client, rid, "claude-bot", "諾薇亞")
        worker = await _join(client, rid, "claude-worker", "米勒")
        bid = (await client.post("/api/boards",
                                 json={"name": "板", "origin_room_id": rid},
                                 headers=owner)).json()["id"]
        # 兩個 agent 都進板，否則 directive 投影不到人身上
        for key, name in (("claude-bot", "諾薇亞"), ("claude-worker", "米勒")):
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": key, "role": "editor",
                                    "display_name": name,
                                    "actor_kind": "claude"}, headers=owner)

        # 指派前送不出去：他還不是任何人的 supervisor
        early = await client.post(f"/api/boards/{bid}/directives",
                                  json={"target_actor_key": "claude-worker",
                                        "text": "這個方向要改"}, headers=bot)
        assert early.status_code == 403

        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"participant_id": bot["X-Participant-Id"]},
                          headers=owner)

        ok = await client.post(f"/api/boards/{bid}/directives",
                               json={"target_actor_key": "claude-worker",
                                     "text": "這個方向要改"}, headers=bot)
        assert ok.status_code == 200, ok.text
        assert ok.json()["delivered"] is True


async def _objective_ready_for_verify(client, rid, hdr):
    """造一個「所有階段都收尾、已送審」的週期——閘 3 過得去的最小形狀。"""
    oid = (await client.post(f"/api/rooms/{rid}/board/objectives",
                             json={"title": "要驗的週期"},
                             headers=hdr)).json()["id"]
    cid = (await client.post(f"/api/board/objectives/{oid}/checklists",
                             json={"title": "清單"}, headers=hdr)).json()["id"]
    tid = (await client.post(f"/api/board/checklists/{cid}/tasks",
                             json={"title": "卡"}, headers=hdr)).json()["id"]
    # todo 不能直接跳 done，中間要經過 in_progress
    for st in ("in_progress", "done"):
        r = await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": st}, headers=hdr)
        assert r.status_code == 200, r.text
    r = await client.post(f"/api/board/checklists/{cid}/status",
                          json={"status": "done"}, headers=hdr)
    assert r.status_code == 200, r.text
    return oid


async def test_the_rooms_supervisor_can_verify_even_as_an_agent(tmp_path):
    """審核放寬給該房的 supervisor（艾斯維爾想法板觀察 ③、2026-09-04 定案）。

    在此之前 verify 是 human-only。supervisor 可以是 agent（N-6 語意），
    而他正是這塊板上「負責看」的那個人——把他擋在確認之外，等於指定了一個
    監察者卻不讓他做監察的最後一步。

    ⚠️ 放寬的是**誰能按**，閘 3（底下全部收尾）一步都沒有鬆。
    """
    app, client = await _client(tmp_path, "sup-verify")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        agent = await _join(client, rid, "agent-sup", "監察者")
        worker = await _join(client, rid, "agent-worker", "工人")

        oid = await _objective_ready_for_verify(client, rid, worker)
        r = await client.post(f"/api/board/objectives/{oid}/review",
                              headers=worker)
        assert r.status_code == 200, r.text

        # 還不是 supervisor 的 agent：擋下（放寬不是對所有 agent 開門）
        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=agent)
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_only"

        r = await client.post(f"/api/rooms/{rid}/board/supervisor",
                              json={"session_key": "agent-sup"}, headers=owner)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=agent)
        assert r.status_code == 200, r.text


async def test_a_supervisor_still_cannot_verify_what_he_sent_for_review(tmp_path):
    """supervisor 送審後不能自己確認。

    🔑 這道閘在 verify 還是 human-only 的時候**永遠不會觸發**（程式碼裡有
    一段註解實測過：整段換成 `if False:` 十四條測試全綠），因為人類送審者
    本來就允許自己確認（房裡只有一個人類時，不許的話那條週期永遠卡住）。

    放寬給 agent supervisor 的那一刻它才真的開始擋——而擋的正是它當初寫下
    來要擋的東西：**宣告完成的身分自己按下確認，那道閘等於不存在**。
    """
    app, client = await _client(tmp_path, "sup-self")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        agent = await _join(client, rid, "agent-sup", "監察者")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)

        oid = await _objective_ready_for_verify(client, rid, agent)
        r = await client.post(f"/api/board/objectives/{oid}/review",
                              headers=agent)
        assert r.status_code == 200, r.text

        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=agent)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["code"] == "self_verification_not_allowed"

        # 人類照樣驗得了——擋的是自我確認，不是這條週期
        r = await client.post(f"/api/board/objectives/{oid}/verify",
                              headers=owner)
        assert r.status_code == 200, r.text


async def test_both_places_describe_the_supervisor_the_same_way(tmp_path):
    """房軸頂層與 `attached_rooms[]` 講同一件事，形狀必須一模一樣。

    這張卡（09/05 `3a518cbe`）的起因就是它們不一樣：一邊回 v1 的
    session_key 字串、一邊回物件。**同一個鍵名兩種型別**，而讀的人得先知道
    自己在哪一條路上——那是一份判準拆成兩份。

    server 端兩處已改用同一個 `_supervisor_obj()`；這條釘住那個決定，
    否則下一次有人「順手」在其中一邊多補一個欄位，漂移不會有任何地方報錯。
    """
    app, client = await _client(tmp_path, "same-shape")
    async with app.router.lifespan_context(app), client:
        rid, owner = await _room(client)
        await _join(client, rid, "agent-sup", "Nova")
        await client.post(f"/api/rooms/{rid}/board/supervisor",
                          json={"session_key": "agent-sup"}, headers=owner)
        # 建一張卡讓板長出來，attached_rooms 才有東西
        await client.post(f"/api/rooms/{rid}/board/tasks",
                          json={"title": "第一張"}, headers=owner)

        body = (await client.get(f"/api/rooms/{rid}/board",
                                 headers=owner)).json()
        top = body["supervisor"]
        (entry,) = [r for r in body["attached_rooms"] if r["id"] == rid]

        assert top is not None and entry["supervisor"] is not None
        assert top == entry["supervisor"], (
            "同一個 supervisor 在兩處長得不一樣——"
            f"頂層 {top}／attached_rooms {entry['supervisor']}"
        )
        assert top["actor_key"] == "agent-sup"
        assert set(top) == {"actor_key", "display_name", "actor_kind",
                            "departed"}
        # session_key 不外流：對外一律用板上那套稱呼
        assert "session_key" not in top
