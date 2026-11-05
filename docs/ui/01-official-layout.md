# 官方 App 布局调研（v0.14.0）→ SwiftUI 映射

来源：`vendor/paseo/packages/app/src`（Expo / React Native，tag v0.14.0）与 `vendor/paseo/docs/*.md`。

引用约定：
- 不带前缀的路径都相对 `packages/app/src/`。
- `docs/xxx.md` 指 `vendor/paseo/docs/xxx.md`。
- 行号以 v0.14.0 为准。

本文只读源码整理，没有截桌面 App 的图。

---

## 0. 先说结论（影响全局的几个事实）

1. **没有独立的"会话页"。** 主界面只有一个：**Workspace 屏**。agent 会话是 workspace 里的一个 **tab**（panel 类型 `agent`）。
   - 路由 `h/[serverId]/agent/[agentId]` 只做一件事：解析出 agent 所属的 workspace，然后 `navigateToAgent({..., pin:true})` 跳过去（`app/h/[serverId]/agent/[agentId].tsx:117`）。
2. **左侧栏的层级是 Project → Workspace，没有 agent 行。** agent 只出现在 workspace 内的 tab 栏里。
   - 侧栏里也没有 host 分区。host 收在侧栏底部的 Hosts 选择器里（`components/left-sidebar.tsx:339-390`）。
3. **宽窄只有一个断点：600pt。**
   - `xs`/`sm`（<600）为 compact：左栏、右栏都是全屏覆盖层，可滑动呼出。
   - `md` 及以上为 wide：左栏、右栏都停靠在内容旁边（`constants/layout.ts:37-49`，`styles/unistyles.ts:6-11`）。
4. **phone 上没有 tab bar，也没有 drawer navigator。**
   - 整体是一个扁平的 native stack，所有 header 都隐藏、不带动画（`app/_layout.tsx:786-816`）。
   - 左右两栏是自绘的滑动覆盖层（`mobile-panels/`）。
   - 其余浮层统一用 bottom sheet。
5. **权限请求嵌在时间线里显示，不弹 modal**（`agent-stream/view.tsx:1014-1025, 1513-1733`）。
6. 图标库是 **lucide**（`lucide-react-native` ^1.50.0），stroke 宽 1.5。

---

## 1. 整体结构

### 1.1 断点与外壳

| 项 | 值 | 引用 |
|---|---|---|
| 断点 | xs 0 / sm 576 / md 600 / lg 992 / xl 1200 | `styles/unistyles.ts:6-11` |
| compact 判定 | breakpoint ∈ {xs, sm}，即宽度 < 600 | `constants/layout.ts:37-49` |
| 分屏（split pane） | 只有 web/Electron 有，原生 iPad 没有 | `constants/layout.ts:54` |
| Header 内高 | 桌面 36，移动 56 | `constants/layout.ts:9-10` |
| 二级 header（tab 行） | 36 | `constants/layout.ts:11` |
| macOS 红绿灯避让区 | 78×45 | `constants/layout.ts:26-27` |
| 聊天列最大宽度 | 820 | `styles/theme.ts:648` |

外壳组件的嵌套：`AppShell` → `MobilePanelsProvider` → `AppWithSidebar` → `RootStack`（`app/_layout.tsx:830-844`）。

`AppContainer`（`app/_layout.tsx:345-512`）按宽窄分两种渲染：
- wide：`SidebarChrome` 排在内容左侧（:448）。
- compact：`SidebarChrome` 放在内容之后，作为覆盖层（:484）。

两种外壳的 testID 分别是 `wide-shell` 和 `compact-shell`（:571）。

### 1.2 左侧栏（宽屏）

**宽度**
- 默认 320，可拖拽调到 200–600，宽度持久化（`stores/panel-store/state.ts:17-19`，拖拽柄在 `components/left-sidebar.tsx:677-710, 797-801`）。
- 实际可见宽度另有上限：`视口宽 − 400`（`components/desktop-sidebar-layout.ts:5, 40-64`）。

**能否显示**
- 前提是剩余宽度够内容区最小宽度：内容区最少 600（右栏 explorer 可见时），Settings 页则最少 720（`components/desktop-sidebar-layout.ts:7-21, 66-72`）。
- 不够时左栏会"让出宽度"：仍然挂载，但 `display:none`（`docs/mobile-panels.md`）。

**折叠**
- 由 `desktop.agentListOpen` 控制，Cmd+B 切换。
- 默认值：web/Electron 打开，原生（包括 iPad）关闭（`stores/panel-store/index.ts:95, 113`）。
- Focus mode（Cmd+Shift+F）会同时隐藏左栏（`stores/panel-store/index.ts:127-134`）。

**背景色**：`surfaceSidebar`。浅色是 #f4f4f5，深色是 #141716，比主内容区更暗一级。

**自上而下的内容**（`components/left-sidebar.tsx`，桌面版是 `DesktopSidebar`:621）：

1. **Header 导航行**（`SidebarNavRows`）。默认四项，依次是：

   | 项 | 图标 | 动作 |
   |---|---|---|
   | New workspace | `Plus` | 新建 workspace |
   | History | `History` | Sessions 历史页 |
   | Search | `Search` | 打开 command center |
   | Schedules | `CalendarClock` | Schedules 页 |

   用户可以重排、隐藏；插件可以追加（`sidebar-nav/model.ts:10-13, 93-120`；`components/sidebar/sidebar-nav-rows.tsx:2`）。

2. **"Workspaces" 分区标题**，右侧带一个 Display preferences 菜单（:808-821）。菜单里可以设：
   - 分组：project / status
   - 排序：manual / created / lastPrompt
   - host 过滤
   - Show 子菜单：Host、Services 等

3. **workspace 列表**（`SidebarWorkspaceList`）。

4. **Sidebar callout 槽**：更新提示、worktree 设置等全局提醒，只在桌面出现。

5. **Footer**（:431-458）：
   - 一行 "Add project"（`FolderPlus`）。
   - 可选的 Usage 行，默认隐藏。
   - 一排图标：**Hosts**（`Server`）、Help、Settings。

### 1.3 workspace 列表：分组、排序、状态

**分组模式**：`"project" | "status"`，默认 `project`，排序默认 `created`（`stores/sidebar-view-store.ts:9, 135-137`）。

