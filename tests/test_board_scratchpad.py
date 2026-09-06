"""想法板（ScratchPad）：多人同時往一份文件裡倒想法。

這是整個 Board 裡**最容易靜默丟資料**的一塊。卡有狀態機擋著，訊息只會往後
長，只有這裡是「別人寫的東西被換掉」——而換掉的那一刻沒有任何一端會報錯。

艾斯維爾的裁決是兩條獨立的約束（2026-09-02）：

    ① 留歷史                          ← 事後查得回來
    ② agent 不得改人類的段落，只能註解  ← 事前就不讓它發生

⚠️ **② 的驗收有兩半，缺一不可**：擋得住 ∧ 沒擋過頭。只驗前半的話，
「全部拒絕」也會通過（@測試Novia 2026-09-02）。
"""

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_server.app import create_app
from chatroom_server.config import Config

pytestmark = pytest.mark.asyncio

ROOT = "root-token"


async def _client(tmp_path, name):
    cfg = Config(db_path=str(tmp_path / f"{name}.db"), api_token=ROOT)
    app = create_app(cfg)
    return app, AsyncClient(transport=ASGITransport(app=app),
                            base_url="http://test",
                            headers={"Authorization": f"Bearer {ROOT}"})


def _key(who):
    return {"X-Session-Key": who}


