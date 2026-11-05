import Foundation
import Observation
import PaseoKit
#if os(iOS)
import UIKit
#endif

/// Ids are only unique within one host, so everything cross-machine is keyed by serverId too.
struct AgentRef: Hashable, Codable, Sendable {
    let serverId: String
    let agentId: String
}

struct WorkspaceRef: Hashable, Codable, Sendable {
    let serverId: String
    let workspaceId: String
}

/// What the detail pane shows.
enum Destination: Hashable, Codable, Sendable {
    case agent(AgentRef)
    /// A workspace showing a non-agent tab (terminal, changes, files, draft).
    case workspace(WorkspaceRef)
    /// New chat; the workspace is picked in the draft (defaults to the last used one).
    case newChat
    case projects
    case history
    case schedules
    case usage
    case board
}

/// One tab in a workspace. Official: workspace-tabs/model.ts (no split panes yet).
enum WorkspaceTab: Hashable, Codable, Sendable {
    case agent(String)
    case terminal(String)
    case changes
    case files
    /// One file, by absolute path on the host.
    case file(String)
    /// A web page (usually a workspace service), by URL.
    case browser(String)
    /// New agent being composed in this workspace.
    case draft(String)
    /// A provider-internal subagent (e.g. Claude's Task tool) of an agent, read-only.
    case subagent(parent: String, id: String)
}

struct WorkspaceTabState: Codable, Sendable {
    var order: [WorkspaceTab] = []
    var selected: WorkspaceTab?
}

enum SidebarSort: String, CaseIterable, Codable {
    case updated, created

    /// "最近活动" orders by the last prompt (falling back to updates), which keeps rows from jumping while agents work.
    var label: String { self == .updated ? "最近活动" : "创建时间" }
}

struct ReviewComment: Identifiable, Hashable {
    let id = UUID()
    let path: String
    /// Line number on the new side (or the old side for removed lines).
    let line: Int
    let removed: Bool
    let snippet: String
    var text: String

    var location: String { path + ":" + String(line) + (removed ? "（删除的行）" : "") }
}

enum SidebarGrouping: String, CaseIterable, Codable {
    case project, status

    var label: String { self == .project ? "按项目" : "按状态" }
}

/// One sidebar group: a project on one machine (or a status, or the pinned section), with its top-level sessions.
struct SessionGroup: Identifiable {
    enum Kind { case project, pinned, status(StatusBucket) }
    let id: String
    let serverId: String
    let name: String
    let hostLabel: String
    var kind: Kind = .project
    /// Most recently active workspace of a project group: its icon, and where 「+」 starts a session.
    var workspace: Workspace?
    /// The project of a group that has no live sessions (listed like the official sidebar); 「+」 opens a workspace in it.
    var project: Project?
    /// One row per workspace (official sidebar): the session it opens, its machine (status/pinned groups mix machines),
    /// and the most urgent status among the workspace's sessions.
    var rows: [(serverId: String, agent: Agent, bucket: StatusBucket)] = []
    var agents: [Agent] { rows.map(\.agent) }
    var bucket: StatusBucket { rows.map(\.bucket).min() ?? .done }
}

