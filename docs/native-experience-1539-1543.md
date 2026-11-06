# 原生体验验证（#1539—#1543）

本次五项功能全部使用 Swift / SwiftUI，平台宿主和剪贴板使用 AppKit / UIKit；没有新增 WebView、HTML 界面或前端框架。

## 行为与入口

- #1539：侧栏顶部四格图标打开跨机器会话总览。按真实状态显示待输入、运行中、待查看和已完成，支持机器、供应商和文本筛选；离线机器显示最后状态并禁用操作。待处理请求复用原有权限组件，停止前确认并重新检查当前状态。
- #1540：工具或思考块旁的详情按钮打开独立详情。窄屏使用系统 sheet，宽屏使用 SwiftUI 侧面板；支持前后切换、复制完整内容和流式跟随。详情中的日志与 diff 不受内联预览截断限制。
- #1541：项目标题显示新回复数量，覆盖同项目下未选中的工作区标签；点击定位新回复。仅使用已有 attention 标记，不修改手动顺序；已读状态由原有 daemon 流程更新。
- #1542：Markdown 表格支持整体复制、双击选择单元格、长按拖动选择矩形后复制。使用 TSV，含制表符、换行或引号的内容正确转义。
- #1543：三组固定 JSONL 覆盖工具状态替换、长回复和代码表格混排，验证正式协议归并以及原生 AgentView 渲染；样本不含真实会话或凭据。

## 已执行验证

- macOS：21 项测试、9 个 suite 通过，覆盖总览状态与筛选、详情全文、未读定位与手动顺序、表格范围和协议回放。表格手势调整后又通过相关 5 项测试。
- iPhone Air（iOS 26.5 模拟器）、iPad（iOS 27.2 模拟器）：`MobileFeatureTests` 通过，生成总览、详情、表格的原生窗口截图。
- Mac 截图覆盖 390/960 宽度的详情与表格、390/1200 宽度总览，以及三组 AgentView 回放。
- `python3 scripts/generate-stream-fixtures.py --check` 通过，确认提交样本可确定性重建。
- 总览权限/停止路径经独立静态评审；回放测试入口经独立评审和修复复审，均通过。
- 独立 macOS 回放应用实际操作：总览跳转、新回复徽标定位且项目顺序不变、原生辅助功能动作选择单元格后复制、整表复制、工具详情打开/前后切换/关闭。剪贴板确认单格为 `项目`、整表含 TSV 行、工具全文包含 `FINAL LOG MARKER` 和退出码。

回放布局时间仅用于后续同机同配置比较，不代表真实模型、网络速度或屏幕 FPS。此次未向真实 daemon 发送停止/权限写操作，未进行实体 iPhone/iPad 触控验收。区域范围与 TSV 由单元测试覆盖，实际长按拖动手势尚待人工验收；本机窗口截图被台前调度转换为缩略图，未将其当作坐标拖动证据，视觉检查使用原生窗口渲染测试截图。

## 重复执行

```sh
python3 scripts/generate-stream-fixtures.py --check
xcodebuild -project Paseo.xcodeproj -scheme Paseo -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/native-experience-tests \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  PASEO_BUNDLE_ID=com.gavin.paseo.experience-tests ONLY_ACTIVE_ARCH=YES test
```

手机和平板使用 `PaseoMobile` scheme 与对应模拟器 destination，限定 `-only-testing:PaseoMobileTests/MobileFeatureTests`。截图路径由测试输出 `FEATURE_SCREENSHOT` 给出。

Mac 截图在 `/tmp/paseo-overview-*.png`、`/tmp/paseo-details-*.png`、`/tmp/paseo-table-*.png`、`/tmp/paseo-replay-*.png`。

## 独立交互回放构建

仅测试构建显式同时启用 `DEBUG PASEO_REPLAY`，并设置 `ENABLE_TESTABILITY=YES` 后才编译入口。启动环境变量 `PASEO_REPLAY_FILE` 指向上述 JSONL；应用标识必须以 `.replay-tests` 结尾，否则立即失败。启动跳过日常凭据读取和主机连接；激活回放时 `persist()` 也禁止写入连接钥匙串，避免测试界面中的设置操作影响日常配置。正常构建不含该入口。

```sh
xcodebuild -project Paseo.xcodeproj -scheme Paseo -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/feature-replay-1543 \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG PASEO_REPLAY' \
  PASEO_BUNDLE_ID=com.gavin.paseo.replay-tests ONLY_ACTIVE_ARCH=YES build
PASEO_REPLAY_FILE="$PWD/AppTests/Fixtures/table-code.jsonl" \
  build.noindex/feature-replay-1543/Build/Products/Release/Paseo.app/Contents/MacOS/Paseo
```

这是自包含的开发回放入口，只自动播放本地样本；回放窗口仍有现有应用导航，不应手动添加真实机器或发起真实业务操作。
