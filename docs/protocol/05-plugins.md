# 05 · 插件：线协议与 6 个已装插件的原生化方案（v0.14.0）

> 来源：`vendor/paseo`（tag `v0.14.0`）以及本机已装插件源码（只读）。行号简写：
> - `messages.ts` = `vendor/paseo/packages/protocol/src/messages.ts`
> - `session.ts` = `vendor/paseo/packages/server/src/server/session.ts`
> - `runtime.ts` / `plugins/index.ts` / `plugin-process.ts` = `vendor/paseo/packages/server/src/server/plugins/…`
> - `plugin/…` = `vendor/paseo/packages/plugin/src/…`，`app/…` = `vendor/paseo/packages/app/src/…`
> - 插件根目录：
>   - `TS` = `/Users/me/.paseo/plugin-sources/title-style`
>   - `CU` = `/Users/me/.paseo/plugins/claude-update/96222741-d3ab-42cd-aeeb-bdfc20568bed/node_modules/paseo-plugin-claude-update`
>   - `UR` = `/Users/me/.paseo/plugins/usage-reset/5b5a640f-1c24-4a45-baf9-6283b8388c55/checkout/usage-reset`
>   - `SP` = `/Users/me/.paseo/plugins/turn-speed/fa801669-ab98-49af-a175-7350d932fd8b/checkout/turn-speed`
>   - `NI` = `/Users/me/.paseo/plugins/next-input/492c52ac-6dec-448f-969e-3269a4b2d2b6/checkout/next-input`
>   - `TB` = `/Users/me/.paseo/plugin-sources/agent-taskboard`
>
> 前置文档：[01-connection.md](./01-connection.md)（`rpc_error`、`server_info.features`、hello capabilities）和 [02-messages.md](./02-messages.md)（订阅、timeline）。示例 JSON 只写 `message` 内层，发送时要套上 `{"type":"session","message":…}`。
> 标 **未确认** 的地方，表示源码里没找到或只能推断。

---

## 0. 结论速览

- 官方 App 的做法：用 `plugin.catalog.get` 拿到每个插件**编译后的 JS 源码文本**（不是 URL），再用 `globalThis.eval` 执行（`app/plugins/evaluate.ts:534`、`app/plugins/registry.ts:115`）。原生端没法这么做，只能对每个插件手写 UI。
- 原生端要用到的线路只有四样：
  1. `plugin.list`：列出插件和状态。
  2. `plugin.rpc.invoke`：调插件 RPC。**插件 settings 的读写也走这条**，没有专门的 settings 消息。
  3. timeline 里的 `{type:"plugin"}` 条目：hello 时要声明 `plugin_timeline_items`。
  4. `status` 推送：`plugin_settings_changed` 和 `plugin_catalog_changed`。
- 我们的 hello 现在**没有声明** `plugin_timeline_items`（`PaseoKit/Sources/PaseoKit/Client/HostStore.swift:170-183`），所以 turn-speed 和 next-input 的时间线行目前会被 daemon 过滤掉。我们开了 `explicit_event_subscriptions`，因此还要显式订阅那两个 `status.plugin_*` 事件。
- 本机实测 `paseo plugin ls`：5 个 running，**claude-update 是 failed**（版本不兼容，见 §2.2）。

---

## 1. 线协议

### 1.1 权限与特性开关

- 所有 `plugin.*` 请求都要求 `daemon.manage` 权限，包括 `plugin.rpc.invoke.request`（`vendor/paseo/packages/server/src/server/authorization/operation-permissions.ts:135-149`）。权限不够时返回 `rpc_error`，`code:"access_denied"`（`session.ts:2208-2220`）。
  - 结果：一个只有只读权限的配对设备，连插件 RPC 都调不了（例如 next-input 的预测）。
- `server_info.features` 里与插件相关的开关（`vendor/paseo/packages/server/src/server/websocket-server.ts:2002-2011`，schema 在 `messages.ts:3702-3719`）：`plugins`、`pluginManagement`、`pluginGitManagement`、`pluginSourceInstallation`、`pluginSourceUpdates`、`pluginLogs`、`pluginThemes`、`pluginSettings`、`pluginTimelineItems`。v0.14.0 全部为 `true`。官方 App 只在 `features.plugins` 存在时才加载插件（`app/plugins/catalog-sync.tsx:18`）。
- 全局开关：daemon config 里的 `pluginsEnabled`。我们的 `App/Sources/UI/DaemonSettingsView.swift:112` 已经有这个开关。

### 1.2 列出插件：`plugin.list`

```json
{"type":"plugin.list.request","requestId":"r1"}
```
响应（`messages.ts:6804-6807`，handler 在 `session.ts:2528`）：
```json
{"type":"plugin.list.response","payload":{"requestId":"r1","plugins":[
  {"id":"claude-update","name":"Claude Code updates","path":"/Users/me/.paseo/plugins/claude-update/…",
   "enabled":true,"status":"failed",
   "npm":{"packageName":"paseo-plugin-claude-update","requestedSpec":"…","version":"0.2.1","integrity":"…"},
   "error":"Plugin \"claude-update\" requires Paseo >=0.10.3 <0.13.0. Your daemon is 0.14.0. Use a compatible plugin version or update the daemon."}
]}}
```
- `PluginListItem` 的字段（`messages.ts:6777-6793`）：`id, name?, icon?, media?, description?, path, enabled, status:"running"|"disabled"|"failed", source?:"directory"|"git", npm?, installation?, remote?, ref?, commit?, error?`。
- `status` 的判定（`plugins/index.ts:81-82`）：
  - `!enabled` 或全局关闭时为 `disabled`。
  - 否则进程起来了就是 `running`，没起来就是 `failed`，失败原因放在 `error` 里（`plugins/index.ts:273`）。
- **这些东西线上都没有**：
  - 没有顶层 `version`。只有 npm 安装的插件有 `npm.version`。
  - 没有 manifest 原文。
  - 没有 `translations`：manifest 里的 `translations.zh-CN.name` 等字段不会下发。
  - `icon` 只是一个相对路径字符串，**没有找到通过协议拿到图标字节的办法**（未确认）。
  - 所以原生端的插件名、中文名、图标都要在客户端里写死。
- 内置插件不出现在这个列表里（`vendor/paseo/docs/plugins.md:112`）。
- 其他管理请求：
  - `plugin.reload/enable/disable/remove.request {requestId, pluginId}`（`messages.ts:1582-1585`）。前三个响应 `{payload:{requestId, plugin: PluginListItem}}`，remove 只回 `{requestId}`（`messages.ts:6900-6907`）。
  - `plugin.logs.get.request {requestId, pluginId}` 返回 `{entries:[{sequence, timestamp, stream:"stdout"|"stderr", message}]}`（`messages.ts:6796-6812`），排查 failed 插件时有用。
  - 安装和更新：`plugin.directory.install/inspect`、`plugin.source.install/status/update/update.preview/update.apply`（`messages.ts:1486-1576`）。原生端暂时不需要。
