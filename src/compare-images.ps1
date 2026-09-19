param(
    [string]$baseline,
    [string]$current,
    [string]$output            = "diff.png",

    # 灰階差異門檻 (%)：大於這個亮度差的 pixel 算「有差」（粉色那條）
    [int]   $thresholdPercent  = 2,

    # 模糊半徑 (像素)：0 = 不模糊，1~2 可去掉一點噪點（同時用在兩個 mask 上）
    [int]   $blurRadius        = 0,

    # Diff coverage PASS/FAIL 門檻 (%)
    [double]$coverageThreshold = 0.1,

    # FUZZ 對應的差異門檻 (%)，用來做「FUZZ mask」
    # 0 代表只要有差就算（用 threshold 0%）
    [int]   $metricFuzzPercent = 0,

    # AE 佔比 PASS/FAIL 門檻 (%)
    [double]$aeMaxPercent      = 0.1
)

$ErrorActionPreference = 'Stop'

# --------- 工具：數字顯示成最多小數點後 3 位 ---------
function Format-Num3 {
    param([double]$x)
    return ('{0:0.###}' -f $x)
}

# --------- 工具：安全轉 double ---------
function Parse-Double {
    param([string]$text)

    if (-not $text) { return 0.0 }

    $text  = $text.Trim()
    $token = $text.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)[0]

    return [double]::Parse($token, [System.Globalization.CultureInfo]::InvariantCulture)
}

# --------- 工具：取得 AE (會吃 fuzz) ---------
function Get-AE {
    param(
        [Parameter(Mandatory)][string]$base,
        [Parameter(Mandatory)][string]$curr
    )

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $args = @('compare')
        if ($metricFuzzPercent -gt 0) {
            $args += '-fuzz'
            $args += ("{0}%%" -f $metricFuzzPercent)  # 例如 "2%"
        }
        $args += @('-metric', 'AE', $base, $curr, 'null:')

        $raw = & magick @args 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    if (-not $raw) { return $null }

    $line = ($raw | Select-Object -First 1).ToString().Trim()
    if (-not $line) { return $null }

    return Parse-Double $line
}

# --------- 檢查路徑 ---------
if (-not (Test-Path $baseline)) {
    Write-Host "Baseline image not found: $baseline" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $current)) {
    Write-Host "Current image not found:  $current" -ForegroundColor Red
    exit 1
}

# --------- 暫存檔 ---------
$baseResized  = Join-Path $env:TEMP "_cmp_base_resized.png"
$currResized  = Join-Path $env:TEMP "_cmp_curr_resized.png"
$diffGray     = Join-Path $env:TEMP "_cmp_diff_gray.png"

$maskT        = Join-Path $env:TEMP "_cmp_mask_threshold.png"   # Threshold 用
$maskF        = Join-Path $env:TEMP "_cmp_mask_fuzz.png"        # FUZZ 用

$maskOverlap  = Join-Path $env:TEMP "_cmp_mask_overlap.png"     # T ∧ F
$maskOnlyT    = Join-Path $env:TEMP "_cmp_mask_onlyT.png"       # 只 Threshold
$maskOnlyF    = Join-Path $env:TEMP "_cmp_mask_onlyF.png"       # 只 FUZZ

$tintT        = Join-Path $env:TEMP "_cmp_tint_threshold.png"   # 粉
$tintF        = Join-Path $env:TEMP "_cmp_tint_fuzz.png"        # 藍
$tintO        = Join-Path $env:TEMP "_cmp_tint_overlap.png"     # 綠

$baseShaded   = Join-Path $env:TEMP "_cmp_base_shaded.png"
$tmp1         = Join-Path $env:TEMP "_cmp_tmp1.png"
$tmp2         = Join-Path $env:TEMP "_cmp_tmp2.png"

