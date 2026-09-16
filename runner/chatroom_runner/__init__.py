"""Chatroom 遠端派工執行器（REMOTE-OPS-PLAN P2）。

與 ``bridge`` 分開的子系統：bridge 是 agent 在房裡的手，runner 是「起 agent」
的手。職責混在一起的話，一個 run 的失敗會長得像房間通訊的失敗。
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
