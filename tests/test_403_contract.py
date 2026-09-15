"""Hub 的 403 code 與 bridge 的翻譯必須對得起來。

2026-08-30：Hub 對私人房回 `room_is_private`，bridge 卻翻成「你的房間身分已
失效，請重新呼叫 chatroom_join」——那個 agent 從沒加入過該房，而被建議去做
的正是它剛剛被拒絕的那個呼叫。

修法是在 bridge 逐一列出已知的非身分 code。但那讓「Hub 新增 403 code 時要
回來加一條」變成純靠記憶的約定，而漏加的症狀是**沉默的誤導**：agent 拿到
一句錯的指引，照做，撞牆，沒有任何地方會報錯。

所以這裡不維護第二份清單——直接從 Hub 的原始碼掃出所有 403 code，拿去打
bridge 的翻譯，看有沒有掉進 fallback。新增 code 忘了處理的話，這個測試會紅。

⚠️ 這是 repo 級的測試（tests/），不是 bridge 的（bridge/tests/）：bridge 是
獨立安裝的套件，執行時看不到 server 的原始碼，這條對表只有在 repo 裡做得到。
"""

import re
from pathlib import Path

from chatroom_mcp.hub import translate_status

_APP = Path(__file__).resolve().parents[1] / "server" / "chatroom_server" / "app.py"

# bridge 認不得 code 時的開場白。看到它＝沒有人為這個 code 寫過處置。
#
# 比對前綴而不是整句：fallback 會把 Hub 的原話串在後面，所以全文每次都不同。
# 也不能拿某個已知 code 的訊息當基準——那正是這個測試第一版踩到的坑：
# `participant_not_active` 的正確訊息剛好與當時的 fallback 一字不差，於是
# 一個處置正確的 code 被判成漏網。fallback 的措辭因此刻意寫得與任何一條
# 具體處置都不一樣。
_FALLBACK_PREFIX = "Hub 拒絕了這個動作（403）"


def _hub_403_codes() -> set[str]:
    """從 Hub 原始碼掃出所有 `_err(403, "code", ...)` 的 code。"""
    text = _APP.read_text(encoding="utf-8")
    # _err(403, "code" —— 允許中間有換行與縮排
    return set(re.findall(r'_err\(\s*403\s*,\s*"([a-z_]+)"', text))


def test_the_scan_actually_finds_something():
    """掃描本身壞掉時，下面那個測試會空跑而看起來全綠。"""
    codes = _hub_403_codes()
    assert len(codes) >= 4, f"只掃到 {codes}——正規式八成跟不上 app.py 的寫法了"
    assert "room_is_private" in codes


def test_every_hub_403_code_has_a_deliberate_translation():
    """每一個 Hub 會回的 403 code，bridge 都要有想過的處置。

    漏掉的話 agent 會拿到「請重新 join」——對私人房、非管理員、被踢這些情況
    來說那是死路，而且錯得很安靜。
    """
    missing = []
    for code in sorted(_hub_403_codes()):
        err = translate_status(403, {"code": code, "message": "（Hub 的說明）"}, "u")
        if err.reason.startswith(_FALLBACK_PREFIX):
            missing.append(code)
    assert not missing, (
        f"這些 403 code 在 bridge 沒有對應的處置，會被翻成「身分已失效」：{missing}。"
        "請到 bridge/chatroom_mcp/hub.py 的 403 分支各加一條——"
        "它是身分問題就設 identity_invalid，不是的話就把 Hub 的說明交出去。"
    )


def test_identity_codes_still_set_the_rejoin_flag():
    """反向守衛：真正的身分問題不能因為上面的拆分而漏掉 need_rejoin。

    漏掉的話 watcher 不會結束進程，變成掛在一個它已經沒有身分的房上。
    """
    for code in ("participant_kicked", "participant_removed_idle",
                 "participant_left", "participant_wrong_room"):
        err = translate_status(403, {"code": code, "message": "x"}, "u")
        assert err.identity_invalid is True, f"{code} 應該仍算身分失效"
