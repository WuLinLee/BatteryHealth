# BatteryHealth：Windows 电池健康度与完整报告

面向 Windows 笔记本、二合一设备和平板电脑的本地电池信息检查工具。采用 **BAT 启动器 + PowerShell 核心脚本** 分离结构，使用 Windows 自带的 `powercfg` 生成报告，不依赖第三方模块。

## 主要功能

- 通过 `powercfg /batteryreport /xml` 生成原始 XML 报告。
- 使用 Windows 原生命令生成 HTML 电池报告，以该报告为基础翻译常见英文标题和字段，尽量保留 Windows 自带的历史表格、图表和续航估算。
- 强制使用白色页面背景、深色正文、浅灰表头和蓝色分区标题，覆盖部分 Windows 原报告自带的黑底深色主题；表格用交替浅色行提升可读性。
- 将健康度摘要和翻译后的 Windows 原报告合并到同一个 `BatteryHealth.html`，不再额外生成一个独立的翻译 HTML。
- 首屏用大号健康度、简单结论、容量对比条和信息卡解释电池现状；用日常语言说明健康度、容量损耗和循环次数。
- 继续保留 `BatteryReport.xml` 作为原始数据，供有需要时排查问题。
- 尽可能处理报告中多块电池的情况。
- 如果 XML 缺少可计算健康度的容量数据，顶部会说明无法计算；下方仍保留 Windows 原生报告的可用内容，不会编造健康度。
- 使用 XML DOM / XPath 读取关键容量数据；对 Windows HTML 只翻译常见可见文字并插入摘要，不重建原报告的表格与图表。不使用 WMI，也不依赖第三方模块。

## 使用方法

1. 下载 `一键查电池.bat` 和 `Check-BatteryHealth.ps1`，放在同一个文件夹。
2. 双击 `一键查电池.bat`。
3. 脚本会在桌面生成报告，并自动尝试打开 `BatteryHealth.html`。
4. 打开的 `BatteryHealth.html` 顶部显示健康度摘要；继续往下就是 Windows 原版完整报告，常见英文标题和字段已翻译，原有历史表格与图表尽量保留。
5. 如果自动打开失败，可手动双击桌面上的 `BatteryHealth.html`。

## 运行后会生成哪些文件？

| 文件 | 用途 |
|---|---|
| `BatteryReport.xml` | 原始 XML 数据；供脚本解析、逐项查看和排查问题。 |
| `BatteryHealth.html` | 唯一的 HTML 报告：顶部是白话健康度摘要，下面接上翻译后的 Windows 原版报告。 |

这些报告都保存在当前 Windows 用户的桌面。Windows 或固件没有提供的信息不会由脚本自行推断。

## 报告里展示哪些信息？

### 普通用户先看这里

中文报告将健康度放在最醒目的位置，并用一句话说明结果，再配上容量比例条和四张小卡片。关键字段均提供日常用语解释，而不是要求用户理解 XML 或技术名词。Windows 原报告紧接在摘要下方，常见英文标题与字段会按内置词条翻译。

页面的状态提示使用简单参考区间（健康度 90% 以上、80–89.9%、50–79.9%、低于 50%）来帮助阅读；这些区间是界面提示，不是对电池是否故障的诊断，也不应单独作为更换依据。微软文档指出，电池可用容量低于设计容量的 80% 可作为电池接近寿命终点的一般参考，但实际情况会受到设备与使用方式影响。

### 电池健康度概览

当报告提供有效的容量值时，展示：

- 电池 ID（若 XML 提供；否则使用脚本生成的序号）。
- 设计容量（Design Capacity，mWh）。
- 当前满充容量（Full Charge Capacity，mWh）。
- 电池健康度估算：`满充容量 ÷ 设计容量 × 100%`。
- 容量损耗估算：`100% − 健康度`。
- 循环次数（Cycle Count；如果 Windows 报告没有该字段，则显示“未提供”）。
- 容量状态提示。当前页面采用低于 50%、低于 80% 的显示分段作为粗略提示，不是电池厂商统一标准，也不代替维修检测。

### Windows 原生完整报告（已合并翻译）

`BatteryHealth.html` 直接以 Windows 的原生 HTML 电池报告为基础，只翻译常见可见标题和字段，并在顶部增加健康度摘要。这样可以尽可能保留 Windows 原来的近期使用、耗电记录、容量历史和续航估算布局，不必将所有原始数据重新拆开、再绘制一遍。

翻译采用本地的常见词条映射。Windows 版本、报告结构或系统语言不同，少数未列入词典的文字仍可能保持原文；图表和日期等数据保持系统生成的内容。

## 兼容性与限制

- 目标是 Windows 10/11 常见桌面 PowerShell 环境；不同系统版本和不同厂商固件提供的 XML 字段可能不同。
- 本工具尚未在所有品牌、型号、固件和 Windows 版本上测试。
- 是否提供循环次数、历史记录和容量估算，取决于系统与设备实际提供的数据。
- 健康度只是根据报告容量推算的估计值，并非电池诊断仪测量结果。
- 如果设计容量或当前满充容量缺失、为零或无效，相关健康度会标记为不可计算。
- 脚本不会因为报告里缺少某个字段就假设其值为零，也不会伪造缺失信息。
- 报告在本机生成，脚本本身不会向网络上传电池数据。
- 如果 Windows 原生 HTML 报告生成失败，脚本会提示错误，不会生成冒充有效完整报告的页面。

## 开源实现与官方文档参考

本项目优先参考社区现有实现，采用“先呈现关键健康度，再保留系统原报告”的方式；翻译只覆盖预设的常见词条，不保证每个 Windows 版本中的每个单词都能翻译。没有直接复制这些项目的完整代码。使用前建议同时查看原项目的许可证与最新说明。

- [homotechsual/Blog-Scripts — Monitoring/BatteryHealth.ps1](https://github.com/homotechsual/Blog-Scripts/blob/main/Monitoring/BatteryHealth.ps1)：使用 `powercfg /batteryreport /XML` 并通过 XML 路径读取电池字段。
- [NSTechBytes/BatteryHealth](https://github.com/NSTechBytes/BatteryHealth)：电池健康度脚本实现参考，重点输出健康度、循环次数和容量。
- [scavin/BatteryHealth](https://github.com/scavin/BatteryHealth)：极简 Windows 电池健康查看器；参考其以大号健康度和简明电池信息为主的界面安排。
- [koetsuji/Windows-Battery-Report](https://github.com/koetsuji/Windows-Battery-Report)：浏览器仪表盘风格的电池报告工具；参考其把关键指标前置展示的思路。
- [auberginehill/get-battery-info](https://github.com/auberginehill/get-battery-info)：展示一般计算机与电池信息，并保存 Windows 电池报告文件。
- [Microsoft Learn — powercfg 命令行选项（中文）](https://learn.microsoft.com/zh-cn/windows-hardware/design/device-experiences/powercfg-command-line-options)：官方说明 `/batteryreport`、`/output` 和 `/xml` 等选项。
- [Microsoft Learn — CIM_Battery（电池容量字段说明）](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/cim-battery)：说明设计容量与满充容量的含义，以及 80% 可作为寿命终点的一般参考之一，而非单独的故障诊断。

## 仓库文件

- `一键查电池.bat`：启动器，运行完暂停窗口以便查看输出。
- `Check-BatteryHealth.ps1`：核心检测、XML 解析和 HTML 报告生成逻辑。
- `README.md`：说明文档。

## 许可证

当前仓库未声明许可证。若希望他人明确地再分发或修改本项目，请添加适当的 LICENSE 文件。
