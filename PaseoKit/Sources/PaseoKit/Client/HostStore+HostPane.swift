// Files, git, terminals and scripts on a host. See docs/protocol/03-files-git-terminal.md.

import Foundation

struct FileTransfer {
    var mime = ""
    var size = 0
    var encoding = ""
    var revision: String?
    var data = Data()
    var started = false
    let path: String
    let continuation: CheckedContinuation<FileContent, Error>
}

extension HostStore {
    // MARK: Binary frames

    func resetHostPaneStreams() {
        terminalSlots.removeAll()
        terminalStreamSubs.removeAll()
        terminalListSubs.removeAll()
        diffSubs.removeAll()
        for (_, t) in fileTransfers { t.continuation.resume(throwing: ActionError.rejected("连接已断开")) }
        fileTransfers.removeAll()
    }

    func handleBinary(_ frame: Data) {
        let b = [UInt8](frame)
        guard b.count >= 2 else { return }
        switch b[0] {
        case 0x01, 0x05:
            guard let terminalId = terminalSlots[Int(b[1])], let sink = terminalSinks[terminalId] else { return }
            let payload = Data(b[2...])
            sink(b[0] == 0x01 ? .output(payload) : .restore(payload))
        case 0x10, 0x11, 0x12:
            let len = Int(b[1])
            guard len > 0, b.count >= 2 + len, let requestId = String(bytes: b[2..<(2 + len)], encoding: .utf8),
                  var t = fileTransfers[requestId] else { return }
            let rest = b[(2 + len)...]
            switch b[0] {
            case 0x10:
                guard rest.count >= 2 else { return }
                let m = Int(rest[rest.startIndex]) << 8 | Int(rest[rest.startIndex + 1])
                let json = Data(rest.dropFirst(2).prefix(m))
                let meta = try? JSONDecoder().decode(JSONValue.self, from: json)
                t.mime = meta?["mime"]?.stringValue ?? "application/octet-stream"
                t.size = Int(meta?["size"]?.doubleValue ?? 0)
                t.encoding = meta?["encoding"]?.stringValue ?? "binary"
                t.revision = meta?["revision"]?.stringValue
                t.started = true
                t.data.reserveCapacity(t.size)
                fileTransfers[requestId] = t
            case 0x11:
                t.data.append(contentsOf: rest)
                fileTransfers[requestId] = t
            default:
                fileTransfers[requestId] = nil
                guard t.data.count == t.size else {
                    t.continuation.resume(throwing: ActionError.rejected("文件传输不完整"))
                    return
                }
                let kind: FileContent.Kind = t.mime.hasPrefix("image/") ? .image
                    : (t.encoding == "utf-8" || t.mime.hasPrefix("text/") || t.mime == "application/json") ? .text : .binary
                t.continuation.resume(returning: FileContent(path: t.path, kind: kind, mimeType: t.mime, data: t.data, size: t.size, revision: t.revision))
            }
        default:
            break
        }
    }

    /// Pushes that belong to the host pane (called from the main push handler).
    func handleHostPane(_ type: String, _ p: JSONValue) {
        switch type {
        case "file_explorer_response":
            // Binary reads only get a JSON reply on failure (or from an old daemon without binary support).
            guard let requestId = p["requestId"]?.stringValue, let t = fileTransfers.removeValue(forKey: requestId) else { return }
            if let e = p["error"]?.stringValue {
                t.continuation.resume(throwing: ActionError.rejected(e))
            } else if let f = p["file"], f != .null {
                let enc = f["encoding"]?.stringValue
                let content = f["content"]?.stringValue ?? ""
                let data = enc == "base64" ? (Data(base64Encoded: content) ?? Data()) : Data(content.utf8)
                let kind: FileContent.Kind = f["kind"]?.stringValue == "image" ? .image : f["kind"]?.stringValue == "binary" ? .binary : .text
                t.continuation.resume(returning: FileContent(path: t.path, kind: kind, mimeType: f["mimeType"]?.stringValue ?? "",
                                                             data: data, size: Int(f["size"]?.doubleValue ?? 0), revision: f["revision"]?.stringValue))
            } else {
                t.continuation.resume(throwing: ActionError.rejected("读取失败"))
            }
        case "checkout_status_update":
            if let cwd = p["cwd"]?.stringValue {
                checkoutStatus[cwd] = CheckoutStatus(p)
                if let pr = p["prStatus"], pr != .null { prStatus[cwd] = PrStatus(pr) }
            }
        case "checkout_diff_update":
            if let cwd = p["cwd"]?.stringValue, diffSubs[cwd]?.id == p["subscriptionId"]?.stringValue { diffs[cwd] = CheckoutDiff(p) }
        case "terminals_changed":
            if let ws = p["workspaceId"]?.stringValue { terminals[ws] = (p["terminals"]?.arrayValue ?? []).compactMap(TerminalInfo.init) }
        case "terminal_stream_exit":
            guard let terminalId = p["terminalId"]?.stringValue else { return }
            terminalSlots = terminalSlots.filter { $0.value != terminalId }
            terminalStreamSubs[terminalId] = nil
            terminalSinks[terminalId]?(.exited(error: p["error"]?.stringValue))
        case "workspace.label.update":
            if p["kind"]?.stringValue == "remove", let name = p["name"]?.stringValue {
                labels.removeAll { $0.name.lowercased() == name.lowercased() }
            } else if let l = p["label"].flatMap(WorkspaceLabel.init) {
                let prev = (p["previousName"]?.stringValue ?? l.name).lowercased()
                labels.removeAll { $0.name.lowercased() == prev || $0.id == l.id }
                labels.append(l)
            }
        case "status":
            switch p["status"]?.stringValue {
            case "daemon_config_changed": daemonConfig = p["config"]
            case "plugin_catalog_changed": Task { await loadPlugins() }
            case "plugin_settings_changed":
                let key = (p["pluginId"]?.stringValue ?? "") + "/" + (p["settingsId"]?.stringValue ?? "")
                pluginSettingsRevision[key, default: 0] += 1
            default: break
            }
        case "agent.provider_subagents.update":
            guard let parent = p["parentAgentId"]?.stringValue ?? p["subagent"]?["parentAgentId"]?.stringValue else { return }
            switch p["kind"]?.stringValue {
            case "upsert":
                if let s = p["subagent"].flatMap(ProviderSubagent.init) {
                    providerSubagents[parent, default: []].removeAll { $0.id == s.id }
                    if !s.isFinished { hiddenProviderSubagents.remove(s.id) }
                    providerSubagents[parent, default: []].append(s)
                    if s.isFinished { reconcileProviderSubagentSubscription() }
                }
            case "remove":
                if let id = p["subagentId"]?.stringValue { providerSubagents[parent]?.removeAll { $0.id == id } }
                reconcileProviderSubagentSubscription()
            case "timeline":
                if let id = p["subagentId"]?.stringValue { applyProviderSubagentStream(parent, id, p) }
            default: break
            }
        case "script_status_update":
            if let ws = p["workspaceId"]?.stringValue { scripts[ws] = (p["scripts"]?.arrayValue ?? []).compactMap(WorkspaceScript.init) }
        case "workspace_setup_progress":
            if let ws = p["workspaceId"]?.stringValue { setupStatus[ws] = WorktreeSetup(p) }
        default:
            break
        }
    }