**project 模式**
- 结构是两层：Project 行（可折叠）→ Workspace 行。
- Project 排序：按名称 `localeCompare`（numeric），再叠加用户拖拽保存的顺序（`projects/workspace-structure.ts:115-121`，`stores/sidebar-order-store.ts`）。
- Workspace 排序：
  - `created`：创建时间倒序。
  - `lastPrompt`：最后一次人类 prompt 的时间倒序，没有 prompt 时用创建时间（`projects/workspace-structure.ts:218-231`）。
  - `manual`：拖拽顺序。
  - 以上都不适用时按名称（:208-215）。
- 时间排序要求所有 host 都支持 `workspaceSortTimes` 能力（`hooks/use-sidebar-workspaces-list.ts:143-149`）。

**status 模式**
- 按状态桶分组，组的显示顺序是 `needs_input, failed, attention, running, done`（`STATUS_BUCKET_ORDER`，`utils/sidebar-agent-state.ts:35-45`）。
- 组内按 `statusEnteredAt` 倒序，再按项目名、workspace 名（`hooks/sidebar-status-view-model.ts:57-82`）。

**Pinned**
- 置顶的 workspace 单独成为最上面一个可折叠分区（`components/sidebar/sidebar-projection.ts:52-73`）。
- Cmd+Shift+P 切换置顶。

**数量限制**
- 每组先显示 7 行 workspace（pinned 分区是 20 行），其余收进 "show more"。
- 未完成（非 done）的 workspace 总是显示（`components/sidebar/sidebar-group-visibility.ts:24-28`）。

**Cmd+数字徽标**：前 9 行显示 Cmd+1…9 快捷键徽标（`hooks/sidebar-status-view-model.ts:84-95`）。

**Workspace 行结构**（`components/sidebar/sidebar-workspace-row-content.tsx:136-173`）：

```
[状态指示器] 标题（单行截断）                 [trailing: diff stat / 快捷键徽标 / kebab]
             meta 行：branch · PR 徽标 · CI checks · service · labels · host 徽标
```

- **状态指示器在左侧**（leading）。实心点直径 6pt，占位 8pt；needs_input 时换成 12pt 的 `CircleAlert`（`utils/status-indicator-geometry.ts`）。
- 行样式：
  - `minHeight` 在 compact 下 44、桌面 36（`styles/density.ts:24`）。
  - padding 为纵 8、左 8、右 12。
  - `borderRadius.lg` = 8。
  - 行间距 2（`components/sidebar-workspace-list.tsx:2747-2760`）。
- 标题字号 `fontSize.base`，字重 normal。选中行背景 `surface2`，hover 背景 `surfaceSidebarHover`。
- 有 hover card（`WorkspaceHoverCard`）。kebab 在桌面 hover 时显示，触屏上常驻（`docs/design.md` §12）。

**状态桶 → 圆点颜色**（`utils/sidebar-agent-state.ts:7`，`utils/status-dot-color.ts:18-31`）：

| bucket | 含义 | 点颜色 |
|---|---|---|
| `needs_input` | 等待权限或提问 | `statusDotWarning`（琥珀色）+ CircleAlert |
| `failed` | 出错 | `statusDotDanger`（红） |
| `running` | 运行中 | `statusDotRunning`（蓝），用 `StatusRing` 动画（`components/status-icon.tsx:39-73`） |
| `attention` | 已完成但没看过（**这就是"未读"**） | `statusDotSuccess`（绿） |
| `done` | 空闲且已读 | 不画点 |

- Project 行折叠后，只显示它下面最紧急的那个状态，优先级为 needs_input > failed > running > attention > done（`utils/sidebar-agent-state.ts:23-29`）。
- 未读的处理：点开 workspace 清除 attention。done 状态的行可以 "Mark as unread"，需要 host 支持 `workspaceMarkUnread`（`hooks/use-workspace-read-state.ts:22-25`，`components/sidebar/sidebar-workspace-row.tsx:125-174`）。
- Archive 是行操作，归档后的 workspace 不再列出。只有 worktree 有未提交或未推送内容时才弹确认（`docs/design.md` §14）。

### 1.4 主内容区（Workspace 屏）

`screens/workspace/workspace-screen.tsx` 自上而下：

1. **Header**（36 高）
   - 左侧：workspace 名（`ScreenTitle`）和 project 名（`workspace-header-source.ts:44-51`，`workspace-screen.tsx:512-521`）。
   - 右侧依次为（:3200-3240）：
     - 插件按钮
     - Scripts（workspace 有脚本时才显示）
     - Open in editor
     - git split button（`git/workspace-actions.tsx:10`）
     - Explorer 开关
2. **Tab 行**（36 高）
   - 每个 tab 显示 provider 图标、agent 标题和状态点。
   - tab 种类（`workspace-tabs/model.ts:35-49`）：`draft`、`agent`、`terminal`、`browser`、`changes_tree`、`files`、`pull_request`、file、`working_diff` 等。
   - "+" 菜单的顺序：agent, terminal, changes, diff, files, browser, pullRequest（`workspace-tabs/launcher/internal/catalog.ts:1-9`）。
   - tab 右键菜单（`workspace-desktop-tabs-row.tsx:1101-1126`）：Copy resume command / Copy agent ID / Rename / Close others / Reload agent / Close 等。
   - 关闭运行中的 agent 需要确认（`workspace-screen.tsx:1973`）。
3. **Pane 区**：web 上可以左右、上下分屏（`SplitContainer`，`workspace-screen.tsx:3476`）。原生只有单个 pane。

### 1.5 右侧栏（Explorer sidebar）

