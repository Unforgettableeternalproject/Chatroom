"""不變量：推進 update_seq 的路徑不得改動 mentions。

`_out()` 判定喚醒時只認新訊息（`m["seq"] > after_seq`），因為既有訊息會為了
釘選／刪除領一個新的 update_seq 重新落進批次裡——不設這條界線，任何人釘一則
@ 過你的舊訊息你就會再醒一次。那條界線由
`test_update_propagation.py::test_pinning_an_old_message_does_not_rementions_its_targets`
守著，運作良好。

但它有一個**隱含前提**：update 路徑不會新增 mention。目前成立（pin / unpin /
delete 都不動 mentions），而 app.py 裡只有一句註解記著這件事。哪天有人加了
會改 mentions 又推 update_seq 的端點——編輯訊息是最可能的那個——那條界線就會
把正當的喚醒吃掉，而症狀是「我明明 @ 了他，他沒醒」，全程零錯誤。

註解攔不住這件事，所以這裡把前提寫成會講話的守衛。編輯訊息已裁定
**只改內文、不動 mentions**（2026-08-31），這條測試就是那個裁決的執行者。
"""

import ast
from pathlib import Path

import chatroom_server.app as app_module

# 只讀取 mentions（不寫入）的函式可以放行——但要在這裡具名列出並說明理由，
# 讓下一個人看得到豁免的代價。清單保持極短
_READ_ONLY_EXEMPT: set[str] = set()


def _nodes_owned_by(fn: ast.AST):
    """該函式自己的節點，不遞迴進巢狀函式。

    app.py 幾乎整份都包在 `create_app` 裡，用 `ast.walk` 會讓每個端點都「屬於」
    它，判定就失去意義。
    """

    def walk(node):
        yield node
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return
        for child in ast.iter_child_nodes(node):
            yield from walk(child)

    for child in ast.iter_child_nodes(fn):
        yield from walk(child)


def _functions_touching_update_seq(tree: ast.AST) -> list[ast.AST]:
    out = []
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if fn.name == "_touch_message":  # 定義本身不算呼叫者
            continue
        for node in _nodes_owned_by(fn):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "_touch_message"
            ):
                out.append(fn)
                break
    return out


def _mentions_literals(fn: ast.AST) -> list[str]:
    """該函式自己提到 mentions 的字面字串（SQL 欄位、dict key 都算）。"""
    found = []
    for node in _nodes_owned_by(fn):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if "mentions" in node.value:
                found.append(node.value.strip()[:60])
    return found


def _source_tree() -> ast.AST:
    return ast.parse(Path(app_module.__file__).read_text(encoding="utf-8"))


def test_the_detector_actually_detects():
    """先證明偵測器有鑑別力——否則下面那條綠燈不代表任何事。

    真正的違規者現在不存在（正是我們要維持的狀態），所以拿一段假的來打。
    """
    offender = ast.parse(
        "async def edit_message(mid, room_id):\n"
        "    await db.execute('UPDATE message SET content=?, mentions=? WHERE id=?')\n"
        "    await _touch_message(mid, room_id)\n"
    )
    fns = _functions_touching_update_seq(offender)
    assert [f.name for f in fns] == ["edit_message"]
    assert _mentions_literals(fns[0]), "偵測器認不出寫入 mentions 的 SQL"

    clean = ast.parse(
        "async def pin_message(mid, room_id):\n"
        "    await db.execute('UPDATE message SET pinned=1 WHERE id=?')\n"
        "    await _touch_message(mid, room_id)\n"
    )
    assert not _mentions_literals(_functions_touching_update_seq(clean)[0])


def test_update_seq_paths_do_not_touch_mentions():
    """現況：所有推進 update_seq 的端點都不碰 mentions。"""
    tree = _source_tree()
    fns = _functions_touching_update_seq(tree)

    # 正向錨點：真的掃到了東西。掃不到任何呼叫者時這條會無聲通過，
    # 而那與「全都乾淨」在綠燈上完全同形
    assert fns, "沒有找到任何 _touch_message 的呼叫者——偵測方式可能已經失效"

    offenders = {
        fn.name: literals
        for fn in fns
        if fn.name not in _READ_ONLY_EXEMPT
        and (literals := _mentions_literals(fn))
    }
    assert not offenders, (
        "這些端點推進了 update_seq 又提到 mentions。若它真的會改動 mentions，"
        "app.py `_out()` 裡「只有新訊息能喚醒」那條界線就會把正當的喚醒吃掉"
        "（症狀：我 @ 了他，他沒醒，而且沒有任何錯誤）——那條界線必須一起改成"
        "比對「mentions 裡新增了我」。若只是讀取，把函式名加進 _READ_ONLY_EXEMPT "
        f"並寫明理由。\n{offenders}"
    )
