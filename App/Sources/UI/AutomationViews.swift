// Schedules and usage pages. Official: screens/schedules-screen.tsx, usage/card.tsx.

import PaseoKit
import SwiftUI

// MARK: Schedules

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var loader = ScheduleListLoader()
    @State private var refresh = 0
    @State private var actionError: (hostID: String, message: String)?
    @State private var tab = 0
    @State private var editing: ScheduleFormTarget?
    @State private var confirmDelete: (HostStore, Schedule)?
    @State private var detail: (HostStore, Schedule)?
    /// 本页自己的主机筛选（nil = 全部机器），不和侧栏共用：在这里只看一台机器，不该让侧栏的会话也跟着少掉。
    @State private var hostFilter: String?

    private var pageHosts: [HostStore] { model.hosts.filter { hostFilter == nil || $0.id == hostFilter } }
    private var connectedHosts: [HostStore] { pageHosts.filter { $0.state == .connected } }
    private var loading: Bool { !loader.loadingHostIDs.isEmpty }
    private var loadKey: ScheduleLoadKey {
        ScheduleLoadKey(hostID: hostFilter, connectedHostIDs: connectedHosts.map(\.id).sorted(), refresh: refresh)
    }
    private var items: [ScheduleListItem] {
        pageHosts.flatMap { h in
            (loader.schedulesByHost[h.id] ?? []).map { ScheduleListItem(host: h, schedule: $0) }
        }.sorted { ($0.schedule.createdAt ?? .distantPast) > ($1.schedule.createdAt ?? .distantPast) }
    }
    private var errors: [(hostID: String, message: String)] {
        pageHosts.compactMap { h in
            guard let message = loader.errorsByHost[h.id] else { return nil }
            return (h.id, "\(h.label)：\(message)")
        }
    }
    private var visibleActionError: String? {
        guard let actionError, pageHosts.contains(where: { $0.id == actionError.hostID }) else { return nil }
        return actionError.message
    }

    private var visible: [ScheduleListItem] {
        items.filter { item in
            let ended = item.schedule.status == "completed" || item.schedule.isExpired || targetGone(item)
            return tab == 0 ? !ended : ended
        }
    }

    var body: some View {
        List {
            if let visibleActionError { Banner(level: "error", message: visibleActionError) }
            ForEach(errors, id: \.hostID) { Banner(level: "error", message: $0.message) }
            ForEach(visible) { item in
                ScheduleRow(item: item, gone: targetGone(item), showHost: model.hosts.count > 1)
                    .contentShape(Rectangle())
                    .onTapGesture { detail = (item.host, item.schedule) }
                    .contextMenu { menu(item) }
            }
            if loading && (!visible.isEmpty || !errors.isEmpty || visibleActionError != nil) {
                ProgressView("加载中…")
            }
        }
        .overlay {
            if visible.isEmpty && errors.isEmpty && visibleActionError == nil {
                if loading || connectedHosts.isEmpty { ProgressView(connectedHosts.isEmpty ? "正在连接…" : "") }
                else if tab == 0 {
                    ContentUnavailableView {
                        Label("没有进行中的计划任务", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("按时间自动开会话做事，比如每个工作日早上 9 点整理 issue。")
                    } actions: {
                        Button("新建计划任务") { editing = .new }.compatibleGlassButtonStyle(prominent: true).tint(Theme.accent)
                            .mobileProminentControlSize()
                    }
                } else {
                    ContentUnavailableView("没有已结束的计划任务", systemImage: "calendar")
                }
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                statusPicker
                if model.hosts.count > 1 { hostPicker }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.surface0)
        }
        #endif
        .navigationTitle("计划任务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                statusPicker.frame(width: 180)
            }
            // 分段控件自带底色，再套工具栏的玻璃胶囊就成了「胶囊里套胶囊」
            .compatibleSharedBackgroundHidden()
            if model.hosts.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    hostPicker.fixedSize()
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) { Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新") }
            ToolbarItem(placement: .primaryAction) { Button { editing = .new } label: { Label("新建", systemImage: "plus") } }
        }
        .task(id: loadKey) {
            actionError = nil
            // No push for schedules: refresh while visible.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onDisappear { loader.cancel() }
        .sheet(item: $editing) { target in ScheduleForm(target: target) { refresh += 1 } }
        .sheet(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
            if let (h, s) = detail { ScheduleDetail(host: h, scheduleId: s.id) }
        }
        .confirmationDialog("删除「\(confirmDelete?.1.title ?? "")」？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let (h, s) = confirmDelete { act(h, s, "delete") }
            }
        } message: { Text("删除后无法恢复。") }
    }

    private var statusPicker: some View {
        Picker("状态", selection: $tab) {
            Text("进行中").tag(0)
            Text("已结束").tag(1)
        }.pickerStyle(.segmented).labelsHidden()
    }

    private var hostPicker: some View {
        Picker("主机", selection: $hostFilter) {
            Text("全部主机").tag(String?.none)
            ForEach(model.hosts) { h in Text(h.label).tag(Optional(h.id)) }
        }
        .pickerStyle(.menu)
        .lineLimit(1)
    }

    private func targetGone(_ item: ScheduleListItem) -> Bool {
        guard let id = item.schedule.targetAgentId else { return false }
        return item.host.state == .connected && item.host.agents[id] == nil
    }

    @ViewBuilder private func menu(_ item: ScheduleListItem) -> some View {
        let s = item.schedule
        Button("编辑…") { editing = .edit(item.host.id, s) }
        if !s.isHeartbeat && (s.status == "active" || s.status == "paused") {
            Button(s.status == "paused" ? "恢复" : "暂停") { act(item.host, s, s.status == "paused" ? "resume" : "pause") }
            Button("立即运行") { act(item.host, s, "run-once") }
        }
        Divider()
        Button("删除", role: .destructive) { confirmDelete = (item.host, s) }
    }

    private func act(_ host: HostStore, _ s: Schedule, _ action: String) {
        Task {
            do {
                if action == "run-once" {
                    Task { try? await host.scheduleAction(action, s.id); refresh += 1 }
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    try await host.scheduleAction(action, s.id)
                }
            } catch {
                actionError = (host.id, "\(s.title)：\(error)")
                return
            }
            refresh += 1
        }
    }

    private func load() async {
        let sources = connectedHosts.map { h in
            ScheduleListLoader.Source(hostID: h.id) { try await h.listSchedules() }
        }
        await loader.load(sources: sources, selectedHostID: hostFilter)
    }
}

