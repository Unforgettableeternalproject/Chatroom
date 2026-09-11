"""Chatroom Hub 備份——資料庫與附件一起帶走。

    python scripts/backup.py                 # 備份到 backups/YYYYMMDD-HHMMSS/
    python scripts/backup.py --out D:/somewhere
    python scripts/backup.py --json          # 給 App 解析用

🔴 **db 與 attachments/ 是兩份東西。** 只備份 db 的話，還原之後訊息都在、
圖全部變 410——因為附件實體是內容定址存在檔案系統上的，DB 裡只有雜湊。
這個腳本兩份一起收，而且**兩份都成功才算成功**（見 `docs/KIT-UI-DESIGN-BRIEF.md`
§4.3 最後一列）。

🔴 **不停 Hub 也能跑。** 用 `VACUUM INTO` 而不是複製檔案：它在一個交易裡
讀出一致的快照，WAL 裡已提交的內容也會進去。直接複製 `chatroom.db` 則會
拿到一個缺 WAL 的半截檔案，而它**開得起來**——壞在看不見的地方。

⚠️ 附件是在 db 快照**之後**複製的，所以備份期間新上傳的附件可能有實體
而 DB 裡沒有紀錄。那個方向是安全的（多出來的檔案沒人參照）；反過來
（DB 有紀錄、實體沒複製到）才會變 410，而先 db 後附件正是為了避免它。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def load_env(env_file: Path) -> dict[str, str]:
    """讀 server/.env。格式與 App 端 `hostEnvProvider` 的解析一致：
    忽略空行與 `#` 開頭，只切第一個 `=`（值裡可能還有 `=`）。"""
    values: dict[str, str] = {}
    if not env_file.exists():
        return values
    for line in env_file.read_text(encoding="utf-8").splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        at = text.find("=")
        if at <= 0:
            continue
        values[text[:at].strip()] = text[at + 1 :].strip()
    return values


def resolve_paths(env: dict[str, str], repo: Path | None = None) -> tuple[Path, Path]:
    """回傳 (db 路徑, 附件目錄)。

    兩者的預設值都跟著 server 端走：db 相對 `server/`，附件在 db 旁邊的
    `attachments/`（`app.py::_attachment_root`）。這裡**不重新定義**它們，
    定義在 server，這裡只是照著算。
    """
    server_dir = (repo or REPO) / "server"
    db = Path(env.get("CHATROOM_DB", "chatroom.db"))
    if not db.is_absolute():
        db = server_dir / db
    db = db.resolve()

    raw_attach = env.get("CHATROOM_ATTACHMENT_DIR", "")
    attach = Path(raw_attach).resolve() if raw_attach else db.parent / "attachments"
    return db, attach


def dir_stats(path: Path) -> tuple[int, int]:
    """(檔案數, 總位元組)。目錄不存在時回 (0, 0)。"""
    if not path.exists():
        return 0, 0
    count = 0
    total = 0
    for entry in path.rglob("*"):
        if entry.is_file():
            count += 1
            total += entry.stat().st_size
    return count, total


def backup(out_root: Path | None = None, repo: Path | None = None) -> dict[str, object]:
    base = repo or REPO
    env = load_env(base / "server" / ".env")
    db, attach = resolve_paths(env, base)

    if not db.exists():
        raise FileNotFoundError(f"找不到資料庫：{db}")

    stamp = datetime.now(timezone.utc).astimezone().strftime("%Y%m%d-%H%M%S")
    root = (out_root or base / "backups").resolve()
    dest = root / stamp
    # exist_ok=False：撞名表示同一秒跑了兩次，蓋掉的那份可能正是要保的那份
    dest.mkdir(parents=True, exist_ok=False)

    db_dest = dest / "chatroom.db"
    # VACUUM INTO 要求目標不存在——它自己就是「絕不覆寫」的，不必先刪
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        conn.execute("VACUUM INTO ?", (str(db_dest),))
    finally:
        conn.close()

    attach_dest = dest / "attachments"
    attach_files, attach_bytes = 0, 0
    if attach.exists():
        shutil.copytree(attach, attach_dest)
        attach_files, attach_bytes = dir_stats(attach_dest)

    manifest = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source_db": str(db),
        "source_attachments": str(attach),
        # 🔴 涵蓋範圍要寫進備份本身：還原的人必須看得出這份備份**包含什麼**。
        # 「attachments 0 個檔案」與「沒有備份 attachments」長得一樣，
        # 而它們在還原時的意義完全相反
        "attachments_existed": attach.exists(),
        "db_bytes": db_dest.stat().st_size,
        "attachment_files": attach_files,
        "attachment_bytes": attach_bytes,
    }
    (dest / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    return {"ok": True, "dest": str(dest), **manifest}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="備份 Chatroom Hub 的資料庫與附件")
    parser.add_argument("--out", default="", help="備份存放的根目錄（預設 backups/）")
    parser.add_argument("--json", action="store_true", help="輸出 JSON（給 App 解析）")
    args = parser.parse_args(argv)

    try:
        result = backup(Path(args.out) if args.out else None)
    except Exception as exc:  # noqa: BLE001 — CLI 邊界，錯誤要講人話
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"備份失敗：{exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
        return 0

    print(f"備份完成：{result['dest']}")
    print(f"  資料庫　 {result['db_bytes']:,} 位元組")
    if result["attachments_existed"]:
        print(f"  附件　　 {result['attachment_files']} 個檔案，"
              f"{result['attachment_bytes']:,} 位元組")
    else:
        # 講明白這是「來源就沒有」而不是「沒備份到」
        print(f"  附件　　 來源目錄不存在（{result['source_attachments']}），"
              "這份備份沒有附件")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
