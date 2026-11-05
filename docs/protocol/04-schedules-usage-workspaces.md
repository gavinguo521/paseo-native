# 04 · 计划任务、用量、工作区与 Agent 扩展操作（v0.14.0）

> 来源：`vendor/paseo`（tag `v0.14.0`）。下文 `path:line` 均相对 `vendor/paseo/`。简写如下：
> - `messages.ts` = `packages/protocol/src/messages.ts`
> - `daemon-client.ts` = `packages/client/src/daemon-client.ts`
> - `session.ts` = `packages/server/src/server/session.ts`
> - `app/…` = `packages/app/src/…`
>
> 前置文档：[01-connection.md](./01-connection.md)（传输、`rpc_error`、`server_info.features`）和 [02-messages.md](./02-messages.md)（订阅模型、agent/workspace 快照、timeline）。本文不重复这两篇里已有的内容。
> 示例 JSON 只写 `message` 内层，发送时要套上 `{"type":"session","message":…}`。
> 标 **未确认** 的地方，表示源码里没看到，或者只能推断。
>
> **对 02 的一处更正**：02 §6.4 说「官方打开 workspace 时调用 `workspace.clear_attention`」，这是错的。`app/hooks/use-workspace-read-state.ts:35` 是侧边栏菜单里 **"Mark as read"** 的实现。打开会话时的自动清除走的是 agent 级的 `clear_agent_attention`（`app/hooks/use-agent-attention-clear.ts:62`），而且只在 agent pane 获得焦点、App 在前台时才触发。

---

## 1. 计划任务（Schedules）与心跳（Heartbeats）

### 1.1 概念：心跳就是一种 schedule

两者共用一套存储、一套 RPC，靠 `target.type` 区分：

| target.type | 产品名 | 每次触发做什么 |
| --- | --- | --- |
| `"new-agent"` | **Schedule** | 新建 workspace，再新建 agent，执行 prompt |
| `"agent"` | **Heartbeat** | 把 prompt 再发给一个已有的 agent |

- App 用 `scheduleProductName` 判断显示哪个名字（`app/utils/schedule-format.ts:31-33`）。概念说明见 `docs/glossary.md:46-47` 和 `public-docs/schedules.md:9-45`。
- WS 协议里**没有专门的 heartbeat RPC**。`create_heartbeat` / `delete_heartbeat` 是 MCP 工具（`packages/server/src/server/agent/tools/paseo-tools.ts:2700-2770`），CLI 对应 `paseo heartbeat …`（`packages/cli/src/commands/heartbeat/index.ts:155-179`）。它们走的是同一个 ScheduleService，用 `createOrReplace` 按 name+target 做幂等（`packages/server/src/server/schedule/service.ts:366-402`）。
- WS 的 `schedule/create` 还接受 `target.type:"self"`，服务端会改写成 `{type:"agent"}`（`packages/server/src/server/session/schedule/schedule-session.ts:71-74`）。原生客户端不用管这个值。

### 1.2 RPC 一览

Schema 在 `packages/protocol/src/schedule/rpc-schemas.ts`，类型在 `packages/protocol/src/schedule/types.ts`。注意 type 字符串用的是**斜杠**。所有响应的形状都是 `{type, payload:{requestId, …, error:null}}`。

| 请求 `type` | 请求字段 | 响应 `type` | payload |
| --- | --- | --- | --- |
| `schedule/create`（:27-37） | `prompt`（min 1）、`name?`、`cadence`、`target`、`maxRuns?`（正整数）、`expiresAt?`（ISO 字符串）、`runOnCreate?` | `schedule/create/response` | `schedule: ScheduleSummary` |
| `schedule/list`（:39） | 无 | `schedule/list/response` | `schedules: ScheduleSummary[]` |
| `schedule/inspect`（:44） | `scheduleId` | `schedule/inspect/response` | `schedule: StoredSchedule`（带 `runs`） |
| `schedule/logs`（:50） | `scheduleId` | `schedule/logs/response` | `runs: ScheduleRun[]`，按 `startedAt` 升序（`service.ts:413-416`） |
| `schedule/pause`（:56） | `scheduleId` | `schedule/pause/response` | `schedule: ScheduleSummary` |
| `schedule/resume`（:62） | `scheduleId` | `schedule/resume/response` | `schedule: ScheduleSummary` |
| `schedule/delete`（:68） | `scheduleId` | `schedule/delete/response` | `scheduleId` |
| `schedule/run-once`（:74） | `scheduleId` | `schedule/run-once/response` | `schedule: StoredSchedule` |
| `schedule/update`（:90-100） | `scheduleId`、`name?: string\|null`、`prompt?`、`cadence?`、`newAgentConfig?`、`maxRuns?: int\|null`、`expiresAt?: string\|null` | `schedule/update/response` | `schedule: StoredSchedule` |

补充说明：

- **update 能改什么**：`newAgentConfig`（:80-88）可以改 `provider?`、`model?`、`modeId?`、`thinkingOptionId?`、`archiveOnFinish?`、`isolation?: "local"|"worktree"`、`cwd?`。传 `null` 或空串表示删掉该字段（`service.ts:90-140`）。update **不能**改 `target`、`title`、`providerOptions`、`featureValues`、`systemPrompt`、`mcpServers`。
- **DaemonClient 方法**（`daemon-client.ts:6429-6538`）：`scheduleCreate`、`scheduleList`、`scheduleInspect({id})`、`scheduleLogs`、`schedulePause`、`scheduleResume`、`scheduleDelete`、`scheduleRunOnce`、`scheduleUpdate`。客户端参数叫 `id`，上线后变成 `scheduleId`。
- **服务端分派**：`session.ts:3186-3203`。
- **错误不放在 `payload.error` 里**。失败时服务端发 `rpc_error{requestId, requestType, error, code:"schedule_request_failed"}`（`schedule-session.ts:36-65`）；成功时 `payload.error` 恒为 null。
- **权限**：全部需要 `automation.manage`（`packages/server/src/server/authorization/operation-permissions.ts:170-178`）。

### 1.3 数据类型（`packages/protocol/src/schedule/types.ts`）

```ts
ScheduleStatus   = "active" | "paused" | "completed"                     // :4
ScheduleCadence  = { type:"cron", expression, timezone? }
                 | { type:"every", everyMs }      // COMPAT 旧格式，只需能解码，不要发送（packages/server/src/server/schedule/cron.ts:89-92）
ScheduleTarget   = { type:"agent", agentId }
                 | { type:"new-agent", config:{ provider, cwd, modeId?, model?, thinkingOptionId?,
                     archiveOnFinish?(默认 true), isolation?("local" 默认), title?|null,
                     providerOptions?, featureValues?, systemPrompt?, mcpServers? } }   // :20-42
ScheduleRun      = { id, scheduledFor, startedAt, endedAt|null, status:"running"|"succeeded"|"failed",
                     agentId|null, workspaceId?|null, output|null, error|null }        // :45-55
StoredSchedule   = { id, name|null, prompt, cadence, target, status, createdAt, updatedAt,
                     nextRunAt|null, lastRunAt|null, pausedAt|null, expiresAt|null, maxRuns|null, runs[] }  // :58-73
ScheduleSummary  = StoredSchedule 去掉 runs                                       // :76-78
```

### 1.4 服务端行为要点（`packages/server/src/server/schedule/service.ts`）

**存储**

- 每个 schedule 一个文件：`$PASEO_HOME/schedules/{id}.json`，id 是 8 位 hex（`packages/server/src/server/schedule/store.ts:12-14,113`）。
- `runs` 内联在文件里，没看到裁剪逻辑（**未确认**是否会无限增长）。

**校验**

- prompt 会先 trim，trim 后不能为空（:82-88）。
- cron 必须是 5 段，只支持数字、`*`、`a-b`、`/n`、`,`，**不支持** `mon`、`jan` 这类名字（`packages/protocol/src/schedule/cron-expression.ts:19-129`）。
- timezone 要能通过 `Intl` 校验（`cron.ts:26-31`）。**没写 timezone 时按 UTC**（`cron.ts:34-43`），所以客户端应该总是带上设备时区。
- `expiresAt` 不校验格式，客户端自己发 ISO 8601。

**创建**（:342-364）

- `runOnCreate` 在 cron 下默认 false，在 every 下默认 true。
- 为 true 时 `nextRunAt = now`，否则取下一个 cron 匹配时间。

**调度循环**（:29, :303-316, :775-825）

- 每 1 s tick 一次。
- 只处理 `active` 且有 `nextRunAt` 的条目。
- 过了 `expiresAt`，或已完成次数 ≥ `maxRuns`，就转为 `completed`（:163-171, :591-603）。
- 开跑前先 claim，并推进 `nextRunAt`。最后一次运行时 `nextRunAt = null`。
- 同一个 schedule 不会并发运行。

**pause / resume**（:418-456）

- pause：`nextRunAt = null`，`pausedAt = now`。
- resume：从当前时刻重新计算 `nextRunAt`。
- 对已经 `completed` 的条目会报错：`"Schedule X is already completed"`。

**update cadence**（:190-206, :471-477）

- active 状态会重算 `nextRunAt`，paused 状态保持 null。
- 新 cron 没带 timezone 时沿用旧的 timezone。
- 对 agent 型 target 传 `newAgentConfig` 会报错（:480-482）。

**run-once**（:558-568, :876-878）

- 已 completed 或正在运行时会拒绝。
- **会等整个运行结束才回响应**。客户端默认 RPC 超时是 60 s（`daemon-client.ts:1091,2170`），长任务会超时，但 daemon 那边照常继续跑。
- 手动触发不推进 cadence。

**执行 heartbeat 型**（:931-970）

- agent 不存在或已归档：判定为 target gone，schedule 立即变成 `completed`（:870-873）。
- agent 正在跑 turn：本次失败。
- 正常情况下，prompt 被包装成 `Schedule "name" fired (id=…, run=…).\n<prompt>`（:75-80），以 system notification 形式、`activeTurnBehavior:"steer"` 注入，然后等 agent 跑完。
- 运行中卡在权限请求上，算失败。

**执行 new-agent 型**（:972-1060）

1. 检查 cwd 是否存在。
2. 按 `isolation` 建 workspace：local 直接用目录，worktree 建 paseo worktree。
3. `createAgent`，带 labels `paseo.schedule-id` / `paseo.schedule-run`，并设 `unattended:true`、`notifyOnFinish:false`。
4. 执行 prompt。`output` 取最终消息，或者对 timeline 做摘要。
5. `archiveOnFinish`（默认 true）为真时，跑完归档 workspace。