- `plugin.catalog.get.request` 返回 `{plugins:[{id, clientBundle, requirements?}]}`（`messages.ts:1470, 6753`），只包含 running 的插件（`runtime.ts:372-375`）。原生端**不需要**这个，最多拿它判断「这个插件当前带客户端 bundle」。

### 1.3 版本兼容检查

- 实现在 `vendor/paseo/packages/protocol/src/plugin-requirements.ts:22-41`：
  - 用 `semver.satisfies(version, range)` 判断，不通过时再拿 stable core（major.minor.patch）试一次。
  - manifest 没写 `requirements.paseo` 时，按 `"<0.8.0"` 处理。
- daemon 在加载和安装时检查（`plugins/index.ts:295, 737-745`），不通过就记为 failed。
- 官方 App 在执行 bundle 前还会再按 App 版本检查一次（`app/plugins/registry.ts:76`）。原生端可以忽略这一步：我们本来就不执行 bundle，只看 daemon 给的 `status`。

### 1.4 调插件 RPC：`plugin.rpc.invoke`

请求（`messages.ts:1587-1593`）：
```json
{"type":"plugin.rpc.invoke.request","requestId":"r2","pluginId":"agent-taskboard",
 "method":"board.locate","input":{"paths":["/Users/me/projects/paseo-native"]}}
```
成功响应（`messages.ts:6909-6915`）：
```json
{"type":"plugin.rpc.invoke.response","payload":{"requestId":"r2","output":{"url":"http://127.0.0.1:7788","reachable":true,"project":"paseo-native"}}}
```
- 错误**不会**放在 response 里。任何异常都会变成一条 `rpc_error`（catch 在 `session.ts:2222-2241`，schema 在 `messages.ts:3868-3876`）：
  ```json
  {"type":"rpc_error","payload":{"requestId":"r2","requestType":"plugin.rpc.invoke.request","error":"Request failed: Plugin next-input does not contribute RPC foo","code":"handler_error"}}
  ```
- 常见的 `error` 内容：
  - `Plugin service is unavailable`（`session.ts:2597`）
  - `Plugin is not available: <id>`：插件没在跑（`runtime.ts:497`）
  - `Plugin <id> does not contribute RPC <method>`（`runtime.ts:499`）
  - `Plugin RPC timed out: <id>.invoke`：30 秒超时（`runtime.ts:43, 696`）
  - zod 校验输入或输出失败，或者 handler 主动 `throw`（`plugin-process.ts:525-545`）。next-input 的 `suggestion_expired` 这类错误就是这样传过来的，客户端要从 `error` 字符串里匹配。
- method 名必须匹配 `^[a-z][a-z0-9._-]*$`（`plugin/rpc.ts:21`）。JS 客户端会在两端都做 zod 校验（`plugin/rpc.ts:31-39`）。原生端用 `Decodable` 解码，解码失败当作错误处理。
- 调用链：`session.ts:2596` → `plugins/index.ts:526` → `runtime.ts:495` → 插件子进程里的 `handlers`（`plugin-process.ts:525`）。

### 1.5 插件 settings：用普通插件 RPC 读写

- 插件在代码里声明 settings：`defineSettings({id, scope:"host", version, schema, migrate?})`（`plugin/settings.ts:5-22`），**不在 `paseo-plugin.json` 里**。manifest 的字段只有 `id, name, description, icon, media, requirements, build`（`vendor/paseo/packages/server/src/server/plugins/manifest.ts:25-36`）。
- 服务端调用 `server.registerSettings(def)` 后，会自动注册 3 个 RPC（`plugin/settings.ts:33-50`、`plugin-process.ts:43-53`）：

| method | input | output |
|---|---|---|
| `settings.<id>.read` | `{}` | `{status:"ready", revision, values}` 或 `{status:"invalid", revision, error}` |
| `settings.<id>.write` | `{revision, values}` | `{status:"saved", revision, values}`、`{status:"conflict", error}` 或 `{status:"invalid", error}` |
| `settings.<id>.reset` | `{revision}` | 同 write，把值恢复为 schema 默认值 |

  - 这里的 `<id>` 是 **settings id**，不是 pluginId。例如 claude-update 是 `settings.update.read`，next-input 是 `settings.preferences.read`。
- 存储位置是 `~/.paseo/plugin-settings/<pluginId>/<settingsId>.json`，内容为 `{"version":N,"values":{…}}`，原子写入，权限 0600（`vendor/paseo/packages/server/src/server/bootstrap.ts:673`、`runtime.ts:859`、`…/plugins/settings/index.ts:168-184`）。
- revision 和冲突（`…/plugins/settings/index.ts:13, 98, 145-149`）：
  - `revision` 是文件原文的 sha256 hex。文件不存在时是字面量 `"missing"`。
  - write 带的 revision 和当前文件不一致时，返回 `conflict`，error 为 "Settings changed on another client. Reload before saving again."
  - 所以每次写都是 read → 整体修改 values → 带上刚读到的 revision 去 write。**write 发的是整个 values 对象，不是 patch。**
  - read 返回的 `values` 已经过 schema 解析，默认值都已补上。
- 存的版本比当前旧时，服务端会自动 migrate 并写回，这也会触发一次变更推送。存的版本比当前新时返回 `invalid`（`…/plugins/settings/index.ts:111-121`）。
- **变更推送**（`messages.ts:3939-3943`，发送在 `session.ts:2701-2706`，来源是子进程的 `settings.changed` 消息，`plugin-process.ts:281`、`runtime.ts:967`）：
  ```json
  {"type":"status","payload":{"status":"plugin_settings_changed","pluginId":"next-input","settingsId":"preferences"}}
  ```
  - 推送里不带新值，收到后要重新 `read`。官方 App 的做法是 invalidate query key `["plugin-settings", settingsId]` 再重新拉（`app/plugins/settings/use-settings.ts:16-45`、`app/plugins/catalog-sync.tsx:64-71`）。
  - 保存成功时，直接用 write 返回的 `values` 和 `revision` 覆盖本地缓存。

### 1.6 其他推送

