# 项目分组排序回归（#1537）

用户反馈：排好序后，项目里的会话收到消息，整个项目分组又跑到顶部。

## 用户确认的规则

默认使用最近活动排序。拖动项目或工作区排序后，必须自动切到手动排序，菜单同步显示手动，并保存该设置；后续消息不能打乱已排好的顺序。只有用户主动选回最近活动时，才恢复自动排序。

此前提交 5327725 将项目顺序与所选排序模式分离，属于对需求的误解，现已撤回这部分实现。不能以“菜单仍显示最近活动，但实际上保持手动顺序”代替正确的模式切换。

## 定位与验证范围

`moveProject` 和 `moveWorkspace` 均调用 `freezeOrderForManual`，后者保存当前顺序并设置 `sort = .manual`；属性观察器将模式保存到 `sidebarSort`。菜单直接绑定同一个 `model.sort`。

本机保存了手动排序和 12 个项目的位置；只读检查运行中的侧栏时，其顺序与记录一致，没有捕获到用户描述的跳动现场。

回归测试验证两种拖动入口：从最近活动切到手动、保存模式、收到消息后顺序不变；另外验证用户主动选回最近活动后恢复自动排序。测试将新 Agent 放回同一字典条目，与 `agent_update` 的数据替换方式一致，不向真实会话发送消息。

此前两项测试的失败依赖“最近活动模式也必须保持手动顺序”的错误预期，不能作为用户问题已经复现的证据。当前测试聚焦用户确认的模式切换规则。

两项模式切换测试均通过，`xcodebuild test` 退出码为 0。当前 Agent 已自查纠正后的 diff；没有新增生产逻辑或改变持久化格式。

## 本地复现

运行 `xcodegen generate`，随后执行：

```sh
xcodebuild -project Paseo.xcodeproj -scheme Paseo -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/ordering-1537 -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  PASEO_BUNDLE_ID=com.gavin.paseo.ordering-tests \
  -only-testing:PaseoTests/SidebarOrderingTests test
```

测试使用独立 bundle ID 和既有的测试连接隔离设置。模型测试不等于已验证实际鼠标拖放、菜单显示与重启恢复；这些仍需现场验收。没有安装、推送或发布新版。

## 新建会话跳顶补修（#1548，2026-11-06）

此前只覆盖已有会话收到消息，没有覆盖新工作区和新项目。`manualOrder` 明确将未记录项放在前面；手动模式下后续出现的项目和工作区也没有及时进入持久化顺序。直接从菜单切换到手动模式还会跳过拖动入口的顺序快照。

本次调整：已记录项保持位置，新增项追加；侧栏结构变化时补记新项目和工作区，不删除筛选隐藏项；菜单切换手动模式也先保存当前顺序。监听放在滚动容器上，保留 `LazyVStack` 内直接的 `ForEach`，避免破坏按需渲染。

针对性回归覆盖：拖动切换模式、旧会话更新、新项目、新工作区、连续新增、重建模型后恢复、菜单切换与搜索筛选。使用独立 bundle ID 和内存 HostStore，不向真实会话发消息。实际另一台 Mac 的新建交互仍需安装后验收；未推送或发布。
