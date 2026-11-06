# 聊天内 HTML 预览与返回会话（#1553）

## 行为

助手消息中独立一行的完整标记会显示为可交互的预览卡片：

```text
visualize{"path":"/path/to/workbench.html","mode":"wide"}
```

- 文件从当前会话的主机读取，不读取手机或另一台 Mac 上的同名路径；相对路径沿用会话目录。
- 支持 UTF-8 的 `.html` / `.htm`，复用当前主机文件读取能力，上限 20 MiB。缺失、断线或无法解码时显示失败与重试。
- `wide` 使用聊天可用宽度和 480 点预览高度；其他模式最多 640 点宽、360 点高。长页面在卡片内滚动，手机使用原页面的响应式布局。
- 手机点“全屏查看”进入全屏，左上始终有“返回会话”；Mac 使用放大面板。展开/返回移动同一 WebView，同一文件重新出现时不会重新加载。
- 原有文件标签页也新增“返回会话”，优先回到打开该文件的来源，包括从历史进入的已归档会话。返回不关闭文件标签、不归档会话。
- 未完成、非法标记和代码围栏中的示例保留文本；用户消息的 `renderMedia: false` 不启动 HTML 读取或执行。

## 支持边界

当前支持自包含 HTML 的内置 CSS、JavaScript、data/blob 图片，不支持外部 CDN、相对资源文件、联网接口或 ChatGPT 专用 widget bridge。页面脚本运行在无同源权限的 sandbox iframe，使用非持久 WebKit 存储；CSP 限制外部资源与请求，导航策略阻止离开预览，不提供 App、凭据或主机文件访问桥接。

## 验证（2026-11-06）

- Mac `PaseoTests/VisualizationTests`：4 项通过，覆盖标记解析/流式补齐/围栏保留、来源返回（含已归档）、WebKit 交互与隔离、预览展开返回保持同一页面。
- Mac 表格选择、表格粘贴与消息回放相关回归：连同预览共 13 项通过。
- iPhone 18 Pro / iOS 27.2 模拟器 `PaseoMobileTests/VisualizationTests`：4 项通过，实际执行全屏展开、等待转场完成、返回聊天并确认 WebView 和页面状态未重建。
- 使用用户提供的真实工作台 HTML，获取手机内嵌、手机全屏和桌面宽度截图并人工查看。全屏布局断言检查页面扩展至屏幕宽度；截图等待 UIKit 转场和 WebKit 快照完成，不用固定 sleep 猜测。
- 新增文案中英文、`git diff --check` 通过。
- 独立静态评审及问题增量复审通过。生产实现评审基线 `37ceffac09681d1ed69afa2dc5cb07a241a7d7fe`，修复后 patch SHA256 `870325039476e98ed7b8e044cd71464f676964f13e4af9eb58f6afd515f1104b`；其后的变更仅扩充测试取证。

复跑命令：

```sh
xcodebuild -project Paseo.xcodeproj -scheme Paseo \
  -destination 'platform=macOS' -derivedDataPath build.noindex/visualize-1553 \
  -skipPackagePluginValidation -only-testing:PaseoTests/VisualizationTests \
  test CODE_SIGNING_ALLOWED=NO

xcodebuild -project Paseo.xcodeproj -scheme PaseoMobile \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro (27.2)' \
  -derivedDataPath build.noindex/visualize-ios-1553 -skipPackagePluginValidation \
  -only-testing:PaseoMobileTests/VisualizationTests \
  test CODE_SIGNING_ALLOWED=NO PASEO_BUNDLE_ID=com.gavin.paseo.visualize-tests
```

默认使用测试内置 HTML；需要重放实际文件时，在命令前设置 `TEST_RUNNER_PASEO_VISUALIZE_SAMPLE=/path/to/workbench.html`。测试输出 `VISUALIZATION_*_SCREENSHOT` 给出截图路径。本次整理后的本地截图位于 `~/outputs/paseo-visualize-1553/`。

尚未在用户真机安装或验收；未推送、未发布。
