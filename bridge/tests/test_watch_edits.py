"""編輯與撤回要叫得醒**跟這件事有關的人**（票 D4）。

`update_seq` 讓既有訊息重新入流，而 watcher 原本把它們一律跳過——註解寫的
是「釘選牆用 chatroom_read(pinned_only) 主動撈」。那對釘選成立：釘選是「這
段話很重要」，晚一點看到不損失什麼，而且有一個主動撈得回來的介面。

**對編輯與撤回不成立。** 沒有任何介面撈得回「我剛才讀到的那則被改掉了」，
agent 只會拿著一份過期的內容繼續工作，而且不會有任何地方報錯。

界線是「這則跟我有關」：我發的、或我被 @ 在裡面。別人改別人的話跟我無關，
而每一個事件都是一次打擾。
"""

import json

import pytest

from chatroom_mcp import watch
from chatroom_mcp.hub import HubClient

from conftest import FakeHub
from test_watch import events_from, make_watcher, ROOM

ME = {ROOM: {"participant_id": "me", "display_name": "Novia", "last_seq": 10}}


def _updates(fake_hub, *messages):
    fake_hub.json(
        "GET", f"/api/rooms/{ROOM}/updates",
        {"messages": list(messages), "you_were_mentioned": False,
         "last_seq": 10},
    )


def _msg(**kw):
    # `id` 一定要有——去重靠它。真實 Hub 每則都帶，fixture 缺了會讓
    # 「同一則的重複事件」測試靜靜地失效
    base = {
        "id": "msg-1",
        "seq": 5, "kind": "chat", "sender_id": "p9", "sender_name": "Bernie",
        "content": "改過的內容", "mentions": [], "pinned": False,
        "deleted": False,
    }
    base.update(kw)
    return base


def test_my_own_message_being_edited_wakes_me(
        fake_hub, tmp_path, monkeypatch, capsys):
    """我說的話被改了——即使改的人是我，那也是我最需要知道的一件事。

    刻意**不沿用**「自己發的不叫醒自己」那條：那條防的是「我剛說完話就被
    自己吵醒」，而這裡是「我說過的話現在長得不一樣了」。
    """
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(sender_id="me", edited_at="2026-08-31T10:00:00Z"))
    w.poll_room()
    ev = events_from(capsys)
    assert [e["event"] for e in ev] == ["message_edited"]
    assert ev[0]["seq"] == 5


def test_my_own_message_being_deleted_wakes_me(
        fake_hub, tmp_path, monkeypatch, capsys):
    """別人撤回我說的話，我一定要知道。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(sender_id="me", content="", deleted=True))
    w.poll_room()
    ev = events_from(capsys)
    assert [e["event"] for e in ev] == ["message_deleted"]


def test_a_message_that_mentioned_me_wakes_me_when_edited(
        fake_hub, tmp_path, monkeypatch, capsys):
    """我因為那個 mention 醒過一次；內容被改掉，我那次醒來的前提就沒了。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(mentions=["Novia"],
                            edited_at="2026-08-31T10:00:00Z"))
    w.poll_room()
    assert [e["event"] for e in events_from(capsys)] == ["message_edited"]


def test_other_peoples_edits_stay_quiet(
        fake_hub, tmp_path, monkeypatch, capsys):
    """別人改別人的話跟我無關——每個事件都是一次打擾。"""
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(edited_at="2026-08-31T10:00:00Z"))
    w.poll_room()
    assert events_from(capsys) == []


def test_pinning_my_message_is_still_quiet(
        fake_hub, tmp_path, monkeypatch, capsys):
    """釘選維持原樣不喚醒——它有主動撈得回來的介面，而編輯沒有。

    這條是防退化的：把「重新入流的訊息」整批放行會讓釘選也開始吵人，
    而房裡釘選的頻率比編輯高得多。
    """
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(sender_id="me", pinned=True))
    w.poll_room()
    assert events_from(capsys) == []


def test_system_messages_never_emit_edit_events(
        fake_hub, tmp_path, monkeypatch, capsys):
    """system 訊息的編輯事件不該存在——Hub 已經擋掉那個動作。

    join 訊息的 sender_id 就是加入者本人，只看「是不是我發的」會讓房間對
    事實的紀錄看起來像我說的話。
    """
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(kind="system", system_event="join",
                            sender_id="me",
                            edited_at="2026-08-31T10:00:00Z"))
    w.poll_room()
    assert events_from(capsys) == []


def test_an_unedited_old_message_does_not_emit(
        fake_hub, tmp_path, monkeypatch, capsys):
    """沒有 edited_at 也沒被刪的舊訊息重新入流時保持安靜。

    舊版 Hub 不回 `edited_at`——那時它也不支援編輯，安靜是對的。
    **降級不壞**：收不到新事件可以接受，崩掉不行。
    """
    w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                     state=ME)
    _updates(fake_hub, _msg(sender_id="me"))
    w.poll_room()
    assert events_from(capsys) == []


