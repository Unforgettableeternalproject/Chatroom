"""交付出去的 kit 不可以帶著開發者這台機器的私人細節。

2026-09-12 艾斯維爾發現：`install-kit/install.py` 的「Hub 位址」預設值是
**他自己的 VPN 位址**。外部人跑安裝器按 Enter 就填了那個值——

- 他沒有那個網路 → 連不上，而前面每一步都顯示成功
- 🚨 **他剛好也在那個網路裡** → **安安靜靜地連到別人的 Hub**

第二種比第一種糟得多，而且沒有任何地方會報錯。

同一批也清掉了所有指名特定 VPN 產品的敘述：文件寫「要連上 Radmin VPN」時，
用 Tailscale 的人會以為自己不符合需求。**前置需求要寫成一個判準
（連不連得到那台機器），不是一個產品名。**
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]

# 會被打包進交付物的地方。**測試自己不在這個範圍裡**——否則底下那些
# 樣式會在這個檔案裡自我觸發
PACKAGED = [REPO / "install-kit", REPO / "host-kit", REPO / "scripts",
            REPO / "bridge" / "chatroom_mcp"]

SUFFIXES = {".py", ".md", ".cmd", ".ps1", ".vbs", ".json", ".toml"}

# 開發機那個 VPN 網段。組出來而不是寫死整串，這樣這個檔案自己不含它
_DEV_NET = "26." + "176."

# 指名特定 VPN 產品的敘述。用它們的人以外的人會以為自己不符合需求
VPN_BRANDS = ["radmin"]

# 文件用位址（RFC 5737 / RFC 1918 / loopback）與綁定萬用位址是允許的
ALLOWED = re.compile(
    r"^(127\.0\.0\.1|0\.0\.0\.0|localhost|192\.0\.2\.\d+|198\.51\.100\.\d+"
    r"|203\.0\.113\.\d+|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+)$")

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")


def packaged_files() -> list[Path]:
    found: list[Path] = []
    for root in PACKAGED:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_file() and path.suffix in SUFFIXES \
                    and "__pycache__" not in path.parts:
                found.append(path)
    return sorted(found)


FILES = packaged_files()


def test_there_are_packaged_files_to_check():
    """先證明樣本存在——0 個檔案「全部通過」與真的沒問題長得一樣。"""
    assert FILES, "找不到任何要檢查的交付檔案，這條測試等於沒在測"


@pytest.mark.parametrize("path", FILES, ids=lambda p: str(p.relative_to(REPO)))
def test_no_developer_network_address(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    assert _DEV_NET not in text, (
        f"{path.relative_to(REPO)} 含開發機的 VPN 網段。"
        "交付出去之後，按 Enter 的人會連不上——或更糟，"
        "剛好也在那個網路裡而靜靜連到別人的 Hub。"
    )


@pytest.mark.parametrize("path", FILES, ids=lambda p: str(p.relative_to(REPO)))
def test_no_vpn_brand_names(path: Path):
    lowered = path.read_text(encoding="utf-8", errors="replace").lower()
    for brand in VPN_BRANDS:
        assert brand not in lowered, (
            f"{path.relative_to(REPO)} 指名了 {brand}。前置需求要寫成一個"
            "判準（連不連得到那台機器），不是一個產品名——用別種 VPN 的人"
            "會以為自己不符合需求。"
        )


@pytest.mark.parametrize("path", FILES, ids=lambda p: str(p.relative_to(REPO)))
def test_no_unexpected_hardcoded_ipv4(path: Path):
    """任何真實 IP 都不該出現在交付物裡。

    允許的只有 loopback、綁定萬用位址、私網範圍與 RFC 5737 的文件用位址
    ——那些都不會指向某個特定的人的機器。
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    bad = [ip for ip in IPV4.findall(text) if not ALLOWED.match(ip)]
    assert not bad, (
        f"{path.relative_to(REPO)} 含寫死的 IP：{sorted(set(bad))}。"
        "範例請用 192.0.2.x（RFC 5737 保留給文件，保證不是任何人的機器）。"
    )