**daemon 重启**（:605-712）

- 还在 `running` 的 run 被标成 failed，error 为 `"Daemon restarted before the scheduled run completed"`。
- 错过的时间点不补跑。
- target agent 已经消失的 heartbeat 被标成 completed。
- 归档 agent 时也会调用 `completeForAgent`（`packages/server/src/server/bootstrap.ts:1434`）。

**Timeline 里的样子**：heartbeat 注入的 prompt 不会显示成 user_message，而是投影为 `tool_call{name:"heartbeat", detail:{type:"plain_text", text, icon:"sparkles"}}`（`packages/server/src/server/agent/agent-messages/envelope.ts:174-190`）。

### 1.5 实时更新

**没有推送**。`messages.ts` 里没有任何 schedule 推送消息，也没有订阅机制。

官方 App 的刷新方式：

- 用 react-query，`staleTime` 5 s，在连接状态变化或 mutation 之后 refetch（`app/hooks/use-schedules.ts:50-55`、`app/hooks/use-schedule-mutations.ts:116-118`）。
- 页面不在焦点时直接渲染空 View（`app/screens/schedules-screen.tsx:51-57`）。

每次运行新建的 agent 和 workspace，会通过已有的 `agent_update` / `workspace_update` 订阅实时出现。

### 1.6 官方 Schedules 页面

**入口**：侧边栏 header 里的 "Schedules"，路由 `app/schedules.tsx`。

**列表**

- 对每台在线 host 各调一次 `schedule/list`，然后合并（`app/schedules/aggregated-schedules.ts:69-124`）。
- 某台 host 失败时显示 error banner；全部失败时显示整页错误和 Retry。
- 筛选：Host（多于一台 host 时才出现）、Active / Ended。
- 排序：`createdAt` 降序（`schedules-screen.tsx:46-49,137`）。

**派生状态**（`app/schedules/schedule-derivation.ts:81-100`），优先级从高到低：

1. `expired`：`expiresAt` 已过。
2. `targetGone`：agent target 在本地 agent 目录里找不到；要等目录加载完才判断。
3. `finished`：`completed`。
4. `paused`。
5. `active`。

Active 页签显示 active 和 paused，其余归到 Ended。Badge 颜色：Active 用 success，Target gone 用 error，其他用 muted（`app/components/schedules/schedule-row.tsx:73-94`）。

**行内容**

- 标题优先级：`name` → `config.title` → prompt 首行 → "Untitled schedule/heartbeat"（`schedule-format.ts:35-51`）。
- 目标行：agent 型显示 agent 标题，new-agent 型显示项目名或缩短后的 cwd。
- Meta 行：`[host ·] cadence · Created 2d ago · Last run 3h ago|Never run · Next run in 3h`（`schedule-row.tsx:100-126`）。"Next run" 只在 active 时显示。
- `describeCron` 把常见 cron 翻成人话，比如 "Weekdays at 09:00 Asia/Shanghai"，翻不了的显示原始表达式（`schedule-format.ts:86-153`）。

**行菜单**（`schedule-row.tsx:265-390`）

- 菜单项：Edit / Pause 或 Resume / Run now / 分隔线 / Delete。
- **Heartbeat 只有 Edit 和 Delete**（:275-277）。
- Run now、Pause、Resume 只对 new-agent 型、且状态为 active 或 paused 的条目可用（:195）。
- Delete 要二次确认，文案是 "Delete "<title>"? This cannot be undone."（`app/components/schedules/schedules-table.tsx:114-124`）。
- pause、resume、delete 都先乐观更新，失败再回滚（`use-schedule-mutations.ts:86-206`）。

**表单**（`app/components/schedules/schedule-form-sheet.tsx`，模型在 `app/schedules/schedule-form-model.ts`）

- 字段：Target、Host、Project、Model、Thinking、Mode、Isolation、Archive on finish、Name、Prompt、Cadence、Max runs（留空表示 Unlimited）。
- Isolation 只在 git 项目、且 host 支持 workspace multiplicity 时显示。
- Cadence 预设：every minute、every hour、Daily 9:00、Weekdays 9:00、Mondays 9:00，另加自定义 cron（`app/schedules/schedule-cadence-options.ts:14-20`）。**App 只提交 cron**，并带设备时区。
- **App 只能新建 new-agent 型**，从不发送 `expiresAt` 和 `runOnCreate`，并把 `config.title` 设为 name（sheet:359-379）。
- 编辑 heartbeat 时**只发 `cadence`**（sheet:317-326）。
- 编辑 schedule 时发 `name`（空串转成 null）、`prompt`、`cadence`、完整的 `newAgentConfig`、`maxRuns`（sheet:337-356）。

**运行历史**：官方 App **没有**运行历史 UI，也不调用 `schedule/inspect` 或 `schedule/logs`。只有 CLI（`paseo schedule logs`）和 MCP（`schedule_logs`）能看。原生客户端可以把它做成增强功能。

### 1.7 JSON 示例

```json
{"type":"schedule/create","requestId":"r-41","name":"Daily triage",
 "prompt":"Triage new GitHub issues and summarize.",
 "cadence":{"type":"cron","expression":"0 9 * * 1-5","timezone":"Asia/Shanghai"},
 "target":{"type":"new-agent","config":{"provider":"claude","cwd":"/Users/me/projects/app",
   "model":"opus","modeId":"bypassPermissions","thinkingOptionId":"high",
   "archiveOnFinish":true,"isolation":"worktree","title":"Daily triage"}},
 "maxRuns":30}
```

```json
{"type":"schedule/list/response","payload":{"requestId":"r-42","error":null,"schedules":[
 {"id":"3fa9c01b","name":"Daily triage","prompt":"Triage new GitHub issues and summarize.",
  "cadence":{"type":"cron","expression":"0 9 * * 1-5","timezone":"Asia/Shanghai"},
  "target":{"type":"new-agent","config":{"provider":"claude","cwd":"/Users/me/projects/app","isolation":"worktree","archiveOnFinish":true}},
  "status":"active","createdAt":"2026-11-01T02:10:00.000Z","updatedAt":"2026-11-03T01:00:41.512Z",
  "nextRunAt":"2026-11-04T01:00:00.000Z","lastRunAt":"2026-11-03T01:00:41.512Z",
  "pausedAt":null,"expiresAt":null,"maxRuns":30},
 {"id":"b71e22d4","name":"ci-babysit","prompt":"Check CI for PR #812; fix if red.",
  "cadence":{"type":"cron","expression":"*/10 * * * *","timezone":"UTC"},
  "target":{"type":"agent","agentId":"8b1d2c3e-5f6a-4b7c-8d9e-0f1a2b3c4d5e"},
  "status":"active","createdAt":"2026-11-03T07:00:00.000Z","updatedAt":"2026-11-03T08:10:02.000Z",
  "nextRunAt":"2026-11-03T08:20:00.000Z","lastRunAt":"2026-11-03T08:10:00.000Z",
  "pausedAt":null,"expiresAt":"2026-11-04T08:00:00.000Z","maxRuns":null}]}}
```

```json
{"type":"schedule/logs/response","payload":{"requestId":"r-43","error":null,"runs":[
 {"id":"5c0e9a12","scheduledFor":"2026-11-03T01:00:00.000Z","startedAt":"2026-11-03T01:00:00.204Z",
  "endedAt":"2026-11-03T01:00:41.512Z","status":"succeeded",
  "agentId":"a1b2c3d4-0000-4000-8000-000000000001","workspaceId":"wks_1a2b3c4d5e6f7a8b",
  "output":"3 new issues triaged …","error":null}]}}

{"type":"rpc_error","payload":{"requestId":"r-44","requestType":"schedule/pause",
 "error":"Schedule 3fa9c01b is already completed","code":"schedule_request_failed"}}
```

### 1.8 未确认

- `runs` 有没有上限。
- 原生客户端调 `run-once` 时该怎么处理超时。建议用长超时，或者发出后不阻塞 UI。
- 普通配对设备是否默认拥有 `automation.manage` 权限。
- heartbeat 的 agent 被归档后，App 依据本地 agent 目录显示 "Target gone"，而服务端已经把它标成 completed，两边状态可能短暂不一致。

### 1.9 原生客户端实现清单

1. Codable 模型：`ScheduleCadence`（`every` 只需能解码）、`ScheduleTarget`（`config` 宽松解码）、`ScheduleRun`、`StoredSchedule` / `ScheduleSummary`、`ScheduleStatus`。
2. 9 个 RPC。把 `rpc_error{code:"schedule_request_failed"}` 映射成用户能看懂的错误。
3. 列表页：多 host 各自 `schedule/list` 后合并。进入页面、下拉刷新、每次 mutation 后都刷新；页面可见时可选 15–30 s 轮询，因为没有推送。
4. 派生状态和分桶（expired > targetGone > finished > paused > active），标题和 meta 行按 1.6 的规则生成，按 `createdAt` 降序。
5. 行操作：Edit、Pause/Resume、Run now、Delete（要确认），乐观更新加失败回滚。Heartbeat 只给 Edit（只改 cadence）和 Delete。
6. new-agent 型表单：host、project（cwd）、provider、model、mode、thinking、isolation 和 archiveOnFinish（受 git 与 multiplicity 条件限制）、name、prompt、cron 预设加自定义（本地按 5 段规则校验）、设备时区、maxRuns。编辑时用 `schedule/update` 只发差异字段。
7. Run now：用长超时或 fire-and-forget，完成后刷新列表。新建的 agent/workspace 可以靠 label `paseo.schedule-id` 关联回对应 schedule。
8. （增强）详情页，用 `schedule/inspect` 展示运行历史：状态、耗时、output/error，以及跳转到对应 agentId/workspaceId 的链接。
9. Timeline 里把 `tool_call name=="heartbeat"` 渲染成系统通知卡片。

---

## 2. 用量（Usage）

### 2.1 两代 RPC 与能力位

| 能力位（`server_info.features`） | 含义 |
| --- | --- |
| `usageSources`（`messages.ts:3661`） | 新的流式 `usage.list_reports.*` 可用 |
| `providerUsageList`（`messages.ts:3753`，COMPAT） | 只有旧的 `provider.usage.list.*` |

- 官方客户端的判断：`supportsUsageReports = usageSources || providerUsageList`（`daemon-client.ts:1266-1268`）。v0.14 的 daemon 两个都会下发（`packages/server/src/server/websocket-server.ts:1952,2048`）。
- 两种 RPC 都需要 `daemon.read` 权限（`operation-permissions.ts:159-160`）。
- **建议原生客户端只实现 `usageSources`**，旧 host 直接提示升级。

