// Connects to a daemon through the relay and runs a few read-only requests.
//
//   PASEO_PAIRING='<pairing link>' [PASEO_PASSWORD=…] swift run paseo-probe
//
// The pairing link and password come from the environment so they never show up in argv or output.

import Foundation
import PaseoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
guard let link = env["PASEO_PAIRING"], !link.isEmpty else { fail("set PASEO_PAIRING to a pairing link") }
var offer: PairingOffer
do { offer = try PairingOffer.parse(link) } catch { fail("pairing link: \(error)") }
if let pw = env["PASEO_PASSWORD"], !pw.isEmpty { offer.password = pw }
print("relay   \(offer.relayEndpoint) tls=\(offer.useTls) offerPinsProtected=\(offer.requireProtected) password=\(offer.password != nil)")

let hello = HelloOptions(clientId: "cid_probe" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                         password: offer.password, appVersion: "paseo-native-probe/0.1")
let started = Date()
let connection: DaemonConnection
do {
    connection = try await DaemonConnection.connect(offer: offer, hello: hello)
} catch let error as DaemonConnectionError where error.isAuthFailure {
    fail("\(error) — set PASEO_PASSWORD")
} catch {
    fail("connect: \(error)")
}
let info = await connection.serverInfo!
print(String(format: "connected in %.0f ms → %@ (paseo %@)", Date().timeIntervalSince(started) * 1000,
             info.hostname ?? "?", info.version ?? "?"))
print("features \(info.features.filter { $0.value.boolValue == true }.keys.sorted().joined(separator: " "))")

do {
    let sent = (Date().timeIntervalSince1970 * 1000).rounded()
    _ = try await connection.request("ping", ["clientSentAt": .number(sent)], timeout: .seconds(5))
    print(String(format: "rpc ping %.0f ms", Date().timeIntervalSince1970 * 1000 - sent))

    let agents = try await connection.request("fetch_agents_request", [
        "sort": [["key": "updated_at", "direction": "desc"]],
        "page": ["limit": 10],
    ])
    let payload = agents["payload"]?.objectValue ?? [:]
    print("fetch_agents_response keys: \(payload.keys.sorted().joined(separator: ", "))")
    let list = payload.values.compactMap(\.arrayValue).first ?? []
    for entry in list {
        let agent = entry["agent"] ?? entry
        let title = agent["title"]?.stringValue ?? "(untitled)"
        let status = agent["status"]?.stringValue ?? "?"
        let id = agent["id"]?.stringValue.map { String($0.prefix(8)) } ?? "?"
        print("  \(id)  \(status.padding(toLength: 8, withPad: " ", startingAt: 0))  \(title)")
    }
} catch {
    fail("\(error)")
}
await connection.close()