- 内容是三个视图：**Changes**（git 变更树）、**Files**（文件树）、**PR**，对应 tab target `changes_tree`、`files`、`pull_request`（`workspace-tabs/explorer-sidebar.ts:11-15`）。
- 宽度默认 320、最小 240。workspace 主体至少保留 360，所以总宽不到 600 时无法停靠（`components/explorer-sidebar-layout.ts:1-4`）。
- 呈现方式：compact 下是 `overlay`，wide 下是 `dock`（`workspace-tabs/explorer-sidebar.ts:22-29`）。
- Cmd+E 或 Ctrl+` 切换（`keyboard/keyboard-shortcuts.ts:929, 951`）；Cmd+. 同时切换左右两栏（:959）。
- 文件、diff 也可以作为普通 tab 在主 pane 打开（"side pane"，见 `docs/explorer-sidebar.md`）。
- terminal 不在右栏，它是 workspace 里的一个 tab。

---

## 2. 导航模型：phone 与宽屏对比

### 2.1 路由（expo-router，`src/app`）

```
index.tsx                     启动分发（见下）
welcome.tsx                   首次使用：添加 host
new.tsx                       New workspace 表单
open-project.tsx              打开/添加项目
sessions.tsx                  历史会话（History）
schedules.tsx                 定时任务
pair-scan.tsx                 扫码配对（expo-camera）
settings/[section].tsx        设置（general / ...）
settings/hosts/[serverId]/[hostSection].tsx   单个 host 设置（connections 等）
h/[serverId]/index.tsx        → 恢复上次的 workspace
h/[serverId]/workspace/[workspaceId]/index.tsx   主界面
h/[serverId]/agent/[agentId].tsx  → 解析后跳到所属 workspace 并激活该 tab
```

**启动分发**（`navigation/host-runtime-bootstrap.ts:180-215`），按顺序判断：
1. 有上次选中的 workspace → 进入它所在 host 的根路由，由 host 根路由负责恢复那个 workspace。
2. 否则，有在线 host → 进第一个在线 host。
3. 否则，有已保存的 host → 进第一个保存的 host。
4. 都没有 → `/welcome`。

### 2.2 Phone（compact，<600）

**三个互斥位置**，用同一个归一化位置值描述（`docs/mobile-panels.md`，`mobile-panels/model.ts:24-33`）：

| 位置 | 内容 | 归一化值 |
|---|---|---|
| `agent-list` | 左栏，即 workspace 列表 | −1 |
| `agent` | 中间，当前 workspace 的当前 tab | 0 |
| `file-explorer` | 右栏，Explorer | 1 |

- 左右两栏都是**全屏宽**覆盖层，滑入时背后有 `rgba(0,0,0,0.5)` 的遮罩（`mobile-panels/model.ts:161-169`）。
- 手势规则：
  - 水平位移 ≥15px 且大于纵向位移，手势才激活（`mobile-panels/gesture-intent.ts:17-21`）。
  - 拖过屏宽 1/3，或速度 > 500，即提交切换（`mobile-panels/gestures.ts:104, 197`）。
  - 在内容区左滑打开 Explorer（`app/_layout.tsx:453`）。
- 冷启动总是停在 `agent` 位置，面板选择不持久化。
- 左栏顶部第一行带关闭按钮（`components/left-sidebar.tsx:548-578`）。点选 workspace 后左栏收起，回到中间。

**Compact header**（`CompactWorkspaceHeader`，`workspace-screen.tsx:3381-3426`）：
- 左侧：汉堡按钮，打开左栏。
- 中间：`MobileWorkspaceTabSwitcher`（`screens/workspace/compact-workspace-header/tab-switcher.tsx:279`）。它是一个下拉，列出本 workspace 的 agent / terminal tab，也能新建 draft 或 terminal。**phone 上没有横向 tab 栏**。
- 右侧：`WorkspaceHeaderMenuMobile` 的 "…" 菜单（`workspace-header-menu.tsx:89-140, 226-315`）。菜单项包括 Copy path、Copy branch、Import session、Scripts、Terminal profiles 等。

**Sheet**
- 全局只有一个 bottom sheet 栈（`IsolatedBottomSheetModal`），从 sheet 里再开 sheet 会叠在上面（`docs/glossary.md` "Sheet"）。
- compact 下，文件和 subagent 用 "sheet tab" 打开，不进入 tab 切换器；sheet 头部有 "Open as tab" 和 "Close"（`docs/explorer-sidebar.md#sheets`）。
- 以下内容在 compact 下都走 sheet：
  - 工具调用详情（`components/message.tsx:2320-2330`）
  - model / mode / thinking 选择（`SheetAgentControlsContent`）
  - 右键菜单（`ContextMenu` 默认用 sheet）
  - Usage
  - 添加 host

### 2.3 宽屏（≥600，Mac / iPad 横屏）

- 三栏：左栏（可折叠、可调宽）、主区（header + tab 行 + pane）、右侧 Explorer（可折叠、可调宽）。
- 菜单用 popover，子菜单 hover 约 90ms 后展开（`docs/menus.md:123-136`）。
- 工具调用在时间线内**原地展开**（详情最高 400）。
- Settings 宽屏时是 list+detail 分栏（320 + ≥400，`constants/layout.ts:19-22`）。
- 官方原生 iPad 也走 wide shell，但左栏默认收起、没有分屏。

---

## 3. Agent 会话（agent tab）

### 3.1 "Header"

agent tab 没有独立的 header。屏幕顶部是 **workspace header**（§1.4）。agent 自身的信息分布如下：

**tab 标签**（`agent-presentation/index.ts:32-87`）
- label 是 agent 标题。标题为空或是 "new agent" 时，显示加载态。
- subtitle 是 `"<Provider> agent"`，icon 是 provider 图标。
- 状态桶由 `deriveSidebarStateBucket` 算出（:73-80），用的是与侧栏同一套颜色。

**provider / model / mode / thinking**
- **不在 header 里**，而是在 composer 工具栏左侧的 Agent controls 里（§3.3）。
- 只有在没有 composer 的场景（例如 sheet 里只读查看）才显示一行事实信息，格式为 `model · thinking · mode · "12k / 200k tokens (6%)"`（`panels/agent-facts-line.ts:26-37`，`panels/agent-panel.tsx:1196, 1328-1331`）。

**面板状态**（`panels/agent-panel.tsx`）

| 状态 | 表现 | 引用 |
|---|---|---|
| 加载中 | 加载态 | :213-255 |
| 找不到 | "Agent not found" | :213-255 |
| 加载出错 | 错误信息 + Retry | :213-255 |
| 归档中 | 覆盖层 | :1268 |
| 同步出错 | 同步错误 callout + Retry | :1300-1320 |
| 已归档 | `ArchivedAgentCallout` 取代 composer | :1465 |
| 是 subagent | 顶部显示 `ParentAgentCallout` | :1171 |