### 2.2 新 RPC：`usage.list_reports.*`（流式）

**请求**（`messages.ts:1852-1858`）：`{type:"usage.list_reports.request", requestId, agentId?, reportIds?, forceRefresh?}`。

- `agentId` 和 `reportIds` 不能同时传，否则 daemon 抛错（`packages/server/src/server/plugins/usage-sources/index.ts:90`）。
- 带 `agentId` 时，查询的是该 agent 启动时所用的账号（session scope）。

**响应流**

- 先收到 0 到多条 `usage.list_reports.update{payload:{requestId, report: UsageReportEntry}}`（`messages.ts:6448-6451`），每取完一个 report 推一条。
- 最后收到终止消息 `usage.list_reports.response{payload:{requestId, error: string|null}}`（`messages.ts:6452-6455`）。错误写在这里的 `error` 字段，不走 `rpc_error`（`packages/server/src/server/session/usage/usage-session.ts:18-46`）。
- 客户端按 requestId 过滤原始消息、收集 update，收到 response 或 rpc_error 时结束（`daemon-client.ts:5656-5759`）。结束之后才到的 update 会被丢弃（:5726）。

**UsageReportEntry**（`messages.ts:6423-6446`）

```ts
{
  id,                    // "<sourceId>:<accountKey>"（usage-sources/index.ts:213）
  sourceId, sourceLabel,
  icon?,                 // 内联 SVG 文本，不是路径（packages/server/src/server/plugins/plugin-process.ts:304-305）
  account: { label? },   // 通常是邮箱
  fetchedAt,             // 本次尝试的开始时间
  successfulAt?,         // 最后一次成功的时间
  report: UsageReport,
  lastSuccessful?: { fetchedAt, report },     // 本次失败时保留的上次成功快照
  loginErrors?: [{ harness, report }]         // 每个失败的登录各一条
}
UsageReport (messages.ts:6411-6422) =
  | { status:"available", planLabel?, windows[], balances?, details? }
  | { status:"unavailable", problem:
        { kind:"expired", expiresAt, refreshedBy? }
      | { kind:"rejected", status:int, refreshedBy? }
      | { kind:"no_quota", detail } }
  | { status:"error", error }
Window  (6339-6355) = { id, label, shortLabel?, summary?, usedPct?|null, remainingPct?|null,
                        resetsAt?, runsOutAt?, shortfallPct?, tone?: "default"|"ok"|"warning"|"danger" }
          // shortLabel 是 "5h"、"wk" 这类短标签；为 "" 时只显示百分比；缺省时回退到 label
Balance (6357-6366) = { id, label, used?, remaining?, limit?, unit:"usd"|"credits"|"requests"|"tokens", resetsAt?, tone? }
Detail  (6368-6373) = { id, label, value: string, tone? }
```

### 2.3 旧 RPC（只需了解）

- `provider.usage.list.request{requestId}`（`messages.ts:1847`）→ `provider.usage.list.response{payload:{requestId, fetchedAt, providers: ProviderUsage[]}}`（6375-6396）。
- `ProviderUsage` 字段：`providerId, displayName, status, planLabel|null, sourceLabel?, fetchedAt?, nextRefreshAt?, windows, balances?, details?, error?`。
- 失败时发 `rpc_error code:"provider_usage_list_failed"`（`usage-session.ts:62-73`）。
- 服务端其实是把新格式的 report 拍平后填进去的（`usage-sources/index.ts:241-263`）。

### 2.4 Daemon 怎么采集用量

**来源**：不是 agent provider 本身提供，而是**注册了 usage source 的插件**：claude、codex、copilot、cursor、grok、kimi、minimax、opencode-go、zai（`plugins/*-usage-source`，例如 `plugins/claude-usage-source/index.server.ts:6-13`）。

- 插件契约是 `discover(scope)` 加 `fetch(input)`，scope 为 `global` 或 `session{provider, model, env}`（`packages/plugin/src/server/usage.ts:67-86`）。

**缓存与超时**（`usage-sources/index.ts:54-243, 335-352`）

- 结果缓存 5 分钟。
- 单次 fetch 限时 20 s，超时报 `"Usage fetch timed out"`。
- 同一账号的多个登录并行尝试，取第一个可用的。
- `forceRefresh` 跳过缓存。

**tone 阈值**：used > 90 为 danger，≥ 70 为 warning，其余为 ok（`packages/plugin/src/server/usage.ts:169-175`）。App 端兜底用同样阈值，只是低于阈值时用 `default`（`app/usage/tone.ts`）。

**Claude 窗口示例**（`plugins/claude-usage-source/server/usage.ts:123-124,254-290,596-611`）

- `five_hour`："Session"/"5h"，带 summary。
- `weekly`："Weekly"/"wk"，带 summary。
- 每个模型一个 `Weekly · <model>`。
- details 里有一条 "Extra usage"，值为 Enabled/Disabled。

### 2.5 Agent 上的 `lastUsage`

**结构**：`AgentUsage`（`messages.ts:426-433`）= `{inputTokens?, cachedInputTokens?, outputTokens?, totalCostUsd?, contextWindowMaxTokens?, contextWindowUsedTokens?}`。

- 它在 agent 快照的 `lastUsage` 字段里（`messages.ts:873`），由 `turn_completed.usage` 更新（`messages.ts:776`）。字段定义 02 已有。

**App 渲染**

- **Composer 上下文环**（`app/composer/index.tsx:284-286,2088-2095`、`app/components/context-window-meter.tsx:37-75`）：
  - 环形进度为 `used/max*100`。
  - 颜色：> 90 用 destructive，≥ 70 用 amber，否则 muted。
  - 费用 < $0.01 显示 `$x.xxxx`，否则显示 `$x.xx`；≤ 0 时不显示。
- **Popover**（`app/components/context-window-details.tsx:38-55`）：
  - 显示 "N% used"、"used/max tokens"、session cost。
  - 内嵌 `AgentUsage` 组件，它调用 `usage.list_reports.request{agentId}`，展示该账号的额度卡片。
  - 只在 popover 打开时加载，gcTime 0，不重试（`app/usage/agent-usage.tsx`、`app/usage/queries.ts:189-213`）。
- **Agent facts 行**：`"12.3k / 200k tokens (6%)"`（`app/panels/agent-facts-line.ts:73-87`）。

### 2.6 官方 UI

**没有独立的 Usage 页面**，用量出现在三个地方：

1. **Settings → Host → Usage 区块**（`HostUsageSection`，`app/screens/settings/host-page.tsx:355`、`app/utils/host-routes.ts:515-528`）。
2. **侧边栏 footer 的 Usage 行**，点开 `UsageModal`：宽屏是 dialog，窄屏是 bottom sheet，最大宽度 640（`app/usage/usage-modal.tsx`、`app/usage/sidebar-item.tsx:53-88`）。
3. **Agent 的上下文 popover**（见 2.5）。

**侧边栏 Usage 行**

- **默认隐藏**，需要用户主动开启（`app/sidebar-nav/model.ts:12,72-73`）。开关是 "Show in sidebar"，在 usage 选项菜单和 Settings → Sidebar 里都有（`app/usage/in-sidebar.ts`、`app/usage/options.tsx`）。
- host 选择顺序：用户手动选的 → 当前 workspace 所在 host → 第一台支持 usage 的已连接 host（`app/usage/model.ts` 的 `resolveUsageHostId`）。
- 行内布局：每个账号一个 source 图标，然后每个 pinned window 显示「进度条 + `31% 5h`」。宽度不够时逐级降级：先去掉进度条，再去掉标签，最后只剩百分比（`app/usage/pinned.ts:33-56,70-99`）。
- 默认 pin：`summary:true` 的窗口；没有的话取第一个有百分比的窗口（`app/usage/preferences.ts:54-70`）。

**卡片**（`app/usage/card.tsx`）

- 头部：`sourceLabel`、`planLabel` badge、Refresh 按钮（tooltip 显示 "Updated X ago"）。
- 主体：每个 window 一条进度条，每个 balance 一条，再加 details 行。
- 底部：`account.label`。
- 当前尝试失败时，用 `lastSuccessful` 的数据按 "retained" 样式显示，并列出错误 `"<harness>: <problem 文案>"`。

**窗口进度条**（`app/usage/window-bar.tsx:50-59`）

- 同时有 `runsOutAt` 和 `shortfallPct` 时显示 "runs out in X"。
- 否则显示 "resets in X"，或者 "resetting now"、"reset time passed"。
- 相对时间每分钟刷新一次（`app/usage/use-relative-time-tick.ts`）。

**数字格式**（`app/usage/format.ts`）

- 百分比：0 位小数，限制在 0–100 之间。
- usd：按货币格式。
- tokens：紧凑记数（如 12.3k）。
- 内置窗口 id（session、weekly、monthly、`five_hour`→Session 等）做本地化。

**刷新策略：不轮询**

- staleTime 60 s；mount、focus、reconnect 时都不自动 refetch（`app/usage/queries.ts:37`、`app/data/query.ts:86-88`）。
- "Refresh all" 发 `forceRefresh:true`。
- 单卡刷新发 `reportIds:[id], forceRefresh:true`；agent 视图里改用 `agentId`。
- 流式到达的 report 原地 upsert，已经显示的顺序保持不变。

**本地偏好**（`AppSettings.usage`，`app/usage/preferences.ts:15-27`）：

- `displayAs: "used"|"remaining"`
- `pins: [{sourceId, windowId}] | null`（null 表示用默认）
- `serverId`

### 2.7 JSON 示例

```json
{"type":"usage.list_reports.request","requestId":"u1","forceRefresh":false}
```

```json
{"type":"usage.list_reports.update","payload":{"requestId":"u1","report":{
 "id":"claude:3f9a51c2","sourceId":"claude","sourceLabel":"Claude","icon":"<svg viewBox=\"0 0 24 24\">…</svg>",
 "account":{"label":"me@example.com"},
 "fetchedAt":"2026-11-03T08:00:00.000Z","successfulAt":"2026-11-03T08:00:01.200Z",
 "report":{"status":"available","planLabel":"Max",
  "windows":[
   {"id":"five_hour","label":"Session","shortLabel":"5h","summary":true,"usedPct":31,"remainingPct":69,"resetsAt":"2026-11-03T10:00:00Z","tone":"ok"},
   {"id":"weekly","label":"Weekly","shortLabel":"wk","summary":true,"usedPct":74,"remainingPct":26,"resetsAt":"2026-11-07T00:00:00Z","tone":"warning"}],
  "balances":[],
  "details":[{"id":"extra_usage","label":"Extra usage","value":"Disabled"}]}}}}
```

