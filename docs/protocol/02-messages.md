# 02 · Paseo 应用层消息（v0.14.0）

> 来源：`vendor/paseo`（tag `v0.14.0`）。下文所有 `path:line` 均相对 `vendor/paseo/`。
> 前置：[01-connection.md](./01-connection.md)（传输、E2EE、`hello`/`server_info`、信封、`requestId`/`rpc_error`、重连）。本文只讲 **`{"type":"session","message":…}` 里面的东西**。
> 标注 **未确认** 的地方表示源码里看不到、或只能推断。
> 示例 JSON 只写 `message` 内层；发送时套上 `{"type":"session","message":<这里>}`。

---

## 0. 速览：v1 原生 App 的消息流

```
connect ─ hello(caps) ─▶ server_info(features)
   │
   ├─ project.list.request                     ─▶ project.list.response          （项目）
   ├─ fetch_workspaces_request{subscribe:{}}   ─▶ fetch_workspaces_response + workspace_update*   （工作区，实时）
   ├─ fetch_agents_request{scope:"active",subscribe:{}} ─▶ fetch_agents_response + agent_update*  （会话列表，实时）
   ├─ session.events.set_subscription.request{events:[agent_permission_request, agent_permission_resolved,
   │        agent_attention_required, project.update, …], notifications:true}  ─▶ 对应推送
   ├─ client_heartbeat（每 15 s / 前后台切换 / 焦点变化）
   │
   打开某会话：
   ├─ agent.timeline.set_subscription.request{agentIds:[id]} ─▶ agent_stream* / agent.timeline.replacement
   ├─ fetch_agent_timeline_request{direction:"tail",limit:40,wholeTurns:true} ─▶ fetch_agent_timeline_response
   ├─ （上滑）fetch_agent_timeline_request{direction:"before",cursor:startCursor}
   ├─ （发现 seq 缺口）fetch_agent_timeline_request{direction:"after",cursor:endCursor}，直到 hasNewer=false
   │
   操作：
   ├─ send_agent_message_request{messageId, activeTurnBehavior:"interrupt"|"steer", images?, attachments?}
   ├─ cancel_agent_request
   ├─ agent_permission_response{agentId, requestId:<permission.id>, response}
   ├─ agent.create.request / update_agent_request{name} / archive_agent_request / refresh_agent_request(取消归档)
   └─ set_agent_mode_request / set_agent_model_request / set_agent_thinking_request / agent.config.apply.request
```

---

## 1. 订阅模型（必须先理解，否则什么推送都收不到）

### 1.1 现代模式 vs 旧广播模式

Daemon 对每个物理 socket 判断它是否 "modern"：`hello.capabilities.owned_subscriptions === true` 即 modern（`packages/server/src/server/session.ts:1303`）。

| | modern（推荐） | legacy（COMPAT，计划 2027-03-09 移除） |
| --- | --- | --- |
| 连接后 | **零推送**：不发任何 agent/workspace/timeline/事件（`docs/protocol-compatibility.md:43-49`） | 隐式广播大部分事件 |
| 列表推送 | 列表请求带 `subscribe: {}` 才建立订阅；同类可多个并存、各自独立过滤 | 同类订阅「后请求覆盖前请求」 |
| 订阅 ID | **由 Host 分配**；请求里带 `subscriptionId` 会报错（`packages/server/src/server/session/owned-subscriptions/index.ts:285-288`） | 可由客户端指定 |
| 事件（权限、attention…） | 必须 `session.events.set_subscription.request` 显式订阅（`session.ts:8487-8516`） | 默认广播（`session.ts:8794-8812`） |
| Timeline | 必须 `agent.timeline.set_subscription.request` | 无 `selective_agent_timeline` 能力时全量广播所有 agent 的流 |

**Swift v1 采用 modern 模式**，下文默认如此。

### 1.2 建议的 hello 能力集

官方默认集见 `packages/client/src/connection/index.ts:127-146`。v1 建议发送（只广播自己真的实现了的语义，`docs/protocol-compatibility.md:36-41`）：

```json
"capabilities": {
  "hello_rejection": true,
  "owned_subscriptions": true,
  "explicit_event_subscriptions": true,
  "selective_agent_timeline": true,
  "timeline_replacement_invalidation": true,
  "timeline_notifications": true,
  "reasoning_merge_enum": true,
  "all_providers": true,
  "custom_mode_icons": true,
  "project_updates": true
}
```

| 能力 | 不发的后果 |
| --- | --- |
| `timeline_notifications` | Daemon 会**过滤掉** `notification` 类时间线条目（`session.ts:1352-1360`）。发了就要能渲染 |
| `plugin_timeline_items` | 不发则过滤掉 `plugin` 条目——v1 不渲染插件条目，**建议不发** |
| `reasoning_merge_enum` | 不发则 `collapsed` 数组里去掉 `"reasoning_merge"`（`session.ts:7853-7859`） |
| `timeline_replacement_invalidation` | 不发则回放（rewind）后 Daemon 重放重建的时间线行，而不是发 `agent.timeline.replacement` |
| `custom_mode_icons` | 不发则模式图标被降级为 `ShieldCheck`；发了就要容忍任意 icon 字符串 |
| `all_providers` | 不发则可能隐藏非内置 provider 的 agent（`session.ts:2137-2140` 附近，**未确认**完整规则） |
| `compact_provider_snapshots` / `provider_snapshot_references` | v1 **不发**：避免处理压缩 provider 目录（**未确认**压缩模式下 `entries` 是否仍完整） |
| `provider_subagents` / `projected_subagent_timeline` | v1 不做 provider 子代理，**不发** |
| `workspace_setup_observation` / `workspace_setup_blocked` / `terminal_reflowable_snapshot` | v1 不做，**不发** |

### 1.3 订阅的生命周期

- 订阅型请求的响应（例如 `fetch_agents_response`）`payload.subscriptionId` 为新 ID；之后的推送（`agent_update` 等）`payload.subscriptionId` 等于它，用于路由（`packages/client/src/connection/owned.ts:193-206`）。
- 释放：`{"type":"subscription.release.request","requestId":"r1","subscriptionId":"<id>"}` → `subscription.release.response{payload:{requestId,subscriptionId}}`（`messages.ts:3245-3252`，`session.ts:2405-2413`）。
- **每次请求都会新建一个订阅**，不是「设置」语义。例如再次发 `agent.timeline.set_subscription.request` 会再加一个 timeline 订阅，旧的要自己 release（`session.ts:1342-1350,2813-2823`）。官方客户端换查询时先 release 旧订阅再建新的（`packages/app/src/runtime/directory-sync/index.ts:614-616,718-720`）。
- 订阅属于物理 socket；断线即作废；重连后全部重建并拿到新 ID（`owned.ts:208-218`，见 01 §5.4）。
- 客户端本地：订阅响应之前到达的同 ID 推送要缓冲（官方最多 128 条，溢出则重新订阅，`owned.ts:31,129-137,166-174`）。实际上 Daemon 先发响应再 flush 引导期间累积的更新（`session.ts:6283-6294`），但跨 actor 的 Swift 实现仍应按 ID 缓冲。

### 1.4 事件订阅

```json
{"type":"session.events.set_subscription.request","requestId":"r2",
 "events":["agent_permission_request","agent_permission_resolved","agent_attention_required","project.update","status.server_info"],
 "notifications":true}
```
→ `{"type":"session.events.set_subscription.response","payload":{"requestId":"r2","subscriptionId":"<id>"}}`

可订阅事件全集（`messages.ts:3202-3220`）：`project.update`、`providers_snapshot_update`、`agent_attention_required`、`agent_permission_request`、`agent_permission_resolved`、`checkout_status_update`、`script_status_update`、`workspace_setup_progress`、`agent.provider_subagents.update`、`terminal_attention_required`、`status.server_info`、`status.daemon_config_changed`、`status.plugin_catalog_changed`、`status.plugin_settings_changed`、`activity_log`、`hub.execution.agent.update`、`hub.execution.agent.stream`。

`notifications: true` 的作用：只有带此标志订阅了 `agent_attention_required` 的 socket 才参与「谁来弹应用内通知 / 是否推送」的计算（`session.ts:2312-2321`，`packages/server/src/server/websocket-server.ts:2814-2816`，详见 §7）。官方 App 订阅：`agent_attention_required, terminal_attention_required, agent_permission_request, agent_permission_resolved, agent.provider_subagents.update, checkout_status_update, status.server_info`，`notifications: true`（`packages/app/src/contexts/session-context.tsx:484-497`）。

---

## 2. 数据模型

### 2.1 Host（daemon）

一个 daemon = 一个 host，身份是 `server_info.serverId`（形如 `srv_…`，持久化在 `$PASEO_HOME/server-id`，`docs/data-model.md:46-48`）。UI 有用字段（`messages.ts:3629-3847`）：`serverId`、`hostname`、`version`、`features.*`（能力开关表，见 01 §4.4）、`permissions`。官方 App 的所有缓存都以 `serverId` 为 key；**agentId / workspaceId 只在一个 host 内唯一**，跨机器展示要用 `(serverId, id)` 作复合键。

