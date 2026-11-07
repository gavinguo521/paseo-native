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
                case .toolCall(_, _, _, let detail, _, let m): m == nil && !detail.isPlan
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
                    case .toolCall(_, _, _, let detail, _, let message) where message == nil && !detail.isPlan:
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
            case .toolCall(_, _, _, let detail, _, let agentMessage) where agentMessage == nil && !detail.isPlan:
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
        positions = nil
        visibilityReads = 0
        key = k
        return items
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

extension EnvironmentValues {
    @Entry var sentImages: [String: [ImageAttachment]] = [:]
    @Entry var messageImagesConnected = false
    @Entry var timelineActions = TimelineActions()
    /// Reads a file on the agent's machine (images in replies that live there). Paths may be relative to the agent's cwd.
    /// Agent id → title on the same host, for tool details that target other sessions.
    @Entry var agentTitle: AgentTitleLookup? = nil
    /// Text being searched in the session; every occurrence is highlighted.
    @Entry var findQuery: String = ""
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
    @State private var expanded = false
    @State private var markdownCache = MarkdownRenderCache()
    @Environment(\.findQuery) private var findQuery

    private static let foldLines = 14
    private var hasTable: Bool { markdownCache.blocks(text).contains { if case .table = $0 { true } else { false } } }
    private var long: Bool { text.count > 900 || text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.foldLines }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let sender {
                Label("由「\(sender)」发送", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
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
                    HStack(spacing: 6) {
                        Spacer(minLength: 64)
                        ForEach(pending.images) { a in
                            (ImageTools.image(a, maxPixel: 1080) ?? Image(systemName: "photo")).resizable().scaledToFit()
                                .frame(maxWidth: 360, maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
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
                // Official presentation: a message from another session reads as a user message with its sender.
                UserBubble(text: text, sender: agentMessage["sender"]?["title"]?.stringValue
                           ?? agentMessage["sender"]?["id"]?.stringValue.map { String($0.prefix(7)) } ?? String(localized: "其他会话"))
                    .padding(.top, 16)
            } else if let agentMessage {
                AgentMessageView(message: agentMessage)
            } else if case .plan(let text) = detail, case .toolCall(_, _, let status, _, _, _) = row.item {
                PlanCard(text: text, status: status)
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
    @AppStorage("autoExpandReasoning") private var autoExpandReasoning = true
    @AppStorage("timelineDetail") private var timelineDetail = TimelineDetail.collapseTurns.rawValue
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
                    } else {
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

    /// The shell command the header names (the running one, or the only step), first line only.
    private var command: String? {
        let r: TimelineRow?
        if running { r = rows.last(where: { if case .toolCall(_, _, let s, _, _, _) = $0.item { s == "running" } else { $0.isStreaming } }) }
        else { r = rows.count == 1 ? rows[0] : nil }
        guard let r, case .toolCall(_, _, _, .shell(let c, _, _, _), _, _) = r.item else { return nil }
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
            if m != nil { continue }
            switch d {
            case .shell: commands += 1
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
                Text(row.item.toolSummary).font(.system(size: Theme.code)).foregroundStyle(Theme.muted).lineLimit(1)
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
            UnknownToolDetail(input: json["input"], output: json["output"], raw: json)
        }
    }
}

/// Tools without a typed detail (MCP, Paseo tools…): input fields as key/value rows, output as text or JSON.
private struct UnknownToolDetail: View {
    let input: JSONValue?
    let output: JSONValue?
    let raw: JSONValue
    @Environment(\.agentTitle) private var agentTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = input?["agentId"]?.stringValue ?? input?["agent_id"]?.stringValue, let title = agentTitle?.lookup(id) {
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

/// Messages between agents (sub-agent finished, cross-machine messages) arrive as tool calls with `agentMessage`.
private struct AgentMessageView: View {
    let message: JSONValue
    @State private var expanded = false

    var body: some View {
        let sender = message["sender"]?["title"]?.stringValue ?? message["sender"]?["id"]?.stringValue.map { String($0.prefix(7)) } ?? String(localized: "其他会话")
        let event = message["event"]?.stringValue ?? "message"
        let label = switch event {
        case "finished": String(localized: "「\(sender)」完成了")
        case "errored": String(localized: "「\(sender)」出错")
        case "permission-required": String(localized: "「\(sender)」需要权限")
        case "closed": String(localized: "「\(sender)」已关闭")
        default: String(localized: "来自「\(sender)」的消息")
        }
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                    Text(label).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: Theme.base)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            if expanded, let text = message["text"]?.stringValue {
                MarkdownView(text: text).padding(.leading, 20)
            }
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
            case .shell(let c, _, _, _): return c
            case .read(let p, _): return String(localized: "读取 \((p as NSString).lastPathComponent)")
            case .edit(let p, _, _, _): return String(localized: "编辑 \((p as NSString).lastPathComponent)")
            case .write(let p, _): return String(localized: "写入 \((p as NSString).lastPathComponent)")
            case .search(let q, _, _): return String(localized: "搜索 \(q)")
            case .fetch(let u, _): return String(localized: "抓取 \(u)")
            case .subAgent(let desc, _): return String(localized: "子任务 \(desc ?? "")")
            case .plainText(let label, _, _): return label ?? name
            case .plan: return String(localized: "计划")
            case .unknown: return name
            }
        default: return ""
        }
    }
}
