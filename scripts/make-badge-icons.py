"""產生工作列角標圖示（`app/assets/badge/*.ico`）。

`windows_taskbar.setOverlayIcon` 只吃 `.ico` 檔路徑，**不能在執行期把數字
畫上去**——Discord 那個紅點數字也是預先做好一組圖示換著用的。所以這裡先
把 1~9 與 9+ 產生出來，App 依未處理數量挑一張。

用純標準庫寫 ICO（`struct` + 手繪點陣），不引入 Pillow：這是**建置期跑一次**
的東西，為它多一個開發依賴不划算，而 ICO 的結構是固定的。

刻意用 BMP(DIB) 而不是 PNG-in-ICO：後者只在部分 Windows 載入路徑上支援，
而失敗時的症狀是「圖示不見了」——那種靜默失效正是這個專案今天付過學費的
形狀。BMP 從 Windows 95 就通。

重新產生：``python scripts/make-badge-icons.py``
"""

from __future__ import annotations

import struct
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "app" / "assets" / "badge"
SIZE = 32

# 徽章底色：紅色系統慣例（未處理／需要注意），與 App 的金色主色分得開，
# 免得在工作列上被當成品牌色而不是狀態。
BADGE_RGB = (0xE5, 0x3E, 0x3E)
TEXT_RGB = (0xFF, 0xFF, 0xFF)

# 5x7 點陣字。小尺寸下用點陣而不是縮放向量字：32px 的圖示縮完會糊，
# 而糊掉的數字在工作列上等於沒有數字。
GLYPHS: dict[str, list[str]] = {
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "..##.", ".#...", "#....", "#####"],
    "3": [".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", "..#..", "..#..", "..#.."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
}


def _blank() -> list[list[tuple[int, int, int, int]]]:
    return [[(0, 0, 0, 0) for _ in range(SIZE)] for _ in range(SIZE)]


def _circle(px) -> None:
    """實心圓。半徑取滿版——角標本來就只有 16x16 的顯示空間，留白等於更小。"""
    c = (SIZE - 1) / 2
    r = SIZE / 2 - 0.5
    for y in range(SIZE):
        for x in range(SIZE):
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            if d <= r - 1:
                px[y][x] = (*BADGE_RGB, 255)
            elif d <= r:
                # 邊緣一圈半透明：沒有它的話圓形在小尺寸下是鋸齒的
                px[y][x] = (*BADGE_RGB, int(255 * (r - d)))


def _draw(px, text: str) -> None:
    scale = 3
    gw = (5 * len(text) + (len(text) - 1)) * scale   # 字間留 1 px
    gh = 7 * scale
    ox = (SIZE - gw) // 2
    oy = (SIZE - gh) // 2
    cx = ox
    for ch in text:
        rows = GLYPHS[ch]
        for gy, row in enumerate(rows):
            for gx, cell in enumerate(row):
                if cell != "#":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        x, y = cx + gx * scale + dx, oy + gy * scale + dy
                        if 0 <= x < SIZE and 0 <= y < SIZE:
                            px[y][x] = (*TEXT_RGB, 255)
        cx += 6 * scale


def _ico(px) -> bytes:
    """單張 32x32 32bpp 的 ICO。"""
    # 像素由下往上、BGRA
    body = bytearray()
    for y in range(SIZE - 1, -1, -1):
        for x in range(SIZE):
            r, g, b, a = px[y][x]
            body += bytes((b, g, r, a))
    # AND 遮罩：32bpp 的 alpha 已經決定透明度，但這個欄位不能省（結構固定）
    mask = bytearray()
    for y in range(SIZE - 1, -1, -1):
        bits = 0
        for x in range(SIZE):
            if px[y][x][3] == 0:
                bits |= 1 << (31 - x)
        mask += struct.pack(">I", bits)

    header = struct.pack(
        "<IiiHHIIiiII",
        40, SIZE, SIZE * 2, 1, 32, 0, len(body) + len(mask), 0, 0, 0, 0,
    )
    image = header + bytes(body) + bytes(mask)
    return (
        struct.pack("<HHH", 0, 1, 1)
        + struct.pack("<BBBBHHII", SIZE, SIZE, 0, 0, 1, 32, len(image), 22)
        + image
    )


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    written = []
    for n in range(1, 10):
        px = _blank()
        _circle(px)
        _draw(px, str(n))
        path = OUT / f"{n}.ico"
        path.write_bytes(_ico(px))
        written.append(path.name)
    # 10 以上一律 9+：兩位數在 16x16 的角標上讀不出來，而「很多」這個資訊
    # 本身就夠了——精確數字要看 App 裡面
    px = _blank()
    _circle(px)
    _draw(px, "9+")
    (OUT / "9plus.ico").write_bytes(_ico(px))
    written.append("9plus.ico")
    print(f"寫入 {OUT}：{', '.join(written)}")


if __name__ == "__main__":
    main()
