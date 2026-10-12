"""`build-app.py` 從 Release tag 取熱修序號。

熱修 tag 長 `v1.2.5-hotfix2`，而 App 的版號仍是 `1.2.5`——序號不另外編進
產物的話，App 檢查更新時分不出自己是 `v1.2.5` 還是 `v1.2.5-hotfix2`。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
BUILD_APP = REPO / "scripts" / "build-app.py"


@pytest.fixture(scope="module")
def build_app():
    sys.path.insert(0, str(REPO / "scripts"))
    spec = importlib.util.spec_from_file_location("build_app_script", BUILD_APP)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    ("tag", "expected"),
    [
        ("v1.2.5-hotfix2", 2),
        ("v1.2.5-hotfix10", 10),
        ("1.2.5-hotfix1", 1),
        ("v1.2.5", 0),
        ("", 0),
        # 不是結尾的 `-hotfix<n>` 不算：那不是 release.yml 會產生的 tag
        ("v1.2.5-hotfix2-rc1", 0),
        ("v1.2.5-hotfix", 0),
    ],
)
def test_hotfix_number(build_app, tag, expected):
    assert build_app.hotfix_number(tag) == expected


def test_release_workflow_passes_the_tag_to_the_app_build():
    """workflow 沒把 tag 傳進去的話，熱修版的 App 會自認是 hotfix 0。"""
    text = (REPO / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8")
    step = text.split("- name: Build App", 1)[1].split("- name:", 1)[0]
    assert "CHATROOM_RELEASE_TAG: ${{ env.RELEASE_TAG }}" in step
