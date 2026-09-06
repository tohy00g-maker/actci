# 產生 actci 的程式圖示：assets\actci.ico（16/24/32/48/64/256）與 assets\actci.png（256 預覽）。
#
# 圖意：深藍圓角底、白色循環箭頭（CI 一圈一圈跑）、右下角綠色勾（判定）。
# 用 GDI+ 直接畫，不依賴任何外部工具；改了想重畫就再跑一次。
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File assets\make-icon.ps1

param([string]$OutDir = $PSScriptRoot)

Add-Type -AssemblyName System.Drawing

function New-IconBitmap([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # 底：圓角方形，漸層藍
    $r = [single]($s * 0.22)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($s - $d, 0, $d, $d, 270, 90)
    $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90)
    $path.AddArc(0, $s - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point($s, $s)),
        [System.Drawing.Color]::FromArgb(255, 47, 129, 247), [System.Drawing.Color]::FromArgb(255, 13, 65, 157))
    $g.FillPath($brush, $path)

    # 循環箭頭：一段 270 度的弧，尾端接一個箭頭
    $stroke = [single]([Math]::Max(1.5, $s * 0.115))
    $inset = [single]($s * 0.24)
    $arcRect = New-Object System.Drawing.RectangleF($inset, $inset, ($s - 2 * $inset), ($s - 2 * $inset))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $stroke)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    # 缺口留在右下角（徽章那一側）：從 60 度順時針畫 300 度，終點在 0 度（正右方）。
    # GDI+ 的角度是順時針、y 軸朝下。
    $startAngle = 75; $sweep = 265   # 終點 340 度（右上），箭頭露在徽章外面指向它
    $g.DrawArc($pen, $arcRect, $startAngle, $sweep)

    # 箭頭在弧的終點，沿順時針切線方向指出去（也就是指向徽章）。
    $cx = $s / 2.0; $cy = $s / 2.0; $radius = ($s - 2 * $inset) / 2.0
    $a = (($startAngle + $sweep) % 360) * [Math]::PI / 180.0
    $endX = $cx + $radius * [Math]::Cos($a); $endY = $cy + $radius * [Math]::Sin($a)
    $tx = -[Math]::Sin($a); $ty = [Math]::Cos($a)     # 順時針切線
    $nx = [Math]::Cos($a); $ny = [Math]::Sin($a)      # 徑向
    $len = $s * 0.19; $half = $s * 0.125
    $tip = New-Object System.Drawing.PointF([single]($endX + $tx * $len), [single]($endY + $ty * $len))
    $b1 = New-Object System.Drawing.PointF([single]($endX + $nx * $half), [single]($endY + $ny * $half))
    $b2 = New-Object System.Drawing.PointF([single]($endX - $nx * $half), [single]($endY - $ny * $half))
    $g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]@($tip, $b1, $b2))

    # 右下角綠色勾徽章
    $br = $s * 0.21
    $bx = $s * 0.71; $by = $s * 0.71
    $ring = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 13, 65, 157), [single]([Math]::Max(1, $s * 0.05)))
    $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 46, 160, 67))), [single]($bx - $br), [single]($by - $br), [single](2 * $br), [single](2 * $br))
    $g.DrawEllipse($ring, [single]($bx - $br), [single]($by - $br), [single](2 * $br), [single](2 * $br))
    $check = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single]([Math]::Max(1.2, $s * 0.07)))
    $check.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $check.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $check.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF([single]($bx - $br * 0.48), [single]($by + $br * 0.02))),
        (New-Object System.Drawing.PointF([single]($bx - $br * 0.12), [single]($by + $br * 0.40))),
        (New-Object System.Drawing.PointF([single]($bx + $br * 0.52), [single]($by - $br * 0.38)))
    )
    $g.DrawLines($check, $pts)

    $g.Dispose(); $pen.Dispose(); $brush.Dispose(); $ring.Dispose(); $check.Dispose()
    return $bmp
}

function Get-PngBytes([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    # 逗號不能省：byte[] 直接 return 會被 PowerShell 拆成一顆一顆的位元組進管線。
    return ,$ms.ToArray()
}

function Write-Ico([string]$path, [int[]]$sizes) {
    # ICO 容器：6 位元組檔頭 + 每張 16 位元組目錄 + 影像資料（PNG 壓縮，Vista 起支援）
    $images = foreach ($s in $sizes) { $b = New-IconBitmap $s; $png = [byte[]](Get-PngBytes $b); $b.Dispose(); [pscustomobject]@{ Size = $s; Data = $png } }
    $images = @($images)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {
        $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$img.Data.Length); $w.Write([uint32]$offset)
        $offset += $img.Data.Length
    }
    foreach ($img in $images) { $w.Write([byte[]]$img.Data) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
    $w.Dispose()
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ico = Join-Path $OutDir 'actci.ico'
$png = Join-Path $OutDir 'actci.png'
Write-Ico -path $ico -sizes @(16, 24, 32, 48, 64, 256)
$preview = New-IconBitmap 256
$preview.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()
# 小尺寸預覽，看 16 與 32 認不認得出來
$sheet = New-Object System.Drawing.Bitmap(200, 72)
$sg = [System.Drawing.Graphics]::FromImage($sheet); $sg.Clear([System.Drawing.Color]::White)
$x = 8
foreach ($s in 16, 24, 32, 48, 64) { $b = New-IconBitmap $s; $sg.DrawImageUnscaled($b, $x, [int](36 - $s / 2)); $b.Dispose(); $x += $s + 8 }
$sg.Dispose(); $sheet.Save((Join-Path $OutDir 'actci-sizes.png'), [System.Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
"寫入 $ico（$((Get-Item $ico).Length) bytes）與 $png"
