"""從備份還原 Hub 的資料庫與附件。

    python scripts/restore.py --list                  # 有哪些備份
    python scripts/restore.py --from backups/2026...  # 還原那一份
    python scripts/restore.py --list --json           # 給 App 解析用

🔴 **這是這個 kit 唯一會毀掉現有資料的操作**，所以三道閘缺一不可：

1. **Hub 必須沒在跑。** SQLite 的 db 被開著時換掉檔案，連著的那個進程仍握著
   舊的 inode／handle，寫回去會把還原的東西蓋掉——而**當下完全看不出來**，
   要到下次重啟才發現還原「沒有生效」。
2. **還原前強制先備份現況。** 還原是覆蓋，發現拿錯備份時原件已經沒了。
   這一步不給關掉的選項：省下的幾秒，代價是唯一的退路。
3. **db 與 attachments 一起換。** 只還原 db 會造出「訊息都在、圖全 410」的
   狀態，正是 `backup.py` 那支在防的事。

⚠️ **`server/.env` 不在備份裡，也不會被還原碰到。** token、port 這些設定
維持現況——還原的是資料，不是組態。有人會預期還原把 token 一起帶回來，
所以這件事要講出來而不是讓人自己發現。
"""

from __future__ import annotations

import argparse
import json
import shutil
import socket
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

# backup.py 的檔名有連字號不能直接 import，用 importlib 載入同一份實作
# ——路徑與 .env 的解析只能有一份，兩份會在某次改動後悄悄分岔
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "_chatroom_backup", ROOT / "scripts" / "backup.py"
)
assert _spec and _spec.loader
_backup = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_backup)


def hub_is_running(repo: Path) -> tuple[bool, str]:
    """Hub 是不是還在跑。回傳 (在跑, 說明)。

    判準用「那個 port 有沒有人在聽」而不是找進程名：**服務模式、前景模式、
    別人手動起的，三種都要擋**，而它們的進程長相不同，唯一共通的是佔著同
    一個 port。
    """
    env = _backup.load_env(repo / "server" / ".env")
    port = env.get("CHATROOM_PORT", "8787")
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=1.5):
            return True, f"127.0.0.1:{port} 還有人在聽"
    except (OSError, ValueError):
        return False, f"127.0.0.1:{port} 沒有人在聽"


def list_backups(repo: Path | None = None) -> list[dict[str, object]]:
    """列出 backups/ 底下的備份，新的在前。

    沒有 manifest 的目錄**仍然列出來**但標記 `complete: False`——那多半是
    手動放進去的、或上次備份中途失敗留下的。藏起來的話，使用者會在畫面上
    找不到一個他明明看得到資料夾的東西。
    """
    base = (repo or ROOT) / "backups"
    if not base.exists():
        return []
    items: list[dict[str, object]] = []
    for entry in sorted(base.iterdir(), reverse=True):
        if not entry.is_dir():
            continue
        manifest_file = entry / "manifest.json"
        info: dict[str, object] = {
            "path": str(entry),
            "name": entry.name,
            "complete": False,
            "has_db": (entry / "chatroom.db").exists(),
            "has_attachments": (entry / "attachments").exists(),
        }
        if manifest_file.exists():
            try:
                manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
                if isinstance(manifest, dict):
                    info.update({
                        "complete": True,
                        "created_at": manifest.get("created_at", ""),
                        "db_bytes": manifest.get("db_bytes", 0),
                        "attachment_files": manifest.get("attachment_files", 0),
                        "attachments_existed": manifest.get(
                            "attachments_existed", False),
                    })
            except (OSError, ValueError):
                pass
        items.append(info)
    return items


