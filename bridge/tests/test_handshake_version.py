"""MCP 交握要說得出自己是哪一版（7ac520e5）。

`initialize` 是 client 在呼叫任何工具之前**唯一**能問出對方版本的地方。
在此之前 `MCPServer("chatroom")` 沒帶 version，交握回的 `serverInfo.version`
一直是空字串——資訊明明有（`version.py` 備妥、stderr banner 印的就是它），
只是沒接進去。

⚠️ 版號本身鑑別力不足：server／bridge／app 三包同版號，09/05 為了「不知道
自己在跑哪一版」繞過一大圈。所以交握要帶 commit，形狀是 `1.1.5+d6ed0025`——
而不是 `version_string()` 那種帶空格與來源標註的人類可讀格式（那不是合法的
版本字串，client 拿去比對會踩到）。
"""

from chatroom_mcp import version as ver


def test_the_handshake_version_is_not_empty():
    """最低要求：說得出一個版本。"""
    assert ver.handshake_version()


def test_it_carries_the_commit_when_there_is_one():
    """有 commit 就帶上——三包同版號時，只有 commit 有鑑別力。"""
    info = ver.build_info()
    s = ver.handshake_version()
    assert s.startswith(info["version"])
    if info["commit"]:
        assert s == f"{info['version']}+{info['commit']}"
    else:
        assert s == info["version"]


def test_it_is_a_machine_readable_string_not_the_banner():
    """交握帶的是版本，不是給人看的 banner。

    `version_string()` 長成 `1.1.5+abc (git)`——空格與括號在版本欄位裡是
    雜訊，client 拿去做比對會踩到。兩個函式刻意分開。
    """
    s = ver.handshake_version()
    assert " " not in s and "(" not in s


def test_the_server_actually_passes_it_into_the_handshake():
    """接上去了才算數——函式存在但沒接進 MCPServer 等於沒做。

    這裡直接問 server 實例，而不是讀原始碼字串：驗的是交握真的會回這個值。
    """
    from chatroom_mcp import server as srv

    assert srv.mcp.version == ver.handshake_version()
    assert srv.mcp.version