- `{"type":"status","payload":{"status":"plugin_catalog_changed","pluginId":"…"}}`（`messages.ts:3934-3937`，`session.ts:2698`）：插件被启用、禁用、重载或更新时触发。原生端收到后重新拉 `plugin.list`，刷新哪些插件 UI 可用。
- 订阅：开了 `explicit_event_subscriptions` 的客户端，要在 `session.events.set_subscription.request.events` 里加上 `"status.plugin_catalog_changed"` 和 `"status.plugin_settings_changed"`（`messages.ts:3215-3216`，过滤逻辑在 `session.ts:1762-1771`）。
- **插件没有自定义推送通道**，没有 event bus。需要实时数据的插件 UI 都靠轮询 RPC（claude-update 30s/2s，usage-reset 5min）。插件的用量来源会出现在普通的 `usage.list_reports.*` 里（见 04 文档），不经过插件 RPC。

### 1.7 插件时间线条目

线上格式是 `AgentTimelineItem` 联合类型的 plugin 分支（`messages.ts:751-758`）：
```json
{"type":"plugin","id":"turn-1762156800123","pluginId":"turn-speed","kind":"turn-speed","version":1,
 "data":{"provider":"claude","outputTokens":1234,"generationMs":29180,"requests":3,"tokensPerSecond":42.3}}
```
- **谁会产生**：只有服务端插件，通过 `paseo.agents.ref(agentId).timeline.append(...)`。底层发的是 `agent.timeline.append.request {requestId, agentId, item:{type:"plugin", id, kind, version(正整数), data}}`（`messages.ts:1595-1606`），响应 `{seq, epoch}`（`messages.ts:6917-6924`）。
  - `pluginId` 由 daemon 根据插件会话身份自动填，普通客户端会话调用会被拒："Only plugin sessions can append plugin timeline items"（`session.ts:7907-7920`）。
  - `data` 上限 64 KiB。
  - 用**同一个 `id`** 再 append 会替换原来那行，并持久化到历史里（`vendor/paseo/public-docs/plugins/reference.md:1672-1702`）。原生端要按 id 做 upsert。
- **怎么下发**：跟普通 timeline 一样，走 `agent_stream` 和 timeline fetch。但客户端必须在 hello 里声明 capability `plugin_timeline_items`（`vendor/paseo/packages/protocol/src/client-capabilities.ts:44-45`）。没声明时，daemon 在直播、拉取、搜索里都会把 plugin 条目过滤掉（`session.ts:1352-1360`，另见 `:1394, :1405, :1909, :4919, :7827, :8084`）。
- **客户端渲染**：官方 App 按 `kind + version` 找 renderer，先用 zod 校验 `data`；找不到 renderer 时显示一行「unavailable」（`app/plugins/timeline/view.tsx:26-36`）。原生端建议：
  - 已知的 kind 用原生 View 渲染。
  - 未知的 kind 不显示，或者显示一行淡灰色的「插件条目（<pluginId>）」。
- **只在客户端生成的条目**：`addTimelineTransformer` 会在 App 本地把 `tool_call` 等条目改写成 plugin 条目（`app/plugins/timeline/model.ts:44-80`），这些不经过线路。本机 6 个插件**都没用 transformer**，不用处理。

### 1.8 官方客户端 API 速查（用来理解各插件的 UI 放在哪）

定义在 `plugin/client/contracts.ts:176-206`，说明见 `vendor/paseo/public-docs/plugins/reference.md`。

| API | 在官方 App 里出现的位置 |
|---|---|
| `addSettingsScreen({id,title,icon,Component})` | 设置 → 插件 → 该插件的页面；`openSettings(id)` 可直接打开（reference.md:1783-1797） |
| `addScreen({id,title,Component})`（旧名 `addSurface`） | 整页路由，用 `openScreen({screenId, params})` 打开，params 是 string→string（reference.md:1185-1197） |
| `addSidebarHeaderItem`（旧名 `addSidebarItem`） | 侧边栏顶部行，拿到 `currentScreen/openScreen/openPopover`（reference.md:1199-1250） |
| `addSidebarFooterItem` | 侧边栏底部，在「Add project」和图标行之间 |
| `addHeaderButton({id,workspaceId,button})` | workspace 顶栏右侧，排在内置按钮之前（reference.md:2338） |
| `addComposerPill` | 某个 agent 的 composer 轨道上（reference.md:2376） |
| `addCommandCenterItem({context:"global"\|"workspace"\|"agent"})` | ⌘K 命令中心（reference.md:2246） |
| `addSlashCommand` | composer 里的 `/name`，在客户端执行（reference.md:2303） |
| `addTimelineRenderer({kind,version,schema,Component})` | 时间线里 plugin 条目的渲染器 |
| `useRpc` | 封装 `plugin.rpc.invoke`（`plugin/client/rpc-context.tsx:26-35`） |
| `useSettings` | 封装 `settings.<id>.read/write/reset` 和变更推送（§1.5） |
| `usePaseo` | `@getpaseo/client` 的 `PaseoApi`，也就是普通 daemon 协议（`plugin/client/paseo-context.tsx:14`） |
| `defineTranslations/useTranslation` | 插件自带的文案包，按 App 的 locale 选择，daemon 不参与（`plugin/client/translations.tsx:27`、`vendor/paseo/docs/plugins.md:89-93`） |

- 任务说明里提到的 `contributeWorkspaceButtons`（agent-taskboard）和 `useUsage`（usage-reset）**不是官方 API**，是插件自己写的 helper。

---

## 2. 逐个插件

### 2.1 title-style（中文任务型标题）— running

**作用**：新 agent 创建后，用一个可配置的 LLM 提示词给 workspace 重新起名，默认生成简体中文的任务型标题。`requirements.paseo ">=0.8.0"`（`TS/paseo-plugin.json:10-12`）。

**服务端（全部逻辑都在这里，任何客户端都生效）**
- 入口：`TS/index.server.ts:6` 调 `registerSettings`；`:7-9` 监听 `agent.created`，然后调 `nameWorkspace`。
- `TS/server/namer.ts:98-202` 的流程：
  - 跳过：没有 workspaceId 的、标题等于 `会话标题生成` 的（也就是它自己起的临时会话）、已经处理过的（`:104-105`）。
  - 直接读文件 `$PASEO_HOME/plugin-settings/title-style/title-style.json`（`:21-34`），`enabled=false` 时退出（`:117`）。
  - 选模型：`model` 写了 `provider/model` 就用它，否则用 daemon config 的 `metadataGeneration.providers[0]`（`:36-54`）。
  - 取第一条 `user_message`，截到 600 字（`:56-73`）。
  - 在同一个 workspace 里新建一个临时 agent，标题 `会话标题生成`，带 label `paseo.parent-agent-id`，所以不会触发通知（`:145-156`）。`waitForFinish(30s)` 后 archive 它（`:159-170`）。
  - 解析返回的 `{"title":…}`，清洗后截到 80 字（`:75-96`）。
  - 只在用户没手动改名、或仍在 60 秒内置命名窗口内时，才调 `ws.setTitle`（`:183-195`）。
