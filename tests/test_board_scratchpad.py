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