```json
{"type":"usage.list_reports.update","payload":{"requestId":"u1","report":{
 "id":"codex:ab12","sourceId":"codex","sourceLabel":"Codex","account":{},
 "fetchedAt":"2026-11-03T08:00:00Z",
 "report":{"status":"unavailable","problem":{"kind":"expired","expiresAt":"2026-11-01T00:00:00Z","refreshedBy":"codex login"}},
 "lastSuccessful":{"fetchedAt":"2026-10-31T22:00:00Z","report":{"status":"available","windows":[]}},
 "loginErrors":[{"harness":"Codex","report":{"status":"unavailable","problem":{"kind":"expired","expiresAt":"2026-11-01T00:00:00Z","refreshedBy":"codex login"}}}]}}}

{"type":"usage.list_reports.response","payload":{"requestId":"u1","error":null}}
```

### 2.8 未确认

- 各个 usage-source 插件是否默认都启用，以及 `pluginsEnabled=false` 会不会关掉用量来源。

### 2.9 原生客户端实现清单

1. 读 `server_info.features.usageSources`，没有就提示「请升级 host」。
2. 实现 `usage.list_reports.request`：按 requestId 收集 update，直到收到 response；`error` 非空视为失败。
3. 模型：`UsageReportEntry`、report union、Window/Balance/Detail/Problem。`icon` 按内联 SVG 渲染，解析失败时退回通用图标。
4. Host 设置页的 Usage 卡片列表：支持 Refresh all 和单卡刷新；处理 retained 状态和 `loginErrors`；相对时间每分钟刷新。
5. 本地偏好：`displayAs`、`pins`、选中的 host。
6. （可选，默认关闭）侧边栏 Usage 行，按降级规则布局，点开弹出完整列表。
7. Composer 上下文环（数据来自 `lastUsage`），popover 打开时才发 `list_reports{agentId}`。
8. 客户端缓存 60 s，不做轮询；daemon 端自己还有 5 分钟缓存。

---

## 3. 工作区（Workspaces）

`WorkspaceDescriptor` 的字段、`fetch_workspaces`、`workspace_update`、`archive_workspace_request` 的基本形态，02 已经讲过。本节只补「创建、选源、管理」相关的内容。

### 3.1 相关能力位

| feature | 作用 |
| --- | --- |
| `workspaceMultiplicity`（`messages.ts:3739`） | 没有它时只能建 worktree |
| `creationLifecycle`（3650） | `workspace.create.update` 进度推送和 `creation.subscribe` 恢复 |
| `workspaceRequestReceipts`、`backgroundWorkspaces`（3657） | 回执、后台创建 |
| `projectAdd`（3743） | 支持 `project.add.request` |
| `forgeSearch`（3691） | 支持 `forge.search.request`；没有时退回 `github_search_request` |
| `workspacePinning` | 置顶 |
| `workspaceMarkUnread` | 标为未读 |
| `workspaceLabels`（3667） | 标签 |

### 3.2 `workspace.create.request`

**Schema**（`messages.ts:2687-2733`）

```ts
{
  type:"workspace.create.request", requestId,
  idempotencyKey?,            // 1–512 字符；官方传 draftId
  workspaceId?,               // ^wks_[a-f0-9]{16}$；host 不支持自选 ID 时，客户端侧直接拒绝（packages/client/src/creation/index.ts:64-65）
  subscribe?: boolean,        // 官方总是 true
  title?, background?, callerAgentId?,
  firstAgentContext?: { prompt?, attachments },
  agent?: WorkspaceInitialAgent,   // = agent.create.request 去掉 type/requestId/idempotencyKey/subscribe/workspaceId/worktree/worktreeName/git（1788-1797）
  source:
    | { kind:"directory", path, projectId? }
    | { kind:"worktree", cwd?, projectId?, action?: "branch-off"|"checkout",
        refName?, baseBranch?, branchName?, worktreeSlug?,
        checkoutSource?: { kind:"change_request", forge?, number, projectPath? },   // 1232-1237
        githubPrNumber? /* COMPAT */ }
}
```

**`directory` 源（本地目录）**

- 路径会做 `~` 展开。目录不存在时返回 `errorCode:"directory_not_found"`（`session.ts:6800-6812`）。
- **不去重**：每次调用都会生成一条新的 workspace 记录（注释在 `messages.ts:2684-2686`）。

**`worktree` 源**

- `cwd` 和 `projectId` 至少要有一个，否则返回 `source_required`（`session.ts:6864-6869`）。
- `branch-off`：`refName` 是基线 ref。
- `checkout`：`refName` 是要检出的分支。
- `branchName` 是新分支名，不填时根据首条 prompt 自动生成。
- `baseBranch` 用来覆盖默认分支的探测结果（`session.ts:6873-6893`）。

**服务端流程**

1. 入口 `session.ts:4187-4300`，进入 `createRequestedWorkspace`（6779-6798），先过插件 `before("workspace.create")` hook。
2. 按源类型走 local 或 worktree 分支。
3. 标题：有 `title` 就用；否则有首条 prompt 时自动命名（6814-6849）。
4. `agent.config.cwd` 必须位于源目录之内，服务端会把它 re-root 到新的 workspace 目录（4235-4256）。

**响应**：`workspace.create.response{payload:{requestId, workspace|null, agent?, creation?: CreationSnapshot, setupTerminalId:null, setupSkippedReason?, error, errorCode?}}`（`messages.ts:5020-5032`）。

- 要等整个创建流程（包括 agent）都完成才返回，官方把超时设为 0，即不超时（`daemon-client.ts:3122-3128`）。
- 成功后另外推送 `workspace_update upsert`；带了首个 agent 时 status 为 `"running"`。

**进度推送**：`workspace.create.update{payload: CreationSnapshot & {subscriptionId?}}`（4994-4997）。

- `CreationSnapshot`（4968-4987）字段：`kind, idempotencyKey, revision, phase, workspaceId, agentId, workspace?, agent?, error, errorCode?, failedStage?, outcomeUnknown?`。
- `phase` 依次为 `accepted → workspace_ready → agent_ready → prompt_started → completed`，失败时为 `failed`。

**断线恢复**

- 发 `creation.subscribe.request{kind:"workspace", idempotencyKey}`（1798-1804），收到 `creation.subscribe.response{snapshot|null}`。
- `null` 表示 daemon 根本没收到原请求，用**同一个 key** 重发即可（`packages/client/src/creation/index.ts:200-216`）。
- 同一个 key 配不同 payload，客户端本地直接报 `workspace_request_key_conflict`（:118-120）。

**官方调用方式**：`createMultiplicityWorkspace`（`app/screens/new-workspace-screen.tsx:283-334`）。

- `idempotencyKey` 用 draftId，并带上 `worktreeSlug`。
- worktree 模式下展开 `cwd: sourceDirectory, projectId, …checkoutRequest`。
- 用户选的 local/worktree 记在表单偏好里（195-225）。
- **workspace 在用户发出第一条消息时才创建**，并且一起带上 `agent`（1235-1268）。

### 3.3 "Start from" 选择器：搜分支和 PR 用哪些 RPC

只在选择器打开、且隔离模式为 worktree 时才发起；输入有防抖，**分支和 PR 两个请求并行发**（`new-workspace-screen.tsx:195-225,1047-1088`）。

**搜分支：`branch_suggestions_request`**

- 请求：`{cwd, query?, limit?(1–200)}`（`messages.ts:2471-2477`），官方传 `limit:20`。
- 响应：`branch_suggestions_response{branches:[string], branchDetails?:[{name, committerDate, hasLocal?, hasRemote?, localAhead?, localBehind?}], error}`（5981-6001）。
- 服务端实现：`packages/server/src/server/session/checkout/checkout-session.ts:381-410`。

分支映射成选择器条目的规则（`app/screens/new-workspace-picker-item.ts:66-120`）：

- 有远程分支时生成 `refName:"refs/remotes/origin/<name>"`，排在前面，作为默认基线。
- 本地分支生成 `refs/heads/<name>`。本地和远程指向不同提交时两条都显示，本地那条标 "(local)" 并显示 ahead/behind。
- 来源不明的分支直接用裸名。
- 默认选中项：`checkout_status.upstreamRef`，取不到时用 `refs/heads/<currentBranch>`；按钮文案最终兜底为 `"main"`（163-178；`new-workspace-screen.tsx:1105`）。

**搜 PR：`forge.search.request`**

- 请求：`{cwd, query, limit?(1–50), kinds?:["change_request"]}`（2524-2531）。
- 响应：`forge.search.response{items, authState?, error}`（6003-6018）。
  - 条目字段：`{kind:"issue"|"change_request", forge?, number, title, url, state, body, labels, projectPath?, baseRefName?, headRefName?, updatedAt?}`（2479-2498）。
  - `authState` 取值：`authenticated|unauthenticated|cli_missing|no_remote|error`（5480-5485）。只有 `authenticated` 时才显示 PR 列表。

**选中后填入 create 的字段**（`new-workspace-picker-item.ts:181-211`）

- 选分支：`{action:"branch-off", refName}`。普通分支在官方 UI 里从不用 `checkout`，协议本身是支持的。
- 选 PR：`{action:"checkout", refName: headRefName, checkoutSource:{kind:"change_request", forge, number, projectPath?}, githubPrNumber /* 仅 github */}`。

**辅助 RPC**：`validate_branch_request{cwd, branchName}` → `{exists, resolvedRef, isRemote, error}`（2426-2431, 5970-5979）。

### 3.4 添加项目，以及目录选择

**`project.add.request{cwd}`**（`messages.ts:2640-2644`）

- 响应：`project.add.response{project: WorkspaceProjectDescriptor|null, error, errorCode?:"directory_not_found"}`（4556-4564）。
- 只注册项目，不创建 workspace。幂等，服务端走 `findOrCreateProjectForDirectory`（`session.ts:6994-7054`）。
- App 侧（`app/hooks/open-project.ts:80-109`）：添加成功后跳到 New Workspace，`sourceDirectory = project.projectRootPath`（`app/components/add-project-flow.tsx:476-490`）。

**浏览 host 上的目录：有，用 `directory_suggestions_request`**。它是搜索接口，不是专门的 ls。

