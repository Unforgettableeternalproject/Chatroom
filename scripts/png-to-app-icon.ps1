# PNG -> 多尺寸 ICO（app/windows/runner/resources/app_icon.ico）。
#
# 用法：pwsh scripts/png-to-app-icon.ps1 -Source logo.png [-Out <路徑>]
#
# 格式是**混合**的，這一點是刻意的，兩個來源都指向它：
#
# 1. `scripts/make-badge-icons.py` 的既有決定——PNG-in-ICO「只在部分 Windows
#    載入路徑上支援，失敗時的症狀是圖示不見了」。所以小尺寸一律 BMP(DIB)，
#    那條路從 Windows 95 就通。
# 2. 但 256 不能用 BMP：那是 ICONDIRENTRY 的寬高欄位只有一個 byte 的尺寸，
#    要寫 0 來表示 256，而 Vista 之後的慣例（Flutter 自己的預設圖也是這樣）
#    就是那一張走 PNG 內嵌。
#
# ⚠️ 驗證產物時**不要用 `System.Drawing.Icon`**：它讀不到 PNG 內嵌的那張，
# 要 256 會安靜退回最大的 BMP，看起來就像「沒有大尺寸」（2026-09-14 實際
# 誤判過一次，還寫進了房內的釋出阻擋理由）。所以這個腳本**寫完自己解析
# ICONDIR 印出結果**——不要求任何人記得另外去驗，也不留一句指向別處的
# 待辦。看輸出那張表就是看真相。
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out
)

Add-Type -AssemblyName System.Drawing

if (-not $Out) {
    $repo = Split-Path -Parent $PSScriptRoot
    $Out = Join-Path $repo "app\windows\runner\resources\app_icon.ico"
}

$bmpSizes = @(16, 24, 32, 48, 64, 128)   # BMP(DIB)：相容路徑
$pngSizes = @(256)                        # PNG 內嵌：256 只有這條路

$src = [System.Drawing.Image]::FromFile((Resolve-Path $Source))
if ($src.Width -lt 256 -or $src.Height -lt 256) {
    Write-Warning "來源只有 $($src.Width)x$($src.Height)，小於 256——放大的那幾張會糊。"
}
if ($src.Width -ne $src.Height) {
    Write-Warning ("來源不是正方形（$($src.Width)x$($src.Height)）——會保持比例置中，" +
        "四周留透明。要填滿整格請自己先裁成方的。")
}

# 圖示格子是正方形的。**非方形來源保持比例、置中、四周留透明**，不要拉伸
# 去填滿——拉伸不會失敗也不會警告，只是把人家的 logo 壓扁，而那種錯要有人
# 盯著圖看才發現。留白會犧牲一點邊長，但它是可逆的損失，變形不是。
# 裁切也不考慮：那會無聲地切掉圖的內容。
function Get-Scaled([System.Drawing.Image]$img, [int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $scale = [math]::Min($s / $img.Width, $s / $img.Height)
    $w = [int][math]::Round($img.Width * $scale)
    $h = [int][math]::Round($img.Height * $scale)
    $g.DrawImage($img, [int](($s - $w) / 2), [int](($s - $h) / 2), $w, $h)
    $g.Dispose()
    return $bmp
}

# BMP(DIB) 的一張：BITMAPINFOHEADER + 由下往上的 BGRA + AND 遮罩。
# 遮罩在 32bpp 下不決定透明度（alpha 已經決定了），但結構固定不能省。
function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
    $s = $bmp.Width
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]40); $bw.Write([int32]$s); $bw.Write([int32]($s * 2))
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
    $rowMask = [math]::Ceiling($s / 32.0) * 4
    $bw.Write([uint32]($s * $s * 4 + $rowMask * $s))
    $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)

    for ($y = $s - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $s; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G)
            $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }
    for ($y = $s - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $rowMask
        for ($x = 0; $x -lt $s; $x++) {
            if ($bmp.GetPixel($x, $y).A -eq 0) {
                $row[[math]::Floor($x / 8)] = $row[[math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8))
            }
        }
        $bw.Write($row)
    }
    $bw.Flush()
    $bytes = $ms.ToArray(); $bw.Close(); $ms.Dispose()
    # ⚠️ 前置逗號不可省：PowerShell 的 return 會把陣列展開成管線元素，
    # 於是收到的是 Object[] 而不是 byte[]。`.Length` 仍然對（元素數一樣），
    # 所以 ICONDIRENTRY 的長度欄位看起來正常，但 BinaryWriter.Write 找不到
    # Object[] 的多載——**資料整段沒寫進去，而且不報錯**。症狀是 offset
    # 指向檔案結尾之外，實測一次。
    return , $bytes
}

