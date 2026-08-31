"""BridgeState 在多執行緒下的存檔。

bridge 的工具是同步 ``def``，FastMCP 丟 threadpool 執行——兩個工具呼叫是
**真的同時**在跑。單一身分槽的時代碰不到，多 subagent 平行呼叫是常態。

實測到的真實缺陷（2026-08-31）：所有執行緒共用同一個 ``.tmp`` 檔名，
Windows 上一條執行緒 ``os.replace`` 另一條正開著的檔案會拋 ``PermissionError``
（直接對打的壓力測試裡 720 次寫入拋了 717 次）。而 ``save()`` 的
``except OSError: pass`` 把它整個吞掉——**那一次存檔靜默地沒有發生**。

影響範圍要講準：因為所有執行緒共用同一個 dict，下一次成功的存檔會把內容
補回去，所以多數情況看不出差別。真正會掉的是**進程結束前的最後一次**。
"""

import json
import os
import threading

import pytest

from chatroom_mcp import state as state_mod
from chatroom_mcp.state import BridgeState


@pytest.fixture
def replace_failures(monkeypatch):
    """記錄 save() 在 os.replace 上吞掉了幾次錯誤。

    直接斷言「磁碟內容不對」抓不到這個 bug——共用 dict 讓下一次存檔補了回去。
    要驗的是**存檔有沒有真的發生**，那只能從被吞掉的例外看。
    """
    failures = []
    real = os.replace

    def counting_replace(src, dst):
        try:
            real(src, dst)
        except OSError as exc:
            failures.append(type(exc).__name__)
            raise

    monkeypatch.setattr(state_mod.os, "replace", counting_replace)
    return failures


def _hammer(st, n_threads=16, rounds=15):
    barrier = threading.Barrier(n_threads)

    def w(n):
        barrier.wait()
        for k in range(rounds):
            st.set_identity(f"room-{n}-{k}", participant_id=f"p{n}{k}",
                            display_name="x")

    threads = [threading.Thread(target=w, args=(n,)) for n in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def test_concurrent_saves_never_silently_fail(tmp_path, replace_failures):
    """沒有任何一次存檔可以被吞掉。

    共用一個 ``.tmp`` 檔名時這條會紅（PermissionError 一片）；每條執行緒
    各用各的暫存檔才會綠。
    """
    st = BridgeState(tmp_path / "state.json")
    # 先塞一批房間讓 payload 夠大，寫檔窗口才夠長到會互相撞上
    for i in range(800):
        st._rooms[f"pre-{i}"] = {"participant_id": "p" * 60,
                                 "display_name": "n" * 60,
                                 "last_seq": i, "session_key": "k" * 60}
    _hammer(st)

    assert replace_failures == [], (
        f"有 {len(replace_failures)} 次存檔被靜默吞掉——"
        "暫存檔名稱在執行緒之間撞號了"
    )


def test_everything_written_is_on_disk(tmp_path):
    """存完之後磁碟要跟記憶體一致，而且檔案是完整可解析的。"""
    st = BridgeState(tmp_path / "state.json")
    _hammer(st, n_threads=12, rounds=10)

    on_disk = json.loads((tmp_path / "state.json").read_text(encoding="utf-8"))
    assert set(on_disk["rooms"]) == set(st.rooms())


def test_no_stray_tmp_files_left_behind(tmp_path):
    """暫存檔帶執行緒識別，但不能留下來——那會在使用者家目錄長垃圾。"""
    st = BridgeState(tmp_path / "state.json")
    _hammer(st, n_threads=8, rounds=5)

    assert list(tmp_path.glob("*.tmp")) == []
