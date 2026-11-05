# Paseo Native

非官方的 [Paseo](https://paseo.sh) 原生客户端，Mac、iPhone、iPad 共用一套 SwiftUI 代码。

> **与 Paseo 官方无关。** 它和官方 App 一样，连接你自己电脑上的 Paseo daemon；可以和官方 App 同时装、同时用。界面只有简体中文。

[English](README.en.md)

<p align="center"><img src="docs/images/mac-session.png" width="820" alt="Mac 版会话界面"></p>

<p align="center">
  <img src="docs/images/iphone-home.png" width="200" alt="iPhone 会话列表">
  <img src="docs/images/iphone-permission.png" width="200" alt="iPhone 上批准命令">
  <img src="docs/images/ipad-session.png" width="380" alt="iPad 会话界面">
</p>

## 有什么

- **原生界面**：SwiftUI + macOS / iOS 26 的 Liquid Glass，长会话滚动流畅
- **功能对齐官方客户端**：多台机器、会话、时间线、权限审批、终端、文件、改动、Git 与 PR、计划任务、命令面板
- **Mac**：菜单栏显示等你处理和运行中的会话；在通知里直接回复、允许或拒绝；快速查看、拖出文件；可以不开官方桌面 App，由本 App 在后台运行 daemon（随时切回官方）
- **iPhone / iPad**：灵动岛和锁屏实时活动；带「允许 / 拒绝 / 回复」按钮的推送——用**你自己的** APNs 密钥，由你自己机器上的插件推送，不经过任何第三方服务器
- **配套插件（可选）**：限额刷新时间、回合速度、下一句建议、中文标题，连上机器时一键安装

## 下载

| 平台 | 怎么装 |
|---|---|
| **Mac** | 到 [Releases](https://github.com/52216108/paseo-native/releases/latest) 下载 `Paseo-Native-x.y.z.dmg`，打开后把「Paseo Native」拖进「应用程序」。已签名、已经过苹果公证，双击就能打开；装好叫「Paseo Native.app」，不会覆盖官方的 Paseo.app |
| **iPhone / iPad** | 暂不提供安装包，需要用 Xcode 自己编译安装，见下面的「[iPhone / iPad 版安装](#iphone--ipad-版安装)」 |

系统要求：macOS 26 / iOS 26 / iPadOS 26。电脑上要有 Paseo daemon（官方桌面 App 自带；已用 Paseo v0.15 测试）。

## 连上你的机器

1. 在运行 daemon 的电脑上执行 `paseo daemon pair`，会显示一个二维码和配对链接（官方桌面 App 的设置里也有）。
2. 打开 Paseo Native →「添加机器」→ 选「配对链接」，粘贴链接（iPhone / iPad 可以直接扫二维码）。

经 Paseo 的中继连接，端到端加密，在外面用手机也能连回家里或公司的电脑。配对链接等同于这台机器的钥匙，只保存在本机钥匙串里。同一个局域网里也可以选「直连地址」。

## 配套插件（可选）

<img src="docs/images/mac-plugins.png" width="520" alt="安装配套插件">

插件装在 **daemon 所在的那台机器**上，装好后对这台机器的所有客户端都生效。**全部是可选的**，不装也能正常使用全部基本功能。

| 插件 | 作用 |
|---|---|
| 限额刷新时间 | 侧栏底部显示 Claude / Codex 用量和各限额的刷新时间 |
| 回合速度 | 每轮回复底部显示生成速度和 token 数 |
| 下一句建议 | 空输入框里预测你接下来要说的话，按 Tab 采用 |
| 标题风格 | 新会话自动起简短的中文任务标题 |
| 灵动岛推送 | App 不在前台时，也能推送更新 iPhone 灵动岛和通知（见下文） |

第一次连上一台机器时会弹窗问一次，点「以后再说」就不装；之后想装、想停用或移除，在「设置 → 机器 → 插件」里操作。插件都是开源的，安装前可以在 [Paseo 插件市场](https://paseo.sh/plugins) 或各自的仓库里看源码。

## 替代官方桌面 App（可选），以及怎么切回官方

只想用 Paseo Native 时，可以让它接管本机的 daemon，不再需要打开官方桌面 App：

1. 打开「设置 → 机器 → 这台 Mac」，这里会显示 daemon 现在由谁运行。
2. 显示「由官方 Paseo App 运行」时，点 **「改由本 App 运行…」**。本 App 会退出官方 App、停掉它的 daemon，再用同一个 `~/.paseo` 启动自己管理的 daemon，并设为开机自动启动。
3. 之后官方 App 可以卸载，也可以留着。

> 已经先把官方 App 卸载了也没关系：这时页面显示「没有运行 Paseo」，点「在这台 Mac 上安装并运行 Paseo…」即可。daemon 用的仍是原来的 `~/.paseo`，机器 ID 和配对都不变，不会丢数据。

daemon 用的仍是官方的 `@getpaseo/cli`，装在「应用程序支持/Paseo Native」里。**机器 ID、配对、会话、插件都在 `~/.paseo`，切换前后完全不变**，手机和其他电脑不用重新配对。电脑上原本没有 Paseo 的，这里的按钮是「在这台 Mac 上安装并运行 Paseo…」，会一并装好命令行（约 600 MB）。

**切回官方**：同一个页面点 **「切回官方 App…」**。本 App 会停掉自己的 daemon、取消它的开机启动、把 `~/.local/bin/paseo` 指回原来的命令行，再打开官方 App 由它接管，数据同样不变。这个按钮只在装了官方 App 时出现；如果之前把官方 App 卸载了，先从 [paseo.sh](https://paseo.sh) 重新下载安装，再回到这里切换。

> 切换后不要再同时打开官方 App 让它也起一个 daemon，两个 daemon 会抢同一个 `~/.paseo`。

## iPhone / iPad 版安装

苹果不允许 App Store 以外随意分发 iOS App，所以需要自己用 Xcode 编译安装：

1. 准备一台装了 **Xcode 26** 的 Mac，安装 XcodeGen：`brew install xcodegen`
2. 获取代码并填写签名配置：
   ```sh
   git clone https://github.com/52216108/paseo-native.git && cd paseo-native
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
   编辑 `Config/Local.xcconfig`：`DEVELOPMENT_TEAM` 填你的 Apple 开发者 Team ID（Xcode → Settings → Accounts 里能看到），`PASEO_BUNDLE_ID` 填一个你自己的 bundle ID，如 `com.yourname.paseo-native`
3. `xcodegen generate && open Paseo.xcodeproj`
4. 用数据线连上 iPhone / iPad（第一次要在设备上打开「设置 → 隐私与安全性 → 开发者模式」）
5. 在 Xcode 里选择你的设备，Product → Scheme → Edit Scheme → Run 把 Build Configuration 改成 **Release**（Debug 版滚动会卡），然后点运行

| | 免费 Apple ID | 付费开发者账号（99 美元/年） |
|---|---|---|
| 能否安装 | 可以 | 可以 |
| 有效期 | 7 天，过期后要重新安装 | 1 年 |
| 推送通知、灵动岛远程更新 | 不支持 | 支持 |

## 灵动岛和推送（可选，需要付费开发者账号）

<p>
  <img src="docs/images/activity-expanded.png" width="380" alt="灵动岛展开">
  <img src="docs/images/activity-lock.png" width="380" alt="锁屏实时活动">
</p>

App 在前台时，灵动岛和锁屏卡片会直接更新，**不需要任何配置**。想在 App 不在前台时也收到更新和「完成 / 需要你批准」的推送，按下面配置：

1. **建 APNs 密钥**：登录 [Apple 开发者后台](https://developer.apple.com/account/resources/authkeys/list) → Keys → 新建，勾选 Apple Push Notifications service；Key Restriction 选 Topic Specific，填你的 bundle ID。Xcode 直接安装的用 Sandbox，TestFlight 安装的用 Production。下载得到的 `.p8` 文件只能下载一次，保存好。密钥必须和签名 App 的是**同一个开发者账号**。
2. **装推送插件**：在其中一台机器上安装「灵动岛推送」插件（「设置 → 机器 → 插件」，或首次连接时的弹窗里勾选）。装一台就够，它会把已关联机器上的会话一起算进来。
3. **配置密钥**：iPhone 上打开「设置 → 通知 → 灵动岛推送」→「配置 APNs 密钥…」，填 Team ID、Key ID，选 `.p8` 文件和环境，保存。

密钥只保存在装插件的那台机器上（`~/.paseo/live-activity/`），推送由那台机器直接发给苹果，不经过任何第三方。

## 从源码编译 Mac 版

步骤和上面 iOS 的 1～3 步相同，然后在 Xcode 里选「My Mac」运行。

- 单元测试：`cd PaseoKit && swift test`
- 命令行编译要加 `-skipPackagePluginValidation`（SwiftTerm 的构建插件）
- 发版脚本：`scripts/release-mac.sh <版本号>` 打已公证的 dmg；`scripts/release-ios.sh` 上传 TestFlight。两个脚本都从 `Config/Local.xcconfig` 读团队和 bundle ID

## 目录

- `PaseoKit/`：协议层 Swift Package（Noise 加密通道、配对、客户端、数据模型），附对真实 daemon 的探针 `paseo-probe`
- `App/`：SwiftUI 界面；`Widgets/`：灵动岛 / 实时活动扩展
- `docs/protocol/`：从官方源码整理的协议文档

## 许可证

[Apache License 2.0](LICENSE)。协议文档参考了 [getpaseo/paseo](https://github.com/getpaseo/paseo)，署名与第三方组件见 [NOTICE](NOTICE)。
