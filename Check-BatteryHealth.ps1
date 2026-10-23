$ErrorActionPreference = 'Stop'

# Battery health checker inspired by open-source PowerShell implementations:
# - homotechsual/Blog-Scripts: powercfg XML report parsing
# - NSTechBytes/BatteryHealth: capacity ratio and readable summary
# Uses Windows built-in tools only. No WMI and no third-party modules.

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("==== {0} ====" -f $Text) -ForegroundColor Cyan
}

function Get-ChildText {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$Name
    )
    if ($null -eq $Node) { return $null }

    $child = $Node.SelectSingleNode("./*[local-name()='$Name']")
    if ($null -eq $child) { return $null }

    $value = $child.InnerText
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value.Trim()
}

function Convert-NonNegativeInt64 {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parsed = [long]0
    if ([long]::TryParse($Value.Trim(), [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }

    return $null
}

function Get-BatteryEntries {
    param([xml]$Document)

    # Prefer the documented BatteryReport/Batteries/Battery path.
    # local-name() fallback tolerates XML namespaces.
    $nodes = $Document.SelectNodes(
        "/*[local-name()='BatteryReport']/*[local-name()='Batteries']/*[local-name()='Battery']"
    )

    # Some Windows versions may expose a different nesting structure.
    if ($null -eq $nodes -or $nodes.Count -eq 0) {
        $nodes = $Document.SelectNodes("//*[local-name()='Battery']")
    }

    $items = @()
    foreach ($node in $nodes) {
        $design = Convert-NonNegativeInt64 (Get-ChildText $node 'DesignCapacity')
        $full = Convert-NonNegativeInt64 (Get-ChildText $node 'FullChargeCapacity')

        if ($null -eq $design -or $null -eq $full) { continue }

        $id = $null
        if ($null -ne $node.Attributes['id']) {
            $id = $node.Attributes['id'].Value
        }
        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = 'Battery ' + ($items.Count + 1)
        }

        $items += [PSCustomObject]@{
            Id = $id
            DesignCapacity = $design
            FullChargeCapacity = $full
            CycleCount = Convert-NonNegativeInt64 (Get-ChildText $node 'CycleCount')
        }
    }

    return ,$items
}

$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = Join-Path $env:USERPROFILE 'Desktop'
}
$xmlPath = Join-Path $desktop 'BatteryReport.xml'
$htmlPath = Join-Path $desktop 'BatteryHealth.html'
$powercfg = Join-Path $env:WINDIR 'System32\powercfg.exe'

