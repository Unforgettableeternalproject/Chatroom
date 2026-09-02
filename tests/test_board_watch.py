"""卡片追蹤：只通知在等這張卡的人。

艾斯維爾的原話是「當追蹤的卡完成就會通知以追蹤的人，**就不需要通知所有
人**」。所以驗收有兩半，缺一不可：

    追蹤者收到      ← 漏送 ＝ 功能等於不存在
    非追蹤者收不到  ← 多送 ＝ 功能沒有意義

⚠️ 只驗前半的話「通知所有人」也會通過，只驗後半的話「誰都不通知」也會
通過。今天 H4 的教訓是同一根：**去重做過頭就是漏送**。
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


async def _room_board(client, who="claude-h", name="艾斯維爾"):
    """一間房 + 一塊掛在它上面的板，回 (room_id, board_id, headers)。"""
    rid = (await client.post("/api/rooms", json={
        "name": "房", "session_key": who})).json()["id"]
    j = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": "human", "role": "human", "session_key": who,
        "preferred_name": name})
    hdr = {"X-Participant-Id": j.json()["participant_id"],
           "X-Session-Key": who}
    # 在房裡建一張卡 ⇒ 換軸時自動建板並掛接
    await client.post(f"/api/rooms/{rid}/board/objectives",
                      json={"title": "週期"}, headers=hdr)
    bid = (await client.get(f"/api/rooms/{rid}/board",
                            headers=hdr)).json()["board_id"]
    return rid, bid, hdr


async def _join(client, rid, bid, hdr, who, name, kind="claude"):
    j = await client.post(f"/api/rooms/{rid}/join", json={
        "kind": kind, "role": "agent", "session_key": who,
        "preferred_name": name})
    await client.post(f"/api/boards/{bid}/members",
                      json={"actor_key": who, "role": "editor",
                            "display_name": name, "actor_kind": kind},
                      headers=hdr)
    return {"X-Participant-Id": j.json()["participant_id"],
            "X-Session-Key": who}


async def _task(client, rid, hdr, title="被等的卡"):
    return (await client.post(f"/api/rooms/{rid}/board/tasks",
                              json={"title": title},
                              headers=hdr)).json()["id"]


async def _inbox(client, who):
    return (await client.get("/api/board/notices",
                             headers={"X-Session-Key": who})).json()


async def test_only_the_watchers_hear_about_it(tmp_path):
    """🚨 兩半一起驗。少任何一半，錯誤的實作都會通過。"""
    app, client = await _client(tmp_path, "twohalves")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            await _join(client, rid, bid, hdr, "claude-n", "沒在等的人")
            tid = await _task(client, rid, hdr)

            r = await client.post(f"/api/boards/{bid}/watches",
                                  json={"item_kind": "task", "item_id": tid},
                                  headers=watcher)
            assert r.status_code == 200 and r.json()["watcher_count"] == 1

            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            done = await client.post(f"/api/board/tasks/{tid}/status",
                                     json={"status": "done"}, headers=hdr)
            assert done.status_code == 200

            got = await _inbox(client, "claude-w")
            assert got["unread_count"] == 1, "追蹤者沒收到，功能等於不存在"
            assert got["notices"][0]["event_type"] == "task_done"
            assert got["notices"][0]["item_title"] == "被等的卡"

            quiet = await _inbox(client, "claude-n")
            assert quiet["unread_count"] == 0, (
                "沒在追蹤的人也收到了——那就是「通知所有人」，功能沒有意義")

            # 做出這次變更的人自己不收：他就是按下那個按鈕的人
            assert (await _inbox(client, "claude-h"))["unread_count"] == 0


async def test_in_progress_does_not_fire(tmp_path):
    """只有完成／取消／重新打開會發。

    每一次狀態變動都發的話，追蹤就跟訂閱整塊板沒有差別——而艾斯維爾要的
    正是「不需要通知所有人」。
    """
    app, client = await _client(tmp_path, "noise")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            tid = await _task(client, rid, hdr)
            await client.post(f"/api/boards/{bid}/watches",
                              json={"item_kind": "task", "item_id": tid},
                              headers=watcher)
            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "blocked"}, headers=hdr)
            assert (await _inbox(client, "claude-w"))["unread_count"] == 0


async def test_reopening_a_card_tells_the_people_who_were_waiting(tmp_path):
    """**「你等的那張卡又打開了」跟完成一樣重要。**

    漏掉的話，等的人會以為可以動工了——而那個誤會不會有任何地方報錯。
    """
    app, client = await _client(tmp_path, "reopen")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            tid = await _task(client, rid, hdr)
            await client.post(f"/api/boards/{bid}/watches",
                              json={"item_kind": "task", "item_id": tid},
                              headers=watcher)
            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=hdr)
            # 人類把它重新打開
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            kinds = [n["event_type"]
                     for n in (await _inbox(client, "claude-w"))["notices"]]
            assert "task_reopened" in kinds, "卡被重新打開，等的人沒被告知"


async def test_a_watch_survives_a_restart(tmp_path):
    """⚠️ 追蹤綁 `actor_key` 不綁 participant。

    agent 重啟會換一個 participant_id。綁 participant 的話，追蹤就在那一刻
    **靜靜地斷了**——而斷掉的當下沒有任何地方會報錯，他只是再也收不到。
    """
    app, client = await _client(tmp_path, "restart")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            tid = await _task(client, rid, hdr)
            await client.post(f"/api/boards/{bid}/watches",
                              json={"item_kind": "task", "item_id": tid},
                              headers=watcher)

            # 重啟：同一個 session_key，新的 participant
            again = await client.post(f"/api/rooms/{rid}/join", json={
                "kind": "claude", "role": "agent", "session_key": "claude-w",
                "preferred_name": "等的人"})
            assert again.json()["participant_id"] is not None

            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=hdr)
            assert (await _inbox(client, "claude-w"))["unread_count"] == 1


async def test_the_notice_waits_for_you_to_come_back(tmp_path):
    """**落地而不是只推播。**

    追蹤者在卡完成的當下很可能不在任何房裡——而那正是他要追蹤、而不是自己
    盯著的理由。只靠當下叫醒的話，功能會在最需要它的情境下失效：
    你追的卡完成了，但你當時不在，於是你永遠不會知道。
    """
    app, client = await _client(tmp_path, "offline")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            tid = await _task(client, rid, hdr)
            await client.post(f"/api/boards/{bid}/watches",
                              json={"item_kind": "task", "item_id": tid},
                              headers=watcher)
            # 離開房間——他現在不在任何掛接房裡
            await client.post(f"/api/rooms/{rid}/leave",
                              json={"participant_id":
                                    watcher["X-Participant-Id"]},
                              headers=watcher)

            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=hdr)

            got = await _inbox(client, "claude-w")
            assert got["unread_count"] == 1, (
                "他當時不在房裡，通知就蒸發了——那是這個功能最該有用的時候")


async def test_marking_read_only_touches_your_own(tmp_path):
    """已讀只動自己的。

    `actor_key` 從呼叫者身上取，不從參數帶——從參數帶的話，任何人都能把
    別人的未讀清掉，而對方看不出發生過什麼。
    """
    app, client = await _client(tmp_path, "read")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            a = await _join(client, rid, bid, hdr, "claude-a", "A")
            b = await _join(client, rid, bid, hdr, "claude-b", "B")
            tid = await _task(client, rid, hdr)
            for who in (a, b):
                await client.post(f"/api/boards/{bid}/watches",
                                  json={"item_kind": "task", "item_id": tid},
                                  headers=who)
            await client.post(f"/api/board/tasks/{tid}/claim", headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "in_progress"}, headers=hdr)
            await client.post(f"/api/board/tasks/{tid}/status",
                              json={"status": "done"}, headers=hdr)

            assert (await _inbox(client, "claude-a"))["unread_count"] == 1
            r = await client.post("/api/board/notices/read?all_notices=true",
                                  headers=a)
            assert r.json()["marked"] == 1
            assert (await _inbox(client, "claude-a"))["unread_count"] == 0
            assert (await _inbox(client, "claude-b"))["unread_count"] == 1, \
                "A 標已讀把 B 的也清掉了"


async def test_you_cannot_watch_a_card_on_another_board(tmp_path):
    """追蹤別塊板的卡**不會報錯**，只是通知永遠不來。

    看起來就像「這張卡還沒完成」，而它其實根本不在你看的那塊板上。
    """
    app, client = await _client(tmp_path, "cross")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            other = (await client.post("/api/boards", json={"name": "另一塊"},
                                       headers=hdr)).json()["id"]
            tid = await _task(client, rid, hdr)
            r = await client.post(f"/api/boards/{other}/watches",
                                  json={"item_kind": "task", "item_id": tid},
                                  headers=hdr)
            assert r.status_code == 404
            assert r.json()["detail"]["code"] == "item_not_on_board"


async def test_the_count_rides_on_the_card(tmp_path):
    """`watcher_count` 與 `watching` 放在 delta 的卡上，不另開一支 API。

    要另外打一支才畫得出來的數字，**就永遠不會出現在卡上**
    （@開發Novia (UI) 2026-09-02）——而認領者該知道自己卡住了誰。
    """
    app, client = await _client(tmp_path, "count")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            tid = await _task(client, rid, hdr)
            await client.post(f"/api/boards/{bid}/watches",
                              json={"item_kind": "task", "item_id": tid},
                              headers=watcher)

            # 追蹤者自己看：watching 為 true
            mine = (await client.get(f"/api/boards/{bid}", headers=watcher)
                    ).json()
            card = next(t for t in mine["tasks"] if t["id"] == tid)
            assert card["watcher_count"] == 1 and card["watching"] is True

            # 認領者看：數字在，但不是他在追
            theirs = (await client.get(f"/api/boards/{bid}", headers=hdr)
                      ).json()
            card = next(t for t in theirs["tasks"] if t["id"] == tid)
            assert card["watcher_count"] == 1 and card["watching"] is False

            # v1 路由（房軸）也看得到——舊 client 不該因為沒升級就少一塊資訊
            v1 = (await client.get(f"/api/rooms/{rid}/board",
                                   headers=watcher)).json()
            card = next(t for t in v1["tasks"] if t["id"] == tid)
            assert card["watcher_count"] == 1 and card["watching"] is True


async def test_watching_moves_the_seq_so_the_count_reaches_the_card(tmp_path):
    """追蹤**要**推進水位，而且要推那張卡自己的號。

    ⚠️ 我原本釘的是相反的方向（「追蹤不改板上的內容，所以不推 seq」），
    而那條測試綠著、守的卻是一個錯誤的決定——`watcher_count` 就放在卡的
    payload 裡，不推的話**那個欄位永遠不會出現在任何一次 delta**，只能靠
    整份重讀補值（審核用Codex-2 2026-09-02 指出）。

    只推板的水位也不夠：delta 撈的是 `board_seq > cursor` 的**列**，卡自己
    的號沒動的話，client 收到「板動了」卻撈不到任何東西——那比不推還糟，
    它會讓人以為變更遺失了。
    """
    app, client = await _client(tmp_path, "seq")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr)
            before = (await client.get(f"/api/boards/{bid}",
                                       headers=hdr)).json()["board_seq"]
            await client.post(f"/api/boards/{bid}/watches",
                              json={"item_kind": "task", "item_id": tid},
                              headers=hdr)
            after = (await client.get(f"/api/boards/{bid}",
                                      headers=hdr)).json()["board_seq"]
            assert after > before

            # 拿舊 cursor 讀增量，那張卡要在裡面，而且帶著新的數字
            delta = (await client.get(
                f"/api/boards/{bid}?after_board_seq={before}",
                headers=hdr)).json()
            card = next((t for t in delta["tasks"] if t["id"] == tid), None)
            assert card is not None, (
                "板的水位動了，但卡沒有出現在增量裡——client 會以為變更遺失")
            assert card["watcher_count"] == 1 and card["watching"] is True

            # 取消追蹤同理；重複取消不該讓整塊板再動一次
            mid = (await client.get(f"/api/boards/{bid}",
                                    headers=hdr)).json()["board_seq"]
            await client.delete(
                f"/api/boards/{bid}/watches?item_kind=task&item_id={tid}",
                headers=hdr)
            gone = (await client.get(f"/api/boards/{bid}",
                                     headers=hdr)).json()["board_seq"]
            assert gone > mid
            await client.delete(
                f"/api/boards/{bid}/watches?item_kind=task&item_id={tid}",
                headers=hdr)
            assert (await client.get(f"/api/boards/{bid}",
                                     headers=hdr)).json()["board_seq"] == gone


async def test_a_board_with_no_live_room_refuses_a_new_watch(tmp_path):
    """新建追蹤時，**零 active room 明確拒絕**（艾斯維爾裁決 2026-09-02）。

    ⚠️ 這與「已經在追的人遇到降級」處置刻意不同：現在就知道沒有地方叫醒
    你，總比先答應下來再讓你空等好。

    判準是**活著的**房，不是 `board_room` 的列數——把最後一間房封存掉會留
    下「掛接數 1、卻沒有任何人叫得醒」的狀態，而那從計數上看起來完全正常
    （@測試Novia T13）。
    """
    app, client = await _client(tmp_path, "noroom")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr)
            ok = await client.post(f"/api/boards/{bid}/watches",
                                   json={"item_kind": "task", "item_id": tid},
                                   headers=hdr)
            assert ok.json()["delivery"] == "room_and_inbox"

            await client.delete(f"/api/boards/{bid}/rooms/{rid}", headers=hdr)
            r = await client.post(f"/api/boards/{bid}/watches",
                                  json={"item_kind": "task", "item_id": tid},
                                  headers=hdr)
            assert r.status_code == 409
            assert r.json()["detail"]["code"] == "board_has_no_room"


async def test_an_archived_room_does_not_count_as_somewhere_to_wake_you(
        tmp_path):
    """封存最後一間房與解除掛接**是同一個狀態**，只是計數看起來不一樣。"""
    app, client = await _client(tmp_path, "archivedroom")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            tid = await _task(client, rid, hdr)
            await client.post(f"/api/rooms/{rid}/archive", headers=hdr)
            r = await client.post(f"/api/boards/{bid}/watches",
                                  json={"item_kind": "task", "item_id": tid},
                                  headers=hdr)
            assert r.status_code == 409, (
                "房封存了還收下追蹤——board_room 的列還在，但沒有人叫得醒")


async def test_detaching_the_last_room_tells_the_watchers_not_the_operator(
        tmp_path):
    """降級要通知**追蹤者**，而且**每個人一筆**。

    解除掛接的是 A，等在卡上的是 B 和 C——這兩群多半不重疊，給 A 看一個
    警告等於沒說（@開發Novia (UI) 2026-09-02）。而同一個人追十張卡不該被
    洗十次（審核用Codex-2）。

    ⚠️ **不清掉任何追蹤**：那是使用者的意圖，不是我們可以代為決定的。
    """
    app, client = await _client(tmp_path, "degrade")
    async with client:
        async with app.router.lifespan_context(app):
            rid, bid, hdr = await _room_board(client)
            watcher = await _join(client, rid, bid, hdr, "claude-w", "等的人")
            first = await _task(client, rid, hdr, "卡一")
            second = await _task(client, rid, hdr, "卡二")
            for tid in (first, second):
                await client.post(f"/api/boards/{bid}/watches",
                                  json={"item_kind": "task", "item_id": tid},
                                  headers=watcher)

            out = await client.delete(f"/api/boards/{bid}/rooms/{rid}",
                                      headers=hdr)
            assert out.json()["degraded_watchers"] == ["claude-w"]

            got = await _inbox(client, "claude-w")
            degraded = [n for n in got["notices"]
                        if n["event_type"] == "delivery_degraded"]
            assert len(degraded) == 1, (
                f"追蹤兩張卡就收到 {len(degraded)} 筆降級通知——"
                "同一個人追十張卡會被洗十次")

            # 操作的人不是受影響的人，他不該收到
            assert not [n for n in (await _inbox(client, "claude-h"))["notices"]
                        if n["event_type"] == "delivery_degraded"]

            # 追蹤本身留著，一個都沒被清掉
            watches = (await client.get(f"/api/boards/{bid}/watches",
                                        headers=watcher)).json()["watches"]
            assert len(watches) == 2, "降級把使用者的追蹤清掉了"