### 2.2 Project（`WorkspaceProjectDescriptorPayloadSchema`，`messages.ts:4312-4328`）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `projectId` | string | Host 内稳定 ID，新格式 `prj_<16hex>`；旧记录可能是路径/remote 形状，**当不透明字符串处理**（`docs/glossary.md`，`docs/data-model.md:3-9`） |
| `projectKey` | string? | 跨 host 的「同一逻辑项目」分组键（当前由 git remote 生成），不要解析（`docs/data-model.md:10-15`） |
| `projectDisplayName` | string | 显示名（已应用用户自定义名） |
| `projectCustomName` | string\|null? | 用户自定义名原值 |
| `projectIconRevision` / `projectCustomIconRevision` | string? | 图标缓存键（图标通过 `project.icon.get.request` 取，v1 可后做） |
| `projectRootPath` | string | 根目录 |
| `projectKind` | `"git"\|"non_git"\|"directory"` | |
| `syncSeq` | int? | 目录同步序号（§3.5） |

### 2.3 Workspace（`WorkspaceDescriptorPayloadSchema`，`messages.ts:4110-4185`）

一个 workspace = 一台 daemon 上的一个具体目录（可能是 worktree），属于唯一的 project（`docs/glossary.md`）。

| 字段 | 说明 |
| --- | --- |
| `id` | 不透明 ID（新格式 `wks_<16hex>`，`messages.ts:2692-2695`） |
| `projectId`、`projectDisplayName`、`projectRootPath`、`projectKind` | 所属项目的冗余信息 |
| `name` | 显示名（已应用 `title`）；`title` 为用户自定义原值，可 null |
| `workspaceDirectory` | 实际目录（缺省回落 `projectRootPath`） |
| `workspaceKind` | `"directory"\|"local_checkout"\|"checkout"\|"worktree"`（`checkout` 为旧值） |
| `status` | 聚合状态桶 `"needs_input"\|"failed"\|"running"\|"attention"\|"done"`（`messages.ts:1310-1316`），按 `workspaceId` 聚合 agent/终端状态（`docs/agent-lifecycle.md:585-602`） |
| `statusEnteredAt`、`activityAt`、`createdAt`、`lastUserMessageAt` | 排序/显示用时间戳（ISO 8601） |
| `pinnedAt` | 置顶时间，null 未置顶 |
| `archivingAt` | 正在归档 |
| `background` | 后台工作区（默认列表排除，§3.2） |
| `labels` | 工作区标签名数组 |
| `diffStat` | `{additions,deletions}` |
| `gitRuntime` | `{currentBranch, remoteUrl, isPaseoOwnedWorktree, isDirty, aheadBehind, aheadOfOrigin, behindOfOrigin}`（`messages.ts:4044-4061`） |
| `githubRuntime` | PR 状态等（字段名是历史遗留，内容 forge 中立，`messages.ts:4063-4108`）；v1 可只显示 PR 标题/状态 |
| `scripts`、`setupStatus`、`worktreeSlug`、`forge`、`project` | v1 可忽略 |

状态桶推导规则（单个 agent）：有待批权限或 `attentionReason=="permission"` → `needs_input`；`status=="error"` 或 `attentionReason=="error"` → `failed`；`running` → `running`；`requiresAttention` → `attention`；否则 `done`（`packages/protocol/src/agent-state-bucket.ts:21-36`）。会话列表上的状态徽标建议直接复用这个函数。

### 2.4 Agent（会话）快照（`AgentSnapshotPayloadSchema`，`messages.ts:853-884`）

所有列表、`agent_update`、`fetch_agent_response`、时间线响应里的 `agent` 都是这个形状。

| 字段 | 类型 | UI 用途 |
| --- | --- | --- |
| `id` | string (UUID) | 主键（Host 内） |
| `provider` | string | `"claude"`、`"codex"`、`"opencode"`、`"copilot"`、`"pi"`、`"omp"` 或自定义 ID（`docs/data-model.md:270-273`）；**开放字符串**，不要做成封闭 enum |
| `cwd` | string | 工作目录 |
| `workspaceId` | string? | 所属 workspace（归属唯一来源，不要用 cwd 推断，`docs/data-model.md:79`） |
| `title` | string\|null | 标题；创建后可能先为 null，再由 Daemon 异步生成并以 `agent_update` 推送 |
| `status` | `"initializing"\|"idle"\|"running"\|"error"\|"closed"` | `closed` = 无运行时但可恢复（不等于归档，`docs/agent-lifecycle.md:12-18`） |
| `activeTurn` | `{turnId, startedAt}\|null`? | 当前回合；`startedAt` 用于「已运行 N 秒」 |
| `model` | string\|null | 当前模型 ID |
| `thinkingOptionId` / `effectiveThinkingOptionId` | string\|null? | 思考档位（请求值 / 实际生效值） |
| `currentModeId` | string\|null | 当前模式（权限模式，如 Claude 的 `default`/`acceptEdits`/`plan`/`bypassPermissions`） |
| `availableModes` | `AgentMode[]` | `{id,label,description?,icon?,colorTier?}`（`messages.ts:300-306`） |
| `features` | `AgentFeature[]`? | provider 开关/下拉（`messages.ts:329-354`） |
| `pendingPermissions` | `AgentPermissionRequest[]` | **待批权限的权威列表**（§5） |
| `capabilities` | `AgentCapabilityFlags` | `supportsStreaming`、`supportsReasoningStream`、`supportsRewind*` 等（`messages.ts:408-424`） |
| `createdAt` / `updatedAt` / `lastUserMessageAt` | ISO string | 排序 |
| `lastUsage` | `{inputTokens,cachedInputTokens,outputTokens,totalCostUsd,contextWindowMaxTokens,contextWindowUsedTokens}`? | 上下文用量条 |
| `lastError` | string? | 错误态说明 |
| `labels` | `Record<string,string>` | `paseo.parent-agent-id` → 父 agent（子代理）；`paseo.parent-server-id` → 父 agent 所在 host（缺省同 host）；`paseo.open-agent-tab.<clientId>` 为各客户端的标签页标记（`packages/protocol/src/agent-labels.ts:1-53`） |
| `requiresAttention` / `attentionReason` / `attentionTimestamp` | bool? / `"finished"\|"error"\|"permission"\|null`? / string? | 「未读」与原因 |
| `archivedAt` | string\|null? | 非 null = 已归档（软删除） |
| `providerUnavailable` | bool? | provider 未安装/被移除 |
| `runtimeInfo` / `persistence` | | 调试用，v1 忽略 |
| `internal` | bool? | 私有 helper，公开列表不会出现 |

子代理：`labels["paseo.parent-agent-id"]` 非空即为子代理；官方「子代理轨」= `parentAgentId == thisAgent.id && !archivedAt`（`docs/agent-lifecycle.md:610-614`）。v1 会话列表建议默认**隐藏子代理**，只在父会话里显示数量。

另有精简版 `AgentListItemPayloadSchema`（`messages.ts:888-907`），目前列表 RPC 不使用它（**未确认**用途，疑似 MCP/CLI）。

### 2.5 Placement（`ProjectPlacementPayloadSchema`，`messages.ts:4021-4026`）

列表条目和 `agent_update.upsert` 会带 `project`：`{projectKey, projectName, workspaceName?, checkout}`，`checkout` 三选一：非 git `{cwd,isGit:false}`、普通 git `{cwd,isGit:true,currentBranch,remoteUrl,isPaseoOwnedWorktree:false,…}`、Paseo worktree `{…,isPaseoOwnedWorktree:true,mainRepoRoot}`（`messages.ts:3970-4019`）。用于在会话行上显示「项目 · 分支」，不用再查 workspace。

---

## 3. 列表与实时更新

### 3.1 项目

```json
{"type":"project.list.request","requestId":"r3"}
```
→ `project.list.response{payload:{requestId, projects:[WorkspaceProjectDescriptor], sync?}}`（`messages.ts:1356-1361,4465-4472`）。

实时：事件订阅 `project.update`（§1.4），推送 `project.update{payload:{subscriptionId, kind:"upsert", project} | {kind:"remove", projectId}, generation?, seq?}`（`messages.ts:4445-4463`）。需要 hello 带 `project_updates` 能力（`session.ts:8791`）。

注意：官方 App 也从 `fetch_workspaces_response.emptyProjects` 拿「没有活跃 workspace 的项目」（只在第一页返回，`messages.ts:4336-4339`）。

### 3.2 工作区

```json
{"type":"fetch_workspaces_request","requestId":"r4",
 "includeBackground":false,
 "sort":[{"key":"activity_at","direction":"desc"}],
 "page":{"limit":200},
 "subscribe":{}}
```
（`messages.ts:1318-1354`）

