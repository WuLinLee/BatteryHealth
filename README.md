# BatteryHealth：Windows 电池健康度与完整报告

面向 Windows 笔记本、二合一设备和平板电脑的本地电池信息检查工具。采用 **BAT 启动器 + PowerShell 核心脚本** 分离结构，使用 Windows 自带的 `powercfg` 生成报告，不依赖第三方模块。

## 主要功能

- 通过 `powercfg /batteryreport /xml` 生成原始 XML 报告。
- 额外通过 Windows 原生命令生成完整 HTML 电池报告，保留 Windows 提供的历史图表和估算章节。
- 自动生成面向普通用户的中文 `BatteryHealth.html` 报告，并尝试用默认浏览器打开。
- 首屏用大号健康度、简单结论、容量对比条和信息卡解释电池现状；用日常语言说明健康度、容量损耗和循环次数。
- 将技术字段、XML 路径和原始 XML 全文收纳到默认折叠的“进阶信息”中，普通用户不用阅读这些内容。
- 保留 XML 中**所有可读的叶子节点值和属性**，展开进阶信息后仍可逐项查看。
- 尽可能处理报告中多块电池的情况。
- 如果 XML 缺少可计算健康度的容量数据，仍会生成详细 XML 查看报告，不会编造健康度。
- 采用 XML DOM / XPath 的命名空间容错方式，不解析 HTML，不使用 WMI，不需要管理员权限（取决于系统策略）。

## 使用方法

1. 下载 `一键查电池.bat` 和 `Check-BatteryHealth.ps1`，放在同一个文件夹。
2. 双击 `一键查电池.bat`。
3. 脚本会在桌面生成报告，并自动尝试打开 `BatteryHealth.html`。
4. 日常只看电池健康度和下面的白话说明即可；一般不需要展开最底部的“进阶信息”。如果需要排查问题，再展开全部 XML 字段并按 **Ctrl+F** 搜索。
5. 如果自动打开失败，可手动双击桌面上的 `BatteryHealth.html`。也可打开 `BatteryReport-Windows.html` 查看 Windows 原生详细报告。

## 运行后会生成哪些文件？

| 文件 | 用途 |
|---|---|
| `BatteryReport.xml` | 原始 XML 数据；供脚本解析、逐项查看和排查问题。 |
| `BatteryReport-Windows.html` | Windows 自带的完整电池报告，包含系统实际能提供的使用记录、历史、容量历史和电池寿命估算等章节。 |
| `BatteryHealth.html` | 本项目生成的中文综合报告：健康度概览、全部 XML 字段/属性和原始 XML 全文。 |

这些报告都保存在当前 Windows 用户的桌面。Windows 或固件没有提供的信息不会由脚本自行推断。

## 报告里展示哪些信息？

### 普通用户先看这里

中文报告将健康度放在最醒目的位置，并用一句话说明结果，再配上容量比例条和四张小卡片。关键字段均提供日常用语解释，而不是要求用户理解 XML 或技术名词。

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

### XML 完整字段区

报告会自动遍历生成的 XML，在每个一级节点下展示所有叶子节点和属性的路径及值。因此除了健康度概览，也可查找 Windows 该次报告实际提供的其他信息，例如历史记录、使用记录、容量历史、估算数据或后续 Windows 版本新增的字段（具体取决于实际 XML 内容）。

对于重复节点，会尽可能在路径中标出序号。原始 XML 全文也会以纯文本形式放在可折叠区域中，便于核对。

### Windows 原生完整报告

脚本还会单独请求 `powercfg /batteryreport /output` 生成原生 HTML。相较于只呈现几个容量值，原生报告更适合查看 Windows 自带的历史表格和图表。这个文件与本项目的中文综合页相互补充。

## 兼容性与限制

- 目标是 Windows 10/11 常见桌面 PowerShell 环境；不同系统版本和不同厂商固件提供的 XML 字段可能不同。
- 本工具尚未在所有品牌、型号、固件和 Windows 版本上测试。
- 是否提供循环次数、历史记录和容量估算，取决于系统与设备实际提供的数据。
- 健康度只是根据报告容量推算的估计值，并非电池诊断仪测量结果。
- 如果设计容量或当前满充容量缺失、为零或无效，相关健康度会标记为不可计算。
- 脚本不会因为报告里缺少某个字段就假设其值为零，也不会伪造缺失信息。
- 报告在本机生成，脚本本身不会向网络上传电池数据。
- 如果 `BatteryReport-Windows.html` 生成失败，中文综合报告仍会尽量展示 XML 中能读取的内容。

## 开源实现与官方文档参考

本项目优先参考社区已有实现中经过实践的思路，并结合当前需求实现完整字段查看；没有直接复制这些项目的完整代码。界面上借鉴“先呈现关键健康度、再提供简短解释、技术数据按需展开”的常见易读设计思路。使用前建议同时查看原项目的许可证与最新说明。

- [homotechsual/Blog-Scripts — Monitoring/BatteryHealth.ps1](https://github.com/homotechsual/Blog-Scripts/blob/main/Monitoring/BatteryHealth.ps1)：使用 `powercfg /batteryreport /XML` 并通过 XML 路径读取电池字段。
- [NSTechBytes/BatteryHealth](https://github.com/NSTechBytes/BatteryHealth)：电池健康度脚本实现参考，重点输出健康度、循环次数和容量。
- [scavin/BatteryHealth](https://github.com/scavin/BatteryHealth)：极简 Windows 电池健康查看器；参考其以大号健康度和简明电池信息为主的界面安排。
- [koetsuji/Windows-Battery-Report](https://github.com/koetsuji/Windows-Battery-Report)：浏览器仪表盘风格的电池报告工具；参考其把关键指标前置展示的思路。
- [auberginehill/get-battery-info](https://github.com/auberginehill/get-battery-info)：展示一般计算机与电池信息，并保存 Windows 电池报告文件。
- [Microsoft Learn — powercfg 命令行选项（中文）](https://learn.microsoft.com/zh-cn/windows-hardware/design/device-experiences/powercfg-command-line-options)：官方说明 `/batteryreport`、`/output` 和 `/xml` 等选项。

## 仓库文件

- `一键查电池.bat`：启动器，运行完暂停窗口以便查看输出。
- `Check-BatteryHealth.ps1`：核心检测、XML 解析和 HTML 报告生成逻辑。
- `README.md`：说明文档。

## 许可证

当前仓库未声明许可证。若希望他人明确地再分发或修改本项目，请添加适当的 LICENSE 文件。
