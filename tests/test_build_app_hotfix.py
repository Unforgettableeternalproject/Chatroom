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


@pytest.mark.parametrize(
    ("tag", "expected"),
    [
        ("v1.2.9-rc1", 1),
        ("v1.2.9-rc12", 12),
        ("1.2.9-rc3", 3),
        ("v1.2.9", 0),
        ("v1.2.9-hotfix1", 0),
        ("", 0),
        # 不是結尾的 `-rc<n>` 不算
        ("v1.2.9-rc1-hotfix1", 0),
        ("v1.2.9-rc", 0),
    ],
)
def test_rc_number(build_app, tag, expected):
    assert build_app.rc_number(tag) == expected


def test_rc_and_hotfix_numbers_do_not_overlap(build_app):
    """RC tag 不會被當成熱修，熱修 tag 也不會被當成 RC。"""
    assert build_app.hotfix_number("v1.2.9-rc1") == 0
    assert build_app.rc_number("v1.2.9-hotfix1") == 0


def test_release_workflow_passes_the_tag_to_the_app_build():
    """workflow 沒把 tag 傳進去的話，熱修版的 App 會自認是 hotfix 0。"""
    text = (REPO / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8")
    step = text.split("- name: Build App", 1)[1].split("- name:", 1)[0]
    assert "CHATROOM_RELEASE_TAG: ${{ env.RELEASE_TAG }}" in step


def _release_workflow() -> dict:
    import yaml

    text = (REPO / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8")
    return yaml.safe_load(text)


def test_release_workflow_triggers_rc_from_develop():
    """develop 的 CI 完成與 RC tag 推送都能觸發；YAML 能解析。"""
    wf = _release_workflow()
    on = wf[True]  # YAML 把 `on` 讀成布林 True
    assert on["workflow_run"]["branches"] == ["master", "develop"]
    assert on["push"]["tags"] == ["v*-rc*"]
    assert "workflow_dispatch" in on


def test_release_workflow_keeps_rc_and_formal_apart():
    """develop 只發 -rc tag，master 絕不發 -rc tag。"""
    wf = _release_workflow()
    run = wf["jobs"]["resolve"]["steps"][1]["run"]
    assert 'RUN_BRANCH" = "develop"' in run
    assert 'grep -E "$RC_RE"' in run
    assert 'grep -Ev "$RC_RE"' in run


def test_release_workflow_strips_rc_suffix_in_version_check():
    text = (REPO / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8")
    assert 'WANT="${WANT%%-rc*}"' in text


def test_release_workflow_marks_rc_as_prerelease_everywhere():
    """三個上傳 job 都要帶 prerelease／make_latest，少一個就會被蓋回 latest。"""
    wf = _release_workflow()
    for job in ("release", "app-macos", "app-linux"):
        steps = [s for s in wf["jobs"][job]["steps"]
                 if str(s.get("uses", "")).startswith("softprops/action-gh-release")]
        assert len(steps) == 1, job
        w = steps[0]["with"]
        assert "outputs.prerelease" in str(w["prerelease"]), job
        assert "'false'" in str(w["make_latest"]), job