private struct ScheduleLoadKey: Equatable {
    let hostID: String?
    let connectedHostIDs: [String]
    let refresh: Int
}

struct ScheduleListItem: Identifiable {
    let host: HostStore
    let schedule: Schedule
    // Schedule IDs belong to a daemon, not to the combined list of machines.
    var id: String { host.id + ":" + schedule.id }
}

struct ScheduleRow: View {
    let item: ScheduleListItem
    let gone: Bool
    let showHost: Bool

    var body: some View {
        let s = item.schedule
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: s.isHeartbeat ? "waveform.path.ecg" : "calendar.badge.clock").foregroundStyle(Theme.muted)
                Text(s.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(badge).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .fixedSize().frame(minHeight: 28)
                    .background(badgeColor.opacity(0.15), in: Capsule()).foregroundStyle(badgeColor)
            }
            Text(target).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Text(meta).font(.system(size: 12)).foregroundStyle(Theme.extraMuted).lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var badge: String {
        let s = item.schedule
        if s.isExpired { return String(localized: "已过期") }
        if gone { return String(localized: "目标已不存在") }
        if s.status == "completed" { return String(localized: "已完成") }
        if s.status == "paused" { return String(localized: "已暂停") }
        return String(localized: "进行中")
    }

    private var badgeColor: Color {
        if gone { return Theme.destructive }
        return item.schedule.status == "active" && !item.schedule.isExpired ? Theme.dotSuccess : Theme.muted
    }

    private var target: String {
        let s = item.schedule
        if let id = s.targetAgentId { return String(localized: "发给会话：\(item.host.agents[id]?.displayTitle ?? String(id.prefix(8)))") }
        return String(localized: "新建会话于 \((s.cwd as NSString?)?.lastPathComponent ?? "?")")
    }

    private var meta: String {
        let s = item.schedule
        var parts: [String] = []
        if showHost { parts.append(item.host.label) }
        parts.append(describeCadence(s))
        parts.append(s.lastRunAt.map { String(localized: "上次 \($0.formatted(.relative(presentation: .named)))") } ?? String(localized: "还没运行过"))
        if s.status == "active", let next = s.nextRunAt { parts.append(String(localized: "下次 \(next.formatted(.relative(presentation: .named)))")) }
        return parts.joined(separator: " · ")
    }
}