    // MARK: Files

    /// Whether `absolutePath` exists, by listing its parent directory.
    public func fileExists(_ absolutePath: String) async -> Bool {
        let dir = (absolutePath as NSString).deletingLastPathComponent, name = (absolutePath as NSString).lastPathComponent
        guard let entries = try? await listDirectory(cwd: dir, path: ".") else { return false }
        return entries.contains { $0.name == name }
    }

    public func listDirectory(cwd: String, path: String) async throws -> [FileEntry] {
        let r = try await conn().request("file_explorer_request", ["cwd": .string(cwd), "path": .string(path), "mode": "list"])
        if let e = r["payload"]?["error"]?.stringValue { throw ActionError.rejected(e) }
        return (r["payload"]?["directory"]?["entries"]?.arrayValue ?? []).compactMap(FileEntry.init)
    }

    /// Reads a file over binary frames (0x10/0x11/0x12); a JSON reply only arrives on error.
    public func readFile(cwd: String, path: String, maxBytes: Int = 64 * 1024 * 1024) async throws -> FileContent {
        let c = try conn()
        let requestId = UUID().uuidString.lowercased()
        let text = try JSONValue.object(["type": "session", "message": [
            "type": "file_explorer_request", "requestId": .string(requestId), "cwd": .string(cwd), "path": .string(path),
            "mode": "file", "acceptBinary": true, "maxBytes": .number(Double(maxBytes)),
        ]]).serialized()
        return try await withCheckedThrowingContinuation { cont in
            fileTransfers[requestId] = FileTransfer(path: path, continuation: cont)
            Task {
                do { try await c.sendRaw(text) } catch {
                    fileTransfers.removeValue(forKey: requestId)?.continuation.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(120))
                fileTransfers.removeValue(forKey: requestId)?.continuation.resume(throwing: ActionError.rejected("读取超时"))
            }
        }
    }

    // MARK: Git

    public func refreshCheckoutStatus(cwd: String) async {
        guard let r = try? await connection?.request("checkout_status_request", ["cwd": .string(cwd)]), let p = r["payload"] else { return }
        checkoutStatus[cwd] = CheckoutStatus(p)
    }

    /// Subscribes to the diff for `cwd` ("uncommitted" or "base"); later snapshots replace `diffs[cwd]`.
    /// `mode`: uncommitted, base or all (needs `checkoutDiffAll`).
    public func subscribeDiff(cwd: String, mode: String, ignoreWhitespace: Bool = false) async {
        let key = mode + (ignoreWhitespace ? "+ws" : "")
        if let old = diffSubs[cwd] {
            if old.mode == key { return }
            diffSubs[cwd] = nil
            _ = try? await connection?.request("subscription.release.request", ["subscriptionId": .string(old.id)])
        }
        var compare: [String: JSONValue] = ["mode": .string(mode)]
        if ignoreWhitespace { compare["ignoreWhitespace"] = true }
        guard let r = try? await connection?.request("subscribe_checkout_diff_request", ["cwd": .string(cwd), "compare": .object(compare)]),
              let p = r["payload"] else { return }
        if let id = p["subscriptionId"]?.stringValue {
            subscriptionIds.insert(id)
            diffSubs[cwd] = (id, key)
        }
        diffs[cwd] = CheckoutDiff(p)
    }

    public func unsubscribeDiff(cwd: String) async {
        guard let old = diffSubs.removeValue(forKey: cwd) else { return }
        _ = try? await connection?.request("subscription.release.request", ["subscriptionId": .string(old.id)])
    }

    /// commit / pull / push / refresh / discard — all reply `{success, error}`.
    public func gitAction(_ action: String, cwd: String, message: String? = nil, paths: [String] = []) async throws {
        let type: String
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        switch action {
        case "commit":
            type = "checkout_commit_request"
            params["addAll"] = true
            if let message, !message.isEmpty { params["message"] = .string(message) }
        case "pull": type = "checkout_pull_request"
        case "push": type = "checkout_push_request"
        case "refresh": type = "checkout.refresh.request"
        case "discard":
            type = "checkout.discard_changes.request"
            params["paths"] = .array(paths.map(JSONValue.string))
        case "mergeFromBase": type = "checkout_merge_from_base_request"
        case "mergeToBase": type = "checkout_merge_request"
        case "pullPush":
            try await gitAction("pull", cwd: cwd)
            try await gitAction("push", cwd: cwd)
            return
        default: return
        }
        let r = try await conn().request(type, params, timeout: .seconds(180))
        if r["payload"]?["success"]?.boolValue == false {
            throw ActionError.rejected(r["payload"]?["error"]?["message"]?.stringValue ?? r["payload"]?["error"]?.stringValue ?? "操作失败")
        }
        await refreshCheckoutStatus(cwd: cwd)
    }

