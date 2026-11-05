# 03 · 宿主面板协议：文件、Git、终端、工作区脚本（v0.14.0）

本文覆盖原生客户端「宿主面板（host pane）」需要的协议：Explorer 侧栏的 Files / Changes / PR、文件查看器、终端 Tab、工作区脚本。传输、信封、E2EE、订阅模型分别见 `01-connection.md` 与 `02-messages.md`，这里不重复。

源码基准：`vendor/paseo`（tag v0.14.0）。引用路径缩写：

| 缩写 | 实际路径 |
| --- | --- |
| `messages.ts` | `packages/protocol/src/messages.ts` |
| `bf/…` | `packages/protocol/src/binary-frames/…` |
| `client.ts` | `packages/client/src/daemon-client.ts` |
| `service.ts` | `packages/server/src/server/file-explorer/service.ts` |
| `files-session.ts` | `packages/server/src/server/session/files/workspace-files-session.ts` |
| `checkout-session.ts` | `packages/server/src/server/session/checkout/checkout-session.ts` |
| `tsc.ts` | `packages/server/src/terminal/terminal-session-controller.ts` |
| `session.ts` | `packages/server/src/server/session.ts` |
| `ws-server.ts` | `packages/server/src/server/websocket-server.ts` |
| `app/…` | `packages/app/src/…` |

通用约定（本文所有请求都适用）：

- 所有请求都是 `{"type":"session","message":{…}}` 信封里的 session 消息（01 §6.1）；下文 JSON 只写内层 `message`。
- 每个请求都带客户端生成的 `requestId`，响应 `payload.requestId` 原样带回。
- **modern 模式（`owned_subscriptions`）下，订阅型请求必须带 `requestId`、不得带 `subscriptionId`**，否则抛错（`packages/server/src/server/session/owned-subscriptions/index.ts:285-288`）。订阅 ID 由 Host 分配，在响应 `payload.subscriptionId` 中返回；释放统一用 `subscription.release.request`（02 §1.3）。
- 路径：几乎所有文件/Git 请求都以 `cwd`（工作区目录，`workspace.workspaceDirectory`）为根，`path` 是相对 `cwd` 的 POSIX 相对路径（根目录写 `"."`）。服务器对 `cwd` 做 `~` 展开。

---

## 0. 功能开关速查（`server_info.features`）

v0.14.0 Daemon 下面这些全部为 `true`（`ws-server.ts:2000-2125`）。客户端仍应按开关做降级，因为可能连到旧 Daemon。

| 开关 | 门控的能力 | 缺失时官方 App 的行为 |
| --- | --- | --- |
| `workspaceFileEditing` | `fs.file.subscribe/unsubscribe`、`fs.file.write` | 不订阅文件变化，只读一次；禁止编辑（`app/file-panels/file/daemon-session.ts:11-29,62`） |
| `fileByteWrites` | `fs.file.write` 的 `contentEncoding:"base64"`（二进制写入） | 只允许写文本（`daemon-session.ts:66`） |
| `fsEntryOps` | `fs.entry.create/rename/delete` | 隐藏新建/重命名/删除（`app/components/file-explorer-pane.tsx:464-470,996-1000`） |
| `fsEntryDuplicate` | `fs.entry.duplicate` | 隐藏「复制一份」 |
| `checkoutRefresh` | `checkout.refresh.request` | — |
| `checkoutDiscardChanges` | `checkout.discard_changes.request` | 隐藏「丢弃更改」 |
| `checkoutDiffAll` | diff `compare.mode:"all"` | **未确认**（app 内未找到直接引用，推测只用于隐藏 "all" 选项） |
| `commitsList` / `commitBaseClassification` | `checkout.commits.list`、提交的 `isOnBase` | — |
| `checkoutForgeSetAutoMerge` / `forgeCheckDetails` | forge 中立的自动合并 / CI 详情 RPC；否则退回 `checkout.github.*` | — |
| `workspaceTerminals` | 以 `workspaceId` 归属的终端（`create_terminal_request.workspaceId` 必需） | SDK 直接报错要求升级（`packages/client/src/terminals/index.ts:87-90`） |
| `terminal-restore-modes` | `subscribe_terminal_request.restore` → `Restore`(0x05) 帧 | 不带 `restore`，收 `Snapshot`(0x04) JSON 帧（`app/terminal/runtime/terminal-restore-options.ts:11-23`） |
| `terminal-input-mode-replay` | 订阅后回放输入模式前导序列（§3.6） | — |
| `terminal-size-ownership` | resize 的 `intent: "claim"\|"update"` 语义（§3.7） | — |
| `workspaceScriptManagement` | `workspace.script.list/start/stop.request` | 只能用旧的 `start_workspace_script_request` |

没有专门门控 `file_explorer_request`、`file.upload.request`、`checkout_*` 基础操作、`list/create/subscribe_terminal` 的开关——它们在所有受支持版本上都可用。

另外，Host 对写操作做权限检查：`file_explorer_request`/`subscribe_terminal_request` 需 `workspace.read`，`fs.*` 写、`file.upload.request`、`create_terminal_request`、`terminal_input`、`checkout_commit_request`、`workspace.script.start.request` 等需 `workspace.write`（`packages/server/src/server/authorization/operation-permissions.ts:60-220`）。**入站二进制帧（终端 Input/Resize、上传 FileChunk）在没有 `workspace.write` 时被静默丢弃**（`session.ts:3238-3251`）。配对的设备默认拥有全部权限（**未确认**细节，见 02）。

---

## 1. 文件

### 1.1 列目录：`file_explorer_request` mode=`list`

请求（`messages.ts:2804-2812`）：

```json
{"type":"file_explorer_request","requestId":"r10",
 "cwd":"/Users/me/code/app","path":"src","mode":"list"}
```

`path` 省略等价于 `"."`。响应（`messages.ts:6087-6098`，条目 schema `messages.ts:2780-2786`）：

```json
{"type":"file_explorer_response","payload":{
  "requestId":"r10","cwd":"/Users/me/code/app","path":"src","mode":"list",
  "directory":{"path":"src","entries":[
    {"name":"index.ts","path":"src/index.ts","kind":"file","size":1834,"modifiedAt":"2026-11-02T09:14:03.120Z"},
    {"name":"components","path":"src/components","kind":"directory","size":192,"modifiedAt":"2026-11-01T22:40:51.004Z"},
    {"name":".env.local","path":"src/.env.local","kind":"file","size":88,"modifiedAt":"2026-10-30T08:00:00.000Z"}
  ]},
  "file":null,"error":null}}
```

服务端语义（`service.ts:156-204`，`files-session.ts:247-290`）：

- **无分页**：一次返回该目录的全部直接子项（非递归）。
- **隐藏文件不过滤**：`.` 开头的条目照样返回；「显示隐藏文件」是**客户端**过滤（`app/file-explorer/visibility.ts:11-16`，规则：`name.startsWith(".")`）。
- `kind` 只有 `file` / `directory`。符号链接按 `fs.stat` 跟随目标判定；悬空链接、指向工作区外的链接**被静默跳过**（`service.ts:180-187`）。
- `size` 是字节数（目录是 `stat.size`，无实际意义）；`modifiedAt` 是 mtime 的 ISO-8601 UTC。
- 服务端排序：mtime 降序，再按 `name.localeCompare`（`service.ts:192-198`）。**官方 App 不依赖服务端顺序**：始终目录在前，再按用户选择的 name / modified（降序）/ size（降序）排序（`app/file-explorer/tree.ts:187-202`）。
- 返回的 `directory.path` 是规范化后的相对路径（根为 `"."`）。客户端应以它（而不是请求的 `path`）作为缓存键。
- 越界保护：`path` 解析后（含 realpath）必须在 `cwd` 内，否则 `error:"Access outside of workspace is not allowed"`（`service.ts:825-848`）。
- 出错时 `directory:null`、`error` 为字符串，例如 `"Requested path is not a directory"`、`ENOENT…`。

官方 App 的树：首次只列 `"."`，展开某个目录时再列该目录；刷新是**手动**的（刷新按钮重列根 + 所有已展开目录，`app/components/file-explorer-pane.tsx:884-901,1606-1632`）。**目录列表没有推送订阅**，文件树不会自动更新。

### 1.2 读文件：`file_explorer_request` mode=`file`

