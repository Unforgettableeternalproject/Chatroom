"""執行器測試的共用裝置。

兩個原則：

- **Hub 用真的 P1 端點**（in-process ASGI），不做 mock：要驗的正是「執行器打
  真實契約打不打得通」，mock 只會驗到我對契約的記憶。
- **claude 用假的**（`fake_claude.py`），絕不起真的：真的那個要登入、要花錢，
  而且它的行為不是這一層要驗的東西。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from chatroom_runner.hub import RunnerHub
from chatroom_server.app import create_app
from chatroom_server.config import Config

from ._fixtures import ROOT_TOKEN, git


@pytest.fixture
async def hub_app(tmp_path):
    """啟動 in-process Hub，回 ``(app, client)``。"""
    cfg = Config(db_path=str(tmp_path / "hub.db"), api_token=ROOT_TOKEN)
    app = create_app(cfg)
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test",
                           headers={"Authorization":
                                    f"Bearer {ROOT_TOKEN}"}) as client:
        async with app.router.lifespan_context(app):
            yield app, client


@pytest.fixture
async def ops_room(hub_app):
    """一間 ops 房 + 一個人類成員的標頭。"""
    _app, client = hub_app
    r = await client.post("/api/rooms", json={"name": "工作房", "kind": "ops",
                                              "session_key": "human-a"})
    assert r.status_code == 200, r.text
    room_id = r.json()["id"]
    j = await client.post(f"/api/rooms/{room_id}/join",
                          json={"kind": "human", "role": "human",
                                "session_key": "human-a",
                                "preferred_name": "艾斯維爾"})
    assert j.status_code == 200, j.text
    return room_id, {"X-Participant-Id": j.json()["participant_id"],
                     "X-Session-Key": "human-a"}


@pytest.fixture
def runner_hub(hub_app):
    _app, client = hub_app
    return RunnerHub("http://test", ROOT_TOKEN, client=client)


@pytest.fixture
def work_repo(tmp_path):
    """一個掛著 origin 的工作樹，停在 ``jsai_dev``。"""
    bare = tmp_path / "origin.git"
    bare.mkdir()
    subprocess.run(["git", "init", "--bare", "-b", "jsai_dev", str(bare)],
                   capture_output=True, check=True)
    repo = tmp_path / "JSAI-Web"
    repo.mkdir()
    git(repo, "init", "-b", "jsai_dev")
    git(repo, "remote", "add", "origin", str(bare))
    (repo / "README.md").write_text("測試用\n", encoding="utf-8")
    git(repo, "add", "README.md")
    git(repo, "commit", "-m", "init")
    git(repo, "push", "-u", "origin", "jsai_dev")
    return repo
