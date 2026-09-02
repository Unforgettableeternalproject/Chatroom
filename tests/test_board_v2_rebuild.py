"""§11 步驟 8：把 item 三表重建成「不綁房間生命週期」的形狀。

v1 一房一板時，`room_id TEXT NOT NULL REFERENCES room(id)` 是對的。v2 之後
板是獨立實體，那條外鍵變成一個**會刪掉資料的約束**——`foreign_keys=ON`
之下，刪掉最後一間掛接房就等於刪掉板上的卡。

換表是這一整包裡唯一動到既有表結構的動作，所以這份測試同時守三件事：
換完之後外鍵真的沒了、**欄位一個都沒少**、以及既有資料一列不差。
"""

import pytest

from chatroom_server.db import MIGRATIONS, open_db

pytestmark = pytest.mark.asyncio

ITEM_TABLES = ("board_objective", "board_checklist", "board_task")


async def _cols(db, table):
    return {r["name"] for r in
            await (await db.execute(f"PRAGMA table_info({table})")).fetchall()}


async def _fks(db, table):
    return {(r["from"], r["table"]) for r in
            await (await db.execute(f"PRAGMA foreign_key_list({table})")
                   ).fetchall()}


async def test_room_and_participant_foreign_keys_are_gone(tmp_path):
    """卡不再綁房間與成員的生命週期。

    板內部的樹狀外鍵（objective_id / checklist_id）**要留著**：那是同一塊
    板裡的結構，沒有跨生命週期的問題，而它擋得住把卡掛到不存在的清單上。
    """
    db = await open_db(str(tmp_path / "fk.db"))
    for table in ITEM_TABLES:
        targets = {t for _, t in await _fks(db, table)}
        assert "room" not in targets, f"{table} 還綁著 room"
        assert "participant" not in targets, f"{table} 還綁著 participant"
    assert ("objective_id", "board_objective") in await _fks(
        db, "board_checklist")
    assert ("checklist_id", "board_checklist") in await _fks(db, "board_task")
    await db.close()


async def test_rebuild_keeps_every_column(tmp_path):
    """**換表時漏一欄不會報錯**——它會在複製時被靜靜丟掉，而表看起來
    一切正常。這條拿 MIGRATIONS 對帳，讓「漏了」變成一個查得到的事實。
    """
    db = await open_db(str(tmp_path / "cols.db"))
    for table in ITEM_TABLES:
        have = await _cols(db, table)
        want = {col for t, col, _ in MIGRATIONS if t == table}
        missing = want - have
        assert not missing, (
            f"{table} 換表後少了這些欄位：{sorted(missing)}。"
            "db.py 的 REBUILT_TABLES 要跟著 MIGRATIONS 一起改")
    await db.close()


async def test_indexes_are_recreated(tmp_path):
    """索引不重建就是**安靜地變慢**，而慢到被發現時沒有人會想到是換表。"""
    db = await open_db(str(tmp_path / "idx.db"))
    rows = await (await db.execute(
        "SELECT name FROM sqlite_master WHERE type='index'")).fetchall()
    names = {r["name"] for r in rows}
    for want in ("idx_btask_room", "idx_btask_checklist", "idx_btask_claim",
                 "idx_bobjective_room", "idx_bchecklist_room",
                 "idx_bobjective_uncategorised",
                 "idx_bchecklist_uncategorised"):
        assert want in names, f"{want} 沒有被重建"
    await db.close()


async def test_existing_rows_survive_the_rebuild(tmp_path):
    """既有資料一列不差、內容一字不改。

    這是整個換表最危險的地方：複製寫錯了不會有任何地方報錯，只是資料
    悄悄變成另一份。
    """
    path = str(tmp_path / "data.db")
    db = await open_db(path)
    now = "2026-09-02T00:00:00+00:00"
    await db.execute(
        "INSERT INTO room (id, name, topic, status, created_at, next_seq)"
        " VALUES ('r1', '房', '', 'active', ?, 1)", (now,))
    await db.execute(
        "INSERT INTO board_objective (id, room_id, board_id, title,"
        " created_by_name, created_by_actor_key, board_seq, created_at)"
        " VALUES ('o1', 'r1', 'b1', '週期', 'Novia', 'claude-n', 3, ?)", (now,))
    await db.execute(
        "INSERT INTO board_checklist (id, room_id, board_id, objective_id,"
        " title, created_at) VALUES ('c1', 'r1', 'b1', 'o1', '階段', ?)", (now,))
    await db.execute(
        "INSERT INTO board_task (id, room_id, board_id, checklist_id, title,"
        " claim_actor_key, claim_state, claim_name, source_seq, created_at)"
        " VALUES ('t1', 'r1', 'b1', 'c1', '一件事', 'claude-n', 'held',"
        " 'Novia', 7, ?)", (now,))
    await db.commit()
    await db.close()

    # 重開＝再跑一次 open_db。已經換過表的庫不該被再換一次，資料也不該動
    db = await open_db(path)
    row = await (await db.execute(
        "SELECT * FROM board_task WHERE id='t1'")).fetchone()
    assert row["title"] == "一件事"
    assert row["claim_actor_key"] == "claude-n"
    assert row["claim_state"] == "held"
    assert row["claim_name"] == "Novia"
    assert row["source_seq"] == 7
    assert row["board_id"] == "b1"
    assert row["room_id"] == "r1", "provenance 不能在換表時被清掉"
    obj = await (await db.execute(
        "SELECT board_seq, created_by_actor_key FROM board_objective"
        " WHERE id='o1'")).fetchone()
    assert obj["board_seq"] == 3
    assert obj["created_by_actor_key"] == "claude-n"
    await db.close()


async def test_a_card_can_outlive_its_room(tmp_path):
    """房被刪掉之後，卡還在——這正是換表要換到的結果。"""
    db = await open_db(str(tmp_path / "outlive.db"))
    now = "2026-09-02T00:00:00+00:00"
    await db.execute(
        "INSERT INTO room (id, name, topic, status, created_at, next_seq)"
        " VALUES ('r1', '房', '', 'active', ?, 1)", (now,))
    await db.execute(
        "INSERT INTO board_objective (id, room_id, board_id, title, created_at)"
        " VALUES ('o1', 'r1', 'b1', '週期', ?)", (now,))
    await db.execute("DELETE FROM room WHERE id='r1'")
    await db.commit()
    row = await (await db.execute(
        "SELECT room_id FROM board_objective WHERE id='o1'")).fetchone()
    assert row is not None, "刪房把卡帶走了"
    assert row["room_id"] == "r1", "房不在了，但它曾經在哪裡要留著"
    await db.close()