请求：

```json
{"type":"file_explorer_request","requestId":"r11",
 "cwd":"/Users/me/code/app","path":"src/index.ts","mode":"file",
 "acceptBinary":true,"maxBytes":67108864}
```

- `acceptBinary:true`：允许 Host 用二进制 FileBegin/FileChunk/FileEnd 帧流式回传（§1.3）。**官方客户端读文件总是带 `acceptBinary:true`**（`client.ts:5088-5123`）。v1 也应如此——否则图片走 base64 JSON、二进制文件**不带内容**。
- `maxBytes`（可选）：Host 先 stat，`size > maxBytes` 直接回 `error:"File is too large to display"`，不传输内容（`files-session.ts:292-297`）。App 的下载走 64 MiB（`app/stores/download-store.ts:21`），文件查看器不传。

**分类规则**（`service.ts:95-137,249-302,348-382`）：

| 判定顺序 | kind | mime |
| --- | --- | --- |
| 扩展名 ∈ `.png .jpg .jpeg .gif .webp .svg` | `image` | `image/png` … `image/svg+xml` |
| 扩展名 ∈ `.pdf .zip .gz .mp3 .mp4 .woff2`，或含 NUL 字节，或控制字符占比 > 30%，或不是合法 UTF-8 | `binary` | 表内 mime，否则 `application/octet-stream` |
| 其他 | `text` | `.json` → `application/json`，其余一律 `text/plain` |

文本编码只认 UTF-8（无 BOM/编码探测）。没有服务端行数/字节上限（除 `maxBytes`），但 relay 帧上限 32 MiB 决定了 JSON 回退路径的实际上限。

**两条回传路径**（`files-session.ts:298-363`）：

1. **二进制路径**（`acceptBinary && 连接有二进制通道`，WebSocket/relay 均有）：Host **不发** `file_explorer_response`，只发 FileBegin → 0..N 个 FileChunk → FileEnd。成功时 JSON 响应由客户端在本地合成（官方客户端在 FileEnd 时合成一条 `error:null, file:null` 的 `file_explorer_response` 来唤醒等待者，`client.ts:6852-6935`）。中途失败（例如「File changed during transfer」）Host 会在已发出 FileBegin 后再发一条带 `error` 的 `file_explorer_response`——客户端必须同时监听同 `requestId` 的 JSON 错误响应并丢弃半截缓冲。
2. **JSON 回退**（没带 `acceptBinary`）：一条 `file_explorer_response`，`file`（`messages.ts:2788-2797`）：

```json
{"type":"file_explorer_response","payload":{
  "requestId":"r12","cwd":"/Users/me/code/app","path":"assets/logo.png","mode":"file",
  "directory":null,"error":null,
  "file":{"path":"assets/logo.png","kind":"image","encoding":"base64",
          "content":"iVBORw0KGgoAAAANSUhEUgAA…","mimeType":"image/png",
          "size":5120,"modifiedAt":"2026-11-02T09:14:03.120Z",
          "revision":"16777230:9024311:5120:1762074843120000000"}}}
```

`encoding`：text → `utf-8`（`content` 为原文），image → `base64`，binary → `none`（**无 content**，只有 size）（`service.ts:206-247`）。

`revision` = `dev:ino:size:mtimeNs`（`service.ts:116-118`），是写回时做乐观并发控制的令牌（§1.6）。

图片预览：拿到字节后按 mime 交给 `UIImage`/`NSImage`；`image/svg+xml` 需要自己的 SVG 渲染（例如 WKWebView），官方 App 用 HTML/文档框架渲染（**未确认**原生实现细节）。

### 1.3 二进制文件传输帧（0x10–0x12）精确布局

定义：`bf/file-transfer.ts:4-8,60-150`。所有多字节整数**大端**。`requestId` 为 UTF-8，长度 1..255 字节（官方用 UUID）。

```
FileBegin (0x10):
  [0]      u8   opcode = 0x10
  [1]      u8   L  = requestId 字节长度 (1..255)
  [2..2+L) utf8 requestId
  [2+L..]  u16  M  = metadata JSON 字节长度 (BE, ≤ 65535)
  [4+L..]  utf8 metadata JSON（长度必须恰好 = M，且帧到此结束）

FileChunk (0x11):
  [0] 0x11 | [1] L | [2..2+L) requestId | [2+L..end) 原始文件字节（可为 0 字节）

FileEnd (0x12):
  [0] 0x12 | [1] L | [2..2+L) requestId     （之后不得有任何字节）
```

FileBegin 的 metadata（`bf/file-transfer.ts:10-17`）：

```json
{"mime":"image/png","size":5120,"encoding":"binary",
 "modifiedAt":"2026-11-02T09:14:03.120Z",
 "revision":"16777230:9024311:5120:1762074843120000000"}
```

`encoding` ∈ `utf-8`（文本）/ `binary`（图片与二进制）。上传方向可多带 `fileName`。

示例：`requestId="r11"`，metadata JSON 长 0x0067 字节：

```
10 03 72 31 31 00 67 7B 22 6D 69 6D 65 22 3A …（JSON）
11 03 72 31 31 <≤256 KiB 文件内容>
11 03 72 31 31 <…>
12 03 72 31 31
```

解码校验（必须照做，否则与官方行为不一致）：帧 < 2 字节、`L == 0`、`L > 剩余长度` → 非法；FileBegin 的 `M != 剩余长度-2` 或 JSON 不合 schema → 非法；FileEnd 携带额外字节 → 非法（`bf/file-transfer.ts:91-130`）。客户端分发顺序：先试 host-route（0x30），再试文件帧，再试终端帧（`client.ts:6798-6850`）——由于 opcode 区间不重叠，Swift 直接按首字节 switch 即可。

接收端组装（照搬 `client.ts:6852-6935`）：

1. 只接受自己有待决 `file_explorer_request` 的 `requestId` 的 FileBegin；记下 mime/size/encoding/modifiedAt/revision。
2. FileChunk 追加（Host 每块最多 256 KiB，`service.ts:110`）。
3. FileEnd 时校验累计字节 == `size`，否则报「File transfer incomplete」。
4. 结果 kind：mime 以 `image/` 开头 → image；`encoding=="utf-8"` 或 `text/*` 或 `application/json` → text；否则 binary（`client.ts:1147-1155`）。

### 1.4 下载到本机

官方 App 两条路（`app/stores/download-store.ts:105-150`）：

1. `file_download_token_request {cwd,path}` → `file_download_token_response {token,fileName,mimeType,size,error}`（`messages.ts:2909-2914,6216-6228`）。直连时用 `GET http://<host>/api/files/download?token=<token>` 下载（一次性 token，默认 TTL 60 s，`packages/server/src/server/bootstrap.ts:688-691,856-912`）。
2. **relay/无 HTTP 端点时**（v1 的默认情形）：先拿 token 只为得到 `size`/`fileName`，`size > 64 MiB` 拒绝；然后走 §1.2 的二进制读（`maxBytes = 64 MiB`）。

v1 建议只实现第 2 条（复用读文件代码）。

### 1.5 文件观察：`fs.file.subscribe.request`（需 `workspaceFileEditing`）

用于文件查看器感知外部修改（`app/file-panels/file/daemon-session.ts:23-55`）。只观察**单个文件**的版本（stat），不推内容；内容变化后客户端自己重读。

```json
{"type":"fs.file.subscribe.request","requestId":"r20","cwd":"/Users/me/code/app","path":"src/index.ts"}
```

响应（`messages.ts:6100-6107`，`FileVersionSchema` `messages.ts:2814-2838`）：

```json
{"type":"fs.file.subscribe.response","payload":{"requestId":"r20","subscriptionId":"7d2c…",
 "initial":{"status":"ready","cwd":"/Users/me/code/app","path":"src/index.ts","size":1834,
   "modifiedAt":"2026-11-02T09:14:03.120Z","revision":"16777230:9024311:1834:1762074843120000000",
   "kind":"text","mimeType":"text/plain"}}}
```

推送：

```json
{"type":"fs.file.update","payload":{"subscriptionId":"7d2c…",
 "version":{"status":"ready","cwd":"/Users/me/code/app","path":"src/index.ts","size":1901,
   "modifiedAt":"2026-11-02T09:20:11.002Z","revision":"16777230:9024311:1901:1762075211002000000",
   "kind":"text","mimeType":"text/plain"}}}
```