    // MARK: Daemon maintenance

    /// Pairing link for adding this machine to another device. It is a key to the machine: show, never log.
    public func pairingLink() async throws -> String {
        let r = try await conn().request("daemon.get_pairing_offer.request")
        guard let url = r["payload"]?["url"]?.stringValue else { throw ActionError.rejected("拿不到配对链接") }
        return url
    }

    public struct DaemonStatus: Sendable {
        public let version: String?
        public let pid: Int?
        public let startedAt: Date?
        public let listen: String?
    }

    public func daemonStatus() async throws -> DaemonStatus {
        let p = try await conn().request("daemon.get_status.request")["payload"]
        return DaemonStatus(version: p?["version"]?.stringValue, pid: p?["pid"]?.doubleValue.map(Int.init),
                            startedAt: p?["startedAt"]?.dateValue, listen: p?["listen"]?.stringValue)
    }

    /// Updates the daemon package; returns "old → new". The daemon restarts afterwards and the client reconnects.
    public func updateDaemon() async throws -> String {
        let p = try await conn().request("daemon.update.request", timeout: .seconds(600))["payload"]
        if p?["success"]?.boolValue != true { throw ActionError.rejected(p?["error"]?.stringValue ?? "更新失败") }
        return (p?["previousVersion"]?.stringValue ?? "?") + " → " + (p?["newVersion"]?.stringValue ?? "?")
    }

    public func diagnostics() async throws -> String {
        try await conn().request("diagnostics.request", timeout: .seconds(60))["payload"]?["diagnostic"]?.stringValue ?? ""
    }

    public func providerDiagnostic(_ provider: String) async throws -> String {
        try await conn().request("provider_diagnostic_request", ["provider": .string(provider)], timeout: .seconds(60))["payload"]?["diagnostic"]?.stringValue ?? ""
    }

    public func refreshProviders(cwd: String?) async {
        var p: [String: JSONValue] = [:]
        if let cwd { p["cwd"] = .string(cwd) }
        _ = try? await connection?.request("refresh_providers_snapshot_request", p)
        try? await Task.sleep(for: .seconds(1))
        await loadProviders(cwd: cwd)
    }

    // MARK: Pull requests and history

    public func loadPrStatus(cwd: String) async {
        guard let r = try? await connection?.request("checkout_pr_status_request", ["cwd": .string(cwd)], timeout: .seconds(60)),
              let p = r["payload"] else { return }
        prStatus[cwd] = PrStatus(p)
    }

    private func checkoutError(_ r: JSONValue) -> String? {
        guard let e = r["payload"]?["error"], e != .null else { return nil }
        return e["message"]?.stringValue ?? e.stringValue ?? "操作失败"
    }

    /// Returns the new PR's URL.
    @discardableResult
    public func createPullRequest(cwd: String, title: String?, body: String?) async throws -> String? {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let title, !title.isEmpty { params["title"] = .string(title) }
        if let body, !body.isEmpty { params["body"] = .string(body) }
        let r = try await conn().request("checkout_pr_create_request", params, timeout: .seconds(180))
        if let e = checkoutError(r) { throw ActionError.rejected(e) }
        await loadPrStatus(cwd: cwd)
        return r["payload"]?["url"]?.stringValue
    }

    /// `method`: merge, squash or rebase.
    public func mergePullRequest(cwd: String, method: String) async throws {
        let r = try await conn().request("checkout_pr_merge_request", ["cwd": .string(cwd), "mergeMethod": .string(method)], timeout: .seconds(180))
        if let e = checkoutError(r) { throw ActionError.rejected(e) }
        await loadPrStatus(cwd: cwd)
        await refreshCheckoutStatus(cwd: cwd)
    }

