# 01 · Paseo 客户端连接协议（v0.14.0）

> 来源：`vendor/paseo`（tag `v0.14.0`）。下文所有 `path:line` 均相对 `vendor/paseo/`。
> 目标读者：从零写 Swift 原生客户端（iOS / iPadOS / macOS）的人。
> 标注 **未确认** 的地方表示源码里看不到、或只能推断。

---

## 0. 总览

```
 Swift App ──wss──▶ Relay (/ws?serverId=…&role=client&v=2) ◀──wss── Daemon (control + per-connection data socket)
     │                  （只转发，零知识）                                │
     └──────────── Noise_NK E2EE（e2ee_hello / e2ee_ready + 受保护记录） ──┘
                         └── App 层：hello → session{status:server_info} → session RPC / push
```

分层（从下到上）：

| 层 | 直连（directTcp） | 中继（relay） |
| --- | --- | --- |
| L1 物理 | `ws(s)://host:port/ws` | `ws(s)://relayHost:port/ws?serverId=&role=client&v=2` |
| L2 端到端安全 | 无（可选 TLS） | `Noise_NK_25519_ChaChaPoly_SHA256` + 受保护记录分帧 |
| L3 App 握手 | `hello` → `server_info` | 同左（在 L2 内部） |
| L4 App 消息 | `{type:"session",message:{…}}` + 二进制帧 | 同左 |

L3/L4 对两种传输完全一样；中继只是在 WebSocket 与 App 层之间插入 L2。

---

## 1. 配对链接（Pairing link）

### 1.1 两种格式

Daemon 生成两种等价的表示：

**A. Offer URL（二维码里就是这个）**

```
https://app.paseo.sh/#offer=<base64url(JSON)>
```

- 生成：`packages/server/src/server/connection-offer.ts:45-52` —— `JSON.stringify(offer)` → UTF-8 → Node `base64url`（**无 padding**，`-`/`_` 字符集）→ 拼到 `appBaseUrl` 的 `/#offer=` 后。
- 默认 `appBaseUrl = "https://app.paseo.sh"`、默认 relay `relay.paseo.sh:443`、默认 `useTls` 当 endpoint 为 `relay.paseo.sh:443` 时为 true：`packages/server/src/server/pairing-offer.ts:36-40`。
- 解析：`packages/protocol/src/connection-offer.ts:27-62`。只看 `#offer=` 之后的部分，与前面的 host/path 无关（e2e 测试里甚至用 `/settings/general#offer=…`，`packages/app/e2e/support/helpers/host-confirmation.ts:24`）。

**B. relay URI（CLI `paseo daemon pair` 额外打印的 `connectionUri`）**

```
relay://<relayHost>:<port>/<urlencoded serverId>?key=<daemonPublicKeyB64>[&ssl=true][&security=protected][&password=<pw>]
```

也可能被包成 `https://…/#connect=<encodeURIComponent(relay://…)>`。

- 生成：`packages/protocol/src/daemon-endpoints.ts:61-72`；CLI 输出 `packages/cli/src/commands/daemon/pair.ts:201-202`。
- 解析：`packages/protocol/src/daemon-endpoints.ts:22-59`。
- App 入口统一判断：以 `relay://` 开头或包含 `#connect=` → 走 B，否则找 `#offer=` → 走 A（`packages/app/src/runtime/host-runtime.ts:1571-1581`，`packages/app/src/components/pair-link-credentials.ts:4-16`）。

注意：**只有 B 形式能携带 `password`**；A 形式（`#offer=`）不带密码，App 需要另行让用户输入（`packages/app/src/components/add-host-modal.tsx`、CHANGELOG 0.13.0「relay connections require the daemon password」`CHANGELOG.md:111`）。

### 1.2 Offer JSON 字段（`ConnectionOfferV2`）

Schema：`packages/protocol/src/connection-offer.ts:9-20`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `v` | literal `2` | 版本，必须是 2 |
| `serverId` | string ≥1 | Daemon 稳定 ID，同时是 relay 的会话路由键。生成格式 `srv_` + 9 字节随机的 base64url（12 字符），`packages/server/src/server/server-id.ts:23-27`；可被 `PASEO_SERVER_ID` 覆盖，所以**不要假设格式** |
| `daemonPublicKeyB64` | string ≥1 | Daemon 静态 X25519 公钥，**标准 base64 带 padding**（44 字符，32 字节）。来自 `$PASEO_HOME/daemon-keypair.json` 的 `publicKeyB64`（`packages/server/src/server/daemon-keypair.ts:16-20`）。Noise NK 的 responder static `rs` |
| `relay.endpoint` | string | `host:port`（IPv6 为 `[::1]:443`），不含 scheme |
| `relay.useTls` | bool, 可选 | true → `wss`。缺省时 App 用兼容回退：端口 443 则 TLS（`packages/app/src/types/host-connection.ts:441-453`，`packages/protocol/src/daemon-endpoints.ts:264-271`） |
| `minimumSecurityMode` | `"protected"`, 可选 | v0.13.0 新增。存在时客户端第一次握手就必须拒绝 legacy（见 §3.8） |

relay URI 的映射（`daemon-endpoints.ts:35-58`）：`hostname:port` → `relay.endpoint`（必须带显式端口、不得有 userinfo）；`pathname[1:]` 解码 → `serverId`（不得含 `/`）；`key` → `daemonPublicKeyB64`；`ssl=="true"` → `useTls`（注意这里**总是**布尔值，缺省即 false，不走 443 回退）；`security` 只允许缺省或 `protected`；`password` 为可选密码。

公钥校验（Daemon 侧 `importPublicKey` 用的规则，客户端应同样严格）：`packages/relay/src/crypto.ts:72-86,111-117` —— 长度 %4==0、严格标准 base64 正则、重新编码必须与原文一致、解码后 32 字节。

### 1.3 解析算法（Swift 伪代码）