def restore(source: Path, repo: Path | None = None) -> dict[str, object]:
    base = repo or ROOT
    source = source.resolve()

    src_db = source / "chatroom.db"
    if not src_db.exists():
        raise FileNotFoundError(f"這份備份裡沒有 chatroom.db：{source}")
    # 打得開才算數。一個 0 位元組或截斷的檔案「存在」，而拿它覆蓋掉正在用的
    # 資料庫之後才發現打不開，那時原件已經被換走了
    try:
        probe = sqlite3.connect(f"file:{src_db}?mode=ro", uri=True)
        try:
            probe.execute("PRAGMA schema_version").fetchone()
        finally:
            probe.close()
    except sqlite3.Error as exc:
        raise ValueError(f"這份備份的資料庫打不開，拒絕還原：{exc}") from exc

    running, detail = hub_is_running(base)
    if running:
        raise RuntimeError(
            f"Hub 還在跑（{detail}）。請先停止 Hub 再還原——"
            "在它跑著的時候換掉資料庫，還原會看起來成功但不會生效。"
        )

    # 閘二：先備份現況。這一步失敗就整個中止，不進入覆蓋階段
    safety = _backup.backup(repo=base)

    dst_db, dst_attach = _backup.resolve_paths(
        _backup.load_env(base / "server" / ".env"), base
    )
    stamp = datetime.now(timezone.utc).astimezone().strftime("%Y%m%d-%H%M%S")

    # db：先落到同目錄的暫存檔再 os.replace——跨檔案系統的 replace 會失敗，
    # 而同目錄保證在同一個檔案系統上
    tmp_db = dst_db.with_name(f"{dst_db.name}.restoring-{stamp}")
    shutil.copy2(src_db, tmp_db)
    tmp_db.replace(dst_db)

    # WAL 與 SHM 是舊資料庫的，留著會讓 SQLite 拿它們去「修復」剛換上的檔案
    for suffix in ("-wal", "-shm"):
        dst_db.with_name(dst_db.name + suffix).unlink(missing_ok=True)

    src_attach = source / "attachments"
    attach_restored = False
    if src_attach.exists():
        staging = dst_attach.with_name(f"{dst_attach.name}.restoring-{stamp}")
        if staging.exists():
            shutil.rmtree(staging)
        shutil.copytree(src_attach, staging)
        # 先把現有的挪開再換上，中途失敗時兩份都還在
        retired = dst_attach.with_name(f"{dst_attach.name}.replaced-{stamp}")
        if dst_attach.exists():
            dst_attach.rename(retired)
        staging.rename(dst_attach)
        if retired.exists():
            shutil.rmtree(retired, ignore_errors=True)
        attach_restored = True

    return {
        "ok": True,
        "restored_from": str(source),
        "db": str(dst_db),
        "attachments_restored": attach_restored,
        # 講出來：這份是還原之前的現況，拿錯備份時從這裡退回去
        "safety_backup": safety["dest"],
        "note": "server/.env（token、port）沒有被動到——還原的是資料不是設定。",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="從備份還原 Hub 的資料")
    parser.add_argument("--list", action="store_true", help="列出可用備份")
    parser.add_argument("--from", dest="source", default="", help="要還原的備份目錄")
    parser.add_argument("--json", action="store_true", help="輸出 JSON（給 App 解析）")
    args = parser.parse_args(argv)

    if args.list:
        items = list_backups()
        if args.json:
            print(json.dumps({"ok": True, "backups": items}, ensure_ascii=False))
            return 0
        if not items:
            print("還沒有任何備份。")
            return 0
        for item in items:
            mark = "" if item["complete"] else "  ⚠️ 沒有 manifest，來歷不明"
            print(f"{item['name']}{mark}")
        return 0

    if not args.source:
        parser.error("要還原請給 --from <備份目錄>，或用 --list 看有哪些")

    try:
        result = restore(Path(args.source))
    except Exception as exc:  # noqa: BLE001 — CLI 邊界，錯誤要講人話
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"還原失敗：{exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
        return 0

    print(f"已還原：{result['restored_from']}")
    print(f"還原前的現況備份在：{result['safety_backup']}")
    print(result["note"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