    /// Reviews and comments on the workspace's PR.
    public func prTimeline(cwd: String, pr: PullRequestInfo) async throws -> [PRTimelineItem] {
        guard let n = pr.number else { return [] }
        var p: [String: JSONValue] = ["cwd": .string(cwd), "prNumber": .number(Double(n))]
        p["repoOwner"] = .string(pr.repoOwner ?? "")
        p["repoName"] = .string(pr.repoName ?? "")
        let r = try await conn().request("pull_request_timeline_request", p, timeout: .seconds(60))
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e["message"]?.stringValue ?? e.stringValue ?? "读取 PR 评论失败") }
        return (r["payload"]?["items"]?.arrayValue ?? []).enumerated().map { PRTimelineItem($1, index: $0) }
    }

    public func checkDetails(cwd: String, pr: PullRequestInfo, check: PullRequestInfo.Check) async throws -> CheckDetails {
        var p: [String: JSONValue] = ["cwd": .string(cwd)]
        if let o = pr.repoOwner { p["repoOwner"] = .string(o) }
        if let n = pr.repoName { p["repoName"] = .string(n) }
        if let id = check.checkRunId { p["checkRunId"] = .number(Double(id)) }
        if let id = check.workflowRunId { p["workflowRunId"] = .number(Double(id)) }
        if let n = pr.number { p["changeRequestNumber"] = .number(Double(n)) }
        let r = try await conn().request("checkout.forge.get_check_details.request", p, timeout: .seconds(60))
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e["message"]?.stringValue ?? "读取检查详情失败") }
        guard let d = r["payload"]?["details"], d != .null else { throw ActionError.rejected("没有详情") }
        return CheckDetails(d)
    }

    public func setAutoMerge(cwd: String, enabled: Bool, method: String = "squash") async throws {
        let r = try await conn().request("checkout.forge.set_auto_merge.request",
                                         ["cwd": .string(cwd), "enabled": .bool(enabled), "mergeMethod": .string(method)], timeout: .seconds(120))
        if let e = checkoutError(r) { throw ActionError.rejected(e) }
        await loadPrStatus(cwd: cwd)
    }

    /// Commits on this branch since it left its base (newest first).
    public func commits(cwd: String) async throws -> [CommitInfo] {
        let r = try await conn().request("checkout.commits.list.request", ["cwd": .string(cwd)], timeout: .seconds(60))
        if let e = checkoutError(r) { throw ActionError.rejected(e) }
        return (r["payload"]?["commits"]?.arrayValue ?? []).compactMap(CommitInfo.init)
    }

    public func commitFileDiff(cwd: String, sha: String, path: String) async throws -> DiffFile? {
        let r = try await conn().request("checkout.commits.file_diff.request",
                                         ["cwd": .string(cwd), "sha": .string(sha), "path": .string(path)], timeout: .seconds(60))
        if let e = checkoutError(r) { throw ActionError.rejected(e) }
        return r["payload"]?["file"].flatMap(DiffFile.init)
    }

    // MARK: Terminals

    /// Live terminal list of a workspace (`terminals_changed` is the reply and every later change).
    public func subscribeTerminals(workspace: Workspace) async {
        guard terminalListSubs[workspace.id] == nil, let c = connection else { return }
        terminalListSubs[workspace.id] = "pending"
        let requestId = UUID().uuidString.lowercased()
        let text = try? JSONValue.object(["type": "session", "message": [
            "type": "subscribe_terminals_request", "requestId": .string(requestId),
            "cwd": .string(workspace.directory), "workspaceId": .string(workspace.id),
        ]]).serialized()
        if let text { try? await c.sendRaw(text) }
        // The first terminals_changed carries our requestId; accept every subscription it names.
        if let r = try? await c.request("list_terminals_request", ["cwd": .string(workspace.directory), "workspaceId": .string(workspace.id)]) {
            terminals[workspace.id] = (r["payload"]?["terminals"]?.arrayValue ?? []).compactMap(TerminalInfo.init)
        }
    }

    public func createTerminal(workspace: Workspace, name: String? = nil, command: String? = nil, args: [String] = []) async throws -> TerminalInfo {
        var params: [String: JSONValue] = ["cwd": .string(workspace.directory), "workspaceId": .string(workspace.id)]
        if let name { params["name"] = .string(name) }
        if let command {
            params["command"] = .string(command)
            params["args"] = .array(args.map(JSONValue.string))
        }
        let r = try await conn().request("create_terminal_request", params)
        guard let t = r["payload"]?["terminal"].flatMap(TerminalInfo.init) else {
            throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? "创建终端失败")
        }
        terminals[workspace.id, default: []].removeAll { $0.id == t.id }
        terminals[workspace.id, default: []].append(t)
        return t
    }

    public func renameTerminal(_ terminalId: String, title: String) async throws {
        let r = try await conn().request("terminal.rename.request", ["terminalId": .string(terminalId), "title": .string(title)])
        if let e = r["payload"]?["error"], e != .null { throw ActionError.rejected(e["message"]?.stringValue ?? e.stringValue ?? "重命名失败") }
    }

    public func killTerminal(_ terminalId: String, workspaceId: String) async throws {
        _ = try await conn().request("kill_terminal_request", ["terminalId": .string(terminalId)])
        terminals[workspaceId]?.removeAll { $0.id == terminalId }
    }

    /// Claims the size, attaches with a visible-snapshot restore and routes frames to `sink`.
    public func attachTerminal(_ terminalId: String, cols: Int, rows: Int, sink: @escaping (TerminalEvent) -> Void) async throws {
        terminalSinks[terminalId] = sink
        focusedTerminalId = terminalId
        sendHeartbeat()
        try await resizeTerminal(terminalId, cols: cols, rows: rows, claim: true)
        let r = try await conn().request("subscribe_terminal_request", [
            "terminalId": .string(terminalId), "restore": ["mode": "visible-snapshot", "scrollbackLines": 500],
        ])
        guard let slot = r["payload"]?["slot"]?.doubleValue else {
            throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? "无法附着终端")
        }
        terminalSlots[Int(slot)] = terminalId
        if let sub = r["payload"]?["subscriptionId"]?.stringValue { terminalStreamSubs[terminalId] = sub }
    }

    public func detachTerminal(_ terminalId: String) {
        terminalSinks[terminalId] = nil
        terminalSlots = terminalSlots.filter { $0.value != terminalId }
        if focusedTerminalId == terminalId { focusedTerminalId = nil; sendHeartbeat() }
        guard let sub = terminalStreamSubs.removeValue(forKey: terminalId), let c = connection else { return }
        Task { _ = try? await c.request("subscription.release.request", ["subscriptionId": .string(sub)]) }
    }

    /// Input goes as JSON `terminal_input` like the official app (no slot timing, UTF-8 decoded host-side).
    public func sendTerminalInput(_ terminalId: String, _ data: Data) {
        guard let c = connection, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return }
        Task { try? await c.send("terminal_input", ["terminalId": .string(terminalId), "message": ["type": "input", "data": .string(s)]]) }
    }

    public func resizeTerminal(_ terminalId: String, cols: Int, rows: Int, claim: Bool) async throws {
        try await conn().send("terminal_input", ["terminalId": .string(terminalId), "message": [
            "type": "resize", "rows": .number(Double(rows)), "cols": .number(Double(cols)), "intent": .string(claim ? "claim" : "update"),
        ]])
    }

    // MARK: Scripts

    public func loadScripts(workspaceId: String) async {
        guard let r = try? await connection?.request("workspace.script.list.request", ["workspaceId": .string(workspaceId)]) else { return }
        scripts[workspaceId] = (r["payload"]?["scripts"]?.arrayValue ?? []).compactMap(WorkspaceScript.init)
    }

    public func scriptAction(_ action: String, workspaceId: String, name: String) async throws {
        let r = try await conn().request("workspace.script.\(action).request", ["workspaceId": .string(workspaceId), "scriptName": .string(name)])
        if let e = r["payload"]?["error"]?.stringValue { throw ActionError.rejected(e) }
        await loadScripts(workspaceId: workspaceId)
    }
}

