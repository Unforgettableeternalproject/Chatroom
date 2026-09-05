"""三步切房補驗（卡 cfaa966e ②）——對**跑著的 Hub** 驗，不是 in-process。

止血 B 防的是這個形狀（艾斯維爾 2026-09-03 實機撞到）：
  1. 從 A 房進板 → 共用快照裝著 A 房的卡，水位被推到最新
  2. 切到 B 房 → 拿到同一份快照 → 水位是 A 房推上去的
  3. 用那個水位要 B 房的增量 → B 房自己的卡一張都不會來
  ⇒ 畫面上留著 A 房的內容，沒有錯誤、沒有空白

`0876746`（房軸回整塊板）根治了它。in-process 測試已經釘住
（test_room_axis_increment_carries_the_other_rooms_changes），這支補的是
**同一件事在真的跑著的 Hub 上也成立**——測試綠證明的是程式碼，不是那台機器。

用法：python three_step_room_switch.py <hub_url> <token>
離開碼：0 通過／1 復現了那個缺陷／2 前提不成立（環境問題，不是結論）
"""

import sys
import uuid

import httpx

# 🚨 **診斷腳本自己不能死在編碼上。** Windows 主控台預設 cp950，一個 `⇒`
# 就會讓整支腳本以 UnicodeEncodeError 收場——而離開碼會變成 1，
# 看起來**像是復現了缺陷**，實際上驗證早就通過了。
# （這個專案 2026-08-29 在 build-app.py 上踩過同一個坑：防某個形狀的工具，
#   第一次執行就示範了那個形狀。）
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

KEY_A = f"probe-a-{uuid.uuid4().hex[:8]}"
KEY_B = f"probe-b-{uuid.uuid4().hex[:8]}"


def main(url: str, token: str) -> int:
    c = httpx.Client(base_url=url, headers={"Authorization": f"Bearer {token}"},
                     timeout=20.0)

    def room(name, key):
        r = c.post("/api/rooms", json={"name": name, "session_key": key})
        r.raise_for_status()
        return r.json()["id"]

    def join(rid, key, name):
        r = c.post(f"/api/rooms/{rid}/join", json={
            "kind": "claude", "role": "agent", "session_key": key,
            "preferred_name": name})
        r.raise_for_status()
        return {"X-Participant-Id": r.json()["participant_id"],
                "X-Session-Key": key}

    tag = uuid.uuid4().hex[:6]
    ra = room(f"切房補驗A-{tag}", KEY_A)
    # 兩間房同一個管理者——掛接要求「同時是兩邊的管理者」，而 App 的實際
    # 情境本來就是同一個人在自己的兩間房之間切
    rb = room(f"切房補驗B-{tag}", KEY_A)
    ha = join(ra, KEY_A, f"ProbeA{tag}")
    hb = join(rb, KEY_B, f"ProbeB{tag}")

    # A 房寫第一張卡 ⇒ 換軸，板在這一刻誕生
    r = c.post(f"/api/rooms/{ra}/board/tasks", json={"title": f"A房的卡-{tag}"},
               headers=ha)
    if r.status_code != 200:
        print(f"[前提不成立] A 房建卡失敗 {r.status_code}: {r.text[:200]}")
        return 2
    bid = c.get(f"/api/rooms/{ra}/board", headers=ha).json()["board_id"]

    # 把 B 房掛到同一塊板上——這是共用快照的前提
    r = c.post(f"/api/boards/{bid}/rooms/{rb}",
               headers={"X-Session-Key": KEY_A})
    if r.status_code != 200:
        print(f"[前提不成立] 掛接 B 房失敗 {r.status_code}: {r.text[:200]}")
        return 2

    # B 房寫自己的卡
    r = c.post(f"/api/rooms/{rb}/board/tasks", json={"title": f"B房的卡-{tag}"},
               headers=hb)
    if r.status_code != 200:
        print(f"[前提不成立] B 房建卡失敗 {r.status_code}: {r.text[:200]}")
        return 2

    # 第 1 步：從 A 房進板（全量），記下水位
    a_full = c.get(f"/api/rooms/{ra}/board?after_board_seq=0", headers=ha).json()
    water = a_full["board_seq"]
    titles_a = sorted(t["title"] for t in a_full["tasks"])
    print(f"① A 房全量：board_seq={water}，卡={titles_a}")

    # 第 2、3 步：切到 B 房，**帶著 A 房推上去的水位**問增量
    b_inc = c.get(f"/api/rooms/{rb}/board?after_board_seq={water}",
                  headers=hb).json()
    print(f"③ B 房增量（水位 {water}）：卡={[t['title'] for t in b_inc['tasks']]}")

    # 判定：全量那次就該同時看得到兩間房的卡（0876746 的語意）
    ok_full = {f"A房的卡-{tag}", f"B房的卡-{tag}"} == set(titles_a)
    if not ok_full:
        print("[復現缺陷] 房軸全量沒有回整塊板——只看得到自己那一段")
        return 1

    # 增量帶著別人的水位問，不該把 B 房的卡吃掉；水位之後沒有新變動時
    # 回空是正確的，關鍵是「client 手上已經有全量」這件事成立
    print("[通過] 房軸全量回的是整塊板，兩間房的卡都在 ⇒ 止血 B 的前提已消失")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