// PASEO_BYTES=<absolute file path>: the same requests (fetch_agents + a binary file read of that path) with and without
// binaryCiphertext, counting relay wire bytes in each direction.
if let bytesPath = env["PASEO_BYTES"], !bytesPath.isEmpty {
    final class CountingTransport: FrameTransport, @unchecked Sendable {
        let inner: WebSocketTransport
        let lock = NSLock()
        var sent = 0, received = 0, binaryIn = 0, textIn = 0
        init(_ url: URL) { inner = WebSocketTransport(url: url) }
        func snapshot() -> (sent: Int, received: Int, textIn: Int, binaryIn: Int) {
            lock.withLock { (sent, received, textIn, binaryIn) }
        }
        func add(_ f: WireFrame, outbound: Bool) {
            lock.lock(); defer { lock.unlock() }
            switch f {
            case .text(let s): if outbound { sent += s.utf8.count } else { received += s.utf8.count; textIn += 1 }
            case .binary(let d): if outbound { sent += d.count } else { received += d.count; binaryIn += 1 }
            }
        }
        func send(_ frame: WireFrame) async throws { add(frame, outbound: true); try await inner.send(frame) }
        func receive() async throws -> WireFrame { let f = try await inner.receive(); add(f, outbound: false); return f }
        func close(code: Int, reason: String) async { await inner.close(code: code, reason: reason) }
    }
    let dir = (bytesPath as NSString).deletingLastPathComponent, name = (bytesPath as NSString).lastPathComponent
    for offerBinary in [false, true] {
        let t = CountingTransport(try offer.relayWebSocketURL())
        let c = try await DaemonConnection.connect(offer: offer, hello: HelloOptions(clientId: hello.clientId, password: hello.password,
                                                                                    appVersion: hello.appVersion, capabilities: HostStore.capabilities),
                                                   transport: t, offerBinaryCiphertext: offerBinary)
        _ = try await c.request("fetch_agents_request", ["sort": [["key": "updated_at", "direction": "desc"]], "page": ["limit": 50]])
        let jsonIn = t.snapshot().received
        // Binary read: FileBegin/FileChunk…/FileEnd frames carrying this request id.
        final class Got: @unchecked Sendable { var bytes = 0; var done: CheckedContinuation<Void, Never>? }
        let got = Got()
        let requestId = UUID().uuidString.lowercased()
        await c.setBinaryHandler { f in
            guard f.count > 2, [0x10, 0x11, 0x12].contains(f[0]) else { return }
            let header = 2 + Int(f[1])
            if f[0] == 0x11 { got.bytes += f.count - header }
            if f[0] == 0x12 { got.done?.resume(); got.done = nil }
        }
        let req = try JSONValue.object(["type": "session", "message": [
            "type": "file_explorer_request", "requestId": .string(requestId), "cwd": .string(dir), "path": .string(name),
            "mode": "file", "acceptBinary": true, "maxBytes": .number(64 * 1024 * 1024),
        ]]).serialized()
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            got.done = k
            Task { try? await c.sendRaw(req) }
        }
        let n = t.snapshot()
        print("offerBinary=\(offerBinary) negotiated=\(c.binaryCiphertext)  sent=\(n.sent)B  recv=\(n.received)B (fetch_agents 后 \(jsonIn)B, 文件读取 \(n.received - jsonIn)B 载荷 \(got.bytes)B)  入站帧 text=\(n.textIn) binary=\(n.binaryIn)")
        await c.close()
    }
    exit(0)
}

// PASEO_PUSH=<seconds>: run the full HostStore idle (or watching PASEO_PUSH_WATCH=<agent prefix>, as an open session
// does) and count server pushes by type.
if let secs = env["PASEO_PUSH"].flatMap(Double.init) {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    while store.state != .connected {
        if case .failed(let m, _) = store.state { fail(m) }
        try? await Task.sleep(for: .milliseconds(100))
    }
    try? await Task.sleep(for: .seconds(2))
    let baseline = store.pushCounts
    var watcher: Task<Void, Never>?
    if let w = env["PASEO_PUSH_WATCH"], !w.isEmpty {
        guard let a = store.agents.values.first(where: { $0.id.hasPrefix(w) }) else { fail("no agent \(w)") }
        print("watch   \(a.id.prefix(8)) \(a.status.rawValue) \(a.displayTitle.prefix(30))")
        watcher = Task { await store.watchProviderSubagents(a.id) }
        let started = Date()
        var last = ""
        while Date().timeIntervalSince(started) < secs {
            try? await Task.sleep(for: .seconds(1))
            let subs = store.providerSubagents(of: a.id)
            let line = "subscribed=\(store.receivesProviderSubagentPushes) subagents=" + subs.map { "\($0.label.prefix(16)):\($0.status)" }.joined(separator: ", ")
            if line != last { print(String(format: "%5.1fs ", Date().timeIntervalSince(started)) + line); last = line }
        }
    } else if let w = env["PASEO_PUSH_TRACK"], !w.isEmpty {
        // Not watched: what the sidebar / Live Activity see (agent status + cached subagents) for sessions matching w.
        let started = Date()
        var last = ""
        while Date().timeIntervalSince(started) < secs {
            try? await Task.sleep(for: .seconds(1))
            let line = store.agents.values.filter { $0.id.hasPrefix(w) || $0.title?.hasPrefix(w) == true }.map { a in
                "\(a.id.prefix(8)) \(a.status.rawValue) subagents=" + store.providerSubagents(of: a.id).map { "\($0.label.prefix(16)):\($0.status)" }.joined(separator: ",")
            }.joined(separator: " | ") + " subscribed=\(store.receivesProviderSubagentPushes)"
            if line != last { print(String(format: "%5.1fs ", Date().timeIntervalSince(started)) + line); last = line }
        }
    } else {
        try? await Task.sleep(for: .seconds(secs))
    }
    let counts = store.pushCounts.mapValues { $0 }.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - (baseline[$1.key] ?? 0) }
        .filter { $0.value > 0 }
    print("pushes in \(Int(secs)) s:")
    for (k, v) in counts.sorted(by: { $0.value > $1.value }) { print("  \(k.padding(toLength: 40, withPad: " ", startingAt: 0)) \(v)") }
    print("provider_subagents.update = \(counts["agent.provider_subagents.update"] ?? 0)  subscribed=\(store.receivesProviderSubagentPushes)")
    watcher?.cancel()
    try? await Task.sleep(for: .seconds(1))
    print("after unwatch: subscribed=\(store.receivesProviderSubagentPushes)")
    store.stop()
    exit(0)
}