extension HostStore {
    // MARK: Labels

    public func setLabel(_ label: String, color: String, on workspaceId: String, assigned: Bool) async throws {
        _ = try await conn().request("workspace.label.assignment.set.request", [
            "workspaceId": .string(workspaceId), "label": ["name": .string(label), "color": .string(color)], "assigned": .bool(assigned),
        ])
    }

    public func updateLabel(_ name: String, newName: String?, color: String?) async throws {
        var p: [String: JSONValue] = ["name": .string(name)]
        if let newName { p["newName"] = .string(newName) }
        if let color { p["color"] = .string(color) }
        _ = try await conn().request("workspace.label.update.request", p)
    }

    /// How many workspaces use the label (for the delete confirmation).
    public func labelUsage(_ name: String) async -> Int {
        let r = try? await connection?.request("workspace.label.delete.inspect.request", ["name": .string(name)])
        return Int(r?["payload"]?["affectedWorkspaceCount"]?.doubleValue ?? 0)
    }

    public func deleteLabel(_ name: String) async throws {
        _ = try await conn().request("workspace.label.delete.request", ["name": .string(name)])
    }

    // MARK: Daemon config

    /// Objects deep-merge; arrays and scalars replace whole, so send full arrays.
    public func patchDaemonConfig(_ patch: [String: JSONValue]) async throws {
        let r = try await conn().request("set_daemon_config_request", ["config": .object(patch)])
        if let c = r["payload"]?["config"] { daemonConfig = c }
    }

    /// Daemons with `terminalsSurviveRestart` (0.15+) keep terminal programs running across a restart
    /// unless `killTerminals`; older ones always close them.
    public var terminalsSurviveRestart: Bool { serverInfo?.hasFeature("terminalsSurviveRestart") == true }

    public func restartDaemon(killTerminals: Bool = false) async throws {
        let params: [String: JSONValue] = killTerminals ? ["killTerminals": true] : [:]
        _ = try await conn().request("restart_server_request", params, timeout: .seconds(10))
    }

    /// Agent profiles from daemon config: named launch bundles `{id, name, provider, model?, modeId?, thinkingOptionId?, featureValues?}`.
    public var agentProfiles: [JSONValue] { daemonConfig?["agentProfiles"]?.arrayValue ?? [] }

    /// Terminal profiles from daemon config (`{id, name, command, args?}`).
    public var terminalProfiles: [JSONValue] { daemonConfig?["terminalProfiles"]?.arrayValue ?? [] }

    // MARK: Uploads