### 3.2 时间线

**条目种类**（`types/stream.ts:85-89`）：`user_message`、`assistant_message`、`thought`、`tool_call`、`todo_list`、`notification`、`compaction`、`plugin`。分发逻辑在 `agent-stream/view.tsx:928-985`。

| 条目 | 呈现 | 引用 |
|---|---|---|
| 用户消息 | 见下方说明 | `components/message.tsx:294-340, 392+` |
| 助手消息 | 见下方说明 | `components/message.tsx:1144+, 594+` |
| Thinking | 一个 "Thinking" 徽标行，**默认折叠**；设置 `autoExpandReasoning`（默认 false）可改为展开 | `agent-stream/view.tsx:1410-1433`；`hooks/use-settings/storage.ts:162` |
| 工具调用 | **默认折叠**的徽标行：名称 + 摘要；运行中有 shimmer 或 spinner，失败时是错误色 | `components/message.tsx:2250-2423` |
| 连续工具调用 | 合并成一行，见"折叠层级" | `agent-stream/view.tsx:875-925`；`tool-calls/detail-level/overview/label.ts:23-50` |
| Plan | `PlanCard` 卡片，不是徽标 | `message.tsx:2378-2386` |
| Todo | `TodoListCard`，可展开徽标，默认折叠；composer 上方还有 Tasks track 悬浮 pill | `message.tsx:1471`；`panels/agent-tracks.tsx:5` |
| 通知 / 错误 | info/warning/error 三色横幅 | `message.tsx:1325+` |
| Compaction | "Compacting..." / "Context compacted (N K tokens)" 分隔标记 | — |
| Subagent | `sub_agent` 工具调用徽标；composer 上方有 Subagents track pill，列出子 agent，可 Detach/Archive | `subagents/track.tsx:71-370` |

**用户消息**
- 右对齐气泡：背景 `surface3`，圆角 16，但右上角是 2；内边距 16；字号 `fontSize.content`。
- 支持图片缩略图和附件。
- 下方一行：时间戳、Rewind 菜单、复制。
- 同一组消息之间间距 4，组前后间距 16。
- agent 之间互发的消息显示 "Sent by {name}"（`agent-stream/presentation.ts:87-104`）。

**助手消息**
- 无气泡，全宽 Markdown（`MarkdownRenderer`），流式渐显。
- 每个 turn 的结尾有 footer：复制、Fork 菜单，以及 "Worked for {duration}"。
- turn 运行中，footer 改为显示实时计时（`agent-stream/turn-footer.tsx:44-86`）。

**工具调用详情**
- 摘要内容来自 `packages/protocol/src/tool-call-display.ts:84-146`：

  | 工具 | 摘要 |
  |---|---|
  | Shell | 命令 |
  | Read / Edit / Write | 相对路径 |
  | Search | 查询词 |
  | Fetch | url |
  | Task | 描述 |

- 展开后的内容（`components/tool-call-details.tsx`）：

  | 工具 | 展开内容 |
  |---|---|
  | shell | `$ cmd` 代码块（:161-177） |
  | edit | `DiffViewer`（:374-377） |
  | read | 高亮代码 |
  | 其他 | key/value |

- 交互：宽屏原地展开，最高 400；compact 下点击打开 bottom sheet（`message.tsx:2320-2330`）。

**折叠层级**：设置 `chatDisplay`，默认 `collapseTurns`（`hooks/use-settings/storage.ts:163`）。
- 连续的工具调用和 thinking 合并成一行 `OverviewToolCallGroupView`，文案形如 "Edited 2 files, ran 3 commands, and read 1 file"，默认折叠。
- `collapseTurns` 下，已完成的 turn 收进用户消息下方的一行 `TurnSummaryLine`（`agent-stream/turn-collapse/summary-line.tsx:20`）。最新一个 turn 保持展开（`agent-stream/presentation.ts:106-140`）。

**权限请求（嵌在时间线里）**
- `PermissionRequestCard` 渲染在列表的 *live head*，即时间线最底部、turn footer 之上（`agent-stream/view.tsx:116-155, 1014-1025`）。
- 卡片内容：
  - 标题：取 `request.title`；没有时用 "Permission Required"；plan 类请求标题是 "Plan"。
  - 描述。
  - 工具详情，最高 200。
  - 提示语 "How would you like to proceed?"。
  - 按钮。
- 按钮：优先用 provider 给的 `request.actions`。没有时默认两个：
  - **Deny**（danger，`X` 图标）
  - **Accept**（primary，`Check` 图标）；plan 类请求叫 **Implement**
  - 见 `agent-stream/view.tsx:1538-1561`。
- 选择 Deny 时附带消息 "Denied by user"（:1625-1641）。
- `kind:"question"` 的请求渲染成多步问答表单 `QuestionFormCard`，按钮为 Next / Submit（`components/question-form-card.tsx`）。
- 待处理期间，侧栏和 tab 的状态都是 `needs_input`（琥珀色）。

### 3.3 Composer

结构：一个输入面（`inputWrapper`）。
- 背景 `surface1`，1px `borderAccent` 描边，圆角 16。
- 上内边距 compact 8 / 宽屏 16，下内边距 compact 8 / 宽屏 12（`composer/input/input.tsx:2259-2275`）。
- 内部自上而下：
  1. attachment tray（附件 pill）
  2. 文本输入。最大高度 160，宽屏为 `max(160, 窗口高×0.5)`（:218-220, 1047-1049）
  3. 工具栏

composer 上方可能浮出 Queue track、Subagents track、Tasks track（见 `docs/glossary.md` "Composer track"）。

**工具栏**

| 位置 | 内容 |
|---|---|
| 左 | Agent controls：model（`CombinedModelSelector`，含 agent profiles）、thinking、mode（**只显示图标**）、provider 特性开关，如 plan_mode、fast_mode（`composer/agent-controls/index.tsx`，`policy.ts:3-5`）。已存在的 agent **不能换 provider**；draft 多一个 provider 选择（:958-982）。compact 下合并成一个 sheet。 |
| 右 | "+" 附件菜单、麦克风（听写）、主按钮 |