func describeCadence(_ s: Schedule) -> String {
    if let ms = s.everyMs { return String(localized: "每 \(Int(ms / 60000)) 分钟") }
    guard let e = s.cronExpression else { return "—" }
    let f = e.split(separator: " ").map(String.init)
    guard f.count == 5 else { return e }
    let time = (Int(f[1]).map { String(format: "%02d", $0) } ?? f[1]) + ":" + (Int(f[0]).map { String(format: "%02d", $0) } ?? f[0])
    switch (f[0], f[1], f[2], f[3], f[4]) {
    case ("*", "*", "*", "*", "*"): return String(localized: "每分钟")
    case (let m, "*", "*", "*", "*") where m.hasPrefix("*/"): return String(localized: "每 \(m.dropFirst(2)) 分钟")
    case (_, "*", "*", "*", "*") where Int(f[0]) != nil: return String(localized: "每小时第 \(f[0]) 分")
    case (_, _, "*", "*", "*") where Int(f[0]) != nil && Int(f[1]) != nil: return String(localized: "每天 \(time)")
    case (_, _, "*", "*", "1-5"): return String(localized: "工作日 \(time)")
    case (_, _, "*", "*", "1"): return String(localized: "每周一 \(time)")
    default: return e
    }
}

enum ScheduleFormTarget: Identifiable {
    case new
    case edit(String, Schedule)
    var id: String { if case .edit(_, let s) = self { s.id } else { "new" } }
}