$entries = @()
foreach ($s in $bmpSizes) {
    $b = Get-Scaled $src $s
    $entries += , @{ size = $s; bytes = (Get-DibBytes $b) }
    $b.Dispose()
}
foreach ($s in $pngSizes) {
    $b = Get-Scaled $src $s
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $entries += , @{ size = $s; bytes = $ms.ToArray() }
    $ms.Dispose(); $b.Dispose()
}
$src.Dispose()

# ⚠️ **先寫暫存檔，驗過才換上去。** 直接開 $Out 會在第一個位元組寫下去的
# 瞬間就把現有的 icon 截斷——之後只要寫入或自驗任何一步失敗，留在 repo 裡
# 的就是一個壞掉的正式圖示，而且它會跟著下一次 build 進產物。
# 暫存檔放同一個目錄，確保 Move 在同一顆磁碟上是原子的。
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
$tmp = "$Out.tmp"
$fs = $null
$bw = $null
try {
    $fs = [System.IO.File]::Create($tmp)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $dim = if ($e.size -ge 256) { 0 } else { $e.size }   # 256 在單位元組欄位裡寫 0
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$e.bytes.Length); $bw.Write([uint32]$offset)
        $offset += $e.bytes.Length
    }
    foreach ($e in $entries) { $bw.Write($e.bytes) }
    $bw.Flush()
    # 先關掉才讀得到完整內容，也讓 finally 不必再關一次
    $bw.Dispose(); $bw = $null
    $fs.Dispose(); $fs = $null

    # 驗的是**暫存檔**，還沒碰到 $Out。這一段刻意不用 System.Drawing（見檔頭），
    # 只讀 ICONDIR 的結構——它回答的是「檔案裡真的有什麼」，不是「某個 API
    # 看得到什麼」。另外驗每張的資料都落在檔案範圍內：PowerShell 的 return
    # 會把 byte[] 展開成 Object[]，那時長度欄位照樣正確、資料卻沒寫進去，
    # 症狀就是 offset 指到檔案結尾之外（實測踩過，少 93% 內容且零錯誤訊息）。
    $blob = [System.IO.File]::ReadAllBytes($tmp)
    $count = [BitConverter]::ToUInt16($blob, 4)
    "  $count 張（檔案 $($blob.Length) bytes）："
    $bad = 0
    for ($i = 0; $i -lt $count; $i++) {
        $e = 6 + 16 * $i
        $w = $blob[$e]; if ($w -eq 0) { $w = 256 }
        $size = [BitConverter]::ToUInt32($blob, $e + 8)
        $off = [BitConverter]::ToUInt32($blob, $e + 12)
        $fits = ($off + $size) -le $blob.Length
        # 越界時不要去讀那個位置——先問「在不在」再問「是什麼」
        $kind = if (-not $fits) { "??" }
        elseif ($blob[$off] -eq 0x89 -and $blob[$off + 1] -eq 0x50) { "PNG" }
        else { "BMP" }
        if (-not $fits) { $bad++ }
        "     {0,3}x{0,-3} {1,-3} {2,7} bytes{3}" -f $w, $kind, $size, $(if ($fits) { "" } else { "   ← 資料超出檔案！" })
    }
    if ($bad -gt 0) {
        throw "$bad 張的資料沒有寫進檔案——產物不可用，$Out 未更動。"
    }

    # 驗過了才換上去。Move -Force 在同一顆磁碟上是 rename，不留半份檔案。
    Move-Item -LiteralPath $tmp -Destination $Out -Force
    "寫出 $Out"
}
finally {
    # ⚠️ 這個 finally 要擋的不只是自驗失敗那一條路：Create／Write／Flush／
    # ReadAllBytes／Move 任何一步丟例外，都會留下一個半成品 .tmp 和沒關上的
    # handle（後者會讓下一次執行連 .tmp 都刪不掉）。**只在已知的失敗分支
    # 清理，等於只擋自己想得到的那幾種失敗。**
    if ($bw) { $bw.Dispose() }
    if ($fs) { $fs.Dispose() }
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
