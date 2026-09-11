"""換掉 Hub 的 token。

    python scripts/rotate-token.py                 # 產生一把新的
    python scripts/rotate-token.py --token <明碼>   # 指定一把（少用）
    python scripts/rotate-token.py --json          # 給 App 解析用

🔴 **換完要重啟 Hub 才生效，而且所有成員都要重拿。** token 是 Hub 啟動時
讀進設定的，改了 `.env` 而沒重啟＝什麼都沒發生（舊 token 照樣通、新的不通）；
重啟之後則是反過來——**每一個 agent、每一台 App 在那一刻全部斷線**，
直到他們拿到新的那把。這不是「成本很低」的操作，成本低的是改檔案那一步。

🔴 **舊 token 會留在 `.env.bak-<時間戳>` 裡。** 換完發現有人拿不到新的、
要先退回去時，那份是唯一的退路——token 是隨機字串，記不住也推不出來。

⚠️ **不先截斷再寫**：寫暫存檔再 `os.replace` 原子換上。直接 `open(.., "w")`
在寫到一半失敗時留下的是一個 0 位元組的 `.env`，那時 Hub 起不來、
而原本只是想換一把 token。
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

KEY = "CHATROOM_TOKEN"


def generate_token() -> str:
    """32 位元組的 urlsafe 隨機字串。與 `install.py` 產生初始 token 的方式一致。"""
    return secrets.token_urlsafe(32)


def rotate(token: str | None = None, repo: Path | None = None) -> dict[str, object]:
    base = repo or REPO
    env_file = base / "server" / ".env"
    if not env_file.exists():
        raise FileNotFoundError(f"找不到設定檔：{env_file}")

    new_token = token or generate_token()
    if not new_token.strip():
        raise ValueError("token 不可以是空的——空 token 會讓 Hub 對所有人敞開")
    # 🔴 不 strip 使用者給的值。前後空白是 token 的一部分還是手滑貼進來的，
    # 這裡分不出來；而 strip 掉之後寫進去的那把與他手上那把不一樣，
    # 症狀是「明明複製貼上還是認證失敗」
    if new_token != new_token.strip():
        raise ValueError("token 前後不可以有空白——寫進 .env 之後讀回來會不一樣")

    original = env_file.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)

    old_token = ""
    replaced = False
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not replaced and stripped.startswith(f"{KEY}="):
            old_token = stripped[len(KEY) + 1 :].strip()
            newline = "\n" if line.endswith("\n") else ""
            out.append(f"{KEY}={new_token}{newline}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        # 原本沒有這一行——補在檔尾，而不是靜靜換不掉
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"{KEY}={new_token}\n")

    stamp = datetime.now(timezone.utc).astimezone().strftime("%Y%m%d-%H%M%S")
    backup_file = env_file.with_name(f".env.bak-{stamp}")
    backup_file.write_text(original, encoding="utf-8")

    tmp = env_file.with_name(f".env.tmp-{stamp}")
    tmp.write_text("".join(out), encoding="utf-8")
    os.replace(tmp, env_file)

    return {
        "ok": True,
        "token": new_token,
        "had_previous": bool(old_token),
        "backup": str(backup_file),
        "env_file": str(env_file),
        # 講清楚現在是什麼狀態：檔案改了，跑著的 Hub 還沒有
        "requires_restart": True,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="換掉 Chatroom Hub 的 token")
    parser.add_argument("--token", default="", help="指定 token（省略則隨機產生）")
    parser.add_argument("--json", action="store_true", help="輸出 JSON（給 App 解析）")
    args = parser.parse_args(argv)

    try:
        result = rotate(args.token or None)
    except Exception as exc:  # noqa: BLE001 — CLI 邊界，錯誤要講人話
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"換 token 失敗：{exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
        return 0

    print(f"新 token：{result['token']}")
    print(f"舊設定備份在：{result['backup']}")
    print("⚠️ 還沒生效——要重啟 Hub。重啟的那一刻所有成員會斷線，")
    print("   直到他們拿到上面這把新的。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