class TestStateIsNotAnEvent:
    """`edited_at` 是**狀態**不是事件——它一旦有值就永遠有值。

    審核用Codex 的 finding：訊息編輯過一次之後，之後**每一次** pin/unpin 讓
    它重新入流，watcher 都會再發一次 `message_edited`。看的人會以為那則又被
    改了一次，而它其實只是被釘了。

    判斷「這次的 update 是不是編輯」不能只看訊息現在長什麼樣，要看**跟上次
    看到的比有沒有變**。
    """

    def test_editing_once_emits_once(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        edited = _msg(sender_id="me", edited_at="2026-08-31T10:00:00Z")
        _updates(fake_hub, edited)
        w.poll_room()
        assert [e["event"] for e in events_from(capsys)] == ["message_edited"]

        # 同一則被釘選——`edited_at` 還在，但這次的變更不是編輯
        _updates(fake_hub, {**edited, "pinned": True})
        w.poll_room()
        assert events_from(capsys) == [], "釘選不該再發一次 message_edited"

    def test_a_second_real_edit_does_emit_again(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """真的又改了一次要再發——不能為了消除重複而把後續編輯一起吃掉。"""
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        _updates(fake_hub, _msg(sender_id="me",
                                edited_at="2026-08-31T10:00:00Z"))
        w.poll_room()
        capsys.readouterr()

        _updates(fake_hub, _msg(sender_id="me", content="又改了一次",
                                edited_at="2026-08-31T10:05:00Z"))
        w.poll_room()
        assert [e["event"] for e in events_from(capsys)] == ["message_edited"]

    def test_deleting_emits_once_too(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """`deleted` 同樣是黏著狀態。撤回的訊息不能被釘，但 update_seq 仍
        可能因為別的路徑再推進一次，那時不該再報一次撤回。"""
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        gone = _msg(sender_id="me", content="", deleted=True)
        _updates(fake_hub, gone)
        w.poll_room()
        assert [e["event"] for e in events_from(capsys)] == ["message_deleted"]

        _updates(fake_hub, gone)
        w.poll_room()
        assert events_from(capsys) == []


class TestUpdateKindIsTheSourceOfTruth:
    """事件來源是 Hub 的 `update_kind`，不是訊息現在長什麼樣。

    審核用Codex 指出簽章比對的兩個破口——它只回答「watcher 記不記得見過這個
    狀態」，回答不了「這次 update 為何發生」。而 watcher 會忘記：

    - **重啟**：`after_seq` 從 state 檔還原，記憶體裡的簽章表歸零
    - **淘汰**：簽章表有上限，而釘選牆的用途正是讓人回頭釘很舊的訊息

    兩種情況下，一次無關的釘選都會被報成「這則剛被編輯」。那不是延遲或重放，
    是**內容錯誤的通知**：讀的人會照著它去行動。
    """

    def test_pin_does_not_report_an_edit_even_with_no_memory(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """全新的 watcher（等同重啟後）看到一則早就編輯過、現在被釘的訊息。

        簽章比對在這裡必然誤報——它沒有「上一次」可比。`update_kind='pin'`
        才答得出這次是釘選。
        """
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        _updates(fake_hub, _msg(sender_id="me",
                                edited_at="2026-08-31T10:00:00Z",
                                pinned=True, update_kind="pin"))
        w.poll_room()
        assert events_from(capsys) == []

    def test_an_edit_still_reports_with_no_memory(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """反向：真的是編輯就要發，即使 watcher 沒有記憶。"""
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        _updates(fake_hub, _msg(sender_id="me",
                                edited_at="2026-08-31T10:00:00Z",
                                update_kind="edit"))
        w.poll_room()
        assert [e["event"] for e in events_from(capsys)] == ["message_edited"]

    def test_eviction_does_not_resurrect_a_stale_edit(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """簽章表被清空（模擬淘汰）之後，釘選仍然不該報成編輯。"""
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        _updates(fake_hub, _msg(sender_id="me",
                                edited_at="2026-08-31T10:00:00Z",
                                update_kind="edit"))
        w.poll_room()
        capsys.readouterr()
        w._seen_updates.clear()   # FIFO 淘汰掉了這一則

        _updates(fake_hub, _msg(sender_id="me",
                                edited_at="2026-08-31T10:00:00Z",
                                pinned=True, update_kind="pin"))
        w.poll_room()
        assert events_from(capsys) == []

    def test_old_hub_without_update_kind_falls_back(
            self, fake_hub, tmp_path, monkeypatch, capsys):
        """舊 Hub 不帶 `update_kind` 時退回簽章比對——降級不壞。

        那條路徑仍有兩個破口（重啟、淘汰），但它是舊 Hub 的既有行為，
        不是新開的洞：升 Hub 就好。
        """
        w = make_watcher(fake_hub, tmp_path, monkeypatch, "--room", ROOM,
                         state=ME)
        _updates(fake_hub, _msg(sender_id="me",
                                edited_at="2026-08-31T10:00:00Z"))
        w.poll_room()
        assert [e["event"] for e in events_from(capsys)] == ["message_edited"]
