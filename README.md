# BatteryHealth（Windows 电池健康度查询）

一个轻量的 Windows PowerShell 电池健康度检查脚本，采用 **BAT 启动器 + PowerShell 核心脚本** 分离结构。

## 功能

- 使用 Windows 自带的 `powercfg /batteryreport /xml` 生成原始 XML 数据。
- 解析可用电池的设计容量、当前满充容量和循环次数（若固件提供）。
- 计算健康度：`满充容量 ÷ 设计容量 × 100%`。
- 将原始数据保留为桌面上的 `BatteryReport.xml`。
- 自动生成中文网页报告 `BatteryHealth.html`，并尝试用默认浏览器打开。
- 支持报告中存在多块电池的情况；缺少关键容量字段时不编造健康度。
- 不使用 WMI、不依赖第三方 PowerShell 模块，也不解析 Windows 原始 HTML 报告。

## 使用方法

1. 下载仓库中的 `一键查电池.bat` 和 `Check-BatteryHealth.ps1`，放在同一个文件夹。
2. 双击 `一键查电池.bat`。
3. 检查命令窗口结果；网页报告和原始 XML 会保存在桌面。

如果浏览器没有自动打开，可手动打开桌面的 `BatteryHealth.html`。XML 是供脚本读取和排查问题的原始数据文件，不需要通过浏览器查看。

## 文件

- `一键查电池.bat`：启动 PowerShell 脚本，并在结束后暂停窗口以便查看结果。
- `Check-BatteryHealth.ps1`：生成和解析 XML、计算健康度、生成 HTML 报告。
- `BatteryReport.xml`：运行时生成的原始数据文件（桌面）。
- `BatteryHealth.html`：运行时生成的中文浏览器报告（桌面）。

## 兼容性与限制

- 面向 Windows 10/11 内置 Windows PowerShell 的常见使用场景；未在所有厂商和固件上测试。
- 是否能读取电池循环次数取决于 Windows 报告和设备固件。
- 如果系统没有提供有效的设计容量或满充容量，脚本会提示无法计算。
- 健康度是基于报告容量的估算值，不是专业电池检测仪的测量结果。

## 参考的开源实现与官方文档

本项目参考了开源项目中的 XML 解析、容量比值计算和命令行输出思路；未直接复制其完整代码：

- [homotechsual/Blog-Scripts — BatteryHealth.ps1](https://github.com/homotechsual/Blog-Scripts/blob/main/Monitoring/BatteryHealth.ps1)
- [NSTechBytes/BatteryHealth](https://github.com/NSTechBytes/BatteryHealth)
- [auberginehill/get-battery-info](https://github.com/auberginehill/get-battery-info)
- [Microsoft Learn — powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)

## 许可证

当前仓库未声明许可证。若要允许他人明确地再分发或修改，请在仓库中添加适当的 LICENSE 文件。
