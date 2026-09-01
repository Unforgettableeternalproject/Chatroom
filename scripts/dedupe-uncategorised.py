#!/usr/bin/env python
"""把每個房間重複的「未分類」收斂成一組，讓 partial unique index 建得起來。

背景：`_uncategorised_checklist` 是 SELECT-then-INSERT，中間有 await 讓出點
——並行建立無 parent 的 Task 時，多路會各自讀到空、各自 INSERT，於是同一個
房間長出好幾組「未分類」週期與清單（審核用 Codex 實測 12 路建出 12 組）。

修法是把「固定名字找得回同一個」這條不變式寫進資料庫（partial unique
index），但 **index 加在既有表上，只要現存資料已經違反它就會直接建立失敗，
連帶讓 DB 開不起來**。所以這支必須先跑。

預設是 dry-run：只讀、只印，不寫任何東西。確認過再加 --apply。

收斂規則：每房保留 **created_at 最早** 的那一組，其餘組別的 Task 搬過去，
空掉的殼軟刪（deleted=1）。保留最早的那組是因為它的 board_seq 最小，
既有 client 的增量游標多半已經看過它。
"""

import argparse
import sqlite3
import sys
from datetime import datetime, timezone

TITLE = "未分類"


def _connect(path: str, writable: bool):
    if writable:
        return sqlite3.connect(path)
    # 唯讀開啟：Hub 可能正跑著，這支不該干擾它
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    return con


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("db", help="chatroom.db 的路徑")
    ap.add_argument("--apply", action="store_true",
                    help="實際寫入。不給的話只印出將要做什麼")
    args = ap.parse_args()

    con = _connect(args.db, args.apply)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    rooms = cur.execute(
        "SELECT room_id, COUNT(*) AS n FROM board_objective"
        " WHERE title=? AND deleted=0 GROUP BY room_id HAVING n > 1",
        (TITLE,),
    ).fetchall()

    total_obj = cur.execute(
        "SELECT COUNT(*) AS n FROM board_objective WHERE title=? AND deleted=0",
        (TITLE,),
    ).fetchone()["n"]
    total_rooms = cur.execute(
        "SELECT COUNT(DISTINCT room_id) AS n FROM board_objective"
        " WHERE title=? AND deleted=0", (TITLE,),
    ).fetchone()["n"]

    print(f"「{TITLE}」週期共 {total_obj} 個，分佈在 {total_rooms} 個房間")
    if not rooms:
        print("沒有任何房間有重複——unique index 建得起來，這支不必 apply")
        return 0

    print(f"其中 {len(rooms)} 個房間有重複：\n")
    moved_total = 0
    sealed_total = 0
    now = datetime.now(timezone.utc).isoformat()

    for room in rooms:
        rid = room["room_id"]
        objs = cur.execute(
            "SELECT id, created_at, board_seq FROM board_objective"
            " WHERE room_id=? AND title=? AND deleted=0"
            " ORDER BY created_at, board_seq", (rid, TITLE),
        ).fetchall()
        keep = objs[0]
        drop = objs[1:]
        # 保留組的「未分類」清單：搬過去的 Task 要有落點
        keep_cl = cur.execute(
            "SELECT id FROM board_checklist WHERE objective_id=? AND title=?"
            " AND deleted=0 ORDER BY created_at, board_seq LIMIT 1",
            (keep["id"], TITLE),
        ).fetchone()
        if keep_cl is None:
            print(f"  ⚠️ {rid}：保留組 {keep['id'][:8]} 底下沒有「{TITLE}」清單，"
                  "跳過這一房（人工處理）")
            continue

        room_moved = 0
        for o in drop:
            cls = cur.execute(
                "SELECT id FROM board_checklist WHERE objective_id=? AND deleted=0",
                (o["id"],),
            ).fetchall()
            for c in cls:
                n = cur.execute(
                    "SELECT COUNT(*) AS n FROM board_task"
                    " WHERE checklist_id=? AND deleted=0", (c["id"],),
                ).fetchone()["n"]
                room_moved += n
                if args.apply and n:
                    cur.execute(
                        "UPDATE board_task SET checklist_id=? WHERE checklist_id=?"
                        " AND deleted=0", (keep_cl["id"], c["id"]),
                    )
                if args.apply:
                    cur.execute(
                        "UPDATE board_checklist SET deleted=1, deleted_at=?"
                        " WHERE id=?", (now, c["id"]),
                    )
            if args.apply:
                cur.execute(
                    "UPDATE board_objective SET deleted=1, deleted_at=?"
                    " WHERE id=?", (now, o["id"]),
                )
        moved_total += room_moved
        sealed_total += len(drop)
        print(f"  {rid}：{len(objs)} 組 → 1 組"
              f"（保留 {keep['id'][:8]}，軟刪 {len(drop)} 組，"
              f"搬 {room_moved} 張 Task）")

    print(f"\n合計：軟刪 {sealed_total} 組空殼，搬動 {moved_total} 張 Task")
    if args.apply:
        con.commit()
        print("已寫入。")
    else:
        print("這是 dry-run，什麼都沒動。確認無誤後加 --apply。")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
