"""session key 的解析優先序（G1：Codex 側的身分分裂）。

審核用Codex 在自己身上實證的病理：Codex 原生的身分是 ``CODEX_THREAD_ID``
（與 writer lock 同值），但 bridge 每個進程自己生一把 ``codex-{uuid12}``。
於是 App 掃得到 writer lock 的那個 UUID，房內的 participant 卻掛在 uuid
fallback 上，兩者沒有任何 join/route 關係——**指派送到一把 key 上、監看掛在
另一把上，永遠不會醒，而且不會有任何錯誤訊息**。

修法是讓 resolver 對齊原生身分。這裡釘住優先序，以及**跨 kind 不採用**那條
——它鏡像 claude 分支的舊教訓：從 Claude session 的 shell 拉起的 Codex 會
繼承母環境變數，不設防就會與母 session 撞 key。
"""

import pytest

from chatroom_mcp import identity

_ALL = (
    "CHATROOM_SESSION_KEY",
    "CLAUDE_CODE_SESSION_ID",
    "CODEX_THREAD_ID",
    "CODEX_SESSION_ID",
)


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """每條測試從空白環境開始——否則跑測試那台機器自己的 session id 會
    洩進來，結果隨開發者的環境而變。"""
    for name in _ALL:
        monkeypatch.delenv(name, raising=False)


class TestCodex:
    def test_thread_id_wins_over_uuid(self, monkeypatch):
        """有 CODEX_THREAD_ID 就用它——那是 Codex 的原生身分，也是 App 掃
        writer lock 時看到的那一把。"""
        monkeypatch.setenv("CODEX_THREAD_ID", "01a05774-2650-7e53")
        assert identity.session_key("codex") == "codex-01a05774-2650-7e53"

    def test_session_id_is_the_fallback(self, monkeypatch):
        """沒有 thread id 時退到 CODEX_SESSION_ID。"""
        monkeypatch.setenv("CODEX_SESSION_ID", "fallback-id")
        assert identity.session_key("codex") == "codex-fallback-id"

    def test_thread_id_beats_session_id(self, monkeypatch):
        """兩個都有時以 thread id 為準——writer lock 用的是它。"""
        monkeypatch.setenv("CODEX_THREAD_ID", "thread")
        monkeypatch.setenv("CODEX_SESSION_ID", "session")
        assert identity.session_key("codex") == "codex-thread"

    def test_explicit_key_still_wins(self, monkeypatch):
        """顯式設定優先於一切——那是「固定人格」的特殊部署用法。"""
        monkeypatch.setenv("CHATROOM_SESSION_KEY", "codex-main")
        monkeypatch.setenv("CODEX_THREAD_ID", "01a05774")
        assert identity.session_key("codex") == "codex-main"

    def test_uuid_remains_the_last_resort(self, monkeypatch):
        """什麼都沒有時仍要生一把——**最後防線不能拿掉**。

        沒有它的話，跑在不提供這些變數的環境裡的 Codex 會完全沒有身分，
        那比每次換一把更糟。
        """
        key = identity.session_key("codex")
        assert key.startswith("codex-")
        assert len(key) > len("codex-")


class TestCrossKindIsolation:
    """**跨 kind 不採用**：這是 claude 分支學過一次的教訓，鏡像過來。

    從 Claude session 的 shell 拉起的 Codex 會繼承母 session 的
    ``CLAUDE_CODE_SESSION_ID``；反過來，Codex 環境裡拉起的 Claude 也可能
    看得到 ``CODEX_*``。任一方向不設防，兩個進程就會撞到同一把 key，
    而 join 冪等會把它們合併成同一個 participant——訊息混流，兩邊都不報錯。
    """

    def test_claude_does_not_take_codex_thread_id(self, monkeypatch):
        monkeypatch.setenv("CODEX_THREAD_ID", "01a05774")
        key = identity.session_key("claude")
        assert "01a05774" not in key

    def test_codex_does_not_take_claude_session_id(self, monkeypatch):
        monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "10a87308")
        key = identity.session_key("codex")
        assert "10a87308" not in key

    def test_other_kinds_take_neither(self, monkeypatch):
        monkeypatch.setenv("CODEX_THREAD_ID", "01a05774")
        monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "10a87308")
        key = identity.session_key("other")
        assert "01a05774" not in key and "10a87308" not in key


class TestStability:
    """**同一個環境重算要得到同一把 key**——那是整個修法的重點。

    bridge 進程會重啟（MCP 重連、Codex 重開），而每次重啟換一把 key 正是
    G1 的病。這條測試把「穩定」變成可驗證的性質，而不是靠實作看起來對。
    """

    def test_codex_key_survives_a_restart(self, monkeypatch):
        monkeypatch.setenv("CODEX_THREAD_ID", "01a05774-2650")
        first = identity.session_key("codex")
        second = identity.session_key("codex")   # 等同進程重啟後重算
        assert first == second

    def test_uuid_fallback_is_the_unstable_one(self, monkeypatch):
        """對照組：沒有原生身分時**本來就會**每次不同。

        這條不是要修的行為，是要**證明上面那條測到了東西**——若 fallback
        也碰巧穩定，穩定性測試就會在實作壞掉時仍然綠。
        """
        assert identity.session_key("codex") != identity.session_key("codex")