    /// JSON `file.upload.request` immediately followed by FileBegin/FileChunk/FileEnd frames with the same request id.
    public func upload(fileName: String, mimeType: String, data: Data) async throws -> UploadedFile {
        let c = try conn()
        let requestId = UUID().uuidString.lowercased()
        let iso = ISO8601DateFormatter().string(from: Date())
        let rid = Array(requestId.utf8)
        func frame(_ op: UInt8, _ body: Data = Data()) -> Data {
            var d = Data([op, UInt8(rid.count)])
            d.append(contentsOf: rid)
            d.append(body)
            return d
        }
        let meta = try JSONValue.object(["mime": .string(mimeType), "size": .number(Double(data.count)), "encoding": "binary",
                                         "modifiedAt": .string(iso), "fileName": .string(fileName)]).serialized()
        var begin = Data()
        begin.appendU16(UInt16(meta.utf8.count))
        begin.append(Data(meta.utf8))
        let responseTask = Task {
            try await c.request("file.upload.request", ["fileName": .string(fileName), "mimeType": .string(mimeType),
                                                        "size": .number(Double(data.count)), "modifiedAt": .string(iso)],
                                timeout: .seconds(600), requestId: requestId)
        }
        // The JSON request registers the upload; frames follow on the same connection, in order.
        try await Task.sleep(for: .milliseconds(30))
        try await c.sendBinary(frame(0x10, begin))
        var offset = 0
        let chunk = 128 * 1024
        while offset < data.count {
            try await c.sendBinary(frame(0x11, data.subdata(in: offset..<min(offset + chunk, data.count))))
            offset += chunk
        }
        try await c.sendBinary(frame(0x12))
        let r = try await responseTask.value
        guard let file = r["payload"]?["file"], file != .null, let id = file["id"]?.stringValue else {
            throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? "上传失败")
        }
        return UploadedFile(id: id, fileName: file["fileName"]?.stringValue ?? fileName, size: data.count, attachment: file)
    }

    // MARK: Find & outline

    /// Replaces the local timeline with the whole history (limit 0), for find and the prompt outline.
    public func loadFullTimeline(_ agentId: String) async {
        guard let r = try? await connection?.request("fetch_agent_timeline_request", [
            "agentId": .string(agentId), "direction": "tail", "limit": 0, "projection": "projected",
        ], timeout: .seconds(120)), let p = r["payload"] else { return }
        var t = AgentTimeline()
        t.applyPage(p)
        timelines[agentId] = t
    }

    // MARK: Project icons

    /// Fetches a project's icon (custom or discovered) unless the cached one has the same revision.
    public func loadProjectIcon(projectId: String, revision: String?) async {
        guard !projectId.isEmpty, serverInfo?.hasFeature("projectCustomIcon") == true else { return }
        if let cached = projectIcons[projectId], cached.revision == revision { return }
        projectIcons[projectId] = (revision, projectIcons[projectId]?.data)
        guard let r = try? await conn().request("project.icon.get.request", ["projectId": .string(projectId)]),
              let p = r["payload"] else { return }
        let data = p["icon"]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        projectIcons[projectId] = (revision, data)
    }

    // MARK: Provider subagents

    public func loadProviderSubagents(_ parentAgentId: String) async {
        guard serverInfo?.hasFeature("providerSubagents") == true,
              let r = try? await connection?.request("agent.provider_subagents.list.request", ["parentAgentId": .string(parentAgentId)]) else { return }
        providerSubagents[parentAgentId] = (r["payload"]?["subagents"]?.arrayValue ?? []).compactMap(ProviderSubagent.init)
        if providerSubagentWatchers[parentAgentId] != nil { reconcileProviderSubagentSubscription() }
    }

    // MARK: Provider subagent pushes
    //
    // The daemon can only subscribe to `agent.provider_subagents.update` for the whole host, and it sends one per step
    // of every subagent. So the push is on only while a session on screen has a live subagent; everything else
    // (sidebar and Live Activity "a parent idles while its background subagent works", AppModel.groupBucket) reads
    // `agent.provider_subagents.list` snapshots: when a turn ends, every 30 s while a cached subagent of an idle
    // parent is still running, and for recently active idle sessions on connect.

    /// Call from a view that shows `parentAgentId`'s subagents; suspends until the view's task is cancelled.
    public func watchProviderSubagents(_ parentAgentId: String) async {
        guard state == .connected else { return }
        providerSubagentWatchers[parentAgentId, default: 0] += 1
        defer {
            let n = (providerSubagentWatchers[parentAgentId] ?? 1) - 1
            providerSubagentWatchers[parentAgentId] = n > 0 ? n : nil
            if n <= 0 { providerSubagentLaunches.remove(parentAgentId) }
            reconcileProviderSubagentSubscription()
        }
        await loadProviderSubagents(parentAgentId)
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// Whether `agent.provider_subagents.update` is currently subscribed.
    public var receivesProviderSubagentPushes: Bool { providerSubagentSubscriptionId != nil }

    private var wantsProviderSubagentPushes: Bool {
        providerSubagentWatchers.keys.contains { parent in
            providerSubagentLaunches.contains(parent) || providerSubagents[parent]?.contains { !$0.isFinished } == true
        }
    }

    /// A watched session's live timeline started a subagent: subscribe before the list shows it.
    func noteProviderSubagentLaunch(_ parentAgentId: String) {
        guard providerSubagentWatchers[parentAgentId] != nil, providerSubagentLaunches.insert(parentAgentId).inserted else { return }
        reconcileProviderSubagentSubscription()
    }

    /// A turn ended: background subagents may still run (or the ones we cached have finished).
    func providerSubagentTurnEnded(_ agentId: String) {
        providerSubagentLaunches.remove(agentId)
        Task { await loadProviderSubagents(agentId) }
    }

    /// Idle parents whose cached subagents still run get no push unless watched; re-read them.
    func pollIdleProviderSubagents() {
        guard state == .connected else { return }
        for (parent, subs) in providerSubagents where providerSubagentWatchers[parent] == nil
            && subs.contains(where: { !$0.isFinished }) {
            guard let a = agents[parent], a.archivedAt == nil, a.status != .running else { continue }
            Task { await loadProviderSubagents(parent) }
        }
    }

    /// On connect: sessions that went idle recently may have left background subagents running.
    func loadRecentIdleProviderSubagents() async {
        guard serverInfo?.hasFeature("providerSubagents") == true else { return }
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let recent = agents.values
            .filter { $0.archivedAt == nil && $0.status != .running && ($0.updatedAt ?? .distantPast) > cutoff }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(10)
        for a in recent { await loadProviderSubagents(a.id) }
    }

    /// Serialized: one subscribe/release in flight, rerun if the wish changed meanwhile.
    func reconcileProviderSubagentSubscription() {
        guard serverInfo?.hasFeature("providerSubagents") == true else { return }
        if providerSubagentReconcile != nil { providerSubagentReconcileAgain = true; return }
        providerSubagentReconcile = Task {
            repeat {
                providerSubagentReconcileAgain = false
                await reconcileProviderSubagentSubscriptionOnce()
            } while providerSubagentReconcileAgain
            providerSubagentReconcile = nil
        }
    }

    private func reconcileProviderSubagentSubscriptionOnce() async {
        guard let c = connection else { return }
        let want = wantsProviderSubagentPushes
        if want, providerSubagentSubscriptionId == nil {
            guard let r = try? await c.request("session.events.set_subscription.request", [
                "events": ["agent.provider_subagents.update"], "notifications": false,
            ]), let id = r["payload"]?["subscriptionId"]?.stringValue, connection === c else { return }
            providerSubagentSubscriptionId = id
            subscriptionIds.insert(id)
            // Upserts between the snapshot and the subscription never arrived.
            for parent in providerSubagentWatchers.keys { await loadProviderSubagents(parent) }
        } else if !want, let id = providerSubagentSubscriptionId {
            providerSubagentSubscriptionId = nil
            subscriptionIds.remove(id)
            _ = try? await c.request("subscription.release.request", ["subscriptionId": .string(id)])
        }
    }

    /// Rows for the composer pill: direct children of the agent, or of one provider subagent, oldest first.
    public func providerSubagents(of parentAgentId: String, under parentSubagentId: String? = nil) -> [ProviderSubagent] {
        (providerSubagents[parentAgentId] ?? [])
            .filter { $0.parentSubagentId == parentSubagentId && !hiddenProviderSubagents.contains($0.id) }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    public func hideProviderSubagents(_ ids: [String]) {
        hiddenProviderSubagents.formUnion(ids)
    }

    public static func providerSubagentKey(_ parentAgentId: String, _ subagentId: String) -> String {
        parentAgentId + "/" + subagentId
    }

    /// Fetches the latest page of a provider subagent's timeline (or an older one with `before`) into
    /// `providerSubagentTimelines`; live rows then arrive as `agent.provider_subagents.update` kind "timeline".
    public func loadProviderSubagentTimeline(parentAgentId: String, subagentId: String, older: Bool = false) async {
        let key = Self.providerSubagentKey(parentAgentId, subagentId)
        var params: [String: JSONValue] = [
            "parentAgentId": .string(parentAgentId), "subagentId": .string(subagentId), "limit": 200,
            "direction": older ? "before" : "tail",
        ]
        if older {
            guard let cursor = providerSubagentTimelines[key]?.startCursor else { return }
            params["cursor"] = cursor
        }
        do {
            let r = try await conn().request("agent.provider_subagents.timeline.get.request", params)
            guard let p = r["payload"] else { return }
            if let e = p["error"]?.stringValue, !e.isEmpty { throw ActionError.rejected(e) }
            // The subagent page carries `rows`; the agent page reader expects `entries` of the same shape.
            var page = p.objectValue ?? [:]
            page["entries"] = p["rows"] ?? .array([])
            var t = providerSubagentTimelines[key] ?? AgentTimeline()
            t.applyPage(.object(page))
            providerSubagentTimelines[key] = t
            providerSubagentTimelineErrors[key] = nil
        } catch {
            providerSubagentTimelineErrors[key] = "\(error)"
        }
    }

    private func applyProviderSubagentStream(_ parentAgentId: String, _ subagentId: String, _ p: JSONValue) {
        let key = Self.providerSubagentKey(parentAgentId, subagentId)
        guard var t = providerSubagentTimelines[key], let item = p["item"] else { return }
        let payload: JSONValue = [
            "event": ["type": "timeline", "item": item],
            "seq": p["seq"] ?? .null, "epoch": p["epoch"] ?? .null, "timestamp": p["timestamp"] ?? .null,
        ]
        switch t.applyStream(payload) {
        case .gap, .epochChanged:
            Task { await loadProviderSubagentTimeline(parentAgentId: parentAgentId, subagentId: subagentId) }
        default:
            providerSubagentTimelines[key] = t
        }
    }
}

// MARK: - Plugins (docs/protocol/05-plugins.md)

public struct PluginInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let enabled: Bool
    /// "running", "disabled" or "failed".
    public let status: String
    public let error: String?
    public var isRunning: Bool { status == "running" }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue else { return nil }
        self.id = id
        name = v["name"]?.stringValue ?? id
        enabled = v["enabled"]?.boolValue ?? false
        status = v["status"]?.stringValue ?? "disabled"
        error = v["error"]?.stringValue
    }
}