- 没有 RPC（settings 那 3 个自动 RPC 除外），没有 timeline 条目。

**设置**：`defineSettings({id:"title-style", scope:"host", version:1})`（`TS/shared/settings.ts:7-19`）

| key | 类型 | 默认值 |
|---|---|---|
| `enabled` | boolean | `true` |
| `instructions` | string，trim 后至少 1 个字 | `DEFAULT_INSTRUCTIONS`（`TS/shared/settings.ts:5`，「用简体中文生成一个简短的任务型标题（不超过 30 个字）……」） |
| `model` | string，trim | `""`（空字符串表示跟随 Metadata 配置） |

- 本机现在存的值：`{"version":1,"values":{"enabled":true,"model":"claude/claude-haiku-5-5"}}`。
- RPC：`settings.title-style.read` / `.write` / `.reset`。

**UI 贡献**：只有一个 `addSettingsScreen({id:"title-style", icon:"Languages"})`（`TS/index.client.tsx:7-12`），实现在 `TS/client/title-style-settings.tsx`：
- loading / error（带重试）/ ready 三种状态（`:106-118`）。
- 多行输入框对应 `instructions`（`:78-86`）。
- 输入框「模型覆盖」对应 `model`，placeholder 是 `例如 anthropic/claude-haiku-4-5`（`:87-94`）。
- 改动后 600ms 防抖自动保存，带 revision（`:48-57`）。保存失败时显示错误，暂停自动保存。
- **`enabled` 没有出现在 UI 上。**
- 文案：中英两套写死在 `TS/client/i18n.ts:13-37`。

**原生方案**：设置 → 插件 → 「标题风格」页面，一个 `Form`：
- `Toggle("自动命名")` 对应 `enabled`（比官方多一个开关）。
- `TextEditor` 对应 `instructions`，最小高度约 120pt，配一个「恢复默认」按钮（客户端内置 `DEFAULT_INSTRUCTIONS` 常量，或者调 `.reset`，但 reset 会把三个字段全部恢复）。
- `model` 用 `Picker`，数据来自已有的模型列表，格式为 `provider/model`，加一项「跟随 Metadata 配置」对应空串。也可以退化为 `TextField`。
- 600ms 防抖保存；收到 conflict 时重新 read，再提示「已在其他设备修改」。

### 2.2 claude-update（Claude Code 自动更新）— **failed，当前不生效**

**实际状态（已确认）**
- `paseo plugin ls` 显示：`claude-update failed yes … ERROR: Plugin "claude-update" requires Paseo >=0.10.3 <0.13.0. Your daemon is 0.14.0.`
- `paseo plugin logs claude-update` 里在 2026-10-30T02:03:55Z 有一条 `[paseo] Plugin failed to load: …`，内容是同一句话。
- 插件版本 0.2.1（`CU/package.json:3`），manifest 要求 `>=0.10.3 <0.13.0`（`CU/paseo-plugin.json:4-6`）。`~/.paseo/config.json` 里仍然是 `enabled:true`。
- 旁证：`~/.paseo/plugin-data/claude-update/state.json` 的最后一次检查停在 2026-10-24T09:17:32Z。当时的状态是 installed 2.1.306、target 2.1.310、`update-available`，还有一条未处理的 `attention`。
- 结论：**daemon 0.14.0 根本没有加载它**，服务端定时器和 UI 都没在跑，调它的 RPC 会得到 `Plugin is not available: claude-update`。上游有没有兼容 0.14 的新版本，**未确认**（要联网用 `paseo plugin update` 或去插件市场看）。

**服务端（加载成功时才有）**
- `CU/index.server.ts:49-73`：`registerSettings(updateSettings)`，然后 `startService`（`CU/server/service.ts:84-171`）：启动 30 秒后第一次 tick，之后每 60 秒 tick 一次，到期才检查，最少间隔 15 分钟。
- 检查会跑 `claude update` 或 `claude install <ver>`（`CU/server/updater.ts`）。
- 用 osascript 发 macOS 通知（`CU/server/notify.ts:16-27`）。
- 用 `ps` 找出还在跑旧版本的 claude 进程（`CU/server/processes.ts`）。
- 抓取 changelog（`CU/shared/notes.ts:11`）。
- 状态写在 `~/.paseo/plugin-data/claude-update/`（`CU/server/paths.ts:11-13`）。
- 没有 timeline 条目。

**RPC**（`CU/shared/status.ts:91-111`，handler 在 `CU/server/handlers.ts:10-20`）

| method | input | output |
|---|---|---|
| `status.get` | `{}` | `Status` |
| `status.check` | `{"apply":false}`（`true` 表示同时安装） | 检查后的 `Status` |
| `status.dismiss` | `{}` | 清除 `attention` 后的 `Status` |

`Status` 的结构（`CU/shared/status.ts:56-88`）：
```json
{"claudePath":"/Users/me/.local/bin/claude","installedVersion":"2.1.306","targetVersion":"2.1.310",
 "claudeChannel":"latest","lastCheckAt":"2026-10-24T09:17:32.777Z","nextCheckAt":null,"scheduled":true,
 "lastOutcome":"update-available","lastMessage":"Claude Code 2.1.310 is available …","consecutiveFailures":0,
 "previousVersion":null,"rollbackCommand":null,
 "attention":{"kind":"update-available","message":"…","at":"…"},
 "autoInstall":false,"checking":false,"activity":null,
 "staleProcesses":[{"pid":1,"version":"2.1.300","kind":"agent","agentId":"…","title":"…","startedAt":"…"}],
 "processListSupported":true,
 "history":[{"at":"…","trigger":"manual","outcome":"up-to-date","from":"…","to":"…","target":"…","message":"…"}],
 "releaseNotes":{"from":"…","to":"…","versions":[{"version":"…","items":["…"],"moreItems":0}],"moreVersions":0,"fetchedAt":"…","error":null},
 "dataDirectory":"/Users/me/.paseo/plugin-data/claude-update"}
```
- `outcome` 的取值（`CU/shared/status.ts:6-15`）：`up-to-date | updated | update-available | pinned | pin-applied | pin-mismatch | channel-mismatch | failed`。
- `activity` 是 `{phase:"checking"|"installing", trigger, startedAt}` 或 null。
- `history` 最多 20 条，最新在前（`CU/server/service.ts:36`）。

**设置**：`id:"update"`（RPC 为 `settings.update.*`），version 1（`CU/shared/settings.ts:14-43`）

