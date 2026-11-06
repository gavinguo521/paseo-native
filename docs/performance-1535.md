# 原生体验优化验证记录（#1535）

2026-11-06，本地开发验证；未推送、未发布或替换日常安装版。

## 实现范围

- 草稿内存即时更新，350 ms 合并落盘；切走、进入后台及 Mac 正常退出时立即保存。输入框子代理和任务区域拆开观察。
- 时间线按回合与行 revision 复用派生结果；Markdown 按完整段落增量解析，只缓存当前文本版本；表格复用同宽度测量。
- 可见时间线采用引用计数、串行更新订阅并补齐漏掉的事件；保留全局状态与通知订阅，非活跃时间线缓存最多 8 个。
- 保存阅读偏移、消息锚点和工具组展开状态；历史范围变化时避免套用失效偏移，加载更早消息时补偿高度变化。
- 搜索/大纲取独立历史快照并合并实时尾部，搜索放到后台执行；定位结果展示最多 81 行，可前后翻页和返回最新。
- 图片读取与解码移出主线程，按显示尺寸生成缩略图，点击后加载原尺寸；缓存有成本上限，保留 EXIF 方向。
- iPhone 声明 `CADisableMinimumFrameDurationOnPhone=true`；开发帧率探针读取设备最大刷新率并记录实际回调间隔。

## 已验证

- `swift test --package-path PaseoKit`：59 项通过，含历史合并去重、流式 revision、跨窗口引用计数及缓存淘汰。
- Mac 优化构建中的 AppTests：7 项通过，含逐字符 Markdown 等价性、逐片段时间线等价性、历史窗口边界、搜索缓存更新和 EXIF 方向。
- SwiftUI 离屏渲染验证了 360/900 点宽的段落和表格换行；已检查生成图片。离屏渲染不覆盖滚动容器中的代码块及真实触控操作，不能替代整页验收。
- iOS Simulator Release 构建通过。未签名 Mac 测试使用独立 bundle ID 和 `PASEO_HOSTS_KEY=performance-tests`，不读取日常连接凭据。
- 独立静态评审及增量复审通过：已修复阅读恢复阻断、搜索快照不更新、后台工具重复行；无遗留必修项。

性能样本为 300 轮、100 个流式片段，累计时间线派生耗时一次测量为缓存 5.57 ms、完整重算 80.15 ms，约减少 93%。这是 CPU 派生计算的微基准，不是端到端延迟、实际帧率或所有会话的性能承诺。

复现界面测试（先 `xcodegen generate`）：

```sh
xcodebuild -project Paseo.xcodeproj -scheme Paseo -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/performance-1535 -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  PASEO_BUNDLE_ID=com.gavin.paseo.performance-tests test
```

## 验收边界

原生 SwiftUI 的帧调度由系统负责，配置允许支持 ProMotion 的 iPhone 使用完整范围，不强制空闲时维持 120 Hz；低电量、温度、系统设置及渲染负载都会影响结果。当前未取得可用 ProMotion 真机，未测持续 120 Hz、掉帧或真实输入延迟。桌面 GUI 自动化也受当前系统访问权限限制，因此端到端交互仍按 [手动回归清单](regression.md) 验收。

官方依据：[ProMotion 优化](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays)、[iPhone 最小帧时长配置](https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone)。
