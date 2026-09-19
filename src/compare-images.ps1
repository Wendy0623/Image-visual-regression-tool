param(
    [Parameter(Mandatory = $true)]
    [string]$Baseline,

    [Parameter(Mandatory = $true)]
    [string]$Current,

    [string]$Output = "diff.png",

    [ValidateRange(0, 100)]
    [double]$PixelThresholdPercent = 2.0,

    [ValidateRange(0, 20)]
    [double]$BlurRadius = 0.0,

    [ValidateRange(0, 100)]
    [double]$CoverageLimitPercent = 0.1,

    [ValidateRange(0, 100)]
    [double]$FuzzPercent = 0.0,

    [ValidateRange(0, 100)]
    [double]$AELimitPercent = 0.1,

    [string]$ReportPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-InvariantDouble {
    param([Parameter(Mandatory = $true)][string]$Value)

    $token = ($Value.Trim() -split '\s+')[0]

    return [double]::Parse(
        $token,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Format-Percent {
    param([double]$Value)

    return $Value.ToString(
        "0.###",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-ImageMagick {
    $command = Get-Command magick -ErrorAction SilentlyContinue

    if (-not $command) {
        throw "ImageMagick was not found. Install ImageMagick and make sure 'magick' is available in PATH."
    }
}

function Get-ImageDimensions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = (& magick identify -format "%w %h" -- "$Path").Trim()

    if (-not $raw) {
        throw "Unable to read image dimensions: $Path"
    }

    $parts = $raw -split '\s+'

    if ($parts.Count -ne 2) {
        throw "Unexpected dimension output for: $Path"
    }

    return [pscustomobject]@{
        Width  = [int]$parts[0]
        Height = [int]$parts[1]
    }
}

function Get-AECount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReferencePath,

        [Parameter(Mandatory = $true)]
        [string]$TestPath,

        [double]$TolerancePercent
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $arguments = @("compare")

        if ($TolerancePercent -gt 0) {
            $arguments += @(
                "-fuzz",
                ("{0}%" -f $TolerancePercent)
            )
        }

        $arguments += @(
            "-metric",
            "AE",
            $ReferencePath,
            $TestPath,
            "null:"
        )

        $raw = & magick @arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    if (-not $raw) {
        throw "ImageMagick did not return an AE value."
    }

    $firstLine = ($raw | Select-Object -First 1).ToString().Trim()

    return ConvertTo-InvariantDouble $firstLine
}

function Write-CheckResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $label = if ($Passed) { "PASS" } else { "FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }

    Write-Host (
        "[{0}] {1}: {2}" -f
        $label,
        $Name,
        $Message
    ) -ForegroundColor $color
}

Assert-ImageMagick

if (-not (Test-Path -LiteralPath $Baseline -PathType Leaf)) {
    throw "Baseline image not found: $Baseline"
}

if (-not (Test-Path -LiteralPath $Current -PathType Leaf)) {
    throw "Current image not found: $Current"
}

$dimensions = Get-ImageDimensions -Path $Baseline

$totalPixels =
    [double]$dimensions.Width *
    [double]$dimensions.Height

$tempRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("visual-regression-" + [guid]::NewGuid().ToString("N"))

New-Item `
    -ItemType Directory `
    -Path $tempRoot |
    Out-Null

$baselineNormalized = Join-Path $tempRoot "baseline.png"
$currentNormalized  = Join-Path $tempRoot "current.png"
$differenceImage    = Join-Path $tempRoot "difference.png"
$thresholdMask      = Join-Path $tempRoot "mask.png"
$lightBaseline      = Join-Path $tempRoot "baseline-light.png"
$highlightLayer     = Join-Path $tempRoot "highlight.png"

try {

    # Normalize both images to the baseline size.
    & magick `
        $Baseline `
        -auto-orient `
        -colorspace sRGB `
        -resize ("{0}x{1}!" -f $dimensions.Width, $dimensions.Height) `
        $baselineNormalized

    & magick `
        $Current `
        -auto-orient `
        -colorspace sRGB `
        -resize ("{0}x{1}!" -f $dimensions.Width, $dimensions.Height) `
        $currentNormalized


    # Create grayscale difference image.
    & magick `
        $baselineNormalized `
        $currentNormalized `
        -compose Difference `
        -composite `
        -colorspace Gray `
        $differenceImage


    # Build threshold mask.
    $maskArguments = @(
        $differenceImage
    )

    if ($BlurRadius -gt 0) {
        $maskArguments += @(
            "-blur",
            ("0x{0}" -f $BlurRadius)
        )
    }

    $maskArguments += @(
        "-threshold",
        ("{0}%" -f $PixelThresholdPercent),
        $thresholdMask
    )

    & magick @maskArguments


    # Binary mask mean = changed pixel ratio.
    $maskMeanText =
        (& magick `
            $thresholdMask `
            -format "%[fx:mean]" `
            info:
        ).Trim()

    $maskMean =
        ConvertTo-InvariantDouble $maskMeanText

    $changedPixels =
        [long][math]::Round(
            $maskMean * $totalPixels
        )

    $coveragePercent =
        $maskMean * 100.0


    # AE metric with ImageMagick fuzz tolerance.
    $aeCount =
        Get-AECount `
            -ReferencePath $baselineNormalized `
            -TestPath $currentNormalized `
            -TolerancePercent $FuzzPercent

    $aePercent =
        if ($totalPixels -gt 0) {
            100.0 * $aeCount / $totalPixels
        }
        else {
            0.0
        }


    # PASS / FAIL.
    $coveragePassed =
        $coveragePercent -le $CoverageLimitPercent

    $aePassed =
        $aePercent -le $AELimitPercent

    $overallPassed =
        $coveragePassed -and $aePassed


    # Visual result:
    # changed pixels are highlighted in magenta.
    & magick `
        $baselineNormalized `
        -fill white `
        -colorize 55 `
        $lightBaseline

    & magick `
        $thresholdMask `
        -alpha copy `
        -fill "#ff00ff" `
        -colorize 100 `
        -channel A `
        -evaluate multiply 0.65 `
        +channel `
        $highlightLayer

    & magick `
        $lightBaseline `
        $highlightLayer `
        -compose Over `
        -composite `
        $Output


    Write-Host ""
    Write-Host "=== Visual Regression Result ==="

    Write-Host (
        "Baseline size : {0} x {1}" -f
        $dimensions.Width,
        $dimensions.Height
    )

    Write-Host (
        "Changed pixels: {0} / {1}" -f
        $changedPixels,
        [long]$totalPixels
    )

    Write-Host (
        "Diff coverage : {0}%" -f
        (Format-Percent $coveragePercent)
    )

    Write-Host (
        "AE difference : {0} pixels ({1}%) with fuzz={2}%" -f
        [long]$aeCount,
        (Format-Percent $aePercent),
        (Format-Percent $FuzzPercent)
    )

    Write-Host (
        "Diff image    : {0}" -f
        $Output
    )

    Write-Host ""


    Write-CheckResult `
        -Name "Coverage" `
        -Passed $coveragePassed `
        -Message (
            "{0}% <= limit {1}%" -f
            (Format-Percent $coveragePercent),
            (Format-Percent $CoverageLimitPercent)
        )

    Write-CheckResult `
        -Name "AE" `
        -Passed $aePassed `
        -Message (
            "{0}% <= limit {1}%" -f
            (Format-Percent $aePercent),
            (Format-Percent $AELimitPercent)
        )

    Write-CheckResult `
        -Name "Overall" `
        -Passed $overallPassed `
        -Message $(
            if ($overallPassed) {
                "all checks passed"
            }
            else {
                "one or more checks exceeded the configured limits"
            }
        )


    # Optional JSON report.
    if ($ReportPath) {

        $report = [ordered]@{

            baseline = $Baseline
            current  = $Current
            output   = $Output

            image = [ordered]@{
                width        = $dimensions.Width
                height       = $dimensions.Height
                total_pixels = [long]$totalPixels
            }

            settings = [ordered]@{
                pixel_threshold_percent = $PixelThresholdPercent
                blur_radius             = $BlurRadius
                coverage_limit_percent  = $CoverageLimitPercent
                fuzz_percent            = $FuzzPercent
                ae_limit_percent        = $AELimitPercent
            }

            metrics = [ordered]@{
                changed_pixels   = $changedPixels
                coverage_percent = [math]::Round(
                    $coveragePercent,
                    6
                )
                ae_pixels = [long]$aeCount
                ae_percent = [math]::Round(
                    $aePercent,
                    6
                )
            }

            pass = [ordered]@{
                coverage = $coveragePassed
                ae       = $aePassed
                overall  = $overallPassed
            }
        }

        $report |
            ConvertTo-Json -Depth 6 |
            Set-Content `
                -LiteralPath $ReportPath `
                -Encoding UTF8

        Write-Host (
            "JSON report   : {0}" -f
            $ReportPath
        )
    }


    if ($overallPassed) {
        exit 0
    }
    else {
        exit 2
    }
}
finally {

    Remove-Item `
        -LiteralPath $tempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}