```swift
struct PairingOffer { serverId: String; daemonPublicKey: Data /*32B*/; daemonPublicKeyB64: String
                      relayEndpoint: String; useTls: Bool; requireProtected: Bool; password: String? }

func parsePairing(_ raw: String) throws -> PairingOffer {
  let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if s.hasPrefix("relay://") || s.contains("#connect=") {
    // —— 形式 B ——
    var uri = s
    if let r = s.range(of: "#connect=") { uri = String(s[r.upperBound...]).removingPercentEncoding! }
    let u = URLComponents(string: uri)!                       // scheme 必须是 "relay"
    guard u.scheme == "relay", let host = u.host, !host.isEmpty, let port = u.port,
          u.user == nil, u.password == nil else { throw .invalid }
    let serverId = String(u.percentEncodedPath.dropFirst()).removingPercentEncoding!
    let key = u.queryItems?.first { $0.name == "key" }?.value     // 注意: URLComponents 不会把 '+' 解成空格，与 JS URLSearchParams 不同！
    guard !serverId.isEmpty, !serverId.contains("/"), let key else { throw .invalid }
    let security = u.queryItems?.first { $0.name == "security" }?.value
    guard security == nil || security == "protected" else { throw .unsupportedSecurity }
    return .init(serverId: serverId, daemonPublicKey: try strictB64Key(key), daemonPublicKeyB64: key,
                 relayEndpoint: normalizeHostPort(host, port),
                 useTls: query("ssl") == "true", requireProtected: security == "protected",
                 password: query("password").flatMap { $0.isEmpty ? nil : $0 })
  }
  // —— 形式 A ——
  guard let r = s.range(of: "#offer=") else { throw .missingOffer }
  var b64 = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
  b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
  let json = try JSONSerialization.jsonObject(with: Data(base64Encoded: b64)!)  // UTF-8 严格解码
  // 校验: v == 2, serverId 非空, daemonPublicKeyB64 非空, relay.endpoint 非空,
  //       relay.useTls 可选 bool, minimumSecurityMode 缺省或 "protected"
  let useTls = relay.useTls ?? (port(of: relay.endpoint) == 443)
  ...
}
```

关于 `key` 中的 `+`：JS `URLSearchParams.get` 会把 `+` 解码为空格，而 `serializeRelayConnectionUri` 用 `url.searchParams.set` 写入，会把 `+` 编码成 `%2B`、`/` 编码成 `%2F`、`=` 编码成 `%3D`（WHATWG `application/x-www-form-urlencoded`）。Swift 侧用 `URLComponents.queryItems` 解码即可得到原文；但若用户手抄的 URI 含裸 `+`，JS 会解成空格导致公钥校验失败，Swift 若保留 `+` 反而能通过——行为差异无害，但测试时注意。

---

## 2. 传输选项

### 2.1 直连 WebSocket

- URL：`ws(s)://<host>:<port>/ws`，`packages/protocol/src/daemon-endpoints.ts:228-233`。默认监听 `127.0.0.1:6767`（`packages/server/src/server/config.ts:38`，`persisted-config.ts:382`），服务端 path 固定 `/ws`、`maxPayload` 100 MiB（`packages/server/src/server/websocket-server.ts:878-879`，`packages/protocol/src/websocket-message-limit.ts:2`）。
- 保存格式 `tcp://host:port[?ssl=true][&password=…]`（`daemon-endpoints.ts:144-202`）。
- 准入检查（升级阶段）：`Host` 头必须在白名单——默认允许 `localhost`、`*.localhost`、**所有 IP 字面量**（`packages/server/src/server/hostnames.ts:57-74` 及其上方 `isDefaultAllowedHostname`）；用域名直连需要 Daemon 配 hostnames，否则 HTTP 403 `Host not allowed`。`Origin` 头缺省即放行（`websocket-server.ts:940-968`），`URLSessionWebSocketTask` 默认不发 Origin，OK。
- 无 E2EE；只有可选 TLS。密码走 App 层 `hello.auth`（§4.3）；兼容旧版本还可在升级请求里带 `Authorization: Bearer <pw>` 或子协议 `paseo.bearer.<pw>`（`packages/client/src/daemon-client.ts:233-283`，服务端 `websocket-server.ts:970-1004`，`COMPAT(headerAuth)` 计划 2027-03-24 删除）。Swift 原生客户端**只用 `hello.auth`** 即可。

### 2.2 经 Relay

URL 构造：`packages/protocol/src/daemon-endpoints.ts:235-258`

```
ws(s)://<relay.endpoint>/ws?serverId=<serverId>&role=client&v=2
```

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `serverId` | offer.serverId | relay 用它定位会话（Cloudflare 实现：`idFromName("relay-v2:"+serverId)`，`packages/relay/src/cloudflare-adapter.ts:591-610`） |
| `role` | `client` | `server` 是 Daemon 用的 |
| `v` | `2` | `CURRENT_RELAY_PROTOCOL_VERSION`（`daemon-endpoints.ts:77`）。v1 是旧的一对一模式，别用 |
| `connectionId` | **客户端不传** | relay 自动分配 `conn_<16hex>`（`cloudflare-adapter.ts:347-351`），客户端永远不知道它，也不需要 |

URL 里**绝不放密码或任何凭据**（`packages/client/src/daemon-client-relay-e2ee-transport.ts:85-93`；带凭据却没开 E2EE 会直接抛 `Relay credentials require E2EE`，`daemon-client.ts:1624-1628`）。

Relay 行为（以仓库内 Cloudflare 实现为准，`cloudflare-adapter.ts`）：

- v2 拓扑：Daemon 维持一条 control socket（`role=server` 无 connectionId）+ 每个客户端一条 data socket（`role=server&connectionId=…`）。客户端连上时 relay 向 control 发 `{"type":"connected","connectionId":…}`，Daemon 再开 data socket（`cloudflare-adapter.ts:124-128,394-397`；Daemon 侧 `packages/server/src/server/relay-transport.ts:340-389`）。
- Daemon data socket 尚未连上时，客户端发来的帧被缓存（最多 200 帧，超出丢最旧的），连上后 flush（`cloudflare-adapter.ts:252-275,481-486`）。10 s 内 Daemon 没反应会 nudge，再 5 s 没反应强制重置 control（`:219-250`）。
- **relay 不会向客户端 socket 发送任何自己的消息**；客户端收到的每一帧都来自 Daemon。
- Daemon data socket 断开 → relay 以 `1012 "Server disconnected"` 关闭所有该 connectionId 的客户端 socket（`:549-558`）。Daemon 发出的 close code（例如 `1008`）**不会**透传给客户端（`docs/relay-endpoint-security.md:64`）。
- 帧大小上限：relay 加密帧 32 MiB（`packages/protocol/src/websocket-message-limit.ts:5`）；客户端发送前按线上字节数检查（`daemon-client-relay-e2ee-transport.ts:233-238`）。
- 生产 relay 是独立仓库的 Elixir 服务（`docs/architecture.md:193`），本仓库的 Cloudflare 实现「保留但未部署」。**未确认**：Elixir relay 的 query 参数、帧缓存、1012 行为、空闲超时、是否响应 WS 协议层 ping 与上述完全一致——文档声称两者行为一致（`docs/relay-endpoint-security.md:64,88`），但源码不在本仓库。

### 2.3 官方 App 默认用哪个

- 配对（扫码 / 粘贴 `#offer=` / `relay://`）只产生 **relay** 连接（offer 是「Relay-only pairing offer」，`connection-offer.ts:3-8`）。所以手机扫码后的默认连接是 relay。
- 一个 host 可以保存多条连接（relay、directTcp、桌面端的 socket/pipe/ssh）。`HostRuntimeController` 周期性探测每条连接延迟，选最快的可用连接；只有新连接比当前快 ≥40 ms 且连续 3 次探测才切换（`packages/app/src/runtime/host-runtime.ts:241-245,1060-1105`，`packages/app/src/utils/connection-selection.ts:26-50`）。直连需要用户手动「Add host」。
- App 在所有平台都发 `clientType: "mobile"`（`host-runtime.ts:586`）；relay 连接配置见 `host-runtime.ts:638-655`。