- 请求（2532-2541）：`{query, cwd?, includeFiles?, includeDirectories?, matchMode?:"fuzzy"|"suffix", limit?(1–100)}`。
- 响应（6031-6047）：`{directories:[string], entries:[{path, kind:"file"|"directory"}], error}`。

**不带 `cwd` 时**，在 `$HOME` 下搜索，返回绝对路径（`session.ts:5174-5225`、`packages/server/src/server/utils/directory-suggestions.ts:661-727`）：

- 空 query 什么都不返回。
- `~`、`~/`，或以 `/` 结尾的路径（如 `~/projects/`）列出该目录的子项。
- `~/projects/pa` 在 `~/projects` 下模糊搜索。
- `$HOME` 之外的绝对路径返回空。macOS 上排除 `~/Library`。
- 所以原生选择器可以靠不断发送 `~/dir/` 一级一级往下浏览。

**带 `cwd` 时**，在 workspace 内搜索：返回相对路径，遵守 gitignore，空 query 列出根目录子项。@file 提及用的就是这种模式（见 4.7）。

**官方 App 的用法**：在 add-project 里以 `includeDirectories:true, includeFiles:false, limit:30` 调用（`add-project-flow.tsx:430-450`）。旁边的 "Browse" 按钮打开的是**本机**原生文件夹选择器，只在 `isLocalDaemon` 时显示（526-540）。**官方没有远程目录浏览对话框。**

**其他相关 RPC**

- `project.create_directory.request{parentPath, name}`（2646-2651, 4575-4587）。
- `workspace.github.search_repositories.request{query, limit?}`（2663-2668）。
- `project.github.clone.request{repo, cloneProtocol?, targetDirectory}`（2672-2677）。
- 旧接口 `open_project_request{cwd}`（2633-2638）会同时创建 workspace。

### 3.5 重命名、置顶、归档、已读/未读

**重命名：`workspace.title.set.request{workspaceId, title: string|null}`**（`messages.ts:1015-1021`）

- 响应 `{requestId, workspaceId, accepted, title, error}`（2134-2145），之后推送 `workspace_update`（`session.ts:3828-3875`）。
- `null` 或空串表示清除标题，显示名回退到分支名或目录名。
- App 发送前先 trim，trim 后为空就发 null；输入框用 `descriptor.title` 预填（`app/components/workspace-rename-modal.tsx:40-54`）。

**置顶：`workspace.pin.set.request{workspaceId, pinned}`**（1023-1028）

- 响应 `{…, accepted, pinnedAt, error}`（2147-2158），之后推送 `workspace_update`（`session.ts:3900-3930`）。
- 侧边栏置顶区按 `pinnedAt` 降序排列（`app/hooks/use-sidebar-pins.ts:13-50`）。

**归档：`archive_workspace_request{workspaceId}`**

- 响应 `{workspaceId, archivedAt, error}`（`session.ts:7488-7553`）。
- 服务端流程：先标记 `archivingAt`，杀掉终端，停掉 setup，归档 agent。
- 普通目录会保留。Paseo 自己建的 worktree，只有在没有其他活跃 workspace 引用它时才删除（`docs/glossary.md:7`）。
- App 侧：worktree 有未提交改动、领先 origin 或有 diffStat 时，先弹风险确认（`app/workspace/use-workspace-archive.ts:81-97`、`app/git/worktree-archive-warning.ts`）；然后乐观隐藏该行，失败时恢复（`app/workspace/workspace-archive.ts:41-100`）。
- 更细粒度的 `paseo_worktree_archive_request{workspaceId?, scope}`（2549-2575）菜单里没用到。

**标为已读：`workspace.clear_attention.request{workspaceId: string|string[]}`**（2735-2739）

- 响应 `{workspaceId, clearedAgentIds, results:[{workspaceId, clearedAgentIds, success, error}], success, error}`（5034-5051）。
- 服务端清掉该 workspace 下所有 agent 的 attention（`session.ts:7556-7690`）。
- App 只在 status 为 `attention` 或 `failed` 时提供这个菜单项（`app/hooks/use-workspace-read-state.ts:22-36`）。

**标为未读：`workspace.mark_unread.request{workspaceId}`**（2741-2745）

- 响应 `{workspaceId, markedAgentId, success, error}`（5053-5062）。
- 服务端挑一个最近更新、处于 idle/closed、没有 attention、没有待处理权限的根 agent 调 `markAgentUnread`。找不到时报 `"Workspace has no finished agent to mark unread"`（`session.ts:7692-7745`）。
- App 只在 `features.workspaceMarkUnread` 存在且 status 为 `done` 时提供。发送前先让 pane 失焦，否则未读标记会被焦点逻辑立刻清掉（`app/workspace/mark-unread.ts`）。

### 3.6 Workspace 标签（labels）

**数据模型**

- 标签目录按 host 存一份：`$PASEO_HOME/projects/workspace-labels.json`（`docs/data-model.md:486-505`）。
- 标签定义 `{name, color}`，color 取值：`violet, sky, emerald, orange, pink, indigo, teal, red, amber, blue`（`packages/protocol/src/workspace-labels.ts:1-12`）。
- 名字比较时先 trim、合并空白，并且不区分大小写（`workspaceLabelKey`）。
- workspace descriptor 里只存名字数组 `labels: string[]`。

**RPC**

| RPC | 字段 | 说明 |
| --- | --- | --- |
| `workspace.label.list.request` | `{subscribe?:{}, sync?:{generation, afterSeq}}` | 响应 `{labels, subscriptionId?, sync:{mode:"snapshot"\|"changes", generation, headSeq, removals}}`。之后推送 `workspace.label.update{kind:"upsert", label, previousName?, generation, seq}` 或 `{kind:"remove", name, …}`（`messages.ts:1040-1046, 4380-4412`；`session.ts:6534-6589`；`daemon-client.ts:2795-2803`） |
| `workspace.label.assignment.set.request` | `{workspaceId, label:{name,color}, assigned}` | 响应 `{label, workspaceLabels}`。名字不在目录里就自动创建；已存在时以目录里的颜色为准（`packages/server/src/server/workspace-labels/internal/service.ts:85-131`） |
| `workspace.label.update.request` | `{name, newName?, color?}` | 响应 `{label, affectedWorkspaceCount}`。改名撞上已有名字时报 `label_name_taken` |
| `workspace.label.delete.inspect.request` / `workspace.label.delete.request` | `{name}` | 响应 `{affectedWorkspaceCount}`。先 inspect，用结果生成确认文案 |

- 标签相关错误走 `rpc_error{code}`（`session.ts:6518-6531`），code 有：`label_name_empty | label_not_found | label_name_taken | workspace_not_found | workspace_label_failed`。
- 侧边栏可以按标签筛选，任一选中标签匹配即显示，另有 "Unlabelled" 选项（`app/components/sidebar/sidebar-labels.ts:29-42`）。标签管理弹窗在 `app/workspace-labels/manager-modal.tsx`。

### 3.7 官方 workspace 行菜单

定义在 `app/components/sidebar/sidebar-workspace-menu.tsx:158-246`，同时用作右键菜单和 kebab 菜单。顺序如下：

1. Copy path（纯本地）
2. Copy branch name（纯本地）
3. Rename（`title.set`）
4. Mark as read（`clear_attention`）
5. Mark as unread（`mark_unread`）
6. Pin / Unpin（`pin.set`）
7. Labels 子菜单（`assignment.set`）
8. Open in file manager（仅 desktop）
9. Archive（`archive_workspace`）

### 3.8 JSON 示例

```json
{"type":"workspace.create.request","requestId":"w31","idempotencyKey":"draft_8f2c1a","subscribe":true,
 "source":{"kind":"worktree","cwd":"/Users/me/projects/app","projectId":"prj_3b9e",
   "worktreeSlug":"fix-login-a1b2","action":"branch-off","refName":"refs/remotes/origin/main"},
 "agent":{"config":{"provider":"claude","cwd":"/Users/me/projects/app","modeId":"default"},
   "initialPrompt":"Fix the login redirect bug","clientMessageId":"m_01","labels":{}}}
```

```json
{"type":"workspace.create.update","payload":{"subscriptionId":"sub_7","kind":"workspace",
 "idempotencyKey":"draft_8f2c1a","revision":2,"phase":"workspace_ready",
 "workspaceId":"wks_1a2b3c4d5e6f7a8b","agentId":null,"error":null}}
```

```json
{"type":"forge.search.request","requestId":"w32","cwd":"/Users/me/projects/app","query":"login","limit":20,"kinds":["change_request"]}

{"type":"forge.search.response","payload":{"requestId":"w32","error":null,"authState":"authenticated",
 "items":[{"kind":"change_request","forge":"github","number":412,"title":"Fix login redirect",
   "url":"https://github.com/me/app/pull/412","state":"OPEN","body":null,"labels":[],
   "baseRefName":"main","headRefName":"fix/login-redirect"}]}}
```

```json
{"type":"directory_suggestions_request","requestId":"w33","query":"~/projects/",
 "includeDirectories":true,"includeFiles":false,"limit":30}

{"type":"directory_suggestions_response","payload":{"requestId":"w33","error":null,
 "directories":["/Users/me/projects/app","/Users/me/projects/paseo-native"],
 "entries":[{"path":"/Users/me/projects/app","kind":"directory"},
            {"path":"/Users/me/projects/paseo-native","kind":"directory"}]}}
```

```json
{"type":"workspace.label.assignment.set.request","requestId":"w34",
 "workspaceId":"wks_1a2b3c4d5e6f7a8b","label":{"name":"urgent","color":"red"},"assigned":true}
```

### 3.9 未确认

- `suggestBranchesForCwd` 怎么排序，是否包含 origin 以外的 remote（App 里把 `origin` 写死了）。
- worktree 创建时 `branchName` 是否在服务端校验，分支重名会返回什么 errorCode。
- `title.set` / `pin.set` 在什么情况下返回 `accepted:false`；目前只见到 not found 这一种。
- `archive_workspace_request` 重复调用是否幂等。
- 原生客户端是否需要 `paseo_worktree_archive_request`。

### 3.10 原生客户端实现清单