- `filter`：`{query?, projectId?}`；`sort.key`：`status_priority|activity_at|name|project_id`；`page.limit ≤ 200`，有 `pageInfo.nextCursor` 则继续翻页（**只在第一页带 `subscribe`**，`packages/app/src/runtime/directory-sync/index.ts:600-635`）。
- `includeBackground`：后台工作区默认排除（`docs/agent-lifecycle.md:492-506`）；需 `features.backgroundWorkspaces`。v1 建议默认 `false`。
- 响应 `fetch_workspaces_response{payload:{requestId, subscriptionId?, entries:[WorkspaceDescriptor], emptyProjects:[…], pageInfo:{nextCursor,prevCursor,hasMore}, sync?}}`（`messages.ts:4330-4347`）。
- 推送 `workspace_update{payload:{subscriptionId, kind:"upsert", workspace} | {kind:"remove", id, emptyProject?, removedProjectId?}}`（`messages.ts:4349-4377`）。`remove` 也用于归档 workspace；`removedProjectId` 表示项目被移除。

### 3.3 会话（agent）列表——活跃

官方 App 的写法（`packages/app/src/runtime/directory-sync/index.ts:42-44,697-735`）：

```json
{"type":"fetch_agents_request","requestId":"r5",
 "scope":"active",
 "sort":[{"key":"updated_at","direction":"desc"}],
 "page":{"limit":200},
 "subscribe":{}}
```

- `scope:"active"`：只返回未归档且所在 workspace 仍活跃的 agent（`session.ts:5522-5531`）。
- `filter`（`messages.ts:948-958`）：`labels`（全等匹配）、`projectKeys`、`statuses`、`includeArchived`、`requiresAttention`、`thinkingOptionId`、`includeBackground`。
- `sort.key`：`status_priority|created_at|updated_at|title`。
- 响应（`messages.ts:4251-4278`）：

```json
{"type":"fetch_agents_response","payload":{
  "requestId":"r5","subscriptionId":"3f0c…",
  "entries":[{"agent":{…AgentSnapshot…},"project":{…Placement…}}],
  "pageInfo":{"nextCursor":null,"prevCursor":null,"hasMore":false}
}}
```

- 推送 `agent_update`（`messages.ts:4187-4206`）：

```json
{"type":"agent_update","payload":{"subscriptionId":"3f0c…","kind":"upsert",
  "agent":{"id":"8b1d…","provider":"claude","cwd":"/Users/me/projects/app","workspaceId":"wks_1a2b3c4d5e6f7a8b",
           "model":"claude-opus-4-1","title":"修复登录页崩溃","status":"running",
           "activeTurn":{"turnId":"turn_7","startedAt":"2026-11-03T03:12:09.120Z"},
           "currentModeId":"default","availableModes":[{"id":"default","label":"Default"},{"id":"plan","label":"Plan"}],
           "pendingPermissions":[],"capabilities":{"supportsStreaming":true,"supportsSessionPersistence":true,"supportsDynamicModes":true,"supportsMcpServers":true,"supportsReasoningStream":true,"supportsToolInvocations":true},
           "persistence":null,"labels":{},"createdAt":"2026-11-03T02:58:00.000Z","updatedAt":"2026-11-03T03:12:09.200Z",
           "lastUserMessageAt":"2026-11-03T03:12:09.000Z","requiresAttention":false,"attentionReason":null,"archivedAt":null},
  "project":{"projectKey":"github.com/me/app","projectName":"app","workspaceName":"main",
             "checkout":{"cwd":"/Users/me/projects/app","isGit":true,"currentBranch":"main","remoteUrl":"git@github.com:me/app.git","isPaseoOwnedWorktree":false}}}}
```
或 `{"kind":"remove","agentId":"…"}`。

**语义**：每次 agent 变化（状态、标题、模式、待批权限、attention…），Daemon 对每个订阅重新判断过滤条件：匹配 → `upsert`（**完整快照，直接替换**），不匹配 → `remove`（`packages/server/src/server/session/agent-updates/agent-updates-service.ts:125-153,266-291`）。所以**归档的 agent 在默认订阅里表现为 `remove`**；`includeArchived:true` 的订阅里则是带 `archivedAt` 的 `upsert`。

### 3.4 会话列表——历史（含已归档）

```json
{"type":"fetch_agent_history_request","requestId":"r6",
 "search":"登录",
 "sort":[{"key":"updated_at","direction":"desc"}],
 "page":{"limit":50}}
```
→ `fetch_agent_history_response{payload:{requestId, entries, pageInfo, searchTruncated?}}`（`messages.ts:1363-1384,4280-4289`）。

- **默认包含已归档**（未指定 `filter.includeArchived` 时服务端补 `true`，`session.ts:5507-5511`），也包含 provider 不可用的持久化记录。
- `search`：对标题、workspace 名、分支、项目名做文本过滤。
- **没有订阅**，纯分页快照；官方 App 用它做「历史」页（`packages/app/src/hooks/use-agent-history.ts:16-18,74-90`）。
- 只想要「已归档」列表：`filter:{includeArchived:true}` 后客户端过滤 `archivedAt != null`（服务端无「仅归档」过滤，**未确认**有无更好方式）。

### 3.5 目录增量同步（可选优化，v1 可后做）

`features.directorySync` 时，列表请求可带 `sync:{generation?, afterSeq?}`，响应带 `sync:{generation, headSeq, mode:"snapshot"|"changes", reason?, removals:[{id,seq}]}`，条目带 `syncSeq`；推送带 `generation`/`seq`（`messages.ts:1261-1279`）。约束：agent 列表带 `sync` 时必须 `scope:"active"` 且**不能有 filter**（`session.ts:6649-6660`）。用于冷启动时只拉变化。v1 直接每次拿全量快照即可（省略 `sync` 字段 → 总是 snapshot）。

### 3.6 单个 agent

```json
{"type":"fetch_agent_request","requestId":"r7","agentId":"8b1d"}
```
`agentId` 可以是完整 ID、唯一前缀或**完整标题**（`messages.ts:1396-1401`）→ `fetch_agent_response{payload:{requestId, agent|null, project?, error|null}}`（`messages.ts:4702-4710`）。用于从通知直接打开会话时拿最新快照。

---

## 4. Agent 时间线

### 4.1 两条通道

1. **实时流** `agent_stream`：低延迟，可能是 delta（文本块追加、工具状态更新）。
2. **权威历史** `fetch_agent_timeline_request`：永远返回「投影后」的完整条目，不含 delta（`docs/timeline-sync.md:3-10`）。

Daemon 在内存里保存投影后的时间线（`packages/server/src/server/agent/agent-timeline-store.ts`）；每个源事件推进 `seq`；同一工具调用的多次状态、连续的助手文本块在投影里合并为一行。`epoch` 是这份内存时间线的代号——Daemon 重建时间线（重启后从 provider 历史恢复、rewind 等）时 epoch 变化，旧 cursor 失效。工具输出（shell）在两条通道上都截断到 64 KiB（`docs/timeline-sync.md:16-19`）。

### 4.2 订阅实时流

```json
{"type":"agent.timeline.set_subscription.request","requestId":"r8","agentIds":["8b1d…"]}
```
→ `agent.timeline.set_subscription.response{payload:{requestId, subscriptionId, agentIds}}`（`messages.ts:1958-1962,4904-4911`）。

- 一次可订多个 agent（官方 App 把「本次会话打开过的所有聊天」放在一个集合里，`docs/timeline-sync.md:199-220`）。
- 每次请求新建一个订阅；要换集合就新建再 release 旧的（§1.3）。
- 推送：`agent_stream` 与 `agent.timeline.replacement`，均带 `subscriptionId`。

### 4.3 `agent_stream` 消息

```json
{"type":"agent_stream","payload":{
  "subscriptionId":"9a7e…","agentId":"8b1d…",
  "event":{ …AgentStreamEvent… },
  "timestamp":"2026-11-03T03:12:10.512Z",
  "seq":57, "epoch":"c1f3e1d2-…"
}}
```
（`messages.ts:4208-4219`；服务端组装 `session.ts:2107-2118`）

`seq`/`epoch` **只在时间线事件上保证存在**（schema 注释「Present for timeline events」）；生命周期事件可能没有（**未确认**是否一律缺省）——客户端只对带 `seq` 的事件做序号检查。

`event` 的全部类型（`AgentStreamEventPayloadSchema`，`messages.ts:761-828`）：

| `event.type` | 字段 | 含义 / 客户端动作 |
| --- | --- | --- |
| `thread_started` | `sessionId, provider` | provider 会话建立；忽略 |
| `turn_started` | `provider, turnId?` | 回合开始 → 显示「运行中」、计时起点 |
| `turn_completed` | `provider, turnId?, usage?` | 回合正常结束；`usage` 更新上下文用量 |
| `turn_failed` | `provider, turnId?, error, code?, diagnostic?` | 回合失败；显示错误 |
| `turn_canceled` | `provider, turnId?, reason` | 被取消 |
| `timeline` | `provider, item, turnId?` | **时间线条目**（§4.6），带 `seq` |
| `permission_requested` | `provider, request` | 也会单独以 `agent_permission_request` 推送（§5），流里的这条可忽略 |
| `permission_resolved` | `provider, requestId, resolution` | 同上 |
| `attention_required` | … | **modern 客户端不会在流里收到**，改为 `agent_attention_required` 事件（`session.ts:1366-1391`） |

回合归属：带 `turnId` 的终止事件只能关闭同 `turnId` 的回合；无 `turnId` 的旧式终止事件关闭当前回合（`docs/timeline-sync.md:259-266`）。状态的**权威来源**是 `agent_update` 快照里的 `status`/`activeTurn`；流事件只用来加速 UI。