struct ScheduleForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: ScheduleFormTarget
    let onDone: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    @State private var cron = "0 9 * * 1-5"
    @State private var workspace: WorkspaceRef?
    @State private var provider = "claude"
    @State private var modelId = ""
    @State private var modeId = ""
    @State private var thinkingId = ""
    @State private var isolation = "local"
    @State private var archiveOnFinish = true
    @State private var maxRuns = ""
    @State private var error: String?
    @State private var saving = false

    private static let presets: [(String, String)] = [
        (String(localized: "每分钟"), "* * * * *"), (String(localized: "每小时"), "0 * * * *"), (String(localized: "每天 9:00"), "0 9 * * *"),
        (String(localized: "工作日 9:00"), "0 9 * * 1-5"), (String(localized: "每周一 9:00"), "0 9 * * 1"),
    ]

    private var editing: (String, Schedule)? { if case .edit(let h, let s) = target { (h, s) } else { nil } }
    private var isHeartbeat: Bool { editing?.1.isHeartbeat ?? false }
    private var host: HostStore? { workspace.flatMap { model.host($0.serverId) } ?? editing.flatMap { model.host($0.0) } }

    var body: some View {
        NavigationStack {
            Form {
                if !isHeartbeat {
                    Section("在哪里运行") {
                        Picker("项目", selection: $workspace) {
                            Text("选择…").tag(WorkspaceRef?.none)
                            ForEach(model.hosts) { h in
                                ForEach(h.workspaces.values.sorted { $0.name < $1.name }) { w in
                                    Text("\(w.projectDisplayName) · \(w.name)\(model.hosts.count > 1 ? " · " + h.label : "")")
                                        .tag(WorkspaceRef?.some(WorkspaceRef(serverId: h.id, workspaceId: w.id)))
                                }
                            }
                        }
                        .disabled(editing != nil)
                        if let host {
                            Picker("Provider", selection: $provider) {
                                ForEach(host.providers.compactMap { $0["provider"]?.stringValue }, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("模型", selection: $modelId) {
                                Text("默认").tag("")
                                ForEach(host.providers.first { $0["provider"]?.stringValue == provider }?["models"]?.arrayValue ?? [], id: \.self) { m in
                                    Text(m["label"]?.stringValue ?? "").tag(m["id"]?.stringValue ?? "")
                                }
                            }
                            let modelEntries = host.providers.first { $0["provider"]?.stringValue == provider }?["models"]?.arrayValue ?? []
                            let modelEntry = modelEntries.first { $0["id"]?.stringValue == modelId } ?? modelEntries.first { $0["isDefault"]?.boolValue == true }
                            let thinking = modelEntry?["thinkingOptions"]?.arrayValue ?? []
                            if !thinking.isEmpty {
                                Picker("思考强度", selection: $thinkingId) {
                                    Text("默认").tag("")
                                    ForEach(thinking, id: \.self) { o in Text(o["label"]?.stringValue ?? "").tag(o["id"]?.stringValue ?? "") }
                                }
                            }
                            Picker("模式", selection: $modeId) {
                                Text("默认").tag("")
                                ForEach(host.providers.first { $0["provider"]?.stringValue == provider }?["modes"]?.arrayValue ?? [], id: \.self) { m in
                                    Text(m["label"]?.stringValue ?? "").tag(m["id"]?.stringValue ?? "")
                                }
                            }
                        }
                        Picker("隔离", selection: $isolation) { Text("直接在目录里").tag("local"); Text("新建 worktree").tag("worktree") }
                        Toggle("跑完自动归档", isOn: $archiveOnFinish)
                    }
                    Section("内容") {
                        TextField("名字（可选）", text: $name)
                        TextField("每次运行时发送的指令", text: $prompt, axis: .vertical).lineLimit(3...8)
                    }
                }
                Section("频率") {
                    Picker("预设", selection: $cron) {
                        ForEach(Self.presets, id: \.1) { Text($0.0).tag($0.1) }
                        if !Self.presets.contains(where: { $0.1 == cron }) { Text("自定义").tag(cron) }
                    }
                    TextField("cron（分 时 日 月 周）", text: $cron).font(.system(.body, design: .monospaced))
                    Text("时区：\(TimeZone.current.identifier)").font(.caption).foregroundStyle(Theme.muted)
                    let next = CronPreview.next(cron, count: 3)
                    if !next.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("接下来会在").font(.caption).foregroundStyle(Theme.muted)
                            ForEach(next, id: \.self) { d in
                                Text(d.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())).font(.caption.monospacedDigit())
                            }
                        }
                    } else if valid {
                        Text("这个表达式在一年内不会触发").font(.caption).foregroundStyle(Theme.dotWarning)
                    }
                    if !isHeartbeat { TextField("最多运行次数（留空为不限）", text: $maxRuns) }
                }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "新建计划任务" : "编辑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(saving || !valid) }
            }
            .task(id: workspace) {
                if let host, host.providers.isEmpty { await host.loadProviders(cwd: workspace.flatMap { model.workspace($0)?.directory }) }
            }
            .onAppear(perform: fill)
        }
        .macOnly { $0.frame(minWidth: 520, minHeight: 560) }
    }

    private var valid: Bool {
        let fields = cron.split(separator: " ")
        guard fields.count == 5, fields.allSatisfy({ $0.allSatisfy { "0123456789*-/,".contains($0) } }) else { return false }
        return isHeartbeat || (workspace != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || editing != nil
    }

    private func fill() {
        guard let (serverId, s) = editing else {
            workspace = model.defaultDraftWorkspace
            return
        }
        name = s.name ?? ""
        prompt = s.prompt
        cron = s.cronExpression ?? cron
        provider = s.config?["provider"]?.stringValue ?? provider
        modelId = s.config?["model"]?.stringValue ?? ""
        modeId = s.config?["modeId"]?.stringValue ?? ""
        thinkingId = s.config?["thinkingOptionId"]?.stringValue ?? ""
        isolation = s.config?["isolation"]?.stringValue ?? "local"
        archiveOnFinish = s.config?["archiveOnFinish"]?.boolValue ?? true
        maxRuns = s.maxRuns.map(String.init) ?? ""
        if let cwd = s.cwd, let h = model.host(serverId), let w = h.workspaces.values.first(where: { $0.directory == cwd }) {
            workspace = WorkspaceRef(serverId: serverId, workspaceId: w.id)
        }
    }

    private func save() {
        saving = true
        error = nil
        let cadence: JSONValue = ["type": "cron", "expression": .string(cron.trimmingCharacters(in: .whitespaces)),
                                  "timezone": .string(TimeZone.current.identifier)]
        Task {
            do {
                if let (serverId, s) = editing, let h = model.host(serverId) {
                    var p: [String: JSONValue] = ["cadence": cadence]
                    if !s.isHeartbeat {
                        p["name"] = name.isEmpty ? .null : .string(name)
                        p["prompt"] = .string(prompt)
                        p["maxRuns"] = Int(maxRuns).map { .number(Double($0)) } ?? .null
                        p["newAgentConfig"] = config()
                    }
                    try await h.updateSchedule(s.id, p)
                } else if let ref = workspace, let h = model.host(ref.serverId) {
                    var p: [String: JSONValue] = ["prompt": .string(prompt), "cadence": cadence, "target": ["type": "new-agent", "config": config()]]
                    if !name.isEmpty { p["name"] = .string(name) }
                    if let n = Int(maxRuns) { p["maxRuns"] = .number(Double(n)) }
                    try await h.createSchedule(p)
                }
                onDone()
                dismiss()
            } catch {
                self.error = "\(error)"
            }
            saving = false
        }
    }

    private func config() -> JSONValue {
        var c: [String: JSONValue] = ["provider": .string(provider), "isolation": .string(isolation), "archiveOnFinish": .bool(archiveOnFinish)]
        if let ref = workspace, let w = model.workspace(ref) { c["cwd"] = .string(w.directory) }
        if !modelId.isEmpty { c["model"] = .string(modelId) }
        if !modeId.isEmpty { c["modeId"] = .string(modeId) }
        if !thinkingId.isEmpty { c["thinkingOptionId"] = .string(thinkingId) }
        if !name.isEmpty { c["title"] = .string(name) }
        return .object(c)
    }
}

