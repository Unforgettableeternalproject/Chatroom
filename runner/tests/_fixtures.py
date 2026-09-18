"""執行器測試的共用工具（fixture 以外的部分）。

⚠️ **不要把這些放進 `conftest.py`**：`bridge/tests/conftest.py` 與這裡同名，
兩邊都用 `from conftest import ...` 的話，pytest 會依匯入順序把其中一邊解析
成另一邊——那不是 import 錯誤，是一個「測試跑起來了、但用的是別人的裝置」
的失敗。這個目錄有 `__init__.py`，模組以套件路徑解析；helper 一律從
`._fixtures` 相對匯入。
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from chatroom_runner.config import config_from_dict

ROOT_TOKEN = "root-token"
FAKE_CLAUDE = str(Path(__file__).resolve().parent / "fake_claude.py")

def git(repo: Path, *args: str) -> str:
    """測試用 git。**只在 tmp_path 的拋棄式 repo 上跑。**

    這裡關掉簽章與 hooks 是因為那是一個沒有身分的暫存 repo，不是繞過專案規則
    ——真正的 commit 走 `git` 本人的設定。
    """
    out = subprocess.run(
        ["git", "-c", "user.email=runner@test", "-c", "user.name=runner",
         "-c", "commit.gpgsign=false", *args],
        cwd=str(repo), capture_output=True, text=True, check=False,
        encoding="utf-8", errors="replace")
    if out.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} 失敗：{out.stderr}")
    return out.stdout.strip()


def config_raw(tmp_path, repo: Path, **overrides) -> dict:
    """設定檔的原始 dict。`make_config` 與「寫成真的檔案」共用同一份——

    reload 要重讀的是**磁碟上的那一份**，兩邊各寫一份的話，測到的設定
    與執行器讀到的不是同一個形狀。
    """
    raw = {
        "hub_url": "http://test",
        "agent_token": ROOT_TOKEN,
        "host": "test-host",
        "label": "test",
        "max_parallel": 2,
        "heartbeat_seconds": 0,
        "require_gpg": False,
        "claude_bin": [sys.executable, FAKE_CLAUDE],
        "state_dir": str(tmp_path / "state"),
        "claude_config_dir": str(tmp_path / "claude-config"),
        "backoff_minutes": [1, 2],
        "allowed_domains": ["github.com"],
        "projects": {
            "ai-website": {
                "default_repo": "JSAI-Web",
                "wall_clock_seconds": 60,
                "context_window_tokens": 200000,
                "context_soft_limit_ratio": 0.7,
                "repos": {
                    "JSAI-Web": {
                        "path": str(repo),
                        "allowed_branches": ["jsai_dev", "feature/*"],
                        "push_branches": ["jsai_dev", "feature/*"],
                    },
                },
            },
        },
    }
    raw.update(overrides)
    return raw


def make_config(tmp_path, repo: Path, **overrides):
    """指向假 claude 與測試 repo 的執行器設定。"""
    return config_from_dict(config_raw(tmp_path, repo, **overrides),
                            base_dir=tmp_path)


def write_config(path: Path, tmp_path, repo: Path, **overrides) -> Path:
    """把設定寫成真的檔案（reload 用）。"""
    path.write_text(
        json.dumps(config_raw(tmp_path, repo, **overrides),
                   ensure_ascii=False, indent=2),
        encoding="utf-8")
    return path


async def create_run(client, room_id, headers, **body):
    payload = {"kind": "investigate", "project": "ai-website",
               "ref": "task-1", "brief": "查一下"}
    payload.update(body)
    r = await client.post(f"/api/rooms/{room_id}/runs", json=payload,
                          headers=headers)
    assert r.status_code == 200, r.text
    return r.json()["run"]