1. 解析 3.1 里的 feature flags，对应 flag 不存在时隐藏相关 UI。
2. 重命名、置顶、归档：都以 `workspace_update` 推送为准，响应里的 `error` 用 toast 提示。归档 worktree 前先做风险确认，然后乐观隐藏。
3. Mark as read / unread，显示条件按 3.5；agent pane 获得焦点时发 `clear_agent_attention`。
4. 添加项目：用不带 `cwd` 的 `directory_suggestions_request` 做搜索框，以 `/` 结尾时进入下一级；确定后发 `project.add.request`，再跳到新建 workspace。
5. 新建 local workspace：`source:{kind:"directory", path, projectId}`，加上 `agent`、`idempotencyKey`、`subscribe:true`。
6. 新建 worktree workspace：选择器里并行发 `branch_suggestions_request` 和 `forge.search.request`，按 3.3 映射成 `refName` 或 `checkoutSource`，再加上 `worktreeSlug`。
7. 创建进度与恢复：处理 `workspace.create.update` 的各个 phase；断线重连后发 `creation.subscribe.request`，拿到 null 就用同一个 key 重发；不给 create 设超时。
8. 标签：`workspace.label.list.request{subscribe:{}}` 加 `workspace.label.update` 推送；行菜单里的 Labels 子菜单；标签管理页（update，先 inspect 再 delete）；侧边栏筛选；处理 `rpc_error` 的 code。
9. （可选）`project.create_directory`、GitHub 仓库搜索和 clone、`validate_branch`。

---

## 4. Agent 扩展操作

这些 RPC 的名字 02（§10）已经列过，本节讲它们的语义和 UI 用法。

### 4.1 回退（rewind）：`agent.rewind.request`

**Schema**（`messages.ts:2074-2091`）

- 请求：`{agentId, messageId, mode: "conversation"|"files"|"both", requestId}`。
- 响应：`agent.rewind.response{payload:{requestId, agentId, ok, error}}`。注意这里的字段是 `ok`，不是 `accepted`。

**哪些模式可用**：看 agent 快照里的 `capabilities.supportsRewindConversation` / `supportsRewindFiles` / `supportsRewindBoth`（`messages.ts:417-422`，默认 false）。各 provider 的支持情况：

| provider | conversation | files | both | 出处 |
| --- | --- | --- | --- | --- |
| claude | ✓ | ✓ | ✓ | `packages/server/src/server/agent/providers/claude/agent.ts:374-376` |
| codex | ✓ | | | `codex-app-server-agent.ts:239-241` |
| pi / omp | ✓ | | | `pi/agent.ts:166`、`omp/agent.ts:124` |
| opencode | | | ✓ | `opencode-agent.ts:138-140` |

- `server_info.features.rewind`（3730）这个 flag 存在，但官方 App 不读它，只看 capabilities。原生客户端要不要也检查这个 flag，**未确认**。

**服务端行为**（`packages/server/src/server/agent/agent-manager.ts:3445-3500`、`session.ts:4835-4905`）

- `messageId` 是 user_message 的客户端 `messageId`。如果 provider 还没回 `providerMessageId`，报 "Cannot rewind before the provider acknowledges…"。
- 有正在进行的 run 时先取消。
- mode 不是 `files` 时，从 provider 重建 timeline，epoch 随之变化，并推送 `agent.timeline.replacement{agentId, epoch}`。
- 权限：`workspace.write`。

**App 侧**

- 入口：每条 user message 尾部的 `RewindMenu`，和时间戳、复制按钮放在一起；只在消息有文本且有 messageId 时出现（`app/components/message.tsx:519-536`）。
- 菜单项：Rewind conversation / Rewind files / Rewind conversation and files（`app/components/rewind/use-rewind-capabilities.ts:24-60`）。
- 成功后（非 `files` 模式），用旧 cursor 重新拉 tail，服务端检测到 epoch 变化会返回 `reset`（`use-rewind-agent-mutation.ts:33-48`）。
- conversation 和 both 模式下，把被回退的那条消息的文本放回 composer（`rewind-mode.ts`、`composer-restore.tsx`）。

### 4.2 分叉（fork）：`agent.fork_context.request`

daemon **只生成一段上下文文本附件，不会创建 agent**。

- 请求：`{agentId, boundaryCursor?:{epoch,seq}, boundaryMessageId?, requestId}`（`messages.ts:1964-1970`）。
- 响应：`{requestId, agentId, attachment: TextAttachment|null, itemCount, boundaryMessageId|null, boundaryCursor?|null, error}`（4936-4947）。
- `TextAttachment` = `{type:"text", mimeType:"text/plain", title?, text, contextKind?}`（1155-1165）。
- 服务端（`session.ts:8156-8210`）把 timeline 序列化到 boundary 为止；不给 boundary 时取全部内容，包括正在流式输出的 turn。权限：`workspace.read`。
- 能力位：`features.agentForkContext`（3763）。用 cursor 作边界还需要 `agentForkContextCursor`，没有的话改用 `boundaryMessageId`（`app/agent-stream/view.tsx:388`）。

**App 流程**（`app/hooks/use-fork-agent.ts:93-198`）

1. 入口是 assistant turn footer 上的 `AssistantForkMenu`，目标可选 `"tab"` 或 `"workspace"`。
2. 拿到附件后，作为 `chat_history` 类型的 composer 附件，开一个新 draft。
3. draft 复制源 agent 的 provider、cwd、modeId、model、thinkingOptionId，以及 `featureValues`（取自 `agent.features[].value`）。
4. 目标为 `workspace` 时，跳到新建 workspace 页面，`sourceDirectory = checkout.cwd`。
5. 用户发送时，附件随 agent 创建一起提交（大概率放在 `attachments[]` 里作为 text 条目，**未确认**）。

Provider subagent 是只读的，不能 fork（`use-fork-agent.ts:64`）。

### 4.3 解除父子关系：`agent.detach.request`

- 请求：`agent.detach.request{agentId, requestId}`。
- 响应：`agent.detach.response{requestId, agentId, accepted, error, notice?}`（`messages.ts:2061-2071`）。
- 效果：删除 `paseo.parent-agent-id` label 和所有 `paseo.open-agent-tab.<clientId>` label（`agent-manager.ts:723-731,2323-2370`）。
- 之后推送子 agent 所在 workspace 和原父 agent 根 workspace 的 `workspace_update`，以及该 agent 的 `agent_update`（`session.ts:3392-3440`）。
- App 侧：subagent track 行上的 Unlink 图标，点击后弹确认 "Detach subagent? … will leave this track and continue as a standalone agent."，确认后打开这个 agent（`app/subagents/detach-subagent.ts`、`app/subagents/track.tsx`）。

### 4.4 重载：`refresh_agent_request`

**没有单独的 reload RPC**。重载和取消归档都用 `refresh_agent_request{agentId}`（`session.ts:4713-4760`）。

**服务端流程**

1. 先取消归档。
2. agent 在内存中：中断当前 turn，然后 `reloadAgentSession(rehydrateFromDisk:true)`。
3. agent 不在内存中：从持久化数据恢复；provider 不可用或没有持久化 handle 时失败。
4. 从 provider 重新灌入 timeline。
5. 回复 `status{status:"agent_refreshed", agentId, requestId, timelineSize}`。

**App 侧**

- 入口：tab 菜单的 "Reload agent"，显示一个常驻的 reloading toast，然后用旧 cursor 拉 tail 拿到 `reset:true`（`app/screens/workspace/workspace-screen.tsx:2172-2190`）。
- 其他调用点：已归档 agent 提示条里的取消归档（`archived-agent-callout.tsx:29`），以及 agent 初始化失败时的兜底（`app/hooks/use-agent-initialization.ts:90-100`）。

### 4.5 thinking 与 provider features

**RPC**（`messages.ts:2004-2028`）

- `set_agent_thinking_request{agentId, thinkingOptionId|null}`
- `set_agent_feature_request{agentId, featureId, value}`
- 两者共用响应 payload：`{requestId, agentId, accepted, error, notice?:{type:"info"|"warning"|"error", message}}`（1979-1985, 323-327）。
- 服务端统一走 `AgentConfigSession.applyConfigChange`（`packages/server/src/server/session/agent-config/agent-config-session.ts:106-140`），新值通过 `agent_update` 回来。

**`agent.features[]` 的结构**（`messages.ts:329-354`）

```ts
| { type:"toggle", id, label, description?, tooltip?, icon?, value: boolean }
| { type:"select", id, label, description?, tooltip?, icon?, desktopTrigger?:"icon"|"label",
    value: string|null, options: AgentSelectOption[] }
```

- 发 `set_agent_feature_request` 时，toggle 传 bool，select 传 option id。
- App 用 fire-and-forget 调用，出错时 toast（`app/composer/agent-controls/index.tsx:1721`）。
- **还没有 agent 的 draft**：用 `list_provider_features_request{draftConfig:{provider, cwd, modeId?, model?, thinkingOptionId?, featureValues?}}` 拿到 features 列表（2948-2963, 6261-6270），选好的值通过 `featureValues` 随创建请求一起提交。

### 4.6 斜杠命令与技能：`list_commands_request`

**Schema**

- 请求：`{agentId, draftConfig?, requestId}`（`messages.ts:2963-2968`）。
- 响应：`list_commands_response{payload:{agentId, commands:[{name, description, argumentHint, kind?:"command"|"skill"}], error, requestId}}`（6457-6472）。未知的 `kind` 按 `"command"` 处理。

**服务端**（`session.ts:5049-5125`）

- 活跃 agent，或已存储且未归档的 agent：调用 `session.listCommands()`。
- 没有 agent 但带了 `draftConfig`：走 `listDraftCommands`。draft 场景下 `agentId` 可以传占位值。

**App 什么时候请求、缓存多久**（`app/hooks/use-agent-commands-query.ts:8-9,66-77`）：只在进入 `/` 模式时请求。会话命令 60 s 内视为新鲜，draft 命令永不过期，失败重试 3 次。

**触发规则**（`app/utils/agent-command-autocomplete.ts:85-117`）

- 找光标前最后一个 `/`，它要么在文本开头，要么前面是空白。
- `/` 到光标之间不能含 `/`、空白或引号。
- `/` 在第 0 位时 position 为 `start`，否则为 `inline`。

**列出哪些条目**（`use-agent-autocomplete.ts:206-237`）

- `start` 位置：客户端内置命令 → 插件命令 → provider 命令。
- `inline` 位置：只列 `kind=="skill"` 的条目。

**客户端内置命令**（`app/client-slash-commands/index.ts:17-36`）：不发 RPC、立即执行，只在没有附件时生效，draft 里隐藏。

- `/exit`（别名 `quit`、`q`）：归档当前 agent。
- `/clear`（别名 `new`）：归档后开一个新 draft。

**插入与发送**（:119-124）

- 把 `[start, end)` 区间替换为 `/name`；光标在文本末尾时再补一个空格。
- 在 `start` 位置按 Esc 会清空输入。
- 命令作为普通 prompt 文本（`/name args`）通过 `send_agent_message_request` 发出，由 provider 解释。没看到 daemon 侧有任何预处理（**未确认**）。

