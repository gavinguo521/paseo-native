// Timeline rows. Official: components/message.tsx, tool-call-details.tsx, agent-stream/view.tsx.

import PaseoKit
import SwiftUI

/// Official chat display setting: everything expanded, tool calls folded, or finished turns folded too.
enum TimelineDetail: String, CaseIterable {
    case full, collapseTools, collapseTurns
    var label: String {
        switch self {
        case .full: String(localized: "完整显示")
        case .collapseTools: String(localized: "折叠工具调用")
        case .collapseTurns: String(localized: "折叠做完的回合")
        }
    }
}

/// 展示单行消息、工具与思考分组，以及已完成操作的摘要；助手正文始终按原顺序可见。
indirect enum DisplayItem: Identifiable {
    case row(TimelineRow, footer: Bool, turn: TurnInfo? = nil)
    case group(id: String, rows: [TimelineRow])
    case turnSummary(id: String, label: String, hidden: [DisplayItem])

    var id: String {
        switch self {
        case .row(let r, _, _): r.id
        case .group(let id, _): id
        case .turnSummary(let id, _, _): id
        }
    }

    /// `separateReasoning`: with 设置「自动展开思考过程」 on, thinking is not merged into tool-call groups, so each
    /// thought shows on its own, opened (official: presentation groups reasoning only while Expand thinking is off).
    static func build(_ rows: [TimelineRow], lastTurnActive: Bool, collapse: Bool = true,
                      separateReasoning: Bool = false) -> [DisplayItem] {
        let rows = dropReadImageEchoes(rows)
        // Split into turns: each user message starts one.
        var turns: [[TimelineRow]] = []
        for r in rows {
            if r.item.startsTurn { turns.append([r]) }
            else if turns.isEmpty { turns.append([r]) }
            else { turns[turns.count - 1].append(r) }
        }
        var out: [DisplayItem] = []
        for (i, turn) in turns.enumerated() {
            let isLast = i == turns.count - 1
            var body = turn
            var head: TimelineRow?
            if let first = body.first, first.item.startsTurn { head = first; body.removeFirst() }
            if let head { out.append(.row(head, footer: true)) }
            var items: [DisplayItem]
            let finalIndex = body.lastIndex { if case .assistantMessage = $0.item { true } else { false } }
            // 助手正文不能因后续补充回复而被收起；只折叠已完成的普通工具操作。
            let worthFolding = finalIndex.map { body[..<$0].contains { r in
                switch r.item {
                case .toolCall(_, _, _, let detail, _, let m): m == nil && !detail.isPlan && r.item.outgoingMessage == nil
                default: false
                }
            } } ?? false
            if (isLast && lastTurnActive) || !collapse || !worthFolding {
                // A finished turn's reply gets the footer even when plugin rows (turn-speed, next-input) follow it.
                items = groupOps(body, finalIndex: isLast && lastTurnActive ? nil : finalIndex, separateReasoning: separateReasoning)
            } else {
                let finalIndex = finalIndex!
                items = []
                var activity: [TimelineRow] = []
                func flushActivity() {
                    guard let first = activity.first else { return }
                    let hasTool = activity.contains { if case .toolCall = $0.item { true } else { false } }
                    if hasTool {
                        let label = workSummary(activity)
                        items.append(.turnSummary(id: "turn-" + first.id,
                            label: label.isEmpty ? String(localized: "查看轮次详情") : label,
                            hidden: groupOps(activity, finalIndex: nil, separateReasoning: separateReasoning)))
                    } else {
                        items += groupOps(activity, finalIndex: nil, separateReasoning: separateReasoning)
                    }
                    activity.removeAll(keepingCapacity: true)
                }
                for row in body[..<finalIndex] {
                    switch row.item {
                    case .reasoning:
                        activity.append(row)
                    case .toolCall(_, _, _, let detail, _, let message)
                        where message == nil && !detail.isPlan && row.item.outgoingMessage == nil:
                        activity.append(row)
                    default:
                        // 正文、计划、上下文压缩提示等保持可见，操作摘要不能跨过它们。
                        flushActivity()
                        items.append(.row(row, footer: false))
                    }
                }
                flushActivity()
                items += groupOps(Array(body[finalIndex...]), finalIndex: 0, separateReasoning: separateReasoning)
            }
            // The reply that closes a finished turn carries how long it took and the whole turn's text.
            if !(isLast && lastTurnActive),
               let k = items.lastIndex(where: { if case .row(let r, true, _) = $0, case .assistantMessage = r.item { true } else { false } }),
               case .row(let r, _, _) = items[k] {
                let start = head?.timestamp ?? body.first?.timestamp
                let duration = zip(start, r.timestamp).map { $1.timeIntervalSince($0) }
                let text = body.compactMap { if case .assistantMessage(let t, _) = $0.item { t } else { nil } }.joined(separator: "\n\n")
                items[k] = .row(r, footer: true, turn: TurnInfo(duration: duration, text: text, speed: TurnSpeed(rows: body)))
            }
            out += items
        }
        return out
    }

    /// Merges consecutive tool calls and thinking; `finalIndex` marks the reply that gets a footer.
    private static func groupOps(_ rows: [TimelineRow], finalIndex: Int?, separateReasoning: Bool) -> [DisplayItem] {
        var out: [DisplayItem] = []
        var run: [TimelineRow] = []
        func flush() {
            if !run.isEmpty { out.append(.group(id: "g-" + run[0].id, rows: run)) }
            run = []
        }
        for (i, r) in rows.enumerated() {
            switch r.item {
            case .toolCall(_, _, _, let detail, _, let agentMessage)
                where agentMessage == nil && !detail.isPlan && r.item.outgoingMessage == nil:
                run.append(r)
            case .reasoning where !separateReasoning:
                run.append(r)
            case .assistantMessage:
                flush()
                out.append(.row(r, footer: i == finalIndex || i == rows.count - 1))
            default:
                flush()
                out.append(.row(r, footer: false))
            }
        }
        flush()
        return out
    }
}

extension DisplayItem {
    /// When a tool returns an image, the daemon follows the tool call with an assistant message that is only that
    /// image (`![Image](file:///…/paseo-attachments-…)`, provider-image-output.ts). After an image Read the picture
    /// is already shown by the read's thumbnail strip, so that echo is dropped (it showed the same image twice,
    /// once small and once large). Image messages after anything else are kept.
    static func dropReadImageEchoes(_ rows: [TimelineRow]) -> [TimelineRow] {
        var out: [TimelineRow] = []
        out.reserveCapacity(rows.count)
        var afterImageRead = false
        for var r in rows {
            if afterImageRead, case .assistantMessage(let text, let messageId) = r.item {
                if isImageOnlyMarkdown(text) { continue }
                // 实时推送时回声没有消息 id，紧接着的回复会被拼进同一条（「![Image](…)时间线还在加载…」），
                // 整条就不再「只有图片」：去掉开头的附件图片，留下后面的文字。
                if let rest = droppingLeadingAttachmentImages(text) {
                    if rest.isEmpty { continue }
                    r.item = .assistantMessage(text: rest, messageId: messageId)
                }
            }
            afterImageRead = r.readImagePath != nil
            out.append(r)
        }
        return out
    }

    /// daemon 回声的图片都在 paseo-attachments 目录（provider-image-output.ts）；只认这种，别误删回复里真正的图片。
    private static let leadingAttachmentImages = try! NSRegularExpression(
        pattern: #"^\s*(?:!\[[^\]]*\]\([^)\s]*paseo-attachments[^)\s]*\)\s*)+"#)

    /// 开头是附件图片时返回去掉它们之后的文字，否则 nil。
    static func droppingLeadingAttachmentImages(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = leadingAttachmentImages.firstMatch(in: text, range: NSRange(location: 0, length: min(ns.length, 4096))),
              m.range.length > 0 else { return nil }
        return ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each run of whitespace belongs to exactly one place (leading, or after an image), so a non-matching text
    /// cannot make the matcher backtrack exponentially.
    private static let imageOnly = try! NSRegularExpression(pattern: #"^\s*(?:!\[[^\]]*\]\([^)\s]+\)\s*)+$"#)

    static func isImageOnlyMarkdown(_ text: String) -> Bool {
        // Image echoes are a line or two; anything long is a real reply, and skipping it bounds the regex work.
        guard text.utf16.count <= 4096 else { return false }
        return imageOnly.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// The last `DisplayItem.build` for one session view: redraws that leave the rows alone (scroll position,
/// find bar, status changes) reuse it instead of regrouping the whole history.
@MainActor final class DisplayItemCache {
    private var key: (revision: Int, lastTurnActive: Bool, collapse: Bool, separateReasoning: Bool)?
    private var items: [DisplayItem] = []
    private var positions: [String: Int]?
    private var visibilityReads = 0
    private struct TurnKey: Equatable {
        var revisions: [Int]
        var active: Bool
        var collapse: Bool
        var reasoning: Bool
    }
    private var turns: [String: (TurnKey, [DisplayItem])] = [:]
    /// 要默认折叠的「来源会话已完成」卡片（行 id），随 items 一起算。
    private(set) var foldedCompletions: Set<String> = []
    /// paseo-peer tell 输出里的「机器名 → serverId」，让同一会话里的 who / logs / wait 也能找到对应的主机。
    private(set) var peerServers: [String: String] = [:]

    func items(_ timeline: AgentTimeline?, lastTurnActive: Bool, collapse: Bool, separateReasoning: Bool) -> [DisplayItem] {
        let k = (revision: timeline?.revision ?? -1, lastTurnActive: lastTurnActive, collapse: collapse,
                 separateReasoning: separateReasoning)
        if let key, key == k { return items }
        var ranges: [Range<Int>] = []
        let rows = timeline?.rows ?? []
        var start = 0
        for i in rows.indices where i > 0 && rows[i].item.startsTurn {
            ranges.append(start..<i)
            start = i
        }
        if start < rows.count { ranges.append(start..<rows.count) }
        var next: [String: (TurnKey, [DisplayItem])] = [:]
        items = []
        for (index, range) in ranges.enumerated() {
            let id = rows[range.lowerBound].id
            let turnKey = TurnKey(revisions: rows[range].map(\.revision), active: index == ranges.count - 1 && lastTurnActive,
                                  collapse: collapse, reasoning: separateReasoning)
            let built: [DisplayItem]
            if let cached = turns[id], cached.0 == turnKey { built = cached.1 }
            else {
                built = DisplayItem.build(Array(rows[range]), lastTurnActive: turnKey.active, collapse: collapse,
                                          separateReasoning: separateReasoning)
            }
            next[id] = (turnKey, built)
            items += built
        }
        turns = next
        foldedCompletions = Self.foldedCompletions(rows)
        peerServers = Self.peerServers(rows)
        positions = nil
        visibilityReads = 0
        key = k
        return items
    }
    static func peerServers(_ rows: [TimelineRow]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            guard case .toolCall(_, _, _, .shell(_, _, let output?, _), _, nil) = row.item, output.contains("serverId"),
                  let message = row.item.outgoingMessage, let machine = message.machine, let server = message.serverId else { continue }
            out[machine] = server
        }
        return out
    }

    /// 来源会话这一轮发过主动消息时，完成通知里的最后回复多半只是收尾，折叠；没发过时最后回复就是它交来的结果，展开。
    /// 「这一轮」= 同一来源上一次完成之后。会话 id 只在所属主机内唯一，所以带上 serverId。
    static func foldedCompletions(_ rows: [TimelineRow]) -> Set<String> {
        var messaged: Set<String> = []
        var folded: Set<String> = []
        for row in rows {
            guard case .toolCall(_, _, _, _, _, let message?) = row.item,
                  let id = message["sender"]?["id"]?.stringValue, !id.isEmpty else { continue }
            let source = (message["sender"]?["serverId"]?.stringValue ?? "") + ":" + id
            switch message["event"]?.stringValue ?? "message" {
            case "message": messaged.insert(source)
            case "finished": if messaged.remove(source) != nil { folded.insert(row.id) }
            default: break
            }
        }
        return folded
    }

    /// 可见 ID 通常只有一屏；按已有显示顺序找锚点，不在每次滚动时扫描整段历史。
    func firstVisibleID(in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        visibilityReads += 1
        // 流式输出通常每版只查询一次；此时不额外建立整份索引。
        if positions == nil, visibilityReads < 3 {
            let visible = Set(ids)
            return items.first { visible.contains($0.id) }?.id
        }
        if positions == nil {
            var indexed: [String: Int] = [:]
            for (index, item) in items.enumerated() where indexed[item.id] == nil { indexed[item.id] = index }
            positions = indexed
        }
        return ids.compactMap { id in positions?[id].map { (id, $0) } }.min { $0.1 < $1.1 }?.0
    }

}

private func zip(_ a: Date?, _ b: Date?) -> (Date, Date)? {
    guard let a, let b else { return nil }
    return (a, b)
}

struct TimelineItemView: View {
    let item: DisplayItem

    var body: some View {
        switch item {
        case .row(let r, let footer, let turn): RowView(row: r, footer: footer, turn: turn)
        case .group(_, let rows): ToolGroupView(rows: rows)
        case .turnSummary(let id, let label, let hidden): TurnSummaryView(id: id, label: label, hidden: hidden)
        }
    }
}

private struct TurnSummaryView: View {
    let id: String
    /// What the turn did; how long it took is under the reply.
    let label: String
    let hidden: [DisplayItem]
    @State private var localExpanded = false
    @Environment(\.timelineReadingState) private var reading
    private var expanded: Bool { reading?.expanded[id] ?? localExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy(duration: 0.2)) {
                let next = !expanded
                localExpanded = next
                reading?.expanded[id] = next
            } } label: {
                HStack(spacing: 4) {
                    Text(label).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: Theme.base))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(hidden) { TimelineItemView(item: $0) }
            } else {
                ReadImageStrip(rows: hidden.flatMap(\.rows))
            }
        }
    }
}