- `status`：`ready` / `missing`（被删）/ `error`。订阅失败时也回 `fs.file.subscribe.response`，`initial.status:"error"`，且订阅已释放（`files-session.ts:128-144`）。
- Host 端用 `fs.watch` 监视父目录，事件 50 ms 去抖后 re-stat；指纹（revision）不变不推；watch 出错退化为每 5 s 轮询（`packages/server/src/server/file-explorer/observer.ts:111-171`）。
- `kind`/`mimeType` 在 v0.13.0+ 的版本里才有；旧 Daemon 缺失时官方 App 改用一次读取的分类（`daemon-session.ts:33-52`）。
- 释放：`fs.file.unsubscribe.request {subscriptionId, requestId}` → `fs.file.unsubscribe.response`，或通用 `subscription.release.request`。
- 断线后需重新订阅；官方客户端把重连后的新 `initial` 当作一次 update 处理（`client.ts:5137-5159`）。

### 1.6 写文件：`fs.file.write.request`（需 `workspaceFileEditing`；base64 需 `fileByteWrites`）

请求（`messages.ts:2854-2864`）：

```json
{"type":"fs.file.write.request","requestId":"r30","cwd":"/Users/me/code/app","path":"README.md",
 "content":"# App\n\nHello\n","contentEncoding":"utf-8",
 "expectedModifiedAt":"2026-11-02T09:14:03.120Z",
 "expectedRevision":"16777230:9024311:1834:1762074843120000000"}
```

结果（`messages.ts:6117-6134`）三选一：

```json
{"type":"fs.file.write.response","payload":{"requestId":"r30","result":
  {"status":"written","modifiedAt":"2026-11-02T09:21:00.500Z","size":14,"revision":"16777230:9024311:14:1762075260500000000"}}}
```
```json
{"status":"conflict","version":{"status":"ready","cwd":"…","path":"README.md","size":1901,"modifiedAt":"…","revision":"…"}}
```
```json
{"status":"error","error":"File is too large to edit"}
```

语义（`service.ts:455-557`）：

- 只能覆盖**已存在**的文件（不存在 → `conflict` + `version.status:"missing"`）。新建文件用 `fs.entry.create`（§1.7）后再写。
- 上限 1 MiB（编码后字节与现有文件大小都受限，`service.ts:111,463-480`）；App 编辑器同样只对 ≤ 1 MiB 的文件开放编辑（`app/file-panels/source/panel.tsx:52,77`）。
- `contentEncoding:"utf-8"` 时，现有文件若是二进制则拒绝（`Binary files cannot be edited`）。
- 并发控制：有 `expectedRevision` 就比 revision，否则比 `expectedModifiedAt`（毫秒 ISO）。写临时文件 `.paseo-<uuid>.tmp` → fsync → 再校验一次 → rename 原子替换，保留原 mode。
- 旧 Daemon（无 `fileByteWrites`）会忽略 `contentEncoding`，把 base64 文本原样写进去——**发 base64 前必须检查开关**。

### 1.7 条目操作：`fs.entry.*`（需 `fsEntryOps` / `fsEntryDuplicate`）

请求（`messages.ts:2866-2895`）与响应（`messages.ts:6136-6181`）：

| 请求 | 字段 | 成功响应关键字段 |
| --- | --- | --- |
| `fs.entry.create.request` | `cwd, parentPath, name, kind:"file"\|"directory"` | `path`（新条目相对路径） |
| `fs.entry.rename.request` | `cwd, path, name`（新名字，不是新路径） | `renamedPath` |
| `fs.entry.duplicate.request` | `cwd, path` | `duplicatedPath`（`foo copy.ts`、`foo copy 2.ts`…） |
| `fs.entry.delete.request` | `cwd, path` | — |

```json
{"type":"fs.entry.rename.request","requestId":"r40","cwd":"/Users/me/code/app","path":"src/old.ts","name":"new.ts"}
{"type":"fs.entry.rename.response","payload":{"requestId":"r40","cwd":"/Users/me/code/app","path":"src/old.ts",
 "renamedPath":"src/new.ts","success":true,"error":null}}
```

规则（`service.ts:610-795`）：`name` 去空白后不能为空/`.`/`..`、不能含 `/` 或 `\`；同名已存在 → `"\"x\" already exists"`（大小写-only 重命名除外）；不能对工作区根做 rename/duplicate/delete；delete 对目录递归删除、对符号链接只删链接；rename 对 git 已跟踪文件用 `git mv`。所有错误都通过 `success:false` + `error` 字符串返回。官方 App 成功后重新列父目录（`app/hooks/use-file-explorer-actions.ts:227-260`），没有推送。

### 1.8 上传（composer 附件）：`file.upload.request` + 二进制帧

无功能开关。流程（`client.ts:5225-5308`，服务端 `packages/server/src/server/file-upload/index.ts`）：

1. 发 JSON：

```json
{"type":"file.upload.request","requestId":"u1","fileName":"crash.log","mimeType":"text/plain",
 "size":245760,"modifiedAt":"2026-11-03T10:00:00.000Z"}
```

2. **紧接着在同一连接**发二进制帧（帧里的 requestId 必须与 JSON 的 `requestId` 一致）：
   - `FileBegin`，metadata `{"mime":"text/plain","size":245760,"encoding":"binary","modifiedAt":"…","fileName":"crash.log"}`（Host 只用它作为「开始」信号，名字/大小以 JSON 请求为准）；
   - 若干 `FileChunk`（官方每块 128 KiB，`client.ts:5275`）；
   - `FileEnd`。
3. 收响应（`messages.ts:6230-6237`）：

```json
{"type":"file.upload.response","payload":{"requestId":"u1","error":null,
 "file":{"type":"uploaded_file","id":"upload_5f0c…","fileName":"crash.log","mimeType":"text/plain",
         "size":245760,"path":"/Users/me/.paseo/uploads/upload_5f0c…/crash.log"}}}
```

4. 把 `file` 原样放进 `send_agent_message_request.attachments`（02 §5.1）。

服务端约束：累计字节超过声明 `size` → 失败；FileEnd 时字节数不等 → `Upload size mismatch`；FileBegin 之前到的 Chunk → 失败；10 分钟无帧 → 静默取消（响应永远不来，客户端需自带超时）；文件名会被消毒（控制字符与 `\/:*?"<>|` → `_`，≤ 255 字节）。客户端侧限制 50 MiB（`app/attachments/upload-limit.ts:2`），服务端无上限。需要 `workspace.write`。

**未确认**：Host 是否保证在处理完 JSON `file.upload.request`（注册 pending upload）之后才处理随后到达的二进制帧；官方客户端依赖这一顺序（不等响应就发帧），未注册时到达的帧会被丢弃（`file-upload/index.ts:80-83`）。Swift 实现应与官方一致：同一连接、严格按序发送。

---

## 2. Git / checkout（Changes 面板）

### 2.1 状态：`checkout_status_request`

```json
{"type":"checkout_status_request","requestId":"g1","cwd":"/Users/me/code/app"}
```

响应是三种形状之一（`messages.ts:5312-5376`）：

```json
{"type":"checkout_status_response","payload":{
  "requestId":"g1","cwd":"/Users/me/code/app","error":null,
  "isGit":true,"isPaseoOwnedWorktree":true,
  "repoRoot":"/Users/me/.paseo/worktrees/app/feat-auth","mainRepoRoot":"/Users/me/code/app",
  "currentBranch":"feat/auth","isDirty":true,"baseRef":"main",
  "aheadBehind":{"ahead":3,"behind":1},
  "aheadOfOrigin":1,"behindOfOrigin":0,"upstreamRef":"refs/remotes/origin/feat/auth",
  "hasRemote":true,"remoteUrl":"git@github.com:me/app.git"}}
```