**"+" 附件菜单**（`composer/index.tsx:2159-2200`）：Add image、Paste image、Add GitHub issue/PR、插件项、Add file。web 上还支持粘贴图片和拖拽文件。

**主按钮**：28×28 圆形，`accent` 填充（`input.tsx:2370-2425`，状态切换在 :867-893）。

| 条件 | 显示 |
|---|---|
| 有内容 | Send，`ArrowUp` 图标 |
| 输入为空且 agent 运行中 | Stop，实心白色 `Square`；正在取消时显示 spinner；tooltip 为 "Interrupt"（`composer/index.tsx:1092-1128`） |
| 其他 | 不显示按钮 |

New workspace 页的主按钮用 `CornerDownLeft` 图标，或文字 "Create"。

**快捷键**
- Enter 发送，Shift+Enter 换行。可以改成 Cmd+Enter 发送（`sendShortcut`）。IME 组字期间忽略 Enter（`composer/input/state.ts:167-176`）。
- Esc 中断 agent（`keyboard/keyboard-shortcuts.ts:1054-1170`）。

**运行中再发送**：设置 `sendBehavior`，默认 `steer`（`hooks/use-settings/storage.ts:145`）。
- 默认动作：steer，即把消息注入当前 turn（`composer/index.tsx:1539-1594`）。
- 备选动作：queue，由 Cmd+Enter 或长按发送键触发（`composer/input/state.ts:135-151`）。
- 排队的消息显示在 Queue track 里，可 Edit 或 Send now。
- 按钮的无障碍文案：Send message / Send and steer / Send and interrupt / Queue message（`composer/input/labels.ts:5-24`）。

**Placeholder**：宽屏 "Message the agent, tag @files, or use /commands and /skills"，phone 上 "Message, @files, /commands"。

**补全**
- `/` 和 `@` 弹出补全，合并 provider 的命令与 skills 和插件命令（`hooks/use-agent-autocomplete.ts`）。
- 客户端内置命令（`client-slash-commands/index.ts:17-36`）：
  - `/exit`：归档 agent。
  - `/clear`：归档 agent 并新开一个 draft。

### 3.4 滚动

- 原生端用倒置的 `FlatList`（`agent-stream/strategy-native.tsx:581-631`）。流式内容、权限卡、footer 放在 `ListHeaderComponent`，也就是视觉上的最底部。
- 贴底模式有两种：`sticky-bottom` 和 `detached`（`bottom-anchor-controller.ts:4`）。距底部 32px 以内算"在底部"（`strategy-native.tsx:270-276`）。
- 不在底部时，淡入一个圆形 `ChevronDown` "回到底部"按钮（`agent-stream/view.tsx:1240-1254`）。
- 历史分页：
  - 先挂载最近约 20 条（`history-window.ts:4`）。
  - 距顶部 96px 时，先展开内存里已有的条目，再向服务器取更早的（`use-stream-history-window.ts:117-121`）。
  - 每页 40 条，按整 turn 取（`timeline/timeline-sync-plan.ts:67-75`）。
- 另有 chat outline（跳到某条 prompt）和会话内查找（`agent-stream/chat-outline/`、`chat-find/`）。

---

## 4. Workspace 概念与新建流程

**Workspace 和 agent 的关系**
- workspace = 某个 daemon 上的一个 cwd（附带 git 状态），属于一个 project（`docs/glossary.md`）。
- **Workspace 屏**是容器：header 显示 workspace 和 project 名、git 操作、脚本；tab 行放多个 agent / terminal / 文件 / diff；右栏是 Explorer。
- **Agent** 是其中一个 tab：时间线 + composer。

**在现有 workspace 新建 agent**
- 点 "+" 选 Agent，或按 Cmd+Shift+A / Cmd+O，打开一个 `draft` tab。
- draft tab 就是一个空时间线加 composer，composer 左侧多一个 **provider** 选择器。
- 发送第一条消息时才真正创建 agent。请求结构（`composer/draft/workspace-tab.tsx:150-178`，`composer/draft/create-agent-request.ts:19-35`）：
  ```
  createAgent({ config:{provider, cwd, modeId?, model?, thinkingOptionId?, featureValues},
                workspaceId, clientMessageId, initialPrompt?, images?, attachments? })
  ```
- 没选 provider 时提示 "Select a model"。

**New workspace 屏**（`screens/new-workspace-screen.tsx`）
- 页面标题 "New workspace"，用 `fontSize["2xl"]`，是全 App 唯一的大标题。
- 表单字段依次是（`screens/new-workspace/form/index.tsx:204-280`）：

  | 字段 | 说明 |
  |---|---|
  | Project | |
  | Host | |
  | Isolation | Local / New worktree，host 支持 worktree 时才显示 |
  | Branch | "Start from"：可搜分支和 PR；选 worktree 时显示 |
  | Launch | Chat，或某个 Terminal profile |

- 表单下方是同一个 composer（带 provider / model / thinking / mode），主按钮 "Create"，允许空提交。旁边还有 Import session。
- 调用 `client.createWorkspace`（:283-328）：
  - source 是 `{kind:"worktree", ...}` 或 `{kind:"directory", path, projectId}`。
  - 同时带上 agent config 和首条 prompt。
- 上次的选择会被记住：provider、各 provider 的 model/mode/thinking、isolation、launch target（`create-agent-preferences/preferences.ts:6-52`）。默认 model 的解析在 `provider-selection/resolve-agent-form.ts`。

**Add project**：从侧栏底部进入，或从 `/open-project` 进入。选择 host 和目录，生成一个 project。

---

## 5. Host 管理

**添加 host**
- 入口有三处：
  - 首次使用的 Welcome 页（`components/welcome-screen.tsx:216-270`）。
  - Settings → Add host（`/settings/general?addHost=…`，`utils/host-routes.ts:556-557`）。
  - Hosts 选择器底部的 "Add host"。