### 4.4 拉取历史

请求（`messages.ts:1907-1926`）：

```json
{"type":"fetch_agent_timeline_request","requestId":"r9","agentId":"8b1d…",
 "direction":"tail","limit":40,"projection":"projected","wholeTurns":true}
```

| 字段 | 说明 |
| --- | --- |
| `direction` | `tail`（最新一页，默认；带 cursor 时默认 `after`）/ `before`（更老）/ `after`（更新，用于补洞） |
| `cursor` | `{epoch, seq}`；`before` 用当前已加载的 `startCursor`，`after` 用 `endCursor` |
| `limit` | 投影条目数目标（不是 delta 数）；缺省 200（`agent-timeline-store.ts:24`）；`0` = 全部。官方 App 用 40（`packages/app/src/timeline/timeline-fetch-policy.ts:3`） |
| `wholeTurns` | 保证 tail/before 页按完整回合切分（可能超过 limit）；仅当 `features.wholeTurnTimeline` 时发送（`packages/client/src/daemon-client.ts:3553-3562`） |
| `projection` | 永远用 `"projected"`（服务端实际也强制 projected，`session.ts:7788`） |
| `mergeWindow` | 允许非连续窗口（跳转到某条 prompt 用），v1 不用 |

响应（`messages.ts:4717-4753`）：

```json
{"type":"fetch_agent_timeline_response","payload":{
  "requestId":"r9","agentId":"8b1d…","agent":{…AgentSnapshot…},
  "direction":"tail","projection":"projected",
  "epoch":"c1f3e1d2-…","reset":false,"staleCursor":false,"gap":false,
  "window":{"minSeq":1,"maxSeq":57,"nextSeq":58},
  "startCursor":{"epoch":"c1f3e1d2-…","seq":31},
  "endCursor":{"epoch":"c1f3e1d2-…","seq":57},
  "hasOlder":true,"hasNewer":false,
  "entries":[
    {"provider":"claude","turnId":"turn_7","timestamp":"2026-11-03T03:12:09.000Z",
     "item":{"type":"user_message","text":"登录页点提交就崩，帮我看看","messageId":"msg_5d0c…","clientMessageId":"msg_5d0c…"},
     "seqStart":51,"seqEnd":51,"sourceSeqRanges":[{"startSeq":51,"endSeq":51}],"collapsed":[]},
    {"provider":"claude","turnId":"turn_7","timestamp":"2026-11-03T03:12:12.300Z",
     "item":{"type":"tool_call","callId":"toolu_01","name":"Bash","status":"completed","error":null,
             "detail":{"type":"shell","command":"npm test -- login","cwd":"/Users/me/projects/app","output":"…","exitCode":1}},
     "seqStart":53,"seqEnd":55,"sourceSeqRanges":[{"startSeq":53,"endSeq":53},{"startSeq":55,"endSeq":55}],"collapsed":["tool_lifecycle"]}
  ],
  "error":null
}}
```

字段语义：

- `entries[].seqStart..seqEnd`：该投影条目覆盖的源序号范围；`sourceSeqRanges` 精确列出覆盖的源段（中间可能夹着别的条目的 seq，比如工具 running 与 completed 之间有文本）；`collapsed`：合并原因 `assistant_merge|reasoning_merge|tool_lifecycle|identity`。
- `startCursor`/`endCursor`：本页边界，下一次 `before`/`after` 用。`window`：Daemon 当前持有的整体范围。
- `reset:true`：cursor 无效（`staleCursor`：epoch 不同；`gap`：cursor 早于 `minSeq`），服务端**改为返回 tail**，客户端必须**丢弃本地该 agent 的时间线后替换**（`agent-timeline-store.ts:91-121`）。
- `error` 非 null 时其余字段为空壳（`session.ts:7867-7897`）；官方客户端抛错（`daemon-client.ts:3586-3589`）。
- 拉时间线会触发 `ensureAgentLoaded`：对 `closed` 的 agent 会加载其 provider 历史（可能拉起进程，`session.ts:7798-7803`，`docs/agent-lifecycle.md:557-563`）。**不要对列表里每个 agent 都预取时间线**，只拉用户打开的那个。

### 4.5 同步算法（Swift 实现建议）

依据 `docs/timeline-sync.md` 与 `packages/app/src/timeline/session-stream-reducers.ts:282-304`：

```
打开 agent A：
  1. 发 agent.timeline.set_subscription.request([A])，开始把 A 的 agent_stream 放进缓冲
  2. 发 fetch tail(limit 40, wholeTurns) → 安装 entries，记 cursor = {epoch, startSeq, endSeq}
  3. 回放缓冲：对每条带 seq 的事件按下面规则处理
收到 agent_stream（带 seq, epoch）：
  - 无 cursor            → 先缓冲（等 tail 回来）
  - epoch != cursor.epoch → 丢弃，并重新 fetch tail（epoch 已变）
  - seq <= endSeq         → 丢弃（已覆盖，"drop_stale"）
  - seq == endSeq + 1     → 应用（reduce），endSeq = seq
  - seq >  endSeq + 1     → 缺口：fetch after(cursor=endCursor)，若 hasNewer 继续用新的 endCursor 拉，
                            直到 hasNewer=false；补洞完成前到达的实时事件继续缓冲
收到 agent.timeline.replacement{agentId, epoch} → 丢弃本地 A 的时间线，重新 fetch tail
上滑到顶 → fetch before(cursor=startCursor)，只在 hasOlder 时；把结果插到前面，只接受与当前 startSeq 相邻的页
从后台回来 / 重连 → 重新订阅 + fetch after(endCursor)（或 tail）；若响应 window.maxSeq == endSeq 则什么都不做
```

要点：

- **补洞与合并**：`after` 页里的投影条目可能和已从实时流收到的内容重叠（例如助手文本已实时拼了前半段，页里给的是完整文本）。官方用 `sourceSeqRanges` 判断：若某投影助手/思考条目的某源段跨过当前 `endSeq`，就**用投影全文替换**本地对应条目，而不是追加（`docs/timeline-sync.md:222-229`，`session-stream-reducers.ts:766-800`）。简化策略：`after` 页的条目只应用 `seqEnd > 本地 endSeq` 的那些；若首条是 assistant/reasoning 且 `seqStart <= endSeq`，用其文本替换本地最后一条同类条目。
- **重试退避**：补洞/订阅失败从 1 s 起倍增到 30 s 上限；成功、重连、前后台切换时重置（`docs/timeline-sync.md:76-80`）。
- **不要用 heartbeat/焦点做投递正确性判断**（`docs/timeline-sync.md:36-45`）。

### 4.6 实时事件如何归约成 UI 行

依据 `packages/app/src/types/stream.ts:922-985,1515-1580`：

| item.type | 归约规则 |
| --- | --- |
| `user_message` | 新行；按 `messageId`/`clientMessageId` 去重（我方乐观插入的行用同一 `clientMessageId` 认领） |
| `assistant_message` | **text 是增量块**：若最后一行是 assistant 且（`messageId` 缺省或相同）→ 追加文本；否则新起一行。中断时若最后一行是刚提交的 user 行，则追加到倒数第二行的 assistant |
| `reasoning` | 增量块：若最后一行是 thought 且 `turnId` 相同 → 追加；否则新行。遇到任何非 reasoning 事件 → 把 thought 标记完成 |
| `tool_call` | 按 `callId` **upsert**：同 callId 的后续事件（running→completed/failed/canceled）替换前一状态，位置保留在首次出现处 |
| `todo` | 整个列表替换（显示为任务清单） |
| `error` | 显示为错误通知行 |
| `notification` | 显示为 info/warning/error 通知行 |
| `compaction` | `loading` 行，随后 `completed` 更新同一行 |
| `plugin` | v1 忽略（并且不发 `plugin_timeline_items` 能力） |

Daemon 端对文本/工具事件做了 60 ms 的合并窗口（`packages/server/src/server/agent/agent-stream-coalescer.ts:3`），所以实时块不会过碎。

### 4.7 时间线条目全目录（`AgentTimelineItemPayloadSchema`，`messages.ts:707-759`）

注意：这是 **`z.union` 而不是 discriminated union**；`tool_call` 再按 `status` 区分（`messages.ts:668-703`）。Swift 侧用 `type` 字段分派，未知 `type` 保留为 `unknown` 不崩溃。

#### `user_message`
```json
{"type":"user_message","text":"把 README 里的安装步骤更新一下","messageId":"msg_3e9a7c1b","clientMessageId":"msg_3e9a7c1b"}
```
`features.canonicalSubmittedPrompts` 时，带 `messageId` 发送的 prompt 会以**同一 ID** 作为 `messageId`（以及 `clientMessageId`）回显成规范行（`docs/timeline-sync.md:252-258,295-299`）。图片/附件**不会回显**（`docs/timeline-sync.md:231-235`），本地要自己保留缩略图。

#### `assistant_message`
```json
{"type":"assistant_message","text":"我先看一下当前的安装步骤。","messageId":"msg_01HZX…"}
```
Markdown 文本；实时流里是增量块，历史里是合并后的全文。