/// Images the agent looked at (screenshots…), kept visible while their steps are folded away.
/// The read result carries no pixels: they are fetched by path the first time they show and kept
/// (ImageSnapshotCache), so a file overwritten later doesn't change older steps.
struct ReadImageStrip: View {
    let rows: [TimelineRow]

    /// Every read, in order: the same path read twice may have shown two different pictures.
    private var images: [TimelineRow] { rows.filter { $0.readImagePath != nil } }

    var body: some View {
        let images = images
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { r in
                        let p = r.readImagePath ?? ""
                        MarkdownImage(alt: (p as NSString).lastPathComponent, url: p, maxSize: CGSize(width: 220, height: 140), cacheKey: r.id)
                            .frame(height: 140)
                    }
                }
            }
            .scrollDisabled(images.count < 3)
        }
    }
}

extension DisplayItem {
    /// Every timeline row inside, in order.
    var rows: [TimelineRow] {
        switch self {
        case .row(let r, _, _): [r]
        case .group(_, let rows): rows
        case .turnSummary(_, _, let hidden): hidden.flatMap(\.rows)
        }
    }
}

extension TimelineRow {
    static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A file the agent read that is an image.
    var readImagePath: String? {
        guard case .toolCall(_, _, _, let detail, _, _) = item, case .read(let path, _) = detail, Self.isImagePath(path) else { return nil }
        return path
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    if s < 60 { return String(localized: "\(s)秒") }
    if s < 3600 { return String(localized: "\(s / 60)分钟\(s % 60)秒") }
    return String(localized: "\(s / 3600)小时\(s % 3600 / 60)分钟")
}

func formatTimestamp(_ d: Date) -> String {
    let cal = Calendar.current
    let time = d.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(d) { return time }
    if cal.isDateInYesterday(d) { return String(localized: "昨天 \(time)") }
    return d.formatted(.dateTime.month().day()) + " " + time
}

/// Per-agent actions reachable from timeline rows.
/// Message actions handed down the timeline. A class so the environment value keeps its identity across
/// re-renders (a fresh struct of closures made every row redraw on every streamed token).
final class TimelineActions {
    let rewindModes: () -> [String]
    let rewind: (String, String) -> Void
    /// Fork the conversation up to an assistant message: into a new tab of this workspace, or a new workspace.
    let fork: (_ messageId: String?, _ newWorkspace: Bool) -> Void

    init(rewindModes: @escaping () -> [String] = { [] }, rewind: @escaping (String, String) -> Void = { _, _ in },
         fork: @escaping (String?, Bool) -> Void = { _, _ in }) {
        self.rewindModes = rewindModes
        self.rewind = rewind
        self.fork = fork
    }
}

/// Reads a file on the agent's machine; stable identity for the same reason as TimelineActions.
final class HostFileReader: Sendable {
    let cacheScope: String
    let read: @Sendable (String) async -> Data?
    let messageImages: @Sendable (String) async throws -> [MessageImage]
    init(cacheScope: String = UUID().uuidString,
         messageImages: @escaping @Sendable (String) async throws -> [MessageImage] = { _ in [] },
         _ read: @escaping @Sendable (String) async -> Data?) {
        self.cacheScope = cacheScope
        self.read = read
        self.messageImages = messageImages
    }
}

final class AgentTitleLookup {
    let lookup: @MainActor (String) -> String?
    init(_ lookup: @escaping @MainActor (String) -> String?) { self.lookup = lookup }
}

struct MessageSender {
    let name: String
    let ref: AgentRef?

    @MainActor static func resolve(_ sender: JSONValue?, host: HostStore?) -> MessageSender {
        let id = sender?["id"]?.stringValue ?? ""
        // 会话 ID 只在所属主机内唯一；短 ID 也必须唯一匹配才能导航。
        let matches = id.isEmpty || host?.agents[id] != nil ? [] : (host?.agents.values.filter { $0.id == id || $0.id.hasPrefix(id) } ?? [])
        let agent = host?.agents[id] ?? (matches.count == 1 ? matches.first : nil)
        let title = agent?.displayTitle ?? sender?["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? (id.isEmpty ? String(localized: "其他会话") : String(id.prefix(7)))
        let workspace = agent?.workspaceId.flatMap { host?.workspaces[$0] }
        let workspaceName = workspace.flatMap { $0.name.isEmpty ? nil : $0.name }
        return MessageSender(name: workspaceName.map { "\($0) / \(title)" } ?? title,
                             ref: host.flatMap { host in agent.map { AgentRef(serverId: host.id, agentId: $0.id) } })
    }
}

final class MessageSenderLookup {
    let lookup: @MainActor (JSONValue?) -> MessageSender
    let open: @MainActor (AgentRef) -> Void
    let sourceHost: @MainActor (JSONValue?) -> HostStore?
    let currentHostID: String
    let showHistory: @MainActor () -> Void
    /// paseo-peer 的机器短名 → App 里的主机：local 是当前主机；否则主机名等于或包含短名（studio ↔「Gavin的Mac Studio」），唯一才算。
    let hostNamed: @MainActor (String) -> HostStore?
    init(host: HostStore, model: AppModel, navigate: (@MainActor (AgentRef) -> Void)? = nil) {
        currentHostID = host.id
        hostNamed = { name in
            let key = name.lowercased()
            if key == "local" { return host }
            let labels = model.hosts.map { ($0, $0.label.lowercased()) }
            if let exact = labels.filter({ $0.1 == key }).map(\.0).first { return exact }
            let partial = labels.filter { $0.1.contains(key) }.map(\.0)
            return partial.count == 1 ? partial[0] : nil
        }
        sourceHost = { sender in sender?["serverId"]?.stringValue.map { model.host($0) } ?? host }
        lookup = { sender in
            let source = sender?["serverId"]?.stringValue.map { model.host($0) } ?? host
            return MessageSender.resolve(sender, host: source)
        }
        open = navigate ?? { model.openMessageSender($0) }
        showHistory = { model.destination = .history; model.revealDetail += 1 }
    }
}

/// 来源信息集中展示，菜单与恢复入口在手机和桌面保持一致。
struct MessageSenderButton: View {
    let sender: JSONValue
    var textAlignment: TextAlignment = .trailing
    /// 跨会话卡片的标题：把来源名放进整句（如「…」发来消息），名字用强调色表示可点；nil 时是用户消息下的「由…发送」。
    var phrase: ((String) -> String)? = nil
    /// 整句的字体和颜色（工具步骤里用更小、更淡的字）。
    var phraseFont: Font = .system(size: 13, weight: .medium)
    var phraseColor: Color = Theme.foreground
    var phraseLineLimit = 2
    @Environment(\.messageSender) private var lookup
    @Environment(\.openWindow) private var openWindow
    @State private var showingDetails = false

    private var source: MessageSender? { lookup?.lookup(sender) }
    private var host: HostStore? { lookup?.sourceHost(sender) }
    private var fullName: String {
        let name = source?.name ?? sender["title"]?.stringValue ?? sender["id"]?.stringValue ?? String(localized: "其他会话")
        if let host, host.id != lookup?.currentHostID { return "\(host.label) · \(name)" }
        return name
    }
    private var link: URL? {
        guard let ref = source?.ref else { return nil }
        return PaseoActivityLink.url(serverId: ref.serverId, agentId: ref.agentId)
    }