- `AddHostMethodModal`（`components/add-host-method-modal.tsx`）提供四种方式：

  | 方式 | 说明 | 限制 |
  |---|---|---|
  | **Scan QR code** | "Encrypted relay connection"。原生端排第一、是主按钮 | 仅原生 |
  | **Direct connection** | 字段：Host、Port、Password（可选）、Use SSL，Advanced 里可填 Connection URI | — |
  | **Paste pairing link** | 支持 `#offer=`、`#connect=`、`relay://` 三种格式（`hosts/pair-scan-model.ts:97-102`） | — |
  | Remote SSH | | 仅 Electron |

- 配对流程的状态：scanning → pairing → connected，或进入 passwordRequired / stopped（`hosts/pair-scan-model.ts:34-95`）。
- 连接信息有变化时，用 `HostConfirmationSheet` 确认。
- 深链由 `OfferLinkListener` 处理，导入后跳到 `/open-project`（`app/_layout.tsx:611-640`）。

**Host 切换器**
- 位于侧栏底部的 `Server` 图标，点开是一个 popover（最小宽 240，向上弹出，可搜索）。
- 列表顺序：本机 host、其他 host、"Add host"（`components/hosts/host-picker.tsx:186-230`）。
- **选中某个 host 是进入该 host 的设置页**，不是"切换视图"（`components/left-sidebar.tsx:351-356`）。

**连接状态**
- 状态值：`idle | connecting | online | offline | error`（`runtime/host-runtime.ts:95`）。
- `HostStatusDot` 是 8px 圆点：online 绿、connecting 琥珀、其余红（`components/host-status-dot.tsx:8-35`）。

**多 host 合并**
- 侧栏**同时显示所有已连接 host** 的 workspace，没有"当前 host"的概念。
- 不同 host 上 `projectKey` 相同的 project 合并成一个显示项目，带 `hosts[]`。若某个 host 内 key 不唯一，则退回用 `serverId:projectId` 作 key（`projects/workspace-structure.ts:153-188`）。
- workspace 的 key 是 `${serverId}:${workspaceId}`（:97）。
- 只有可见内容跨 ≥2 个 host 时，行上才显示 host 徽标（`hooks/sidebar-workspaces-view-model.ts:461-471`）。徽标颜色取自 identity 色表（`styles/identity-colors.ts`）。
- Display preferences 里的 host 过滤：空数组表示全部；只有多于一个 host 时才出现这一项（`stores/sidebar-view-store.ts:53-54`，`components/sidebar/display-preferences/menu.tsx:184`）。

---

## 6. 视觉 Token（`styles/theme.ts`）

### 6.1 颜色

默认浅色主题见 `theme.ts:323-345`，默认深色主题 "Paseo"（深色偏青绿）见 `theme.ts:460-477`。

| 角色 | Light | Dark |
|---|---|---|
| surface0（背景 / 弹层） | #ffffff | #181B1A |
| surface1（composer 底，深色下也是 workspace 底） | #fafafa | #1E2120 |
| surface2（muted / input / 侧栏选中） | #f4f4f5 | #272A29 |
| surface3（用户气泡 / secondary 按钮） | #e4e4e7 | #434645 |
| surface4 | #d4d4d8 | #595B5B |
| surfaceSidebar | #f4f4f5 | #141716 |
| foreground | #1a1a1e | #fafafa |
| foregroundMuted | #71717a | #A1A5A4 |
| foregroundExtraMuted | #a1a1aa | #717574 |
| border | #e4e4e7 | #252B2A |
| borderAccent | #ececf1 | #2F3534 |
| accent（主 CTA / 发送键） | #20744A | #20744A |
| accentBright | #239956 | #7ccba0 |
| accentForeground | #ffffff | #ffffff |
| destructive | #b04138 | #c64f43 |
| interactionHighlight（hover / 按下） | rgba(0,0,0,0.06) | rgba(255,255,255,0.08) |

**状态点**（`theme.ts:204-218`）：

| token | Light | Dark |
|---|---|---|
| statusDotSuccess | #299f51 | #35c264 |
| statusDotDanger | #f12e2f | #f7796d |
| statusDotWarning | #b37824 | #db932e |
| statusDotRunning | #268ae0 | #5caaf6 |

**状态文字**（PR / CI / diff stat 用，`theme.ts:146-159`）：

| token | Light | Dark |
|---|---|---|
| statusSuccess | #3e704a | #6cb17b |
| statusDanger | #9d433b | #d8847b |
| statusWarning | #7b5d39 | #c09664 |
| statusMerged | #7347af | #a890d5 |

对应的浅底色是同色加透明度：浅色 12%，深色 16%（:165-174）。

**diff 颜色**（:116-124）：

| | Light | Dark |
|---|---|---|
| 新增 | #15803d | #4ade80 |
| 删除 | #b91c1c | #ef4444 |

**其他深色主题**：zinc、midnight、claude、ghostty、pureBlack（:480-541, 721）。v1 不做。

### 6.2 字体与排版

- **字号**（`theme.ts:577-607`）：

  | token | 值 |
  |---|---|
  | code | 12 |
  | sm | 12 |
  | base | 14 |
  | content（消息正文 / 输入框 / Markdown） | 15 |
  | lg | 16 |
  | xl | 18 |
  | 2xl | 20 |
  | 3xl | 22 |
  | 4xl | 26 |

  新装的原生端：base 默认 15，content 默认 16（`docs/design.md:33`）。
- **字体**：iOS 用 `system-ui`（即 SF），等宽用 `ui-monospace`（SF Mono）。
- **字重**只分三档（`docs/design.md` §3）：
  - 屏幕标题用 `ScreenTitle`：base 字号，compact 下字重 400，桌面 **300**。
  - 分区标签、modal 标题用 medium（500）。
  - 其余一律 normal。
- **层级**靠颜色 foreground / foregroundMuted 区分，不靠字号。
- **行高**：diff 行 22；用户气泡在 web 上为 content × 1.4。

### 6.3 间距、圆角、尺寸

