"""把翻譯鍵加進 App 的 ARB（模板 zh_TW ＋ en），多個工作者同時呼叫也安全。

    python scripts/l10n_add.py --key chatSendButton --zh "送出" --en "Send" --desc "輸入框旁的送出鈕"
    python scripts/l10n_add.py --batch entries.json      # 一次加一批
    python scripts/l10n_add.py --sync-zh                 # 用 OpenCC 把 zh_TW 裡 zh 缺的鍵補成簡中

`entries.json` 是一個陣列，每項 `{"key", "zh", "en", "desc", "placeholders"?}`；
`placeholders` 直接是 ARB 的 `placeholders` 物件（例：`{"count": {"type": "int"}}`）。

規則：
- 鍵已存在且文字相同 ⇒ 跳過；文字不同 ⇒ 報錯不寫（要改既有鍵請直接改 ARB）。
- 三份 ARB 都用 UTF-8、兩空白縮排、`ensure_ascii=False`；重寫時保留既有鍵的順序，新鍵接在最後。
- 寫入前拿 `lib/l10n/.l10n.lock`（O_EXCL 建檔）當鎖，拿不到就等；多個 agent 平行抽取不會互相蓋掉。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import OrderedDict
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

ROOT = Path(__file__).resolve().parent.parent
L10N = ROOT / "app" / "lib" / "l10n"
ARB = {
    "zh_TW": L10N / "app_zh_TW.arb",
    "en": L10N / "app_en.arb",
    "zh": L10N / "app_zh.arb",
}
LOCK = L10N / ".l10n.lock"


def _load(path: Path) -> OrderedDict:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=OrderedDict)


def _dump(path: Path, data: OrderedDict) -> None:
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


class _Lock:
    def __enter__(self):
        deadline = time.time() + 120
        while True:
            try:
                self.fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(self.fd, str(os.getpid()).encode())
                return self
            except FileExistsError:
                if time.time() > deadline:
                    raise SystemExit(f"✕ 等鎖逾時：{LOCK} 被佔著（若確定沒人在寫就手動刪掉它）")
                time.sleep(0.2)

    def __exit__(self, *exc):
        os.close(self.fd)
        try:
            LOCK.unlink()
        except FileNotFoundError:
            pass


def add_entries(entries: list[dict]) -> tuple[int, int]:
    """回傳 (新增數, 跳過數)。任何一筆衝突就整批不寫。"""
    for e in entries:
        for f in ("key", "zh", "en"):
            if not e.get(f):
                raise SystemExit(f"✕ 缺欄位 {f!r}：{e}")
        if e["key"].startswith("@") or not e["key"][0].islower():
            raise SystemExit(f"✕ 鍵要 lowerCamelCase：{e['key']}")
    with _Lock():
        tw, en = _load(ARB["zh_TW"]), _load(ARB["en"])
        added = skipped = 0
        for e in entries:
            k = e["key"]
            if k in tw:
                if tw[k] != e["zh"] or en.get(k) != e["en"]:
                    raise SystemExit(
                        f"✕ 鍵 {k} 已存在且文字不同（既有 zh={tw[k]!r} en={en.get(k)!r}），"
                        "整批未寫入；要改既有鍵請直接改 ARB")
                skipped += 1
                continue
            tw[k] = e["zh"]
            meta = OrderedDict()
            if e.get("desc"):
                meta["description"] = e["desc"]
            if e.get("placeholders"):
                meta["placeholders"] = e["placeholders"]
            tw["@" + k] = meta
            en[k] = e["en"]
            added += 1
        if added:
            _dump(ARB["zh_TW"], tw)
            _dump(ARB["en"], en)
    return added, skipped


def sync_zh() -> int:
    from opencc import OpenCC  # opencc-python-reimplemented（.venv 已裝）

    cc = OpenCC("tw2s")
    with _Lock():
        tw, zh = _load(ARB["zh_TW"]), _load(ARB["zh"])
        n = 0
        for k, v in tw.items():
            if k.startswith("@") or k in zh:
                continue
            zh[k] = cc.convert(v)
            n += 1
        if n:
            _dump(ARB["zh"], zh)
    return n


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--key")
    p.add_argument("--zh")
    p.add_argument("--en")
    p.add_argument("--desc", default="")
    p.add_argument("--placeholders", help="JSON 物件字串")
    p.add_argument("--batch", type=Path, help="JSON 陣列檔")
    p.add_argument("--sync-zh", action="store_true")
    a = p.parse_args()
    if a.sync_zh:
        print(f"✓ zh 補了 {sync_zh()} 個鍵")
        return
    if a.batch:
        entries = json.loads(a.batch.read_text(encoding="utf-8"))
    elif a.key:
        e = {"key": a.key, "zh": a.zh, "en": a.en, "desc": a.desc}
        if a.placeholders:
            e["placeholders"] = json.loads(a.placeholders)
        entries = [e]
    else:
        p.error("要 --key 或 --batch 或 --sync-zh")
    added, skipped = add_entries(entries)
    print(f"✓ 新增 {added}、跳過 {skipped}（已存在且相同）")


if __name__ == "__main__":
    main()