- `isGit:false` 时 repoRoot/currentBranch/isDirty/baseRef/aheadBehind… 均为 `null`。
- `aheadBehind` 是相对 **baseRef**（PR 目标分支）的；`aheadOfOrigin/behindOfOrigin` 是相对 `upstreamRef`（上游跟踪分支）的。`upstreamRef` 要原样使用，不要自己拼 `origin/<branch>`（`messages.ts:5316-5321`）。
- `currentBranch:null` = detached HEAD。
- `error.code` ∈ `NOT_GIT_REPO | NOT_ALLOWED | MERGE_CONFLICT | UNKNOWN`（`messages.ts:2214-2224`）。
- **状态里没有文件列表**。「哪些文件变了」来自 diff（§2.3）；workspace 描述符上也有轻量的 `gitRuntime` 和 `diffStat {additions,deletions}`（`messages.ts:4044-4061,4161-4167`，02 §2.3），列表页显示用它就够。

### 2.2 状态推送：`checkout_status_update`（必须显式订阅事件）

modern 模式下，只有在 `session.events.set_subscription.request` 的 `events` 里包含 `"checkout_status_update"` 才会推送（`packages/server/src/server/session/owned-subscriptions/replies.ts:37-38`，`session.ts:1459-1468,6724-6736`）。订阅后 Host 会对所有活跃工作区建立 git 观察，任一变化推送：

```json
{"type":"checkout_status_update","payload":{
  "subscriptionId":"ev-1","requestId":"subscription:/Users/me/code/app","cwd":"/Users/me/code/app",
  "error":null,"isGit":true,"isPaseoOwnedWorktree":false,"repoRoot":"/Users/me/code/app","mainRepoRoot":null,
  "currentBranch":"main","isDirty":false,"baseRef":"main","aheadBehind":{"ahead":0,"behind":0},
  "aheadOfOrigin":0,"behindOfOrigin":0,"upstreamRef":"refs/remotes/origin/main",
  "hasRemote":true,"remoteUrl":"git@github.com:me/app.git",
  "prStatus":{"cwd":"/Users/me/code/app","status":null,"githubFeaturesEnabled":true,
              "authState":"authenticated","forge":"github","error":null,
              "requestId":"subscription:/Users/me/code/app"}}}
```

- 形状 = 状态响应 + 可选 `prStatus`（与 §2.6 的 `checkout_pr_status_response.payload` 同形，`messages.ts:5489-5517`）。
- `requestId` 形如 `subscription:<cwd>`，**不是**请求关联；按 `cwd` 路由。
- Host 对每个 cwd 做指纹去重，只在内容变化时推（`checkout-session.ts:519-547`）。
- 官方 App 订阅了它（02 §1.4）。

### 2.3 Diff：订阅 / 一次性读取

比较模式 `compare`（`messages.ts:2226-2230`，解析 `packages/server/src/utils/checkout-git.ts:3498-3521`）：

| mode | 比较对象 | 含未跟踪文件 |
| --- | --- | --- |
| `uncommitted` | 工作区 vs `HEAD`（= 未提交的改动） | 是 |
| `base` | `merge-base(baseRef, HEAD)` vs `HEAD`（= 本分支已提交的改动） | 否 |
| `all` | `merge-base(baseRef, HEAD)` vs 工作区（已提交 + 未提交，需 `checkoutDiffAll`） | 是 |

`baseRef` 省略时用工作区存储的/自动推断的基线分支；`base`/`all` 推不出基线时返回空列表。`ignoreWhitespace:true` 忽略空白差异。官方 App 的 Changes 面板只提供 `uncommitted` 与 `base`（`app/panels/changes/state.ts:6`），默认 `uncommitted`（**未确认**默认值出处，推断自 `app/git/use-working-diff.ts:56`）。客户端发送前会把空 `baseRef` 去掉（`client.ts:4436-4454`）。

**订阅（推荐，Changes 面板用）**：

```json
{"type":"subscribe_checkout_diff_request","requestId":"d1","cwd":"/Users/me/code/app",
 "compare":{"mode":"uncommitted"}}
```

响应 `subscribe_checkout_diff_response`（含首个快照），之后每次变化推 `checkout_diff_update`（**整份**新快照，不是增量）（`messages.ts:5519-5546`，`checkout-session.ts:425-476`）：

```json
{"type":"checkout_diff_update","payload":{"subscriptionId":"9a1e…","cwd":"/Users/me/code/app","error":null,
 "files":[
  {"path":"src/auth.ts","isNew":false,"isDeleted":false,"additions":2,"deletions":1,"status":"ok",
   "hunks":[{"oldStart":10,"oldCount":4,"newStart":10,"newCount":5,"lines":[
     {"type":"header","content":"@@ -10,4 +10,5 @@"},
     {"type":"context","content":"export function login(user: User) {",
      "tokens":[{"text":"export","style":"keyword"},{"text":" ","style":null},{"text":"function","style":"keyword"}]},
     {"type":"remove","content":"  return token;"},
     {"type":"add","content":"  audit(user);"},
     {"type":"add","content":"  return token;"},
     {"type":"context","content":"}"}]}]},
  {"path":"src/new-file.ts","isNew":true,"isDeleted":false,"additions":12,"deletions":0,"status":"ok","hunks":[…]},
  {"path":"src/renamed.ts","oldPath":"src/old-name.ts","isNew":false,"isDeleted":false,"additions":0,"deletions":0,"status":"ok","hunks":[]},
  {"path":"assets/logo.png","isNew":false,"isDeleted":false,"additions":0,"deletions":0,"status":"binary","hunks":[]}
 ]}}
```

释放：`unsubscribe_checkout_diff_request {subscriptionId}` 或 `subscription.release.request`。Host 在提交/拉取/丢弃等操作后会主动刷新所有订阅（`checkout-session.ts:549-551`）。

**一次性读取**：`checkout.diff.get.request {cwd, compare}` → `checkout.diff.get.response`，payload 同上但无 `subscriptionId`（`messages.ts:2246-2251,5536-5541`）。

**单文件 diff 格式**（`ParsedDiffFileSchema`，`messages.ts:2754-2778`）：**结构化 hunk，不是 unified 文本**。

- `lines[].type`：`header`（每个 hunk 的第一行，`content` 为 `@@ -a,b +c,d @@`）、`context`、`add`、`remove`。`content` **不含** `+`/`-`/空格前缀（`packages/server/src/server/utils/diff-highlighter.ts:104-156`）。`\ No newline at end of file` 行被丢弃。
- 行号需客户端自己数：从 hunk 的 `oldStart`/`newStart` 起，`context` 两边都 +1，`remove` 只旧 +1，`add` 只新 +1。
- `tokens`（可选）是服务端语法高亮结果：按顺序拼接 `text` 等于 `content`；`style` 是高亮类名（可能是 `"heading meta"` 这样的复合类名，`messages.ts:2746-2752`）或 `null`。v1 可忽略 tokens 直接渲染纯文本。**未确认**：style 名称全集（来自 lezer 高亮器）。
- `status`：`ok` / `binary`（无 hunks）/ `too_large`（单文件 diff > 1 MiB，无 hunks）。
- 「状态字母」需自己推：`isNew` → A，`isDeleted` → D，有 `oldPath` → R，否则 M。未跟踪文件表现为 `isNew:true`。协议里没有 git porcelain 的 XY 码。
- `files` 已按 `path` 字典序排序（`packages/server/src/server/checkout-diff-manager.ts:280-284`）。
- 整体过大（结构化 JSON 超出 relay 帧预算，约 32 MiB − 1 MiB）时：`files:[]`、`diffTooLarge:true`、`error:{code:"UNKNOWN",message:"Diff too large to display"}`（`checkout-diff-manager.ts:272-278`，`checkout-git.ts:2180-2188`）。UI 应显示「改动太大」而不是「无改动」。

### 2.4 操作：官方 App 提供的动作

全部是简单请求 → `{cwd, success, error}` 响应（`messages.ts:2259-2306,5549-5662`），App 把 `error.message` 弹 toast（`app/git/actions-store.ts:185-390`）：

