"""`install-kit` 的註冊檔：targets 必須合併，不能覆寫。

🔴 2026-09-09（測試Novia，09/09 房 seq 186 實測）：這台 kit 的**既定流程**
就是分兩次跑安裝器——`--name` 一次只吃一個值，而 Claude 與 Codex 的房內代稱
往往不同。覆寫的話第二次會把第一次洗掉，於是 App 顯示「只裝了 codex」而實際
兩端都在。

那不是顯示錯誤而已：使用者看到之後合理的反應是**再跑一次安裝器**，然後把
另一端的代稱洗掉——**一個顯示錯誤誘導出一個真實的破壞**。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent


def _load_installer(kit_dir: Path, registry: Path):
    """把 install-kit/install.py 載進來，並把它的路徑常數指到暫存目錄。

    直接 import 會動到真的 `~/.chatroom/`——測試不該碰使用者的家目錄。
    """
    spec = importlib.util.spec_from_file_location(
        "_mcp_installer", REPO / "install-kit" / "install.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules["_mcp_installer"] = module
    spec.loader.exec_module(module)
    module.KIT_DIR = kit_dir
    module.REGISTRY = registry
    return module


@pytest.fixture()
def installer(tmp_path):
    kit = tmp_path / "kit"
    kit.mkdir()
    registry = tmp_path / "home" / ".chatroom" / "mcp-kit.json"
    return _load_installer(kit, registry), registry


def _read(registry: Path) -> dict:
    return json.loads(registry.read_text(encoding="utf-8"))


def test_第一次安裝就寫得出註冊檔(installer):
    module, registry = installer
    module.write_registry(["claude"])
    data = _read(registry)
    assert data["targets"] == ["claude"]
    assert data["target_installed_at"]["claude"]


def test_分兩次安裝要合併而不是覆寫(installer):
    module, registry = installer
    module.write_registry(["claude"])
    module.write_registry(["codex"])
    data = _read(registry)
    assert data["targets"] == ["claude", "codex"], (
        "覆寫的話 App 會說只裝了 codex，而使用者會再跑一次安裝器把 claude "
        "那端的代稱洗掉"
    )


def test_沒重裝的那一端保留原本的安裝時間(installer):
    module, registry = installer
    module.write_registry(["claude"])
    first = _read(registry)["target_installed_at"]["claude"]

    module.write_registry(["codex"])
    data = _read(registry)
    assert data["target_installed_at"]["claude"] == first, (
        "這次沒裝 claude，不能假裝它剛剛被更新過——「哪一端比較舊」正是這個"
        "欄位存在的理由"
    )
    assert data["target_installed_at"]["codex"] != ""


def test_同一端重裝會更新它自己的時間(installer):
    module, registry = installer
    module.write_registry(["claude"])
    before = _read(registry)
    # 時間戳的精度是秒，直接改舊值比 sleep 可靠也快
    stale = dict(before)
    stale["target_installed_at"] = {"claude": "2020-01-01T00:00:00+00:00"}
    registry.write_text(json.dumps(stale), encoding="utf-8")

    module.write_registry(["claude"])
    assert _read(registry)["target_installed_at"]["claude"] != (
        "2020-01-01T00:00:00+00:00")


def test_舊格式留下的_target_沒有時間就讓它沒有(installer):
    """🔴 不要替它編一個時間（測試Novia 09/09 房 seq 204 實測的起點狀態）。

    舊版安裝器沒有 `target_installed_at`，所以那筆 target 的時間**從來沒被
    記過**。填今天的等於宣稱它剛剛被更新，填 `installed_at` 等於宣稱那是它的
    安裝時刻——兩個都是編出來的，而且會讓人拿它去判斷「哪一端比較舊」時
    得到相反的結論。顯示「不明」才是誠實的。
    """
    module, registry = installer
    registry.parent.mkdir(parents=True, exist_ok=True)
    registry.write_text(json.dumps({
        "version": 1,
        "kit_root": str(module.KIT_DIR),
        "installed_at": "2026-09-01T00:00:00+00:00",
        "targets": ["codex"],
        # 舊格式：沒有 target_installed_at
    }), encoding="utf-8")

    module.write_registry(["claude"])
    data = _read(registry)
    assert data["targets"] == ["claude", "codex"]
    assert "codex" not in data["target_installed_at"], (
        "codex 的安裝時間從來沒被記過——補一個假的比留白更糟"
    )
    assert data["target_installed_at"]["claude"]


def test_解到別的位置重裝就整份取代(installer, tmp_path):
    module, registry = installer
    module.write_registry(["claude", "codex"])

    # 使用者把 kit 解到別的地方重裝：舊的 targets 可能指向已經不存在的設定
    other = tmp_path / "kit2"
    other.mkdir()
    module.KIT_DIR = other
    module.write_registry(["claude"])

    data = _read(registry)
    assert data["kit_root"] == str(other)
    assert data["targets"] == ["claude"], "換了位置就不是同一包，不該合併舊的"


def test_舊檔壞掉不擋住寫入(installer):
    module, registry = installer
    registry.parent.mkdir(parents=True, exist_ok=True)
    registry.write_text("{ 半個檔案", encoding="utf-8")

    module.write_registry(["claude"])
    assert _read(registry)["targets"] == ["claude"]


def test_寫不進去不會炸掉安裝(installer, tmp_path):
    module, _ = installer
    # 指到一個不可能建立的位置：write_registry 只該印警告，不該讓安裝中止
    module.REGISTRY = tmp_path / "kit" / "install.py" / "nope" / "x.json"
    (tmp_path / "kit" / "install.py").write_text("not a dir", encoding="utf-8")
    module.write_registry(["claude"])  # 不應拋例外
