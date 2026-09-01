"""subagent 回收時限的預設值與文件一致性守衛。

120 秒是為「crash 殘骸」訂的，但實測一次真正的規劃／審查工作可以靜默
超過十分鐘（2026-09-01：規劃 subagent 靜默 632 秒後身分已被回收，
要發報告時才發現沒有身分）。時限拉長不會讓殘骸失控——父層離場會級聯
帶走旗下所有 subagent，殘骸的最長存活本來就受父層限制。

第二條測試是**靜態守衛**：這個數字被五個檔案用散文重述過，改了預設值
卻漏改敘述的話，使用者讀到的是舊契約而測試全綠。
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from chatroom_server.config import Config

ROOT = Path(__file__).resolve().parents[1]

# 會用散文描述 subagent 時限的檔案
PROSE_FILES = [
    "bridge/chatroom_mcp/server.py",
    "docs/SUBAGENT-IDENTITY.md",
    "app/lib/screens/chat/chat_screen.dart",
]

# 「120」曾被寫死在敘述裡的形狀
STALE_PATTERNS = [
    re.compile(r"預設\s*120\s*秒"),
    re.compile(r"TTL\s*是\s*120\s*秒"),
    re.compile(r"SUBAGENT_TIMEOUT\s*=\s*120\b"),
]


def test_subagent_timeout_default_is_long_enough_for_real_work():
    """預設值要撐得住一次真正的背景工作，不是只撐得住一次 tool call。"""
    assert Config().subagent_timeout == 900


def test_subagent_timeout_stays_below_parent_cascade_relevance():
    """仍要明顯短於「整場對話」的量級，殘骸不能無限期掛在成員列上。"""
    cfg = Config()
    assert cfg.subagent_timeout < 3600


@pytest.mark.parametrize("relpath", PROSE_FILES)
def test_no_stale_120_second_prose(relpath: str):
    """散文裡不得殘留舊的 120 秒契約。"""
    text = (ROOT / relpath).read_text(encoding="utf-8")
    hits = [p.pattern for p in STALE_PATTERNS if p.search(text)]
    assert not hits, f"{relpath} 仍寫著舊的 subagent 時限：{hits}"
