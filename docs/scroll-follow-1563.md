# 流式输出自动贴底（#1563 / GitHub #7）

## 原因与修复

旧实现把瞬时几何距离直接写入 atBottom：内容高度从 1000 增至 1600、偏移仍为 600、视口 400 时，即使没有用户滚动，也会关闭自动跟随的底部锚点。纯几何回归固定覆盖这一事件顺序。

新的 TimelineBottomFollow 保留独立跟随意图：内容增高不取消跟随；用户实际上翻并离开底部才退出；用户滚回底部或显式返回最新后继续跟随。空闲时对内容/视口尺寸变化补底部定位，滚动交互过程中不抢位。

历史窗口、恢复旧偏移、搜索定位和向前补页期间禁用跟随干预。没有改变 32pt 容差，也没有增加定时滚动。

参考 Apple 的 [onScrollPhaseChange](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:)) 和 ScrollPosition.isPositionedByUser；滚轮/键盘无连续 phase 时使用用户定位标记与实际偏移变化。

## 验证范围

TimelineBottomFollowTests 覆盖几何先增高、用户上翻、阅读时增高、重新贴底、视口缩小和程序定位；原生 NSScrollView 测试使用正式 modifier，验证连续大幅增高、滚轮上翻、滚回底部和显式返回最新。原生滚轮事件直接派发给测试滚动视图，不等同于真人触控板验收。

结果：Mac TimelineBottomFollowTests、StreamReplayTests、TimelinePerformanceTests 共 13 项通过；iOS MobileFeatureTests 1 项通过。采用 Release 优化加测试入口、独立测试 bundle ID，未连接真实会话。静态独立评审通过，评审提出的原生滚轮验证缺口已补测通过。

仅本地修复；不包含在已发布的 1.0.18 中。
