# 三个响应性场景的对照验证（#1555）

2026-11-06，本地 Release 优化构建加 DEBUG（测试入口），隔离 bundle ID 和配对钥匙串。测试只用测试目标内固定样本，不连接真实 daemon。未替换日常应用、推送或发布。

## 保留的改动

1. 流式代码按完整行复用高亮和块注释状态，只重新处理末尾未完成行。重写、截短、语言变化会失效重算；维持原算法和 4,000 行着色上限。未改变 Markdown 协议或消息内容。
2. 文件源码预览后台准备文本与行号，使用原生连续文本控件；按实际可见文本范围请求高亮，每批最多 128 行发布属性。着色不替换文本、选区或焦点。保留原来的 20,000 行预览与 5,000 行高亮上限，复制完整文件按钮保持原行为。Mac 用 NSTextView，iOS 用外层横向滚动和内层 UITextView 纵向滚动；iOS 行宽在后台测量。Markdown/HTML 渲染预览没有改动。

## 对照方法与观察

同一测试进程、相同文本比较原实现与新实现，不用 Debug 数字与 Release 数字互比。`ResponsivenessTests` 保留原始整块高亮、原文件富文本生成及候选布局，仅存在测试目标中。

- 流式代码：1,200 行 Swift/中文固定代码，再追加 40 行；原算法累计 1.68–1.74 秒，新算法约 71–74 ms。测的是高亮生成，包含新缓存第一次完整计算，不是整页帧率。
- 文件预览：12,000 行相同代码和字体。一次最终回归的原同步富文本准备约 342 ms、原首布局约 2,247 ms；新后台文本准备约 12 ms、新原生首布局约 26 ms。图片已检查，跨行选区在后台着色和跳行之后保持不变。
- 文件对照中同时记录 `awaitWall`：它还包含前一套 SwiftUI 视图已排队的主线程工作，因此不能把后台函数计时直接称为用户打开文件的端到端耗时。上面的准备和布局应分别理解，不承诺所有文件固定提速倍数。

## 长会话：实验完成，未保留生产改动

已确认展开历史会放大首次布局成本：同一段 Markdown 从 16 项增加到 160 项，基线约 58–61 ms → 430–470 ms。

尝试过回到最新后收缩已展开窗口，但独立评审指出：用户选中较早消息后滚动到底，销毁离屏视图会破坏仍保留的文本选区。因此完整撤回该实现，`AgentView` 和 `TimelineReadingState` 无最终变更。

随后对照保留所有视图、复用高度测量的自定义 Layout。160 项一轮为原布局 462 ms、候选 475 ms；另一轮为 456 / 452 ms，无稳定收益。候选只保留在测试中用于复现，不进入生产。仍使用原有首屏 16 项窗口、历史展开和阅读恢复行为。没有宣称本轮解决了长会话布局问题。

## 验证范围

- 逐字符增量高亮与原算法等价，覆盖跨行注释、中文/emoji、重写/清空/截短、语言切换和高亮行数上限。
- 原有时间线/Markdown/图片回归和协议流回放继续执行。
- Mac 原生文件截图与实际文本选区断言；同一文件可定位到第 11,000 行。
- iPhone 模拟器验证大文件源码横向滚动、原生跨行选区、后台高亮、横滚后跳到短行以及目标确实与视口相交。
- 原生文本布局期间直接改属性曾引起 iOS 布局重入；最终改为退出滚动回调后合并更新。iOS 非连续布局下的远距离定位会使用估算坐标并复位偏移；最终仅在指定行跳转时补齐目标前的布局，再按实际坐标定位。首次打开仍按需布局；远距离跳转的同步布局成本仍存在。
- Mac 相关 14 项测试通过；加强目标行可见性断言后，重跑的性能测试套件 4 项也通过。iOS 1 项集成测试通过，等待第 5,000 行着色完成后验证第 11,000 行仍在视口、横向偏移已复位、选区不变。
- 独立静态评审及修复增量复审：自动收缩导致选区丢失、iOS 横滚后短行目标不可见两项均已解决。

这些证据不是 GPU 帧呈现、触控板惯性手感、真机 120 Hz 或真实网络会话端到端验收。流式输出的 Markdown 尾部解析和单行不断增长的高亮仍可能有成本；未为此扩大改动。

## 复现

```sh
xcodegen generate
xcodebuild -project Paseo.xcodeproj -scheme Paseo -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/responsiveness-1555 -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  PASEO_BUNDLE_ID=com.gavin.paseo.performance-tests \
  -only-testing:PaseoTests/ResponsivenessTests \
  -only-testing:PaseoTests/TimelinePerformanceTests \
  -only-testing:PaseoTests/StreamReplayTests test
```

iOS 使用 `PaseoMobile` scheme、独立 derivedDataPath、指定模拟器 destination 和 `-only-testing:PaseoMobileTests/FileSourceTests`。具体输出由 `RESPONSIVENESS` / `FILE_MOBILE screenshot=` 日志定位，`.xcresult` 位于对应 derivedDataPath 的 `Logs/Test`。测试方法过滤必须包含 Swift Testing 的实际方法标识；本轮使用 suite 过滤，避免只出现 `TEST SUCCEEDED` 却执行 0 项。

原生文本容器的尺寸/跟随机制参考 [Apple NSTextContainer 文档](https://developer.apple.com/documentation/uikit/nstextcontainer/widthtrackstextview)。