| key | 类型 | 默认值 |
|---|---|---|
| `enabled` | boolean（按计划检查） | `true` |
| `mode` | `"auto"`\|`"notify"` | `"notify"` |
| `channel` | `"latest"`\|`"stable"` | `"latest"` |
| `intervalHours` | number，1 到 168 | `4` |
| `pinnedVersion` | string，`^(\d+\.\d+\.\d+)?$` | `""` |
| `claudePath` | string，最长 1024 | `""` |
| `desktopNotifications` | boolean | `true` |

**UI 贡献**（`CU/index.client.tsx`，文案只有英文，没有 i18n）
1. `addSurface("status")`（`:14`）：整页状态面板（`CU/client/status.tsx:140-425`）。依次是：
   - attention 卡片，带 Dismiss。
   - Checks：上次检查、结果（失败时带连续失败次数）、进行中的进度和耗时、下次检查时间，以及「Check now」（`apply:false`）和「Update now」（`apply:true`）两个按钮。
   - Auto-update 开关（写 `mode`）。
   - Versions。
   - Release notes：最多 3 个版本，每个最多 12 条，外加官方 changelog 链接。
   - Roll back：显示 `rollbackCommand`。
   - 还在跑旧版本的进程列表。
   - History。
   - 日志目录。
   - 刷新：平时 30 秒一次 `status.get`，检查中 2 秒一次（`CU/client/check.ts:44-48`）。
2. `addSettingsScreen({id:"settings", icon:"RefreshCw"})`（`:15-20`，`CU/client/settings.tsx`）：
   - Checks 区：最近状态和 Check now。
   - 开关：Auto-update、Check on a schedule、Channel、Desktop notifications。
   - 输入框：intervalHours、pinnedVersion、claudePath，点 Save 保存。
   - settings 为 invalid 时显示 Reset。
3. `addSidebarItem({id:"status", surface:"status"})`（`:27`）：侧边栏一行。平时显示「Claude Code updates」。有需要处理的事时标题和图标会变（`CU/shared/format.ts:192-208`）：「Claude update ready」「Claude pin mismatch」「Claude update failed」「Claude channel issue」。客户端每 60 秒轮询一次 `status.get`（`:33-41`）。
4. 3 个全局 `addCommandCenterItem`（`:43-80`）：`open-status`、`check-now`、`open-settings`。

**原生方案**：**先不做**。插件管理列表里显示 failed 标签、`error` 原文，以及「查看日志」（`plugin.logs.get`）。等插件恢复 running 后再按下面做：
- 侧边栏「工具」区加一行，60 秒轮询，有 attention 时换成橙色或红色图标。
- 点开进入 `ClaudeUpdateStatusView`：`List` 按上面 1 的顺序分 section。
- 设置页 `Form`：Toggle、Picker、Stepper(1...168)、TextField 加 Save。
- 加 3 个命令面板动作。

### 2.3 usage-reset（限额刷新时间）— running

**作用**：在侧边栏底部显示 Claude / Codex 各个限额窗口（5 小时、周、按模型的周限额、月）的剩余百分比；点开浮层可以看刷新时间、倒计时、「日均可用」是否偏紧，并能控制每个窗口要不要在侧边栏显示。`requirements >=0.13.0`。

**服务端**：只有 `registerSettings(sidebarPrefs)`（`UR/index.server.ts:5-7`）。没有 hook，没有自定义 RPC，没有 timeline 条目。**数据全部来自 daemon 自带的用量接口**，所以只有在有这个插件 UI 的客户端里才会显示。

**数据来源**（`UR/client/usage-data.ts:56-93`）：`usePaseo().providers.listUsage()`，也就是普通协议 `provider.usage.list.request`（`vendor/paseo/packages/client/src/daemon-client.ts:5647-5651`）：
- 需要 `features.providerUsageList`。
- 响应：`provider.usage.list.response {payload:{requestId, fetchedAt, providers: ProviderUsage[]}}`（`messages.ts:6375-6395`）。
- 详见 [04 文档](./04-schedules-usage-workspaces.md) 的用量一节。**这不是插件 RPC。**
- 插件的处理方式：
  - 去掉 `status=="available"` 但 `windows` 为空的 provider（`:63-65`）。
  - 每 5 分钟轮询一次，所有组件共享一份数据（`:18, 31-54`）。打开浮层时强制刷新（`UR/client/usage-popover.tsx:235-237`）。
  - 已经有数据时，一次失败不清空；只采纳最后一次请求的结果（`:58, 69, 72`）。

**设置**：`id:"sidebar"`（RPC 为 `settings.sidebar.*`），schema 是 `{hidden: string[] = []}`（`UR/shared/settings.ts:5-10`）
- 元素是 `windowKey = "${providerId}/${windowId}"`（`:12-14`），例如 `"claude/five_hour"`。
- 切换时写整个 `{hidden:[…]}`，带 revision（`UR/client/usage-data.ts:107-125`）。settings 还没读到时，眼睛按钮禁用。

**计算规则（原生端照抄）**
- 剩余 = `remainingPct ?? 100 - usedPct`（`usage-data.ts:95-99`）。
- provider 图标取 `providerId` 冒号前的部分：codex、grok、claude（`UR/client/provider-icons.ts`）。
- 进度条颜色：剩余 <10% 为 `#FF5A50`，<30% 为 `#FF9F0A`，其余 `#4A9DF8`（`usage-data.ts:130-134`）。
- 日均可用（`usage-data.ts:139-169`）：
  - 窗口前缀决定周期：`five_hour` 是 5 小时，按小时算；`weekly` 是 7 天，按天算；`monthly` 是 30 天，按天算。
  - `perUnitPct = 剩余% ÷ (距刷新时间 ÷ 单位时长)`。
  - `ratio = perUnitPct ÷ (100 ÷ 单位个数)`。ratio <0.5 为 danger（`#E5484D`），<0.85 为 warning（`#E08600`），否则 ok（`#1F9D55`）（`:172-176`）。
  - 距刷新不到一个单位、或没有 `resetsAt` 时不显示。
- 时间格式（`UR/client/format.ts`）：
  - 刷新时间取整到分钟，显示「今天 HH:mm / 明天 HH:mm / 周X M/D HH:mm」（`:7-28`）。
  - 倒计时显示「还有 X 天 Y 小时 / X 小时 Y 分 / X 分钟」（`:30-39`）。
  - 标签本地化：Session / Weekly / Monthly 前缀换成中文，`wk` / `mo` 换成「周」「月」（`:49-68`）。
- 文案：`UR/client/locales/zh-CN.json`，26 个 key。