| 动作 | 请求 | 说明 |
| --- | --- | --- |
| 提交 | `checkout_commit_request {cwd, message?, addAll?}` | App 发 `{addAll:true}` **不带 message**：Host 用 AI 自动生成提交信息（`checkout-session.ts:742-783`）。`addAll` 默认 true（`git add -A`）。v1 建议让用户输入 message |
| 拉取 | `checkout_pull_request {cwd}` | 当前分支 pull |
| 推送 | `checkout_push_request {cwd}` | 当前分支 push |
| 同步 | 先 pull 再 push（客户端串行） | — |
| 刷新 | `checkout.refresh.request {cwd}`（需 `checkoutRefresh`） | 强制重算 git 快照 + forge 状态，触发 diff 刷新 |
| 丢弃 | `checkout.discard_changes.request {cwd, paths:[…]}`（≥1 个路径，需 `checkoutDiscardChanges`） | 已跟踪 → `git checkout`，未跟踪 → `git clean -fd`（**不可恢复**，`checkout-git.ts:3730-3784`） |
| 合并到基线 / 从基线合并 | `checkout_merge_request` / `checkout_merge_from_base_request` | `MERGE_CONFLICT` 错误码 |
| 建 PR / 合并 PR / 自动合并 | `checkout_pr_create_request`、`checkout_pr_merge_request {mergeMethod}`、`checkout.forge.set_auto_merge.request` | v1 可后做 |
| 其它 | 切分支、重命名分支、stash、提交列表 `checkout.commits.list`、单提交单文件 diff `checkout.commits.file_diff` | v1 可后做 |

```json
{"type":"checkout_commit_request","requestId":"c1","cwd":"/Users/me/code/app","message":"Fix login audit","addAll":true}
{"type":"checkout_commit_response","payload":{"requestId":"c1","cwd":"/Users/me/code/app","success":true,"error":null}}
```

### 2.5 PR 状态

两个来源：

1. **workspace 描述符的 `githubRuntime`**（字段名历史遗留，内容 forge 中立，`messages.ts:4063-4108`）：`pullRequest {number,url,title,state,isMerged,isDraft,mergeable,checks[],checksStatus,reviewDecision,…}`、`featuresEnabled`、`error`、`refreshedAt`。随 workspace 推送更新，v1 显示 PR 徽标用它即可。
2. **`checkout_pr_status_request {cwd}`** → `checkout_pr_status_response`（`messages.ts:2411-2415,5792`，payload `messages.ts:5489-5503`）：`status`（`CheckoutPrStatusSchema`，`messages.ts:5431-5475`，含 `checks[].status` 字符串、`github.mergeStateStatus` 等）、`authState` ∈ `authenticated|unauthenticated|cli_missing|no_remote|error`、`forge`。也会随 `checkout_status_update.prStatus` 推送。

```json
{"type":"checkout_pr_status_response","payload":{"requestId":"p1","cwd":"/Users/me/code/app",
 "githubFeaturesEnabled":true,"authState":"authenticated","forge":"github","error":null,
 "status":{"forge":"github","number":42,"url":"https://github.com/me/app/pull/42","title":"Add login audit",
   "state":"OPEN","baseRefName":"main","headRefName":"feat/auth","isMerged":false,"isDraft":false,
   "mergeable":"MERGEABLE","checksStatus":"pending","reviewDecision":null,"repoOwner":"me","repoName":"app",
   "checks":[{"name":"ci / test","status":"pending","url":"https://github.com/…","workflow":"ci","duration":"2m"}]}}}
```

PR 时间线（评论/review）`pull_request_timeline_request` 和 CI 详情 `checkout.forge.get_check_details.request` 留给后续版本。

### 2.6 v1 「Changes 列表 + 单文件 diff」最少需要

1. 事件订阅里加 `checkout_status_update`（分支/ahead/behind/dirty 实时）。
2. 打开 Changes 时 `subscribe_checkout_diff_request {mode:"uncommitted"}`，`files` 就是列表（路径、A/M/D/R、+/-），点击某项直接用同一份数据里的 `hunks` 渲染——**不需要再请求单文件 diff**。
3. 关闭面板时 release。

---

## 3. 终端

### 3.1 列表与订阅列表

**一次性列表**（`messages.ts:2992-2997,6527-6534`）：

```json
{"type":"list_terminals_request","requestId":"t1","cwd":"/Users/me/code/app","workspaceId":"ws_123"}
{"type":"list_terminals_response","payload":{"requestId":"t1","cwd":"/Users/me/code/app","terminals":[
  {"id":"term_ab12","name":"Terminal 1","cwd":"/Users/me/code/app","workspaceId":"ws_123","title":"zsh",
   "activity":{"state":"idle","attentionReason":null,"changedAt":1762160000000}},
  {"id":"term_cd34","name":"dev","cwd":"/Users/me/code/app","workspaceId":"ws_123","title":"dev","activity":null}]}}
```

- 带 `workspaceId` 时按归属工作区过滤（`cwd` 不再限制）；只带 `cwd` 时返回该工作区根下的终端；都不带返回全部（`tsc.ts:416-460`）。终端只对**创建它的** workspace 可见（`docs/terminal-activity.md`）。v1 一律带 `workspaceId`。
- `activity`（`packages/protocol/src/terminal-activity.ts:9-16`）：`state` ∈ `idle|working|attention`（未知值降级为 `idle`），`attentionReason` ∈ `finished|needs_input|null`，`changedAt` 为毫秒时间戳；`null` = 未知。Tab 指示点：`needs_input` → 需输入，`finished` → 完成待看，`working` → 运行中（`terminal-activity.ts:23-31`）。
- 脚本也跑在终端里（§4），列表里包含脚本终端；官方 App 用 `workspace.scripts[].terminalId` 把它们与普通终端区分开（`app/screens/workspace/terminals/use-workspace-terminals.ts:118-129`）。

**订阅列表**（官方 App 用这个）：

```json
{"type":"subscribe_terminals_request","requestId":"t2","cwd":"/Users/me/code/app","workspaceId":"ws_123"}
```

注意**没有 `subscribe_terminals_response`**：首个回包就是带 `requestId` 的 `terminals_changed`，之后每次变化（新建/退出/标题/activity 变化）推送不带 `requestId` 的 `terminals_changed`，`terminals` 是**全量**列表（元素无 `cwd`）（`messages.ts:6536-6545`，`tsc.ts:344-414`，`replies.ts:33`）：

```json
{"type":"terminals_changed","payload":{"subscriptionId":"5b7f…","requestId":"t2","cwd":"/Users/me/code/app",
 "workspaceId":"ws_123","terminals":[{"id":"term_ab12","name":"Terminal 1","workspaceId":"ws_123","title":"zsh","activity":null}]}}
```

modern 模式必须带 `requestId`（否则 owned subscription 抛错）。释放用 `subscription.release.request`（`unsubscribe_terminals_request` 在 modern 下会抛错，`owned-subscriptions/index.ts:386-395`）。

### 3.2 创建、改名、关闭

```json
{"type":"create_terminal_request","requestId":"t3","cwd":"/Users/me/code/app","workspaceId":"ws_123"}
{"type":"create_terminal_response","payload":{"requestId":"t3","error":null,
 "terminal":{"id":"term_ef56","name":"Terminal 2","cwd":"/Users/me/code/app","workspaceId":"ws_123","activity":null}}}
```

字段（`messages.ts:3012-3031`）：`cwd`（进程工作目录）、`workspaceId`（v0.14 必需：缺省时尝试按 cwd 反查，查不到报 `workspaceId is required`；workspace 不活跃报错，`tsc.ts:530-600`）、`name?`、`command?`+`args?`（不给就是用户默认 shell）、`size?`（初始 PTY 尺寸，官方 App 不再发送；不发则 80×24，由首次 resize 修正）、`agentId`（已废弃，带了直接报错）。失败（例如 profile 命令不存在）→ `terminal:null, error:"…"`。

**终端 profile**：Host 配置 `terminalProfiles[] {id,name,command,args?,icon?}`（`packages/protocol/src/terminal-profile.ts`，存于 daemon config，`messages.ts:241`，用 `get_daemon_config_request` 读取）。`args`/`command` 里的 `{{{prompt}}}` 是占位符，由**客户端**替换后再发 `create_terminal_request{name:profile.name, command, args}`；没有 prompt 时整项为 `{{{prompt}}}` 或 `--x={{{prompt}}}` 的参数要丢弃（`packages/protocol/src/terminal-profiles.ts:12-30,64-100`，App 用法 `use-workspace-terminals.ts:131-153`）。内置默认 profile：claude / codex / opencode / pi。**未确认**：config 未设置 `terminalProfiles` 时 App 是否回退到 `DEFAULT_TERMINAL_PROFILES`。

改名：`terminal.rename.request {terminalId, title}`（trim 后 1..200 字符）→ `terminal.rename.response {success, error}`。