/// Run history (an addition over the official app, which has none).
private struct ScheduleDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostStore
    let scheduleId: String
    @State private var schedule: Schedule?

    var body: some View {
        NavigationStack {
            List {
                if let s = schedule {
                    Section("指令") { Text(s.prompt).textSelection(.enabled) }
                    Section("频率") { Text(describeCadence(s)); if let tz = s.timezone { Text(tz).foregroundStyle(Theme.muted) } }
                    Section("运行记录（\(s.runs.count)）") {
                        if s.runs.isEmpty { Text("还没运行过").foregroundStyle(Theme.muted) }
                        ForEach(s.runs.reversed()) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: run.status == "succeeded" ? "checkmark.circle" : run.status == "failed" ? "xmark.circle" : "clock")
                                        .foregroundStyle(run.status == "succeeded" ? Theme.dotSuccess : run.status == "failed" ? Theme.destructive : Theme.muted)
                                    Text(run.startedAt.map(formatTimestamp) ?? "")
                                    if let a = run.startedAt, let b = run.endedAt { Text("· " + formatDuration(b.timeIntervalSince(a))).foregroundStyle(Theme.muted) }
                                    Spacer()
                                    if let agentId = run.agentId, host.agents[agentId] != nil {
                                        Button("打开会话") { dismiss(); model.open(AgentRef(serverId: host.id, agentId: agentId)) }
                                    }
                                }
                                if let out = run.output ?? run.error {
                                    Text(out).font(.system(size: 12)).foregroundStyle(run.error != nil ? Theme.destructive : Theme.muted).lineLimit(6)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(schedule?.title ?? String(localized: "计划任务"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { schedule = try? await host.inspectSchedule(scheduleId) }
        }
        .macOnly { $0.frame(minWidth: 520, minHeight: 480) }
    }
}

// MARK: Usage

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var reports: [String: [UsageReport]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loading: Set<String> = []
    @AppStorage("usageDisplay", store: AppDefaults.store) private var displayRemaining = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(model.hosts) { host in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            HostStatusDot(state: host.state)
                            Text(host.label).font(.system(size: 15, weight: .semibold))
                            if loading.contains(host.id) { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                        if let e = errors[host.id] { Banner(level: "error", message: e) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                            ForEach(reports[host.id] ?? []) { UsageCard(report: $0, displayRemaining: displayRemaining) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if reports.values.allSatisfy(\.isEmpty) {
                if model.connectionKey.isEmpty || !loading.isEmpty { ProgressView(model.connectionKey.isEmpty ? "正在连接…" : "正在获取用量…") }
                else if errors.isEmpty { ContentUnavailableView("没有用量数据", systemImage: "chart.bar", description: Text("这台机器上没有启用用量来源插件。")) }
            }
        }
        .navigationTitle("用量")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $displayRemaining) { Text("已用").tag(false); Text("剩余").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            // 分段控件自带底色，再套工具栏的玻璃胶囊就成了「胶囊里套胶囊」
            .compatibleSharedBackgroundHidden()
            ToolbarItem(placement: .primaryAction) { Button { Task { await load(force: true) } } label: { Label("刷新", systemImage: "arrow.clockwise") } }
        }
        .task(id: model.connectionKey) { await load(force: false) }
    }

    private func load(force: Bool) async {
        for h in model.hosts where h.state == .connected {
            guard h.usageQueriesEnabled else { errors[h.id] = String(localized: "这台机器关闭了用量查询（机器设置 → 会话）"); continue }
            Task { await load(h, force: force) }
        }
    }

    /// Reports stream in one by one; each replaces its own card in place.
    private func load(_ h: HostStore, force: Bool) async {
        loading.insert(h.id)
        do {
            try await h.usageReports(forceRefresh: force) { r in
                var list = reports[h.id] ?? []
                if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r } else { list.append(r) }
                reports[h.id] = list
            }
            errors[h.id] = nil
        } catch { errors[h.id] = "\(error)" }
        loading.remove(h.id)
    }
}

private struct UsageCard: View {
    let report: UsageReport
    let displayRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(report.sourceLabel).font(.system(size: 15, weight: .semibold))
                if let plan = report.planLabel {
                    Text(plan).font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.surface2, in: Capsule())
                }
                Spacer()
                if let at = report.fetchedAt { Text(at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(Theme.extraMuted) }
            }
            if let problem = report.problem { Banner(level: report.retained ? "warning" : "error", message: problem + (report.retained ? String(localized: "（显示上次成功的数据）") : "")) }
            ForEach(report.windows) { w in
                let used = w.usedPct ?? (w.remainingPct.map { 100 - $0 } ?? 0)
                let shown = displayRemaining ? 100 - used : used
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(windowLabel(w)).font(.system(size: 13))
                        Spacer()
                        Text(displayRemaining ? String(localized: "\(Int(shown.rounded()))% 剩余") : String(localized: "\(Int(shown.rounded()))% 已用")).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                    ProgressView(value: min(max(used, 0), 100), total: 100).tint(tone(w.tone, used))
                    if let at = w.runsOutAt ?? w.resetsAt {
                        // Countdown plus the exact moment (official 0.15 #8162).
                        Text(w.runsOutAt != nil ? String(localized: "\(at.formatted(.relative(presentation: .named)))用完 · \(formatWhen(at))") : String(localized: "\(at.formatted(.relative(presentation: .named)))重置 · \(formatWhen(at))"))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            ForEach(report.balances) { b in
                HStack {
                    Text(b.label).font(.system(size: 13))
                    Spacer()
                    Text([b.used.map { fmt($0, b.unit) }, b.limit.map { "/ " + fmt($0, b.unit) }].compactMap { $0 }.joined(separator: " "))
                        .font(.system(size: 13)).monospacedDigit()
                }
            }
            ForEach(Array(report.details.enumerated()), id: \.offset) { _, d in
                HStack { Text(d.label).foregroundStyle(Theme.muted); Spacer(); Text(d.value) }.font(.system(size: 12))
            }
            if let account = report.account { Text(account).font(.caption).foregroundStyle(Theme.extraMuted) }
        }
        .padding(16)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderAccent))
    }

    /// Built-in window ids get Chinese names (official: usage/format.ts localizes the same ids).
    private func windowLabel(_ w: UsageWindow) -> String {
        let names = ["five_hour": String(localized: "5 小时窗口"), "session": String(localized: "5 小时窗口"), "weekly": String(localized: "本周"), "monthly": String(localized: "本月"), "daily": String(localized: "今日")]
        if let n = names[w.id] { return n }
        return w.label.replacingOccurrences(of: "Weekly", with: String(localized: "本周")).replacingOccurrences(of: "Session", with: String(localized: "5 小时窗口"))
    }

    private func tone(_ t: String?, _ used: Double) -> Color {
        switch t {
        case "danger": return Theme.destructive
        case "warning": return Theme.dotWarning
        case "ok": return Theme.accent
        default: return used > 90 ? Theme.destructive : used >= 70 ? Theme.dotWarning : Theme.accent
        }
    }

    private func fmt(_ v: Double, _ unit: String) -> String {
        switch unit {
        case "usd": return v.formatted(.currency(code: "USD"))
        case "tokens": return v.formatted(.number.notation(.compactName))
        default: return v.formatted(.number.precision(.fractionLength(0...1)))
        }
    }
}

