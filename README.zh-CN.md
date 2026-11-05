# Paseo Native

非官方的 [Paseo](https://paseo.sh) 原生客户端，支持 macOS、iOS、iPadOS，用 SwiftUI 编写。

> **与 Paseo 官方无关。** Paseo Native 和官方 App 一样连接你自己的 Paseo daemon，可以和官方 App 同时使用。
> 界面只有简体中文。

[English](README.md)

## 特点

- Mac、iPhone、iPad 共用一套 SwiftUI 代码，使用 macOS / iOS 26 的 Liquid Glass 界面
- 多机器、会话、时间线、权限审批、终端、文件、改动、Git 与 PR、命令面板
- **Mac**：菜单栏状态、在通知里直接回复和批准、快速查看、拖出文件；可以不开官方桌面 App，由本 App 管理本机
  daemon（随时可以切回官方 App）
- **iPhone / iPad**：灵动岛和锁屏实时活动、带「允许 / 拒绝 / 回复」按钮的远程推送——由 daemon 插件用
  **你自己的** APNs 密钥推送，不经过任何第三方服务器
- 一键安装配套 daemon 插件（限额刷新时间、回合速度、下一句建议、中文标题）

## 系统要求

- macOS 26 / iOS 26 / iPadOS 26
- 一个 Paseo daemon（已用 Paseo v0.15 测试），经 Paseo relay 或直连都可以

## 安装

**Mac**：从 [Releases](../../releases) 下载已签名、已公证的 dmg。装好是「Paseo Native.app」，不会覆盖官方的 Paseo.app。

**iPhone / iPad**：用 Xcode 自己编译（见下）。用免费 Apple ID 签名的 App 7 天后失效，也收不到远程推送；
付费开发者账号没有这两个限制。

## 编译

```sh
brew install xcodegen
git clone https://github.com/52216108/paseo-native.git && cd paseo-native
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填你自己的 Team ID 和 bundle ID
xcodegen generate                                         # Paseo.xcodeproj 不进仓库，由 project.yml 生成
open Paseo.xcodeproj
```

- 日常使用请在 Product → Scheme → Edit Scheme → Run 里把 Build Configuration 改成 Release，Debug 版滚动明显掉帧。
- 单元测试：`cd PaseoKit && swift test`。命令行编译要加 `-skipPackagePluginValidation`（SwiftTerm 的插件）。
- 发版：`scripts/release-mac.sh <版本号>` 打已公证的 Mac dmg；`scripts/release-ios.sh --check` 检查、
  `scripts/release-ios.sh` 上传 TestFlight。两个脚本都从 `Config/Local.xcconfig` 读团队和 bundle ID。

## 推送和灵动岛（可选，iOS）

1. 在 Apple 开发者后台建一个 APNs 密钥（.p8）——必须和签名 App 的是同一个团队。
2. 在某台机器的 daemon 上装 `live-activity` 插件（设置 → 机器 → 插件 → 配套插件）。
3. App 里：设置 → 通知 → 灵动岛推送 → 配置 APNs 密钥。

密钥只保存在那台机器上（`~/.paseo/live-activity/`）。

## 在 Mac 上运行 daemon

设置 → 机器 → 这台 Mac。官方桌面 App 在运行 daemon 时，可以「改由本 App 运行」：之后开机自动启动，不再需要官方
App。所有数据都在 `~/.paseo`，机器 ID、配对、会话、插件都不变。「切回官方 App」可以反向切换。不要让两边同时运行
daemon。

## 目录

- `PaseoKit/`：协议层 Swift Package（Noise 加密通道、配对、客户端、数据模型），带对真实 daemon 的探针 `paseo-probe`
- `App/`：SwiftUI 界面；`Widgets/`：灵动岛 / 实时活动扩展
- `docs/protocol/`：从官方源码整理的协议文档

## 许可证

[Apache License 2.0](LICENSE)。署名与第三方组件见 [NOTICE](NOTICE)。
