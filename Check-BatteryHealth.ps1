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

    function Get-FriendlyXmlLabel {
        param([string]$Name)

        $labels = @{
            BatteryReport = '报告基本信息'
            Batteries = '电池列表'
            Battery = '电池信息'
            DesignCapacity = '新电池标称容量'
            FullChargeCapacity = '当前充满时的容量'
            CycleCount = '累计充放电循环次数'
            Manufacturer = '制造商'
            ManufactureName = '电池制造商'
            ManufactureDate = '生产日期'
            Model = '设备型号'
            ModelNumber = '电池型号'
            SerialNumber = '序列号'
            Chemistry = '电池类型'
            DesignVoltage = '设计电压'
            Voltage = '电池电压'
            Capacity = '容量'
            RemainingCapacity = '剩余容量'
            StartTime = '开始时间'
            EndTime = '结束时间'
            Duration = '持续时间'
            Active = '活动状态'
            ConnectedStandby = '连接待机'
            Sleep = '睡眠'
            Hibernate = '休眠'
            AC = '连接电源适配器'
            OnBattery = '使用电池供电'
            RecentUsage = '最近使用情况'
            UsageHistory = '使用历史'
            BatteryUsage = '电池耗电记录'
            CapacityHistory = '电池容量变化历史'
            BatteryLifeEstimates = '续航时间估算'
            FullLifeTime = '满电预计续航时间'
            EstimatedRunTime = '预计剩余使用时间'
            ReportTime = '报告生成时间'
            SystemInfo = '系统信息'
            ComputerName = '电脑名称'
            OSVersion = 'Windows 版本'
            PowerSource = '供电来源'
            PowerState = '电源状态'
            Level = '电量水平'
            State = '状态'
            Count = '数量'
            Value = '记录值'
            Timestamp = '记录时间'
            Event = '事件'
            History = '历史记录'
            Device = '设备信息'
            Computer = '电脑信息'
        }

        if ($labels.ContainsKey($Name)) { return $labels[$Name] }

        # If Windows adds a field unknown to this script, keep its name visible but make CamelCase easier to read.
        return ([regex]::Replace($Name, '(?<=[a-z0-9])(?=[A-Z])', ' '))
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

    # Build plain-language cards for everyday users. Technical XML remains available below.
    $batteryCards = foreach ($battery in $batteries) {
        $safeId = ConvertTo-HtmlSafe $battery.Id
        $cycleText = if ($null -ne $battery.CycleCount) { '{0:N0} 次' -f $battery.CycleCount } else { '设备未提供' }
        if ($null -ne $battery.CycleCount) {
            $cycleHelp = '这是电池累计完成的充放电循环估算，不是插上充电器的次数。'
        } else {
            $cycleHelp = '部分电脑不提供这项数据；不影响健康度计算。'
        }

        if ($battery.DesignCapacity -le 0 -or $battery.FullChargeCapacity -le 0) {
            $healthText = '暂不可计算'
            $wearText = '暂无数据'
            $wearLabel = '容量损耗'
            $statusText = '系统没有提供有效容量'
            $statusClass = 'unknown'
            $headline = '暂时无法判断电池健康程度'
            $plainExplanation = '系统报告中缺少可用于计算的容量数值。可以先查看下方详细信息，或重新生成一次报告。'
            $barWidth = 0
        } else {
            $healthValue = [math]::Round(100.0 * $battery.FullChargeCapacity / $battery.DesignCapacity, 1)
            $wearValue = [math]::Round(100.0 - $healthValue, 1)
            $healthText = '{0:N1}%' -f $healthValue
            $barWidth = [math]::Min(100, [math]::Max(0, $healthValue))

            if ($healthValue -gt 100) {
                $wearLabel = '与标称容量的差异'
                $wearText = '高于标称 {0:N1}%' -f [math]::Abs($wearValue)
                $statusText = '容量读数高于标称值'
                $statusClass = 'good'
                $headline = '当前读数高于电池出厂标称容量'
                $plainExplanation = '这可能与电池容量估算或校准有关，不代表电池容量真的无限增加。可正常使用，并观察后续变化。'
            } elseif ($healthValue -ge 90) {
                $wearLabel = '大约损耗了'
                $wearText = '{0:N1}%' -f $wearValue
                $statusText = '状态不错'
                $statusClass = 'good'
                $headline = '电池状态看起来不错'
                $plainExplanation = '现在充满时能储存的电量，仍接近新电池的标称容量。照常使用即可。'
            } elseif ($healthValue -ge 80) {
                $wearLabel = '大约损耗了'
                $wearText = '{0:N1}%' -f $wearValue
                $statusText = '总体尚可'
                $statusClass = 'good'
                $headline = '电池有一些自然损耗'
                $plainExplanation = '现在能储存的电量比刚买时少了一些。通常不必只凭这个数字就更换；如果续航明显缩短，再进一步检查。'
            } elseif ($healthValue -ge 50) {
                $wearLabel = '大约损耗了'
                $wearText = '{0:N1}%' -f $wearValue
                $statusText = '容量下降较明显'
                $statusClass = 'warn'
                $headline = '电池续航可能已经变短'
                $plainExplanation = '电池现在能储存的电量明显少于新电池。可以留意日常使用时间是否缩短；如果影响使用，再考虑检测或更换。'
            } else {
                $wearLabel = '大约损耗了'
                $wearText = '{0:N1}%' -f $wearValue
                $statusText = '容量衰减较多'
                $statusClass = 'bad'
                $headline = '电池可储存的电量已经明显减少'
                $plainExplanation = '当前满充容量不到新电池标称值的一半，续航可能明显缩短。如果已经影响使用，建议进一步检测电池。'
            }
        }

        $designWh = '{0:N1} Wh' -f ($battery.DesignCapacity / 1000.0)
        $fullWh = '{0:N1} Wh' -f ($battery.FullChargeCapacity / 1000.0)
        $designMwh = '{0:N0} mWh' -f $battery.DesignCapacity
        $fullMwh = '{0:N0} mWh' -f $battery.FullChargeCapacity
        $safeCycle = ConvertTo-HtmlSafe $cycleText
        $safeCycleHelp = ConvertTo-HtmlSafe $cycleHelp
        $safeHeadline = ConvertTo-HtmlSafe $headline
        $safePlainExplanation = ConvertTo-HtmlSafe $plainExplanation
        $safeStatusText = ConvertTo-HtmlSafe $statusText
        $safeWearLabel = ConvertTo-HtmlSafe $wearLabel
        $safeDesignWh = ConvertTo-HtmlSafe $designWh
        $safeFullWh = ConvertTo-HtmlSafe $fullWh
        $safeDesignMwh = ConvertTo-HtmlSafe $designMwh
        $safeFullMwh = ConvertTo-HtmlSafe $fullMwh

        $cardHtml = @"
<article class="battery-card">
  <div class="battery-card-head">
    <div><div class="eyebrow">检测到的电池</div><h2>$safeId</h2></div>
    <span class="status $statusClass">$safeStatusText</span>
  </div>
  <div class="health-hero">
    <div class="health-number">$healthText</div>
    <div class="health-copy"><h3>$safeHeadline</h3><p>$safePlainExplanation</p></div>
  </div>
  <div class="health-track" role="img" aria-label="按设计容量比例显示当前满充容量"><div class="health-fill $statusClass" style="width:${barWidth}%"></div></div>
  <div class="track-caption"><span>新电池标称容量：100%</span><span>当前满充容量：$healthText</span></div>
  <div class="detail-grid">
    <div class="detail-card"><span class="detail-label">新电池时的标称容量</span><strong>$safeDesignWh</strong><small>设计容量 · $safeDesignMwh</small></div>
    <div class="detail-card"><span class="detail-label">现在充满大约能存多少</span><strong>$safeFullWh</strong><small>当前满充容量 · $safeFullMwh</small></div>
    <div class="detail-card"><span class="detail-label">$safeWearLabel</span><strong>$wearText</strong><small>与新电池标称容量对比</small></div>
    <div class="detail-card"><span class="detail-label">充放电循环次数</span><strong>$safeCycle</strong><small>$safeCycleHelp</small></div>
  </div>
</article>
"@
        $cardHtml
    }

    $batteryCardsHtml = $batteryCards -join [Environment]::NewLine
    if (@($batteryCards).Count -eq 0) {
        $batteryCardsHtml = @"
<div class="empty-state">
  <div class="empty-icon">i</div>
  <h2>这次没有读到足够的电池容量数据</h2>
  <p>系统仍然生成了原始报告，但暂时无法准确计算健康度。请向下展开“进阶信息”，查看电脑实际提供了哪些数据。脚本不会猜一个健康度出来。</p>
</div>
"@
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
                $friendlyLabel = ConvertTo-HtmlSafe (Get-FriendlyXmlLabel -Name $element.LocalName)
                $fieldRows.Add(('<tr><td><strong>{0}</strong><small class="raw-path">{1}</small></td><td>{2}</td></tr>' -f $friendlyLabel, $path, (ConvertTo-HtmlSafe $value)))
                $localLeafCount++
            }
            if ($null -ne $element.Attributes) {
                foreach ($attribute in $element.Attributes) {
                    $path = ConvertTo-HtmlSafe ((Get-XmlNodePath -Node $element -Section $sectionNode) + '/@' + $attribute.LocalName)
                    $friendlyLabel = ConvertTo-HtmlSafe ('属性：' + (Get-FriendlyXmlLabel -Name $attribute.LocalName))
                    $fieldRows.Add(('<tr><td><strong>{0}</strong><small class="raw-path">{1}</small></td><td>{2}</td></tr>' -f $friendlyLabel, $path, (ConvertTo-HtmlSafe $attribute.Value)))
                    $localAttributeCount++
                }
            }
        }

        $totalFieldCount += $fieldRows.Count
        $safeSectionName = ConvertTo-HtmlSafe (Get-FriendlyXmlLabel -Name $sectionNode.LocalName)
        $rawSectionName = ConvertTo-HtmlSafe $sectionNode.LocalName
        $sectionTitle = '{0}（系统字段：{1}；共 {2} 项信息）' -f $safeSectionName, $rawSectionName, $fieldRows.Count
        $safeSectionTitle = ConvertTo-HtmlSafe $sectionTitle
        $tableRows = $fieldRows -join [Environment]::NewLine
        $sectionDetailHtml = @"