| 类别 | 值 | 引用 |
|---|---|---|
| Spacing | 0.5:2, 1:4, 1.5:6, 2:8, 3:12, 4:16, 6:24, 8:32, 12:48；**不允许用表外数值** | `theme.ts:560-575` |
| 圆角 | sm 2, base 4, md 6, lg 8（侧栏行）, xl 12, 2xl 16（composer / 气泡）, full | `theme.ts:609-618` |
| 图标 | xs 12, sm 14, md 16, lg 20；stroke 1.5；compact 下放大为 14/18/20/24 | `theme.ts:593-600`；`styles/density.ts:15` |
| 行高（density） | 普通行 compact 44 / 桌面 36；紧凑行 36/28；图标按钮 44/28；Markdown 块间距 12/16 | `styles/density.ts:22-31` |
| 控件高 | xs 28, sm 32, md/lg 44 | `docs/design.md` §4 |
| 菜单行 | 指针设备 28，触屏 40 | `docs/menus.md:159-186` |
| 阴影（深色 md） | rgba(0,0,0,.2), y4, r8 | `theme.ts:680-699` |

### 6.4 常用 lucide 图标

`Plus`（新建）、`History`、`Search`、`CalendarClock`、`FolderPlus`、`Server`（hosts）、`Settings`、`MoreVertical`（kebab，14）、`ChevronRight` / `ChevronDown`、`ArrowUp`（发送）、`Square`（停止）、`CornerDownLeft`、`CircleAlert`（needs_input）、`Check` / `X`（权限）、`QrCode`、`Link2`、`ClipboardPaste`、`AudioLines`。

**SF Symbols 对照**

| lucide | SF Symbol |
|---|---|
| `Plus` | `plus` |
| `History` | `clock.arrow.circlepath` |
| `Search` | `magnifyingglass` |
| `CalendarClock` | `calendar.badge.clock` |
| `FolderPlus` | `folder.badge.plus` |
| `Server` | `server.rack` |
| `Settings` | `gearshape` |
| `MoreVertical` | `ellipsis` |
| `ArrowUp` | `arrow.up` |
| `Square` | `stop.fill` |
| `CircleAlert` | `exclamationmark.circle.fill` |
| `QrCode` | `qrcode.viewfinder` |

### 6.5 风格原则（`docs/design.md`）

- 安静、留白。
- 每个界面最多一个 accent 主按钮。
- 红色只在确认对话框里出现。
- 禁用态只降低透明度，不改颜色。
- 状态变化不能引起布局抖动，需要预留空间。

---

## 7. 键盘快捷键与 Command Center

所有绑定在 `keyboard/keyboard-shortcuts.ts:266-1170`（Mac 写法；其他平台用 Ctrl 对应）。

| 快捷键 | 动作 | 行 |
|---|---|---|
| ⌘K | 打开 / 关闭 Command Center | :867 |
| ⌘P | Command Center，只搜文件 | :316 |
| ⌘O | 新建 agent（当前 workspace 的 draft tab） | :268 |
| ⌘N | 新建 workspace | :292 |
| ⌘⇧⌫ | 归档 workspace | :342 |
| ⌘⇧P | 置顶 / 取消置顶 workspace | :368 |
| ⌘T | tab "+" 菜单 | :392 |
| ⌘⇧A / B / G / E | 新开 agent / browser / changes / files tab | :414-482 |
| ⌘W | 关闭当前 tab | :504 |
| ⌘1…9 | 跳到侧栏第 N 个 workspace | :539 |
| ⌘⌥1…9 | 跳到第 N 个 tab | :580 |
| ⌘[ / ⌘] | 上一个 / 下一个 workspace | :621, :645 |
| ⌥⇧[ / ⌥⇧] | 上一个 / 下一个 tab | :695, :707 |
| ⌘\ / ⌘⇧\ | 向右 / 向下分屏 | :721, :732 |
| ⌘⇧T | 新建 terminal | :843 |
| ? | 快捷键帮助 | :891 |
| ⌘B | 切换左栏 | :907 |
| ⌘E（或 ⌃`） | 切换右栏 Explorer | :929 |
| ⌘. | 同时切换左右栏 | :959 |
| ⌘, | 设置 | :983 |
| ⌘⇧F | Focus mode | :1007 |
| ⌘L | 聚焦输入框 | 1054+ |
| ⇧Tab（输入框内） | 切换 mode | 1054+ |
| Esc | 中断 agent | 1054+ |
| ⌘D / ⌘⇧D | 听写 / 语音模式 | 1054+ |

**Command Center**（`command-center/`）
- 一个居中弹出的搜索面板。
- 内置结果类型：`workspace`、`agent`、`file`、`contribution`（`results.ts:53-95`）。
- 分区内容：
  - 所有 host 的 Workspaces、Agents（`command-center.tsx:250-261`）。
  - Files：输入了查询词或开了文件过滤时才出现。
  - 全局动作（`root-registration.tsx:137-309`）：Add project、New workspace、Import session、Sessions、Schedules、Settings、切换侧栏、切换分组方式。
  - workspace 动作（`workspace-contributions.ts`）：git、tab、pane、pin、rename、copy path 等。
  - agent 控制（`agent-control-contributions.ts`）：选 model / thinking / mode、plan mode、fast mode。
- 条目可设为 `visibility:"query"`，即只在输入查询词后才出现。

---

## 8. SwiftUI 映射方案（v1）

### 8.1 总体：两栏 NavigationSplitView 加 inspector

官方是"左栏 + workspace（tab）+ 右栏"三段式。原生化时建议：

```
NavigationSplitView(columnVisibility:)        // 两栏，不用三栏
 ├─ sidebar:  SidebarView                     // Project → Workspace 列表（全部 host 合并）
 └─ detail:   WorkspaceView(workspaceKey)     // header + tab 选择 + AgentView
               .inspector(isPresented:)       // 右栏 Explorer（v1 先不做，见 8.4）
