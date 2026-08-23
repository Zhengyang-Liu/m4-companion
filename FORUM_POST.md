# Forum post draft

## M4 Companion — an unofficial MOMENTUM 4 controller for macOS

I wanted the controls I use most on my phone to be available directly on my Mac, so I built **M4 Companion**.

It is a native, open-source macOS app for Sennheiser MOMENTUM 4 with:

- multipoint device switching;
- battery and connection status;
- Adaptive / Custom / Off noise control;
- transparency and Anti-Wind controls;
- five-band EQ, presets, and Bass Boost;
- medium and large interactive desktop widgets;
- local phone-side state synchronization while the app is open.

Everything runs locally over Bluetooth. There is no account, cloud backend, telemetry, or analytics.

**Current status:** v0.2.0 Technical Preview for macOS 14+. The DMG is ad-hoc signed and not notarized, so macOS may require **Open Anyway** or the scoped quarantine command documented in the README. I clean-tested the release-style DMG locally; the menu bar app and WidgetKit widget both loaded and worked after the bypass.

Download: https://github.com/Zhengyang-Liu/m4-companion/releases/tag/v0.2.0

Source: https://github.com/Zhengyang-Liu/m4-companion

Website: https://zhengyang-liu.github.io/m4-companion/

This is an independent, unofficial project and is not affiliated with or endorsed by Sennheiser or Sonova.

---

## 中文版

做了一个 **M4 Companion**：面向 Sennheiser MOMENTUM 4 的非官方原生 macOS 控制工具。

目前支持：

- 双设备连接查看与切换
- 电量和连接状态
- Adaptive / Custom / Off 降噪模式
- 通透强度和防风噪
- 五段 EQ、预设和 Bass Boost
- 中号与大号交互式桌面小组件
- 主程序打开时同步手机端对耳机设置的修改

所有功能均在本机通过蓝牙完成，不需要账号、云服务，也没有遥测或分析。

当前是 **v0.2.0 Technical Preview**，要求 macOS 14+。安装包采用 Ad-hoc 签名，尚未经过 Apple 公证，所以首次启动可能需要在“隐私与安全性”中选择“仍要打开”，或按 README 执行仅针对本 App 的 quarantine 移除命令。我已经从发布版 DMG 安装并验证过菜单栏程序和 Widget。

下载：https://github.com/Zhengyang-Liu/m4-companion/releases/tag/v0.2.0

源码：https://github.com/Zhengyang-Liu/m4-companion

介绍页：https://zhengyang-liu.github.io/m4-companion/

本项目为独立非官方开源项目，与 Sennheiser 或 Sonova 无隶属或背书关系。