### 4.7 @文件提及：`directory_suggestions_request`

和 3.4 是同一个 RPC，区别是这里带 `cwd`，所以返回相对路径。

**触发规则**（`app/utils/file-mention-autocomplete.ts:20-57`）

- 找光标前最后一个 `@`，它前面不能是 `[\w+]`，这样可以排除邮箱地址。
- query 里不能含空白、引号、`<`、`>`。

**请求参数**（`use-agent-autocomplete.ts:401-474`）

- 防抖 180 ms。
- `{cwd: agent.cwd 或 draft 的 cwd, query, limit:50, includeFiles:true, includeDirectories:true}`。
- 结果 15 s 内视为新鲜；新请求加载期间继续显示上一次的结果。

**插入**：把 `@query` 替换成带双引号的相对路径 `"src/login.ts"`，路径里的 `"` 要转义。这只是纯文本，不会生成结构化附件。

### 4.8 消息队列：客户端实现

**队列在客户端**

- `sendBehavior` 是纯客户端偏好，取值 `"interrupt" | "steer" | "queue"`，默认 `"steer"`（`app/hooks/use-settings/storage.ts:145,225`；设置 UI 在 `app/screens/settings/general/sending-section.tsx`）。
- 即使选了 `queue`，只要 agent 有待处理的权限请求，就改用 `interrupt` 直接发，免得消息卡住（`app/composer/input/state.ts:9-14`）。

**入队**

- turn 进行中、且不是强制发送时，`submitAgentInput` 把消息放进队列（`app/composer/submit.ts:45-52`）。
- 队列数据结构：`sessionStore.queuedMessages: Map<agentId, [{id, text, attachments}]>`（`app/stores/session-store.ts:447`、`app/composer/actions.ts:246-262`）。

**UI**：composer 上方一条队列轨道，每条都有 Edit（弹回 composer 继续编辑）和 Send now（立即发送；失败时放回队首）（`app/composer/index.tsx:383-395,665-710`、`app/composer/actions.ts:275-337`）。

**出队**（`app/runtime/host-runtime.ts:2559-2610`、`app/timeline/viewed-timeline-sync.ts:252`）

- 触发：`onAgentStoppedRunning`，或者当前正在查看的 agent 的 turn phase 变成 `idle`。
- 一次取队首一条，以 `activeTurnBehavior:"steer"` 发出；每个 agent 同一时间只有一条在途。

**daemon 侧的队列**：只服务于 agent 之间发消息（请求带 `sourceAgentId`），这时响应里 `deliveryStatus:"queued"`（`messages.ts:5070`、`session.ts:8259-8283`）。和 UI 的消息队列无关。

**持久化**：App 重启后队列是否还在，**未确认**。队列里图片附件的 id 不会被清理（`app/stores/draft-store/index.ts:189-200`）。

### 4.9 子 agent：两套互不相干的机制

**(a) Paseo 子 agent**：别的 agent 通过 MCP `create_agent` 创建出来的普通 agent。

- 带 label `paseo.parent-agent-id`；跨 host 时还有 `paseo.parent-server-id`，缺省表示同一台 host（`packages/protocol/src/agent-labels.ts:2-3,18-46`）。
- `paseo.open-agent-tab.<clientId>="true"` 表示这个子 agent 在某个客户端开了独立 tab。
- 父子关系由客户端根据 agent 列表自行推导（`app/subagents/select.ts:74-100`）。
- 子 agent 是完整的 agent：可以打开、归档、detach。

**(b) Provider subagent**：provider 内部的子 agent，比如 Claude 的 Task 工具。只读，不能 fork。

- 前置条件：
  - 能力位 `features.providerSubagents`；嵌套展示（`parentSubagentId`）还需要 `providerSubagentNesting`（`select.ts:180-185`）。
  - hello 里声明 capability `provider_subagents`（`messages.ts:7687`）。
  - 订阅 `agent.provider_subagents.update` 事件。
- 列表：`agent.provider_subagents.list.request{parentAgentId}` → `{subagents:[Descriptor], error}`（4801-4831）。
  - Descriptor 字段：`{id, parentAgentId, parentSubagentId?, provider, title|null, description|null, status:"running"|"completed"|"failed"|"canceled", createdAt, updatedAt, toolCallId|null, cwd?, subtitle?}`。
  - `subtitle` 只用于显示，不要解析。
- 时间线：`agent.provider_subagents.timeline.get.request{parentAgentId, subagentId, direction?, cursor?, limit?}`，返回常规的 timeline 分页结构（1948-1956, 4833-4874）。
- 推送：`agent.provider_subagents.update`，`kind` 取值：
  - `upsert{subagent}`
  - `timeline{parentAgentId, subagentId, provider, item, timestamp, seq, epoch}`
  - `remove{parentAgentId, subagentId}`
  
  定义见 4876-4903，App 的 reducer 在 `app/subagents/provider-store.ts:220-275`。
- 流量：这个事件只能按事件名订阅，daemon 会把整台机器上每个子代理的每一步都推过来（`session.ts` `forwardProviderSubagentUpdate`，实测几个子代理在跑时约 0.9 KB/s）。本 App 不放进主订阅，而是单开一条只含它的 events 订阅，仅在屏幕上的会话有运行中子代理时打开；侧栏、灵动岛要的「父会话空闲、后台子代理在跑」改用回合结束时、每 30 s（仅对缓存里仍在跑的）和连接时（最近 30 分钟活跃的空闲会话）拉列表。实现见 `HostStore+HostPane.swift`「Provider subagent pushes」。

两种子 agent 在 UI 上都渲染在父 agent composer 上方的同一条 "track" 里（`app/subagents/track.tsx`）。provider subagent 可以通过 `toolCallId` 关联到产生它的那个 tool call。

### 4.10 JSON 示例

```json
{"type":"agent.rewind.request","agentId":"8b1d2c3e-5f6a-4b7c-8d9e-0f1a2b3c4d5e","messageId":"msg_01JB8Q2X","mode":"conversation","requestId":"a41"}
{"type":"agent.rewind.response","payload":{"requestId":"a41","agentId":"8b1d2c3e-5f6a-4b7c-8d9e-0f1a2b3c4d5e","ok":true,"error":null}}
```

```json
{"type":"agent.fork_context.request","agentId":"8b1d2c3e-…","boundaryCursor":{"epoch":"ep_9a1","seq":212},"requestId":"a42"}
{"type":"agent.fork_context.response","payload":{"requestId":"a42","agentId":"8b1d2c3e-…",
 "attachment":{"type":"text","mimeType":"text/plain","title":"Fix login flow","text":"<conversation transcript…>"},
 "itemCount":37,"boundaryMessageId":null,"boundaryCursor":{"epoch":"ep_9a1","seq":212},"error":null}}
```

```json
{"type":"list_commands_request","agentId":"8b1d2c3e-…","requestId":"a43"}
{"type":"list_commands_response","payload":{"agentId":"8b1d2c3e-…","requestId":"a43","error":null,"commands":[
 {"name":"compact","description":"Clear conversation history but keep a summary","argumentHint":"<instructions>","kind":"command"},
 {"name":"paseo-handoff","description":"Hand off the current task to another agent","argumentHint":"","kind":"skill"}]}}
```

```json
{"type":"directory_suggestions_request","cwd":"/Users/me/projects/app","query":"src/log","limit":50,
 "includeFiles":true,"includeDirectories":true,"requestId":"a44"}
{"type":"directory_suggestions_response","payload":{"requestId":"a44","error":null,
 "directories":["src/logging"],"entries":[{"path":"src/logging","kind":"directory"},{"path":"src/login.ts","kind":"file"}]}}
```

```json
{"type":"set_agent_feature_request","agentId":"8b1d2c3e-…","featureId":"fast_mode","value":true,"requestId":"a45"}
{"type":"set_agent_feature_response","payload":{"requestId":"a45","agentId":"8b1d2c3e-…","accepted":true,"error":null}}
```

上面的 `fast_mode` 只是示意，实际的 id 以 `agent.features[].id` 为准。

### 4.11 原生客户端实现清单

1. Thinking 和 features 控件：根据 `agent.features[]` 渲染；发 set 请求后以 `agent_update` 回来的值为准，`notice` 和 `error` 用 toast 提示。draft 场景用 `list_provider_features_request`。
2. Reload：发 `refresh_agent_request`，等到 `status: agent_refreshed`，再用旧 cursor 拉 tail 并处理 `reset`。
3. 客户端消息队列：每个 agent 一个数组，加上 `sendBehavior` 偏好。turn 变 idle 时取队首用 steer 发出；有待处理权限时改用 interrupt；每条提供 Edit 和 Send now。
4. `/` 自动补全：触发和插入规则见 4.6；结果缓存 60 s；inline 位置只列 skill；`/exit` 和 `/clear` 在本地实现。
5. `@` 自动补全：`directory_suggestions_request`，带 agent 的 cwd，防抖 180 ms，limit 50，插入带引号的相对路径。
6. Rewind：根据 capabilities 生成菜单，只对有 messageId 的 user 行提供；收到 replacement 后重拉 tail；conversation 和 both 模式把文本放回 composer。
7. Fork（检查 `agentForkContext`）：拿到附件后开新 draft，复制源 agent 的配置并带上附件。
8. Paseo 子 agent track：根据 `paseo.parent-agent-id` label 推导，支持归档和 `agent.detach.request`。
9. （最后做）Provider subagent：hello capability、事件订阅、能力位，三者齐全后实现列表、推送和只读 timeline。

---

## 5. 设置：daemon 配置与客户端偏好

### 5.1 Daemon 配置 RPC

**读取**：`get_daemon_config_request{requestId}` → `get_daemon_config_response{payload:{requestId, config: MutableDaemonConfig}}`（`messages.ts:1661-1664, 5086-5094`；`session.ts:2918-2923`）。权限：`daemon.read`。

**写入**：`set_daemon_config_request{requestId, config: MutableDaemonConfigPatch}` → `set_daemon_config_response{payload:{requestId, config}}`，返回改完之后的完整配置（`messages.ts:1666-1670, 5198-5206`；`session.ts:2939-2948`）。

- 权限：`daemon.manage`（`operation-permissions.ts:106,184`）。
- 客户端方法：`patchDaemonConfig`（`daemon-client.ts:5545`）。

**推送**：每次改动后广播 `{type:"status", payload:{status:"daemon_config_changed", config}}`（`websocket-server.ts:2132-2158`）。