```

**为什么不用三栏（sidebar / content / detail）**：官方侧栏里没有 agent 行，agent 是 workspace 内的 tab。三栏会把 agent 列表变成中间一栏，和官方布局不一致。

**宽屏**（Mac、iPad 横屏，`horizontalSizeClass == .regular`）
- sidebar 宽度：Mac 上 `navigationSplitViewColumnWidth(min:200, ideal:320, max:600)`，与官方一致。
- 默认展开；`⌘B` 用 `columnVisibility` 切换。

**iPhone**（以及 iPad 竖屏分屏下的 compact 宽度）
- NavigationSplitView 自动折叠成 stack：sidebar 列表是根页面，点 workspace 后 push 进 WorkspaceView。
- 这与官方"左栏覆盖层 + 返回中间"的交互等价。iOS 原生的边缘右滑返回，对应官方的左滑呼出左栏。
- 冷启动直接恢复上次的 workspace：用 `NavigationSplitView` 的 `preferredCompactColumn = .detail`（iOS 17+），对应官方冷启动停在 `agent` 位置。

### 8.2 视图清单

| SwiftUI 视图 | 对应官方 | 要点 |
|---|---|---|
| `SidebarView` | `LeftSidebar` | 见下方说明 |
| `WorkspaceRow` | `SidebarWorkspaceRowContent` | 见下方说明 |
| `WorkspaceView` | `workspace-screen.tsx` | 见下方说明 |
| `AgentView` | `AgentConversationPanel` | `ScrollView` + `LazyVStack`，用 `.defaultScrollAnchor(.bottom)` 加 `scrollPosition` 实现贴底，配一个"回到底部"浮钮；顶部 `onAppear` 触发分页加载 |
| `TimelineItemView` | `agent-stream/view.tsx` 的分发 | 用户气泡 / Markdown / ThinkingRow / ToolCallRow（`DisclosureGroup`，默认折叠）/ ToolGroupRow / PlanCard / TodoCard / NoticeBanner / CompactionMarker |
| `PermissionCard` | `PermissionRequestCard` | 嵌在时间线底部；按钮来自 `request.actions`，没有时用 Deny / Accept（Implement）；question 类型做简化表单 |
| `ComposerView` | `Composer` | 圆角 16 的 surface1 输入面：`TextField(axis:.vertical)` + 工具栏（左 Model/Mode/Thinking 的 `Menu`，右 附件 / 发送 / 停止）。Mac 上 Enter 发送、⇧Enter 换行；iOS 上换行键是换行，靠按钮发送 |
| `NewAgentDraft` | draft tab | 同 AgentView，空时间线，composer 多一个 Provider 选择；首条消息时调用 `createAgent` |
| `NewWorkspaceSheet` | `new-workspace-screen` | Form：Project / Host / Isolation / Branch + 首条 prompt；宽屏用 sheet，iPhone push |
| `HostsView` / `AddHostSheet` | host-picker / add-host-method-modal | 扫码（`DataScannerViewController` 或 AVFoundation）、粘贴配对链接、Direct；每个 host 带一个状态点 |
| `CommandPalette` | Command Center | Mac 用 ⌘K 弹出；iOS 上可以用 `.searchable` 代替 |
| `SettingsView` | settings | Mac 用 `Settings {}` scene；iOS push |

**`SidebarView`**
- `List(selection:)` + `.listStyle(.sidebar)`。
- 结构：Section "Pinned"；按 Project 分 `Section`，`isExpanded` 绑定到折叠状态。
- 底部 `safeAreaInset(edge:.bottom)` 放 Hosts、Settings。
- toolbar 放 New workspace、Search。

**`WorkspaceRow`**
- 左：6pt 状态点（running 用 `.symbolEffect(.pulse)` 或自绘环）。
- 中：标题、meta 行（branch 等）。
- 右：diff stat。
- `.badge` 不用；未读用绿点，与官方一致。
- 菜单：`.contextMenu`（Pin / Archive / Mark unread / Copy path）。

**`WorkspaceView`**
- 宽屏：toolbar 标题为 workspace 名，副标题为 project 名（`.navigationSubtitle`，Mac）。
- tab 切换：宽屏用横向 tab 条（自绘，36 高）；iPhone 用标题位置的 `Menu`，对应官方的 `MobileWorkspaceTabSwitcher`。
- "+" 菜单 v1 只有 "New agent"。

### 8.3 状态与数据映射要点

- 侧栏数据是**所有 host 合并后**的视图：
  - workspace 主键用 `serverId:workspaceId`。
  - project 合并按 `projectKey`；同一 host 内 key 不唯一时，退回 `serverId:projectId`。
  - 只有跨 ≥2 个 host 时才显示 host 徽标。
- 状态桶的推导要复刻 `deriveSidebarStateBucket`：输入为 status、isTurnActive、pendingPermissionCount、requiresAttention。v1 把它做成 PaseoKit 里的纯函数，并写单测。
- 排序：v1 支持 `created`、`lastPrompt` 两种，加上 status 分组模式。手动拖拽排序放到 later。
- 设置项保留三个，默认值与官方一致：`sendBehavior`（默认 steer）、`chatDisplay`（默认 collapseTurns）、`autoExpandReasoning`（默认 false）。

### 8.4 v1 功能取舍

| 功能 | v1 | 说明 |
|---|---|---|
| 多 host 合并侧栏、host 状态点 | 做 | |
| Project → Workspace 分组、Pinned、status 分组 | 做 | |
| 未读（attention）、needs_input 提示 | 做 | |
| agent 时间线：消息 / Markdown / thinking / 工具调用折叠 / 合并组 / plan / todo / 通知 | 做 | |
| 工具调用详情：shell 命令、edit diff（简单统一 diff 渲染） | 做 | |
| 时间线内权限卡（含 plan、question） | 做 | 这是核心价值 |
| Composer：发送 / steer / 停止、model / mode / thinking 选择、图片附件 | 做 | |
| 新建 agent（draft） | 做 | |
| 新建 workspace（Local / Worktree + branch） | 做 | 先做 Local，Worktree 次之 |
| 添加 host：扫码 / 粘贴链接 / Direct | 做 | |
| 快捷键：⌘K ⌘N ⌘O ⌘B ⌘1-9 ⌘[ ⌘] ⌘W Esc ⌘, | 做（Mac / iPad 硬件键盘） | |
| Command Center | 简版：workspace / agent 搜索 + 少量动作 | |
| Queue track、Subagents track | later | |
| Explorer 右栏（Files / Changes / PR） | later | `.inspector` 预留位置 |
| Terminal、Browser tab | later | |
| 分屏、tab 拖拽、Focus mode | 不做 | 官方原生端也没有分屏 |
| 听写 / 语音模式 | later | 系统键盘自带听写可先替代 |
| Schedules、Usage、插件、多主题 | later | |
| Fork、Rewind、chat outline、会话内查找 | later | |
| Remote SSH | 不做 | 官方仅 Electron |