<details class="xml-section">
<summary>$safeSectionTitle</summary>
<div class="table-wrap"><table class="data-table"><thead><tr><th>信息名称（已尽量翻译）<br><small>括号内为系统原字段名</small></th><th>系统记录的内容</th></tr></thead><tbody>
$tableRows
</tbody></table></div>
</details>
"@
        $sectionHtml.Add($sectionDetailHtml)
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
<title>电池健康体检报告</title>
<style>
:root { color-scheme: light dark; --ink:#15243b; --muted:#67768d; --line:#e6ebf2; --paper:#f3f6fb; --blue:#2864e8; }
* { box-sizing:border-box; }
body { margin:0; padding:28px 16px 48px; font-family:"Segoe UI","Microsoft YaHei",sans-serif; background:var(--paper); color:var(--ink); line-height:1.6; }
main { max-width:960px; margin:0 auto; }
.top { padding:8px 2px 22px; }
.brand { color:var(--blue); font-size:12px; font-weight:800; letter-spacing:1.8px; text-transform:uppercase; }
h1 { margin:6px 0 5px; font-size:clamp(28px,5vw,38px); line-height:1.2; letter-spacing:-.7px; }
.subtitle { color:var(--muted); font-size:15px; }
.timestamp { color:var(--muted); font-size:12px; margin-top:12px; }
.battery-card, .panel { background:#fff; border:1px solid #e9eef5; border-radius:20px; padding:24px; margin-bottom:18px; box-shadow:0 8px 28px rgba(28,49,83,.055); }
.battery-card-head { display:flex; gap:12px; align-items:center; justify-content:space-between; flex-wrap:wrap; margin-bottom:12px; }
.eyebrow { color:var(--muted); font-size:12px; font-weight:700; letter-spacing:.4px; }
.battery-card-head h2 { font-size:18px; margin:2px 0 0; }
.status { display:inline-flex; align-items:center; padding:6px 11px; border-radius:999px; font-size:12px; font-weight:800; white-space:nowrap; }
.good { color:#146c43; background:#e1f7ea; } .warn { color:#875400; background:#fff2cf; } .bad { color:#a52a2a; background:#ffe5e5; } .unknown { color:#475569; background:#edf0f4; }
.health-hero { display:grid; grid-template-columns:auto 1fr; align-items:center; gap:22px; padding:6px 0 10px; }
.health-number { color:var(--blue); font-size:clamp(52px,10vw,76px); font-weight:800; line-height:1; letter-spacing:-2px; font-variant-numeric:tabular-nums; }
.health-copy h3 { margin:0 0 5px; font-size:20px; line-height:1.35; }
.health-copy p { margin:0; color:#586982; font-size:14px; }
.health-track { background:#e9eef5; height:12px; border-radius:99px; overflow:hidden; margin-top:15px; }
.health-fill { height:100%; border-radius:99px; background:#17a66a; min-width:0; } .health-fill.good { background:#17a66a; }
.health-fill.warn { background:#e6a327; } .health-fill.bad { background:#dc5555; } .health-fill.unknown { background:#aab3c0; }
.track-caption { display:flex; justify-content:space-between; gap:12px; flex-wrap:wrap; color:#7a8799; font-size:11px; margin-top:7px; }
.detail-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px; margin-top:23px; }
.detail-card { border:1px solid var(--line); background:#fbfcfe; border-radius:14px; padding:16px; min-width:0; }
.detail-label { display:block; color:var(--muted); font-size:12px; margin-bottom:5px; }
.detail-card strong { display:block; font-size:22px; font-weight:750; letter-spacing:-.3px; overflow-wrap:anywhere; }
.detail-card small { display:block; margin-top:5px; color:#7b8799; font-size:11px; overflow-wrap:anywhere; }
.section-title { margin:0 0 6px; font-size:20px; }
.section-intro { color:var(--muted); font-size:13px; margin:0 0 16px; }
.plain-list { display:grid; gap:12px; }
.plain-item { display:grid; grid-template-columns:30px 1fr; gap:10px; align-items:start; }
.number { width:28px; height:28px; border-radius:9px; display:grid; place-items:center; background:#eaf0ff; color:#2457c5; font-weight:800; font-size:12px; }
.plain-item strong { display:block; font-size:14px; margin:1px 0 3px; }
.plain-item p { margin:0; color:#62718a; font-size:13px; }
.tip { background:#f1f6ff; border:1px solid #dfebff; padding:14px 15px; border-radius:12px; color:#445c7a; font-size:12px; line-height:1.7; margin-top:17px; }
.link-row { display:flex; flex-wrap:wrap; align-items:center; gap:10px; margin-top:17px; }
.link-button { display:inline-flex; align-items:center; gap:8px; background:#205ad8; color:#fff; text-decoration:none; padding:11px 15px; border-radius:10px; font-weight:700; font-size:13px; }
.link-button:hover { background:#1749b7; }
.link-help { color:var(--muted); font-size:12px; }
.advanced { padding:0; overflow:hidden; }
.advanced > summary { cursor:pointer; list-style:none; padding:18px 22px; font-size:14px; font-weight:800; display:flex; align-items:center; justify-content:space-between; gap:10px; }
.advanced > summary::-webkit-details-marker { display:none; }
.advanced > summary:after { content:"＋"; color:var(--blue); font-size:20px; }
.advanced[open] > summary:after { content:"－"; }
.advanced-content { padding:0 22px 22px; border-top:1px solid var(--line); }
.xml-section { border:1px solid #e5eaf1; border-radius:10px; margin:10px 0; overflow:hidden; }
.xml-section > summary { cursor:pointer; list-style:none; padding:12px 13px; background:#f7f9fc; font-weight:650; font-size:12px; overflow-wrap:anywhere; }
.xml-section > summary::-webkit-details-marker { display:none; }
.xml-section > summary:before { content:"＋"; display:inline-block; width:22px; color:var(--blue); }
.xml-section[open] > summary:before { content:"－"; }
.xml-section .table-wrap { padding:0 10px 10px; overflow-x:auto; }
.data-table { width:100%; border-collapse:collapse; min-width:460px; }
.data-table th,.data-table td { text-align:left; padding:9px; border-bottom:1px solid var(--line); vertical-align:top; font-size:12px; overflow-wrap:anywhere; }
.data-table th { color:var(--muted); background:#fff; }
.data-table td.path { width:43%; color:#52627a; font:11px Consolas,"Courier New",monospace; } .raw-path { display:block; margin-top:3px; color:#929db0; font:10px Consolas,"Courier New",monospace; overflow-wrap:anywhere; }
details.raw { border:1px solid #e5eaf1; border-radius:10px; overflow:hidden; margin-top:14px; }
details.raw summary { cursor:pointer; padding:12px 13px; background:#f7f9fc; font-size:12px; font-weight:700; }
pre { margin:0; padding:14px; max-height:520px; overflow:auto; font:11px/1.5 Consolas,"Courier New",monospace; white-space:pre; background:#111b2d; color:#e1e9f5; }
.empty-state { background:#fff8e8; border:1px solid #f1dca7; border-radius:16px; padding:24px; margin-bottom:18px; }
.empty-icon { display:grid; place-items:center; width:32px; height:32px; border-radius:50%; background:#ffedbf; color:#805500; font-weight:900; }
.empty-state h2 { margin:10px 0 5px; font-size:19px; } .empty-state p { margin:0; color:#725b2e; font-size:13px; }
.footer { text-align:center; color:#8995a6; font-size:11px; padding:6px; }
@media (max-width:580px) {
 body { padding:17px 10px 32px; } .battery-card,.panel { padding:17px; border-radius:16px; }
 .health-hero { grid-template-columns:1fr; gap:10px; } .health-number { font-size:64px; }
 .detail-grid { grid-template-columns:1fr 1fr; gap:8px; } .detail-card { padding:12px; } .detail-card strong { font-size:18px; }
 .section-title { font-size:18px; } .advanced > summary { padding:16px; } .advanced-content { padding:0 12px 15px; }
}
@media (prefers-color-scheme: dark) {
 :root { color-scheme:dark; --ink:#e7edf6; --muted:#b3bfd0; --line:#354257; --paper:#101827; --blue:#80aaff; }
 body { background:var(--paper); color:var(--ink); } .battery-card,.panel { background:#1b2738; border-color:#29364a; }
 .health-copy p,.plain-item p,.link-help { color:#b8c5d8; } .detail-card { background:#202d40; border-color:#354257; }
 .detail-card small,.track-caption { color:#a9b8cb; } .health-track { background:#344258; }
 .tip { background:#1d2e48; border-color:#2e466b; color:#c4d8fb; }
 .advanced-content { border-color:#354257; } .xml-section,.details.raw { border-color:#354257; }
 .xml-section > summary,details.raw summary { background:#243248; } .data-table th { background:#1b2738; }
 .data-table td.path { color:#c0ccdc; } .raw-path { color:#9aabc2; } .data-table th,.data-table td { border-color:#354257; }
 .empty-state { background:#3a301b; border-color:#645027; } .empty-icon { background:#57451e; color:#ffdfa0; }
 .empty-state p { color:#e1ce9e; }
}
</style>
</head>
<body>
<main>
<header class="top">
  <div class="brand">BATTERY HEALTH · 本机报告</div>
  <h1>电池健康体检报告</h1>
  <div class="subtitle">先看健康度，其他信息都用简单的话说明。</div>
  <div class="timestamp">报告生成时间：$generatedAt</div>
</header>

$batteryCardsHtml

<section class="panel">
  <h2 class="section-title">这几个数字怎么看？</h2>
  <p class="section-intro">不用了解技术术语，记住下面几点就够了。</p>
  <div class="plain-list">
    <div class="plain-item"><div class="number">1</div><div><strong>健康度：现在的电池和新电池相比，还能存多少电</strong><p>例如 85%，表示根据系统报告估算，目前充满时能储存的电量约为新电池标称值的 85%。</p></div></div>
    <div class="plain-item"><div class="number">2</div><div><strong>容量损耗：相比新电池，大约少了多少储电能力</strong><p>健康度 85%，就大约损耗了 15%。这不等于当前电量，也不直接表示还剩多少使用时间。</p></div></div>
    <div class="plain-item"><div class="number">3</div><div><strong>循环次数：累计使用过多少个完整充放电循环</strong><p>不是每插一次充电器就算一次。部分电脑不提供循环次数，所以显示“设备未提供”很正常。</p></div></div>
  </div>
  <div class="tip"><strong>温馨提示：</strong>健康度是 Windows 根据电池报告容量计算出来的估算值。它不能单独判断电池是否故障；实际续航还会受屏幕亮度、运行的软件、温度和使用方式影响。若电池出现鼓包或机身被顶起，应停止使用并尽快联系维修人员。</div>
</section>

<section class="panel">
  <h2 class="section-title">想看 Windows 原版详细报告？</h2>
  <p class="section-intro">这里的中文页面适合日常查看；Windows 原版报告会包含更多历史记录和图表，信息也更技术化。</p>
  <div class="link-row">
    $nativeHtmlLink
    <span class="link-help">原版报告生成失败时，这个链接可能不可用。</span>
  </div>
</section>

<section class="panel advanced">
  <details class="advanced">
    <summary>进阶信息：查看系统提供的全部字段（一般不用看）</summary>
    <div class="advanced-content">
      <p class="section-intro">以下内容主要用于排查问题。常见字段已经尽量翻译成中文；括号下方保留系统原字段名，方便搜索。不同 Windows 版本和设备可能提供不同内容。</p>
      $sectionHtmlText
      <details class="raw"><summary>展开原始 XML 全文（技术内容）</summary><pre>$rawXmlSafe</pre></details>
      <p class="section-intro">原始 XML 文件位置：$safeXmlPath</p>
    </div>
  </details>
</section>

<div class="footer">本地生成 · 电池数据不会由此脚本上传到网络</div>
</main>
</body>
</html>
"@

    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

    Write-Host ''
    Write-Host ("XML report saved at: {0}" -f $xmlPath) -ForegroundColor Green
    if ($nativeHtmlAvailable) {
        Write-Host ("Windows full report saved at: {0}" -f $nativeHtmlPath) -ForegroundColor Green
    }
    Write-Host ("Friendly HTML report saved at: {0}" -f $htmlPath) -ForegroundColor Green
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