- modern 客户端需要订阅事件 `status.daemon_config_changed`（`session.ts:8786`）。
- App 收到后直接替换缓存（`app/hooks/use-daemon-config.ts`、`app/data/push-router.ts:282-284`）。

**从磁盘重载**：`daemon.config.reload.request`（1437, 5176-5185），返回 `{appliedPaths, restartRequiredPaths, overrideControlledPaths}`，需要 `features.daemonConfigReload`。官方 App 没用到。

**Patch 语义**（`packages/server/src/server/daemon-config-store.ts:86-105, 275-306, 381-445`）

- 对象做深合并；**数组和标量整体替换**。所以 `terminalProfiles`、`agentProfiles`、`metadataGeneration.providers` 每次都要发完整数组。
- `removeProviders: [id]` 用来删除 provider。
- 不在支持列表里的字段会被静默丢弃，比如 `skills`。
- relay 由启动参数覆盖时，修改 `relay.enabled` 会报错。
- 配置持久化到 `$PASEO_HOME/config.json`（`packages/server/src/server/persisted-config.ts:378-402`）。

**可以 patch 的键**（`messages.ts:206-250`）

| 键 | 结构 / 说明 |
| --- | --- |
| `relay` | `{enabled, requireProtectedSecurity?}` |
| `mcp` | `{injectIntoAgents}` |
| `browserTools` | `{enabled}` |
| `providers.<id>` | `{enabled?, paseoTools?{enabled?, disabledTools?}, additionalModels?[{id,label,description?,isDefault?}], …}`，其余字段透传（extends/label/command/env/params） |
| `removeProviders` | `[id]` |
| `metadataGeneration` | `{providers:[{provider, model?, thinkingOptionId?}]}` |
| `autoArchiveAfterMerge` | |
| `enableTerminalAgentHooks` | |
| `idleRuntimeCleanup` | |
| `appendSystemPrompt` | |
| `terminalProfiles` | `[{id,name,command,args?,icon?}]`（`packages/protocol/src/terminal-profile.ts`） |
| `agentProfiles` | `[{id,name,icon?,color?,provider,model?,modeId?,thinkingOptionId?,featureValues?,notes?}]`（`packages/protocol/src/agent-profile.ts:12-28`） |
| `pluginsEnabled` | |
| `plugins` | |
| `features` | `{dictation{enabled, stt}, voiceMode{enabled, stt, tts, llm?, turnDetection?}}`；patch 里可以带 `apiKey`，传 null 表示清除（`packages/protocol/src/speech/rpc-schemas.ts:32-130`） |

**只读的键**（读得到，但不能 patch）：

- `mcp.enabled`、`hostnames`、`cors`、`trustedProxies`、`git{maxProcessesPerSecond, maxProcessConcurrency}`、`app.baseUrl`、`catalogRefreshTimeoutMs`、`envOverrides`。
- `skills.selection` 要通过 `agent.skills.save_selection.request`（1647）修改。

### 5.2 官方设置项中由 daemon 配置支撑的部分

都在 Settings → Host 页面下，路径 `app/screens/settings/…`。

| 设置项 | 配置键 | 出处 |
| --- | --- | --- |
| Agents · 向 agent 注入 Paseo 工具 | `mcp.injectIntoAgents`（只要不是 `false` 就显示为开） | `host-page.tsx:865-900` |
| Agents · Browser tools | `browserTools.enabled` | `browser-tools-card.tsx:22` |
| Agents · 追加系统提示词 | `appendSystemPrompt` | `host-page.tsx:983-1015` |
| Agents · 空闲 runtime 清理 | `idleRuntimeCleanup`（只要不是 `false` 就显示为开） | `idle-runtime-cleanup-card.tsx:21,61` |
| Agents · Agent profiles | `agentProfiles` | `app/agent-profiles/internal/use-agent-profiles.ts:24` |
| Workspaces · 合并后自动归档 | `autoArchiveAfterMerge` | `host-page.tsx:904-933` |
| Terminals · 终端 agent hooks | `enableTerminalAgentHooks` | `host-page.tsx:943-973` |
| Terminals · Terminal profiles | `terminalProfiles` | `host-page.tsx:1431-1451` |
| Providers · 启用/停用 | `providers.<id>.enabled` | `providers-section.tsx:369` |
| Providers · 删除 | `removeProviders` | `providers-section.tsx:398` |
| Providers · 添加 ACP provider | `providers.<id>{extends:"acp",…}` | `app/hooks/use-acp-provider-catalog.ts:11-31` |
| Provider 详情 · 额外模型 | `providers.<id>.additionalModels` | `app/components/provider-diagnostic-sheet.tsx:162-179,604-655` |
| Metadata generation（自动命名所用模型） | `metadataGeneration.providers` | `metadata-generation-page.tsx:27-50` |
| Voice（听写 / 语音模式） | `features`（同时读 `envOverrides`） | `voice/voice-page.tsx:56-103` |
| Plugins 总开关 | `pluginsEnabled` | `plugins-page.tsx:392,487` |
| Pair device · 启用 relay | `relay.enabled`（需要 `features.relayConfig`） | `app/desktop/components/pair-device-section.tsx:67-70` |

**只读取不修改的地方**：`terminalProfiles` 还被新建 workspace 页（`new-workspace-screen.tsx:917-920`）、workspace header 菜单（`workspace-header-menu.tsx:241`）和 launcher（`app/workspace-tabs/launcher/index.tsx:222`）读取。

**Host 页里走其他 RPC、不走 config 的部分**

- Agent skills：`agent.skills.get_status|reconcile|uninstall|save_selection|import_legacy_selection`（`app/agent-skills/use-agent-skills.ts`）。
- 重启：`restart_server_request`（`daemon-client.ts:4043`）。
- 升级：`daemon.update.request`。
- 用量：见第 2 节。
- 项目配置：`read_project_config_*` 系列。
- 插件：插件相关 RPC。

### 5.3 纯客户端偏好

**`AppSettings`**，存储 key 为 `@paseo:app-settings`（`app/hooks/use-settings/keys.ts:3`；schema 在 `app/hooks/use-settings/storage.ts:77-160`）。

外观与字体：

- `theme`、`pluginThemeId`、`language`
- `uiFontFamily`、`monoFontFamily`、`uiBaseFontSize`、`contentFontSize`、`codeFontSize`、`contentMaxWidth`、`syntaxTheme`

发送与输入：

- `sendBehavior: "interrupt"|"steer"|"queue"`（默认 steer，见 4.8）
- `sendShortcut: "enter"|"mod-enter"`
- `vimKeybindings`

聊天显示：

- `chatDisplay: "full"|"collapseToolCalls"|"collapseTurns"`
- `autoExpandReasoning`、`chatOutlineEnabled`

侧边栏与工作区：

- `workspaceTitleSource: "title"|"branch"`
- `sidebarWorkspaceTrailing: "diff"|"timestamp"|"none"`
- `sidebarRowItems{branch, project, host, changeRequest, labels, …}`
- `sidebarChecksDisplay`
- `sidebarNavItems` / `sidebarFooterItems`：`[{key, visible}]`

用量：

- `usage{displayAs, pins, serverId}`

打开方式与面板：

- `serviceUrlBehavior: "ask"|"in-app"|"external"`
- `openInSidePane{explorerFiles, diffs, chatFiles, diffFiles, subagents}`
- `pullRequestOpenLocation: "main"|"side"|"explorer"`
- `filePanelAssociations`

终端：

- `terminalScrollbackLines`

仅 desktop：

- `manageBuiltInDaemon`、`releaseChannel`

**其他本地存储**

- `@paseo:keyboard-shortcut-overrides`（`app/hooks/use-keyboard-shortcut-overrides.ts:11`）
- `@paseo:daemon-registry`：host 列表，以及 Host → Appearance 里设置的标签和颜色（`app/runtime/host-runtime.ts:1529`）
- `@paseo:preferred-editor`
- `@paseo:changes-preferences`
- `sidebar-view`
- `paseo-drafts`
- `paseo:last-workspace-route-selection`
- `@paseo:sidebar-callout-dismissals`
- `@paseo:client-id-v1`

上面这些在 `app/stores/*`。

**仅 desktop（Electron）的设置区**：浏览器数据、integrations、通知、系统权限、本地 daemon 启停。设置分区的完整列表见 `app/screens/settings-screen.tsx:164-229`。

### 5.4 JSON 示例

```json
{"type":"set_daemon_config_request","requestId":"c2",
 "config":{"autoArchiveAfterMerge":true,"providers":{"codex":{"enabled":false}}}}
```

```json
{"type":"status","payload":{"status":"daemon_config_changed","config":{
 "mcp":{"enabled":true,"injectIntoAgents":true},"browserTools":{"enabled":false},
 "providers":{"codex":{"enabled":false}},"metadataGeneration":{"providers":[]},
 "autoArchiveAfterMerge":true,"enableTerminalAgentHooks":false,"idleRuntimeCleanup":true,
 "appendSystemPrompt":"","terminalProfiles":[{"id":"zsh","name":"zsh","command":"zsh"}],
 "agentProfiles":[],"pluginsEnabled":true}}}
```

### 5.5 未确认

- `providers.<id>.paseoTools` 服务端怎么应用，以及哪个 UI 会修改它。
- 普通 `set` 之后哪些键需要重启 daemon 才生效；只有 reload RPC 会返回 `restartRequiredPaths`。
- `get_daemon_config_response` 会不会带出密钥。speech 相关字段只暴露 `hasApiKey`，推测不会。

### 5.6 原生客户端实现清单

1. 订阅 `status.daemon_config_changed`；每台 host 发一次 `get_daemon_config_request` 并缓存结果。
2. 写一个通用 patch helper：只发最小差异，**数组整个发**；拿 `set_daemon_config_response` 返回的 config 覆盖本地状态。
3. 显示编辑控件前，检查 `daemon.manage` 权限和相关 feature 位（`relayConfig` 等）。
4. Host 设置页按这个顺序实现：
   1. Agents：MCP 注入、browser tools、系统提示词、空闲清理
   2. Workspaces：自动归档
   3. Providers：启用、删除、额外模型
   4. Terminals：profiles、hooks
   5. Metadata generation
   6. Agent profiles
   7. Voice
   8. Plugins 总开关
5. 客户端偏好存进 UserDefaults，优先做 `sendBehavior`、`sendShortcut`、主题和字体、`chatDisplay`、侧边栏行内容和可见性、usage 偏好、`workspaceTitleSource`、host 列表及其标签和颜色。
