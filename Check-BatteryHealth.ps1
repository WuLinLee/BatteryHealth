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

    Write-Host ''
    Write-Host ("XML report saved at: {0}" -f $xmlPath) -ForegroundColor Green
    Write-Host 'The XML report is intentionally kept on the Desktop.'
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