try {
    # ===== 1) 尺寸對齊：以 baseline 為基準 =====
    $sizeStr = & magick identify -format "%w %h" "$baseline"
    if (-not $sizeStr) {
        Write-Host "Failed to read baseline size." -ForegroundColor Red
        exit 1
    }
    $parts = $sizeStr.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    [int]$width  = $parts[0]
    [int]$height = $parts[1]
    [double]$totalPixels = [double]$width * [double]$height

    & magick "$baseline" -resize "${width}x${height}!" "$baseResized"
    & magick "$current"  -resize "${width}x${height}!" "$currResized"

    # ===== 2) 灰階差異圖 =====
    & magick "$baseResized" "$currResized" -compose Difference -composite -colorspace Gray "$diffGray"

    # ===== 3) 兩種門檻的 mask：Threshold 用 (粉) & FUZZ 用 (藍) =====
    if ($blurRadius -gt 0) {
        & magick "$diffGray" -blur 0x$blurRadius -threshold ("{0}%%" -f $thresholdPercent) "$maskT"
    } else {
        & magick "$diffGray" -threshold ("{0}%%" -f $thresholdPercent) "$maskT"
    }

    $fuzzThrStr = if ($metricFuzzPercent -le 0) { "0%" } else { ("{0}%%" -f $metricFuzzPercent) }
    if ($blurRadius -gt 0) {
        & magick "$diffGray" -blur 0x$blurRadius -threshold $fuzzThrStr "$maskF"
    } else {
        & magick "$diffGray" -threshold $fuzzThrStr "$maskF"
    }

    # ===== 4) coverage 計算（用 Threshold 的 mask）=====
    $meanStr = & magick "$maskT" -format "%[fx:mean]" info:
    $meanVal = Parse-Double $meanStr
    $diffPixels = [long]([math]::Round($meanVal * $totalPixels))
    $coverage   = $meanVal * 100.0

    $covStr     = Format-Num3 $coverage
    $totalPix_i = [long]$totalPixels

    Write-Host ("Diff coverage : {0} percent  ({1} / {2} pixels)" -f $covStr, $diffPixels, $totalPix_i)

    $covThrStr = Format-Num3 $coverageThreshold
    $covPass   = ($coverage -lt $coverageThreshold)
    if ($covPass) {
        Write-Host ("[COVERAGE] PASS : coverage {0} < threshold {1} percent" -f $covStr, $covThrStr) -ForegroundColor Green
    } else {
        Write-Host ("[COVERAGE] FAIL : coverage {0} >= threshold {1} percent" -f $covStr, $covThrStr) -ForegroundColor Red
    }

    # ===== 5) 先「分類」再上色：每個 pixel 只屬於一種 =====
    # u = Threshold mask, v = FUZZ mask，兩張都是 0 or 1 (經過 threshold 後)
    # Overlap : T && F
    & magick "$maskT" "$maskF" -fx 't = (u>0.5); f = (v>0.5); t && f ? 1 : 0' "$maskOverlap"
    # OnlyT   : T && !F
    & magick "$maskT" "$maskF" -fx 't = (u>0.5); f = (v>0.5); t && !f ? 1 : 0' "$maskOnlyT"
    # OnlyF   : F && !T
    & magick "$maskT" "$maskF" -fx 't = (u>0.5); f = (v>0.5); f && !t ? 1 : 0' "$maskOnlyF"

    # ===== 6) 視覺化：白底 + 粉 / 藍 / 綠 =====
    # 6a) baseline 整體洗白
    & magick "$baseResized" -fill white -colorize 60 "$baseShaded"

    # 6b) 粉色（只 Threshold）
    & magick "$maskOnlyT" `
        -alpha copy `
        -fill "#ff00ff" -colorize 100 `
        -channel A -evaluate multiply 0.6 +channel `
        "$tintT"

    # 6c) 藍色（只 FUZZ）
    & magick "$maskOnlyF" `
        -alpha copy `
        -fill "#0000ff" -colorize 100 `
        -channel A -evaluate multiply 0.6 +channel `
        "$tintF"

    # 6d) 綠色（兩者重疊）
    & magick "$maskOverlap" `
        -alpha copy `
        -fill "#00ff00" -colorize 100 `
        -channel A -evaluate multiply 0.6 +channel `
        "$tintO"

    # 6e) 疊合：先粉 → 再藍 → 再綠（但因為三張 mask 已互斥，所以不會再互相蓋色）
    & magick "$baseShaded" "$tintT" -compose Over -composite "$tmp1"
    & magick "$tmp1"       "$tintF" -compose Over -composite "$tmp2"
    & magick "$tmp2"       "$tintO" -compose Over -composite "$output"

    # ===== 7) AE (with fuzz) =====
    Write-Host ""
    Write-Host ("==== AE metric (with fuzz = {0}% ) ====" -f $metricFuzzPercent)

    $aeRaw = Get-AE -base $baseResized -curr $currResized

    if ($aeRaw -eq $null) {
        Write-Host "AE : N/A (compare failed)" -ForegroundColor Yellow
        $aePass = $false
    } else {
        $aePercent = if ($totalPixels -gt 0) {
            100.0 * $aeRaw / $totalPixels
        } else { 0.0 }

        $aePercentStr = Format-Num3 $aePercent
        $aeMaxStr     = Format-Num3 $aeMaxPercent

        Write-Host ("AE : {0} pixels ({1} percent of image)" -f ([long]$aeRaw), $aePercentStr)

        $aePass = ($aePercent -le $aeMaxPercent)
        if ($aePass) {
            Write-Host ("[AE] PASS : {0} <= {1} percent" -f $aePercentStr, $aeMaxStr) -ForegroundColor Green
        } else {
            Write-Host ("[AE] FAIL : {0} > {1} percent" -f $aePercentStr, $aeMaxStr) -ForegroundColor Red
        }
    }

    # ===== 8) 總結 Result =====
    Write-Host ""
    if ($covPass -and $aePass) {
        Write-Host "Result: PASS (coverage + AE both within limits)" -ForegroundColor Green
    } else {
        Write-Host "Result: FAIL (either coverage or AE exceeds limits)" -ForegroundColor Red
    }
}
finally {
    Remove-Item $baseResized, $currResized, $diffGray, `
                $maskT, $maskF, $maskOverlap, $maskOnlyT, $maskOnlyF, `
                $tintT, $tintF, $tintO, $baseShaded, $tmp1, $tmp2 `
                -ErrorAction SilentlyContinue
}