    var body: some View {
        Button {
            if let ref = source?.ref, host?.state == .connected, host?.agents[ref.agentId]?.archivedAt == nil {
                lookup?.open(ref)
            } else { showingDetails = true }
        } label: {
            if let phrase {
                Text(Self.sentence(phrase(fullName), name: fullName))
                    .font(phraseFont).foregroundStyle(phraseColor)
                    .lineLimit(phraseLineLimit).truncationMode(.middle).multilineTextAlignment(textAlignment)
                    #if os(iOS)
                    .frame(minHeight: 32)
                    #endif
                    .contentShape(Rectangle())
            } else {
                Label("由「\(fullName)」发送", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .lineLimit(2).multilineTextAlignment(textAlignment)
                    .padding(.vertical, 6)
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #endif
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain).help(fullName)
        .contextMenu {
            Button("查看完整名称与状态") { showingDetails = true }
            if let link {
                Button("复制会话链接", systemImage: "link") { Pasteboard.copy(link.absoluteString) }
            }
            #if os(macOS)
            if let ref = source?.ref {
                Button("在新窗口打开", systemImage: "macwindow.badge.plus") { openWindow(value: ref) }
            }
            #endif
        }
        .sheet(isPresented: $showingDetails) {
            MessageSenderDetails(sender: sender, lookup: lookup)
        }
    }
}

extension MessageSenderButton {
    /// 整句里只给来源名上强调色。
    static func sentence(_ text: String, name: String) -> AttributedString {
        var out = AttributedString(text)
        if let range = out.range(of: name) { out[range].foregroundColor = Theme.accentBright }
        return out
    }
}

struct MessageSenderDetails: View {
    let sender: JSONValue
    let lookup: MessageSenderLookup?
    @Environment(\.dismiss) private var dismiss
    @State private var fetched: Agent?
    @State private var error: String?
    @State private var loading = false
    private var host: HostStore? { lookup?.sourceHost(sender) }
    private var source: MessageSender? { lookup?.lookup(sender) }
    private var agent: Agent? { fetched ?? source?.ref.flatMap { host?.agents[$0.agentId] } }

    private var fetchedName: String? {
        guard let fetched else { return nil }
        let workspace = fetched.workspaceId.flatMap { host?.workspaces[$0] }
        return workspace.flatMap { $0.name.isEmpty ? nil : $0.name }.map { "\($0) / \(fetched.displayTitle)" } ?? fetched.displayTitle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(fetchedName ?? source?.name ?? sender["title"]?.stringValue ?? sender["id"]?.stringValue ?? String(localized: "其他会话"))
                        .font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let host { Text(host.label).foregroundStyle(Theme.muted) }
                    if host == nil {
                        Text("发送方主机尚未添加。请先从侧栏添加对应主机。")
                    } else if host?.state != .connected {
                        Text("发送方主机未连接，连接后可以查看会话。")
                        if host?.automaticConnectionPaused == true {
                            Button("恢复自动连接") { host?.setAutomaticConnectionPaused(false) }
                        } else {
                            Button("连接主机") { host?.reconnectNow() }
                        }
                    } else if let agent {
                        Text(agent.archivedAt == nil ? "会话可访问" : "这个会话已归档")
                        Button(agent.archivedAt == nil ? "打开会话" : "在历史中查找") {
                            guard let host else { return }
                            if agent.archivedAt != nil { lookup?.showHistory() }
                            else { lookup?.open(AgentRef(serverId: host.id, agentId: agent.id)) }
                            dismiss()
                        }
                        if let url = host.flatMap({ PaseoActivityLink.url(serverId: $0.id, agentId: agent.id) }) {
                            Button("复制会话链接", systemImage: "link") { Pasteboard.copy(url.absoluteString) }
                        }
                    } else if !loading && error == nil {
                        Text("会话不在当前列表中，可以向主机查询。")
                    }
                    if let error { Text(error).foregroundStyle(Theme.destructive).textSelection(.enabled) }
                    if loading { ProgressView() }
                    if host?.state == .connected {
                        Button("重新查询") { Task { await refresh() } }.disabled(loading)
                    }
                    Button("查看会话历史") { lookup?.showHistory(); dismiss() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .navigationTitle("消息来源")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
        .frame(minWidth: 300, idealWidth: 440, minHeight: 320)
        .task(id: host?.state == .connected) {
            if agent == nil { await refresh() }
        }
    }

    private func refresh() async {
        guard !loading, let host, host.state == .connected, let id = sender["id"]?.stringValue else { return }
        loading = true; error = nil
        defer { loading = false }
        do { fetched = try await host.fetchAgentSnapshot(source?.ref?.agentId ?? id) }
        catch { self.error = String(localized: "无法查询会话：\(String(describing: error))") }
    }
}

extension EnvironmentValues {
    @Entry var messageSender: MessageSenderLookup? = nil
    @Entry var sentImages: [String: [ImageAttachment]] = [:]
    @Entry var messageImagesConnected = false
    @Entry var timelineActions = TimelineActions()
    /// Reads a file on the agent's machine (images in replies that live there). Paths may be relative to the agent's cwd.
    /// Agent id → title on the same host, for tool details that target other sessions.
    @Entry var agentTitle: AgentTitleLookup? = nil
    /// Text being searched in the session; every occurrence is highlighted.
    @Entry var findQuery: String = ""
    /// DisplayItemCache.foldedCompletions：默认折叠的完成卡片。
    @Entry var foldedCompletions: Set<String> = []
    @Entry var hostFileReader: HostFileReader? = nil
}

private struct MessageMenu: View {
    let text: String
    var messageId: String? = nil
    var isAssistant = false
    /// Whole turn's replies (only on the turn's last reply).
    var turnText: String? = nil
    @Environment(\.timelineActions) private var actions
    @State private var selecting = false

    var body: some View {
        Menu {
            Button("复制", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
            Button("选择文本", systemImage: "text.cursor") { selecting = true }
            if let turnText, turnText != text { Button("复制整轮回复", systemImage: "doc.on.doc.fill") { Pasteboard.copy(turnText) } }
            let modes = actions.rewindModes()
            if let messageId, !modes.isEmpty {
                Divider()
                ForEach(modes, id: \.self) { mode in
                    Button(mode == "conversation" ? "回退对话到这里" : mode == "files" ? "回退文件到这里" : "回退对话和文件到这里",
                           systemImage: "arrow.uturn.backward") { actions.rewind(messageId, mode) }
                }
            }
            if isAssistant {
                Divider()
                Button("分叉到新标签页", systemImage: "arrow.triangle.branch") { actions.fork(messageId, false) }
                Button("分叉到新工作区", systemImage: "folder.badge.plus") { actions.fork(messageId, true) }
            }
        } label: {
            // 无边框样式下只认图标画出来的像素：「⋯」只有三个小点，必须给整块矩形作为点击区域，否则很难点中。
            Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("消息操作")
        // Replies are Markdown; show them as plain text. The user's own messages are already plain.
        .sheet(isPresented: $selecting) { SelectTextSheet(text: isAssistant ? MarkdownBlock.plainText(text) : text) }
    }
}

/// The user's (or another agent's) message, folded when long. Official: user-message.tsx "Show more".
struct UserBubble: View {
    let text: String
    var pending = false
    /// Another session sent this (official "Sent by …").
    var sender: String? = nil
    var openSender: (() -> Void)? = nil
    var senderMetadata: JSONValue? = nil
    @State private var expanded = false
    @State private var markdownCache = MarkdownRenderCache()
    @Environment(\.findQuery) private var findQuery

    private func senderLabel(_ name: String) -> some View {
        Label("由「\(name)」发送", systemImage: "bubble.left.and.text.bubble.right")
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
            .lineLimit(2).multilineTextAlignment(.trailing)
            .contentShape(Rectangle())
    }

    private static let foldLines = 14
    private var hasTable: Bool { markdownCache.blocks(text).contains { if case .table = $0 { true } else { false } } }
    private var long: Bool { text.count > 900 || text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.foldLines }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let senderMetadata {
                MessageSenderButton(sender: senderMetadata)
            } else if let sender {
                if let openSender {
                    Button(action: openSender) { senderLabel(sender) }
                        .buttonStyle(.plain)
                        .help(sender)
                } else {
                    senderLabel(sender)
                }
            }
            HStack {
                Spacer(minLength: 64)
                VStack(alignment: .leading, spacing: 6) {
                    if hasTable {
                        MarkdownView(text: text, renderMedia: false)
                    } else {
                        Text({ var a = AttributedString(text); highlight(&a, findQuery); return a }())
                        .font(.system(size: Theme.content))
                        .lineSpacing(MarkdownView.lineSpacing)
                        .textSelection(.enabled)
                        .lineLimit(long && !expanded && findQuery.isEmpty ? Self.foldLines : nil)
                    }
                    if long && !hasTable {
                        Button(expanded ? "收起" : "显示全部") { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 22))
                .opacity(pending ? 0.6 : 1)
            }
        }
    }
}

/// 新会话的第一条消息：点「开始」到 daemon 回复之间。
struct PendingStart {
    let text: String
    let images: [ImageAttachment]
}

/// daemon 要先把提供方进程拉起来才回复（实测 2～3 秒），这段时间先显示刚发的消息，不让界面停在草稿页。
/// 官方 workspace-tab.tsx 提交中同样先渲染会话视图。
struct PendingStartView: View {
    let pending: PendingStart

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 6) {
                if !pending.images.isEmpty {
                    UserMessageImages(messageId: "pending-start", localImages: pending.images)
                }
                UserBubble(text: pending.text, pending: true)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在启动会话…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding(4)
            .modifier(ReadingColumn())
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: .infinity)
    }
}

struct TurnInfo {
    let duration: TimeInterval?
    /// All assistant text of the turn, for "复制整轮回复".
    let text: String
    /// turn-speed plugin stats for this turn, shown after the duration.
    var speed: TurnSpeed? = nil
}

private struct RowView: View {
    @Environment(\.messageSender) private var messageSender
    @Environment(\.foldedCompletions) private var foldedCompletions
    /// paseo-peer tell 失败（退出码非 0）时的输出末尾，显示在「发给…失败」卡片里。
    static func shellFailure(_ detail: ToolCallDetail) -> String? {
        guard case .shell(_, _, let output, let code?) = detail, code != 0 else { return nil }
        let tail = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
        return tail.isEmpty ? String(localized: "退出码 \(code)") : String(tail)
    }
    let row: TimelineRow
    let footer: Bool
    var turn: TurnInfo? = nil

    /// Copy, message menu, time and duration under the last reply of a turn.
    @ViewBuilder private func footerActions(text: String, messageId: String?) -> some View {
        // 两个图标按钮各带 28×24 的点击区域，彼此不再加间距，看起来和原来一样近
        HStack(spacing: 0) {
            Button { Pasteboard.copy(text) } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("复制")
                .accessibilityLabel("复制")
            MessageMenu(text: text, messageId: messageId, isAssistant: true, turnText: turn?.text)
        }
        // 图标本身仍和正文左边对齐（点击区域往左多出的部分不占版面）
        .padding(.leading, -7)
        if let t = row.timestamp { Text(formatTimestamp(t)).lineLimit(1) }
        if let d = turn?.duration, d >= 1 { Text(String(localized: "用时 \(formatDuration(d))")).lineLimit(1) }
    }
    @Environment(\.sentImages) private var sentImages

    var body: some View {
        switch row.item {
        case .userMessage(let text, _):
            VStack(alignment: .trailing, spacing: 6) {
                UserMessageImages(messageId: row.id, localImages: sentImages[row.id] ?? [])
                // 只发图片时文字为空，不画空气泡。
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    UserBubble(text: text, pending: row.isPending)
                }
                HStack(spacing: 12) {
                    if !row.isPending { MessageMenu(text: text, messageId: row.id) }
                    if let t = row.timestamp { Text(row.isPending ? String(localized: "发送中…") : formatTimestamp(t)) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.extraMuted)
            }
            .padding(.top, 16)
        case .assistantMessage(let text, let messageId):
            VStack(alignment: .leading, spacing: 8) {
                MarkdownView(text: text, continuousSelection: true)
                if footer {
                    // One line when it fits; otherwise the speed moves to a second line. A footer wider than the column
                    // widened the whole timeline on iPhone, pushing every reply against the left edge until the next layout.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            footerActions(text: text, messageId: messageId)
                            if let speed = turn?.speed { Text(speed.short).monospacedDigit().lineLimit(1).help(speed.full) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 14) { footerActions(text: text, messageId: messageId) }
                            if let speed = turn?.speed { Text(speed.short).monospacedDigit().help(speed.full) }
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.extraMuted)
                }
            }
        case .reasoning:
            ToolGroupView(rows: [row])
        case .toolCall(_, _, _, let detail, _, let agentMessage):
            if let agentMessage, agentMessage["event"]?.stringValue == "message", let text = agentMessage["text"]?.stringValue {
                CrossSessionMessageCard(message: agentMessage, text: text, timestamp: row.timestamp)
                    .padding(.top, 16)
            } else if let agentMessage {
                CrossSessionMessageCard(message: agentMessage, text: agentMessage["text"]?.stringValue ?? "",
                                        foldable: foldedCompletions.contains(row.id), timestamp: row.timestamp)
            } else if case .plan(let text) = detail, case .toolCall(_, _, let status, _, _, _) = row.item {
                PlanCard(text: text, status: status)
            } else if let outgoing = row.item.outgoingMessage, case .toolCall(_, _, let status, let detail, let error, _) = row.item {
                OutgoingMessageCard(message: outgoing, status: status, error: error, shellFailure: Self.shellFailure(detail),
                                    timestamp: row.timestamp)
            } else {
                ToolGroupView(rows: [row])
            }
        case .todo(let items):
            TodoCard(items: items)
        case .error(let message):
            Banner(level: "error", message: message)
        case .notification(let level, let message):
            Banner(level: level, message: message)
        case .compaction(let status, let trigger, let preTokens):
            HStack {
                VStack { Divider() }
                Text(status == "loading" ? String(localized: "正在压缩上下文…")
                     : (trigger == "manual" ? String(localized: "已手动压缩上下文") : trigger == "auto" ? String(localized: "已自动压缩上下文") : String(localized: "上下文已压缩"))
                        + (preTokens.map { String(localized: "（压缩前 \(formatTokens($0))）") } ?? ""))
                    .font(.caption).foregroundStyle(Theme.muted)
                VStack { Divider() }
            }
        case .plugin(_, let pluginId, let kind, _, let data):
            PluginRowView(rowId: row.id, pluginId: pluginId, kind: kind, data: data)
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: Tool calls and thinking

struct ToolGroupView: View {
    let rows: [TimelineRow]
    @Environment(\.toolDetailsAction) private var details
    @AppStorage("autoExpandReasoning", store: AppDefaults.store) private var autoExpandReasoning = true
    @AppStorage("timelineDetail", store: AppDefaults.store) private var timelineDetail = TimelineDetail.collapseTurns.rawValue
    @State private var userExpanded: Bool?
    @Environment(\.timelineReadingState) private var reading
    private var expansionKey: String { "tools-" + (rows.first?.id ?? "") }
    private var expanded: Bool {
        reading?.expanded[expansionKey] ?? userExpanded ?? (timelineDetail == TimelineDetail.full.rawValue
            || (autoExpandReasoning && rows.allSatisfy { if case .reasoning = $0.item { true } else { false } }))
    }

    private func toggleExpanded() {
        let next = !expanded
        userExpanded = next
        reading?.expanded[expansionKey] = next
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading) {
                if rows.count == 1, case .reasoning(let text) = rows[0].item { reasoning(text) }
                else { group }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let details, let first = rows.first {
                Button { details.open(first.id) } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 36, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("查看工具详情").help("查看工具详情")
            }
        }
    }

    /// A thought on its own, laid out like the other step rows (same icon column, title weight and text
    /// start), without the completed tick or a second heading. Collapsed it previews the first line.
    @ViewBuilder private func reasoning(_ raw: String) -> some View {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let streaming = rows[0].isStreaming
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { toggleExpanded() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.system(size: 15, weight: .light)).frame(width: 18)
                        .foregroundStyle(Theme.muted)
                    Text(streaming ? "思考中…" : "思考").font(.system(size: Theme.base, weight: .semibold))
                        .foregroundStyle(Theme.foreground.opacity(0.75))
                    if !expanded {
                        Text(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                            .font(.system(size: Theme.base)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, !text.isEmpty {
                Text(text).font(.system(size: Theme.base)).foregroundStyle(Theme.muted)
                    .lineSpacing(3).textSelection(.enabled)
                    .padding(.leading, 26)
                    .transition(.opacity)
            }
        }
    }

    private var group: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { toggleExpanded() } } label: {
                HStack(spacing: 8) {
                    icon
                    if let command {
                        // A command line is data, not a heading: one quiet monospaced line.
                        Text(isBackground ? "后台运行" : "运行").font(.system(size: Theme.base, weight: .semibold))
                            .foregroundStyle(Theme.foreground.opacity(0.75))
                        Text(command).lineLimit(1).truncationMode(.tail)
                            .font(.system(size: Theme.code, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    } else if headerAction == nil {
                        Text(summary).lineLimit(1).truncationMode(.middle)
                            .font(.system(size: Theme.base, weight: .semibold))
                            .foregroundStyle(Theme.foreground.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: Theme.base))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 会话名要能单独点，不能放进展开 / 收起的按钮里：盖在图标右边。
            .overlay(alignment: .leading) {
                if let headerAction { PaseoAgentActionLabel(action: headerAction).padding(.leading, 26).padding(.trailing, 8) }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { ToolDetailView(row: $0, showHeader: true) }
                }
                .padding(.leading, 18)
                .transition(.opacity)
            } else {
                ReadImageStrip(rows: rows).padding(.leading, 26)
            }
        }
    }

    private var running: Bool {
        rows.contains {
            if case .toolCall(_, _, let status, _, _, _) = $0.item { return status == "running" }
            return $0.isStreaming
        }
    }

    private var failed: Bool {
        rows.contains { if case .toolCall(_, _, let s, _, _, _) = $0.item { s == "failed" } else { false } }
    }

    @ViewBuilder private var icon: some View {
        if running {
            ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 18, height: 18)
        } else {
            // 工具失败多是命令非零退出等常态（agent 会自己处理），不算会话出错：全灰，只靠图标形状区分。
            Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 17, weight: .light)).frame(width: 18)
                .foregroundStyle(Theme.muted)
        }
    }

    /// 标题这一步（正在跑的那步，或唯一一步）是针对某个会话的 Paseo 调用时，用可点的一句话。
    private var headerAction: PaseoAgentAction? {
        if running { return rows.last(where: { if case .toolCall(_, _, let s, _, _, _) = $0.item { s == "running" } else { $0.isStreaming } })?.item.paseoAgentAction }
        return rows.count == 1 ? rows[0].item.paseoAgentAction : nil
    }

    /// The shell command the header names (the running one, or the only step), first line only.
    private var command: String? {
        let r: TimelineRow?
        if running { r = rows.last(where: { if case .toolCall(_, _, let s, _, _, _) = $0.item { s == "running" } else { $0.isStreaming } }) }
        else { r = rows.count == 1 ? rows[0] : nil }
        guard let r, case .toolCall(_, _, _, .shell(let c, _, _, _), _, _) = r.item, PeerCommand(c) == nil else { return nil }
        let line = c.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? c
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// 单条后台命令（Bash 的 run_in_background）：标成「后台运行」，它在这里立刻完成，真正的进度看输入框上方的后台任务。
    private var isBackground: Bool {
        guard rows.count == 1, case .toolCall(_, let name, _, .shell(_, _, let output?, _), _, _) = rows[0].item else { return false }
        return AgentBackgroundTask.taskId(fromOutput: output, toolName: name) != nil
    }

    /// "N 项操作" like the reference design; the running one names what it is doing.
    private var summary: String {
        if running, let r = rows.last(where: { if case .toolCall(_, _, let s, _, _, _) = $0.item { s == "running" } else { $0.isStreaming } }) {
            return r.item.toolSummary
        }
        if rows.count == 1 { return rows[0].item.toolSummary }
        let detail = detailedSummary
        return String(localized: "\(rows.count) 项操作") + (detail.isEmpty ? "" : " · " + detail)
    }

    private var detailedSummary: String {
        rows.count == 1 ? rows[0].item.toolSummary : workSummary(rows)
    }
}

/// What a stretch of agent work did, such as "改了 2 个文件，运行 3 个命令" (official summarizeToolCalls +
/// useOverviewSummaryLabel): files count once however often they were touched; thinking is named only when
/// it is all there is. Empty when nothing is countable (only messages).
func workSummary<S: Sequence>(_ rows: S) -> String where S.Element == TimelineRow {
    var edited = Set<String>(), read = Set<String>()
    var commands = 0, searches = 0, thoughts = 0, other = 0
    for r in rows {
        switch r.item {
        case .reasoning: thoughts += 1
        case .toolCall(_, _, _, let d, _, let m):
            if m != nil || r.item.outgoingMessage != nil { continue }
            switch d {
            case .shell(let c, _, _, _): if PeerCommand(c) == nil { commands += 1 } else { other += 1 }
            case .read(let p, _): read.insert(p)
            case .edit(let p, _, _, _), .write(let p, _): edited.insert(p)
            case .search, .fetch: searches += 1
            default: other += 1
            }
        default: break
        }
    }
    var parts: [String] = []
    if !edited.isEmpty { parts.append(String(localized: "改了 \(edited.count) 个文件")) }
    if commands > 0 { parts.append(String(localized: "运行 \(commands) 个命令")) }
    if !read.isEmpty { parts.append(String(localized: "读了 \(read.count) 个文件")) }
    if searches > 0 { parts.append(String(localized: "搜索 \(searches) 次")) }
    if other > 0 { parts.append(String(localized: "\(other) 个其他操作")) }
    if thoughts > 0 && parts.isEmpty { parts.append(String(localized: "思考")) }
    return parts.joined(separator: String(localized: "，", comment: "列举时的分隔符（逗号）"))
}

struct ToolDetailView: View {
    let row: TimelineRow
    let showHeader: Bool
    var fullContent = false
    @State private var previewHeight: CGFloat = 0

    @ViewBuilder var body: some View {
        if fullContent {
            if let path = row.readImagePath {
                MarkdownImage(alt: path, url: path, cacheKey: row.id)
            } else if case .toolCall(_, _, _, .edit(_, let old, let new, let unified), _, _) = row.item {
                DiffView(diff: unified ?? DiffView.fallback(old: old ?? "", new: new ?? ""), lineLimit: nil)
            } else {
                CodeBlock(code: ToolDetailsSelection.text(row))
            }
        } else { preview }
    }

    private var preview: some View {
        ScrollView(.vertical) {
            previewContent
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { previewHeight = $0 }
        }
        // Measure without a height proposal: short blocks stay compact and long diffs cannot
        // draw over later messages. The same viewport is used on iOS and macOS.
        .frame(height: min(previewHeight, 400), alignment: .top)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .clipped()
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showHeader {
                if let action = row.item.paseoAgentAction {
                    PaseoAgentActionLabel(action: action, font: .system(size: Theme.code), color: Theme.muted)
                } else {
                    Text(row.item.toolSummary).font(.system(size: Theme.code)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            switch row.item {
            case .reasoning(let text):
                Text(text).font(.system(size: Theme.base)).foregroundStyle(Theme.muted).textSelection(.enabled)
            case .toolCall(_, _, _, let detail, let error, _):
                detailView(detail)
                // daemon 有时把 error 发成 JSON null，别显示成字面量「null」。
                if let error, error != .null {
                    Text(error["message"]?.stringValue ?? error.description)
                        .font(.system(size: Theme.code, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func detailView(_ d: ToolCallDetail) -> some View {
        switch d {
        case .shell(let command, _, let output, let exitCode):
            CodeBlock(code: "$ \(command)" + (output.map { "\n" + $0.suffix(6000) } ?? "") + (exitCode.map { $0 == 0 ? "" : "\n[exit \($0)]" } ?? ""))
        case .edit(_, let old, let new, let unified):
            DiffView(diff: unified ?? DiffView.fallback(old: old ?? "", new: new ?? ""))
        case .read(let path, _) where TimelineRow.isImagePath(path):
            // Fixed height, so the list doesn't jump when the image arrives.
            MarkdownImage(alt: (path as NSString).lastPathComponent, url: path, maxSize: CGSize(width: 520, height: 300), cacheKey: row.id)
                .frame(height: 300, alignment: .leading)
        case .write(_, let content), .read(_, let content):
            if let content { CodeBlock(code: String(content.prefix(6000))) }
        case .search(_, let content, let files):
            CodeBlock(code: content ?? files.joined(separator: "\n"))
        case .fetch(_, let result):
            if let result { MarkdownView(text: String(result.prefix(4000))) }
        case .subAgent(let description, let log):
            VStack(alignment: .leading, spacing: 4) {
                if let description { Text(description).font(.system(size: Theme.base)) }
                if let log, !log.isEmpty {
                    // The log is one action per line; show the latest ones.
                    let lines = log.split(separator: "\n").suffix(40)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: Theme.code, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
            }
        case .plainText(_, let text, _):
            if let text { MarkdownView(text: text) }
        case .plan(let text):
            MarkdownView(text: text)
        case .unknown(let json):
            // 标题已是「查看「…」的状态」这样的一句话时，不再重复「目标会话」。
            UnknownToolDetail(input: json["input"], output: json["output"], raw: json,
                              showsTarget: !(showHeader && row.item.paseoAgentAction != nil))
        }
    }
}

/// Tools without a typed detail (MCP, Paseo tools…): input fields as key/value rows, output as text or JSON.
private struct UnknownToolDetail: View {
    let input: JSONValue?
    let output: JSONValue?
    let raw: JSONValue
    var showsTarget = true
    @Environment(\.agentTitle) private var agentTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTarget, let id = input?["agentId"]?.stringValue ?? input?["agent_id"]?.stringValue, let title = agentTitle?.lookup(id) {
                Label("目标会话「\(title)」", systemImage: "bubble.left").font(.system(size: Theme.base)).foregroundStyle(Theme.muted)
            }
            if let input, input != .null {
                section("输入") {
                    if let obj = input.objectValue {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                            ForEach(obj.keys.sorted(), id: \.self) { k in
                                GridRow {
                                    Text(k).foregroundStyle(Theme.muted)
                                    Text(short(obj[k]!)).textSelection(.enabled).lineLimit(6)
                                }
                            }
                        }
                        .font(.system(size: Theme.code, design: .monospaced))
                    } else {
                        CodeBlock(code: pretty(input))
                    }
                }
            }
            if let output, output != .null {
                section("输出") {
                    if let s = output.stringValue { MarkdownView(text: String(s.prefix(6000))) }
                    else if let text = output["content"]?.arrayValue?.compactMap({ $0["text"]?.stringValue }), !text.isEmpty {
                        MarkdownView(text: String(text.joined(separator: "\n").prefix(6000)))
                    } else { CodeBlock(code: String(pretty(output).prefix(6000))) }
                }
            }
            if (input == nil || input == .null) && (output == nil || output == .null) {
                CodeBlock(code: String(pretty(raw).prefix(4000)))
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.extraMuted)
            content()
        }
    }

    private func short(_ v: JSONValue) -> String {
        if let s = v.stringValue { return s }
        return pretty(v)
    }

    private func pretty(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? v.description
    }
}

struct DiffView: View {
    let diff: String
    var lineLimit: Int? = 400
    /// Cap the height (permission card): short diffs keep their size, long ones scroll inside instead of
    /// spilling over the card and its buttons.
    var maxHeight: CGFloat? = nil

    var body: some View {
        if let maxHeight {
            ViewThatFits(in: .vertical) {
                lines
                ScrollView(.vertical) { lines }
            }
            .frame(maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            lines
        }
    }

    private var lines: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit ?? Int.max).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .font(.system(size: Theme.code, design: .monospaced))
            .padding(.vertical, 6)
        }
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }

    private func color(_ l: Substring) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return Theme.diffAdd }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return Theme.diffRemove }
        if l.hasPrefix("@@") { return Theme.muted }
        return Theme.foreground
    }

    private func background(_ l: Substring) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return Theme.diffAdd.opacity(0.08) }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return Theme.diffRemove.opacity(0.08) }
        return .clear
    }

    static func fallback(old: String, new: String) -> String {
        old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }.joined(separator: "\n") + "\n"
            + new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
    }
}

// MARK: Cards

struct PlanCard: View {
    let text: String
    var status: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("计划", systemImage: "list.bullet.clipboard").font(.system(size: Theme.base, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                if let (label, color) = statusLabel {
                    Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
                }
            }
            MarkdownView(text: text)
        }
        .padding(14)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderAccent))
    }
}