#### `reasoning`（思考）
```json
{"type":"reasoning","text":"README 里有两处提到 npm install，需要统一成 pnpm……"}
```

#### `tool_call`
公共字段：`callId`、`name`（provider 原始工具名，如 `Bash`、`Read`、`Edit`、`mcp__paseo__create_agent`）、`status`（`running|completed|failed|canceled`）、`error`（仅 failed 非 null，任意 JSON）、`detail`（下表）、`metadata?`、`agentMessage?`。

`detail.type` 全集（`messages.ts:569-666`）：

| detail.type | 字段 | 渲染建议 |
| --- | --- | --- |
| `shell` | `command, cwd?, output?, exitCode?` | 终端样式；`output` ≤ 64 KiB |
| `read` | `filePath, content?, offset?, limit?` | 「读取 <文件>」可展开内容 |
| `edit` | `filePath, oldString?, newString?, unifiedDiff?` | **diff 视图**：优先 `unifiedDiff`，否则用 old/new 自行生成 |
| `write` | `filePath, content?` | 新文件内容 |
| `search` | `query, toolName?(search/grep/glob/web_search), content?, filePaths?, webResults?[{title,url}], numFiles?, numMatches?, …` | 搜索结果 |
| `fetch` | `url, prompt?, result?, code?, codeText?, bytes?, durationMs?` | 网页抓取 |
| `sub_agent` | `subAgentType?, description?, childSessionId?, log, actions?` | 子任务卡片 |
| `plain_text` | `label?, text?, icon?` | 通用文本卡片（icon 取 `TOOL_CALL_ICON_NAMES`：wrench/square_terminal/eye/pencil/search/bot/sparkles/brain/mic_vocal，`agent-types.ts:201-211`） |
| `plan` | `text` | 计划（Markdown） |
| `worktree_setup` | `worktreePath, branchName, log, commands[], truncated?` | 旧数据兼容 |
| `unknown` | `input, output`（任意 JSON） | 折叠显示 JSON |

running 示例（实时流）：
```json
{"type":"tool_call","callId":"toolu_01","name":"Bash","status":"running","error":null,
 "detail":{"type":"shell","command":"npm test -- login","cwd":"/Users/me/projects/app"}}
```
完成（同 callId 的后续事件）：
```json
{"type":"tool_call","callId":"toolu_01","name":"Bash","status":"completed","error":null,
 "detail":{"type":"shell","command":"npm test -- login","cwd":"/Users/me/projects/app",
           "output":"FAIL src/login.test.ts\n  ✕ submits form (12 ms)\n","exitCode":1}}
```
编辑（diff）：
```json
{"type":"tool_call","callId":"toolu_02","name":"Edit","status":"completed","error":null,
 "detail":{"type":"edit","filePath":"/Users/me/projects/app/src/login.tsx",
           "oldString":"onSubmit={submit}","newString":"onSubmit={handleSubmit}",
           "unifiedDiff":"@@ -42,1 +42,1 @@\n-  onSubmit={submit}\n+  onSubmit={handleSubmit}\n"}}
```
失败：
```json
{"type":"tool_call","callId":"toolu_03","name":"Read","status":"failed",
 "error":{"message":"File does not exist."},"detail":{"type":"read","filePath":"/Users/me/projects/app/src/old.ts"}}
```
**跨 agent 消息**：`agentMessage:{event:"message"|"finished"|"errored"|"permission-required"|"closed", sender:{id, serverId?, title?}, text}`（`packages/protocol/src/agent-message.ts:4-12`）——子代理完成通知等以 `tool_call` + `plain_text` 外壳承载，新客户端应读 `agentMessage` 而不是解析工具名（`docs/timeline-sync.md:280-286`）。计划审批工具在 Claude 下 `name` 为 `plan_approval`（`packages/server/src/server/agent/providers/claude/tool-call-mapper.test.ts:20-50`）。

#### `todo`
```json
{"type":"todo","items":[
  {"text":"定位崩溃原因","completed":true,"status":"completed"},
  {"text":"修复 handleSubmit","completed":false,"status":"in_progress","activeForm":"正在修复 handleSubmit"},
  {"text":"补测试","completed":false,"status":"pending"}]}
```

#### `error`
```json
{"type":"error","message":"Claude Code process exited unexpectedly (code 1)"}
```

#### `notification`（需 `timeline_notifications` 能力）
```json
{"type":"notification","level":"warning","message":"Context window 90% full"}
```

#### `compaction`
```json
{"type":"compaction","status":"completed","trigger":"auto","preTokens":182000}
```

#### `plugin`
```json
{"type":"plugin","id":"row-1","pluginId":"my-plugin","kind":"status-card","version":1,"data":{"…":"…"}}
```
v1 不渲染。

### 4.8 回合（turn）分组

一个可见回合 = 一次 canonical run；有 `turnId` 时按 `turnId` 分组，缺失时 `user_message`、带 `agentMessage` 的 tool_call、`name=="heartbeat"` 的 tool_call 各自开启新回合（`packages/protocol/src/timeline-turn.ts:1-24`）。时间线条目的 `turnId` 在实时流事件（`event.turnId`）和历史条目（`entries[].turnId`）上都有。

### 4.9 其他时间线 RPC（可后做）

- `agent.timeline.list_prompts.request{agentId}` → `{epoch, prompts:[{seq,timestamp,preview}]}`：跳转到某次提问（`messages.ts:1936-1940,4784-4799`，需 `features.agentTimelinePromptIndex`）。
- `agent.timeline.search.request{agentId,query,cursor?}` → `{epoch, locations:[{seq,role,count?}], nextCursor}`（`messages.ts:1928-1934,4764-4782`）。
- `agent.fork_context.request`、`agent.rewind.request{agentId,messageId,mode}`（需 `capabilities.supportsRewind*`）。

---

## 5. 发送

### 5.1 新回合 / 插话（steer）/ 中断

请求（`messages.ts:1403-1417`）：

```json
{"type":"send_agent_message_request","requestId":"r10","agentId":"8b1d…",
 "text":"顺便把 iOS 的也改了",
 "messageId":"msg_8f2c4d1e",
 "activeTurnBehavior":"steer",
 "images":[{"data":"<base64>","mimeType":"image/png"}],
 "attachments":[{"type":"text","mimeType":"text/plain","title":"crash.log","text":"…"}]}
```

| 字段 | 说明 |
| --- | --- |
| `agentId` | 完整 ID / 唯一前缀 / 完整标题 |
| `messageId` | **客户端生成，务必带**：用于幂等（`messageReceipts`）和规范 user 行的 ID（§4.7）。官方 `generateMessageId()`（`packages/app/src/composer/actions.ts:207`） |
| `activeTurnBehavior` | agent 正在跑时：`"interrupt"`（**人类发送的默认值**，打断当前回合再开新回合）或 `"steer"`（把消息插入当前回合）（`session.ts:8285-8312`）。空闲时两者都直接开新回合 |
| `images` | `[{data: base64, mimeType}]`（`messages.ts:1239-1242`） |
| `attachments` | 判别联合（`messages.ts:1155-1214`）：`text`、`uploaded_file{id,fileName,mimeType,size,path}`（需先 `file.upload.request` 走二进制上传，可后做）、`review`、`github_pr`/`github_issue`/`forge_change_request`/`forge_issue`。无法解析的附件被**静默丢弃**（`messages.ts:1216-1230`） |
| `sessionMode` | 一次性模式覆盖（**未确认**取值语义） |
| `sourceAgentId`/`sourceAgentServerId` | agent 间消息用，App 不发 |

响应（`messages.ts:5064-5073`）：`send_agent_message_response{payload:{requestId, agentId, accepted, deliveryStatus?:"queued", error}}`。`accepted:false` → 显示失败、回滚乐观行。Daemon 在回复 accepted 之前会等到回合真正开始，并保证规范 user 行已记录（`docs/timeline-sync.md:245-250`，`session.ts:8285-8295`）。

注意：
- 发送消息会**清空该 agent 的待批权限**（`clearPendingPermissions: true`，`session.ts:8289`）——具体是 deny 还是丢弃 **未确认**；UI 上应在发送后移除权限卡片（随后的 `agent_update`/`agent_permission_resolved` 会确认）。
- `steer` 需要 provider 支持 `steerActiveTurn`；不支持时走「原有派发行为」（`packages/server/src/server/agent/agent-manager.ts:3032-3080`），即效果可能等同 interrupt/排队——**未确认**，UI 上把 steer 标为「尽力而为」。官方 App 在 steer 时把本地 user 行挂到当前 `turnId` 下（`composer/actions.ts:215-217`）。
- 乐观 UI：先本地插入 user 行（带 `clientMessageId`），收到规范 `user_message`（同 ID）时认领，RPC 失败且尚未被认领则回滚（`docs/timeline-sync.md:237-243`）。
- 旧的 `send_agent_message`（无 `_request`，`messages.ts:1247-1255`）**不在入站联合里**，不要用。

### 5.2 取消 / 中断