/// Context window ring for the composer (from `lastUsage`). Official: components/context-window-meter.tsx.
struct ContextRing: View {
    let usage: Usage
    /// 有值时弹出面板下面附上这个会话的限额（usage-reset 插件在跑时）。
    var quota: (host: HostStore, agentId: String, model: String?)? = nil
    /// Ring only (narrow screens); the popover still has the numbers.
    var compact = false
    @State private var showing = false

    var body: some View {
        if let max = usage.contextWindowMaxTokens, max > 0, let used = usage.contextWindowUsedTokens {
            let pct = used / max * 100
            Button { showing.toggle() } label: { ring(pct) }
                .buttonStyle(.plain)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    details(used: used, max: max, pct: pct).compactPopover()
                }
                .help("上下文 \(Int(used).formatted(.number.notation(.compactName))) / \(Int(max).formatted(.number.notation(.compactName))) tokens")
        }
    }

    private func details(used: Double, max: Double, pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上下文用量").font(.system(size: 13, weight: .semibold))
            ProgressView(value: min(pct / 100, 1)).tint(pct > 90 ? Theme.destructive : pct >= 70 ? Theme.dotWarning : Theme.accent)
            row(String(localized: "已用"), String(localized: "\(Int(used).formatted()) / \(Int(max).formatted()) tokens（\(Int(pct))%）"))
            if let v = usage.inputTokens { row(String(localized: "本轮输入"), Int(v).formatted() + " tokens") }
            if let v = usage.cachedInputTokens, v > 0 { row(String(localized: "其中缓存命中"), Int(v).formatted() + " tokens") }
            if let v = usage.outputTokens { row(String(localized: "本轮输出"), Int(v).formatted() + " tokens") }
            if let c = usage.totalCostUsd, c > 0 { row(String(localized: "累计花费"), c < 0.01 ? String(format: "$%.4f", c) : String(format: "$%.2f", c)) }
            if pct >= 70 { Text("快满时可以发 /compact 压缩上下文").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            if let quota, AgentQuotaSection.available(quota.host) {
                Divider().padding(.vertical, 4)
                AgentQuotaSection(host: quota.host, agentId: quota.agentId, model: quota.model)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.muted); Spacer(); Text(v).monospacedDigit() }.font(.system(size: 12))
    }

    @ViewBuilder private func ring(_ pct: Double) -> some View {
        do {
            Chip {
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2.5)
                    Circle().trim(from: 0, to: min(pct / 100, 1)).stroke(pct > 90 ? Theme.destructive : pct >= 70 ? Theme.dotWarning : Theme.muted,
                                                                      style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                if !compact {
                    Text("\(Int(pct))%")
                    if let cost = usage.totalCostUsd, cost > 0 { Text(cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)) }
                }
            }
        }
    }
}

