"""內建使用手冊。

手冊要對所有 MCP client 有效——Codex 讀不到 Claude Code 的 skill，卻同樣會
把 mention 漏掉。工具是這些 client 唯一共同的載體。
"""

from pathlib import Path

from chatroom_mcp import server as srv
from chatroom_mcp.guide import GUIDE

# repo 根目錄：bridge/tests/test_guide.py → 上溯兩層
_DOC = Path(__file__).resolve().parents[2] / "docs" / "CHATROOM.md"


def test_guide_returns_the_manual():
    result = srv.chatroom_guide()
    assert result["ok"] is True
    assert result["guide"] == GUIDE


def test_guide_covers_the_things_that_fail_silently():
    """手冊的價值在於「猜錯又不會報錯」的那幾件事，缺一件就等於沒寫。"""
    for topic in (
        "chatroom_wait",          # 等待不要用輪詢
        "unresolved_mentions",    # 對著空氣說話
        "回覆本身就等於 mention",  # reply = mention
        "room_is_private",        # 私人房進不去不是壞掉
        "need_rejoin",            # 身分失效的處置
        "pinned_only",            # 釘選是給未來的讀者看的
        "chatroom_ask_human",     # 卡住要問人，不要自己猜
    ):
        assert topic in GUIDE, f"手冊沒有涵蓋：{topic}"


def test_guide_is_not_in_every_tool_listing():
    """手冊本體不該塞進 docstring——那會佔用每一次對話的上下文。"""
    assert len(srv.chatroom_guide.__doc__ or "") < 400
    assert len(GUIDE) > 2000


def test_doc_matches_the_packaged_guide():
    """docs/CHATROOM.md 是 GUIDE 的逐字副本，不能漂移。

    兩份存在的理由不同：bridge 是獨立安裝的套件，執行時讀不到 repo 的
    docs/，所以必須帶著自己的副本；而人要讀、要拿去包成 skill 的是檔案。
    真相在 guide.py——改了那裡就要把 GUIDE 寫回 docs/CHATROOM.md。

    不比對就會出現最糟的那種情況：兩份都看起來像官方說明，內容卻不一樣，
    而沒有任何地方會告訴你該信哪一份。
    """
    assert _DOC.is_file(), f"找不到 {_DOC}"
    assert _DOC.read_text(encoding="utf-8") == GUIDE, (
        "docs/CHATROOM.md 與 guide.py 的 GUIDE 不一致。"
        "改 guide.py 之後要把 GUIDE 原樣寫回 docs/CHATROOM.md。"
    )


def test_doc_is_a_bare_manual():
    """那份檔案要能直接被包成 skill，所以不放任何前言或產生器註解。"""
    assert _DOC.read_text(encoding="utf-8").startswith("# Chatroom 使用手冊")


def test_guide_reports_the_running_build():
    """實跑版本要從回應拿得到，不能只寫在工具說明裡。

    工具說明結尾那份是 client 在交握時抓的、會被快取——升級之後它還是舊的。
    「設定檔換了、跑著的沒換」這個落差**沒有任何一條從回應拿得到的路**時，
    症狀是新參數被靜靜忽略（2026-09-09 實際踩過：舊 bridge 沒有 card_refs）。
    """
    info = srv.chatroom_guide()["bridge"]
    assert set(info) >= {"version", "commit", "built_at", "source"}
    assert info["version"]


def test_join_also_reports_the_running_build(fake_hub):
    """join 也帶版本——查得起，才有人會查。

    guide 的回傳約 8000 字，為了看一個版本號去讀它會吃掉一大塊上下文。
    join 是每個 agent 開工前一定會呼叫的那一支，而它的回應很小。
    （@測試Novia 09/09 房 seq 193 提的取捨）
    """
    room = "room-guide"
    fake_hub.json(
        "POST", f"/api/rooms/{room}/join",
        {"participant_id": "pid-1", "display_name": "Aster", "rejoined": False},
    )
    info = srv.chatroom_join(room)["bridge"]
    assert set(info) >= {"version", "commit", "built_at", "source"}


def test_guide_tells_you_how_to_wake_up():
    """手冊要教「怎麼掛 watcher」——沒掛的話 @ 你你不會醒，而且不會報錯。

    這是 2026-09-15 補的洞：掛法只寫在 install-kit/README.md，那是給**人**
    讀的檔案。agent 讀 guide 找不到，只能從工具名稱猜，然後猜到
    `chatroom_watch`（那支是追蹤任務板卡片的，必填 task_id）。
    """
    assert "## 0." in GUIDE, "掛 watcher 要排在標準流程之前"
    for topic in ("watcher", "--room", "chatroom_watch", "--all-messages"):
        assert topic in GUIDE, f"手冊沒有涵蓋：{topic}"
    # §0 要排在 §1 前面：agent 照順序讀，排在後面等於沒寫
    assert GUIDE.index("## 0.") < GUIDE.index("## 1.")


def test_guide_never_hardcodes_a_machine_path():
    """手冊是同一份常數發給所有人，寫死路徑就是發作者那台的路徑。

    `~/.claude/skills/chatroom/SKILL.md` 正是這樣壞的——裡面的 Monitor 指令
    指向作者的開發樹，複製到任何別台機器都是死的。
    """
    for bad in (r"C:\Users", "C:/Users/", "/home/", "site-packages"):
        assert bad not in GUIDE, f"手冊裡出現了本機路徑：{bad}"


def test_watcher_setup_points_at_files_that_exist():
    """`watcher` 欄位要是**能貼上就跑**的東西，不是範例。

    只斷言欄位存在的話，回傳一個編出來的路徑照樣會綠——而那正是這個欄位
    要取代的失敗模式。所以驗檔案真的在磁碟上。
    """
    info = srv.chatroom_guide()["watcher"]
    assert set(info) >= {"python", "script", "session_watcher", "room_watcher"}
    assert Path(info["python"]).is_file(), info["python"]
    assert Path(info["script"]).is_file(), info["script"]
    assert Path(info["script"]).name == "watch.py"
    # 房內 watcher 與 session watcher 的差別就在這個旗標，混用會漏一半
    assert "--room" in info["room_watcher"]
    assert "--room" not in info["session_watcher"]


def test_watcher_setup_fills_room_id_when_given():
    from chatroom_mcp.guide import watcher_setup
    assert "--room r-42" in watcher_setup("r-42")["room_watcher"]
    assert "<room_id>" in watcher_setup()["room_watcher"]


def test_card_watch_tool_disowns_the_name_collision():
    """`chatroom_watch` 的說明要自己撇清——名字最像的那個是錯的。

    截圖實錄（2026-09-15）：agent 要掛背景通知，工具列表裡掃到 chatroom_watch，
    然後回報「這不是等人邀請的 watcher」——它已經走到那支工具面前才發現。
    說明要在它被選中的那一刻就把人送去對的地方。
    """
    doc = srv.chatroom_watch.__doc__ or ""
    assert "不是" in doc and "watcher" in doc
    assert "chatroom_guide" in doc, "要指出正確的去處，光說『不是』沒有用"