---

## 3. E2EE（仅 relay）

### 3.1 两种模式

| 模式 | 构造 | 何时使用 |
| --- | --- | --- |
| `protected` | `Noise_NK_25519_ChaChaPoly_SHA256`（Noise 规范 rev 34） | 双方都 ≥ v0.13.0 时必然协商到 |
| `legacy` | X25519 + NaCl `box`（XSalsa20-Poly1305，随机 24B nonce） | 旧对端；无防重放 |

`docs/relay-endpoint-security.md:7-16`；代码入口 `packages/relay/src/secure-channel.ts:1-23`。**Swift 客户端建议只实现 `protected`**（v0.13.0+ Daemon 必然支持），把 `minimumMode` 固定为 `protected`。legacy 见 §3.9。

### 3.2 Noise 参数

| 项 | 值 | 出处 |
| --- | --- | --- |
| 协议名 | `Noise_NK_25519_ChaChaPoly_SHA256`（32 字节，恰好 = HASHLEN，所以 `h` = 名字 ASCII 本身，**不哈希**） | `packages/relay/src/noise/index.ts:26`；`noise/symmetric-state.ts:15-25` |
| 模式 | NK：`<- s` / `...` / `-> e, es` / `<- e, ee` | `noise/index.ts:9-14,69-72` |
| Prologue | ASCII `paseo-relay-e2ee/1`（18 字节） | `secure-channel.ts:114` |
| DH | X25519；DH 结果全零即报错（`invalid DH public key`） | `noise/index.ts:219-230` |
| Cipher | ChaCha20-Poly1305（IETF，12B nonce = 4 字节 0 + 8 字节**小端** counter），16B tag | `noise/cipher-state.ts:3-6,68-76` |
| Hash | SHA-256，HKDF = Noise §4.3（HMAC-SHA256 链） | `noise/symmetric-state.ts:65-72` |
| 单条 Noise 消息上限 | 65535 字节 | `noise/cipher-state.ts:6` |
| responder static `rs` | offer 中的 `daemonPublicKeyB64` | `secure-channel.ts:159,165` |

### 3.3 握手状态机（逐字节）

初始化（initiator = 客户端）——`noise/index.ts:102-128`：

```
h  = "Noise_NK_25519_ChaChaPoly_SHA256"   (32B, 原样)
ck = h
k  = empty, n = 0
h  = SHA256(h || prologue)                 // mixHash(prologue)
h  = SHA256(h || rs)                       // pre-message "<- s"
```

**Message 1（客户端写，`-> e, es`）**——`noise/index.ts:130-156`：

```
e  = 新生成 X25519 密钥对
h  = SHA256(h || e.pub)                         // token e
(ck, k) = HKDF(ck, X25519(e.priv, rs)); n = 0   // token es (initiator: e × rs)
c  = ChaChaPoly_Encrypt(k, nonce(n=0), ad=h, payload)   // encryptAndHash
h  = SHA256(h || c)
msg1 = e.pub(32) || c(payload.len + 16)
```

`payload` = 参数字节 `[0x01, flags]`（§3.4）。所以 `msg1` 长度固定 32 + 2 + 16 = **50 字节**。

**Message 2（Daemon 写，`<- e, ee`）**——客户端读，`noise/index.ts:158-186`：

```
re = msg2[0..32];  h = SHA256(h || re)              // token e
(ck, k) = HKDF(ck, X25519(e.priv, re)); n = 0       // token ee
payload = ChaChaPoly_Decrypt(k, nonce(0), ad=h, msg2[32..])   // decryptAndHash
h = SHA256(h || msg2[32..])
```

`msg2` 也是 50 字节；payload 为 Daemon 选定的参数。

**Split**——`noise/symmetric-state.ts:53-63`，`noise/index.ts:196-204`：

```
(k1, k2) = HKDF(ck, empty)
客户端: send = CipherState(k1, n=0), receive = CipherState(k2, n=0)
Daemon:  send = k2, receive = k1
```

HKDF（`symmetric-state.ts:66-72`）：

```
temp = HMAC-SHA256(key=ck, data=ikm)
out1 = HMAC-SHA256(key=temp, data=0x01)
out2 = HMAC-SHA256(key=temp, data=out1 || 0x02)
```

这与 RFC 5869 的 `HKDF-Extract(salt=ck, ikm)` + `HKDF-Expand(prk, info=∅, L=64)` 完全等价，所以 CryptoKit 的 `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:64)` 取前后 32 字节也可，但手写 HMAC 更直观、便于对照向量。

CipherState 规则（`noise/cipher-state.ts:33-65`）：

- 无 key 时 encrypt/decrypt 为恒等（只在握手 msg1 的 `e` 之前出现，NK 中实际不会用到）。
- 发送：先取 nonce 再自增，**在任何 await 之前同步预留**；n 到 2^64−1 抛 `nonce exhausted`，绝不回绕。
- 接收：只有 tag 验证成功才自增 n。重复、乱序、反射的记录都会因 nonce 不符而解密失败。
- 传输阶段 AD 永远为空（`protected-records.ts:9,29`）。
- **没有 rekey**：整条连接一对密钥，连接断开即丢弃；重连 = 全新握手（新 ephemeral）。

### 3.4 参数 payload（握手消息内的 2 字节）

`secure-channel.ts:115-118,794-807`：

```
byte0 = 0x01            // PARAMS_VERSION
byte1 = flags           // bit0 = binaryCiphertext；其它位保留，必须为 0
```

- 客户端在 msg1 中「提供」；Daemon 在 msg2 中「选择」——v0.14.0 Daemon 原样回传客户端提供的值（`secure-channel.ts:492-494`）。
- 客户端校验 msg2 payload：长度必须 2、版本必须 0x01、无保留位、且不能选择客户端未提供的 flag（`secure-channel.ts:285-288,801-807`）。
- `binaryCiphertext=1`：App 层的「二进制帧」加密后以 WebSocket 二进制帧发送；文本帧永远以 base64 文本发送。`=0`：一律 base64 文本。**无论哪种，接收方都根据记录内的 `kind` 字节还原 App 帧类型**，不看 WS 帧类型。Swift 客户端默认提供 `0x01`（`SecureChannel.open(offerBinaryCiphertext:)`）。daemon 0.15.0 的 JSON 消息仍是文本记录、照样 base64，实测只有文件读写、终端流这类二进制负载省下约 25% 线上字节。

### 3.5 握手外层 JSON 信封

握手消息以**明文 WebSocket 文本帧**承载在 JSON 里（`secure-channel.ts:122-138,153-216`）：

客户端 → Daemon：