**UI 贡献**
1. `addSidebarFooterItem({id:"usage-reset"})`（`UR/index.client.tsx:6-10`，`UR/client/sidebar-item.tsx:26-85`）：
   - 每个可用账户一行：provider 图标，后面依次排未隐藏的窗口，每个写「`NN%` + 短标签」。按模型的窗口 "wk Fable" 只显示 "Fable"（`:19-22`）。
   - 日均可用为 warning 或 danger 时，百分比变色。
   - 每分钟刷新一次。没有可显示的窗口时，显示 Clock 图标加「限额」占位。
   - 点击后 `openPopover`：宽屏是锚定浮层，窄屏是 bottom sheet。
2. `UsagePopover`（`UR/client/usage-popover.tsx:229-291`）：
   - 头部：标题、「更新于 HH:mm」、刷新按钮。
   - 每个 provider 一节：图标、名字、`planLabel` 胶囊、账户。
   - 每个窗口一行：标签加「剩余 NN%」，分段进度条（每格 3px、间隔 2px，`:87-103`），「{何时} 刷新 · 还有…」，「日均可用 N% / 每小时可用 N%」，右侧眼睛按钮切换是否在侧边栏显示。

**原生方案**
- 和官方内置的 Usage 行**合并成一个实现**（内置那个默认隐藏，见 04 文档）。插件 running 时，用 usage-reset 的展示规则和 `hidden` 设置。
- `UsageStore`（`@Observable`，每个 host 一个）：
  - 有视图在看时每 5 分钟拉一次，浮层打开时强制刷新。
  - 失败时保留旧数据。
- 侧边栏底部 `Section`：每个账户一个 `HStack`（provider 图标 + `ForEach` 窗口：`Text("\(pct)%").monospacedDigit()` 加 `.secondary` 短标签），用 `TimelineView(.periodic(from:.now, by:60))` 驱动倒计时。
- 点击后 macOS 用 `.popover`，iOS 用 `.sheet` 加 `.presentationDetents([.medium])`。
- 浮层里每个窗口：`Canvas` 自绘分段条，或者 `ProgressView`；自写「今天/明天」formatter；眼睛按钮（`eye` / `eye.slash`）写入 `settings.sidebar.write`。

### 2.4 turn-speed（回合速度）— running

**作用**：每一轮 Claude Code / Codex 对话正常结束后，在时间线末尾加一行「⚡ 42.3 tok/s · 输出 1,234 tokens · 生成 29.2 秒 · 3 次请求」。`requirements >=0.13.0`。

**服务端（全部逻辑都在这里，任何声明了 capability 的客户端都能收到）**
- `agent.turn_started`（`SP/index.server.ts:51-64`）：
  - 只处理 provider 为 claude 或 codex 的回合。
  - 记下开始时间，取 `runtimeInfo.sessionId ?? persistence.sessionId`，找到会话 jsonl 文件，记下当前大小作为 offset（`SP/server/session-files.ts:17-26, 50-92`）。
  - Claude 的文件在 `~/.claude/projects/<cwd>/<sid>.jsonl`，Codex 的在 `~/.codex/sessions/Y/M/D/rollout-*-<id>.jsonl`。
- `agent.turn_ended`，且 `outcome.kind=="completed"` 时（`SP/index.server.ts:66-103`）：
  - 分别在 800ms 和 2500ms 后读日志（`:20, 81-85`）。
  - 解析：Claude 按 `message.id` 合并；Codex 按 `token_usage_record` 切分（`SP/server/parse.ts:38-99`）。
  - 只统计时间落在本回合内的请求，`tokensPerSecond` 保留一位小数（`parse.ts:102-123`）。
  - 有结果时 `timeline.append`（`SP/index.server.ts:88-94`）。会话已被删除时静默跳过（`:95-98`）。
- 没有设置，也没有 RPC。

**timeline 条目**：`kind:"turn-speed"`，`version:1`，`id:"turn-<startedAt 毫秒>"`。data schema 在 `SP/shared/speed.ts:4-18`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `provider` | `"claude"`\|`"codex"` | |
| `outputTokens` | int ≥0 | 包含 thinking / reasoning token |
| `generationMs` | number ≥0 | 模型请求耗时之和，不含工具执行时间 |
| `requests` | int ≥1 | 模型请求次数 |
| `tokensPerSecond` | number ≥0 | 一位小数 |

示例见 §1.7。

**UI 贡献**：`addTimelineRenderer({kind:"turn-speed", version:1})`（`SP/index.client.tsx:6-11`），实现在 `SP/client/speed-row.tsx:6-33`：
- 一行 12pt 的弱化文字，上下各留 4pt。
- 内容是四段用 ` · ` 连起来。时长不满 60 秒时显示「X.Y 秒」，否则「M 分 S 秒」。
- 没有交互。
- 中文文案在 `SP/client/locales/zh-CN.json`：「⚡ {tps} tok/s」「输出 {count} tokens」「生成 {duration}」「{count} 次请求」。

**原生方案**
- hello 里加 `plugin_timeline_items: true`。
- `AgentTimelineItem` 加 `case plugin(PluginTimelineItem)`，`data` 先保留为 `JSONValue`。
- 注册表按 `(pluginId, kind, version)` 分派，`TurnSpeedRow` 解码成 `struct TurnSpeed: Decodable`，解码失败就不显示。
- 样式：`Text(…).font(.caption).foregroundStyle(.secondary)`，可以在前面加一个小 provider 图标，再加 `accessibilityLabel`。
- 按 `id` upsert。
- 这是最便宜的一个，适合用来打通 plugin timeline 这条管线。

### 2.5 next-input（下一句建议）— running

**作用**：agent 一轮结束后，预测用户下一句可能要说的话（一句短话），在最新回答下面显示一行淡色的「✨ …」。用户可以一键发送，也可以点开编辑、复制或发送。manifest 有 `translations.zh-CN {name:"下一句建议"}`（`NI/paseo-plugin.json:1-17`）。

**服务端**（`NI/index.server.ts`）
- `registerSettings(preferences)`（`:13`）。settings 变化时清空所有状态（`:23`）。
- `agent.turn_started`、`agent.archived`、`agent.closed` 时，清掉该 agent 的状态，并中止进行中的预测（`:25-30`）。
- `agent.turn_ended`（`:31-50`）满足以下条件时继续：有 workspaceId、不是子 agent、`outcome=="completed"`、`enabled` 为 true、能找到 claude CLI。然后等 3.5 秒（期间来了新回合就取消），再 append 一条**占位条目**（`:46-48`）。这一步不读对话，也不调模型。
- **预测是懒加载的**，只有客户端调 `suggestions.predict` 时才生成（`:53-87`）：
  - 用 `refetch({direction:"tail"|"before", limit:100, projection:"projected"})` 往回翻，最多 5 页，凑够 4 条以上 user 消息就停（`:65-73`）。
  - `selectContext`：最多取最近 8 条，总长 12,000 字，单条 4,000 字，最后一条必须是 assistant（`NI/server/context.ts:5-26`）。
  - 调本机的 `claude --print --model <m> --output-format json --safe-mode --tools "" …`，30 秒超时（`NI/server/generate.ts:14-43`）。
  - 模型须返回 `{"suggestion":"…"}`，不超过 160 字、不能换行（`context.ts:28-36`）。
  - 同一个 agent + token 共用一个 Promise，多个客户端只跑一次模型，不重试（`NI/server/predictions.ts:2-15`）。