extension PlanCard {
    /// Plan tool call outcome: completed = approved, failed = rejected, canceled.
    fileprivate var statusLabel: (String, SwiftUI.Color)? {
        switch status {
        case "completed": (String(localized: "已批准"), Theme.dotSuccess)
        case "failed": (String(localized: "已拒绝"), Theme.destructive)
        case "canceled", "cancelled": (String(localized: "已取消"), Theme.muted)
        case "running": (String(localized: "等待确认"), Theme.dotWarning)
        default: nil
        }
    }
}

func formatTokens(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk tokens", Double(n) / 1000) : "\(n) tokens"
}

struct TodoCard: View {
    let items: [TodoItem]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                    Text("任务 \(items.filter(\.completed).count)/\(items.count)")
                    if let current = items.first(where: { $0.status == "in_progress" }) {
                        Text("· " + current.text).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: Theme.base)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item.text).strikethrough(item.completed).foregroundStyle(item.completed ? Theme.muted : Theme.foreground)
                    } icon: {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.dotted" : "circle")
                            .foregroundStyle(item.completed ? Theme.dotSuccess : Theme.muted)
                    }
                    .font(.system(size: Theme.base))
                }
                .padding(.leading, 20)
            }
        }
    }
}

struct Banner: View {
    let level: String
    let message: String