```json
{"type":"cancel_agent_request","requestId":"r11","agentId":"8b1d…"}
```
→ `cancel_agent_response{payload:{requestId, agentId, agent|null, error?}}`（`messages.ts:1885-1889,4949-4957`）。随后流里出现 `turn_canceled`，`agent_update` 状态回到 `idle`。取消是幂等的；若 provider 拒绝中断，agent 保持运行并返回 error（`docs/agent-lifecycle.md:413-424`）。

### 5.3 模式 / 模型 / 思考档位

| 请求 | 字段 | 响应 |
| --- | --- | --- |
| `set_agent_mode_request` | `agentId, modeId` | `set_agent_mode_response` |
| `set_agent_model_request` | `agentId, modelId\|null` | `set_agent_model_response` |
| `set_agent_thinking_request` | `agentId, thinkingOptionId\|null`（需 `features.agentThinkingUpdate`） | `set_agent_thinking_response` |
| `set_agent_feature_request` | `agentId, featureId, value` | `set_agent_feature_response` |
| `agent.config.apply.request` | `agentId, config:{modelId?, modeId?, thinkingOptionId?, featureValues?}`（需 `features.agentConfigApply`） | `agent.config.apply.response` |

响应 payload 统一为 `{requestId, agentId, accepted, error|null, notice?:{type:"info"|"warning"|"error",message}}`（`messages.ts:1972-2059`）。变化随后以 `agent_update` 体现（`currentModeId`、`model`…）。

候选值：模式在快照 `availableModes`；模型列表用
```json
{"type":"get_providers_snapshot_request","requestId":"r12","cwd":"/Users/me/projects/app"}
```
→ `get_providers_snapshot_response{payload:{entries:[{provider,status,enabled,label?,models?:[{id,label,isDefault?,thinkingOptions?,defaultThinkingOptionId?,contextWindowMaxTokens?}],modes?,defaultModeId?}], generatedAt, …}}`（`messages.ts:370-383,1826-1832,6289-6302`）。或单 provider 的 `list_provider_models_request{provider,cwd?}`（`messages.ts:1807-1812,6239-6248`）。

---

## 6. 创建、重命名、归档

### 6.1 在已有 workspace 里创建会话

modern（`features.creationLifecycle`）用 `agent.create.request`（`messages.ts:1750-1786`）。最小参数：

```json
{"type":"agent.create.request","requestId":"r13",
 "idempotencyKey":"create-7c1e…",
 "workspaceId":"wks_1a2b3c4d5e6f7a8b",
 "config":{"provider":"claude","cwd":"/Users/me/projects/app","model":"claude-opus-4-1","modeId":"default"},
 "initialPrompt":"登录页点提交就崩，帮我看看",
 "clientMessageId":"msg_5d0c…",
 "labels":{}}
```

| 字段 | 说明 |
| --- | --- |
| `config.provider`、`config.cwd` | 必填；`cwd` 用 workspace 的 `workspaceDirectory` |
| `config.model` / `modeId` / `thinkingOptionId` / `title` | 可选；`title` ≤ 200 字符（`packages/protocol/src/agent-title-limits.ts:1`），不给则 Daemon 根据首条 prompt 生成 |
| `workspaceId` | 指定归属；归属不从 cwd 推断（`docs/agent-lifecycle.md:445`） |
| `initialPrompt` + `clientMessageId` + `images?` + `attachments?` | 创建即发送首条消息 |
| `idempotencyKey` | 建议带：断线重连后可用 `creation.subscribe.request{kind:"agent",idempotencyKey}` 找回结果（`messages.ts:1799-1805`，`packages/client/src/creation/index.ts:195-212`） |
| `agentId` | 可选 UUID，客户端预选 ID |
| `subscribe` | `true` 时过程中推送 `agent.create.update`（`CreationSnapshot`：`phase` = `accepted→agent_ready→prompt_started→completed|failed`，`messages.ts:4968-5000`） |
| `autoArchive` | 首个回合结束后自动归档 |
| 旧字段 `git`/`worktreeName` | **已拒绝**，要新 worktree 用 `workspace.create.request`（`daemon-client.ts:3170-3174`） |

响应：`agent.create.response{payload:{requestId, agent|null, error|null, creation?}}`（`messages.ts:5010-5018`）。新 agent 同时以 `agent_update upsert` 出现在列表订阅里。

旧 Daemon（无 `creationLifecycle`）回落 `create_agent_request`，结果以 `status` 消息返回：`{status:"agent_created", agentId, requestId, agent}` 或 `{status:"agent_create_failed", requestId, error}`（`messages.ts:3887-3899`，`daemon-client.ts:3184-3239`）。

新建 workspace（含 worktree）+ 首个 agent：`workspace.create.request{source:{kind:"directory",path}|{kind:"worktree",cwd?,projectId?,action?,refName?,branchName?…}, agent?:{config,initialPrompt,…}, title?, idempotencyKey?}` → `workspace.create.response`（`messages.ts:2686-2734,5020-5032`）。v1 可后做。

### 6.2 重命名

```json
{"type":"update_agent_request","requestId":"r14","agentId":"8b1d…","name":"登录页崩溃修复"}
```
→ `update_agent_response{payload:{requestId,agentId,accepted,error}}`（`messages.ts:979-985,2092-2095`）。同一请求可带 `labels`（合并还是替换 **未确认**；只改名时不要发 `labels`）。

### 6.3 归档 / 取消归档 / 删除

- 归档：`{"type":"archive_agent_request","requestId":"r15","agentId":"8b1d…"}` → `agent_archived{payload:{agentId, archivedAt, requestId}}`（`messages.ts:966-970,5279-5286`，`session.ts:3355-3368`）。软删除：关闭运行时、设置 `archivedAt`、级联归档同 workspace 且未在任何客户端打开的子代理（`docs/agent-lifecycle.md:516-533`）。活跃列表订阅随后收到 `remove`。归档正在运行的 agent 前要确认（官方有确认框）。
- 批量：`close_items_request{agentIds,terminalIds}` → `close_items_response`（`messages.ts:972-977`），v1 不需要。
- 取消归档：官方 App 调 `refresh_agent_request{agentId}`（`packages/app/src/components/archived-agent-callout.tsx:24-34`）→ `status{status:"agent_refreshed", agentId, requestId, timelineSize?}`（`messages.ts:1879-1883,3907-3911`）。
- 删除：`delete_agent_request` → `agent_deleted`。App 不提供，v1 不做。
- 归档整个 workspace：`archive_workspace_request{workspaceId}` → `archive_workspace_response{workspaceId, archivedAt, error}`（`messages.ts:2680-2685,4692-4700`）。

### 6.4 已读

用户看过某 agent 后：`{"type":"clear_agent_attention","agentId":"8b1d…","requestId":"r16"}`（`agentId` 也可以是数组）→ `clear_agent_attention_response{payload:{requestId, agentId, agents:[AgentSnapshot]}}`（`messages.ts:2926-2930,4959-4966`）。workspace 级：`workspace.clear_attention.request{workspaceId}`（官方打开 workspace 时调用，`packages/app/src/hooks/use-workspace-read-state.ts:35`）；`workspace.mark_unread.request` 标为未读。

---

## 7. 权限请求

### 7.1 推送

需事件订阅 `agent_permission_request` / `agent_permission_resolved`（§1.4）。

```json
{"type":"agent_permission_request","payload":{"subscriptionId":"…","agentId":"8b1d…",
  "request":{
    "id":"permission-2c4f9a1e-…","provider":"claude","name":"Bash","kind":"tool",
    "title":"Run npm install","description":"Install dependencies",
    "input":{"command":"npm install","description":"Install dependencies"},
    "detail":{"type":"shell","command":"npm install"},
    "suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm install:*"}],"behavior":"allow","destination":"localSettings"}],
    "metadata":{"toolUseId":"toolu_04"}}}}
```
（`messages.ts:518-531,5252-5259`；Claude 构造见 `packages/server/src/server/agent/providers/claude/agent.ts:5100-5140`；`suggestions` 的内部结构是 provider 原样透传，示例为 Claude SDK 的 PermissionUpdate 形状，**未确认**其他 provider）

`AgentPermissionRequest` 字段：

| 字段 | 说明 |
| --- | --- |
| `id` | 权限请求 ID（回应时作为 `requestId`） |
| `kind` | `tool`（工具调用）/ `plan`（计划审批）/ `question`（向用户提问）/ `mode`（切模式）/ `other` |
| `name` | 工具名 |
| `title`/`description` | 摘要 |
| `input` | 工具原始入参；`question` 时形如 `{questions:[{question, header, multiSelect?, options:[{label, description?, preview?}]}]}`（`packages/app/src/components/question-form-card-core.ts:26-60`）；`plan` 时 `input.plan` 或 `metadata.planText` 为计划 Markdown |
| `detail` | 与 tool_call 相同的 `ToolCallDetail`，可直接复用渲染 |
| `actions` | 可选的按钮定义 `[{id, label, behavior:"allow"|"deny", variant?:"primary"|"secondary"|"danger", intent?:"implement"|"implement_resume"|"dismiss"}]`（`messages.ts:494-500`） |
| `suggestions` | provider 建议的「永久规则」 |
| `metadata` | 其他（`planText`、`toolUseId`…） |