public struct PluginSettings: Sendable {
    public let revision: String
    public let values: [String: JSONValue]
}

extension HostStore {
    public func isPluginRunning(_ id: String) -> Bool { plugins.contains { $0.id == id && $0.isRunning } }

    /// The daemon's global plugin switch. Unset counts as off (new daemons), so only `true` runs plugins.
    public var pluginsGloballyEnabled: Bool { daemonConfig?["pluginsEnabled"]?.boolValue == true }

    func loadPlugins() async {
        guard let r = try? await connection?.request("plugin.list.request") else { return }
        plugins = (r["payload"]?["plugins"]?.arrayValue ?? []).compactMap(PluginInfo.init)
        pluginsLoaded = true
    }

    /// Calls a plugin's server RPC; failures arrive as rpc_error (thrown).
    public func invokePlugin(_ pluginId: String, _ method: String, _ input: JSONValue = [:], timeout: Duration = .seconds(45)) async throws -> JSONValue {
        let r = try await conn().request("plugin.rpc.invoke.request", ["pluginId": .string(pluginId), "method": .string(method), "input": input], timeout: timeout)
        return r["payload"]?["output"] ?? .null
    }

    public func readPluginSettings(_ pluginId: String, _ settingsId: String) async throws -> PluginSettings {
        let out = try await invokePlugin(pluginId, "settings.\(settingsId).read")
        guard out["status"]?.stringValue == "ready" else { throw ActionError.rejected(out["error"]?.stringValue ?? "设置无效") }
        return PluginSettings(revision: out["revision"]?.stringValue ?? "missing", values: out["values"]?.objectValue ?? [:])
    }

    /// Writes the whole values object; a stale revision returns a conflict.
    public func writePluginSettings(_ pluginId: String, _ settingsId: String, revision: String, values: [String: JSONValue]) async throws -> PluginSettings {
        let out = try await invokePlugin(pluginId, "settings.\(settingsId).write", ["revision": .string(revision), "values": .object(values)])
        switch out["status"]?.stringValue {
        case "saved": return PluginSettings(revision: out["revision"]?.stringValue ?? revision, values: out["values"]?.objectValue ?? values)
        case "conflict": throw ActionError.rejected("设置已在其他设备上修改，请重新打开再改")
        default: throw ActionError.rejected(out["error"]?.stringValue ?? "保存失败")
        }
    }