async def _human_board(client, who="claude-h", name="艾斯維爾"):
    """建一塊板，owner 是**人類**。守門看的就是這個 kind。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": who})).json()["id"]
    j = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": who,
        "preferred_name": name})
    hdr = {"X-Participant-Id": j.json()["participant_id"],
           "X-Session-Key": who}
    bid = (await client.post("/api/boards", json={"name": "板"},
                             headers=hdr)).json()["id"]
    return bid, hdr


async def _add_agent(client, bid, hdr, who, name="Bot"):
    await client.post(f"/api/boards/{bid}/members",
                      json={"actor_key": who, "role": "editor",
                            "display_name": name, "actor_kind": "claude"},
                      headers=hdr)
    return _key(who)


async def _pad(client, bid, hdr, content="人類寫的第一段"):
    r = await client.post(f"/api/boards/{bid}/scratchpads",
                          json={"title": "想法", "content": content},
                          headers=hdr)
    body = r.json()
    return body["id"], body["first_block_id"]


# ── ② 擋得住 ────────────────────────────────────────────────────────

async def test_an_agent_cannot_rewrite_a_human_paragraph(tmp_path):
    """🚨 這條是整份檔案的核心：**事前擋下，不是事後記錄。**

    擋不住的話，agent 可以把艾斯維爾寫的一句話改成別的意思，而 rev 對得上、
    回 200、沒有任何一端報錯。留歷史查得回來，但那時話已經被改過了。
    """
    app, client = await _client(tmp_path, "guard")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, bkid = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")

            r = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                json={"content": "被改掉的話", "rev": 1}, headers=bot)
            assert r.status_code == 403, "agent 改掉了人類寫的段落"
            assert r.json()["detail"]["code"] == "human_block_readonly"
            assert "註解" in r.json()["detail"]["message"], (
                "要說出替代做法，不是只說不行——不然 agent 會改去把意見"
                "寫成新的一段，混進本文裡")

            # 刪除走同一道關卡：刪掉別人的話比改掉更徹底
            r = await client.delete(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                headers=bot)
            assert r.status_code == 403

            body = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=hdr)).json()
            assert body["blocks"][0]["content"] == "人類寫的第一段"


async def test_an_agent_cannot_rewrite_another_agents_paragraph(tmp_path):
    """agent 也不能改**另一個 agent** 寫的段落。先做嚴的——放寬比收緊安全。"""
    app, client = await _client(tmp_path, "guard2")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, _ = await _pad(client, bid, hdr)
            a = await _add_agent(client, bid, hdr, "claude-a", "A")
            b = await _add_agent(client, bid, hdr, "claude-b", "B")
            bkid = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "A 的想法"}, headers=a)).json()["id"]

            r = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                json={"content": "B 改的", "rev": 1}, headers=b)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_your_block"


async def test_reordering_is_human_only(tmp_path):
    """排序不改內容，但它改變別人那段話的**上下文**——那與改寫是同一類的事。"""
    app, client = await _client(tmp_path, "reorder")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, first = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            second = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "agent 的想法"}, headers=bot)).json()["id"]

            r = await client.post(f"/api/boards/{bid}/scratchpads/{pid}/reorder",
                                  json={"block_ids": [second, first],
                                        "rev": 2}, headers=bot)
            assert r.status_code == 403
            r = await client.post(f"/api/boards/{bid}/scratchpads/{pid}/reorder",
                                  json={"block_ids": [second, first],
                                        "rev": 2}, headers=hdr)
            assert r.status_code == 200
            body = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=hdr)).json()
            assert [b["id"] for b in body["blocks"]] == [second, first]


# ── ② 沒擋過頭（少一條，「全部拒絕」就會通過）───────────────────

async def test_the_guard_does_not_block_everything_else(tmp_path):
    """四件**必須做得到**的事。這半漏掉的話，守門過頭與守門正確長得一樣。"""
    app, client = await _client(tmp_path, "notoverblock")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, human_block = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")

            # ① agent 加自己的段落——這就是它丟想法的方式
            mine = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "我的想法"}, headers=bot))
            assert mine.status_code == 200
            mine_id = mine.json()["id"]

            # ② agent 改自己寫的那段
            r = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{mine_id}",
                json={"content": "我的想法（改過）", "rev": 1}, headers=bot)
            assert r.status_code == 200, "agent 連自己寫的都改不了，守門過頭了"

            # ③ agent 對人類的段落加註解——**這是它唯一能做的事，不能擋**
            r = await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}"
                f"/blocks/{human_block}/notes",
                json={"content": "這裡我有不同看法"}, headers=bot)
            assert r.status_code == 200, (
                "註解也被擋掉的話，「只能註解」就變成「什麼都不能做」")

            # ④ 人類改 agent 寫的段落
            r = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{mine_id}",
                json={"content": "人類整理過", "rev": 2}, headers=hdr)
            assert r.status_code == 200

            body = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=hdr)).json()
            notes = [n for b in body["blocks"] for n in b["notes"]]
            assert [n["content"] for n in notes] == ["這裡我有不同看法"]


async def test_can_edit_is_computed_by_the_server(tmp_path):
    """`can_edit` 由伺服器算。

    讓 client 自己推斷的話，兩邊的規則會漂移，而漂移的那一半沒有人在看：
    畫面給了編輯框、送出時 403。
    """
    app, client = await _client(tmp_path, "canedit")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, human_block = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            mine = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "我的"}, headers=bot)).json()["id"]

            seen = {b["id"]: b["can_edit"] for b in (await client.get(
                f"/api/boards/{bid}/scratchpads/{pid}",
                headers=bot)).json()["blocks"]}
            assert seen[human_block] is False
            assert seen[mine] is True

            body = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=hdr)).json()
            assert all(b["can_edit"] for b in body["blocks"])
            assert body["i_am_human"] is True


# ── ① 留歷史 ────────────────────────────────────────────────────────

async def test_a_legal_rewrite_still_keeps_the_original(tmp_path):
    """⚠️ **CAS 防的是「同時寫」，防不了「後來的人把你的話改掉了」。**

    後者是合法的循序寫入：rev 對得上、回 200、沒有任何一端報錯，而那段原話
    就沒了。**這是所有靜默失效裡最安靜的一種——它連衝突都沒有。**

    守門擋得住 agent 走 API，擋不住人類自己把 agent 的話改掉，而那同樣需要
    查得回來。
    """
    app, client = await _client(tmp_path, "history")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, _ = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            bkid = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "agent 原本說的話"},
                headers=bot)).json()["id"]

            # 人類改掉它——完全合法，不會有任何一端報錯
            r = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                json={"content": "人類改寫過的話", "rev": 1}, headers=hdr)
            assert r.status_code == 200

            hist = (await client.get(
                f"/api/boards/{bid}/scratchpads/{pid}"
                f"/blocks/{bkid}/revisions", headers=bot)).json()
            assert len(hist["revisions"]) == 1
            old = hist["revisions"][0]
            assert old["content"] == "agent 原本說的話"
            assert old["author_name"] == "Bot", "原文的作者要留著"
            assert old["replaced_by_name"] == "艾斯維爾", "誰改的也要留著"


async def test_deleting_a_block_keeps_what_it_said(tmp_path):
    """刪掉一段也要留原文——刪除比改寫更徹底。"""
    app, client = await _client(tmp_path, "deletehist")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, bkid = await _pad(client, bid, hdr, content="要被刪掉的話")
            await client.delete(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                headers=hdr)
            hist = (await client.get(
                f"/api/boards/{bid}/scratchpads/{pid}"
                f"/blocks/{bkid}/revisions", headers=hdr)).json()
            assert [r["content"] for r in hist["revisions"]] == ["要被刪掉的話"]


# ── CAS ─────────────────────────────────────────────────────────────

async def test_a_stale_write_is_refused_and_says_what_is_there_now(tmp_path):
    """同一段、兩個人都拿著 rev=1 ⇒ 後寫的被擋下，而不是安靜地蓋掉。

    409 一定要帶 `content` 與 `rev`：client 沒有現值的話，唯一能做的就是把
    使用者的輸入丟掉再讀一次——那等於把這裡防住的遺失原封不動搬到畫面上。
    """
    app, client = await _client(tmp_path, "cas")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, bkid = await _pad(client, bid, hdr)
            rid2 = (await client.post("/api/rooms", json={
                "name": "房2", "session_key": "claude-h2"})).json()["id"]
            j = await client.post(f"/api/rooms/{rid2}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-h2",
                "preferred_name": "另一個人"})
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-h2", "role": "editor",
                                    "display_name": "另一個人",
                                    "actor_kind": "human"}, headers=hdr)
            other = {"X-Participant-Id": j.json()["participant_id"],
                     "X-Session-Key": "claude-h2"}

            first = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                json={"content": "先寫的", "rev": 1}, headers=hdr)
            assert first.status_code == 200 and first.json()["rev"] == 2

            second = await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}",
                json={"content": "後寫的", "rev": 1}, headers=other)
            assert second.status_code == 409, "後寫的把先寫的蓋掉了"
            detail = second.json()["detail"]
            assert detail["code"] == "scratchpad_block_stale"
            assert detail["content"] == "先寫的", "409 沒帶現值，client 只能丟掉輸入"
            assert detail["rev"] == 2 and detail["your_rev"] == 1


# ── 其他 ────────────────────────────────────────────────────────────

async def test_the_listing_says_someone_left_a_note(tmp_path):
    """清單要回 `unresolved_notes`。

    那是唯一能讓人知道「有人對你的段落提了意見」的線索。不放進清單的話，
    就只能靠一份一份打開去發現，而沒有人會那樣做。
    """
    app, client = await _client(tmp_path, "list")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, bkid = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}/notes",
                json={"content": "一則意見"}, headers=bot)
            pads = (await client.get(f"/api/boards/{bid}/scratchpads",
                                     headers=hdr)).json()["scratchpads"]
            assert pads[0]["unresolved_notes"] == 1
            assert pads[0]["block_count"] == 1
            assert "blocks" not in pads[0], "清單回了整份內容，那不是清單該做的事"


async def test_a_stranger_cannot_read_the_pad(tmp_path):
    """想法板裡是還沒成形的東西，權限跟板一樣，不放寬。"""
    app, client = await _client(tmp_path, "acl")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, _ = await _pad(client, bid, hdr)
            for r in (await client.get(f"/api/boards/{bid}/scratchpads",
                                       headers=_key("claude-zzz")),
                      await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                       headers=_key("claude-zzz"))):
                assert r.status_code == 403
                assert r.json()["detail"]["code"] == "not_board_member"


async def test_every_pad_change_leaves_an_event(tmp_path):
    """想法板的每一次變更也要進稽核串。

    ⚠️ 這是 `test_board_event_completeness.py` 的判準延伸到新表：**列舉**
    所有會推進 `board_seq` 的操作，斷言每個號都有 event。挑幾個來驗的寫法
    會漏掉剛加的那一種——而那正是最可能漏的一種。
    """
    app, client = await _client(tmp_path, "events")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, first = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            second = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "第二段"}, headers=bot)).json()["id"]
            await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{first}/notes",
                json={"content": "一則註解"}, headers=bot)
            await client.put(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{second}",
                json={"content": "改過", "rev": 1}, headers=hdr)
            pad_rev = (await client.get(
                f"/api/boards/{bid}/scratchpads/{pid}",
                headers=hdr)).json()["rev"]
            await client.post(f"/api/boards/{bid}/scratchpads/{pid}/reorder",
                              json={"block_ids": [second, first],
                                    "rev": pad_rev}, headers=hdr)
            await client.delete(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks/{second}",
                headers=hdr)
            await client.delete(f"/api/boards/{bid}/scratchpads/{pid}",
                                headers=hdr)

            body = (await client.get(f"/api/boards/{bid}/events",
                                     headers=hdr)).json()
            kinds = {e["event_type"] for e in body["events"]}
            for want in ("scratchpad_created", "scratchpad_block_added",
                         "scratchpad_note_added", "scratchpad_block_written",
                         "scratchpad_reordered", "scratchpad_block_deleted",
                         "scratchpad_deleted"):
                assert want in kinds, f"{want} 沒有留下 canonical event"
            # 缺號＝有洞。從外面算得出來（@測試Novia 2026-09-02）
            got = {e["board_seq"] for e in body["events"]}
            missing = set(range(1, body["board_seq"] + 1)) - got
            assert not missing, f"這些 board_seq 沒有對應的 event：{sorted(missing)}"


# ── 真併發（@開發Novia (除錯) verify_scratchpad_race.py 的形狀）───────

async def test_deleting_the_same_block_twice_moves_the_water_once(tmp_path):
    """**一次實際的刪除只能有一格水位。**

    兩路都領號的話，水位推兩格而刪除只發生一次——`/events` 上就出現兩次
    刪除，而稽核串的意義正在於它對得上實際發生的事
    （@開發Novia (除錯) 2026-09-03 量到 6 → 8）。

    ⚠️ 關鍵是**先 CAS 後領號**。反過來的話，輸的那路已經把號領走了。
    """
    import asyncio

    app, client = await _client(tmp_path, "doubledelete")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, bkid = await _pad(client, bid, hdr, content="要被刪的")
            before = (await client.get(f"/api/boards/{bid}",
                                       headers=hdr)).json()["board_seq"]
            path = f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}"
            a, b = await asyncio.gather(client.delete(path, headers=hdr),
                                        client.delete(path, headers=hdr))
            assert {a.status_code, b.status_code} == {200}
            done = [r for r in (a, b) if not r.json().get("already_deleted")]
            assert len(done) == 1, "兩路都認為自己刪掉了它"

            after = (await client.get(f"/api/boards/{bid}",
                                      headers=hdr)).json()["board_seq"]
            assert after == before + 1, f"水位推了 {after - before} 格"


async def test_a_note_never_ends_up_on_a_deleted_block(tmp_path):
    """加註解與刪段落同時發生時，**不能兩個都成功而留下孤兒**。

    註解掛在一個已經不存在的段落上：查得到、畫面上看不到，而兩邊都不報錯
    ——今天講了一整天的那個形狀，換到 block→note 這一層
    （@開發Novia (除錯) 2026-09-03 F 組）。
    """
    import asyncio

    app, client = await _client(tmp_path, "notevsdelete")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, bkid = await _pad(client, bid, hdr)
            base = f"/api/boards/{bid}/scratchpads/{pid}/blocks/{bkid}"
            await asyncio.gather(
                client.post(f"{base}/notes", json={"content": "一則註解"},
                            headers=hdr),
                client.delete(base, headers=hdr))

            orphans = await (await app.state.db.execute(
                "SELECT n.id FROM board_scratchpad_note n"
                " JOIN board_scratchpad_block b ON b.id = n.block_id"
                " WHERE n.deleted=0 AND b.deleted=1")).fetchall()
            assert not orphans, (
                f"{len(orphans)} 則註解掛在已刪的段落上——查得到、看不到、"
                "而且沒有任何一端報錯")


async def test_a_note_can_actually_become_resolved(tmp_path):
    """「N 則未處理」要有辦法變成已處理。

    schema、清單與畫面上都有那個數字，卻沒有任何一條路讓它下降的話，**它
    只會往上長，長到沒有人再看它**（審核用Codex-2 2026-09-03）。有狀態就要
    有轉移，不然那個狀態是假的。

    誰能標：段落的作者（意見是對他的）或人類成員。**註解者自己不行**——
    「我提的意見我自己說處理完了」不是處理完了。
    """
    app, client = await _client(tmp_path, "resolve")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, human_block = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            nid = (await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}"
                f"/blocks/{human_block}/notes",
                json={"content": "一則意見"}, headers=bot)).json()["id"]

            base = f"/api/boards/{bid}/scratchpads/{pid}/notes/{nid}/resolve"
            mine = await client.post(base, headers=bot)
            assert mine.status_code == 403, "註解者自己把它標成處理完了"

            ok = await client.post(base, headers=hdr)
            assert ok.status_code == 200 and ok.json()["resolved"] is True
            pads = (await client.get(f"/api/boards/{bid}/scratchpads",
                                     headers=hdr)).json()["scratchpads"]
            assert pads[0]["unresolved_notes"] == 0

            # 重複標記不該再動一次板：什麼都沒發生
            again = await client.post(base, headers=hdr)
            assert again.json()["unchanged"] is True
            assert again.json()["board_seq"] is None

            back = await client.post(f"{base}?unresolve=true", headers=hdr)
            assert back.status_code == 200 and back.json()["resolved"] is False


# ── 整份的 can_edit：漏一個欄位，全部人都變成唯讀 ────────────────────

async def test_the_pad_says_whether_i_may_write_into_it(tmp_path):
    """讀一份想法板要回**整份**的 `can_edit`，不是只有每一段的。

    🚨 這條測的是一個漏欄位：段落層級的 `can_edit` 答的是「這一段是不是我
    寫的」，答不了「我能不能往這份裡加東西」。owner 讀自己的想法板時，
    每一段都 `can_edit=True`，但「加一段」「掛註解」這些動作沒有任何欄位
    授權——client 只好預設拒絕，於是**畫面對所有人唯讀，包括 owner**，
    而兩邊的程式碼看起來都對，沒有任何一端報錯
    （艾斯維爾 2026-09-03：「ScratchPad 基本沒有作用」）。
    """
    app, client = await _client(tmp_path, "pad-can-edit")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, _ = await _pad(client, bid, hdr)

            mine = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=hdr)).json()
            assert mine["can_edit"] is True, "owner 讀自己的板卻不能寫"

            # editor 也能寫——他丟想法用的正是這個畫面
            bot = await _add_agent(client, bid, hdr, "claude-bot")
            as_bot = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                       headers=bot)).json()
            assert as_bot["can_edit"] is True

            # viewer 不能。守門結果由伺服器算，client 不自己推斷
            await client.post(f"/api/boards/{bid}/members",
                              json={"actor_key": "claude-eye", "role": "viewer",
                                    "display_name": "旁觀", "actor_kind": "claude"},
                              headers=hdr)
            as_viewer = (await client.get(
                f"/api/boards/{bid}/scratchpads/{pid}",
                headers=_key("claude-eye"))).json()
            assert as_viewer["can_edit"] is False


async def test_an_archived_board_is_read_only_for_its_owner_too(tmp_path):
    """板封存之後連 owner 都只能看——`can_edit` 要跟著寫入門檻走。

    寫入端點擋的是 `status != 'active'`（409 board_archived）。`can_edit`
    只看角色的話，封存板會給 owner 一個編輯框，按下去才 409。
    """
    app, client = await _client(tmp_path, "pad-archived")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, _ = await _pad(client, bid, hdr)
            archived = await client.post(f"/api/boards/{bid}/archive",
                                         headers=hdr)
            assert archived.status_code == 200, archived.text
            body = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=hdr)).json()
            assert body["can_edit"] is False


async def test_a_human_from_the_room_is_still_a_human_on_the_pad(tmp_path):
    """房內身分退路不能把人類降級成 agent。

    🚨 `_board_role` 2026-09-03 加了「掛接房成員自動 editor」的退路之後，
    這種人**寫得動板卻沒有 `board_member` 列**。名字與 kind 只查 board_member
    的話 kind 是空字串 ⇒ `_actor_is_human` 為 false ⇒ 他寫下的段落被記成
    agent 寫的，於是**他自己改不動自己寫的東西**，而沒有任何地方報錯。

    kind 是守門的依據（「agent 不得改人類的段落」全靠它），不是裝飾。
    """
    app, client = await _client(tmp_path, "human-from-room")
    async with client:
        async with app.router.lifespan_context(app):
            room_id = (await client.post("/api/rooms", json={
                "name": "房", "session_key": "claude-h"})).json()["id"]
            j0 = await client.post(f"/api/rooms/{room_id}/join", json={
                "kind": "human", "role": "human", "session_key": "claude-h",
                "preferred_name": "艾斯維爾"})
            hdr = {"X-Participant-Id": j0.json()["participant_id"],
                   "X-Session-Key": "claude-h"}
            bid = (await client.post(
                "/api/boards",
                json={"name": "板", "origin_room_id": room_id},
                headers=hdr)).json()["id"]
            pid, _ = await _pad(client, bid, hdr)

            # 另一個人類，只進房、沒被加進板
            j = await client.post(f"/api/rooms/{room_id}/join", json={
                "kind": "human", "role": "human", "session_key": "human-2",
                "preferred_name": "另一個人"})
            assert j.status_code == 200, j.text
            them = {"X-Participant-Id": j.json()["participant_id"],
                    "X-Session-Key": "human-2"}

            body = (await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                     headers=them)).json()
            assert body["can_edit"] is True
            assert body["i_am_human"] is True, "房內的人類被當成 agent 了"

            # 他寫的段落改得動——kind 記對了才有這個結果
            add = await client.post(
                f"/api/boards/{bid}/scratchpads/{pid}/blocks",
                json={"content": "我寫的"}, headers=them)
            assert add.status_code == 200, add.text
            mine = next(b for b in (await client.get(
                f"/api/boards/{bid}/scratchpads/{pid}",
                headers=them)).json()["blocks"] if b["content"] == "我寫的")
            assert mine["can_edit"] is True
            assert mine["author_kind"] == "human"


async def test_a_removed_member_is_not_still_a_member(tmp_path):
    """被移除的成員不該還被當成成員拿名字與 kind。

    `_board_role` 早就有 `removed_at IS NULL`，但取名字那兩處漏了——於是
    授權說他不是成員、身分卻還查得到他，兩個答案不一致
    （@開發Novia (除錯) 2026-09-03）。
    """
    app, client = await _client(tmp_path, "removed-member")
    async with client:
        async with app.router.lifespan_context(app):
            bid, hdr = await _human_board(client)
            pid, _ = await _pad(client, bid, hdr)
            bot = await _add_agent(client, bid, hdr, "claude-gone", "離職的")
            await client.request("DELETE",
                                 f"/api/boards/{bid}/members/claude-gone",
                                 headers=hdr)
            r = await client.get(f"/api/boards/{bid}/scratchpads/{pid}",
                                 headers=bot)
            assert r.status_code == 403
            assert r.json()["detail"]["code"] == "not_board_member"


# ---------------------------------------------------------------------------
# 段落狀態：已實作／已放棄（09/06 卡 6b1e6ecc，艾斯維爾想法板 #6 段）
#
# 段落除了刪除之外要能標記「後來怎麼了」。與段落標籤**正交**——標籤是分類
# （bug / feature / design），狀態是結局。
#
# 三態，且 `""` ≠ `abandoned`：「還沒標」與「決定不做」是兩件事，畫成同一種
# 就等於替所有沒人管的段落做了決定。
#
# 寫入語意（決策Novia 09/06 #68 裁定，UI 提的問題）：**沒送＝不動、
# 送空＝清除、送值＝設定**。PUT 對 `content`/`tags` 是整份覆寫，狀態若跟著
# 那個語意，改個錯字就會順手把狀態清掉——那正是這包一直在抓的靜默資料遺失。
# ---------------------------------------------------------------------------


async def _write(client, bid, pad, blk, hdr, **fields):
    body = {"content": "改寫", "tags": [], "rev": 1, **fields}
    return await client.put(
        f"/api/boards/{bid}/scratchpads/{pad}/blocks/{blk}",
        json=body, headers=hdr)


async def _block(client, bid, pad, blk, hdr):
    r = await client.get(f"/api/boards/{bid}/scratchpads/{pad}", headers=hdr)
    assert r.status_code == 200, r.text
    return next(b for b in r.json()["blocks"] if b["id"] == blk)


async def test_a_fresh_paragraph_has_no_state_yet(tmp_path):
    """沒有狀態是空字串，不是缺欄位——client 分不出「還沒標」與「舊版沒有
    這個欄位」的話，它只能兩種都當成沒標，而那兩件事的處置不同。"""
    app, client = await _client(tmp_path, "pad_state_fresh")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        assert (await _block(client, bid, pad, blk, hdr))["state"] == ""


async def test_marking_implemented_and_abandoned(tmp_path):
    """兩個結局都標得起來，而且分得出來。"""
    app, client = await _client(tmp_path, "pad_state_set")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)

        r = await _write(client, bid, pad, blk, hdr, state="implemented")
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk,
                             hdr))["state"] == "implemented"

        r = await _write(client, bid, pad, blk, hdr, rev=2, state="abandoned")
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk,
                             hdr))["state"] == "abandoned"


async def test_not_sending_state_leaves_it_alone(tmp_path):
    """🚨 **沒送就是不動。**

    PUT 對 `content` 與 `tags` 是整份覆寫，狀態若跟著同一個語意，改個錯字
    就會順手把「已實作」清掉——200 回來、兩邊都沒有錯誤訊息。這與 09/05 那
    次 tags 被 retry 清掉是同一個形狀。
    """
    app, client = await _client(tmp_path, "pad_state_untouched")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, state="implemented")

        r = await _write(client, bid, pad, blk, hdr, rev=2,
                         content="只是改個錯字")
        assert r.status_code == 200, r.text
        blkrow = await _block(client, bid, pad, blk, hdr)
        assert blkrow["content"] == "只是改個錯字"
        assert blkrow["state"] == "implemented", "改內容順手把狀態清掉了"


async def test_sending_an_empty_state_clears_it(tmp_path):
    """清除是**明確動作**：送空字串才清。標錯了要拿得回來。"""
    app, client = await _client(tmp_path, "pad_state_clear")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, state="abandoned")

        r = await _write(client, bid, pad, blk, hdr, rev=2, state="")
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk, hdr))["state"] == ""


async def test_an_unknown_state_is_refused(tmp_path):
    """值域擋下，`allowed` 一起給——回應自己就是文件。

    默默存進去的話，UI 拿到一個它畫不出來的值，多半會退回「沒標」顯示：
    使用者按了、看起來沒反應，而沒有任何地方報錯。
    """
    app, client = await _client(tmp_path, "pad_state_bad")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)

        r = await _write(client, bid, pad, blk, hdr, state="done")
        assert r.status_code == 422, r.text
        assert "implemented" in r.json()["detail"]["allowed"]


async def test_a_stale_write_hands_back_the_state_too(tmp_path):
    """🔴 **衝突回應一定要帶 `state`。**

    與 09/05 那條 `tags` 教訓完全同型（資料損失級）：狀態與內容是同一次寫入
    的兩半，衝突回應少給哪一半，retry 就只能用手上那份舊的——而「保留我的」
    正是拿新版 rev ＋ 舊值重送 ⇒ 對方剛標好的狀態被清掉，200 回來，
    兩邊都沒有錯誤訊息。
    """
    app, client = await _client(tmp_path, "pad_state_stale")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, state="implemented")

        # 手上還握著 rev=1
        r = await _write(client, bid, pad, blk, hdr, rev=1, content="慢了一步")
        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "scratchpad_block_stale"
        assert detail["state"] == "implemented",             "衝突回應沒帶 state——retry 會拿舊值把它清掉"


async def test_state_and_tags_are_orthogonal(tmp_path):
    """標籤是分類、狀態是結局，兩軸各走各的。

    寫成明確的斷言是因為它們同在一句 UPDATE 裡，寫錯一個逗號就會互相牽動，
    而那種牽動要等有人同時用到兩者才看得見。
    """
    app, client = await _client(tmp_path, "pad_state_orthogonal")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)

        r = await _write(client, bid, pad, blk, hdr, tags=["design"],
                         state="implemented")
        assert r.status_code == 200, r.text
        row = await _block(client, bid, pad, blk, hdr)
        assert row["tags"] == ["design"] and row["state"] == "implemented"

        # 只改標籤，狀態不動
        r = await _write(client, bid, pad, blk, hdr, rev=2, tags=["bug"])
        assert r.status_code == 200, r.text
        row = await _block(client, bid, pad, blk, hdr)
        assert row["tags"] == ["bug"] and row["state"] == "implemented"


# ---------------------------------------------------------------------------
# tags 也走 containsKey（09/06 卡 c22ca1b4，決策重裁）
#
# 原本是整份覆寫，而 `chatroom_scratchpad_edit` 根本不送 tags ⇒ **agent 每次
# 改寫段落都在清標籤，200 回來、兩邊都沒有錯誤訊息**。實測見卡片。
#
# 決策 #68 原裁「既有債、今天不動」建立在「呼叫端有帶就不會丟」的前提上，
# 那個前提是錯的。改採與 `state` 同一套語意：沒送＝不動、送 []＝清除、
# 送值＝設定。
# ---------------------------------------------------------------------------


async def _write_raw(client, bid, pad, blk, hdr, body):
    """完全照給的 body 送——要測「沒送某個欄位」就不能用會補預設的 helper。"""
    return await client.put(
        f"/api/boards/{bid}/scratchpads/{pad}/blocks/{blk}",
        json=body, headers=hdr)


async def test_not_sending_tags_leaves_them_alone(tmp_path):
    """🚨 **這條就是 bridge 那個 bug 的本體。**

    `chatroom_scratchpad_edit` 只送 content 與 rev。整份覆寫語意下，那等於
    每一次改寫都在把標籤清成空——而清空是靜悄悄發生的。
    """
    app, client = await _client(tmp_path, "pad_tags_untouched")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, tags=["design"])

        # bridge 的形狀：只有 content 與 rev
        r = await _write_raw(client, bid, pad, blk, hdr,
                             {"content": "改一個錯字", "rev": 2})
        assert r.status_code == 200, r.text
        row = await _block(client, bid, pad, blk, hdr)
        assert row["content"] == "改一個錯字"
        assert row["tags"] == ["design"], "改內容順手把標籤清掉了"


async def test_sending_an_empty_list_clears_the_tags(tmp_path):
    """清除仍然做得到，只是要明確講——與 state 同一個判斷。"""
    app, client = await _client(tmp_path, "pad_tags_clear")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, tags=["design"])

        r = await _write_raw(client, bid, pad, blk, hdr,
                             {"content": "改寫", "tags": [], "rev": 2})
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk, hdr))["tags"] == []


async def test_sending_tags_still_replaces_them(tmp_path):
    """有送就照送——App 現在的行為完全不變。"""
    app, client = await _client(tmp_path, "pad_tags_set")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, tags=["design"])

        r = await _write_raw(client, bid, pad, blk, hdr,
                             {"content": "改寫", "tags": ["bug"], "rev": 2})
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk, hdr))["tags"] == ["bug"]


async def test_touching_neither_keeps_both(tmp_path):
    """兩軸都沒送就兩軸都不動——這是最常見的那次寫入（改錯字）。"""
    app, client = await _client(tmp_path, "pad_both_untouched")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        await _write(client, bid, pad, blk, hdr, tags=["design"],
                     state="implemented")

        r = await _write_raw(client, bid, pad, blk, hdr,
                             {"content": "改一個錯字", "rev": 2})
        assert r.status_code == 200, r.text
        row = await _block(client, bid, pad, blk, hdr)
        assert row["tags"] == ["design"] and row["state"] == "implemented"


# ---------------------------------------------------------------------------
# 標狀態不受作者守門（09/06，決策裁 A，源自 @測試Novia #93）
#
# `_block_guard` 保護的是**不可逆的原文**：改寫別人寫的東西會讓它消失。
# 標狀態不動任何人的原文，它是在旁邊掛一個結論——可逆、可清除、留事件。
# 同一道門擋兩種動作，其中一種擋錯了。
#
# 語意上更直接：「已實作」該由實作的人標，而實作的人幾乎不會是提出想法的
# 那個人。**寫原文的人反而最不需要標它。**
#
# 實測基線（改之前，記憶體 DB）：
#     B 標 A 的段落   403 not_your_block
#     A 標人類的段落  403 human_block_readonly
#     人類標 A 的段落 200 OK      ← 人類本來就不受 _block_guard 限制
# ---------------------------------------------------------------------------


async def test_an_agent_can_mark_someone_elses_paragraph(tmp_path):
    """別人的段落標得動——那正是這個功能的主要用法。"""
    app, client = await _client(tmp_path, "state_cross_agent")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        a = await _add_agent(client, bid, hdr, "agent-a", "AgentA")
        b = await _add_agent(client, bid, hdr, "agent-b", "AgentB")
        pad, _ = await _pad(client, bid, hdr)
        blk = (await client.post(
            f"/api/boards/{bid}/scratchpads/{pad}/blocks",
            json={"content": "A 的想法"}, headers=a)).json()["id"]

        r = await _write_raw(client, bid, pad, blk, b,
                             {"content": "A 的想法", "state": "implemented",
                              "rev": 1})
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk,
                             hdr))["state"] == "implemented"


async def test_an_agent_can_mark_a_human_paragraph(tmp_path):
    """人類寫的段落也標得動。

    決定放棄的常常是監督者，而監督者多半是 agent——擋住它等於讓那個角色
    標不了自己剛裁定要放棄的東西。
    """
    app, client = await _client(tmp_path, "state_on_human_block")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        a = await _add_agent(client, bid, hdr, "agent-a", "AgentA")
        pad, blk = await _pad(client, bid, hdr)

        r = await _write_raw(client, bid, pad, blk, a,
                             {"content": "人類寫的第一段",
                              "state": "abandoned", "rev": 1})
        assert r.status_code == 200, r.text
        assert (await _block(client, bid, pad, blk,
                             hdr))["state"] == "abandoned"


async def test_the_content_guard_is_untouched(tmp_path):
    """**放寬的只有狀態那一格。**

    寫成明確的斷言是因為最容易的寫法是把整道守門跳過去——那會連原文一起
    放行，而原文的改寫是不可逆的。
    """
    app, client = await _client(tmp_path, "state_guard_intact")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        a = await _add_agent(client, bid, hdr, "agent-a", "AgentA")
        b = await _add_agent(client, bid, hdr, "agent-b", "AgentB")
        pad, human_blk = await _pad(client, bid, hdr)
        a_blk = (await client.post(
            f"/api/boards/{bid}/scratchpads/{pad}/blocks",
            json={"content": "A 的想法"}, headers=a)).json()["id"]

        # 改內容仍被擋——連同時帶 state 也一樣
        r = await _write_raw(client, bid, pad, a_blk, b,
                             {"content": "B 亂改", "state": "implemented",
                              "rev": 1})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "not_your_block"

        r = await _write_raw(client, bid, pad, human_blk, a,
                             {"content": "改人類的原文", "rev": 1})
        assert r.status_code == 403, r.text
        assert r.json()["detail"]["code"] == "human_block_readonly"

        # 標籤也還在守門後面——決策只放寬了狀態那一軸
        r = await _write_raw(client, bid, pad, a_blk, b,
                             {"content": "A 的想法", "tags": ["bug"],
                              "rev": 1})
        assert r.status_code == 403, r.text


async def test_marking_still_needs_to_be_on_the_board(tmp_path):
    """放寬到「板成員」，不是放寬到「任何人」。

    ⚠️ 這條與上面那條守的是不同的門：`_block_guard` 是作者守門，這裡是
    板成員資格。兩道門常被當成同一道，而只剩一道的時候沒有任何地方會說。
    """
    app, client = await _client(tmp_path, "state_needs_membership")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)

        r = await _write_raw(client, bid, pad, blk, _key("nobody"),
                             {"content": "人類寫的第一段",
                              "state": "implemented", "rev": 1})
        assert r.status_code == 403, r.text


async def test_the_server_says_who_may_mark_the_state(tmp_path):
    """🚨 **`can_edit` 答不了「我能不能標狀態」——那是兩道不同的門。**

    UI 拿 `can_edit`（content 的守門）決定要不要畫「＋狀態」入口的話，
    放寬完全失效：server 允許、畫面不給，功能做了但沒有人找得到，而且
    不會有任何錯誤（@開發Novia (UI) 09/06 #99）。

    判準只有 server 一份——client 自己算就是製造第二份，兩邊會漂移。
    """
    app, client = await _client(tmp_path, "pad_can_set_state")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        a = await _add_agent(client, bid, hdr, "agent-a", "AgentA")
        pad, human_blk = await _pad(client, bid, hdr)

        row = await _block(client, bid, pad, human_blk, a)
        assert row["can_edit"] is False, "人類寫的段落 agent 改不動（不變）"
        assert row["can_set_state"] is True,             "標狀態的入口被 content 守門連坐關掉了"

        # 自己寫的那一段兩者都是 True
        mine = (await client.post(
            f"/api/boards/{bid}/scratchpads/{pad}/blocks",
            json={"content": "A 的想法"}, headers=a)).json()["id"]
        row = await _block(client, bid, pad, mine, a)
        assert row["can_edit"] is True and row["can_set_state"] is True


async def test_a_viewer_may_not_mark_anything(tmp_path):
    """放寬到板成員，不是放寬到旁觀者。判準與寫入端點同源。"""
    app, client = await _client(tmp_path, "pad_viewer_no_state")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        await client.post(f"/api/boards/{bid}/members",
                          json={"actor_key": "watcher", "role": "viewer",
                                "display_name": "旁觀", "actor_kind": "claude"},
                          headers=hdr)
        pad, blk = await _pad(client, bid, hdr)

        row = await _block(client, bid, pad, blk, _key("watcher"))
        assert row["can_edit"] is False and row["can_set_state"] is False


async def test_an_archived_board_lets_nobody_mark(tmp_path):
    """封存的板整份唯讀——只看角色的話會給 owner 一個按下去才 409 的入口。"""
    app, client = await _client(tmp_path, "pad_archived_no_state")
    async with client, app.router.lifespan_context(app):
        bid, hdr = await _human_board(client)
        pad, blk = await _pad(client, bid, hdr)
        assert (await client.post(f"/api/boards/{bid}/archive",
                                  headers=hdr)).status_code == 200

        row = await _block(client, bid, pad, blk, hdr)
        assert row["can_set_state"] is False