**权威列表**：`AgentSnapshot.pendingPermissions`。冷启动、重连后以快照为准，事件只是增量。解决时推送：

```json
{"type":"agent_permission_resolved","payload":{"subscriptionId":"…","agentId":"8b1d…",
  "requestId":"permission-2c4f9a1e-…","resolution":{"behavior":"allow"}}}
```
（`messages.ts:5261-5269`）。也可能由别的客户端、插件或「发新消息」解决——收到就移除卡片。

### 7.2 回应

```json
{"type":"agent_permission_response","agentId":"8b1d…","requestId":"permission-2c4f9a1e-…",
 "response":{"behavior":"allow"}}
```
（`messages.ts:2207-2212`）。**注意 `requestId` 是权限请求的 `id`，同时也是 RPC 关联键**。成功后 modern 客户端收到一条作为回复的 `agent_permission_resolved`（`session.ts:5147-5155`）；失败时没有专门的错误响应，Daemon 发 `activity_log` 错误并抛出（`session.ts:5156-5171`）——客户端应设超时（官方 15 s，`packages/app/src/agent-stream/view.tsx:1586-1594`，`daemon-client.ts:6039-6073`），也可能收到 `rpc_error`（**未确认**）。

`response` 形状（`messages.ts:502-516`）：

| 场景 | response |
| --- | --- |
| 允许一次 | `{"behavior":"allow"}` |
| 拒绝 | `{"behavior":"deny","message":"Denied by user"}`；`interrupt:true` 同时打断回合 |
| 点了 `actions` 里的按钮 | `{"behavior":<action.behavior>,"selectedActionId":<action.id>}`（deny 时官方加 `message:"Denied by user"`，`view.tsx:1620-1636`） |
| 计划审批 | Claude 给 `actions`：`reject`(deny)、`implement`(allow)、可能还有 `implement_resume`（「Implement with Bypass/Auto」）（`claude/agent.ts:1157-1188`） |
| 回答问题（`kind:"question"`） | `{"behavior":"allow","updatedInput":{...request.input,"answers":{"<header>":"<选中 label，多选用 \", \" 连接，或自定义文本>"}}}`；放弃回答 `{"behavior":"deny","message":"Dismissed by user"}`（`packages/app/src/components/question-form-card.tsx:447-485`，`question-form-card-core.ts:106-136`） |
| 总是允许 | `{"behavior":"allow","updatedPermissions": request.suggestions}`——协议支持（`messages.ts:504-509`，Claude 端透传 `claude/agent.ts:2918`），但**官方 App 不提供这个按钮**（app 内无 `updatedPermissions`/`suggestions` 用法），属于 **未确认（未经官方 UI 验证）** 的路径；Codex 等 provider 是否支持 **未确认** |
| 修改入参后允许 | `{"behavior":"allow","updatedInput":{…}}` |

无 `actions` 时官方默认两个按钮：Deny（`id:"reject"`, deny）和 Accept/Implement（`id:"accept"`, allow）（`view.tsx:1538-1562`）。

### 7.3 状态与通知

有待批权限时 agent 的状态桶为 `needs_input`，同时 Daemon 发 `agent_attention_required{reason:"permission"}`（§8）。

---

## 8. 通知与推送

### 8.1 Daemon 发出什么

Agent 结束回合、出错、请求权限时，AgentManager 触发 attention 回调，`websocket-server.ts` 的 `broadcastAgentAttention` 处理（`packages/server/src/server/websocket-server.ts:2787-2883`）：

1. 构造通知内容（`packages/protocol/src/agent-attention-notification.ts:172-213`）：

| reason | title | body |
| --- | --- | --- |
| `finished` | `Agent finished` | 最后一条助手消息的纯文本预览（去 Markdown，≤220 字符），否则 `Finished working.` |
| `permission` | `Agent needs permission` | 最新待批权限的 title/description/input 预览，否则 `Permission requested.` |
| `error` | `Agent needs attention` | `Encountered an error.` |

   `data = {serverId, workspaceId, agentId, reason}`。

2. 计算通知计划（`packages/server/src/server/agent-attention-policy.ts:42-80`），参与者 = 带 `notifications:true` 订阅了 `agent_attention_required` 的 socket：
   - 「在场」= 最近一次 `client_heartbeat.lastActivityAt` 在 **180 s** 内（`PRESENCE_THRESHOLD_MS`，`:3`）。
   - 任一在场客户端 `appVisible && focusedAgentId == 该 agent` → 不通知也不推送。
   - 否则若有在场客户端 → 只让**最近活跃**的那个在应用内弹通知（`shouldNotify:true`），**不推送**。
   - 无人在场 → 推送（`error` 原因**不推送**，`isPushEligibleAttentionReason`，`:78-80`）。

3. 给每个订阅者发：
```json
{"type":"agent_attention_required","payload":{"subscriptionId":"…","agentId":"8b1d…",
  "reason":"finished","timestamp":"2026-11-03T03:20:41.002Z","shouldNotify":true,
  "notification":{"title":"Agent finished","body":"已修复 handleSubmit，测试全部通过。",
    "data":{"serverId":"srv_…","workspaceId":"wks_1a2b3c4d5e6f7a8b","agentId":"8b1d…","reason":"finished"}}}}
```
（`messages.ts:4913-4934`）。官方 App 仅在 `shouldNotify` 时弹本地通知（`session-context.tsx:509-515`）。终端也有类似的 `terminal_attention_required`（v1 不需要）。

### 8.2 `client_heartbeat`（在场与焦点）

```json
{"type":"client_heartbeat","deviceType":"mobile","focusedAgentId":"8b1d…","focusedTerminalId":null,
 "lastActivityAt":"2026-11-03T03:20:30.000Z","appVisible":true,"appVisibilityChangedAt":"2026-11-03T03:15:00.000Z"}
```
（`messages.ts:2931-2940`）。无响应。官方每 **15 s** 发一次，并在可见性/焦点变化时立即发（`packages/app/src/hooks/client-activity-tracker.ts:1`，`use-client-activity.ts:132`）。进入后台时应立即发一条 `appVisible:false`——否则 180 s 内 Daemon 仍认为你在场，**不会推送**。`deviceType` 只有 `web|mobile`，macOS 原生 App 发 `web` 还是 `mobile` 对策略无影响（策略只看 `appVisible`/焦点/时间）。

### 8.3 官方 App 的推送链路（现状）

- App 用 `expo-notifications` 的 `getExpoPushTokenAsync({projectId})` 拿 `ExponentPushToken[…]`，每次连上 host 就发 `{"type":"register_push_token","token":"…"}`（无响应，`messages.ts:2970-2973`；`packages/app/src/push-notifications/internal/subscriptions.ts:44-84`）。
- **Daemon 自己直接 POST 到 Expo 推送服务** `https://exp.host/--/api/v2/push/send`，消息 `{to, title, body, data, sound:"default"}`，每批 ≤100（`packages/server/src/server/push/push-service.ts:24-60`）。**中间没有 Paseo 自己的推送服务器**；relay/Hub 不参与推送。Expo 再转 APNs/FCM。
- token 存在 `$PASEO_HOME/push-tokens.json`，**48 h 租约**，`register_push_token` 和每次 `client_heartbeat` 都会续租（`push/index.ts:8`，`push/token-store.ts:34-76`，`session.ts:5004-5022,5038-5043`）；Expo 返回 `DeviceNotRegistered`/`InvalidCredentials` 时删除（`push-service.ts:88-108`）。
- 推送发给**所有**有效 token（不区分设备/客户端，`push/index.ts:38-43`）。
- 注销：`push.unregister.request{token}` → `push.unregister.response`（需 `features.pushTokenRevocation`，`messages.ts:2975-2985`）。
- iOS 通知点击：Expo 把 data 放在 `userInfo.body`，内容 `{serverId, workspaceId, agentId, reason}`；打开时应忽略 workspaceId 只按 `(serverId, agentId)` 导航（agent 可能已移动，`docs/notifications.md:9-14,38-52`）。

### 8.4 对我们自建 APNs 的含义

Daemon 只认识 Expo 推送协议，**不会直接发 APNs**。可选方案（均为推断，**未确认**可行性细节）：

1. **Expo 代转**：在自己的 Expo/EAS 项目里上传我们 App 的 APNs key，原生 App 用 APNs device token 调 Expo 的 token 交换接口拿 `ExponentPushToken`，再 `register_push_token`。Daemon 零改动；但依赖 Expo 服务、payload 被 Expo 包装（数据在 `body` 下），无法用 `mutable-content`/category 动作（通知里批权限）等高级字段——Expo 消息格式支持 `categoryId`、`mutableContent` 等，但 **Daemon 只发 `to/title/body/data/sound`**（`push-service.ts:45-51`），拿不到。
2. **Daemon 插件**（推荐方向）：服务端插件可监听 `agent.turn_ended`、`agent.permission_requested`、`agent.permission_resolved` 等生命周期事件（`public-docs/plugins/reference.md:965-1019`），在插件里直接调 APNs（或我们的推送中转），完全控制 payload（category、thread-id、可操作通知、Live Activity 更新）。缺点：失去 Daemon 内置的「在场即不推送」判断，要自己用 heartbeat 等价逻辑或接受重复；插件能否拿到客户端在场状态 **未确认**。
3. **常驻观察者**：在 Mac 上跑一个用 Paseo SDK 的小进程订阅 `agent_attention_required`（`notifications:false` 时不影响官方 App 的在场计算）并转发 APNs。和 2 类似但不依赖插件机制。