    /// Installs a plugin from a git URL or a local directory on the host.
    public func installPlugin(source: String, ref: String?) async throws {
        let isPath = source.hasPrefix("/") || source.hasPrefix("~")
        var p: [String: JSONValue] = isPath ? ["path": .string(source)] : ["source": .string(source)]
        if !isPath, let ref, !ref.isEmpty { p["ref"] = .string(ref) }
        let r = try await conn().request(isPath ? "plugin.directory.install.request" : "plugin.source.install.request", p, timeout: .seconds(300))
        if r["payload"]?["plugin"] == nil { throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? "安装失败") }
        await loadPlugins()
    }

    // MARK: Worktree setup

    public func subscribeSetup(workspaceId: String) async {
        guard let r = try? await connection?.request("workspace.setup.subscribe.request", ["workspaceId": .string(workspaceId)]),
              let snap = r["payload"]?["snapshot"], snap != .null else { return }
        if let id = r["payload"]?["subscriptionId"]?.stringValue { subscriptionIds.insert(id) }
        setupStatus[workspaceId] = WorktreeSetup(snap)
    }

    public func rerunSetup(workspaceId: String) async throws {
        let r = try await conn().request("workspace.setup.run.request", ["workspaceId": .string(workspaceId)], timeout: .seconds(60))
        if let e = r["payload"]?["error"]?.stringValue { throw ActionError.rejected(e) }
    }

    // MARK: Forge search

    public func forgeSearch(cwd: String, query: String) async throws -> [ForgeItem] {
        let r = try await conn().request("forge.search.request", ["cwd": .string(cwd), "query": .string(query), "limit": 20], timeout: .seconds(30))
        if let e = r["payload"]?["error"]?.stringValue { throw ActionError.rejected(e) }
        return (r["payload"]?["items"]?.arrayValue ?? []).compactMap(ForgeItem.init)
    }

    // MARK: Orchestration skills (installed into ~/.agents, ~/.claude, ~/.codex on the host)

    public struct SkillsStatus: Sendable {
        /// not-installed, up-to-date, drift.
        public let state: String
        public let pendingOps: [String]
        public let available: [String]
        public let installed: [String]
        /// nil = all skills (including future ones).
        public let selected: [String]?
        /// Removals the daemon wants confirmed before saving a selection.
        public let confirmRemovals: [String]

        init(_ p: JSONValue?) {
            state = p?["state"]?.stringValue ?? "not-installed"
            pendingOps = (p?["ops"]?.arrayValue ?? []).compactMap { o in
                let kind = ["add": "添加", "update": "更新", "delete": "删除"][o["kind"]?.stringValue ?? ""] ?? ""
                return o["name"]?.stringValue.map { kind + " " + $0 }
            }
            available = (p?["available"]?.arrayValue ?? []).compactMap(\.stringValue)
            installed = (p?["installed"]?.arrayValue ?? []).compactMap(\.stringValue)
            let sel = p?["selection"]
            selected = sel?["mode"]?.stringValue == "custom" ? (sel?["skills"]?.arrayValue ?? []).compactMap(\.stringValue) : nil
            confirmRemovals = (p?["confirmationRequired"]?["removals"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
    }

    /// `action`: get_status, reconcile (install/update) or uninstall.
    public func skills(_ action: String) async throws -> SkillsStatus {
        SkillsStatus(try await conn().request("agent.skills.\(action).request", timeout: .seconds(120))["payload"])
    }

    public func saveSkillSelection(_ selected: [String]?, confirmedRemovals: [String] = []) async throws -> SkillsStatus {
        var p: [String: JSONValue] = ["selection": selected.map { ["mode": "custom", "skills": .array($0.map(JSONValue.string))] } ?? ["mode": "all"]]
        if !confirmedRemovals.isEmpty { p["confirmedRemovals"] = .array(confirmedRemovals.map(JSONValue.string)) }
        return SkillsStatus(try await conn().request("agent.skills.save_selection.request", p, timeout: .seconds(120))["payload"])
    }

    public func reloadPlugin(_ id: String) async throws {
        _ = try await conn().request("plugin.reload.request", ["pluginId": .string(id)], timeout: .seconds(60))
        await loadPlugins()
    }

    public func removePlugin(_ id: String) async throws {
        _ = try await conn().request("plugin.remove.request", ["pluginId": .string(id)], timeout: .seconds(60))
        await loadPlugins()
    }

    // MARK: Import provider sessions

    public struct RecentSession: Sendable, Identifiable, Hashable {
        public let providerId: String
        public let providerLabel: String
        public let handleId: String
        public let cwd: String
        public let title: String?
        public let firstPrompt: String?
        public let lastPrompt: String?
        public let lastActivityAt: Date?
        public var id: String { providerId + ":" + handleId }
    }

    /// Sessions started outside Paseo (Claude Code, Codex…) that can be imported.
    public func recentProviderSessions(cwd: String?, query: String?) async throws -> [RecentSession] {
        var p: [String: JSONValue] = ["limit": 100]
        if let cwd { p["cwd"] = .string(cwd) }
        if let query, !query.isEmpty { p["query"] = .string(query) }
        let r = try await conn().request("fetch_recent_provider_sessions_request", p, timeout: .seconds(60))
        return (r["payload"]?["entries"]?.arrayValue ?? []).compactMap { e in
            guard let id = e["providerId"]?.stringValue, let h = e["providerHandleId"]?.stringValue else { return nil }
            return RecentSession(providerId: id, providerLabel: e["providerLabel"]?.stringValue ?? id, handleId: h,
                                 cwd: e["cwd"]?.stringValue ?? "", title: e["title"]?.stringValue,
                                 firstPrompt: e["firstPromptPreview"]?.stringValue, lastPrompt: e["lastPromptPreview"]?.stringValue,
                                 lastActivityAt: e["lastActivityAt"]?.dateValue)
        }
    }

    public func importSession(_ s: RecentSession) async throws -> String {
        let r = try await conn().request("import_agent_request", ["providerId": .string(s.providerId), "provider": .string(s.providerId),
                                                                  "providerHandleId": .string(s.handleId), "cwd": .string(s.cwd)],
                                         timeout: .seconds(180))
        let p = r["payload"]
        if p?["status"]?.stringValue == "agent_create_failed" { throw ActionError.rejected(p?["error"]?.stringValue ?? "导入失败") }
        if let a = p?["agent"].flatMap(Agent.init) { agents[a.id] = a }
        guard let id = p?["agentId"]?.stringValue else { throw ActionError.rejected("导入失败") }
        return id
    }

    public func setPluginEnabled(_ pluginId: String, _ enabled: Bool) async throws {
        _ = try await conn().request(enabled ? "plugin.enable.request" : "plugin.disable.request", ["pluginId": .string(pluginId)])
        await loadPlugins()
    }

    public func pluginLogs(_ pluginId: String) async -> [String] {
        guard let r = try? await connection?.request("plugin.logs.get.request", ["pluginId": .string(pluginId)]) else { return [] }
        return (r["payload"]?["entries"]?.arrayValue ?? []).suffix(200).map {
            ($0["timestamp"]?.stringValue ?? "") + " " + ($0["message"]?.stringValue ?? "")
        }
    }
}