try {
    Write-Host ''
    Write-Host 'Windows Battery Health Check' -ForegroundColor Cyan
    Write-Host 'Uses the built-in powercfg XML battery report.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-Path -LiteralPath $powercfg)) {
        throw 'Windows powercfg.exe was not found.'
    }

    # Remove an older report first, so an unsuccessful command cannot leave
    # a stale report that looks like a fresh result.
    if (Test-Path -LiteralPath $xmlPath) {
        Remove-Item -LiteralPath $xmlPath -Force
    }

    Write-Host 'Generating XML report on Desktop...' -ForegroundColor Yellow
    & $powercfg /batteryreport /xml /output $xmlPath

    if ($LASTEXITCODE -ne 0) {
        throw "powercfg failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        throw 'The XML report was not created. This device or Windows build may not support this report.'
    }
    if ((Get-Item -LiteralPath $xmlPath).Length -eq 0) {
        throw 'The XML report is empty.'
    }

    [xml]$document = New-Object System.Xml.XmlDocument
    $document.Load($xmlPath)

    $batteries = @(Get-BatteryEntries $document)

    if ($batteries.Count -eq 0) {
        Write-Host 'No valid battery capacity entries were found in the XML report.' -ForegroundColor Yellow
        Write-Host 'The report has been kept on your Desktop for diagnosis.' -ForegroundColor Yellow
        Write-Host ("Report: {0}" -f $xmlPath)
        throw 'Cannot calculate health because DesignCapacity or FullChargeCapacity is missing or invalid.'
    }

    Write-Section 'RESULTS'
    Write-Host ("Battery entries found: {0}" -f $batteries.Count)

    $index = 0
    foreach ($battery in $batteries) {
        $index++
        Write-Host ''
        Write-Host ("Battery {0}: {1}" -f $index, $battery.Id) -ForegroundColor Cyan

        Write-Host ("  Design capacity      : {0:N0} mWh" -f $battery.DesignCapacity)
        Write-Host ("  Full charge capacity : {0:N0} mWh" -f $battery.FullChargeCapacity)

        if ($battery.DesignCapacity -le 0 -or $battery.FullChargeCapacity -le 0) {
            Write-Host '  Health                : Not available (capacity is zero)' -ForegroundColor Red
            continue
        }

        $health = [math]::Round(100.0 * $battery.FullChargeCapacity / $battery.DesignCapacity, 1)
        $wear = [math]::Round(100.0 - $health, 1)

        if ($health -lt 50) {
            $color = 'Red'
            $status = 'Significant capacity loss'
        }
        elseif ($health -lt 80) {
            $color = 'Yellow'
            $status = 'Capacity has degraded'
        }
        else {
            $color = 'Green'
            $status = 'Capacity is generally good'
        }

        Write-Host ("  Battery health        : {0:N1}%" -f $health) -ForegroundColor $color
        Write-Host ("  Estimated capacity loss: {0:N1}%" -f $wear) -ForegroundColor $color
        Write-Host ("  Assessment            : {0}" -f $status) -ForegroundColor $color

        if ($null -ne $battery.CycleCount) {
            Write-Host ("  Cycle count            : {0}" -f $battery.CycleCount)
        }
        else {
            Write-Host '  Cycle count            : Not provided by firmware/report' -ForegroundColor DarkGray
        }
    }

    # Build a browser-friendly HTML summary from the same XML values.
    # Keep the original XML for troubleshooting; HTML is a separate presentation file.
    $rows = foreach ($battery in $batteries) {
        $safeId = [System.Security.SecurityElement]::Escape([string]$battery.Id)
        $designText = '{0:N0}' -f $battery.DesignCapacity
        $fullText = '{0:N0}' -f $battery.FullChargeCapacity
        $cycleText = if ($null -ne $battery.CycleCount) { [string]$battery.CycleCount } else { '未提供' }

        if ($battery.DesignCapacity -le 0 -or $battery.FullChargeCapacity -le 0) {
            $healthText = '不可计算'
            $wearText = '不可计算'
            $statusText = '容量数据无效'
            $statusClass = 'unknown'
        }
        else {
            $healthValue = [math]::Round(100.0 * $battery.FullChargeCapacity / $battery.DesignCapacity, 1)
            $wearValue = [math]::Round(100.0 - $healthValue, 1)
            $healthText = '{0:N1}%' -f $healthValue
            $wearText = '{0:N1}%' -f $wearValue
            if ($healthValue -lt 50) {
                $statusText = '容量损耗较大'
                $statusClass = 'bad'
            }
            elseif ($healthValue -lt 80) {
                $statusText = '容量有所衰减'
                $statusClass = 'warn'
            }
            else {
                $statusText = '容量状态良好'
                $statusClass = 'good'
            }
        }

        $safeCycle = [System.Security.SecurityElement]::Escape($cycleText)
        '<tr><td>{0}</td><td>{1} mWh</td><td>{2} mWh</td><td><strong>{3}</strong></td><td>{4}</td><td><span class="status {5}">{6}</span></td></tr>' -f $safeId, $designText, $fullText, $healthText, $safeCycle, $statusClass, $statusText
    }

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>电池健康度报告</title>
<style>
:root { color-scheme: light dark; }
body { margin: 0; padding: 32px 18px; font-family: "Segoe UI", "Microsoft YaHei", sans-serif; background: #f3f6fb; color: #172033; }
main { max-width: 1000px; margin: auto; }
header, section { background: #fff; border-radius: 16px; padding: 24px; margin-bottom: 18px; box-shadow: 0 6px 24px rgba(30,50,80,.08); }
h1 { margin: 0 0 8px; font-size: 28px; } .muted { color: #687386; font-size: 14px; }
.table-wrap { overflow-x: auto; } table { width: 100%; border-collapse: collapse; min-width: 680px; }
th, td { padding: 14px 12px; text-align: left; border-bottom: 1px solid #e7ebf2; }
th { background: #f7f9fc; font-size: 13px; color: #536176; }
.status { display: inline-block; padding: 5px 10px; border-radius: 999px; font-size: 13px; font-weight: 600; }
.good { background: #dcfce7; color: #166534; } .warn { background: #fef3c7; color: #92400e; }
.bad { background: #fee2e2; color: #991b1b; } .unknown { background: #e5e7eb; color: #374151; }
.note { line-height: 1.7; color: #4b5563; }
@media (prefers-color-scheme: dark) {
 body { background: #111827; color: #e5e7eb; } header, section { background: #1f2937; }
 th { background: #273449; color: #cbd5e1; } th, td { border-color: #374151; }
 .muted, .note { color: #cbd5e1; }
}
</style>
</head>
<body>
<main>
<header>
<h1>电池健康度报告</h1>
<div class="muted">生成时间：$generatedAt</div>
</header>
<section>
<div class="table-wrap">
<table>
<thead><tr><th>电池</th><th>设计容量</th><th>当前满充容量</th><th>健康度</th><th>循环次数</th><th>评估</th></tr></thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
</div>
</section>
<section class="note">
<strong>计算说明</strong><br>
健康度 = 当前满充容量 ÷ 设计容量 × 100%。<br>
容量损耗率 = 100% − 健康度。健康度高于 100% 也可能出现，不一定代表故障。循环次数取决于设备固件是否提供。<br>
原始 XML 数据保存在桌面：BatteryReport.xml
</section>
</main>
</body>
</html>
"@

    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

    Write-Host ''
    Write-Host ("XML report saved at: {0}" -f $xmlPath) -ForegroundColor Green
    Write-Host ("HTML report saved at: {0}" -f $htmlPath) -ForegroundColor Green
    Write-Host 'Opening the HTML report in your default browser...' -ForegroundColor Cyan
    Start-Process -FilePath $htmlPath
    Write-Host 'Health = Full charge capacity / Design capacity * 100%.'
    Write-Host 'A result above 100% can occur and does not automatically mean a fault.'
}
catch {
    Write-Host ''
    Write-Host 'CHECK FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host ("If generated, the XML report is here: {0}" -f $xmlPath) -ForegroundColor Yellow
    exit 1
}