无论哪种方案，原生 App 都应：发 `client_heartbeat`（让官方路径的在场判断正确）；前台用 `agent_attention_required.shouldNotify` 决定是否弹应用内通知；通知 payload 只依赖 `{serverId, agentId, reason}`。

---

## 9. 多机器（Connected hosts）

- 官方 App 的「多机器」= **客户端分别连每个 host**（每个 host 一个 DaemonClient/连接，`packages/app/src/runtime/host-runtime.ts:575-620`），各自拉列表；没有「一个 daemon 返回所有机器 agent」的聚合 RPC。历史页也是逐 host 请求后合并（`packages/app/src/hooks/use-agent-history.ts:19,160-180`）。**跨机器列表 = 客户端 fan-out，按 `(serverId, agentId)` 去重合并**。
- Daemon 侧的 Connected hosts（A 保存到 B 的连接）主要服务于 agent 委派和「经 A 路由到 B」：`hosts.list.request{observe?:true}` → `hosts.list.response{directory:{self:{serverId,label}, hosts:[{registrationId, serverId|null, label, status:"connecting"|"online"|"offline"|"error"|"disabled", lastOnlineAt, …}]}}`，变化推 `hosts.changed`（`packages/protocol/src/hosts.ts:17-33,39-43,74-85`；需 `features.connectedHosts`，权限 `daemon.read`）。
- 经 A 访问 B：`hosts.route.open.request{serverId,scopeId}` 开一个虚拟会话，然后在 `hosts.route.frame.request`/`hosts.route.frame` 里承载对 B 的完整 hello/session 流（`hosts.ts:59-115`，`docs/connected-hosts.md:15-27,90-100`）。官方 App 的 `connection.type === "routed"` 就是这么连 B 的（`host-runtime.ts:595-603`）。这属于传输层，见 01；v1 若每台 Mac 都有自己的 relay 配对，可以不做路由。
- 子代理可能在别的 host：`labels["paseo.parent-server-id"]` 指明父 agent 所在 host（`agent-labels.ts:39-52`）；打开跨 host 子代理 = 连到那个 host 打开普通会话（`docs/connected-hosts.md:39-44`）。

---

## 10. 其他要点

- **错误**：多数 `*_response` 自带 `error` 字段；部分失败走 `rpc_error{requestId, requestType?, error, code?}`（例如 `fetch_agents_request` 失败，`session.ts:6295-6309`）。等待响应时两者都要匹配（见 01 §6.2）。
- **权限（RBAC）**：普通配对用户是 owner，拥有全部权限；会话级权限见 `server_info.permissions`。读需 `workspace.read`，发消息/批权限需 `workspace.write`，建/归档 workspace 需 `workspace.manage`（`docs/permissions.md:22-34`，`packages/server/src/server/authorization/operation-permissions.ts`）。
- **ID 解析**：`fetch_agent_request`、`send_agent_message_request`、`wait_for_finish_request` 的 `agentId` 接受前缀/标题；其他请求一律传完整 ID。
- **`wait_for_finish_request{agentId,timeoutMs?}`** → `{status:"idle"|"error"|"permission"|"timeout", final, lastMessage}`（`messages.ts:1419-1425,5075-5084`），适合快捷指令/Widget 的「等它跑完」，不适合 UI。
- **`agent_status` / `agent_list`**（`messages.ts:4221-4235`）：旧消息，现代流程不依赖。
- **Daemon 的消息大小**：单条 WS 消息 ≤100 MiB，relay 加密帧 ≤32 MiB（`packages/protocol/src/websocket-message-limit.ts`）——发图片前压缩，base64 后不要接近 relay 上限。
- **兼容性**：解析要宽松——忽略未知字段、未知 `type`、未知枚举值（provider、icon、mode 等都是开放字符串）；新功能看 `server_info.features.*` 开关（`docs/protocol-compatibility.md`）。

---

## 11. v1 必需 vs 可后做

### 11.1 v1 必需

**握手 / 订阅基础**
- hello 能力集（§1.2）；`status`(`server_info`) 解析
- `session.events.set_subscription.request` / `.response`
- `subscription.release.request` / `.response`
- `rpc_error`
- `client_heartbeat`
- `ping`(session) / `pong`（前台校验，见 01）

**列表**
- `project.list.request` / `project.list.response`；`project.update`（事件）
- `fetch_workspaces_request`(subscribe) / `fetch_workspaces_response`；`workspace_update`
- `fetch_agents_request`(scope active, subscribe) / `fetch_agents_response`；`agent_update`
- `fetch_agent_history_request` / `fetch_agent_history_response`（归档/历史页）
- `fetch_agent_request` / `fetch_agent_response`（从通知打开）

**时间线**
- `agent.timeline.set_subscription.request` / `.response`
- `agent_stream`（全部 event 类型 + 全部 item 类型，`plugin` 除外）
- `agent.timeline.replacement`
- `fetch_agent_timeline_request` / `fetch_agent_timeline_response`（tail/before/after）

**发送与控制**
- `send_agent_message_request` / `send_agent_message_response`（interrupt + steer + images）
- `cancel_agent_request` / `cancel_agent_response`
- `set_agent_mode_request` / `set_agent_mode_response`
- `set_agent_model_request` / `set_agent_model_response`
- `get_providers_snapshot_request` / `get_providers_snapshot_response`（模型/模式候选）

**权限**
- `agent_permission_request`、`agent_permission_resolved`（事件）
- `agent_permission_response`（allow / deny / actions / question answers）

**生命周期**
- `agent.create.request` / `agent.create.response`（+ 回落 `create_agent_request` → `status: agent_created|agent_create_failed`）
- `update_agent_request` / `update_agent_response`（重命名）
- `archive_agent_request` / `agent_archived`
- `refresh_agent_request` / `status: agent_refreshed`（取消归档）
- `clear_agent_attention` / `clear_agent_attention_response`

**通知**
- `agent_attention_required`（事件，`notifications:true`）
- 推送方案二选一落地前：`register_push_token` / `push.unregister.request`（若走 Expo 代转）

### 11.2 可后做

- `set_agent_thinking_request`、`set_agent_feature_request`、`agent.config.apply.request`、`list_provider_models_request`、`list_provider_modes_request`、`list_provider_features_request`、`providers_snapshot_update`
- `workspace.create.request` / `workspace.create.response` / `workspace.create.update`、`creation.subscribe.request`、`agent.create.update`
- `archive_workspace_request`、`workspace.title.set.request`、`workspace.pin.set.request`、`workspace.clear_attention.request`、`workspace.mark_unread.request`、`workspace.label.*`
- 目录增量同步（`sync` 字段 / `directorySync`）
- `agent.timeline.list_prompts.request`、`agent.timeline.search.request`、`agent.fork_context.request`、`agent.rewind.request`、`agent.detach.request`
- `file.upload.request`（uploaded_file 附件，需二进制帧）、`list_commands_request`（斜杠命令）
- 子代理：`agent.provider_subagents.list.request`、`agent.provider_subagents.timeline.get.request`、`agent.provider_subagents.update`
- 多机器路由：`hosts.list.request`、`hosts.changed`、`hosts.route.*`
- `wait_for_finish_request`（快捷指令）
- diff/git：`checkout_status_request`、`checkout.diff.get.request`、`subscribe_checkout_diff_request`、`checkout_status_update`
- 终端、文件浏览、语音/听写、计划任务、插件、daemon 配置

---

## 12. 未确认事项汇总

1. 生命周期类 `agent_stream` 事件（`turn_*`）是否带 `seq`/`epoch`——schema 只承诺时间线事件带。
2. `all_providers` 不发时具体隐藏哪些 provider 的 agent。
3. `compact_provider_snapshots` 模式下 `get_providers_snapshot_response.entries` 是否仍完整（v1 不发该能力规避）。
4. 发消息时 `clearPendingPermissions` 对待批权限是 deny 还是静默丢弃。
5. provider 不支持 steer 时 `activeTurnBehavior:"steer"` 的实际行为（排队 / 打断 / 拒绝）。
6. `update_agent_request.labels` 是合并还是替换。
7. 「总是允许」（`updatedPermissions: suggestions`）在非 Claude provider 上是否生效；官方 UI 未使用。
8. `agent_permission_response` 失败时客户端能否收到 `rpc_error`（源码可见的是 `activity_log` + 抛异常）。
9. `sessionMode` 字段的取值语义。
10. 自建 APNs 的三种方案（Expo 代转 / 插件 / 常驻观察者）的可行性细节，尤其插件能否获知客户端在场状态。
11. `AgentListItemPayloadSchema` 的使用方（似乎不用于 App 列表）。
12. 只列已归档 agent 是否有服务端过滤（目前只能 `includeArchived:true` 后客户端过滤）。