// PASEO_WATCH=<agentId prefix>: run the full HostStore (subscriptions + timeline sync) for 20 s.
if let watch = env["PASEO_WATCH"], !watch.isEmpty {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    while store.state != .connected {
        if case .failed(let m, _) = store.state { fail(m) }
        try? await Task.sleep(for: .milliseconds(100))
    }
    print("store   agents=\(store.agents.count) workspaces=\(store.workspaces.count) projects=\(store.projects.count)")
    for a in store.agents.values.sorted(by: { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) {
        print("  \(a.id.prefix(8)) \(a.status.rawValue) sub=\(a.isSubagent) arch=\(a.archivedAt != nil) ws=\(a.workspaceId.map { String($0.prefix(10)) } ?? "nil") \(a.displayTitle.prefix(24))")
    }
    guard let agent = store.agents.values.first(where: { $0.id.hasPrefix(watch) }) else { fail("no agent \(watch)") }
    print("open    \(agent.displayTitle) [\(agent.status.rawValue), \(agent.bucket.rawValue)]")
    store.openTimeline(agent.id)
    var lastCount = -1
    for _ in 0..<200 {
        try? await Task.sleep(for: .milliseconds(100))
        let rows = store.timelines[agent.id]?.rows ?? []
        if rows.count != lastCount {
            lastCount = rows.count
            let t = store.timelines[agent.id]
            print("rows=\(rows.count) seq \(t?.startSeq ?? -1)…\(t?.endSeq ?? -1) hasOlder=\(t?.hasOlder ?? false)")
            for r in rows.suffix(3) {
                let kind: String
                switch r.item {
                case .userMessage(let s, _): kind = "user: " + s
                case .assistantMessage(let s, _): kind = "assistant: " + s
                case .reasoning(let s): kind = "thinking: " + s
                case .toolCall(_, let n, let st, _, _, _): kind = "tool \(n) \(st)"
                case .todo(let items): kind = "todo \(items.count)"
                default: kind = "\(r.item)"
                }
                print("   · " + kind.replacingOccurrences(of: "\n", with: " ").prefix(100))
            }
        }
    }
    store.stop()
}

// PASEO_EXTRAS=1: schedules and usage reports through HostStore.
if env["PASEO_EXTRAS"] == "1" {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    while store.state != .connected {
        if case .failed(let m, _) = store.state { fail(m) }
        try? await Task.sleep(for: .milliseconds(100))
    }
    do {
        let schedules = try await store.listSchedules()
        print("schedules \(schedules.count)")
        for s in schedules.prefix(5) { print("  \(s.id) \(s.status) \(s.isHeartbeat ? "heartbeat" : "schedule") \(s.cronExpression ?? "-") \(s.title.prefix(30))") }
    } catch { print("schedules error: \(error)") }
    do {
        var n = 0
        try await store.usageReports { r in
            n += 1
            let w = r.windows.map { "\($0.shortLabel ?? $0.label) \(Int($0.usedPct ?? -1))%" }.joined(separator: ", ")
            print("  usage \(r.sourceLabel) \(r.account ?? "") plan=\(r.planLabel ?? "-") \(w) \(r.problem ?? "")")
        }
        print("usage done")
    } catch { print("usage error: \(error)") }
    if let w = store.workspaces.values.first(where: { $0.isGit }) {
        let b = await store.branchSuggestions(cwd: w.directory, query: "")
        print("branches in \(w.name): " + b.prefix(6).map { "\($0.label)(\($0.detail))" }.joined(separator: ", "))
        let prs = await store.searchChangeRequests(cwd: w.directory, query: "")
        print("prs: \(prs.count)")
    }
    print("home: \(store.homeDirectory ?? "?")")
    let dirs = await store.pathSuggestions(cwd: nil, query: "~/projects/", includeFiles: false)
    print("~/projects/: " + dirs.prefix(5).map(\.path).joined(separator: ", "))
    if let w = store.workspaces.values.first(where: { $0.directory.hasSuffix("paseo-mesh") }) ?? store.workspaces.values.first {
        print("host pane on \(w.directory)")
        do {
            let entries = try await store.listDirectory(cwd: w.directory, path: ".")
            print("  ls: " + entries.prefix(8).map { $0.isDirectory ? $0.name + "/" : $0.name }.joined(separator: " "))
            if let f = entries.first(where: { !$0.isDirectory && $0.name.hasSuffix(".md") }) {
                let c = try await store.readFile(cwd: w.directory, path: f.path)
                print("  read \(f.path): \(c.kind) \(c.mimeType) \(c.size)B first line: \(c.text?.split(separator: "\n").first ?? "")")
            }
        } catch { print("  files error: \(error)") }
        await store.refreshCheckoutStatus(cwd: w.directory)
        if let st = store.checkoutStatus[w.directory] { print("  git: \(st.currentBranch ?? "-") dirty=\(st.isDirty) ahead=\(st.aheadOfOrigin) behind=\(st.behindOfOrigin)") }
        await store.subscribeDiff(cwd: w.directory, mode: "uncommitted")
        if let d = store.diffs[w.directory] { print("  diff: \(d.files.count) files " + d.files.prefix(3).map { "\($0.letter) \($0.path) +\($0.additions)-\($0.deletions)" }.joined(separator: ", ")) }
        do {
            let t = try await store.createTerminal(workspace: w, name: "probe")
            final class Box: @unchecked Sendable { var out = Data() }
            let box = Box()
            try await store.attachTerminal(t.id, cols: 100, rows: 30) { e in
                switch e { case .output(let d), .restore(let d): box.out.append(d); case .exited: break }
            }
            try? await Task.sleep(for: .milliseconds(800))
            store.sendTerminalInput(t.id, Data("echo PASEO_NATIVE_OK $((6*7))\r".utf8))
            try? await Task.sleep(for: .seconds(2))
            let text = String(decoding: box.out, as: UTF8.self)
            print("  terminal \(t.id.prefix(10)) got \(box.out.count)B, contains result: \(text.contains("PASEO_NATIVE_OK 42"))")
            store.detachTerminal(t.id)
            try await store.killTerminal(t.id, workspaceId: w.id)
            print("  terminal killed")
        } catch { print("  terminal error: \(error)") }
        await store.loadScripts(workspaceId: w.id)
        print("  scripts: \(store.scripts[w.id]?.map(\.name) ?? [])")
    }
    print("labels: \(store.labels.map { "\($0.name)(\($0.color))" })")
    print("config keys: \(store.daemonConfig?.objectValue?.keys.sorted().joined(separator: ",") ?? "nil")")
    print("terminal profiles: \(store.terminalProfiles.compactMap { $0["name"]?.stringValue })")
    do {
        let up = try await store.upload(fileName: "probe.txt", mimeType: "text/plain", data: Data(String(repeating: "hello paseo native\n", count: 20000).utf8))
        print("upload ok: \(up.id) \(up.fileName) \(up.size)B path=\(up.attachment["path"]?.stringValue ?? "?")")
    } catch { print("upload error: \(error)") }
    if let a = store.agents.values.first(where: { $0.id.hasPrefix("61d44d45") }) {
        await store.loadFullTimeline(a.id)
        print("full timeline rows: \(store.timelines[a.id]?.rows.count ?? 0)")
        await store.loadProviderSubagents(a.id)
        print("provider subagents: \(store.providerSubagents[a.id]?.count ?? -1)")
    }
    store.stop()
}

// PASEO_RAW=<agent prefix>: dump raw timeline items whose text is short, to inspect odd rows.
if let raw = env["PASEO_RAW"], !raw.isEmpty {
    // Same capabilities as the app, so plugin rows are included.
    let c = try await DaemonConnection.connect(offer: offer, hello: HelloOptions(clientId: hello.clientId, password: hello.password,
                                                                                appVersion: hello.appVersion, capabilities: HostStore.capabilities))
    let list = try await c.request("fetch_agents_request", ["page": ["limit": 200]])
    let id = (list["payload"]?["entries"]?.arrayValue ?? []).compactMap { $0["agent"]?["id"]?.stringValue }.first { $0.hasPrefix(raw) } ?? raw
    let r = try await c.request("fetch_agent_timeline_request", ["agentId": .string(id), "direction": "tail", "limit": 25, "projection": "projected"])
    for e in r["payload"]?["entries"]?.arrayValue ?? [] {
        let item = e["item"] ?? .null
        let t = item["text"]?.stringValue ?? ""
        let d = item["detail"]
        if item["type"]?.stringValue == "plugin" {
            print("PLUGIN", String(describing: item).prefix(300))
            // PASEO_PREDICT=1: ask next-input for this row's suggestion, as the app does when it shows it.
            if env["PASEO_PREDICT"] == "1", item["pluginId"]?.stringValue == "next-input", let token = item["data"]?["token"] {
                let out = try? await c.request("plugin.rpc.invoke.request", ["pluginId": "next-input", "method": "suggestions.predict",
                                                                            "input": ["agentId": .string(id), "token": token]], timeout: .seconds(45))
                print("PREDICT", String(describing: out?["payload"] ?? .null).prefix(400))
            }
        }
        print((e["timestamp"]?.stringValue ?? "-") + " | " + (item["type"]?.stringValue ?? "?") + " | " + (item["name"]?.stringValue ?? "") + " | " + (d?["type"]?.stringValue ?? "") + " | "
              + String((t.isEmpty ? (d?["label"]?.stringValue ?? d?["text"]?.stringValue ?? "") : t).prefix(60)).replacingOccurrences(of: "\n", with: " "))
    }
    await c.close()
}

// PASEO_RESOLVE=<base>|<relative path>: the app's nested-repo link lookup (exists? else a search hit ending with it).
if let spec = env["PASEO_RESOLVE"], let bar = spec.firstIndex(of: "|") {
    let base = String(spec[..<bar]), rel = String(spec[spec.index(after: bar)...])
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    for _ in 0..<40 where store.state != .connected { try await Task.sleep(for: .milliseconds(250)) }
    let abs = (base + "/" + rel as NSString).standardizingPath
    print("exists", abs, await store.fileExists(abs))
    let hits = await store.pathSuggestions(cwd: base, query: (rel as NSString).lastPathComponent)
    print("hits", hits.prefix(5).map(\.path))
    print("resolved", hits.first { !$0.isDirectory && ($0.path == rel || $0.path.hasSuffix("/" + rel)) }?.path ?? "-")
    store.stop()
}

// PASEO_PLUGIN_CALL=<pluginId>:<method>: invoke a plugin RPC with empty input and print the output.
if let call = env["PASEO_PLUGIN_CALL"], let sep = call.firstIndex(of: ":") {
    let c = try await DaemonConnection.connect(offer: offer, hello: HelloOptions(clientId: hello.clientId, password: hello.password,
                                                                                appVersion: hello.appVersion, capabilities: HostStore.capabilities))
    let r = try? await c.request("plugin.rpc.invoke.request", ["pluginId": .string(String(call[..<sep])), "method": .string(String(call[call.index(after: sep)...])),
                                                               "input": [:]], timeout: .seconds(30))
    print("CALL", String(describing: r?["payload"] ?? .null).prefix(800))
    await c.close()
}

// PASEO_SUBS=<agent id>: raw provider subagents and managed children (by parent label) of one agent.
if let parent = env["PASEO_SUBS"], !parent.isEmpty {
    let c = try await DaemonConnection.connect(offer: offer, hello: hello)
    let r = try await c.request("agent.provider_subagents.list.request", ["parentAgentId": .string(parent)])
    for s in r["payload"]?["subagents"]?.arrayValue ?? [] {
        var o = s.objectValue ?? [:]
        o.removeValue(forKey: "parentAgentId")
        print("provider", String(describing: JSONValue.object(o)).prefix(400))
    }
    // Same request the app makes when a subagent tab opens (needs the projected_subagent_timeline capability).
    if let sub = r["payload"]?["subagents"]?.arrayValue?.first?["id"]?.stringValue {
        let sc = try await DaemonConnection.connect(offer: offer, hello: HelloOptions(clientId: hello.clientId, password: hello.password, appVersion: hello.appVersion,
                                                                                      capabilities: HostStore.capabilities))
        let t = try await sc.request("agent.provider_subagents.timeline.get.request",
                                     ["parentAgentId": .string(parent), "subagentId": .string(sub), "direction": "tail", "limit": 200])
        let rows = t["payload"]?["rows"]?.arrayValue ?? []
        print("timeline of \(sub): \(rows.count) rows, error=\(t["payload"]?["error"]?.stringValue ?? "nil")")
        for row in rows.prefix(6) {
            print("  ", row["item"]?["type"]?.stringValue ?? "?", (row["item"]?["text"]?.stringValue ?? row["item"]?["name"]?.stringValue ?? "").prefix(80))
        }
        await sc.close()
    }
    let list = try await c.request("fetch_agents_request", ["page": ["limit": 200]])
    for e in list["payload"]?["entries"]?.arrayValue ?? [] {
        let a = e["agent"] ?? .null
        let labels = a["labels"]
        if a["parentAgentId"]?.stringValue == parent || labels?["paseo.parent-agent-id"]?.stringValue == parent {
            print("managed", a["id"]?.stringValue ?? "", a["status"]?.stringValue ?? "", a["archivedAt"]?.stringValue ?? "-",
                  a["parentAgentId"]?.stringValue ?? "-", labels.map { String(describing: $0) } ?? "", a["title"]?.stringValue ?? "")
        }
    }
    await c.close()
}

// PASEO_FORK=<agent id>: fork context up to the latest assistant message that has a messageId.
if let agentId = env["PASEO_FORK"], !agentId.isEmpty {
    let c = try await DaemonConnection.connect(offer: offer, hello: hello)
    let r = try await c.request("fetch_agent_timeline_request", ["agentId": .string(agentId), "direction": "tail", "limit": 40, "projection": "projected"])
    let mid = (r["payload"]?["entries"]?.arrayValue ?? []).compactMap { e -> String? in
        e["item"]?["type"]?.stringValue == "assistant_message" ? e["item"]?["messageId"]?.stringValue : nil
    }.last
    print("assistant messageId:", mid ?? "nil")
    for boundary in [mid, nil] {
        var params: [String: JSONValue] = ["agentId": .string(agentId)]
        if let boundary { params["boundaryMessageId"] = .string(boundary) }
        let f = try await c.request("agent.fork_context.request", params)
        let a = f["payload"]?["attachment"]
        print("boundary=\(boundary ?? "nil") type=\(a?["type"]?.stringValue ?? "-") keys=\(a?.objectValue?.keys.sorted() ?? []) error=\(f["payload"]?["error"]?.stringValue ?? "-")",
              "size=\(String(describing: a).count)")
    }
    await c.close()
}

// PASEO_GIT=<cwd>: PR status and branch commits.
if let cwd = env["PASEO_GIT"], !cwd.isEmpty {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    for _ in 0..<100 where store.state != .connected { try await Task.sleep(for: .milliseconds(100)) }
    await store.loadPrStatus(cwd: cwd)
    let pr = store.prStatus[cwd]
    print("pr auth=\(pr?.authState ?? "nil") forge=\(pr?.forge ?? "-") pr=\(pr?.pullRequest.map { "#\($0.number ?? 0) \($0.state) \($0.title) checks=\($0.checks.count) \($0.checksStatus ?? "-")" } ?? "none")")
    do {
        let cs = try await store.commits(cwd: cwd)
        print("commits: \(cs.count)")
        for c in cs.prefix(3) { print("  \(c.shortSha) remote=\(c.isOnRemote) files=\(c.files.count) \(c.subject.prefix(50))") }
        if let c = cs.first, let f = c.files.first {
            let d = try await store.commitFileDiff(cwd: cwd, sha: c.sha, path: f.path)
            print("  file diff \(f.path): lines=\(d?.lines.count ?? -1)")
        }
    } catch { print("commits error: \(error)") }
    store.stop()
}

// PASEO_MAINT=1: daemon status, diagnostics and provider diagnostic sizes (the pairing link is a secret: length only).
if env["PASEO_MAINT"] == "1" {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    for _ in 0..<100 where store.state != .connected { try await Task.sleep(for: .milliseconds(100)) }
    let st = try await store.daemonStatus()
    print("status version=\(st.version ?? "-") pid=\(st.pid ?? -1) started=\(st.startedAt.map { "\($0)" } ?? "-")")
    print("pairing link length:", (try? await store.pairingLink())?.count ?? -1)
    print("diagnostics chars:", (try? await store.diagnostics())?.count ?? -1)
    print("claude diagnostic chars:", (try? await store.providerDiagnostic("claude"))?.count ?? -1)
    try? await Task.sleep(for: .seconds(2))
    let withResume = store.agents.values.filter { $0.resumeCommand != nil }
    print("resume commands: \(withResume.count)/\(store.agents.count)", withResume.first.map { String($0.resumeCommand!.prefix(16)) + "…" } ?? "")
    if let sk = try? await store.skills("get_status") {
        print("skills state=\(sk.state) available=\(sk.available.count) installed=\(sk.installed.count) selected=\(sk.selected.map { "\($0.count)" } ?? "all") ops=\(sk.pendingOps.count)")
    }
    store.stop()
}

// PASEO_IMPORTABLE=<cwd or "all">: sessions started outside Paseo that could be imported (listing only).
if let where_ = env["PASEO_IMPORTABLE"], !where_.isEmpty {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    for _ in 0..<100 where store.state != .connected { try await Task.sleep(for: .milliseconds(100)) }
    do {
        let list = try await store.recentProviderSessions(cwd: where_ == "all" ? nil : where_, query: nil)
        print("importable: \(list.count)")
        for s in list.prefix(3) { print("  \(s.providerLabel) \(s.cwd) \(String((s.title ?? s.firstPrompt ?? "").prefix(40)))") }
    } catch { print("importable error: \(error)") }
    store.stop()
}

// PASEO_DIRECT=host:port: direct WebSocket (no relay); prints the daemon's server id and agent count.
if let ep = env["PASEO_DIRECT"], !ep.isEmpty {
    let probe = PairingOffer.direct(serverId: "", endpoint: ep, useTls: false, password: env["PASEO_PASSWORD"])
    let c = try await DaemonConnection.connectDirect(url: probe.directWebSocketURL(), hello: hello, expectedServerId: "")
    let info = await c.serverInfo
    let list = try await c.request("fetch_agents_request", ["page": ["limit": 200]])
    print("direct ok serverId=\(info?.serverId ?? "?") version=\(info?.version ?? "?") agents=\(list["payload"]?["entries"]?.arrayValue?.count ?? -1)")
    await c.close()
}

// PASEO_PLUGINS=1: plugin list, settings, RPC, plugin timeline rows.
if env["PASEO_PLUGINS"] == "1" {
    let store = HostStore(offer: offer, label: "probe", clientId: hello.clientId, appVersion: "paseo-native-probe/0.1")
    store.start()
    while store.state != .connected { try? await Task.sleep(for: .milliseconds(100)) }
    try? await Task.sleep(for: .milliseconds(500))
    for p in store.plugins { print("plugin \(p.id) \(p.status) \(p.error.map { String($0.prefix(60)) } ?? "")") }
    if let s = try? await store.readPluginSettings("title-style", "title-style") { print("title-style settings: \(s.values.keys.sorted()) rev=\(s.revision.prefix(8))") }
    if let s = try? await store.readPluginSettings("next-input", "preferences") { print("next-input settings: \(s.values)") }
    if let s = try? await store.readPluginSettings("usage-reset", "sidebar") { print("usage-reset settings: \(s.values)") }
    do { print("board.locate: \(try await store.invokePlugin("agent-taskboard", "board.locate", ["paths": [.string(FileManager.default.currentDirectoryPath)]]))") }
    catch { print("board error \(error)") }
    if let a = store.agents.values.first(where: { $0.id.hasPrefix("61d44d45") }) {
        await store.loadFullTimeline(a.id)
        let pluginRows = (store.timelines[a.id]?.rows ?? []).compactMap { r -> String? in
            if case .plugin(_, let pid, let kind, _, let data) = r.item { return "\(pid)/\(kind) \(data)" } else { return nil }
        }
        print("plugin rows: \(pluginRows.count)"); pluginRows.suffix(3).forEach { print("  " + $0.prefix(200)) }
    }
    store.stop()
}