/// Next run times of a 5-field cron expression in the local time zone (official: next-run preview).
enum CronPreview {
    static func next(_ expr: String, count: Int, from start: Date = Date()) -> [Date] {
        let f = expr.split(separator: " ").map(String.init)
        guard f.count == 5,
              let minutes = parse(f[0], 0...59), let hours = parse(f[1], 0...23), let dom = parse(f[2], 1...31),
              let months = parse(f[3], 1...12), let dowRaw = parse(f[4], 0...7) else { return [] }
        let dow = Set(dowRaw.map { $0 == 7 ? 0 : $0 })
        let domAny = f[2] == "*", dowAny = f[4] == "*"
        let cal = Calendar.current
        var out: [Date] = []
        var day = cal.startOfDay(for: start)
        for _ in 0..<400 {
            let c = cal.dateComponents([.month, .day, .weekday], from: day)
            let dayOK: Bool = {
                let d = dom.contains(c.day!), w = dow.contains(c.weekday! - 1)
                if domAny && dowAny { return true }
                if domAny { return w }
                if dowAny { return d }
                return d || w
            }()
            if months.contains(c.month!) && dayOK {
                for h in hours.sorted() {
                    for m in minutes.sorted() {
                        if let t = cal.date(bySettingHour: h, minute: m, second: 0, of: day), t > start {
                            out.append(t)
                            if out.count == count { return out }
                        }
                    }
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    private static func parse(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            var lo = range.lowerBound, hi = range.upperBound
            if pieces[0] != "*" {
                let bounds = pieces[0].split(separator: "-")
                guard let a = Int(bounds[0]) else { return nil }
                lo = a
                hi = bounds.count == 2 ? (Int(bounds[1]) ?? a) : (pieces.count == 2 ? range.upperBound : a)
            }
            guard lo >= range.lowerBound, hi <= range.upperBound, lo <= hi else { return nil }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out
    }
}
