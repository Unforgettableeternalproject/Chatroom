"""驗證開跑前的定錨閘——**先證明你打的是哪一台，再開始驗**。

2026-09-05 同一個形狀撞了三次（8787 版本／綠燈涵蓋範圍／8788 port 被佔），
共通點都是「看起來成功」與「真的是它」之間那道縫：

- `curl /api/health` 有回應，只證明**那個 port 上有東西在回話**，
  不證明「我起的那台起來了」——回話的可能是昨天就在跑的舊進程。
- 在跑著舊碼的 Hub 上驗新行為，每一項都會**安靜地驗不到**，
  而且長得像「功能沒做」，不像「你打錯機器」。

所以：任何驗證跑之前，先跑這支。**不符就不要開始**，
不然你花的時間會產出一份看起來完整、結論全錯的報告。

⚠️ **這支只定錨得了版本，定錨不了身分。** 它問的是 health，而 health 分不出
「回話的是誰起的進程」——同一份碼但不是你這次拉起來的那台，它照樣放行。
本機還要看**自己那支啟動腳本的離開碼**（port 被佔時 uvicorn 會 exit 3，
而那時 health 仍然有回應）。**遠端定錨版本、本機定錨身分，兩者不能互相取代。**

原始版本由測試端（Clockwork-Community）寫於 2026-09-05，收進 repo 時補了
輸出編碼那一段。

用法：python anchor.py <hub_url> <token> <expected_commit>
離開碼：0 = 定錨相符，可以開跑；1 = 不符，停手；2 = 問不到，同樣停手
"""

from __future__ import annotations

import sys

import httpx

# 🚨 **閘門自己不能死在編碼上。** Windows 主控台預設 cp950，而底下的
# ✅／🚨／❌ 一個都印不出來——實測（開發機，2026-09-05）：定錨**相符**時
# 唯一表達成功的那一行拋 UnicodeEncodeError，Python 以 exit 1 收場，
# 於是「可以開跑」被回報成「打錯機器，停手」。**閘門的假陰性。**
#
# 寫這支的那台印得出來，這台印不出來——跨裝置差異，而它只在成功路徑上發作。
# 專案 2026-08-29 已在 build-app.py 上踩過同型的坑。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

if len(sys.argv) != 4:
    print(__doc__)
    sys.exit(2)

URL = sys.argv[1].rstrip("/")
TOKEN = sys.argv[2]
EXPECTED = sys.argv[3].strip()

try:
    r = httpx.get(f"{URL}/api/health",
                  headers={"Authorization": f"Bearer {TOKEN}"}, timeout=15.0)
    r.raise_for_status()
    j = r.json()
except Exception as e:  # noqa: BLE001
    print(f"❌ 問不到 {URL} 的 health：{e!r}")
    print("   結論未知——**不要當成可以開跑**。")
    sys.exit(2)

build = j.get("build") or {}
commit = str(build.get("commit") or j.get("commit") or "")
print(f"目標    : {URL}")
print(f"版本    : {j.get('version')}")
print(f"commit  : {commit or '<缺>'}")
print(f"source  : {build.get('source') or '<缺>'}")
print(f"built_at: {build.get('built_at') or '<空，走 git checkout 那條路徑就是空的>'}")
print(f"期望    : {EXPECTED}")

if not commit:
    print("\n🚨 health 沒吐 commit，定錨不了。停手。")
    sys.exit(2)

# 允許長短不一（12 碼 vs 40 碼），以較短的那個當前綴比對
a, b = commit.lower(), EXPECTED.lower()
if not (a.startswith(b) or b.startswith(a)):
    print("\n🚨 **打錯機器了**——這台跑的不是你要驗的那份碼。")
    print("   在這上面驗新行為，每一項都會安靜地驗不到，")
    print("   而結果會長得像「功能沒做」，不像「你打錯機器」。停手。")
    sys.exit(1)

if a.endswith("-dirty"):
    # 停手而不是警告：dirty 的產物對不回任何 commit，在它上面測出來的東西
    # 工作區一被蓋過就**世界上不存在第二份**，重現不了
    print("\n🚨 這台是 **-dirty** build，對不回任何 commit。")
    print("   驗收要凍結的版本不能是它。停手。")
    sys.exit(1)

print("\n✅ 定錨相符，可以開跑。")
sys.exit(0)