```json
{"type":"e2ee_hello",
 "key":"<legacy X25519 临时公钥 base64>",
 "capabilities":{"binaryCiphertext":true},
 "protected":{"v":1,"message":"<base64(msg1)>"}}
```

Daemon → 客户端：

```json
{"type":"e2ee_ready","protected":{"v":1,"message":"<base64(msg2)>"}}
```

要点：

- `key` **必填且非空**（Daemon 的 `isHelloEnvelope` 校验，`secure-channel.ts:751-760`），即使走 protected 也要发。它是给旧 Daemon 走 legacy 用的一把**独立**临时 X25519 公钥（不是 Noise 的 `e`）。Swift：`Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()`。
- `capabilities` 在 protected 模式下不被认证、被忽略（`docs/relay-endpoint-security.md:24`）；照抄 `{"binaryCiphertext":true}` 即可（或与 flags 保持一致）。
- `protected.v` 必须是 1；`message` 是**标准 base64**（`base64-js fromByteArray`，带 padding）。解码端容忍 url-safe 字符和缺失 padding（`packages/relay/src/base64.ts:7-19`）。
- 客户端：只处理 `type:"e2ee_ready"` 的文本帧，握手期间其他帧一律忽略（`secure-channel.ts:251-277`）。`e2ee_ready` 带 `protected` → 走 protected；不带 → legacy（若 `minimumMode=protected` 则失败）。**`protected` 存在但非法 → 握手失败，绝不回退 legacy**。
- **重发**：客户端每 1000 ms 重发**同一个字节完全相同的** hello 文本，直到收到 ready（`secure-channel.ts:119,183-213`）。Daemon 缓存首个 hello 文本与 ready 文本：完全相同的 hello → 回同一个 ready，counter 不受影响；不同的 hello → 以 `1008 "E2EE re-handshake transcript mismatch"` 关闭（`secure-channel.ts:633-643`）。⇒ Swift 实现必须**序列化一次、缓存字符串、重复发送同一字符串**，不要每次重新 `JSONEncoder` 编码（键序可能变）。
- 打开后再收到 `e2ee_ready` 直接忽略（`secure-channel.ts:636`）。
- Daemon 侧握手超时 15 s 后直接 terminate socket（`packages/server/src/server/websocket/secure-relay-ingress.ts:21,60-63`）。

### 3.6 受保护记录（Protected records）——传输阶段的分帧与分块

`packages/relay/src/protected-records.ts:1-229`，规范描述 `docs/relay-endpoint-security.md:30-43`。

一个 App 帧（一条 JSON 文本或一段二进制）= 一条 wire record = 1..N 个 Noise 传输消息（chunk）：

```
chunk plaintext = kind(1) || flags(1) || totalLength(u32 BE) || data
chunk wire      = ciphertextLength(u16 BE) || ChaChaPoly(sendKey, nonce(n++), ad=∅, chunk plaintext)
wire record     = chunk wire || chunk wire || ...
```

| 常量 | 值 | 出处 |
| --- | --- | --- |
| `kind` | `0x00` text（UTF-8），`0x01` binary | `protected-records.ts:23-24` |
| `flags` | bit0 `FIRST`，bit1 `FINAL`，其余保留 | `:25-26` |
| HEADER | 6 字节 | `:27` |
| `MAX_CHUNK_DATA_BYTES` | 65535 − 16 − 6 = **65513** | `:32` |
| 每块开销 | 2 + 6 + 16 = 24 字节 | `:35` |
| 块数 | `max(1, ceil(totalLength / 65513))`（空帧也有 1 块） | `:37-39` |
| record 总长 | `totalLength + 块数 × 24` | `:42-44` |

编码（`:46-69`）：按 65513 切片；第 i 块 flags = (i==0 ? FIRST : 0) | (i==last ? FINAL : 0)；每块都写同一个 `kind` 与 `totalLength`。

解码规则（`:81-198`），任何违例都抛错并必须关闭通道，不得交付部分明文：

1. 读 u16 长度；长度 < 22（16+6）或 > 65535 → `invalid chunk length`；剩余字节不足 → `record truncated`。
2. 解密（失败 → `authentication failed`；接收 counter 只在成功时 +1）。
3. flags 有保留位 → 错；kind 非 0/1 → 错。
4. 第一块必须 FIRST；**在分配缓冲前**校验 `protectedRecordByteLength(totalLength) == record 实际字节数`，否则 `record length mismatch`。
5. 后续块不得 FIRST、kind/totalLength 必须一致；最后一块（且仅最后一块）FINAL；非最后块 data 必须恰好 65513 字节，最后块 = 余数。
6. 结束时块数和已写字节必须吻合；多余尾随字节 → `unexpected chunk after final`。

WebSocket 承载（`secure-channel.ts:645-663` 发送，`:610-631` 接收）：

- 发送：`kind==binary && binaryCiphertext` → 以 WS 二进制帧发送 record 原始字节；否则 → `base64(record)` 作为 WS 文本帧。
- 接收：WS 二进制帧 → 直接当 record；WS 文本帧 → 先看是否为握手 JSON（trim 后以 `{` 开头：`e2ee_hello`/`e2ee_ready` 当握手流量处理，**其他任何 JSON 视为对方在发明文，立即失败**，`secure-channel.ts:772-792`），否则 base64 解码后当 record。
- 解出的 `kind==text` 用严格 UTF-8 解码交给 App 层作为文本；`kind==binary` 作为二进制交给 App 层的二进制帧解析器（§6.3）。
- 关于 `chunked-transport.ts`：v0.14.0 的 `packages/protocol/src` 中**不存在**该文件；E2EE 的分块就是上面的 `protected-records.ts`。

### 3.7 失败与关闭码（客户端视角）

| 情况 | 谁关 | 码 | 出处 |
| --- | --- | --- | --- |
| protected 握手失败 / 只拿到 legacy 但要求 protected / 降级检测 | 客户端 | `4002` | `secure-channel.ts:101-102`；`daemon-client-relay-e2ee-transport.ts:138-149` |
| 入站记录认证或分帧失败 | 客户端 | `4003` | `secure-channel.ts:103-108` |
| `openClientSecureChannel` 本身抛错（如公钥非法） | 客户端 | `4001 "E2EE handshake failed"` | `daemon-client-relay-e2ee-transport.ts:203-209` |
| 入站记录失败 | Daemon | `1011`（到客户端会被 relay 换成 `1012`） | `secure-channel.ts:110`；`docs/relay-endpoint-security.md:50,64` |
| Daemon 策略拒绝 legacy | Daemon | `1008 protected endpoint security required`（同上被 relay 替换） | `secure-channel.ts:99-100,515-521` |

客户端遇到自己的 `4002` 应停止自动重连并提示升级（`daemon-client.ts:1549-1551`）。注意 `4001/4002/4003` 与 Daemon App 层的同号关闭码（§4.5）语义不同——前者是客户端本地决定的，后者是 Daemon 在直连时发出的；经 relay 时 Daemon 的关闭码根本到不了客户端。