**timeline 条目**：`kind:"next-input"`，`version:1`（`NI/shared/contracts.ts:14-20`）。持久化下来的 data **永远是 idle 和空 text**，真正的建议文字只通过 RPC 拿：
```json
{"type":"plugin","id":"suggestion-6f1c…","pluginId":"next-input","kind":"next-input","version":1,
 "data":{"agentId":"a1","workspaceId":"w1","token":"6f1c…","status":"idle","text":""}}
```
- data 的字段：`{agentId, workspaceId, token, status:"idle"|"loading"|"ready"|"error", text}`。

**RPC**（`NI/shared/contracts.ts:22-38`）

| method | input | output |
|---|---|---|
| `suggestions.predict` | `{agentId, token}` | `{status:"ready"\|"empty"\|"expired"\|"unavailable"\|"error", text}` |
| `suggestions.send` | `{agentId, token, text}`（trim 后 1 到 2000 字） | `{}`，服务端调 `paseo.agents.ref(agentId).send(text)`（`NI/index.server.ts:88-91`） |
| `claude.status` | `{}` | `{path: string\|null, searched: string[]}` |

- `predict` 返回 `expired` 表示 token 过期或已经开始新回合；`unavailable` 表示找不到 CLI。
- `send` 的错误（`NI/server/send.ts:4-15`），通过 `rpc_error.error` 字符串传回：
  - `suggestion_expired`：行不存在、token 不对，或状态不是 ready。
  - `needs_edit`：文字没改，而且命中了 `requiresEditing`。
  - `suggestion_already_attempted`：同一个 token 只能发一次，不能重试。
- 安全闸门 `requiresEditing`（`NI/shared/safety.ts:2-11`）：反引号、`rm`/`sudo`/`curl`/`ssh`、`git push/reset`、`--force`/`-f`、路径、URL、token/secret/password，以及中英文的「删除 / 推送 / 部署 / 发布 / 强制」等词。命中时必须先编辑才能发送。

**设置**：`id:"preferences"`（RPC 为 `settings.preferences.*`），version 1（`NI/shared/contracts.ts:5-12`）

| key | 类型 | 默认值 |
|---|---|---|
| `enabled` | boolean | `true` |
| `model` | `"haiku"`\|`"sonnet"`\|`"opus"`\|`"custom"` | `"haiku"` |
| `customModel` | string，须匹配 `[A-Za-z0-9._\-\[\]]+` 且不以 `-` 开头（`NI/shared/model.ts:1-3`） | `""` |

- 校验规则（refine）：`model=="custom"` 时 `customModel` 必须合法；否则 `customModel` 必须为空。

**UI 贡献**（`NI/index.client.tsx`）
1. `addTimelineRenderer({kind:"next-input", version:1})`（`:39`），组件 `Row` 在 `:12-38`：
   - agent 状态是 `idle` 且这行还没失效时，才调一次 `suggestions.predict`（`:21-29`）。agent 一变成 running，这行就永久失效（`:17-20`）。
   - 结果是 ready 或 error 才显示（`:30-34`）。
   - 折叠态（`NI/client/editor.tsx:32-42`）：一行 12pt 淡色「✨ text」，点文字展开；旁边有发送图标，命中 `requiresEditing` 时隐藏。用 `marginTop:-16` 贴在上一行下面。
   - 展开态（`:43-62`）：提示语、多行输入框（最多 2000 字）、Copy / Send / Cancel 三个按钮。
   - 发送成功后这行消失；发送失败显示「未能确认发送成功…」，并禁止再次发送。
   - 草稿按 token 存在内存里（`NI/client/drafts.ts:11-26`）。
2. `addSettingsScreen({id:"preferences", title:"下一句建议", icon:"Sparkles"})`（`:10`，`NI/client/settings.tsx:10-45`）：
   - `enabled` 开关。
   - 模型选择，加自定义 ID 输入框和「保存模型」按钮。
   - Claude CLI 状态：显示找到的路径，或者列出查过的路径，加「重新检查」按钮（调 `claude.status`）。
   - 隐私说明（`NI/client/locales/zh-CN.json:20-21`）。
3. 它不碰 composer，没有用 `addComposerPill`。

**原生方案**
- 时间线：遇到 `next-input` 条目时，只在两个条件同时满足时才渲染：它是该 agent 时间线的**最后一个条目**（或者最后一个 assistant 消息后面紧跟着的条目），并且 agent 是 `idle`。
  - 满足后调一次 `predict`，按 token 缓存结果。
  - 折叠态：`HStack { Text("✨ " + text).font(.caption).foregroundStyle(.secondary); Button(paperplane) }`，用 Swift 移植的 `requiresEditing` 决定是否隐藏发送按钮。
  - 展开态：`TextEditor` 加 Copy / Send / Cancel。
  - agent 进入 running 后隐藏这一行。
- **Composer 集成（比官方好用的地方）**：加一个「填入输入框」动作，把建议写进我们 composer 的草稿。之后走普通的发消息流程，不经过 `suggestions.send`。代价是失去服务端的一次性发送和 `needs_edit` 保护，但用户本来就要在 composer 里检查一遍，可以接受。直接「发送」仍然走 `suggestions.send`。
- 设置页：`Toggle`、`Picker`（Haiku / Sonnet / Opus / 自定义）、自定义时显示的 `TextField`（本地正则校验）、CLI 状态行加「重新检查」、隐私说明。

### 2.6 agent-taskboard（看板）— running

**作用**：给 Paseo 加一个入口，打开本机 agent-taskboard 看板服务的网页。**这个页面是本地 URL 的 iframe（webview），不是用 RPC 数据画出来的列表。** 插件版本 0.1.0（`TB/package.json:4`），没有设置，没有 timeline 条目。

**服务端**：只注册了一个 RPC `board.locate`（`TB/index.server.ts:5-8`）。

| method | input | output |
|---|---|---|
| `board.locate` | `{paths: string[]}`，按 workspace 目录、项目根目录的顺序 | `{url: string, reachable: boolean, error?: string, project: string\|null}` |