关闭：`kill_terminal_request {terminalId}` → `kill_terminal_response {terminalId, success}`（Host 先给正在观察的流发 `terminal_stream_exit`，再杀进程并等待退出，`tsc.ts:772-790`）。批量关闭也可用 `close_items_request {terminalIds:[…]}`。

纯文本抓取（不依赖仿真器，适合预览/复制）：`capture_terminal_request {terminalId, start?, end?, stripAnsi:true}` → `capture_terminal_response {lines[], totalLines}`（`messages.ts:3119-3126,6592-6600`）。

### 3.3 附着（attach）流：`subscribe_terminal_request`

```json
{"type":"subscribe_terminal_request","requestId":"t4","terminalId":"term_ab12",
 "restore":{"mode":"visible-snapshot","scrollbackLines":200}}
```

成功（`messages.ts:6565-6582`）：

```json
{"type":"subscribe_terminal_response","payload":{"requestId":"t4","terminalId":"term_ab12","slot":7,
 "subscriptionId":"c0ffee…","error":null}}
```

失败：`{"terminalId":"…","error":"Terminal not found"|"No terminal stream slots available"|"Terminal manager not available","requestId":"t4"}`（无 slot）。

**slot 分配**（`tsc.ts:44,1132-1143`）：每个 Host session 0..255 循环分配，跳过占用中的；一个 slot 对应一个附着流。之后该终端的所有二进制帧第 2 字节都是这个 slot。客户端按 `slot → terminalId` 路由；**收到 response 前到达的同 slot 帧应丢弃**（官方路由器无注册即丢，`packages/client/src/terminal-stream-router.ts:53-56`；Host 先发 response 再发首帧）。断线重连后所有 slot 失效，要清空映射并重新订阅（`client.ts:1666,7021`）。

同一终端可被多个客户端/多个 Tab 同时附着，各得一个 slot。

**脱离（detach）**：`subscription.release.request {subscriptionId}`（modern；`unsubscribe_terminal_request` 只适用于 legacy）。终端进程不受影响。

**流结束**：`terminal_stream_exit`（`messages.ts:6602-6610`）

```json
{"type":"terminal_stream_exit","payload":{"subscriptionId":"c0ffee…","terminalId":"term_ab12"}}
{"type":"terminal_stream_exit","payload":{"subscriptionId":"c0ffee…","terminalId":"term_ab12","error":"Unable to read terminal snapshot"}}
```

无 `error` = PTY 已退出（Host 会先把残余输出冲刷完再发它，`tsc.ts:1159-1176`）；有 `error` = 观察失败，进程可能还活着（可重新订阅）。两种情况下该 slot 都已释放。

### 3.4 终端二进制帧布局（0x01–0x05）

`bf/terminal.ts:10-89`：

```
[0] u8 opcode   0x01 Output | 0x02 Input | 0x03 Resize | 0x04 Snapshot | 0x05 Restore
[1] u8 slot     subscribe_terminal_response.slot
[2..] payload   （可为空）
```

| opcode | 方向 | payload |
| --- | --- | --- |
| `0x01` Output | Host → 客户端 | PTY 原始输出，UTF-8 字节（来自 JS 字符串重编码，每帧都是完整 UTF-8 序列）。Host 以 5 ms 首尾节流合并（`packages/server/src/terminal/terminal-output-coalescer.ts:19-62`）。**直接喂给 SwiftTerm** |
| `0x02` Input | 客户端 → Host | 用户输入字节；Host 按 UTF-8 解码后写入 PTY，空 payload 忽略（`tsc.ts:249-259`） |
| `0x03` Resize | 客户端 → Host | UTF-8 JSON：`{"rows":40,"cols":120,"intent":"update"}`（`bf/terminal.ts:4-8`）；`intent` 可省略（视为 `claim`） |
| `0x04` Snapshot | Host → 客户端 | UTF-8 JSON 的 `TerminalState`（`messages.ts:6511-6525`）：`rows, cols, grid[][], scrollback[][], cursor{row,col,hidden?,style?,blink?}, title?, gridWrapped?, scrollbackWrapped?`，cell = `{char, fg?, bg?, fgMode?, bgMode?, bold?, italic?, underline?, dim?, inverse?, strikethrough?}` |
| `0x05` Restore | Host → 客户端 | **ANSI 字节流**：服务端把快照渲染成转义序列（`packages/protocol/src/terminal-snapshot.ts:29-62`）。**直接喂给 SwiftTerm**（先 reset，见 §3.5） |

入站帧只对**该 slot 的拥有者 socket** 生效，否则静默丢弃（`tsc.ts:237-241`）；还需 `workspace.write` 权限。

示例：

```
01 07 1B 5B 33 32 6D 6F 6B 1B 5B 30 6D 0D 0A           Output slot 7: ESC[32mok ESC[0m \r\n
02 07 6C 73 0D                                         Input  slot 7: "ls\r"
03 07 7B 22 72 6F 77 73 22 3A 34 30 2C …               Resize slot 7: {"rows":40,"cols":120,"intent":"update"}
```

**输入/resize 的 JSON 等价物**：`terminal_input`（`messages.ts:3090-3111`），按 `terminalId` 寻址，不需要 slot、不需要先 attach：

```json
{"type":"terminal_input","terminalId":"term_ab12","message":{"type":"input","data":"ls\r"}}
{"type":"terminal_input","terminalId":"term_ab12","message":{"type":"resize","rows":40,"cols":120,"intent":"claim"}}
{"type":"terminal_input","terminalId":"term_ab12","message":{"type":"mouse","row":3,"col":10,"button":0,"action":"down"}}
```

**官方 App 的输入与 resize 全部走 JSON `terminal_input`，不用 0x02/0x03 帧**（`app/components/terminal-pane.tsx:715-740,940-960`，`app/terminal/runtime/terminal-stream-controller.ts:77-83`）。两条路径在 Host 端效果相同（同一个 `applyTerminalSize` / `session.send`）。v1 建议也用 JSON，原因：不依赖 slot 时序、attach 前就能 claim 尺寸、与官方行为一致。二进制 Input 帧可作为后续优化（省 JSON 开销）。注意两条路径都是**按 UTF-8 解码**再写 PTY，非 UTF-8 的单字节（例如 8-bit Meta）会被替换——SwiftTerm 默认发送的都是 UTF-8/ESC 序列，不受影响。

### 3.5 首屏：快照 / 恢复语义

`subscribe_terminal_request.restore` 决定附着后先收到什么（`packages/server/src/terminal/terminal-restore.ts:19-82`，`tsc.ts:973-1130`）：

| `restore` | 首帧 | 内容 |
| --- | --- | --- |
| 省略（legacy / 无 `terminal-restore-modes`） | `0x04` Snapshot | JSON 全量 `TerminalState`（含全部 scrollback） |
| `{"mode":"visible-snapshot","scrollbackLines":N}` | `0x05` Restore | 可见屏 + 最近 N 行 scrollback 的 ANSI。N 默认 200，上限 500 |
| `{"mode":"full-snapshot"}` | `0x05` Restore | 可见屏 + 全部 scrollback 的 ANSI |
| `{"mode":"live"}` | 无快照帧 | 只收之后的新输出 |

之后的流程（三种 restore 模式通用）：快照帧之后 Host 先回放**输入模式前导序列**（§3.6），再回放快照期间缓冲的输出（按 revision 去重，不会重复），然后进入实时 Output 帧（`tsc.ts:1106-1130`）。

**Restore 帧随时可能再来**：当某客户端积压（输出 > 256 KiB 且发送缓冲 > 4 MiB；relay 连接无法测缓冲时只看前者），Host 丢弃积压改发一个新的 Restore（`live` 模式此时自动升级为 `visible-snapshot`）（`tsc.ts:895-920`，`docs/terminal-performance.md:26`）。所以 Restore/Snapshot 处理器必须是「随时重置并重绘」，不能只在附着时生效。

Restore 的 ANSI 内容（`terminal-snapshot.ts:29-62`）：逐行输出 scrollback+grid（SGR 着色，宽字符续格跳过），行间 `\r\n`；末尾 `ESC[0m`、可选光标形状 `ESC[n q`、光标定位 `ESC[r;cH`、`ESC[?25h/l`。它**不包含清屏**——客户端必须先重置。官方做法：在 Restore 数据前拼上 `ESC c`（RIS），并在写入期间**屏蔽仿真器产生的回应字节**（`app/terminal/runtime/terminal-emulator-runtime.ts:163,914-929,702-707`）。

