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
$nativeHtmlPath = Join-Path $desktop 'BatteryReport-Windows.html'
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

    # Create Microsoft's native HTML report too, so history charts and estimates remain available.
    $nativeHtmlAvailable = $false
    try {
        if (Test-Path -LiteralPath $nativeHtmlPath) { Remove-Item -LiteralPath $nativeHtmlPath -Force }
        & $powercfg /batteryreport /output $nativeHtmlPath | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $nativeHtmlPath) -and
            (Get-Item -LiteralPath $nativeHtmlPath).Length -gt 0) {
            $nativeHtmlAvailable = $true
        } else {
            Write-Host 'Windows native HTML report was not created; XML details will still be shown.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host 'Windows native HTML report could not be generated; continuing with XML details.' -ForegroundColor Yellow
    }

    $batteries = @(Get-BatteryEntries $document)

    if ($batteries.Count -eq 0) {
        Write-Host 'No valid battery capacity entries were found in the XML report.' -ForegroundColor Yellow
        Write-Host 'The detailed HTML report will still be created to show the XML fields.' -ForegroundColor Yellow
        Write-Host ("Report: {0}" -f $xmlPath)
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

    # Render all XML leaf values and attributes, including fields unknown to this script.
    function ConvertTo-HtmlSafe {
        param([AllowNull()][object]$Value)
        if ($null -eq $Value) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    function Get-XmlNodePath {
        param([System.Xml.XmlNode]$Node, [System.Xml.XmlNode]$Section)
        $parts = @()
        $current = $Node
        while ($null -ne $current -and $current.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            $segment = $current.LocalName
            $parent = $current.ParentNode
            if ($null -ne $parent) {
                $siblings = @($parent.ChildNodes | Where-Object {
                    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq $current.LocalName
                })
                if ($siblings.Count -gt 1) {
                    $ordinal = 1
                    for ($i = 0; $i -lt $siblings.Count; $i++) {
                        if ([object]::ReferenceEquals($siblings[$i], $current)) { $ordinal = $i + 1; break }
                    }
                    $segment = '{0} [{1}]' -f $segment, $ordinal
                }
            }
            $parts = @($segment) + $parts
            if ([object]::ReferenceEquals($current, $Section)) { break }
            $current = $parent
        }
        return '/' + ($parts -join '/')
    }

    $batteryRows = foreach ($battery in $batteries) {
        $safeId = ConvertTo-HtmlSafe $battery.Id
        $cycleText = if ($null -ne $battery.CycleCount) { ConvertTo-HtmlSafe $battery.CycleCount } else { '未提供' }
        if ($battery.DesignCapacity -le 0 -or $battery.FullChargeCapacity -le 0) {
            $healthText = '不可计算'; $wearText = '不可计算'; $statusText = '容量数据无效'; $statusClass = 'unknown'
        } else {
            $healthValue = [math]::Round(100.0 * $battery.FullChargeCapacity / $battery.DesignCapacity, 1)
            $wearValue = [math]::Round(100.0 - $healthValue, 1)
            $healthText = '{0:N1}%' -f $healthValue
            $wearText = '{0:N1}%' -f $wearValue
            if ($healthValue -lt 50) { $statusText = '容量损耗较大'; $statusClass = 'bad' }
            elseif ($healthValue -lt 80) { $statusText = '容量有所衰减'; $statusClass = 'warn' }
            else { $statusText = '容量状态良好'; $statusClass = 'good' }
        }
        '<tr><td>{0}</td><td>{1:N0} mWh</td><td>{2:N0} mWh</td><td><strong>{3}</strong></td><td>{4}</td><td>{5}</td><td><span class="status {6}">{7}</span></td></tr>' -f $safeId, $battery.DesignCapacity, $battery.FullChargeCapacity, $healthText, $wearText, $cycleText, $statusClass, $statusText
    }

    $sectionHtml = New-Object 'System.Collections.Generic.List[string]'
    $totalElementCount = 0
    $totalFieldCount = 0
    foreach ($sectionNode in $document.DocumentElement.ChildNodes) {
        if ($sectionNode.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $elementNodes = @($sectionNode) + @($sectionNode.SelectNodes('.//*'))
        $fieldRows = New-Object 'System.Collections.Generic.List[string]'
        $localLeafCount = 0
        $localAttributeCount = 0

        foreach ($element in $elementNodes) {
            $totalElementCount++
            $hasElementChild = $false
            foreach ($child in $element.ChildNodes) {
                if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) { $hasElementChild = $true; break }
            }
            if (-not $hasElementChild) {
                $path = ConvertTo-HtmlSafe (Get-XmlNodePath -Node $element -Section $sectionNode)
                $value = [string]$element.InnerText
                if ([string]::IsNullOrWhiteSpace($value)) { $value = '(空值)' }
                $fieldRows.Add('<tr><td class="path">{0}</td><td>{1}</td></tr>' -f $path, (ConvertTo-HtmlSafe $value))
                $localLeafCount++
            }
            if ($null -ne $element.Attributes) {
                foreach ($attribute in $element.Attributes) {
                    $path = ConvertTo-HtmlSafe ((Get-XmlNodePath -Node $element -Section $sectionNode) + '/@' + $attribute.LocalName)
                    $fieldRows.Add('<tr><td class="path">{0}</td><td>{1}</td></tr>' -f $path, (ConvertTo-HtmlSafe $attribute.Value))
                    $localAttributeCount++
                }
            }
        }

        $totalFieldCount += $fieldRows.Count
        $safeSectionName = ConvertTo-HtmlSafe $sectionNode.LocalName
        $sectionTitle = '{0} — {1} 个字段值（{2} 个叶子节点，{3} 个属性）' -f $safeSectionName, $fieldRows.Count, $localLeafCount, $localAttributeCount
        $safeSectionTitle = ConvertTo-HtmlSafe $sectionTitle
        $tableRows = $fieldRows -join [Environment]::NewLine
        $sectionHtml.Add(@"
<details class="xml-section">
<summary>$safeSectionTitle</summary>
<div class="table-wrap"><table class="data-table"><thead><tr><th>XML 路径</th><th>值</th></tr></thead><tbody>
$tableRows
</tbody></table></div>
</details>
"@)
    }

    $xmlText = [System.IO.File]::ReadAllText($xmlPath)
    $rawXmlSafe = ConvertTo-HtmlSafe $xmlText
    $sectionHtmlText = $sectionHtml -join [Environment]::NewLine
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $xmlInfo = Get-Item -LiteralPath $xmlPath
    $xmlSizeKb = [math]::Round($xmlInfo.Length / 1KB, 1)
    if ($nativeHtmlAvailable) {
        $nativeHtmlLink = '<a class="link-button" href="BatteryReport-Windows.html">打开 Windows 原生完整电池报告</a>'
        $nativeStatusText = '已生成'
    } else {
        $nativeHtmlLink = '<span class="muted">Windows 原生报告未生成；下方仍会显示 XML 全部可用字段。</span>'
        $nativeStatusText = '未生成'
    }
    if ($batteries.Count -gt 0) {
        $batterySummary = '识别到 {0} 个包含设计容量和满充容量的电池条目。' -f $batteries.Count
    } else {
        $batterySummary = '未识别到包含有效设计容量和满充容量的电池条目。请查看下方 XML 字段；脚本不会猜测健康度。'
    }
    $safeBatterySummary = ConvertTo-HtmlSafe $batterySummary
    $safeGeneratedAt = ConvertTo-HtmlSafe $generatedAt
    $safeXmlPath = ConvertTo-HtmlSafe $xmlPath

    $html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Windows 电池健康度与完整数据报告</title>
<style>
:root { color-scheme: light dark; } * { box-sizing: border-box; }
body { margin: 0; padding: 28px 16px 48px; font-family: "Segoe UI", "Microsoft YaHei", sans-serif; background: #f2f5fa; color: #182235; line-height: 1.55; }
main { max-width: 1180px; margin: auto; }
header, section { background: #fff; border-radius: 15px; padding: 22px; margin-bottom: 18px; box-shadow: 0 6px 24px rgba(30,50,80,.07); }
h1 { margin: 0 0 8px; font-size: clamp(25px, 4vw, 34px); } h2 { margin: 0 0 14px; font-size: 21px; }
.muted { color: #687386; font-size: 13px; overflow-wrap: anywhere; } .lead { font-size: 15px; margin: 16px 0 0; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-top: 20px; }
.kpi { padding: 16px; border: 1px solid #e5eaf2; border-radius: 12px; background: #f9fbfe; min-width: 0; }
.kpi .label { color: #67758a; font-size: 13px; margin-bottom: 5px; } .kpi .value { font-size: 22px; font-weight: 700; overflow-wrap: anywhere; }
.table-wrap { width: 100%; overflow-x: auto; } table { width: 100%; border-collapse: collapse; min-width: 740px; }
th, td { padding: 12px; text-align: left; vertical-align: top; border-bottom: 1px solid #e7ebf2; }
th { background: #f7f9fc; font-size: 12px; color: #536176; white-space: nowrap; } td { font-size: 14px; overflow-wrap: anywhere; }
.status { display: inline-block; padding: 4px 9px; border-radius: 999px; font-size: 12px; font-weight: 700; white-space: nowrap; }
.good { background: #dcfce7; color: #166534; } .warn { background: #fef3c7; color: #92400e; } .bad { background: #fee2e2; color: #991b1b; } .unknown { background: #e5e7eb; color: #374151; }
.link-button { display: inline-block; margin-top: 10px; padding: 10px 14px; border-radius: 9px; background: #1d4ed8; color: #fff; text-decoration: none; font-weight: 600; }
.xml-section { border: 1px solid #e2e8f0; border-radius: 10px; margin: 10px 0; overflow: hidden; }
.xml-section > summary { cursor: pointer; list-style: none; padding: 13px 15px; background: #f7f9fc; font-weight: 650; overflow-wrap: anywhere; }
.xml-section > summary::-webkit-details-marker { display: none; } .xml-section > summary::before { content: "＋"; display: inline-block; width: 24px; color: #2563eb; }
.xml-section[open] > summary::before { content: "－"; } .xml-section[open] > summary { border-bottom: 1px solid #e2e8f0; }
.xml-section .table-wrap { padding: 0 12px 12px; } .data-table { min-width: 560px; } .data-table td.path { width: 42%; font-family: Consolas, "Courier New", monospace; color: #475569; font-size: 12px; }
details.raw { border: 1px solid #e2e8f0; border-radius: 10px; overflow: hidden; } details.raw summary { cursor: pointer; padding: 14px; background: #f7f9fc; font-weight: 650; }
pre { margin: 0; padding: 16px; max-height: 680px; overflow: auto; font: 12px/1.5 Consolas, "Courier New", monospace; white-space: pre; background: #0f172a; color: #e2e8f0; }
.note { line-height: 1.75; color: #536176; font-size: 13px; } .footer { color: #6b7280; font-size: 12px; text-align: center; padding: 8px; overflow-wrap: anywhere; }
@media (prefers-color-scheme: dark) {
 body { background: #101827; color: #e5eaf2; } header, section { background: #1c2737; }
 .kpi { background: #202e41; border-color: #344256; } .kpi .label, .muted, .note, .footer { color: #bdc9da; }
 th, .xml-section > summary, details.raw summary { background: #263449; color: #dbe5f2; } th, td, .xml-section, details.raw, .xml-section[open] > summary { border-color: #3a4658; }
 .data-table td.path { color: #bdc9da; }
}
</style>
</head>
<body><main>
<header>
<h1>Windows 电池健康度与完整数据报告</h1>
<div class="muted">生成时间：$safeGeneratedAt · 数据来源：Windows 内置 powercfg</div>
<p class="lead">$safeBatterySummary</p>
<div class="grid">
<div class="kpi"><div class="label">识别到的有效电池条目</div><div class="value">$($batteries.Count)</div></div>
<div class="kpi"><div class="label">XML 元素数</div><div class="value">$totalElementCount</div></div>
<div class="kpi"><div class="label">字段值和属性总数</div><div class="value">$totalFieldCount</div></div>
<div class="kpi"><div class="label">原始 XML 大小</div><div class="value">$xmlSizeKb KB</div></div>
</div>
$nativeHtmlLink
</header>
<section>
<h2>一、电池健康度概览</h2>
<p class="note">健康度 = 当前满充容量 ÷ 设计容量 × 100%。容量损耗估算 = 100% − 健康度。该比例是根据 Windows 报告容量计算的估算值，并非专业检测仪测量结果。健康度超过 100% 也可能出现，不一定代表故障。</p>
<div class="table-wrap"><table>
<thead><tr><th>电池 ID</th><th>设计容量</th><th>当前满充容量</th><th>健康度估算</th><th>容量损耗估算</th><th>循环次数</th><th>状态评估</th></tr></thead>
<tbody>
$($batteryRows -join [Environment]::NewLine)
</tbody></table></div>
</section>
<section>
<h2>二、XML 全部字段（可展开查询）</h2>
<p class="note">按原始 XML 的一级节点分组，逐项列出全部叶子节点值和 XML 属性，包括不参与健康度计算的历史记录及 Windows 版本新增字段。可用浏览器 Ctrl+F 搜索。字段与数值均来自本机报告；不存在的数据不会猜测补齐。</p>
$sectionHtmlText
</section>
<section>
<h2>三、原始 XML 全文</h2>
<p class="note">原始 XML 作为纯文本安全展示，便于核对和排查问题。</p>
<details class="raw"><summary>展开原始 XML</summary><pre>$rawXmlSafe</pre></details>
</section>
<section>
<h2>四、文件与兼容性说明</h2>
<p class="note"><strong>原始 XML：</strong> $safeXmlPath</p>
<p class="note"><strong>Windows 原生完整报告：</strong>桌面上的 BatteryReport-Windows.html（状态：$nativeStatusText），包含 Windows 报告支持的近期使用、使用历史、容量历史和电池寿命估算等章节。</p>
<p class="note"><strong>循环次数：</strong>取决于设备固件和 Windows 报告，不保证所有型号均提供。</p>
<p class="note"><strong>多电池：</strong>展示所有可识别的有效电池条目；即使有条目缺少关键容量，原始 XML 全部字段区仍会将可用数据列出。</p>
<p class="note"><strong>兼容性：</strong>使用 Windows 自带 PowerShell 和 powercfg，不调用 WMI、不安装第三方模块。不同 Windows 版本及设备固件提供的字段可能不同。</p>
</section>
<div class="footer">BatteryHealth · 本地生成的离线报告 · 未上传任何电池数据</div>
</main></body></html>
"@

    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

    Write-Host ''
    Write-Host ("XML report saved at: {0}" -f $xmlPath) -ForegroundColor Green
    if ($nativeHtmlAvailable) {
        Write-Host ("Windows full report saved at: {0}" -f $nativeHtmlPath) -ForegroundColor Green
    }
    Write-Host ("Detailed HTML report saved at: {0}" -f $htmlPath) -ForegroundColor Green
    Write-Host 'Opening the detailed HTML report in your default browser...' -ForegroundColor Cyan
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
