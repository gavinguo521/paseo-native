# 四处交互路径的性能验证（#1556）

2026-11-07。基线 `eba03b913d5eba8c70022fe34fc6b6f37a3b42ec`。使用 Release 优化构建，加 DEBUG 仅启用测试入口；独立 bundle ID `com.gavin.paseo.performance-tests` 与配对存储，不连接真实 daemon、不替换日常安装版本。

## 实现与边界

1. **文件搜索**：`FileSearchIndex` actor 缓存当前文件的分行及小写文本；查询、索引准备都离开主线程。视图只读取结果数组，避免 `matchLines` 在同一轮渲染中反复扫描全文。查询变化立即隐藏旧匹配，取消旧任务，不发布过期结果。文件头行数在加载时后台计算一次。首次搜索包括索引准备成本，缓存随文件视图生命周期释放。
2. **流式 Markdown**：仅对已识别且尚未闭合的代码围栏采用增量路径，保留前面块，只检查追加内容是否出现闭围栏。使用 UTF-8 前缀确认真实追加，避免反复按字符遍历旧文本。重写、截短和闭围栏回退原解析；含 CR 的尾部不建立快路径，避免混合 LF/CRLF 分行语义差异。列表、表格、普通长段落的解析方式未改。
3. **滚动锚点**：同一版显示条目连续查询可见 ID 时，第三次起建立位置索引，只在一屏 ID 中找最早条目；条目更新即失效。每版只查一次的流式场景仍用原扫描，不为每个增量额外建全量索引。已有的非观察阅读偏移和阅读恢复流程保持不变。
4. **会话回切**：最近八个会话复用 `DisplayItemCache`，键包含机器和会话 ID；展示结果继续按全局唯一的时间线/行 revision 以及折叠、运行状态、推理显示设置失效。缓存淘汰仅丢派生结果，不修改阅读位置和网络订阅。仍在显示的窗口可以继续持有自己的缓存引用。

## 对照数据

同进程、同样本比较旧算法与新算法；代码位于 `InteractionPerformanceTests`，旧 Markdown 缓存仅存在测试目标。

| 场景 | 原实现 | 新实现 | 含义 |
| --- | ---: | ---: | --- |
| 20,000 行，9 个查询（含中文、emoji、空查询） | 435 ms | 251 ms | 累计查询；新路径包括首次索引准备和 actor 等待。每查询只算一次旧扫描，未用多次 UI 属性读取放大收益。 |
| 未闭合代码块 4,000 行，追加 80 次 | 175 ms | 16 ms | 仅 Markdown 块派生，不包含着色、布局、网络。 |
| 3,000 条显示内容，300 次可见锚点查询 | 44.8 ms | 1.09 ms | 累计 CPU 路径，新值包括索引建立；平均单次节省约 0.15 ms。不是滚动帧率。 |
| 30 次重复会话显示派生 | 48.3 ms | 0.023 ms | 只测已有历史的派生缓存命中。 |
| 实际 AgentView 回切首布局，7 次合计 | 360 ms | 338 ms | 此轮约 6%，每次约 3 ms；页面布局仍占主要时间，不是数量级提速。 |

最终修复后复测：搜索 446 → 254 ms，代码尾部 179 → 17 ms，锚点 46.1 → 1.12 ms，派生缓存 49.8 → 0.023 ms，实际页面回切 383 → 373 ms（约 3%）。因此回切收益表述为约 3%–6%，没有证明切换体感会明显改变。

原生页面对照使用真实 `AgentView`、固定离线 HostStore 和 1,500 回合数据。每轮新建视图模拟回切，交替冷/热顺序，并排除首轮 SwiftUI/字体预热。它不包含真实服务端订阅、网络补页，也不代表历史任意位置恢复或所有窗口状态。

## 验证

最终 Mac 三个相关套件共 16 项通过，iOS 两个相关套件共 2 项通过。

- 搜索与原实现结果逐项一致；覆盖大小写、中文/emoji、空查询、缺失结果、文件替换以及取消任务后不返回旧搜索结果。
- Markdown 逐字符追加、重写、截短、围栏闭合、混合换行与完整解析一致；另有评审发现的两片段回归，防止闭合代码块吞入普通正文。
- 可见锚点与原顺序扫描一致；条目替换后索引失效；缓存复用、淘汰和展示设置变化保持正确。
- 原有时间线窗口/阅读恢复、增量 Markdown/回合派生及协议流回放套件继续执行。
- iOS 模拟器执行原生大文件选择/跳转和现有界面布局回归。
- 独立静态评审发现一项混合换行正确性问题，已修复并通过增量复审。

这些测试没有测量真实触控/键盘事件到屏幕呈现的延迟、GPU 掉帧或真机 120 Hz。结论限于上述固定样本；文件搜索和代码尾部解析减轻工作量最明确，会话回切属于小幅优化。

## 复现

```sh
xcodegen generate
xcodebuild -project Paseo.xcodeproj -scheme Paseo -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/responsiveness-1555 -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
  PASEO_BUNDLE_ID=com.gavin.paseo.performance-tests \
  -only-testing:PaseoTests/InteractionPerformanceTests \
  -only-testing:PaseoTests/TimelinePerformanceTests \
  -only-testing:PaseoTests/StreamReplayTests test
```

iOS 使用 `PaseoMobile`、独立 derivedDataPath、模拟器 destination，筛选 `PaseoMobileTests/FileSourceTests` 和 `PaseoMobileTests/MobileFeatureTests`。日志里的 `INTERACTION` 为实测值，测试总数及结果须以 Swift Testing 汇总为准。