**可重排快照（reflow）**：hello 里声明 `terminal_reflowable_snapshot: true` 后，快照带 `gridWrapped/scrollbackWrapped`，Restore 渲染会把软换行的逻辑行连续输出（autowrap 开），让仿真器把续行标记为 wrapped，以后改列宽能正确重排；不声明则每行硬换行（`ESC[?7l … ESC[?7h`），改宽后旧内容不重排（`terminal-snapshot.ts:30-60`，`packages/protocol/src/client-capabilities.ts:19-24`）。**本文建议 v1 发送该能力**——这修正 02 §1.2「不发」的建议：用 Restore 路径时客户端不解析 JSON，额外字段无副作用，只带来更好的重排。

**SwiftTerm 对接**：

- Output / Restore payload → `terminalView.feed(byteArray: ArraySlice(payload))`。
- Restore 前：`terminal.resetToInitialState()`（或 feed `ESC c`），并在 feed 期间让 `TerminalViewDelegate.send(source:data:)` 丢弃输出（设一个 `suppressInput` 标志，feed 完同步清除）。
- Snapshot（JSON，仅当 Host 不支持 restore 模式时）：照 `renderTerminalSnapshotToAnsi` 把 `TerminalState` 转成 ANSI 再按 Restore 处理（该函数 ~200 行，可直接移植；颜色：`fgMode` 1=16 色（≥8 用亮色 90/100 段）、2=256 色、3=24 位 RGB `value` 打包为 `0xRRGGBB`，`terminal-snapshot.ts:201-224`）。v0.14 Daemon 都支持 restore，v1 可以不做 Snapshot。
- **未确认**：快照是否保留备用屏（alternate screen）、鼠标跟踪等模式；Restore ANSI 中只恢复了 SGR/光标/autowrap，全屏 TUI（vim/htop）恢复后可能需要一次 resize 触发重绘（附着时官方总会发一次 resize claim，见 §3.7，这通常会让 TUI 收到 SIGWINCH 重绘——前提是尺寸确有变化）。

### 3.6 输入模式（terminal-input-mode-replay）

Host 跟踪 PTY 输出里的输入模式开关，附着时（快照之后）把当前状态作为前导序列回放（`packages/protocol/src/terminal-input-mode.ts:148-163`，`tsc.ts:1110-1114`）：

| 模式 | 序列 |
| --- | --- |
| kitty 键盘协议 flags>0 | `ESC[=<flags>;1u` |
| win32-input-mode | `ESC[?9001h` |
| 应用光标键 DECCKM | `ESC[?1h` |
| 括号粘贴 | `ESC[?2004h` |

这样新附着的仿真器能和 PTY 里程序的期望一致（例如 Claude Code 依赖 kitty 键盘协议区分 Shift+Enter）。对 SwiftTerm：DECCKM 与 bracketed paste 会被自动吸收并影响其按键编码；kitty 键盘协议与 win32-input-mode **SwiftTerm 不支持**（**未确认** SwiftTerm 当前版本），这意味着 Shift+Enter 等修饰键组合无法按 kitty 编码发送——官方 App 自己维护一份 `TerminalInputModeTracker` 并按它编码按键（`app/components/terminal-pane.tsx:381,729-737`，`app/terminal/runtime/terminal-key-dispatch.ts`）。v1 可先接受该限制，后续可移植 `terminal-input-mode.ts` + key dispatch。

### 3.7 尺寸归属（terminal-size-ownership）

一个 PTY 只有一个尺寸，多个客户端同时看时由「拥有者」决定（`packages/server/src/terminal/terminal-size-ownership.ts:11-38`，`docs/terminal-performance.md:31`）：

- `intent:"claim"`：成为拥有者并应用尺寸（尺寸未变也会转移所有权）。缺省 intent 视为 claim（兼容旧客户端）。
- `intent:"update"`：只有当前拥有者的 update 会生效，其他连接的 update 被忽略。
- 拥有者按**连接（socket）**记，弱引用。

官方 App 策略：Tab 获得焦点/用户直接交互（键入、点按）时发 `claim`；之后同一 Tab 因分屏、键盘弹出等引起的尺寸变化发 `update`（`app/terminal/native-renderer/terminal-input-resize-policy.ts`，`terminal-pane.tsx:930-960`）。附着前先发一次 claim（`terminal-stream-controller.ts:77-83`）。

**modern 模式下 `restore.size` 被忽略**（只在 legacy 源上用于 claim，`tsc.ts:703-708`），所以必须用 `terminal_input` resize 单独 claim。

SwiftTerm：在 `sizeChanged(source:newCols:newRows:)` 里发 `update`；在 Tab 出现/成为第一响应者/用户输入时发 `claim`（带当前 cols/rows）。

### 3.8 terminal_attention_required 与焦点

需在事件订阅里包含 `"terminal_attention_required"`（modern）。当终端 activity 从 working → idle（`finished`）或进入需输入（`needs_input`）时推送（`ws-server.ts:2884-2970`）：

```json
{"type":"terminal_attention_required","payload":{"subscriptionId":"ev-1","serverId":"srv_1",
 "terminalId":"term_ab12","cwd":"/Users/me/code/app","workspaceId":"ws_123",
 "reason":"finished","title":"Terminal finished","body":"Terminal 1","shouldNotify":true}}
```

- `shouldNotify` 的含义同 agent attention（02 §7/§8）：只有一个客户端会拿到 `true`，由它弹应用内通知；需要事件订阅时带 `notifications:true` 才参与这个选择。
- activity 来源是终端里 agent CLI 的 hook（Claude/Codex/OpenCode），普通 shell 命令不会产生（`docs/terminal-activity.md`）。
- **清除 attention**：没有专门 RPC；发 `client_heartbeat` 且 `appVisible:true`、`focusedTerminalId:"<id>"` 时 Host 清掉该终端的 attention（`session.ts:5017-5035`）。所以终端 Tab 处于前台时，心跳里要带 `focusedTerminalId`（02 §8.2），否则指示点不会消失。

### 3.9 hello 能力与事件订阅（终端/文件/Git 相关增量）

在 02 §1.2 的基础上：

```json
"capabilities": { "...02 建议的全部...": true, "terminal_reflowable_snapshot": true }
```

事件订阅（与 02 §1.4 合并为一次或分多次 `session.events.set_subscription.request` 均可）：

```json
{"type":"session.events.set_subscription.request","requestId":"e1",
 "events":["checkout_status_update","script_status_update","terminal_attention_required", "...其他..."],
 "notifications":true}
```

终端不需要其他客户端能力；`terminal-restore-modes` 等是**服务端** `server_info.features`，不是 hello 能力。

---

## 4. 工作区脚本

### 4.1 数据模型

脚本来自仓库根 `paseo.json` 的 `scripts`（`packages/protocol/src/paseo-config-schema.ts:38-44,74-79`），例如 `{"scripts":{"dev":{"type":"service","command":"npm run dev","port":3000},"test":{"command":"npm test"}}}`。每个脚本运行在一个 Host 终端里（命令被键入 shell，`packages/server/src/server/worktree-bootstrap.ts:665-668`）。

`WorkspaceScriptPayload`（`messages.ts:4031-4043`）：

```json
{"scriptName":"dev","type":"service","hostname":"dev--feat-auth--app.localhost","port":41237,
 "localProxyUrl":"http://dev--feat-auth--app.localhost:6767","publicProxyUrl":null,
 "proxyUrl":"http://dev--feat-auth--app.localhost:6767",
 "lifecycle":"running","health":"healthy","exitCode":null,"terminalId":"term_9z8y"}
```

