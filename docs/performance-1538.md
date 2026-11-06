# iPhone / iPad 多项目侧栏验证（#1538）

2026-11-06，验证 #1536 的公共侧栏优化在移动端是否生效。本轮新增移动端测试入口，复用 Mac 的内存样本，没有新增生产行为修改。

## 环境与样本

- iPhone Air 模拟器，iOS 26.5，侧栏宽 420 点。
- iPad 模拟器（iPad17,4），iPadOS 27.2，单独验证 320 点宽的原生侧栏。
- 每端分别运行 30、60、100 个项目；每项目 8 个工作区、每工作区 2 个会话，即 480、960、1600 个会话。
- Release 优化加 DEBUG，独立测试 bundle ID 和钥匙串条目；数据仅在测试目标内生成，未连接真实 daemon。

## 结果

两端测试均通过，原生截图已查看：首屏按需创建、100 项目滚到底再回顶部，无测试中可见的空白或越界。项目数量增加没有再次触发全量行布局。没有发现需要单独修复的 iPhone / iPad 特有问题。共享样本抽取后的 Mac 侧栏 3 项回归也通过。

| 项目数 | iPhone 首屏行 body 次数 | iPad 首屏行 body 次数 | 全量工作区行数 |
| --- | ---: | ---: | ---: |
| 30 | 16 | 32 | 240 |
| 60 | 32 | 64 | 480 |
| 100 | 32 | 64 | 800 |

这些是含 SwiftUI 更新在内的行视图计算次数，不是唯一可见行数。100 项目程序滚动：iPhone 98 步到尾部、iPad 94 步到尾部，两端返回顶部后内容正常。横滑手势的静态检查确认：纵向移动不持续写横向偏移；本轮没有自动化验证手指手势竞争、惯性滚动、归档动作或折叠点击。

模拟器中的分组计算平均值（连续 10 次）分别为：iPhone 约 2.95 / 5.98 / 10.29 ms，iPad 约 2.90 / 5.85 / 9.30 ms。这不是设备实际性能、掉帧率或 120 Hz 验收。样本不含真实项目的自定义图标、PR 标签或持续网络推送；真机输入、GPU 呈现与功耗限制仍需在对应硬件上测试。

## 复现

```sh
xcodegen generate
xcodebuild -project Paseo.xcodeproj -scheme PaseoMobile -configuration Release \
  -destination 'platform=iOS Simulator,id=<设备 UUID>' \
  -derivedDataPath build.noindex/performance-mobile-1538 -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  PASEO_BUNDLE_ID=com.gavin.paseo.performance-tests test
```

同架构第二台模拟器可将最后的 `test` 换成 `test-without-building`。截图路径由测试日志的 `MOBILE-SIDEBAR screenshot=` 输出。iPad 截图右侧空白属于只挂载侧栏的测试容器，不是主界面缺失。