- 实现（`TB/server/board.ts:49-74`）：
  - 请求 `http://127.0.0.1:7788/api/projects`（`BOARD_URL`，`TB/shared/board.ts:5`），8 秒超时。
  - 用 `Bearer` 鉴权，token 取环境变量 `BOARD_TOKEN`，没有就读 `~/.project-board/token`（`TB/server/board.ts:7-14`）。
  - 对路径 `realpath` 后按最长前缀匹配项目，跳过 `missing` 的（`:34-47`）。
  - 失败时返回 `reachable:false`，`error` 为 `"HTTP 401"`、`"连接超时"` 或其他异常信息，`project:null`。
- 看板服务本身由独立的 agent-taskboard 进程在 7788 端口提供，**不归插件管**。本机探测：`GET /` 返回 200（SPA）；不带 token 请求 `/api/projects` 返回 `{"error":"unauthorized"}`。

**UI 贡献**（`TB/index.client.tsx`）
1. `addScreen({id:"board", title:"看板"})`（`:39`），组件 `BoardScreen` 在 `TB/client/board-screen.tsx:10-77`：
   - 用 params `{dir?, root?}` 调 `board.locate({paths:[dir, root]})`（`:12-18`）。
   - **非 web 平台（官方的 iOS / Android）只显示「请在电脑端打开看板」**（`:37-44`）。
   - 不可达时显示「看板服务没有响应」、URL、原因和「重试」（`:46-68`）。
   - 成功时显示 iframe，地址为 `url + "/p/" + 每段分别编码的项目名`（匹配不到项目就用首页）`+ "?sidebar=collapsed"`（`:71-75`、`TB/shared/board.ts:22-24`、`TB/client/web.ts:14-22`）。
2. `addSidebarHeaderItem({id:"board", title:"看板"})`（`:40`）：侧边栏顶部一行，图标 `SquareKanban`，看板打开时高亮。点击时：
   - 从当前桌面路由 `/h/<host>/(workspace|agent)/<id>` 推出当前 workspace（`TB/client/web.ts:45-50`）。
   - 是 agent 路由时，先 `agents.ref().refresh()` 拿到所属 workspace（`:22-35`）。
   - 然后用 `{dir, root}` 打开看板；推不出来就打开首页。
3. `addCommandCenterItem({id:"open-project-board", title:"打开本项目看板", context:"workspace"})`（`:41-49`）。
4. 插件自写的 `contributeWorkspaceButtons`（`TB/client/workspace-buttons.ts:10-75`）：
   - 订阅 `workspaces.list({subscribe:{}})`。
   - 给每个 workspace 加一个 `addHeaderButton({id:"board", button:{title:"打开本项目看板", icon:"SquareKanban", behavior:{kind:"action"}}})`。
   - 点击后用 `{dir: workspaceDirectory, root: projectRootPath}` 打开看板。

**原生方案**
- 侧边栏顶部加一行「看板」（SF Symbol `rectangle.split.3x1`），workspace 顶栏工具栏加一个同功能按钮，命令面板加「打开本项目看板」。
- `BoardView`：
  1. 调 `board.locate {paths:[workspace.directory, workspace.projectRootPath]}`。
  2. `reachable == false` 时显示 `ContentUnavailableView`，内容为原因和「重试」。
  3. 成功时用 `WKWebView`（macOS 下包一层 `NSViewRepresentable`）加载 `url + projectPath + "?sidebar=collapsed"`。
- **限制**：`127.0.0.1:7788` 是 daemon 所在机器的回环地址，只有原生 App 和 daemon 在同一台 Mac 上时才能打开。
  - 判断方法：连接的是本地 socket 或 localhost host。
  - 其他情况（iOS、远程 host、中继）跟官方一样，显示「仅在运行 daemon 的电脑上可用」，同时给出 URL，方便复制。
- 不建议做原生列表：那样要绕过 daemon 直接请求 `/api/projects`，还要拿到看板 token。

---

## 3. 实现计划（按优先级）

**P0：插件基础设施（PaseoKit）**
1. hello capabilities 加 `"plugin_timeline_items": true`（`HostStore.swift:170`）。事件订阅加上 `status.plugin_catalog_changed` 和 `status.plugin_settings_changed`。
2. `PluginClient`：
   - `list()` 对应 `plugin.list`。
   - `invoke<I: Encodable, O: Decodable>(pluginId, method, input)` 对应 `plugin.rpc.invoke`，`rpc_error` 映射成 `PluginRPCError(message)`。
   - 维护 `pluginsById`，只有 `status=="running"` 的插件才启用对应的原生 UI。收到 `plugin_catalog_changed` 时重新拉列表。
3. `PluginSettingsStore<Values: Codable>`：read / write(整个 values, revision) / reset，处理 conflict（重新 read 并提示），收到 `plugin_settings_changed(pluginId, settingsId)` 时重新 read。
4. `AgentTimelineItem.plugin` 解码，按 `(pluginId, kind, version)` 分派渲染，按 `id` upsert。未知的条目不显示。
5. 设置 → 插件 列表：显示名称、状态（running / disabled / failed）、`error`、启用开关（`plugin.enable/disable`）、重载、日志（`plugin.logs.get`）。插件的中文名在客户端写死。

**P1：只读、收益高**
6. turn-speed 时间线行：最简单，用来验证 P0 的第 4 步。
7. usage-reset 侧边栏底部和浮层：和内置 Usage 合并；同时打通 settings 写入（`hidden`）。

**P2：交互复杂一些**
8. next-input：时间线建议行，加 predict 和 send，加「填入输入框」；再做设置页。
9. title-style 设置页：纯 settings 表单。

**P3**
10. agent-taskboard：侧边栏入口、顶栏按钮，加 `WKWebView`，只在本机时可用。
11. claude-update：等插件兼容 0.14 后再做。现在只在插件列表里显示 failed 和原因。

## 4. 未确认

- 有没有办法通过协议拿到插件图标（manifest 的 `icon` 是相对路径）和 manifest 里的 `translations`。我没找到，目前当作拿不到处理。
- claude-update 上游有没有兼容 0.14 的版本，需要联网查。
- 只有只读权限的配对设备：插件 RPC 需要 `daemon.manage`，所以 next-input 预测、usage-reset 写 settings、看板定位在这种设备上都会失败。官方 App 在这种情况下怎么降级显示，我没有细查。
- next-input 的「最后一个条目」判定：官方靠 agent 状态和 running 后失效来控制，并不显式判断是不是最后一行。如果历史里留下多条 idle 占位条目，翻看旧回合时会不会去调 predict（服务端应该会返回 `expired`），没有实测。
- agent-taskboard 在原生 macOS 上用 WKWebView 加载 `http://127.0.0.1` 需要 ATS 例外（`NSAllowsLocalNetworking`），工程配置还没确认。