    var body: some View {
        Label(message, systemImage: level == "error" ? "xmark.octagon" : level == "warning" ? "exclamationmark.triangle" : "info.circle")
            .font(.system(size: Theme.base))
            .foregroundStyle(level == "error" ? Theme.destructive : level == "warning" ? Theme.dotWarning : Theme.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((level == "error" ? Theme.destructive : level == "warning" ? Theme.dotWarning : Theme.muted).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

/// 只解析结构化会话通知中已知的官方包装；普通消息和不完整包装保持原文。
struct AgentMessageContent {
    let introduction: String
    let response: String?
    let trailing: String

    init(text: String, sender: JSONValue?, event: String) {
        let cleaned = Self.introduction(text: text, sender: sender, event: event)
        guard event != "message", cleaned != text,
              let open = cleaned.range(of: "<agent-response>\n"),
              let close = cleaned.range(of: "\n</agent-response>", options: .backwards),
              open.upperBound <= close.lowerBound else {
            introduction = cleaned.contains("<agent-response>") || cleaned.contains("</agent-response>") ? text : cleaned
            response = nil
            trailing = ""
            return
        }
        introduction = cleaned
        response = String(cleaned[open.upperBound..<close.lowerBound])
        trailing = String(cleaned[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var note: String {
        guard response != nil, let open = introduction.range(of: "<agent-response>\n") else { return introduction }
        return String(introduction[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func introduction(text: String, sender: JSONValue?, event: String) -> String {
        let reasons: [String: [String]] = ["finished": ["finished"], "errored": ["errored", "was canceled"],
            "permission-required": ["needs permission"], "closed": ["was closed", "is unavailable"]]
        guard let id = sender?["id"]?.stringValue, !id.isEmpty,
              let first = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              first.hasPrefix("Agent \(id) ("),
              reasons[event]?.contains(where: { first.hasSuffix(") \($0).") }) == true else { return text }
        var body = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let server = sender?["serverId"]?.stringValue,
           body == "Server: \(server)" || body.hasPrefix("Server: \(server)\n") {
            body = String(body.dropFirst("Server: \(server)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }
}

/// 引用正文与当前会话区分；历史快照不会因来源会话继续运行而更新。
/// 标题一句话说清「谁 · 做了什么 · 几点」。主动消息和不折叠的完成通知是卡片；折叠的完成通知只是一行状态，
/// 下面带最后回复第一行的预览，点开才变成卡片。原始消息、复制在右上角「⋯」里。
struct CrossSessionMessageCard: View {
    let message: JSONValue
    let text: String
    /// 完成通知是否默认折叠（来源这一轮已主动发过消息时）；否则和主动消息一样直接显示。
    var foldable = true
    var timestamp: Date? = nil
    @State private var expanded = false
    @State private var showingAll = false
    @State private var showingOriginal = false
    @Environment(\.findQuery) private var findQuery

    private var event: String { message["event"]?.stringValue ?? "message" }
    private var canFold: Bool { event == "finished" && foldable }
    /// 直接展开的完成 / 状态通知很长时先限高，免得一条通知占满屏；主动消息和用户点开的折叠通知显示全文。
    private static let clippedHeight: CGFloat = 280
    private func clips(_ content: AgentMessageContent) -> Bool {
        guard event != "message", !(canFold && expanded), !showingAll, findQuery.isEmpty else { return false }
        let body = [content.note, content.response ?? "", content.trailing].joined(separator: "\n")
        return body.count > 600 || body.split(whereSeparator: \.isNewline).count > 12
    }

    /// 需要你处理的（需要权限、出错）用醒目的颜色。
    private var icon: (name: String, color: Color) {
        switch event {
        case "finished": ("checkmark.circle.fill", Theme.dotSuccess)
        case "errored": ("xmark.circle.fill", Theme.dotDanger)
        case "permission-required": ("exclamationmark.triangle.fill", Theme.dotWarning)
        case "closed": ("minus.circle.fill", Theme.extraMuted)
        default: ("quote.bubble.fill", Theme.accentBright)
        }
    }

    private func phrase(_ name: String) -> String {
        switch event {
        case "finished": String(localized: "「\(name)」已完成")
        case "errored": String(localized: "「\(name)」出错或已取消")
        case "permission-required": String(localized: "「\(name)」需要权限")
        case "closed": String(localized: "「\(name)」已关闭")
        default: String(localized: "「\(name)」发来消息")
        }
    }

    var body: some View {
        let content = AgentMessageContent(text: text, sender: message["sender"], event: event)
        Group {
            if canFold && !expanded && findQuery.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    header
                    Button { withAnimation(.snappy(duration: 0.2)) { expanded = true } } label: {
                        HStack(spacing: 4) {
                            Text(Self.preview(content)).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 21)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 4)
            } else {
                let clipped = clips(content)
                VStack(alignment: .leading, spacing: 12) {
                    header
                    VStack(alignment: .leading, spacing: 12) {
                        if !content.note.isEmpty { MarkdownView(text: content.note, renderMedia: false, continuousSelection: true) }
                        if let response = content.response {
                            Text("最后回复").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            MarkdownView(text: response, renderMedia: false, continuousSelection: true)
                        }
                        if !content.trailing.isEmpty { MarkdownView(text: content.trailing, renderMedia: false, continuousSelection: true) }
                    }
                    .frame(maxHeight: clipped ? Self.clippedHeight : nil, alignment: .top)
                    .clipped()
                    .mask {
                        if clipped {
                            LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        } else { Rectangle() }
                    }
                    if clipped || showingAll {
                        Button(showingAll ? "收起" : "显示全部") { withAnimation(.snappy(duration: 0.2)) { showingAll.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accentBright)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.accentBright.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accentBright.opacity(0.22), lineWidth: 1))
            }
        }
        .sheet(isPresented: $showingOriginal) { SelectTextSheet(text: text) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon.name).font(.system(size: 13)).foregroundStyle(icon.color)
            if let sender = message["sender"] {
                MessageSenderButton(sender: sender, textAlignment: .leading, phrase: phrase)
            } else {
                Text(phrase(String(localized: "其他会话"))).font(.system(size: 13, weight: .medium))
            }
            if let timestamp {
                Text(formatTimestamp(timestamp)).font(.system(size: 12)).foregroundStyle(Theme.extraMuted)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            if canFold && expanded && findQuery.isEmpty {
                Button("收起") { withAnimation(.snappy(duration: 0.2)) { expanded = false } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Menu {
                Button("复制内容", systemImage: "doc.on.doc") {
                    let content = AgentMessageContent(text: text, sender: message["sender"], event: event)
                    Pasteboard.copy(content.response ?? content.note)
                }
                Button("查看原始消息", systemImage: "doc.plaintext") { showingOriginal = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Theme.muted)
            .accessibilityLabel("消息操作")
        }
    }

    /// 折叠时的预览：最后回复（没有就是说明）的第一行纯文本。
    static func preview(_ content: AgentMessageContent) -> String {
        let plain = MarkdownBlock.plainText(content.response ?? content.note)
        let line = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String(localized: "最后回复：\($0)") } ?? String(localized: "查看最后回复")
    }
}

/// 一个目标会话：和收到的消息的 sender 同形（id + serverId + title），复用 MessageSenderButton 的名字解析和跳转。
/// serverId 依次取：调用里写明的 → 同一会话里 paseo-peer tell 打出来的（machine → serverId）→ 按主机名找。
/// paseo-peer 的机器名对不上 App 里的主机时用一个不存在的 serverId，免得短 id 碰巧匹配到本机的会话而跳错。
@MainActor func sessionTarget(agentId: String, serverId: String?, machine: String?, title: String?,
                              lookup: MessageSenderLookup?, peerServers: [String: String]) -> JSONValue {
    var t: [String: JSONValue] = ["id": .string(agentId)]
    if let title { t["title"] = .string(title) }
    if let serverId { t["serverId"] = .string(serverId) }
    else if let machine {
        if let server = peerServers[machine] ?? lookup?.hostNamed(machine)?.id { t["serverId"] = .string(server) }
        else {
            t["serverId"] = .string("peer:" + machine)
            if title == nil { t["title"] = .string("\(machine) · \(agentId.prefix(7))") }
        }
    }
    return .object(t)
}

/// 针对某个会话的 Paseo 调用（查看状态、读活动、取消、归档…），以及 paseo-peer 的同类子命令（logs、wait、permit…）：
/// 显示成一句话，会话名可点。
struct PaseoAgentAction: Equatable {
    let leaf: String
    let agentId: String
    var serverId: String? = nil
    /// paseo-peer 的机器短名。
    var machine: String? = nil

    init(leaf: String, agentId: String, serverId: String? = nil, machine: String? = nil) {
        self.leaf = leaf; self.agentId = agentId; self.serverId = serverId; self.machine = machine
    }

    init?(name: String, detail: ToolCallDetail) {
        if case .shell(let command, _, _, _) = detail {
            guard case .agent(let action)? = PeerCommand(command) else { return nil }
            self = action
            return
        }
        guard case .unknown(let json) = detail, let leaf = OutgoingAgentMessage.paseoLeafName(name),
              Self.agentTools.contains(leaf), let input = json["input"],
              let id = (input["agentId"] ?? input["agent_id"])?.stringValue, !id.isEmpty else { return nil }
        self.leaf = leaf
        agentId = id
        serverId = input["serverId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    static let agentTools: Set<String> = ["get_agent_status", "get_agent_activity", "update_agent", "set_agent_mode",
                                          "cancel_agent", "archive_agent", "kill_agent", "respond_to_permission"]

    func phrase(_ name: String) -> String {
        switch leaf {
        case "get_agent_status": String(localized: "查看「\(name)」的状态")
        case "get_agent_activity": String(localized: "查看「\(name)」的最近活动")
        case "update_agent": String(localized: "修改「\(name)」的设置")
        case "set_agent_mode": String(localized: "切换「\(name)」的模式")
        case "cancel_agent": String(localized: "取消「\(name)」当前这一轮")
        case "archive_agent": String(localized: "归档「\(name)」")
        case "kill_agent": String(localized: "关闭「\(name)」")
        case "peer_logs": String(localized: "查看「\(name)」的记录")
        case "peer_wait": String(localized: "等「\(name)」跑完这一轮")
        case "permit_allow": String(localized: "批准「\(name)」的权限请求")
        case "permit_deny": String(localized: "拒绝「\(name)」的权限请求")
        case "permit_list": String(localized: "查看「\(name)」待批准的权限")
        default: String(localized: "回复「\(name)」的权限请求")
        }
    }

    /// 不针对某个会话的 Paseo 调用：一句话，带上关键参数（名字、脚本名…）。
    static func label(_ leaf: String, input: JSONValue?) -> String? {
        func field(_ keys: String...) -> String? {
            for k in keys { if let v = input?[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v } }
            return nil
        }
        func named(_ base: String, _ value: String?) -> String { value.map { "\(base)「\(String($0.prefix(60)))」" } ?? base }
        switch leaf {
        case "list_agents": return String(localized: "列出会话")
        case "list_hosts": return String(localized: "列出机器")
        case "list_workspaces": return String(localized: "列出工作区")
        case "list_pending_permissions": return String(localized: "列出待批准的权限")
        case "list_providers": return String(localized: "列出模型服务")
        case "list_models": return named(String(localized: "列出模型"), field("provider"))
        case "list_profiles": return String(localized: "列出配置")
        case "inspect_provider": return named(String(localized: "查看模型服务"), field("provider"))
        case "create_agent": return named(String(localized: "新开会话"), field("title"))
        case "create_workspace":
            return named(String(localized: "新建工作区"), field("title", "name") ?? field("path", "cwd").map { ($0 as NSString).lastPathComponent })
        case "rename_workspace": return named(String(localized: "工作区改名为"), field("title", "name"))
        case "archive_workspace": return String(localized: "归档工作区")
        case "list_workspace_scripts": return String(localized: "列出工作区脚本")
        case "start_workspace_script": return named(String(localized: "启动脚本"), field("scriptName"))
        case "stop_workspace_script": return named(String(localized: "停止脚本"), field("scriptName"))
        case "create_terminal": return named(String(localized: "新建终端"), field("name", "command"))
        case "list_terminals": return String(localized: "列出终端")
        case "capture_terminal": return String(localized: "读取终端输出")
        case "send_terminal_keys": return named(String(localized: "向终端发送按键"), field("keys"))
        case "kill_terminal": return String(localized: "关闭终端")
        case "create_schedule": return named(String(localized: "新建定时任务"), field("name", "cron"))
        case "create_heartbeat": return named(String(localized: "新建心跳"), field("name", "cron"))
        case "update_schedule": return named(String(localized: "修改定时任务"), field("name"))
        case "list_schedules": return String(localized: "列出定时任务")
        case "inspect_schedule": return String(localized: "查看定时任务")
        case "schedule_logs": return String(localized: "查看定时任务日志")
        case "run_schedule_once": return String(localized: "立即运行定时任务")
        case "pause_schedule": return String(localized: "暂停定时任务")
        case "resume_schedule": return String(localized: "恢复定时任务")
        case "delete_schedule": return String(localized: "删除定时任务")
        case "delete_heartbeat": return String(localized: "删除心跳")
        default: return nil
        }
    }
}

/// `paseo-peer <机器> <子命令> …`（tell 和 run 见 OutgoingAgentMessage）：针对某个会话的给出 PaseoAgentAction，其余给一句话。
enum PeerCommand: Equatable {
    case agent(PaseoAgentAction)
    case plain(String)

    init?(_ command: String) {
        guard let args = PeerCommand.args(command), let first = args.first else { return nil }
        if args.count == 1 {
            switch first {
            case "ls": self = .plain(String(localized: "列出所有机器")); return
            case "doctor": self = .plain(String(localized: "检查跨机器连接")); return
            case "whoami": self = .plain(String(localized: "查看本会话的来源说明")); return
            default: return nil
            }
        }
        if ["init", "invite", "join", "password", "link", "whoami"].contains(first) {
            switch first {
            case "whoami": self = .plain(String(localized: "查看本会话的来源说明"))
            case "link": self = .plain(String(localized: "登记连接主机"))
            default: return nil
            }
            return
        }
        let machine = first, sub = args[1], rest = Array(args.dropFirst(2))
        // 跳过带值的选项（--days 7、--tail 40…），剩下的是位置参数。
        let valueFlags: Set<String> = ["--days", "--tail", "--timeout", "--interval", "--start-grace", "--label", "--name", "--file"]
        var positional: [String] = []
        var skip = false
        for a in rest {
            if skip { skip = false; continue }
            if valueFlags.contains(a) { skip = true; continue }
            if !a.hasPrefix("-") { positional.append(a) }
        }
        let agent = { (leaf: String, id: String?) -> PeerCommand? in
            guard let id, !id.isEmpty else { return nil }
            return .agent(PaseoAgentAction(leaf: leaf, agentId: id, machine: machine))
        }
        // 「在本机上」/「在 studio 上」：中文和机器名之间留空格。
        let on = machine == "local" ? String(localized: "本机") : " \(machine) "
        let result: PeerCommand?
        switch sub {
        case "who": result = .plain(positional.first.map { String(localized: "在\(on)上查看做「\($0)」的会话") }
                                    ?? String(localized: "在\(on)上查看做本项目的会话"))
        case "find": result = .plain(String(localized: "在\(on)上找做「\(positional.joined(separator: " / "))」的会话"))
        case "mine": result = .plain(String(localized: "列出本会话在\(on)上开的配合会话"))
        case "ls": result = .plain(String(localized: "列出\(on)上的会话"))
        case "logs": result = agent("peer_logs", positional.first)
        case "wait": result = agent("peer_wait", positional.first)
        case "workspace":
            result = rest.first == "ls" ? .plain(String(localized: "列出\(on)上的工作区"))
                : rest.first == "rename" ? .plain(String(localized: "改\(on)上的工作区名")) : nil
        case "agent":
            let id = rest.count > 1 ? rest[1] : nil
            switch rest.first {
            case "update": result = agent("update_agent", id)
            case "archive": result = agent("archive_agent", id)
            case "mode": result = agent("set_agent_mode", id)
            default: result = nil
            }
        case "permit":
            let id = rest.count > 1 ? rest[1] : nil
            switch rest.first {
            case "allow": result = agent("permit_allow", id)
            case "deny": result = agent("permit_deny", id)
            case "ls": result = id.flatMap { agent("permit_list", $0) } ?? .plain(String(localized: "查看\(on)上待批准的权限"))
            default: result = nil
            }
        case "provider": result = .plain(String(localized: "查看\(on)上的模型服务"))
        default: result = nil
        }
        guard let result else { return nil }
        self = result
    }

    /// 命令里第一处 paseo-peer 调用的参数（到 ; && | 等为止）。
    static func args(_ command: String) -> [String]? {
        guard command.contains("paseo-peer") else { return nil }
        let words = OutgoingAgentMessage.shellWords(command)
        guard let i = words.firstIndex(where: { $0.map { ($0 as NSString).lastPathComponent == "paseo-peer" } ?? false }) else { return nil }
        var args: [String] = []
        for w in words[(i + 1)...] {
            guard let w else { break }
            args.append(w)
        }
        return args.isEmpty ? nil : args
    }

    /// 时间线里一行的文字版（工具详情面板、进度提示用）：会话名用短 id。
    var summary: String {
        switch self {
        case .agent(let a): a.phrase(a.machine.map { "\($0) · \(a.agentId.prefix(7))" } ?? String(a.agentId.prefix(7)))
        case .plain(let s): s
        }
    }
}

extension TimelineItem {
    var paseoAgentAction: PaseoAgentAction? {
        guard case .toolCall(_, let name, _, let detail, _, nil) = self else { return nil }
        return PaseoAgentAction(name: name, detail: detail)
    }
}

extension EnvironmentValues {
    /// 这个会话里 paseo-peer tell 打出来的「机器名 → serverId」（DisplayItemCache.peerServers）。
    @Entry var peerServers: [String: String] = [:]
}

/// 工具步骤里的「查看「…」的状态」：会话名可点；名字没解析到时退回短 id。
struct PaseoAgentActionLabel: View {
    let action: PaseoAgentAction
    var font: Font = .system(size: Theme.base, weight: .semibold)
    var color: Color = Theme.foreground.opacity(0.75)
    @Environment(\.messageSender) private var lookup
    @Environment(\.peerServers) private var peerServers

    var body: some View {
        MessageSenderButton(sender: sessionTarget(agentId: action.agentId, serverId: action.serverId, machine: action.machine,
                                                  title: nil, lookup: lookup, peerServers: peerServers),
                            textAlignment: .leading, phrase: action.phrase,
                            phraseFont: font, phraseColor: color, phraseLineLimit: 1)
    }
}

/// 本会话发给别的会话的消息：Paseo 工具 send_agent_prompt，或 shell 里的 `paseo-peer <机器> tell <id> …`。
struct OutgoingAgentMessage: Equatable {
    /// 新开会话（create_agent 带 initialPrompt）时为 true；会话 id 在输出里，还没返回时为空。
    var creates = false
    /// create_agent 的 title：会话还查不到时显示它。
    var title: String? = nil
    var agentId: String
    /// send_agent_prompt 的 serverId（同机时没有）。
    var serverId: String? = nil
    /// paseo-peer 的机器短名（studio、mini、local），显示时按主机名找对应的主机。
    var machine: String? = nil
    /// 发出的内容；`tell --file` 时为 nil，内容在 file 里。
    var prompt: String? = nil
    var file: String? = nil

    init(agentId: String, serverId: String? = nil, machine: String? = nil, prompt: String? = nil, file: String? = nil) {
        self.agentId = agentId; self.serverId = serverId; self.machine = machine; self.prompt = prompt; self.file = file
    }

    init?(name: String, detail: ToolCallDetail) {
        if case .shell(let command, _, let output, _) = detail {
            guard var message = Self.peerTell(command) ?? Self.peerRun(command, output: output) else { return nil }
            // paseo-peer tell 发送成功后打一行「已发送：studio（serverId srv_…）」，有它就不用按机器名猜主机。
            if let output, let m = Self.sentMarker.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let r = Range(m.range(at: 1), in: output) { message.serverId = String(output[r]) }
            self = message
            return
        }
        guard case .unknown(let json) = detail, let leaf = Self.paseoLeafName(name), let input = json["input"] else { return nil }
        switch leaf {
        case "send_agent_prompt":
            guard let id = input["agentId"]?.stringValue, !id.isEmpty, let prompt = input["prompt"]?.stringValue else { return nil }
            agentId = id
            self.prompt = Self.droppingSourceLine(prompt)
        case "create_agent":
            guard let prompt = input["initialPrompt"]?.stringValue,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            creates = true
            agentId = json["output"].flatMap(Self.createdAgentId) ?? ""
            title = input["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            self.prompt = Self.droppingSourceLine(prompt)
        default:
            return nil
        }
        serverId = input["serverId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// create_agent 输出里的会话 id：可能直接在 output 里，也可能套在 structuredContent / output 里，或是文本里的 JSON。
    static func createdAgentId(_ output: JSONValue) -> String? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? e.encode(output), let text = String(data: data, encoding: .utf8),
              let m = agentIdPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    private static let agentIdPattern = try! NSRegularExpression(pattern: #"agentId\\*"\s*:\s*\\*"([A-Za-z0-9_-]+)"#)

    /// mcp__paseo__send_agent_prompt（Claude）或 paseo.send_agent_prompt（其他 provider）；official tool-name-normalization.ts。
    static func paseoLeafName(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.contains("__") {
            let parts = n.components(separatedBy: "__").filter { !$0.isEmpty }
            guard parts.count >= 3, parts[0] == "mcp", parts[1] == "paseo" || parts[1].hasPrefix("paseo_") else { return nil }
            return parts.dropFirst(2).joined(separator: "__")
        }
        if let dot = n.firstIndex(of: ".") {
            let ns = n[..<dot]
            guard ns == "paseo" || ns.hasPrefix("paseo_") else { return nil }
            return String(n[n.index(after: dot)...])
        }
        return nil
    }

    /// 跨机器 / 跨项目消息第一行是「来自本会话」的来源说明，在自己的时间线里是废话，去掉。
    static func droppingSourceLine(_ prompt: String) -> String {
        let prefixes = ["【跨机器消息】", "【跨项目消息】", "[Cross-machine message]", "[Cross-project message]"]
        let trimmed = prompt.drop { $0.isWhitespace }
        guard prefixes.contains(where: { trimmed.hasPrefix($0) }) else { return prompt }
        let firstLine = trimmed.prefix { !$0.isNewline }
        let after = trimmed.dropFirst(firstLine.count)
        // 来源说明以「（id 短id）」结尾，同一行后面可能还接着正文（「…（id f6ae738），Gavin 让我把这件事派给你。」），只去掉说明。
        var lineRest = ""
        if let id = firstLine.range(of: #"[（(]id [0-9A-Za-z_-]+[）)]"#, options: .regularExpression) {
            lineRest = String(firstLine[id.upperBound...]).trimmingCharacters(in: .whitespaces)
            while let c = lineRest.first, "，,。.：:".contains(c) { lineRest.removeFirst() }
        }
        let rest = (lineRest.trimmingCharacters(in: .whitespaces) + after).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? prompt : rest
    }

    static let sentMarker = try! NSRegularExpression(pattern: #"serverId ([A-Za-z0-9_-]+)[）)]"#)

    /// `…/paseo-peer <机器> tell <id> "消息"` 或 `… tell <id> --file <路径>`（前后可以接 ; && | 等）。
    static func peerTell(_ command: String) -> OutgoingAgentMessage? {
        guard command.contains("tell"), let args = PeerCommand.args(command), args.count >= 4, args[1] == "tell",
              !args[2].hasPrefix("-") else { return nil }
        let machine = args[0], id = args[2]
        if args[3] == "--file" {
            guard args.count >= 5 else { return nil }
            return OutgoingAgentMessage(agentId: id, machine: machine, file: args[4])
        }
        return OutgoingAgentMessage(agentId: id, machine: machine, prompt: heredocBody(args[3]) ?? args[3])
    }

    /// `paseo-peer <机器> run [--no-wait] [--title 名] [--workspace id] … "要做的事"`：在那台机器上新开会话并发送。
    static func peerRun(_ command: String, output: String?) -> OutgoingAgentMessage? {
        guard command.contains("run"), let args = PeerCommand.args(command), args.count >= 3, args[1] == "run" else { return nil }
        let valueFlags: Set<String> = ["--workspace", "--title", "--name", "--mode", "--label", "--cwd", "--provider",
                                       "--model", "--thinking", "--prompt-file", "--host"]
        var title: String?, prompt: String?, i = 2
        while i < args.count {
            let a = args[i]
            if valueFlags.contains(a) {
                if a == "--title" || a == "--name", i + 1 < args.count { title = args[i + 1] }
                i += 2; continue
            }
            if !a.hasPrefix("-") && !a.hasPrefix("$(") { prompt = a }
            i += 1
        }
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var message = OutgoingAgentMessage(agentId: output.flatMap(firstUUID) ?? "", machine: args[0],
                                           prompt: droppingSourceLine(heredocBody(prompt) ?? prompt))
        message.creates = true
        message.title = title
        return message
    }

    static func firstUUID(_ text: String) -> String? {
        text.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// `"$(cat <<'EOF' … EOF)"` 写法的消息取出正文。
    static func heredocBody(_ word: String) -> String? {
        guard word.hasPrefix("$(cat <<"),
              let m = heredoc.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)),
              let body = Range(m.range(at: 2), in: word) else { return nil }
        return String(word[body])
    }
    private static let heredoc = try! NSRegularExpression(
        pattern: #"^\$\(cat <<-?\s*['"]?(\w+)['"]?\n(.*?)\n\s*\1\s*\)$"#, options: [.dotMatchesLineSeparators])

    /// 简单的 shell 分词：单双引号、反斜杠转义；; & | 换行 和重定向是分隔（nil）。不展开变量和 $(…)（整段保留成一个词）。
    static func shellWords(_ s: String) -> [String?] {
        var out: [String?] = []
        var word = "", inWord = false
        var quote: Character? = nil
        var escaped = false
        func flush() { if inWord { out.append(word) }; word = ""; inWord = false }
        var depth = 0  // 没加引号的 $( … ) 整段算一个词（如 $(paseo-peer whoami --labels)）
        var previous: Character? = nil
        for c in s {
            defer { previous = c }
            if depth > 0 {
                word.append(c)
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                continue
            }
            if escaped {
                if quote == "\"" && !"\"\\$`\n".contains(c) { word.append("\\") }
                if c != "\n" { word.append(c) }  // 反斜杠加换行是续行
                escaped = false; inWord = true; continue
            }
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\" && q == "\"" { escaped = true }
                else { word.append(c) }
                continue
            }
            if c == "(" && previous == "$" && quote == nil && !escaped {
                word.append(c); depth = 1; continue
            }
            switch c {
            case "'", "\"": quote = c; inWord = true
            case "\\": escaped = true
            case " ", "\t": flush()
            case ";", "&", "|", "\n", "<", ">", "(", ")": flush(); out.append(nil)
            default: word.append(c); inWord = true
            }
        }
        flush()
        return out
    }
}

extension TimelineItem {
    var outgoingMessage: OutgoingAgentMessage? {
        guard case .toolCall(_, let name, _, let detail, _, nil) = self else { return nil }
        return OutgoingAgentMessage(name: name, detail: detail)
    }
}

/// 「已发给「…」」卡片：目标名可点，直接跳到那个会话（带返回）；正文是发过去的内容。
struct OutgoingMessageCard: View {
    let message: OutgoingAgentMessage
    let status: String
    let error: JSONValue?
    /// paseo-peer 命令退出码非 0 时的输出末尾。
    var shellFailure: String? = nil
    var timestamp: Date? = nil
    @State private var showingAll = false
    @State private var fileText: String?
    @State private var fileMissing = false
    @Environment(\.findQuery) private var findQuery
    @Environment(\.messageSender) private var lookup
    @Environment(\.hostFileReader) private var fileReader

    private var failed: Bool { status == "failed" || (error != nil && error != .null) || shellFailure != nil }
    private var text: String? { message.prompt ?? fileText }
    private var clips: Bool {
        guard let text, !showingAll, findQuery.isEmpty else { return false }
        return text.count > 600 || text.split(whereSeparator: \.isNewline).count > 12
    }

    @Environment(\.peerServers) private var peerServers
    private var target: JSONValue {
        sessionTarget(agentId: message.agentId, serverId: message.serverId, machine: message.machine, title: message.title,
                      lookup: lookup, peerServers: peerServers)
    }

    private func phrase(_ name: String) -> String {
        if message.creates {
            if failed { return String(localized: "新开会话「\(name)」失败") }
            if status == "running" { return String(localized: "正在新开会话「\(name)」") }
            return String(localized: "新开会话「\(name)」并发送")
        }
        if failed { return String(localized: "发给「\(name)」失败") }
        if status == "running" { return String(localized: "正在发给「\(name)」") }
        return String(localized: "已发给「\(name)」")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: failed ? "xmark.circle.fill" : message.creates ? "plus.bubble.fill" : "paperplane.fill").font(.system(size: 13))
                    .foregroundStyle(failed ? Theme.dotDanger : Theme.accentBright)
                MessageSenderButton(sender: target, textAlignment: .leading, phrase: phrase)
                if let timestamp {
                    Text(formatTimestamp(timestamp)).font(.system(size: 12)).foregroundStyle(Theme.extraMuted)
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 8)
                if let text {
                    Menu {
                        Button("复制内容", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("消息操作")
                }
            }
            if let text {
                let clipped = clips
                MarkdownView(text: text, renderMedia: false, continuousSelection: true)
                    .frame(maxHeight: clipped ? 200 : nil, alignment: .top)
                    .clipped()
                    .mask {
                        if clipped {
                            LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        } else { Rectangle() }
                    }
                if clipped || showingAll {
                    Button(showingAll ? "收起" : "显示全部") { withAnimation(.snappy(duration: 0.2)) { showingAll.toggle() } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accentBright)
                }
            } else if let file = message.file {
                Text(fileMissing ? String(localized: "内容在文件 \(file)，已读不到") : String(localized: "内容在文件 \(file)"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
            if failed, let reason = shellFailure ?? error.flatMap({ $0 == .null ? nil : $0["message"]?.stringValue ?? $0.stringValue ?? $0.description }) {
                Text(reason)
                    .font(.system(size: Theme.code, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(6).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .task(id: message.file) {
            // tell --file：正文在发送方机器上的文件里（发完通常还在），按需读出来。
            guard message.prompt == nil, let file = message.file, let fileReader else { return }
            if let data = await fileReader.read(file), let s = String(data: data, encoding: .utf8) { fileText = s }
            else { fileMissing = true }
        }
    }
}

extension TimelineItem {
    /// User messages and messages from other sessions open a turn (official presentation.ts).
    var startsTurn: Bool {
        switch self {
        case .userMessage: true
        case .toolCall(_, _, _, _, _, let m): m?["event"]?.stringValue == "message"
        default: false
        }
    }
}

extension ToolCallDetail {
    var isPlan: Bool { if case .plan = self { true } else { false } }
}

extension TimelineItem {
    /// One-line label (official: packages/protocol/src/tool-call-display.ts).
    var toolSummary: String {
        switch self {
        case .reasoning: return String(localized: "思考")
        case .toolCall(_, let name, _, let d, _, _):
            switch d {
            case .shell(let c, _, _, _): return PeerCommand(c)?.summary ?? c
            case .read(let p, _): return String(localized: "读取 \((p as NSString).lastPathComponent)")
            case .edit(let p, _, _, _): return String(localized: "编辑 \((p as NSString).lastPathComponent)")
            case .write(let p, _): return String(localized: "写入 \((p as NSString).lastPathComponent)")
            case .search(let q, _, _): return String(localized: "搜索 \(q)")
            case .fetch(let u, _): return String(localized: "抓取 \(u)")
            case .subAgent(let desc, _): return String(localized: "子任务 \(desc ?? "")")
            case .plainText(let label, _, _): return label ?? name
            case .plan: return String(localized: "计划")
            case .unknown(let json):
                if let action = PaseoAgentAction(name: name, detail: d) { return action.phrase(String(action.agentId.prefix(7))) }
                return OutgoingAgentMessage.paseoLeafName(name).flatMap { PaseoAgentAction.label($0, input: json["input"]) } ?? name
            }
        default: return ""
        }
    }
}