### 3.8 防降级与 pin

- v0.13.0+ Daemon 在**每个**会话的 `server_info.features.relayProtectedSecurity: true`（`packages/server/src/server/websocket-server.ts:1935-1952`）。客户端若协商到 legacy 却在第一条 `server_info` 里看到它 → 以 `4002` 关闭（`daemon-client-relay-e2ee-transport.ts:61-79,134-153`）。
- App 在首次 protected 握手成功后，或 offer 带 `minimumSecurityMode` 时，对该 daemon 公钥永久 pin `protected`；同一进程内一次 protected 之后的重连也强制 protected（`docs/relay-endpoint-security.md:54-62`，`daemon-client.ts:1477-1491`）。Swift 实现只做 protected，天然满足。

### 3.9 Legacy 模式（可选，不建议）

仅为连接 < v0.13.0 的 Daemon。`packages/relay/src/crypto.ts` + `encrypted-channel.ts`：共享密钥 = `nacl.box.before(daemonPub, clientEphemeralPriv)`（X25519 + HSalsa20），每条消息 `nonce(24 随机) || XSalsa20-Poly1305 密文`，文本 base64 发送，无 counter、无防重放。CryptoKit **没有** XSalsa20/HSalsa20，需要 [swift-sodium](https://github.com/jedisct1/swift-sodium)（`crypto_box_beforenm` / `crypto_box_easy_afternm`）或 TweetNacl Swift 封装。

### 3.10 CryptoKit 映射（protected 模式所需原语全部具备）

| Noise 原语 | CryptoKit |
| --- | --- |
| X25519 | `Curve25519.KeyAgreement.PrivateKey` / `.sharedSecretFromKeyAgreement(with:)`，用 `withUnsafeBytes` 取 32 字节原始共享秘密 |
| 测试向量注入固定 ephemeral | `Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret32)`（CryptoKit 内部做 clamp，与 noble 一致） |
| ChaCha20-Poly1305 | `ChaChaPoly.seal(pt, using: SymmetricKey(data:k), nonce: try ChaChaPoly.Nonce(data: 4×0x00 + n.littleEndian 8B), authenticating: ad)`，输出取 `ciphertext + tag`（**不要**用 `.combined`，它前置了 nonce）；解密用 `ChaChaPoly.SealedBox(nonce:ciphertext:tag:)` |
| SHA-256 | `SHA256.hash(data:)` |
| HMAC-SHA256 / HKDF | `HMAC<SHA256>.authenticationCode(for:using:)` |
| 全零 DH 检查 | 自己检查 32 字节是否全 0。**未确认**：CryptoKit 对低阶点是否会自行抛错；无论如何显式检查一次 |
| base64 | `Data.base64EncodedString()`（标准、带 padding）；解码前把 `-_` 换成 `+/` 并补 padding |

没有任何需要第三方库的原语（legacy 除外）。若想用现成 Noise 实现，可评估 Swift 的 Noise 库，但 NK 只有两条消息，手写约 200 行，更易对齐向量，推荐手写。

### 3.11 测试向量（可直接移植为 Swift 测试）

- 向量文件：`packages/relay/src/noise/fixtures/nk-25519-chachapoly-sha256.json`。两组 `Noise_NK_25519_ChaChaPoly_SHA256` 向量，来源 noise-c 的 `cacophony.txt` 与 `noise-c-basic.txt`（第二组含 `handshake_hash`）。字段：`init_prologue`、`init_ephemeral`（私钥）、`init_remote_static`、`resp_static`（私钥）、`resp_ephemeral`、`messages[6]`（前 2 条握手 + 4 条传输，传输消息 AD 为空、按 initiator/responder 交替）。
- 用法参考：`packages/relay/src/noise/noise.test.ts:24-67`（向量），`:69-128`（重复/乱序/反射/重放/全零公钥拒绝），`:130-150`（nonce 用尽），`:152-166`（握手顺序错误）。
- 注意向量的 prologue 是 `"John Galt"` 而非 `paseo-relay-e2ee/1`，payload 也不是 2 字节参数——向量只验证 Noise 内核；分帧另测。
- 分帧规则测试：`packages/relay/src/protected-records.test.ts:77-175`（无固定向量，是性质测试，可移植为 Swift 单测）。
- 端到端：`packages/relay/src/secure-channel.test.ts`（双模式、混合版本、重试、录制重放、降级）。

---

## 4. App 层握手（在安全通道之上）

### 4.1 时序

```
[WS open]                         (relay: 先完成 §3 握手，再视为 "open")
C → S  {"type":"hello", ...}                         // 立即发送
S → C  {"type":"session","message":{"type":"status","payload":{"status":"server_info", ...}}}
       —— 或 ——
S → C  {"type":"hello.rejected","reason":...,"accepts":["password"]}  然后关闭
```

客户端在 transport open 时发送 hello（`daemon-client.ts:1528-1536,6594-6632`），收到第一条 `server_info` 才算 connected（`daemon-client.ts:7152-7178`）。没有其他欢迎消息（`docs/architecture.md:250-265`）。

### 4.2 `hello` 消息

Schema：`packages/protocol/src/messages.ts:7659-7697`

```json
{
  "type": "hello",
  "clientId": "cid_0f1e…",
  "clientType": "mobile",
  "protocolVersion": 1,
  "auth": {"kind": "password", "password": "…"},
  "appVersion": "0.14.0",
  "capabilities": {"hello_rejection": true}
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `type` | ✓ | `"hello"` |
| `clientId` | ✓ | 非空（trim 后），**跨连接稳定**——Daemon 用 `(principalId, clientId)` 识别并恢复逻辑会话（`websocket-server.ts:1747-1752`）。官方 App 格式 `cid_` + 无连字符 UUID，存于本地（`packages/app/src/utils/client-id.ts:44`）。Swift：首启生成，存 Keychain/UserDefaults。不得用 `plugin` 保留前缀（`websocket-server.ts:1717-1727`） |
| `clientType` | ✓ | 枚举 `mobile`/`browser`/`cli`/`mcp`/`hub`；非法值 → hello 校验失败 → `4002 Invalid hello`。原生 App 用 `"mobile"` |
| `protocolVersion` | ✓ | 整数。客户端写死 `1`（`daemon-client.ts:6615`）；Daemon `WS_PROTOCOL_VERSION = 1`，只拒绝 `< 1`（`websocket-server.ts:510,1692-1703`） |
| `auth` | – | `{kind:"password",password}` 或 `{kind:"localCredential",token}`（后者只给同机桌面端）。经 relay 时**只能**放这里 |
| `appVersion` | – | 字符串，Daemon 记录并用于日志/兼容 |
| `capabilities` | – | `passthrough` 对象，键为 `CLIENT_CAPS`（`packages/protocol/src/client-capabilities.ts:1-50`），值多为 `true`。官方默认集见 `packages/client/src/connection/index.ts:127-146` |
| `sessionPermissions` | – | 权限子集上限（缩权用），一般不发 |
| `routed` / `producer` | – | 守护进程间路由用，客户端不发 |

能力（capabilities）的含义：广播某能力等于承诺实现对应的接收语义（`docs/protocol-compatibility.md:43-49`）。建议 Swift 原型**先只发 `hello_rejection: true`**（必须，否则 relay 上无法区分密码错误，见 §4.4），之后每实现一类功能再加对应能力（如 `owned_subscriptions`、`explicit_event_subscriptions`、`selective_agent_timeline` 等，详见后续文档）。

### 4.3 密码认证（v0.13 起 relay 也强制）

服务端：`packages/server/src/server/session-admission-auth.ts:11-32`

- Daemon 未设密码 → 直接以 `owner` 准入（忽略 `auth`）。
- 设了密码且 hello 无 `auth` → `password_required`。
- `kind:"password"` → bcrypt `compare(password, passwordHash)`，不符 → `incorrect_password`。
- 准入成功的 principal 都是 `owner`，权限 `OWNER_PERMISSIONS`。

密码的来源：relay URI 的 `password` 参数，或用户手动输入。配对链接等同于密码（CHANGELOG 提到对此有警告），Swift 要把密码存 Keychain。

### 4.4 服务器回复

**成功**——`websocket-server.ts:1773`（新会话）/ `:1909`（恢复会话），payload 构造 `:1935-1952+`，信封 `:2122-2130`：

```json
{"type":"session","message":{"type":"status","payload":{
  "status":"server_info",
  "protocolVersion":1,
  "serverId":"srv_…",
  "hostname":"my-mac",
  "version":"0.14.0",
  "sourceId":"owner",
  "permissions":[…],
  "desktopManaged":false,
  "capabilities":{"voice":{…}},
  "features":{"relayProtectedSecurity":true,"ownedSubscriptions":true,"connectedHosts":true, … }
}}}
```

Schema：`packages/protocol/src/messages.ts:3629-3842`（`ServerInfoStatusPayloadSchema`，`passthrough`，所有字段除 `status`/`serverId` 外可选）。客户端应：

- 用 `serverId` 核对 offer 中的 serverId（官方 App 用它做 host 身份）。
- 缓存 `features` 作为本连接的能力表（每次重连都会重新下发，断线时清空，`daemon-client.ts:7022`）。
- relay 连接若检测到 legacy + `relayProtectedSecurity` → 4002（§3.8）。

**拒绝**——`websocket-server.ts:1839-1868`：

1. 仅当客户端 hello 带了 `auth` **或** `capabilities.hello_rejection === true` 时，先发：
   ```json
   {"type":"hello.rejected","reason":"password_required"|"incorrect_password"|"incompatible_protocol","accepts":["password"]}
   ```
   （schema `messages.ts:7715-7719`）
2. 然后关闭：认证失败 `4401`（reason `Password required` / `Incorrect password`），协议不兼容 `4003`（`Incompatible protocol version`）。

客户端处理：`daemon-client.ts:6772-6783`（记录原因，认证类原因禁止自动重连，`:7024`）；直连时也可从 close reason 文本兜底识别（`daemon-client.ts:258-263`）。**经 relay 时关闭码被 relay 替换为 1012**，唯一可靠信号是 `hello.rejected` ⇒ 必须发 `hello_rejection` 能力。

### 4.5 其他错误情形（Daemon 的 App 层关闭码）

`websocket-server.ts:131,504-510`

| 码 | reason | 触发 |
| --- | --- | --- |
| `4001` | `Hello timeout` | 连接（relay 为安全通道建立）后 15 s 内没收到 hello（`:1438-1457`） |
| `4002` | `Invalid hello` / `Session message before hello` / `Unexpected hello` / `Invalid plugin clientId` | hello schema 不合法；hello 前发了其他消息（含 `ping`，见 §5.1）；已连接后再发 hello（`:2337-2357,2433-2458,2536-2546`） |
| `4003` | `Incompatible protocol version` | `protocolVersion < 1` |
| `4401` | `Password required` / `Incorrect password` | 认证失败 |
| `1001` | `Server shutting down` | Daemon 停机/启动中 |
| `1008` | `Invalid host routing frame` | 非法 0x30 路由帧 |
| `1009` | – | 超过 100 MiB |

---

## 5. 保活、重连与恢复

### 5.1 应用层 ping/pong（liveness）

- **不是** RFC 6455 控制帧 ping，也不是 session RPC：顶层 JSON `{"type":"ping"}` → 顶层 `{"type":"pong"}`（无 payload）。Schema `messages.ts:7651-7657`；服务端 `websocket-server.ts:2510-2517`；客户端 `daemon-client.ts:2459-2512`。
- 客户端节奏（`daemon-client.ts:1094-1097,2515-2541,7123-7136`）：connected 后**等 10 s** 发第一次，之后每 10 s 一次（上一轮结束后再计时）；单次超时 15 s；连续 2 次失败 → 关闭 transport（1001 `Liveness check timed out`）并重连。**任何一条通过校验的入站消息**（含二进制帧）都会把失败计数清零（`:6760,6817,6833`）。
- 服务端租约（`packages/server/src/server/websocket/physical-socket.ts:5-44`）：收到第一个 `ping` 才开始租约（45 s），之后任何入站帧续期；每 10 s 检查，过期则强制断开（`websocket-server.ts:905-915`）。从不发 ping 的 socket 不受租约约束。
- 注意：服务端只在 **已有会话** 时回 pong；hello 之前发 `ping` 会被当作「hello 前的消息」→ `4002`（`websocket-server.ts:2510-2525,2433-2458`）。所以 ping 定时器必须在收到 `server_info` 之后才启动。
- 另有一个 **session 级** ping RPC 用于测延迟/前台校验：`{"type":"session","message":{"type":"ping","requestId":"…","clientSentAt":<ms>}}` → `{"type":"session","message":{"type":"pong","payload":{"requestId","clientSentAt","serverReceivedAt","serverSentAt"}}}`（`messages.ts:2942-2946,3858-3866`，`daemon-client.ts:2408-2440`）。App 回到前台时用它（3 s 超时）验证连接（`daemon-client.ts:1701-1722`）。它是做「第一个 RPC」的理想候选（§8）。
- relay 层：Daemon 自己对 control socket 发 WS 协议 ping（`relay-transport.ts:47-49`），与客户端无关。客户端 socket 上 relay 是否有空闲超时 **未确认**（Elixir relay 不在仓库）；10 s 一次的应用层 ping 足以保活。iOS 上 `URLSessionWebSocketTask.sendPing` 可选，不是协议要求。

### 5.2 重连策略（客户端）

`daemon-client.ts:1089-1093,6987-7092`

- 连接超时：15 s（从发起到收到 `server_info`，覆盖 WS 建立 + E2EE + hello），超时以 1001 关闭并重连（`:1513-1526`）。
- 退避：`delay = min(1500 × 2^attempt, 30000)` ms；收到 `server_info` 时 `attempt = 0`。
- 不重连的情况：认证失败（`password_required`/`incorrect_password`）、客户端自己的 `4002`（endpoint security），以及用户主动 close。
- 断线时：所有等待中的 RPC 以 `DaemonConnectionError(DAEMON_CONNECTION_LOST)` 失败；**已发出但无响应**的请求标记 `outcome: "unknown"`（`:7247-7262`）；排队未发的消息失败；终端流 slot 清空；`server_info` 清空（`:6987-7032`）。**非幂等的变更不自动重放**（`docs/connected-hosts.md:81-88`）。
- 「connecting」期间发起的请求排队，最多等 60 s，connected 后按序发送（`daemon-client.ts:2093-2147`）；「disconnected」时直接失败。
- relay 上每次重连 = 新 WS + 新 Noise 握手（新 ephemeral，counter 从 0）+ 新 `hello`。不存在会话密钥恢复。

### 5.3 服务端会话恢复（resume）

- Daemon 用 `(principalId, clientId)` 作为可重连会话键（`websocket-server.ts:1747-1752`）。最后一个 socket 断开后会话保留 **90 s**（`EXTERNAL_SESSION_DISCONNECT_GRACE_MS`，`:504,2245-2279`）；期间同 clientId 的 hello 走 `resumeSession`（`:1870-1913`），重新下发 `server_info`。
- 同一逻辑会话可同时挂多个物理 socket（多标签页、直连 + relay 并存，`docs/architecture.md:278`）。
- 恢复的只是 Daemon 侧的 Session 对象（agent 管理等服务端状态）；**订阅、终端 attach、进行中的操作都属于物理 socket**，旧 socket 断开即释放（`docs/architecture.md:268-272`，`docs/connected-hosts.md:99-100`；`websocket-server.ts:2242-2244` 清理该 socket 的 timeline 订阅）。

### 5.4 重连后必须重新请求的状态

客户端视角（`daemon-client.ts:7163-7176` 在 connected 时执行）：

1. 重新读取 `server_info.features`（能力可能因 Daemon 升级而变化）。
2. 重建所有订阅（owned subscriptions：重新发起带 `subscribe`/`observe` 的列表请求，拿到**新的** `subscriptionId`；旧 ID 作废）——`owned.restore(...)`，`packages/client/src/connection/index.ts:33-56`，`docs/protocol-compatibility.md:51-53`。
3. 重新拉取列表快照（agents、workspaces、projects 等），因为断线期间的推送已丢失。
4. 重新 attach 终端流（slot 已清空）、重新订阅正在查看的 agent timeline。
5. 恢复进行中的创建流程（`creations.reconnect()`，基于幂等键/requestId）。
6. 发送断线期间排队的请求；对 `outcome: "unknown"` 的变更先查询再决定是否重试。
7. 推送 token、`client_heartbeat`（前台/焦点状态）等「每连接」状态重新上报（**未确认**是否必须每次重报；官方 App 由上层定期发送 `client_heartbeat`，`daemon-client.ts:2370-2387`）。

---

## 6. App 层消息信封

### 6.1 顶层信封（JSON 文本帧）

`messages.ts:7651-7733`

| 方向 | `type` | 形状 |
| --- | --- | --- |
| C→S | `hello` | §4.2 |
| C→S | `ping` | `{"type":"ping"}` |
| C→S | `recording_state` | `{"type":"recording_state","isRecording":bool}`（语音用） |
| C→S | `session` | `{"type":"session","message":<SessionInboundMessage>}` |
| S→C | `pong` | `{"type":"pong"}` |
| S→C | `session` | `{"type":"session","message":<SessionOutboundMessage>}` |
| S→C | `hello.rejected` | §4.4 |

### 6.2 Session 消息与 RPC 关联

- 请求：参数平铺在 message 顶层，带 `requestId`：
  `{"type":"session","message":{"type":"fetch_agents_request","requestId":"<uuid>", …}}`
- 响应：结果在 `payload` 下，`payload.requestId` 原样回带：
  `{"type":"session","message":{"type":"fetch_agents_response","payload":{"requestId":"<uuid>", …}}}`（例：`messages.ts:4269-4278`）
- 命名：旧的扁平名 `xxx_request` / `xxx_response`；新 RPC 用点分命名空间 `domain.ns.verb.request` / `.response`（`docs/rpc-namespacing.md:1-65`）。客户端把 `type` 以 `_response` / `.response` / `/response` 结尾或为 `rpc_error` 的消息视为关联响应（`daemon-client.ts:295-330`）。新式响应类型可由请求类型机械推导（`.request` → `.response`，`daemon-client.ts:2271-2292`）。
- 流式 RPC：可在终结 `.response` 之前发若干 `.update`，共享同一 `requestId`（`docs/rpc-namespacing.md:28-32`）。
- 通用错误：`{"type":"rpc_error","payload":{"requestId","requestType"?,"error","code"?}}`（`messages.ts:3868-3876`）。Daemon 不认识的 session 消息类型 → `code:"unknown_schema"`（提示升级 Daemon）；校验失败 → `code:"invalid_message"`（`websocket-server.ts:2337-2390`）。客户端等待时同时匹配 `rpc_error` 与目标响应（`daemon-client.ts:2162-2210`）。
- `requestId`：官方用 `crypto.randomUUID()`（`daemon-client.ts:6568-6570`），任意唯一字符串即可。
- 默认 RPC 超时 60 s（`daemon-client.ts:1091`，`docs/architecture.md:280`）。
- 服务器推送（无 requestId）：`{"type":"session","message":{"type":"agent_update","payload":{…}}}`、`agent_stream`、`workspace_update`、`agent_permission_request` 等（`docs/architecture.md:285-299`）。基于订阅的推送在 payload 里带 `subscriptionId` 用于路由（`packages/client/src/connection/owned.ts:190-206`）。
- Session 消息联合：入站 `SessionInboundMessageSchema`（`messages.ts:3254`），出站 `SessionOutboundMessageSchema`（`messages.ts:6955`）。

### 6.3 二进制帧（App 层）

与 JSON 共用同一 WebSocket（relay 下为 `kind=binary` 的受保护记录）。首字节为 opcode（`packages/protocol/src/binary-frames/`）：

| opcode | 用途 |
| --- | --- |
| `0x01`–`0x05` | 终端流：Output / Input / Resize / Snapshot / Restore，第 2 字节为 slot（`terminal.ts:10-16`） |
| `0x10`–`0x12` | 文件传输：FileBegin / FileChunk / FileEnd（`file-transfer.ts:4-8`） |
| `0x30` | 守护进程间 host 路由帧（`host-route.ts:3`），客户端可先忽略 |

客户端分发顺序见 `daemon-client.ts:6798-6866`。细节留给终端/文件文档。

---

## 7. 版本兼容规则

`docs/protocol-compatibility.md`，`docs/architecture.md:326-339`

1. **协议契约：永远兼容。** Schema 只增不减：新字段一律可选；不得把可选改必填、删除字段或收窄类型（`string`→`enum`、nullable→non-null 都算收窄）。旧 App 必须能解析新 Daemon 的消息，反之亦然（`protocol-compatibility.md:9-27`）。
   ⇒ Swift 解码必须**宽松**：忽略未知字段；未知 `type` 的消息丢弃而不是报错；枚举字段要有 `unknown` 兜底。
2. **功能契约：按能力门控一次。** 新功能依赖 `server_info.features.*` 布尔旗标；缺少旗标就提示「请升级 Daemon」，不做降级模拟（`protocol-compatibility.md:31-41`）。已有功能（读历史、终端等）永不被新能力门控。
3. **反向门控：** Daemon 只在客户端在 hello 里声明了对应 `CLIENT_CAPS` 时才发送新的枚举值/新消息形状（`architecture.md:328-339`）。所以 Swift 客户端**只声明自己真正能解析的能力**。能力按物理 socket 计算，不跨 socket 借用。
4. `protocolVersion`：文档写「取客户端与 Daemon 最大值中较小者」（`protocol-compatibility.md:13`），但 v0.14.0 代码中双方都写死 `1`，Daemon 只拒绝 `< 1`，`server_info.protocolVersion` 恒为 1（`websocket-server.ts:510,1692,1938`）。实际版本差异全靠 features/capabilities 处理。
5. `hello.rejected` 只发给声明了 `hello_rejection` 或带了 `auth` 的客户端，旧客户端只看 close code（`protocol-compatibility.md:13`）。
6. Relay E2EE：两侧都新 → `protected`；一侧旧 → `legacy`（Daemon 可用 `daemon.relay.requireProtectedSecurity` 禁止）。出现 `protected` 字段但非法时绝不回退（`relay-endpoint-security.md:45-76`）。
7. 所有兼容垫片都带 `COMPAT(name): added in vX, remove after <date>` 注释（`protocol-compatibility.md:85-99`），`rg "COMPAT\("` 可列出全部；Swift 端如需对旧 Daemon 兼容，按这些标签判断何时可删。

---

## 8. 最小连接清单（Swift 原型：经 relay 发出第一个 RPC）

**准备**

- [ ] 解析配对链接（§1.3），得到 `serverId`、`daemonPublicKey`(32B)、`relayEndpoint`、`useTls`、可选 `password`；严格校验公钥 base64。
- [ ] 生成并持久化 `clientId`（如 `cid_<uuid 无连字符>`）。

**L1 WebSocket**

- [ ] `URLSessionWebSocketTask` 连接 `wss://<relayEndpoint>/ws?serverId=<serverId>&role=client&v=2`（不带 connectionId、不带任何凭据/子协议）。
- [ ] 同时处理文本帧与二进制帧。启动 15 s 总连接超时。

**L2 Noise NK**

- [ ] 实现 CipherState / SymmetricState / NK HandshakeState（§3.3），先用 `nk-25519-chachapoly-sha256.json` 两组向量跑通单测（§3.11）。
- [ ] Prologue = `"paseo-relay-e2ee/1"`，`rs` = daemon 公钥；msg1 payload = `[0x01, 0x01]`（提供 binaryCiphertext；daemon 回 `0x00` 时整条通道退回 base64 文本）。
- [ ] 生成一把独立 X25519 临时公钥填 `key`。
- [ ] 构造 `e2ee_hello` JSON **一次**，WS open 后立即发送，并每 1 s 重发同一字符串直到收到 ready。
- [ ] 只接受文本帧里 `type=="e2ee_ready"` 的 JSON；必须含 `protected.v==1`；base64 解 msg2 → `readMessage` → 校验参数 payload（2 字节、0x01、无保留位、未选未提供的位）→ `split()`。没有 `protected` → 以 4002 关闭（拒绝 legacy）。
- [ ] 实现受保护记录编解码（§3.6）：发送 = 编码 → base64 → WS 文本帧；接收 = 文本帧（若以 `{` 开头：`e2ee_ready` 忽略，其它 JSON → 关闭 4003）base64 解码 / 二进制帧原样 → 解码 → 按 `kind` 交给 App 层。任何错误 → 以 4003 关闭并清除密钥。
- [ ] 发送 counter 在加密时同步自增（Swift 用 actor 或串行队列保证不并发复用 nonce）。

**L3 App 握手**

- [ ] 安全通道打开后立即加密发送：
  `{"type":"hello","clientId":"…","clientType":"mobile","protocolVersion":1,"capabilities":{"hello_rejection":true},"appVersion":"…"[,"auth":{"kind":"password","password":"…"}]}`
- [ ] 等第一条 `{"type":"session","message":{"type":"status","payload":{"status":"server_info",…}}}`：核对 `serverId`；保存 `features`；状态置为 connected；重置退避计数。
- [ ] 若先收到 `hello.rejected`：`password_required`/`incorrect_password` → 提示输入密码、停止自动重连；`incompatible_protocol` → 提示升级。

**L4 第一个 RPC 与保活**

- [ ] 发送 session ping：`{"type":"session","message":{"type":"ping","requestId":"<uuid>","clientSentAt":<epoch ms>}}`，等待 `message.type=="pong"` 且 `payload.requestId` 匹配（或 `rpc_error` 同 requestId）。拿到即证明整条链路可用。
- [ ] connected 后 10 s 开始每 10 s 发 `{"type":"ping"}`，15 s 超时，连续 2 次失败重连；任何有效入站消息清零失败计数。
- [ ] 断线 → 失败所有挂起请求 → `min(1500·2^n, 30000)` ms 退避 → 全新 WS + 全新 Noise + 全新 hello（同一 clientId）。

---

## 9. 未确认事项汇总

1. 生产 Elixir relay（`getpaseo/paseo-relay`，不在仓库）与 Cloudflare 实现在 URL 参数、帧缓存上限、1012 替换关闭码、客户端 socket 空闲超时、WS 协议层 ping 响应上的一致性。
2. CryptoKit `sharedSecretFromKeyAgreement` 对低阶/全零公钥是否自行抛错（实现中显式检查全零即可规避）。
3. `protocol-compatibility.md` 所述的 protocolVersion「取较小值」协商在 v0.14.0 代码中没有体现（双方恒为 1）。
4. 重连后 `client_heartbeat`、push token 是否必须每个物理连接重新上报（官方由 App 上层周期性发送，未在连接层强制）。
5. 服务端 `ExternalSocketMetadata.externalSessionKey = "session:<connectionId>"`（`relay-transport.ts:373-376`）在 v0.14.0 是否仍参与会话键计算；从 `handleHello` 看实际恢复键是 `(principalId, clientId)`，relay connectionId 每次重连都会变，因此恢复只依赖 clientId。
