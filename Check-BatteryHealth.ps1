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
            $id = '电池 ' + ($items.Count + 1)
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
$nativeHtmlPath = Join-Path $env:TEMP ("BatteryReport-source-{0}.html" -f $PID)
$htmlPath = Join-Path $desktop 'BatteryHealth.html'
$powercfg = Join-Path $env:WINDIR 'System32\powercfg.exe'

try {
    Write-Host ''
    Write-Host 'Windows 电池健康检查' -ForegroundColor Cyan
    Write-Host '使用 Windows 自带的电池报告，并在原报告上翻译常见字段。' -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-Path -LiteralPath $powercfg)) {
        throw '找不到 Windows 自带的 powercfg.exe。'
    }

    # Remove an older report first, so an unsuccessful command cannot leave
    # a stale report that looks like a fresh result.
    if (Test-Path -LiteralPath $xmlPath) {
        Remove-Item -LiteralPath $xmlPath -Force
    }

    Write-Host '正在生成原始 XML 数据...' -ForegroundColor Yellow
    & $powercfg /batteryreport /xml /output $xmlPath

    if ($LASTEXITCODE -ne 0) {
        throw "生成 XML 报告失败，powercfg 退出代码：$LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        throw '没有生成 XML 报告；此设备或 Windows 版本可能不支持该报告。'
    }
    if ((Get-Item -LiteralPath $xmlPath).Length -eq 0) {
        throw '生成的 XML 报告为空。'
    }

    [xml]$document = New-Object System.Xml.XmlDocument
    $document.Load($xmlPath)

    # Generate Windows' original HTML to a temporary file; it will be translated and merged below.
    if (Test-Path -LiteralPath $nativeHtmlPath) {
        Remove-Item -LiteralPath $nativeHtmlPath -Force
    }
    Write-Host '正在生成 Windows 原版完整 HTML 报告...' -ForegroundColor Yellow
    & $powercfg /batteryreport /output $nativeHtmlPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg 生成 HTML 报告失败，退出代码：$LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $nativeHtmlPath) -or (Get-Item -LiteralPath $nativeHtmlPath).Length -eq 0) {
        throw 'Windows 没有生成有效的 HTML 电池报告。'
    }

    $batteries = @(Get-BatteryEntries $document)

    if ($batteries.Count -eq 0) {
        Write-Host 'XML 报告中没有找到可用于计算健康度的容量数据。' -ForegroundColor Yellow
        Write-Host '仍会显示 Windows 原版报告，但健康度将标记为暂不可计算。' -ForegroundColor Yellow
        Write-Host ("原始 XML：{0}" -f $xmlPath)
    }

    Write-Section '电池健康度结果'
    Write-Host ("识别到的电池条目：{0}" -f $batteries.Count)

    $index = 0
    foreach ($battery in $batteries) {
        $index++
        Write-Host ''
        Write-Host ("电池 {0}：{1}" -f $index, $battery.Id) -ForegroundColor Cyan

        Write-Host ("  新电池标称容量：{0:N0} mWh" -f $battery.DesignCapacity)
        Write-Host ("  当前满充容量：{0:N0} mWh" -f $battery.FullChargeCapacity)

        if ($battery.DesignCapacity -le 0 -or $battery.FullChargeCapacity -le 0) {
            Write-Host '  健康度：暂不可计算（容量为零）' -ForegroundColor Red
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

        Write-Host ("  电池健康度：{0:N1}%" -f $health) -ForegroundColor $color
        Write-Host ("  估算容量损耗：{0:N1}%" -f $wear) -ForegroundColor $color
        Write-Host ("  状态判断：{0}" -f $status) -ForegroundColor $color

        if ($null -ne $battery.CycleCount) {
            Write-Host ("  充放电循环次数：{0}" -f $battery.CycleCount)
        }
        else {
            Write-Host '  充放电循环次数：设备未提供' -ForegroundColor DarkGray
        }
    }

    # HTML-encode values before placing battery identifiers and labels into the report.
    function ConvertTo-HtmlSafe {
        param([AllowNull()][object]$Value)
        if ($null -eq $Value) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    # Build plain-language health cards; native Windows report details remain below.
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
  <p>系统仍然生成了原始报告，但暂时无法准确计算健康度。请继续向下查看 Windows 原版报告。脚本不会猜一个健康度出来。</p>
</div>
"@
    }

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Translate the native Windows battery report in place, then insert the health summary
    # at the top. We only translate visible text between tags; charts, tables, history and CSS remain.
    $reportHtml = [System.IO.File]::ReadAllText($nativeHtmlPath)

    $translations = @(
        @{ English = 'Battery report'; Chinese = '电池报告' },
        @{ English = 'Installed batteries'; Chinese = '已安装的电池' },
        @{ English = 'Installed battery'; Chinese = '已安装的电池' },
        @{ English = 'Recent usage'; Chinese = '近期使用情况' },
        @{ English = 'Battery usage history'; Chinese = '电池使用历史' },
        @{ English = 'Usage history'; Chinese = '使用历史' },
        @{ English = 'Battery capacity history'; Chinese = '电池容量变化历史' },
        @{ English = 'Battery life estimates'; Chinese = '电池续航时间估算' },
        @{ English = 'Battery life estimate'; Chinese = '电池续航时间估算' },
        @{ English = 'NAME'; Chinese = '电池名称' },
        @{ English = 'MANUFACTURER'; Chinese = '制造商' },
        @{ English = 'SERIAL NUMBER'; Chinese = '序列号' },
        @{ English = 'CHEMISTRY'; Chinese = '电池类型' },
        @{ English = 'DESIGN CAPACITY'; Chinese = '新电池标称容量' },
        @{ English = 'FULL CHARGE CAPACITY'; Chinese = '当前满充容量' },
        @{ English = 'CYCLE COUNT'; Chinese = '充放电循环次数' },
        @{ English = 'Report time'; Chinese = '报告生成时间' },
        @{ English = 'Computer name'; Chinese = '电脑名称' },
        @{ English = 'BIOS'; Chinese = 'BIOS 版本' },
        @{ English = 'SYSTEM SKU'; Chinese = '系统产品编号' },
        @{ English = 'POWER SOURCE'; Chinese = '电源来源' },
        @{ English = 'Power source'; Chinese = '电源来源' },
        @{ English = 'AC usage'; Chinese = '接通电源使用时长' },
        @{ English = 'Battery usage'; Chinese = '电池耗电情况' },
        @{ English = 'Current estimate'; Chinese = '当前估算' },
        @{ English = 'Estimated runtime'; Chinese = '预计续航时间' },
        @{ English = 'Charge level'; Chinese = '电量水平' },
        @{ English = 'Percentage remaining'; Chinese = '剩余电量百分比' },
        @{ English = 'System product name'; Chinese = '电脑型号' },
        @{ English = 'OS build'; Chinese = 'Windows 版本号' },
        @{ English = 'Platform role'; Chinese = '设备类型' },
        @{ English = 'Connected standby'; Chinese = '连接待机' },
        @{ English = 'Start time'; Chinese = '开始时间' },
        @{ English = 'End time'; Chinese = '结束时间' },
        @{ English = 'State'; Chinese = '状态' },
        @{ English = 'Source'; Chinese = '供电来源' },
        @{ English = 'Capacity remaining'; Chinese = '剩余电量' },
        @{ English = 'Energy drained'; Chinese = '消耗电量' },
        @{ English = 'Period'; Chinese = '时间段' },
        @{ English = 'Duration'; Chinese = '持续时间' },
        @{ English = 'Active'; Chinese = '正在使用' },
        @{ English = 'Suspended'; Chinese = '已挂起' },
        @{ English = 'Hibernation'; Chinese = '休眠' },
        @{ English = 'Sleep'; Chinese = '睡眠' },
        @{ English = 'Screen on'; Chinese = '屏幕开启' },
        @{ English = 'Screen off'; Chinese = '屏幕关闭' },
        @{ English = 'AC time'; Chinese = '接通电源时间' },
        @{ English = 'Battery time'; Chinese = '电池供电时间' },
        @{ English = 'At full charge'; Chinese = '按当前满充容量估算' },
        @{ English = 'At design capacity'; Chinese = '按新电池标称容量估算' },
        @{ English = 'Since OS install'; Chinese = '从安装 Windows 起累计' },
        @{ English = 'Estimated battery life'; Chinese = '预计电池续航时间' },
        @{ English = 'Full charge'; Chinese = '充满电' },
        @{ English = 'Design capacity'; Chinese = '新电池标称容量' },
        @{ English = 'Full charge capacity'; Chinese = '当前满充容量' },
        @{ English = 'Cycle count'; Chinese = '充放电循环次数' }
    )

    foreach ($translation in $translations) {
        # Match a complete visible text node; avoid changing CSS classes, attributes or scripts.
        $pattern = '(?i)(>)(\s*)' + [regex]::Escape($translation.English) + '(\s*)(<)'
        $replacement = '$1$2' + $translation.Chinese + '$3$4'
        $reportHtml = [regex]::Replace($reportHtml, $pattern, $replacement)
    }

    $summaryHtml = @"
<section id="batteryhealth-summary" lang="zh-CN">
  <div class="bh-intro">
    <div class="bh-brand">BATTERY HEALTH · 本机报告</div>
    <h1>电池健康度报告</h1>
    <p>先看健康度摘要；继续向下就是 Windows 原版电池报告，历史表格和图表都保留了，常见标题与字段已翻译。</p>
    <small>生成时间：$generatedAt</small>
  </div>
  $batteryCardsHtml
  <div class="bh-note"><strong>简单说明：</strong>健康度表示当前满充容量相对于新电池标称容量的比例；容量损耗表示与新电池相比少了多少储电能力。循环次数不是每插一次充电器就算一次。实际续航还受屏幕亮度、软件、温度和使用方式影响。</div>
  <div class="bh-native-title"><strong>Windows 完整电池报告（已翻译常见标题）</strong><p>下面的近期使用情况、耗电记录、容量历史和续航估算来自 Windows 原报告；历史是否完整取决于系统已记录的数据。</p></div>
</section>
"@

    $summaryCss = @"
<style id="batteryhealth-summary-style">
#batteryhealth-summary { font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif; color:#182235; width:100%; max-width:none; margin:0; padding:30px 20px 32px; line-height:1.6; background:#f4f7fb !important; border-bottom:1px solid #dce4ef; }
#batteryhealth-summary * { box-sizing:border-box; }
#batteryhealth-summary .bh-intro { padding:4px 2px 18px; }
#batteryhealth-summary .bh-brand { color:#2864e8; font-size:11px; font-weight:800; letter-spacing:1.5px; }
#batteryhealth-summary h1 { margin:6px 0; font-size:30px; line-height:1.25; }
#batteryhealth-summary .bh-intro p,#batteryhealth-summary .bh-native-title p { color:#65748a; font-size:13px; margin:6px 0; }
#batteryhealth-summary small { color:#748198; font-size:11px; }
#batteryhealth-summary .battery-card { background:#fff; border:1px solid #e5ebf3; border-radius:17px; padding:20px; margin:0 0 14px; box-shadow:0 5px 22px rgba(26,50,85,.05); }
#batteryhealth-summary .battery-card-head { display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; }
#batteryhealth-summary .eyebrow { font-size:11px; color:#748198; }
#batteryhealth-summary .battery-card-head h2 { margin:0; font-size:17px; }
#batteryhealth-summary .status { display:inline-flex; border-radius:99px; padding:5px 10px; font-size:11px; font-weight:800; }
#batteryhealth-summary .good { color:#17653e; background:#e2f7e9; }
#batteryhealth-summary .warn { color:#895800; background:#fff2d2; }
#batteryhealth-summary .bad { color:#a42b2b; background:#ffe5e5; }
#batteryhealth-summary .unknown { color:#4b5563; background:#eef1f5; }
#batteryhealth-summary .health-hero { display:grid; grid-template-columns:auto 1fr; align-items:center; gap:20px; margin:14px 0; }
#batteryhealth-summary .health-number { color:#2864e8; font-size:clamp(48px,7vw,68px); font-weight:800; line-height:1; letter-spacing:-2px; }
#batteryhealth-summary .health-copy h3 { margin:0 0 5px; font-size:17px; }
#batteryhealth-summary .health-copy p { margin:0; font-size:13px; color:#52627a; }
#batteryhealth-summary .health-track { height:10px; background:#e8edf5; border-radius:99px; overflow:hidden; margin-top:12px; }
#batteryhealth-summary .health-fill { display:block; height:100%; border-radius:99px; background:#19a565; }
#batteryhealth-summary .health-fill.warn { background:#e6a22c; }
#batteryhealth-summary .health-fill.bad { background:#d95151; }
#batteryhealth-summary .health-fill.unknown { background:#aab4c2; }
#batteryhealth-summary .track-caption { display:flex; justify-content:space-between; gap:12px; flex-wrap:wrap; color:#7a8799; font-size:11px; margin-top:7px; }
#batteryhealth-summary .detail-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:9px; margin-top:17px; }
#batteryhealth-summary .detail-card { background:#f8fafd; border:1px solid #e9eef5; border-radius:11px; padding:12px; min-width:0; }
#batteryhealth-summary .detail-label { display:block; font-size:11px; line-height:1.5; color:#748198; min-height:30px; }
#batteryhealth-summary .detail-card strong { display:block; font-size:19px; overflow-wrap:anywhere; }
#batteryhealth-summary .detail-card small { display:block; margin-top:4px; }
#batteryhealth-summary .bh-note { background:#eff5ff; border:1px solid #dfebff; border-radius:13px; color:#425b7d; padding:13px 15px; font-size:12px; line-height:1.7; margin:16px 0 26px; }
#batteryhealth-summary .bh-native-title { border-top:1px solid #e3e9f1; padding-top:20px; }
#batteryhealth-summary .bh-native-title strong { font-size:17px; }
@media(max-width:620px) {
 #batteryhealth-summary { padding:0 10px; margin-top:14px; }
 #batteryhealth-summary h1 { font-size:25px; }
 #batteryhealth-summary .battery-card { padding:15px; }
 #batteryhealth-summary .health-hero { grid-template-columns:1fr; gap:10px; }
 #batteryhealth-summary .health-number { font-size:58px; }
 #batteryhealth-summary .detail-grid { grid-template-columns:repeat(2,minmax(0,1fr)); }
 #batteryhealth-summary .detail-card strong { font-size:17px; }
}

/* ---- Force a clean white report, regardless of the Windows report's built-in dark theme ---- */
html { background:#ffffff !important; color-scheme:light !important; }
body {
  background:#ffffff !important; background-color:#ffffff !important; color:#263445 !important;
  font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important;
  letter-spacing:normal !important; margin:0 !important; padding:0 0 42px !important;
}
#batteryhealth-summary .bh-intro,
#batteryhealth-summary .battery-card,
#batteryhealth-summary .bh-note,
#batteryhealth-summary .bh-native-title {
  width:100%; max-width:1120px; margin-left:auto; margin-right:auto;
}
#batteryhealth-summary .bh-intro { padding-bottom:20px; }
#batteryhealth-summary .bh-card, #batteryhealth-summary .battery-card {
  background:#ffffff !important; color:#263445 !important; border:1px solid #dfe6ef !important;
}
#batteryhealth-summary .bh-note { background:#f0f6ff !important; color:#385478 !important; }
#batteryhealth-summary .bh-native-title { margin-top:24px; }