@MainActor @Observable
final class AppModel {
    private(set) var hosts: [HostStore] = []
    var destination: Destination? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(destination), forKey: "destination") }
    }
    /// nil = all hosts.
    var hostFilter: String? {
        didSet { UserDefaults.standard.set(hostFilter, forKey: "hostFilter") }
    }
    var sort: SidebarSort = .updated {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sidebarSort") }
    }
    var grouping: SidebarGrouping = SidebarGrouping(rawValue: UserDefaults.standard.string(forKey: "sidebarGrouping") ?? "") ?? .project {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "sidebarGrouping") }
    }
    var search = ""
    /// Lowercased label names; "" means "unlabelled". Empty set = no filter.
    var labelFilter: Set<String> = []
    /// Bumped when a sidebar row is tapped; on iPhone it shows the content page even if the destination did not change.
    var revealDetail = 0
    /// Projects merged by hand across machines when their names differ ("Acme web app" on one machine is
    /// "web-app" on another): "serverId|project name" → the sidebar group it joins. Local to this app.
    var projectAliases: [String: String] = (UserDefaults.standard.dictionary(forKey: "projectAliases") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(projectAliases, forKey: "projectAliases") }
    }
    /// Messages waiting for the current turn to end, per agent (client-side, like the official queue track).
    var queue: [String: [QueuedMessage]] = [:]

    /// Unsent composer text per agent, kept across switching sessions and relaunches.
    private(set) var composerDrafts: [String: String] = UserDefaults.standard.dictionary(forKey: "composerDrafts") as? [String: String] ?? [:]

    func saveDraft(_ text: String, for agentId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { composerDrafts[agentId] = nil } else { composerDrafts[agentId] = text }
        UserDefaults.standard.set(composerDrafts, forKey: "composerDrafts")
    }
    /// Which settings page opens next (0 通用, 1 机器).
    var settingsTab = 0

    /// Review comments on diff lines per checkout directory, sent to an agent together as feedback.
    var reviewComments: [String: [ReviewComment]] = [:]

    /// Settings the next new-agent draft starts from (/new, /clear, profiles).
    struct DraftPreset {
        var provider: String
        var model: String?
        var thinking: String?
        var modeId: String?
    }
    var draftPreset: DraftPreset?

    /// Pending fork: the next new chat carries this context and copies the source agent's config.
    var forkDraft: ForkDraft?
    /// Workspace the board opens for (nil = board home).
    var boardWorkspace: WorkspaceRef?
    var hasBoardPlugin: Bool { hosts.contains { $0.isPluginRunning("agent-taskboard") } }

    struct ForkDraft {
        let title: String
        let attachment: JSONValue
        let provider: String
        let model: String?
        let thinking: String?
        let modeId: String?
        /// Forked "into a new workspace": the new-chat page opens the worktree picker.
        var newWorkspace = false
    }

    /// Official: hooks/use-fork-agent.ts — a draft carrying the chat history, in a new tab or for a new workspace.
    func startFork(from ref: AgentRef, attachment: JSONValue, newWorkspace: Bool) {
        guard let a = agent(ref) else { return }
        forkDraft = ForkDraft(title: a.displayTitle, attachment: attachment, provider: a.provider, model: a.model,
                              thinking: a.thinkingOptionId, modeId: a.currentModeId, newWorkspace: newWorkspace)
        guard let w = workspace(of: ref) else { destination = .newChat; return }
        let ws = WorkspaceRef(serverId: ref.serverId, workspaceId: w.id)
        if newWorkspace {
            draftWorkspace = ws
            destination = .newChat
        } else {
            select(.draft(UUID().uuidString), in: ws)
        }
    }
    /// Workspace a new chat goes into; remembered across launches.
    var draftWorkspace: WorkspaceRef? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(draftWorkspace), forKey: "draftWorkspace") }
    }

    private static let hostsKey: String = {
        #if DEBUG
        // 截图 / 演示：PASEO_HOSTS_KEY=<名字> 用单独的钥匙串条目存机器列表，不读也不覆盖日常用的那份
        if let k = ProcessInfo.processInfo.environment["PASEO_HOSTS_KEY"], !k.isEmpty { return "hosts.v1." + k }
        #endif
        return "hosts.v1"
    }()
    private let clientId: String
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    private struct StoredHost: Codable {
        var label: String
        var offer: PairingOffer
    }

    init() {
        // Stable across launches: the daemon resumes the logical session by clientId.
        if let id = UserDefaults.standard.string(forKey: "clientId") {
            clientId = id
        } else {
            clientId = "cid_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(clientId, forKey: "clientId")
        }
        if let data = Keychain.load(Self.hostsKey), let stored = try? JSONDecoder().decode([StoredHost].self, from: data) {
            hosts = stored.map { makeStore($0.offer, label: $0.label) }
        }
        #if DEBUG
        // Development: seed a machine from the environment so the link never has to be typed or shown.
        if let link = ProcessInfo.processInfo.environment["PASEO_PAIRING"], !link.isEmpty,
           let offer = try? PairingOffer.parse(link), host(offer.serverId) == nil {
            try? addHost(link: link, label: ProcessInfo.processInfo.environment["PASEO_LABEL"] ?? "本机", password: nil)
        }
        #endif
        let d = UserDefaults.standard
        if let data = d.data(forKey: "destination") { destination = try? JSONDecoder().decode(Destination.self, from: data) }
        if let data = d.data(forKey: "workspaceTabs"), let t = try? JSONDecoder().decode([String: WorkspaceTabState].self, from: data) {
            tabState = t
        }
        if let data = d.data(forKey: "draftWorkspace") { draftWorkspace = try? JSONDecoder().decode(WorkspaceRef.self, from: data) }
        hostFilter = d.string(forKey: "hostFilter")
        sort = SidebarSort(rawValue: d.string(forKey: "sidebarSort") ?? "") ?? .updated
    }

    // MARK: Sidebar

    var visibleHosts: [HostStore] { hosts.filter { hostFilter == nil || $0.id == hostFilter } }

    /// Changes whenever a host connects or drops; pages use it to reload once connections are up.
    var connectionKey: String { hosts.filter { $0.state == .connected }.map(\.id).sorted().joined(separator: ",") }

    /// Workspaces grouped by (machine, project), most recently active group first; each workspace is one row
    /// and its sessions are tabs inside it, like the official sidebar.
    /// Pinned workspaces first (official "Pinned" section), then by project or by status.
    var groups: [SessionGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var matched: [(HostStore, Agent)] = []
        for h in visibleHosts {
            for a in h.agents.values where !h.isNested(a) && a.archivedAt == nil && matchesLabels(a, in: h)
                && (query.isEmpty || a.displayTitle.lowercased().contains(query)
                    || (a.workspaceId.flatMap { h.workspaces[$0]?.title }?.lowercased().contains(query) ?? false)) {
                matched.append((h, a))
            }
        }
        typealias Row = (host: HostStore, agent: Agent, bucket: StatusBucket, key: Date)
        var collapsed: [Row] = []
        for (_, list) in Dictionary(grouping: matched, by: { $0.0.id + ":" + ($0.1.workspaceId ?? "agent:" + $0.1.id) }) {
            let h = list[0].0
            let pick = representative(list.map(\.1), host: h)
            // Status and order come from all the workspace's live sessions, not only the ones matching the search.
            let all = pick.workspaceId.map { ws in h.agents.values.filter { $0.workspaceId == ws && $0.archivedAt == nil && !h.isNested($0) } } ?? [pick]
            collapsed.append((h, pick, groupBucket(all, in: h), all.map { sortKey($0) }.max() ?? sortKey(pick)))
        }
        collapsed.sort { $0.key > $1.key }
        let rowsOf = { (list: [Row]) in list.map { (serverId: $0.host.id, agent: $0.agent, bucket: $0.bucket) } }
        let pinned = collapsed.filter { r in r.agent.workspaceId.flatMap { r.host.workspaces[$0]?.pinnedAt } != nil }
        let rest = collapsed.filter { r in r.agent.workspaceId.flatMap { r.host.workspaces[$0]?.pinnedAt } == nil }
        let multiHost = visibleHosts.count > 1
        var out: [SessionGroup] = []
        switch grouping {
        case .project:
            // Same-named projects on different machines are one group (official single list); rows keep their machine.
            // Insertion order follows `rest`, which is already newest first.
            var order: [String] = []
            var byProject: [String: [Row]] = [:]
            for r in rest {
                let key = groupName(r.host.id, projectName(of: r.agent, in: r.host))
                if byProject[key] == nil { order.append(key) }
                byProject[key, default: []].append(r)
            }
            for key in order {
                let list = byProject[key]!
                // The most recently active workspace decides the icon and where 「+」 starts a session.
                let latest = list.compactMap { r in r.agent.workspaceId.flatMap { r.host.workspaces[$0] }.map { (r.host, $0) } }
                    .max { ($0.1.activityAt ?? .distantPast) < ($1.1.activityAt ?? .distantPast) }
                let h = latest?.0 ?? list[0].host
                let machines = Set(list.map(\.host.id))
                out.append(SessionGroup(id: "project:" + key, serverId: h.id, name: key, hostLabel: machines.count > 1 ? "" : h.label,
                                        workspace: latest?.1, rows: rowsOf(list)))
            }
            // Every other project, like the official sidebar, after the active ones and by name.
            if query.isEmpty && labelFilter.isEmpty {
                let shown = Set(out.map(\.id))
                var idle: [String: [(HostStore, Project)]] = [:]
                for h in visibleHosts {
                    for project in h.projects.values where !shown.contains("project:" + groupName(h.id, project.displayName)) {
                        idle[groupName(h.id, project.displayName), default: []].append((h, project))
                    }
                }
                for name in idle.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    let list = idle[name]!
                    out.append(SessionGroup(id: "project:" + name, serverId: list[0].0.id, name: name,
                                            hostLabel: list.count > 1 ? "" : list[0].0.label, project: list[0].1))
                }
            }
        case .status:
            let names: [StatusBucket: String] = [.needsInput: "需要输入", .failed: "失败", .running: "运行中", .attention: "待查看", .done: "已完成"]
            let byBucket = Dictionary(grouping: rest) { $0.bucket }
            for b in byBucket.keys.sorted() {
                let list = (byBucket[b] ?? []).sorted { $0.key > $1.key }
                out.append(SessionGroup(id: "status:" + b.rawValue, serverId: list[0].host.id, name: names[b] ?? b.rawValue,
                                        hostLabel: multiHost ? "全部主机" : list[0].host.label, kind: .status(b), rows: rowsOf(list)))
            }
        }
        if !pinned.isEmpty {
            out.insert(SessionGroup(id: "pinned", serverId: pinned[0].host.id, name: "置顶", hostLabel: "", kind: .pinned,
                                    rows: rowsOf(pinned)), at: 0)
        }
        return out
    }

    /// Status of a workspace row: the most urgent of its sessions, where a session that waits for input or is
    /// running also counts when only one of its subagents (nested Paseo sessions or provider subagents such as
    /// Claude's Task tool) does — a parent idling while its children work is still running.
    func groupBucket(_ roots: [Agent], in host: HostStore) -> StatusBucket {
        let live = host.agents.values.filter { $0.archivedAt == nil && $0.parentAgentId != nil }
        let children = Dictionary(grouping: live) { $0.parentAgentId! }
        var best = roots.map(\.bucket).min() ?? .done
        var stack = roots.map(\.id)
        var seen = Set(stack)
        while let id = stack.popLast() {
            if host.providerSubagents(of: id).contains(where: { !$0.isFinished }) { best = min(best, .running) }
            for c in children[id] ?? [] where seen.insert(c.id).inserted {
                if c.bucket == .needsInput || c.bucket == .running { best = min(best, c.bucket) }
                stack.append(c.id)
            }
        }
        return best
    }

    /// The sidebar group a machine's project belongs to: its own name unless merged into another.
    func groupName(_ serverId: String, _ projectName: String) -> String {
        projectAliases[serverId + "|" + projectName] ?? projectName
    }

    /// The (machine, project name) pairs shown in a project group.
    func projectMembers(_ groupName: String) -> [(serverId: String, name: String)] {
        var out: [(String, String)] = []
        for h in hosts {
            var names = Set(h.projects.values.map(\.displayName))
            names.formUnion(h.agents.values.map { projectName(of: $0, in: h) })
            for n in names where self.groupName(h.id, n) == groupName { out.append((h.id, n)) }
        }
        return out
    }

    /// Merges one project group into another (all its machines' projects follow).
    func mergeProject(_ source: String, into target: String) {
        guard source != target else { return }
        var aliases = projectAliases
        for m in projectMembers(source) { aliases[m.serverId + "|" + m.name] = target }
        // Anything that pointed at the source now points at the target.
        for (k, v) in aliases where v == source { aliases[k] = target }
        projectAliases = aliases
    }

    /// Undoes manual merges into a group: every project shows under its own name again.
    func unmergeProject(_ group: String) {
        projectAliases = projectAliases.filter { $0.value != group }
    }

    /// The session a workspace row opens: the one being viewed, else the workspace's selected tab, else the most recent.
    private func representative(_ list: [Agent], host: HostStore) -> Agent {
        if case .agent(let r) = destination, r.serverId == host.id, let hit = list.first(where: { $0.id == r.agentId }) { return hit }
        if let ws = list[0].workspaceId, case .agent(let id)? = tabState[host.id + ":" + ws]?.selected,
           let hit = list.first(where: { $0.id == id }) { return hit }
        return list.max { sortKey($0) < sortKey($1) }!
    }

    /// New session in a project without live sessions: reuse its main-directory workspace, else open one (official).
    func startSession(in project: Project, host: HostStore) async throws {
        var wsId = host.workspaces.values.first { $0.projectId == project.id && $0.directory == project.rootPath }?.id
        if wsId == nil {
            (wsId, _) = try await host.createWorkspace(source: ["kind": "directory", "path": .string(project.rootPath),
                                                                "projectId": .string(project.id)])
        }
        guard let wsId else { throw HostStore.ActionError.rejected("没有拿到工作区") }
        select(.draft(UUID().uuidString), in: WorkspaceRef(serverId: host.id, workspaceId: wsId))
    }

    /// Opens a sidebar row: a workspace opens on its last selected tab (official), a session without one opens directly.
    func openRow(_ ref: AgentRef) {
        // iPhone: the sidebar is its own page, so tapping the row already shown must still go back to it.
        revealDetail += 1
        guard let w = workspace(of: ref) else { open(ref); return }
        let ws = WorkspaceRef(serverId: ref.serverId, workspaceId: w.id)
        if currentWorkspace == ws { return }
        if let tab = tabState[key(ws)]?.selected, tabs(ws).contains(tab) { select(tab, in: ws) } else { open(ref) }
    }

    private func matchesLabels(_ a: Agent, in h: HostStore) -> Bool {
        guard !labelFilter.isEmpty else { return true }
        let labels = a.workspaceId.flatMap { h.workspaces[$0]?.labels } ?? []
        if labels.isEmpty { return labelFilter.contains("") }
        return labels.contains { labelFilter.contains($0.lowercased()) }
    }

    /// All label names across hosts, for the sidebar filter.
    var allLabels: [WorkspaceLabel] {
        var seen = Set<String>()
        return hosts.flatMap(\.labels).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    private func sortKey(_ a: Agent?) -> Date? {
        guard let a else { return nil }
        return sort == .updated ? (a.lastUserMessageAt ?? a.updatedAt ?? a.createdAt) : a.createdAt
    }

    private func sortKey(_ a: Agent) -> Date { sortKey(Optional(a)) ?? .distantPast }

    func projectName(of agent: Agent, in host: HostStore) -> String {
        if let ws = agent.workspaceId, let w = host.workspaces[ws], !w.projectDisplayName.isEmpty { return w.projectDisplayName }
        let last = (agent.cwd as NSString).lastPathComponent
        return last.isEmpty ? "其他" : last
    }

    func workspace(_ ref: WorkspaceRef) -> Workspace? { host(ref.serverId)?.workspaces[ref.workspaceId] }

    func workspace(of ref: AgentRef) -> Workspace? {
        guard let id = agent(ref)?.workspaceId else { return nil }
        return host(ref.serverId)?.workspaces[id]
    }

    /// Default workspace for a new chat: the remembered one, else the current session's, else the most active.
    var defaultDraftWorkspace: WorkspaceRef? {
        if let d = draftWorkspace, workspace(d) != nil { return d }
        if case .agent(let r) = destination, let w = workspace(of: r) { return WorkspaceRef(serverId: r.serverId, workspaceId: w.id) }
        let all = visibleHosts.flatMap { h in h.workspaces.values.map { (h.id, $0) } }
        return all.max { ($0.1.activityAt ?? .distantPast) < ($1.1.activityAt ?? .distantPast) }
            .map { WorkspaceRef(serverId: $0.0, workspaceId: $0.1.id) }
    }

    func open(_ ref: AgentRef) {
        if let w = workspace(of: ref) {
            let ws = WorkspaceRef(serverId: ref.serverId, workspaceId: w.id)
            var state = tabState[key(ws)] ?? WorkspaceTabState()
            if !state.order.contains(.agent(ref.agentId)) { state.order.append(.agent(ref.agentId)) }
            state.selected = .agent(ref.agentId)
            tabState[key(ws)] = state
        }
        destination = .agent(ref)
    }

    // MARK: Workspace tabs

    /// Opens a provider subagent in a tab of its parent's workspace, like the official app.
    func openProviderSubagent(serverId: String, parentAgentId: String, subagentId: String) {
        guard let w = workspace(of: AgentRef(serverId: serverId, agentId: parentAgentId)) else { return }
        select(.subagent(parent: parentAgentId, id: subagentId), in: WorkspaceRef(serverId: serverId, workspaceId: w.id))
    }

    /// Line to jump to per open file tab (absolute path), from links like `Foo.swift:42`.
    var fileLines: [String: Int] = [:]

    /// Opens a file from a reply link in its own tab.
    func openFile(_ absolutePath: String, line: Int?, in ws: WorkspaceRef) {
        fileLines[absolutePath] = line
        select(.file(absolutePath), in: ws)
    }

    /// Agents being archived and terminals being killed, hidden until the host confirms.
    var closingTabs: Set<WorkspaceTab> = []

    /// Per workspace ("serverId:workspaceId"), remembered across launches.
    var tabState: [String: WorkspaceTabState] = [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(tabState), forKey: "workspaceTabs") }
    }

    private func key(_ ws: WorkspaceRef) -> String { ws.serverId + ":" + ws.workspaceId }

    /// The workspace the detail pane shows, if any.
    var currentWorkspace: WorkspaceRef? {
        switch destination {
        case .agent(let r): workspace(of: r).map { WorkspaceRef(serverId: r.serverId, workspaceId: $0.id) }
        case .workspace(let w): w
        default: nil
        }
    }

    /// Like the official app: every live top-level agent and terminal of the workspace has a tab,
    /// plus whatever was opened by hand; remembered order first, new ones appended.
    func tabs(_ ws: WorkspaceRef) -> [WorkspaceTab] {
        guard let host = host(ws.serverId) else { return [] }
        let terminals = host.terminals[ws.workspaceId]
        var viewing: String?
        if case .agent(let r) = destination, r.serverId == ws.serverId { viewing = r.agentId }
        var result = (tabState[key(ws)]?.order ?? []).filter { tab in
            if closingTabs.contains(tab) { return false }
            return switch tab {
            // An archived agent keeps its tab only while it is being looked at (opened from history).
            case .agent(let id): host.agents[id].map { $0.archivedAt == nil || id == viewing } ?? false
            case .terminal(let id): terminals.map { $0.contains { $0.id == id } } ?? true
            case .subagent(let parent, _): host.agents[parent].map { $0.archivedAt == nil } ?? false
            default: true
            }
        }
        let roots = host.agents.values.filter { $0.workspaceId == ws.workspaceId && $0.archivedAt == nil && !$0.isSubagent }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        for a in roots where !result.contains(.agent(a.id)) && !closingTabs.contains(.agent(a.id)) { result.append(.agent(a.id)) }
        for t in terminals ?? [] where !result.contains(.terminal(t.id)) && !closingTabs.contains(.terminal(t.id)) { result.append(.terminal(t.id)) }
        // 以前替换草稿时留下的重复标签（已存进 tabState），按首次出现去重。
        var seen = Set<WorkspaceTab>()
        return result.filter { seen.insert($0).inserted }
    }

    func selectedTab(_ ws: WorkspaceRef) -> WorkspaceTab? {
        let all = tabs(ws)
        if case .agent(let r) = destination, r.serverId == ws.serverId, all.contains(.agent(r.agentId)) { return .agent(r.agentId) }
        if let s = tabState[key(ws)]?.selected, all.contains(s) { return s }
        return all.first
    }

    func select(_ tab: WorkspaceTab, in ws: WorkspaceRef) {
        var state = tabState[key(ws)] ?? WorkspaceTabState()
        if !state.order.contains(tab) { state.order = tabs(ws).filter { $0 != tab } + [tab] }
        state.selected = tab
        tabState[key(ws)] = state
        if case .agent(let id) = tab { destination = .agent(AgentRef(serverId: ws.serverId, agentId: id)) }
        else { destination = .workspace(ws) }
    }

    func moveTab(from: Int, to: Int, in ws: WorkspaceRef) {
        var order = tabs(ws)
        guard order.indices.contains(from), order.indices.contains(to), from != to else { return }
        let t = order.remove(at: from)
        order.insert(t, at: to)
        tabState[key(ws), default: WorkspaceTabState()].order = order
    }

    /// Drops a tab from the layout only; archiving agents and killing terminals is the caller's job.
    func removeTab(_ tab: WorkspaceTab, in ws: WorkspaceRef, replacement: WorkspaceTab? = nil) {
        let all = tabs(ws)
        var state = tabState[key(ws)] ?? WorkspaceTabState()
        var order = all
        if let i = order.firstIndex(of: tab) {
            if let replacement {
                // 新会话一出现，tabs() 就把它自动补在末尾；草稿再换成它会出现两个同样的标签，先去掉补的那个。
                order.removeAll { $0 == replacement }
                order[order.firstIndex(of: tab) ?? i] = replacement
            } else { order.remove(at: i) }
        }
        state.order = order
        let wasSelected = selectedTab(ws) == tab
        tabState[key(ws)] = state
        if let replacement { select(replacement, in: ws) }
        else if wasSelected {
            let i = all.firstIndex(of: tab) ?? 0
            let next = order.indices.contains(i) ? order[i] : order.last
            if let next { select(next, in: ws) } else { state.selected = nil; tabState[key(ws)] = state; destination = .workspace(ws) }
        }
    }

    private(set) var appActive = true

    private var started = false

    /// 只跑一次：iOS 上实时活动的推送令牌可能在后台把 App 唤醒，那时窗口还没出来就要先连上机器。
    func start() {
        guard !started else { return }
        started = true
        NotificationManager.shared.setUp()
        NotificationManager.shared.onOpen = { [weak self] ref in self?.open(ref) }
        NotificationManager.shared.onAction = { [weak self] ref, action in await self?.handleNotification(action, ref: ref) }
        NotificationManager.shared.isHostConnected = { [weak self] id in self?.host(id)?.state == .connected }
        hosts.forEach { $0.start() }
        hosts.filter { $0.label == Self.unnamedHost }.forEach { adoptHostname($0) }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                self?.hosts.forEach { $0.refreshRunningAgents() }
            }
        }
        #if DEBUG
        // Development: PASEO_OPEN=<agent id prefix>[:subagents|:host[:files|changes|terminal|scripts]] opens a screen for screenshots.
        if let spec = ProcessInfo.processInfo.environment["PASEO_OPEN"], !spec.isEmpty {
            let parts = spec.split(separator: ":").map(String.init)
            let pages: [String: Destination] = ["newChat": .newChat, "projects": .projects, "history": .history,
                                                "schedules": .schedules, "usage": .usage, "board": .board]
            // home: the session list itself (iPhone's root), e.g. with PASEO_SWIPE_DEMO=1.
            if parts[0] == "home" { destination = nil; return }
            if let page = pages[parts[0]] {
                destination = page
                if parts.count > 1 { debugSheet = parts[1] }
                return
            }
            debugPane = parts.count > 1 ? parts[1] : nil
            debugHostTab = parts.count > 2 ? parts[2] : nil
            Task {
                for _ in 0..<100 {
                    if let (h, a) = hosts.lazy.compactMap({ h in h.agents.values.first { $0.id.hasPrefix(parts[0]) }.map { (h, $0) } }).first {
                        open(AgentRef(serverId: h.id, agentId: a.id))
                        // PASEO_THEN_OPEN=<prefix>[,<prefix>…]: then open each, 8 s apart (e.g. parent → subagent → parent).
                        for next in (ProcessInfo.processInfo.environment["PASEO_THEN_OPEN"] ?? "").split(separator: ",") {
                            try? await Task.sleep(for: .seconds(8))
                            if let b = h.agents.values.first(where: { $0.id.hasPrefix(next) }) { open(AgentRef(serverId: h.id, agentId: b.id)) }
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        #endif
    }

    /// PASEO_DUMP_PROVIDERS: what the app holds as provider entries (provider, status, model ids), to debug model labels.
    func dumpProviders(to path: String) async {
        try? await Task.sleep(for: .seconds(15))
        var lines: [String] = []
        for h in hosts {
            lines.append("host \(h.label) state=\(h.state) entries=\(h.providers.count)")
            for e in h.providers {
                let ids: [String] = (e["models"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
                let name: String = e["provider"]?.stringValue ?? "?"
                let status: String = e["status"]?.stringValue ?? "?"
                let keys: String = (e.objectValue?.keys.sorted() ?? []).joined(separator: ",")
                lines.append("  " + name + " status=" + status + " models=" + String(ids.count) + " " + ids.prefix(3).joined(separator: ",") + " keys=" + keys)
            }
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(0)
    }

    var debugPane: String?
    var debugSheet: String?
    var debugHostTab: String?

    /// Every top-level session in sidebar order (for ⌘1…9 and ⌘[ / ⌘]).
    var orderedSessions: [AgentRef] {
        groups.flatMap { g in g.rows.map { AgentRef(serverId: $0.serverId, agentId: $0.agent.id) } }
    }

    func step(_ delta: Int) {
        let list = orderedSessions
        guard !list.isEmpty else { return }
        if case .agent(let r) = destination, let i = list.firstIndex(of: r) {
            open(list[(i + delta + list.count) % list.count])
        } else {
            open(list[0])
        }
    }

    func host(_ serverId: String) -> HostStore? { hosts.first { $0.id == serverId } }

    func agent(_ ref: AgentRef) -> Agent? { host(ref.serverId)?.agents[ref.agentId] }

    /// Parses a pairing link and adds (or updates) the machine. Throws on an invalid link.
    @discardableResult
    func addHost(link: String, label: String, password: String?) throws -> HostStore {
        var offer = try PairingOffer.parse(link)
        if let password, !password.isEmpty { offer.password = password }
        if let existing = host(offer.serverId) {
            existing.label = label.isEmpty ? existing.label : label
            existing.updatePassword(offer.password)
            persist()
            return existing
        }
        let store = makeStore(offer, label: label.isEmpty ? Self.unnamedHost : label)
        hosts.append(store)
        persist()
        store.start()
        if label.isEmpty { adoptHostname(store) }
        return store
    }

    /// Placeholder until a machine added without a name reports its own.
    private static let unnamedHost = "新机器"

    /// Names a machine added without a name after its host name ("Johns-Mac-mini.local" → "Johns-Mac-mini")
    /// once it connects, unless the user renamed it meanwhile.
    private func adoptHostname(_ store: HostStore) {
        Task { [weak self] in
            for _ in 0..<120 {
                if let name = store.serverInfo?.hostname?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    guard store.label == Self.unnamedHost else { return }
                    store.label = name.hasSuffix(".local") ? String(name.dropLast(6)) : name
                    self?.persist()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Adds a daemon reached by address (no relay): connects once to learn its server id, then saves it.
    func addDirectHost(address: String, useTls: Bool, label: String, password: String?) async throws -> HostStore {
        var endpoint = address.trimmingCharacters(in: .whitespaces)
        for prefix in ["ws://", "wss://", "http://", "https://", "tcp://"] where endpoint.hasPrefix(prefix) { endpoint.removeFirst(prefix.count) }
        if let slash = endpoint.firstIndex(of: "/") { endpoint = String(endpoint[..<slash]) }
        if !endpoint.contains(":") || endpoint.hasSuffix("]") { endpoint += ":6767" }
        let pw = password.flatMap { $0.isEmpty ? nil : $0 }
        let probe = PairingOffer.direct(serverId: "", endpoint: endpoint, useTls: useTls, password: pw)
        let c = try await DaemonConnection.connectDirect(url: probe.directWebSocketURL(),
                                                         hello: HelloOptions(clientId: clientId, password: pw, appVersion: appVersion),
                                                         expectedServerId: "")
        let info = await c.serverInfo
        await c.close()
        guard let serverId = info?.serverId, !serverId.isEmpty else { throw HostStore.ActionError.rejected("没有拿到这台机器的 ID") }
        let offer = PairingOffer.direct(serverId: serverId, endpoint: endpoint, useTls: useTls, password: pw)
        if let existing = host(serverId) {
            // Already paired through the relay: keep that connection, just remember the name.
            existing.label = label.isEmpty ? existing.label : label
            persist()
            return existing
        }
        let store = makeStore(offer, label: label.isEmpty ? (info?.hostname ?? endpoint) : label)
        hosts.append(store)
        persist()
        store.start()
        return store
    }

    func removeHost(_ serverId: String) {
        host(serverId)?.stop()
        hosts.removeAll { $0.id == serverId }
        if case .agent(let r) = destination, r.serverId == serverId { destination = nil }
        if hostFilter == serverId { hostFilter = nil }
        persist()
    }

    func rename(host serverId: String, to label: String) {
        host(serverId)?.label = label
        persist()
    }

    func setPassword(host serverId: String, _ password: String?) {
        host(serverId)?.updatePassword(password)
        persist()
    }

    func setAppVisible(_ visible: Bool) {
        appActive = visible
        hosts.forEach { $0.setAppVisible(visible) }
    }

    /// 用户看得到 App（Mac 一直算；iOS 不是被通知按钮从后台唤醒的）：这时才直接打开会话。
    private static var userCanSee: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    /// Reply / allow / deny straight from a notification, without opening the session.
    /// Permission buttons only answer a single plain tool request; questions and plans need the session.
    /// iOS：按钮会把挂起的 App 从后台唤醒，那时和机器的连接早断了——先申请后台时间、重连、等会话和待批准请求
    /// 加载出来（最多 20 秒）再处理，做完才返回。
    func handleNotification(_ action: NotificationManager.NotificationAction, ref: AgentRef) async {
        #if os(iOS)
        let bg = UIApplication.shared.beginBackgroundTask(withName: "paseo.notification-action")
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        #endif
        start()
        guard let host = host(ref.serverId) else { return }
        let isReply: Bool = { if case .reply = action { return true } else { return false } }()
        for _ in 0..<40 {
            if host.state == .connected, let a = host.agents[ref.agentId], isReply || !a.pendingPermissions.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let title = host.agents[ref.agentId]?.displayTitle ?? "会话"
        do {
            switch action {
            case .reply(let text):
                guard host.state == .connected else { throw HostStore.ActionError.notConnected }
                try await host.send(text, to: ref.agentId, steer: true)
            case .allow, .deny:
                guard host.state == .connected else { throw HostStore.ActionError.notConnected }
                let pending = host.agents[ref.agentId]?.pendingPermissions ?? []
                let requestId: String? = { switch action { case .allow(let id), .deny(let id): id; default: nil } }()
                // 只处理通知对应的那个请求；通知没带 id（同时有多个请求）或那个请求已处理过，就不替用户批别的。
                let target = requestId.flatMap { id in pending.first { $0.id == id } }
                guard let request = target, request.kind != "question", request.kind != "plan" else {
                    if requestId != nil, target == nil {
                        NotificationManager.shared.postFailure("已经处理过了 · \(title)", body: "通知里的这个请求已经不在等你批准了。", ref: ref)
                    } else if Self.userCanSee {
                        open(ref)
                    } else {
                        NotificationManager.shared.postFailure("要在 App 里处理 · \(title)", body: "这是问题、计划或多个请求，点这里打开会话。", ref: ref)
                    }
                    return
                }
                let allow: Bool = { if case .allow = action { return true } else { return false } }()
                var response: [String: JSONValue] = ["behavior": .string(allow ? "allow" : "deny")]
                if let a = request.actions.first(where: { ($0.behavior == "deny") != allow }) {
                    response["behavior"] = .string(a.behavior)
                    response["selectedActionId"] = .string(a.id)
                }
                if !allow { response["message"] = "Denied by user" }
                try await host.respond(to: request, agentId: ref.agentId, response: response)
            }
        } catch {
            NotificationManager.shared.postFailure("没能完成 · \(title)", body: "\(error)", ref: ref)
        }
    }

    private func makeStore(_ offer: PairingOffer, label: String) -> HostStore {
        let store = HostStore(offer: offer, label: label, clientId: clientId, appVersion: appVersion)
        store.onAttention = { [weak self, weak store] e in
            guard let self, let store else { return }
            let viewing = self.appActive && self.destination == .agent(AgentRef(serverId: e.serverId, agentId: e.agentId))
            guard !viewing, e.shouldNotify || !self.appActive else { return }
            #if os(iOS)
            // 切到后台还连着机器的那几秒：插件会推远程通知，这里不再弹本地的，免得重复。
            if LiveActivityController.shared.remoteAlertsReady, !LiveActivityController.isForeground { return }
            #endif
            // 需要批准且只有一个请求时，把它的 id 带进通知，按钮只处理这一个。
            let pending = store.agents[e.agentId]?.pendingPermissions ?? []
            let requestId = e.reason == "permission" && pending.count == 1 ? pending.first?.id : nil
            let agent = store.agents[e.agentId]
            let agentTitle = agent?.displayTitle ?? "会话"
            let workspace = agent?.workspaceId.flatMap { store.workspaces[$0] }
            let workspaceTitle = workspace?.title.flatMap { $0.isEmpty ? nil : $0 } ?? agentTitle
            NotificationManager.shared.post(e, hostLabel: store.label, workspaceTitle: workspaceTitle, agentTitle: agentTitle,
                                            requestId: requestId)
        }
        return store
    }

    private func persist() {
        let stored = hosts.map { StoredHost(label: $0.label, offer: $0.offer) }
        if let data = try? JSONEncoder().encode(stored) { Keychain.save(data, account: Self.hostsKey) }
    }
}