- `type`：`service`（长期服务，分配端口并经 service proxy 暴露，`docs/service-proxy.md`）或 `script`（一次性命令，`hostname` = 脚本名，`port`/`proxyUrl` 为 null）。
- `lifecycle`：`running` / `stopped`；`health`：`healthy` / `unhealthy` / `null`（仅 service 有健康检查）；`exitCode`：停止后的退出码。
- `terminalId`：承载该脚本的终端，**「日志」就是附着这个终端**（§3.3）。没有单独的日志 RPC。`script` 类型命令结束后 shell 仍在，终端保留可看输出、再次启动会复用（`worktree-bootstrap.ts:513-516,654-659`）；`stop` 会杀掉终端。
- 同一份数组也在 workspace 描述符 `scripts` 字段里（02 §2.3）。
- `proxyUrl` 指向 Host 本机的 `.localhost` 域名，手机上一般不可直达（**未确认** v1 是否展示）。

### 4.2 RPC（需 `workspaceScriptManagement`）

| 请求 | 响应 payload（`messages.ts:4645-4667`） |
| --- | --- |
| `workspace.script.list.request {workspaceId}` | `{workspaceId, scripts:[…], error}` |
| `workspace.script.start.request {workspaceId, scriptName}` | `{workspaceId, scriptName, script, error}` |
| `workspace.script.stop.request {workspaceId, scriptName}` | `{workspaceId, scriptName, script, error}` |

```json
{"type":"workspace.script.start.request","requestId":"s1","workspaceId":"ws_123","scriptName":"dev"}
{"type":"workspace.script.start.response","payload":{"requestId":"s1","workspaceId":"ws_123","scriptName":"dev",
 "script":{"scriptName":"dev","type":"service","lifecycle":"running","terminalId":"term_9z8y","…":"…"},"error":null}}
```

错误示例：`"Script 'x' is not configured in paseo.json"`、`"Script 'dev' is not running"`（stop 一个未运行的脚本）、`"Workspace scripts are not available on this daemon"`；工作区处于自动化被阻止状态时 start 会被拒（`assertAutomationAllowed`）（`packages/server/src/server/session/workspace-scripts/workspace-scripts-service.ts:155-242`，`session.ts:7273-7360`）。

旧接口 `start_workspace_script_request {workspaceId, scriptName}` → `start_workspace_script_response {workspaceId, scriptName, terminalId, error}`（`messages.ts:3041-3046,4634-4643`）仍可用，v1 用新接口。

### 4.3 状态推送：`script_status_update`

需事件订阅 `"script_status_update"`。任一脚本生命周期变化时，Host 向**所有**订阅了该事件的客户端推该工作区的完整脚本数组（`workspace-scripts-service.ts:133-145`，`ws-server.ts:1045-1049`）：

```json
{"type":"script_status_update","payload":{"subscriptionId":"ev-2","workspaceId":"ws_123","scripts":[{"scriptName":"dev","lifecycle":"stopped","exitCode":130,"terminalId":"term_9z8y","…":"…"}]}}
```

官方 App 单独建一个只含 `script_status_update` 的事件订阅，订阅就绪后对关心的每个 workspace 调一次 `workspace.script.list.request` 补齐订阅前的变化（`app/runtime/directory-sync/index.ts:233-345`）。

---

## 5. 最小实现清单（按顺序）

### 5.1 文件浏览器

1. 读取 `server_info.features`，记下 `fsEntryOps`/`fsEntryDuplicate`。
2. 打开时 `file_explorer_request{mode:"list", path:"."}`；以响应 `directory.path` 为键缓存。
3. 展开目录时按需列该目录；本地排序（目录在前 + name/mtime/size），本地过滤 `.` 开头条目（开关）。
4. 下拉刷新 = 重列根 + 所有已展开目录（无推送）。
5. 错误：`error` 非 null 时显示在该节点上。
6. （可后做）新建/重命名/复制/删除：`fs.entry.*`，成功后重列父目录。
7. （可后做）下载：`file_download_token_request` 拿 size → 二进制读（`maxBytes` 64 MiB）→ 分享面板。

### 5.2 文件查看器

1. 实现二进制帧解码器 0x10/0x11/0x12（§1.3），按 `requestId` 聚合，校验 size。
2. 读：`file_explorer_request{mode:"file", acceptBinary:true}`；同时监听同 `requestId` 的 `file_explorer_response`（错误或旧 Daemon 的 JSON 回退）。
3. 按 kind 渲染：text（UTF-8 文本 + 语法高亮可选）、image（UIImage；SVG 另行处理）、binary（显示大小 + 「下载」）。
4. 有 `workspaceFileEditing` 时 `fs.file.subscribe`；收到 `fs.file.update` 且 revision 变化 → 重读（编辑中则提示冲突）；`missing` → 显示已删除。关闭时 release。
5. （可后做）编辑保存：`fs.file.write` 带 `expectedRevision`；处理 `conflict`/`error`；≤ 1 MiB。

### 5.3 Changes + diff

1. 事件订阅加入 `checkout_status_update`；工作区头部显示分支、ahead/behind（相对 base 和 upstream）、dirty。
2. 打开 Changes：`subscribe_checkout_diff_request{compare:{mode:"uncommitted"}}`；列表 = `files`（A/M/D/R 由 isNew/isDeleted/oldPath 推导，+/- 计数）。
3. 处理 `checkout_diff_update`（整份替换）、`diffTooLarge`、`error`。
4. 点击文件：直接渲染该文件 `hunks`（header/context/add/remove，自算行号）；`status:"binary"|"too_large"` 显示占位。
5. 可选切换 `base` 模式（release 旧订阅、建新订阅）。
6. （可后做）动作：commit（带 message）/ pull / push / refresh / discard（二次确认，不可恢复）；PR 徽标用 workspace `githubRuntime.pullRequest`。

### 5.4 终端

1. hello 加 `terminal_reflowable_snapshot:true`；事件订阅加 `terminal_attention_required`。
2. 实现终端帧解码（首字节 0x01–0x05，第 2 字节 slot），维护 `slot → terminalId` 映射；断线清空。
3. Tab 列表：`subscribe_terminals_request{cwd, workspaceId, requestId}` → `terminals_changed`（全量）；排除脚本终端。
4. 新建：`create_terminal_request{cwd, workspaceId}`（可选 profile 的 command/args）。
5. 附着：先 `terminal_input` resize `claim`（SwiftTerm 当前 cols/rows），再 `subscribe_terminal_request{restore:{mode:"visible-snapshot",scrollbackLines:200}}`；记录 slot 与 subscriptionId。
6. 收 Restore（任何时候）：reset + 屏蔽回应 + feed；收 Output：直接 feed。
7. 输入：SwiftTerm `send(source:data:)` → `terminal_input{message:{type:"input",data:String(utf8)}}`。
8. 尺寸：`sizeChanged` → resize `update`；获得焦点/用户输入 → `claim`。
9. 处理 `terminal_stream_exit`（无 error = 进程结束，显示「已退出」；有 error = 可重试附着）。
10. 离开 Tab：`subscription.release.request`；关闭 Tab：`kill_terminal_request`。
11. 前台终端 Tab：`client_heartbeat.focusedTerminalId` = 该 id（清除 attention）。

### 5.5 脚本

1. 事件订阅 `script_status_update`；进入工作区时 `workspace.script.list.request` 补齐（或直接用 workspace 描述符的 `scripts`）。
2. 列表显示 名称 / type / lifecycle / health / exitCode。
3. 启动 / 停止：`workspace.script.start|stop.request`，错误 toast。
4. 「日志」：用 `terminalId` 走 §5.4 的附着流程（只读展示也可以，但输入同样可用）。

---

## 6. 未确认事项汇总

1. `checkoutDiffAll` 开关在官方 App 中的具体门控位置（§0）。
2. 配对设备的默认权限是否覆盖全部 `workspace.write` 操作（§0）。
3. Host 是否保证 `file.upload.request` 先于后续二进制帧被处理（官方客户端依赖此顺序）（§1.8）。
4. SVG 等非位图图片在官方原生端的渲染方式（§1.2）。
5. Changes 面板默认比较模式是否恒为 `uncommitted`（§2.3）。
6. diff `tokens[].style` 的完整类名集合（§2.3）。
7. 终端快照是否保留备用屏、鼠标模式等；全屏 TUI 恢复后的重绘行为（§3.5）。
8. SwiftTerm 对 kitty 键盘协议 / win32-input-mode 的支持情况（§3.6）。
9. daemon config 未设 `terminalProfiles` 时 App 是否回退到内置默认 profile（§3.2）。
10. 脚本 `proxyUrl` 在移动端是否有可用场景（§4.1）。
