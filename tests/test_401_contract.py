"""Hub 的 401 code 與 bridge 的翻譯必須對得起來。

`test_403_contract` 的孿生。403 那條擋住了「非身分問題被翻成請重新 join」，
但 401 這邊完全沒有等價的守門——而症狀更貴：

2026-08-31 加了 401 `session_key_header_required`（回應指派要證明你就是被
指派的那個 session），bridge 把它翻成「token 無效或未設定，請確認
CHATROOM_TOKEN」。token 明明是好的，agent 會照著去查設定，然後在那裡繞很久。

401 的 code 只會越來越多，所以這裡不維護第二份清單——直接從 Hub 的原始碼掃
出所有 401 code，拿去打 bridge 的翻譯，看有沒有掉進「token 有問題」那條
fallback。新增 code 忘了處理的話，這個測試會紅。

⚠️ 與 403 那條同理，這是 repo 級的測試：bridge 是獨立安裝的套件，執行時看
不到 server 的原始碼。
"""

import re
from pathlib import Path

from chatroom_mcp.hub import translate_status

_APP = Path(__file__).resolve().parents[1] / "server" / "chatroom_server" / "app.py"

# bridge 認不得 401 code 時的退路。它假設問題出在 token——**那個假設對
# 「你沒帶某個身分標頭」的 code 完全是誤導**，而兩者都是 401。
_TOKEN_FALLBACK_MARK = "CHATROOM_TOKEN"

# 唯一一個 fallback 對它剛好正確的 code：`invalid_token` 真的就是 token 有
# 問題。列在這裡而不是讓它安靜通過——白名單要是**顯式**的，否則下一個人
# 看到測試放行會以為所有 401 都不必處置。
_TOKEN_IS_ACTUALLY_THE_PROBLEM = {"invalid_token"}


def _hub_401_codes() -> set[str]:
    """從 Hub 原始碼掃出所有 `_err(401, "code", ...)` 的 code。"""
    text = _APP.read_text(encoding="utf-8")
    return set(re.findall(r'_err\(\s*401\s*,\s*"([a-z_]+)"', text))


def test_the_scan_actually_finds_something():
    """掃描壞掉時，下面那個測試會空跑而看起來全綠。"""
    codes = _hub_401_codes()
    assert codes, "一個 401 code 都沒掃到——正規式八成跟不上 app.py 的寫法了"
    assert "participant_header_required" in codes


def test_every_hub_401_code_has_a_deliberate_translation():
    """每一個 Hub 會回的 401 code，bridge 都要有想過的處置。

    漏掉的話 agent 會被告知「去檢查 CHATROOM_TOKEN」——而 token 是好的。
    這種指引比沒有指引糟：它給了一個明確但錯誤的方向。
    """
    missing = []
    for code in sorted(_hub_401_codes() - _TOKEN_IS_ACTUALLY_THE_PROBLEM):
        err = translate_status(401, {"code": code, "message": "（Hub 的說明）"}, "u")
        if _TOKEN_FALLBACK_MARK in err.reason:
            missing.append(code)
    assert not missing, (
        f"這些 401 code 在 bridge 沒有對應的處置，會被翻成「token 無效」：{missing}。"
        "請到 bridge/chatroom_mcp/hub.py 的 401 分支各加一條——"
        "缺的是房內身分就設 identity_invalid（agent 該去 join），"
        "缺的是別的標頭就把 Hub 的說明交出去（agent 該補那個標頭）。"
    )


def test_the_whitelist_is_not_stale():
    """白名單裡的 code 必須真的還存在於 Hub。

    Hub 拿掉某個 code 之後白名單留著，就變成一條沒有人記得為什麼在那裡的
    例外——而下一個同名的 code 會直接從它底下溜過去。
    """
    stale = _TOKEN_IS_ACTUALLY_THE_PROBLEM - _hub_401_codes()
    assert not stale, f"白名單裡這些 code 已經不存在於 Hub：{stale}"


def test_missing_participant_still_sets_the_rejoin_flag():
    """反向守衛：真正的「房內身分不見了」不能因為上面的拆分而漏掉 need_rejoin。

    漏掉的話 agent 不會去重新 join，只會反覆撞同一道門。
    """
    err = translate_status(
        401, {"code": "participant_header_required", "message": "x"}, "u")
    assert err.identity_invalid is True


def test_a_missing_session_key_is_not_a_rejoin():
    """反過來也要成立：沒帶 session key **不是**房內身分失效。

    設了 identity_invalid 的話 watcher 會結束進程、agent 會去重新 join——
    而那兩件事都解決不了「這個請求少一個標頭」。
    """
    err = translate_status(
        401, {"code": "session_key_header_required", "message": "x"}, "u")
    assert err.identity_invalid is False