/* Main title */
body > h1 {
  max-width:1120px !important; margin:28px auto 14px !important; padding:0 22px !important;
  color:#173d78 !important; background:transparent !important; border:0 !important;
  font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important;
  font-size:28px !important; font-weight:700 !important; line-height:1.3 !important;
  letter-spacing:normal !important;
}

/* Clear, numbered-looking section bands */
body > h2 {
  max-width:1120px !important; margin:30px auto 10px !important; padding:12px 15px !important;
  color:#1d3b68 !important; background:#edf4ff !important;
  border:1px solid #d8e5f8 !important; border-left:5px solid #3978e8 !important;
  border-radius:8px !important; box-sizing:border-box !important;
  font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important;
  font-size:18px !important; font-weight:700 !important; line-height:1.4 !important;
  letter-spacing:normal !important;
}
body > .explanation, body > .explanation2 {
  max-width:1120px !important; margin:7px auto 12px !important; padding:0 22px !important;
  color:#68778d !important; background:transparent !important; font-size:13px !important;
  font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important; letter-spacing:normal !important;
}

/* Tables: white cells, soft-gray headings, alternating rows, consistent spacing */
body > table {
  width:calc(100% - 44px) !important; max-width:1120px !important; margin:12px auto 28px !important;
  table-layout:auto !important; border-collapse:separate !important; border-spacing:0 !important;
  border:1px solid #dce4ee !important; border-radius:10px !important; overflow:hidden !important;
  background:#ffffff !important; background-color:#ffffff !important; color:#2f3b4d !important;
  box-shadow:0 4px 15px rgba(30,50,80,.045) !important;
  font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important; letter-spacing:normal !important;
  font-size:13px !important;
}
body > table thead, body > table thead tr, body > table thead td {
  background:#edf2f9 !important; background-color:#edf2f9 !important; color:#344054 !important;
}
body > table td, body > table th {
  padding:10px 12px !important; color:#344054 !important; background:#ffffff !important;
  border:0 !important; border-bottom:1px solid #e6ebf2 !important;
  font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important;
  letter-spacing:normal !important; font-size:13px !important; vertical-align:top !important;
}
body > table thead td, body > table th {
  background:#edf2f9 !important; color:#334155 !important; font-weight:700 !important;
}
body > table tr.even td, body > table .even td { background:#f8fafc !important; }
body > table tr.odd td, body > table .odd td { background:#ffffff !important; }
body > table tr.dc.even td, body > table tr.dc.odd td,
body > table .dc.even td, body > table .dc.odd td {
  background:#fff0f0 !important; color:#8e343d !important;
}
body > table tr.even.suspend td, body > table tr.odd.suspend td,
body > table .even.suspend td, body > table .odd.suspend td {
  background:#f2f0ff !important; color:#4b4380 !important;
}
body > table .label, body > table td.label, body > table span.label {
  background:transparent !important; color:#65738a !important; font-weight:700 !important;
}
body > table .nobatts, body > table td.nobatts {
  background:#fff6e5 !important; color:#805b17 !important;
}
body > table td.colBreak { padding:0 !important; background:#ffffff !important; border:0 !important; }
body > table tr:last-child td { border-bottom:0 !important; }
body svg { background:transparent !important; }
body svg text { fill:#46566d !important; color:#46566d !important; font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif !important; }
body .explanation, body .explanation2 { color:#68778d !important; }
body hr { border:0 !important; border-top:1px solid #e1e7ef !important; }
body a { color:#245fc8 !important; }
@media(max-width:720px) {
  body > h1, body > h2, body > .explanation, body > .explanation2 { margin-left:14px !important; margin-right:14px !important; }
  body > table { width:calc(100% - 28px) !important; }
  body > h2 { font-size:16px !important; }
}
</style>
"@

    $htmlOpen = [regex]::Match($reportHtml, '(?i)<html\b[^>]*>')
    if ($htmlOpen.Success) {
        $reportHtml = $reportHtml.Substring(0, $htmlOpen.Index) + '<html lang="zh-CN">' + $reportHtml.Substring($htmlOpen.Index + $htmlOpen.Length)
    }

    $headClose = [regex]::Match($reportHtml, '(?i)</head>')
    if ($headClose.Success) {
        $reportHtml = $reportHtml.Substring(0, $headClose.Index) + $summaryCss + $reportHtml.Substring($headClose.Index)
    }

    $bodyOpen = [regex]::Match($reportHtml, '(?i)<body\b[^>]*>')
    if (-not $bodyOpen.Success) {
        throw 'Windows 生成的 HTML 结构与预期不符，无法添加中文摘要。'
    }
    $insertAt = $bodyOpen.Index + $bodyOpen.Length
    $reportHtml = $reportHtml.Substring(0, $insertAt) + $summaryHtml + $reportHtml.Substring($insertAt)
    $html = $reportHtml

    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

    if (Test-Path -LiteralPath $nativeHtmlPath) {
        Remove-Item -LiteralPath $nativeHtmlPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host ("原始 XML 数据：{0}" -f $xmlPath) -ForegroundColor Green
    Write-Host ("合并后的中文完整报告：{0}" -f $htmlPath) -ForegroundColor Green
    Write-Host '已把健康度摘要和翻译后的 Windows 原版电池报告合并到同一个 HTML 文件。' -ForegroundColor Cyan
    Write-Host '正在打开浏览器...' -ForegroundColor Cyan
    Start-Process -FilePath $htmlPath
    Write-Host '健康度 = 当前满充容量 ÷ 新电池标称容量 × 100%。'
    Write-Host '原始 XML 已保留；Windows 原始 HTML 的历史内容和图表已合并到中文报告。'
}
catch {
    if (Test-Path -LiteralPath $nativeHtmlPath) {
        Remove-Item -LiteralPath $nativeHtmlPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host 'CHECK FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host ("If generated, the XML report is here: {0}" -f $xmlPath) -ForegroundColor Yellow
    exit 1
}
