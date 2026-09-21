"""執行器測試套件。

有 `__init__.py` 是刻意的：`bridge/tests` 也有一個 `conftest.py`，
沒有套件邊界時兩個同名模組會在 pytest 的 prepend 匯入模式下撞在一起。
"""
