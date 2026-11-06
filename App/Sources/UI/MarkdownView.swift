// Block-level Markdown for assistant messages. Inline styling uses AttributedString's Markdown parser;
// blocks (headings, lists, quotes, fenced code, tables, rules) are split here.

import PaseoKit
import SwiftUI
import WebKit

struct MarkdownView: View {
    /// Extra leading between wrapped lines; the system default is tight for Chinese body text.
    static let lineSpacing: CGFloat = 5
    let text: String
    // 用户粘贴的表格只做本地排版，不因同条消息含图片或图表而加载外部资源。
    var renderMedia = true
    @State private var renderCache = MarkdownRenderCache()
    @Environment(\.findQuery) private var findQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(renderCache.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s).font(.system(size: Theme.content + CGFloat(max(0, 4 - level)) * 1.5, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let s):
            inline(s).font(.system(size: Theme.content)).lineSpacing(Self.lineSpacing)
        case .list(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(Theme.muted).monospacedDigit()
                        // Wrap long items instead of truncating them with "…".
                        inline(item.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: Theme.content))
                    .lineSpacing(Self.lineSpacing)
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }
        case .quote(let s):
            inline(s).font(.system(size: Theme.content)).lineSpacing(Self.lineSpacing).foregroundStyle(Theme.muted)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 3) }
        case .code(let lang, let code):
            if renderMedia && lang?.lowercased() == "mermaid" { MermaidView(source: code) } else { CodeBlock(code: code, language: lang) }
        case .table(let rows, let aligns):
            MarkdownTable(rows: rows, aligns: aligns, cell: { inline($0.replacingOccurrences(of: "<br>", with: "\n")) })
        case .rule:
            Divider()
        case .image(let alt, let url):
            if renderMedia { MarkdownImage(alt: alt, url: url) }
            else { Text("![\(alt)](\(url))").font(.system(size: Theme.content)) }
        case .visualization(let reference):
            if renderMedia { VisualizationPreview(reference: reference) }
            else { Text(reference.marker).font(.system(size: Theme.content)) }
        }
    }

    private func inline(_ s: String) -> some View {
        HoverableMarkdownText(attributed: renderCache.inline(s, query: findQuery) {
            var attributed = InlineMarkdown.parse(s)
            FileLink.annotate(&attributed)
            // Keep links recognizable without relying on color alone.
            for run in attributed.runs where run.link != nil {
                attributed[run.range].underlineStyle = .single
            }
            highlight(&attributed, findQuery)
            return attributed
        })
    }
}

/// Text stays native and selectable; the renderer only records the actual web-link hit areas.
private struct WebLinkAttribute: TextAttribute { let url: URL }

private final class WebLinkHitAreas {
    var areas: [(CGRect, URL)] = []
}

private struct WebLinkRenderer: TextRenderer {
    let hitAreas: WebLinkHitAreas
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var areas: [(CGRect, URL)] = []
        for line in layout {
            for run in line {
                if let link = run[WebLinkAttribute.self] {
                    areas.append((run.typographicBounds.rect, link.url))
                }
                context.draw(run)
            }
        }
        hitAreas.areas = areas
    }
}

private struct HoverableMarkdownText: View {
    let attributed: AttributedString
    @Environment(\.openWebLinkInApp) private var openInApp
    @State private var hitAreas = WebLinkHitAreas()
    @State private var hoveredURL: URL?
    @State private var anchor = CGRect.zero
    @State private var presented = false
    @State private var pending: Task<Void, Never>?
    @State private var closing: Task<Void, Never>?
    @State private var pointerInPopover = false
    @State private var keyboardPresentation = false

    private var text: Text {
        attributed.runs.reduce(Text("")) { result, run in
            let part = Text(AttributedString(attributed[run.range]))
            if let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return result + part.customAttribute(WebLinkAttribute(url: url))
            }
            return result + part
        }
    }

    private var webURLs: [URL] {
        var seen = Set<URL>()
        return attributed.runs.compactMap { run in
            guard let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private func closeLater() {
        pending?.cancel()
        closing?.cancel()
        guard !keyboardPresentation else { return }
        closing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !pointerInPopover else { return }
            presented = false
            hoveredURL = nil
        }
    }

    @ViewBuilder private func actions(for url: URL) -> some View {
        Button("应用内打开", systemImage: "globe") {
            presented = false
            openInApp?(url)
        }.disabled(openInApp == nil)
        Button("默认浏览器打开", systemImage: "arrow.up.right.square") {
            presented = false
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
        Button("复制链接", systemImage: "doc.on.doc") {
            Pasteboard.copy(url.absoluteString)
            presented = false
        }
    }

    var body: some View {
        #if os(macOS)
        text.textRenderer(WebLinkRenderer(hitAreas: hitAreas))
            .focusable(!webURLs.isEmpty)
            .onKeyPress(.space) { showFromKeyboard() }
            .onKeyPress(.return) { showFromKeyboard() }
            .contextMenu {
                ForEach(webURLs, id: \.self) { url in
                    if webURLs.count == 1 { actions(for: url) }
                    else { Menu(url.absoluteString) { actions(for: url) } }
                }
            }
            .accessibilityActions {
                ForEach(webURLs, id: \.self) { url in
                    Button(String(localized: "应用内打开：\(url.absoluteString)")) { openInApp?(url) }
                    Button(String(localized: "默认浏览器打开：\(url.absoluteString)")) { NSWorkspace.shared.open(url) }
                    Button(String(localized: "复制链接：\(url.absoluteString)")) { Pasteboard.copy(url.absoluteString) }
                }
            }
            .onContinuousHover { phase in
                guard !keyboardPresentation else { return }
                switch phase {
                case .active(let point):
                    guard let hit = hitAreas.areas.first(where: { $0.0.contains(point) }) else {
                        closeLater()
                        return
                    }
                    closing?.cancel()
                    guard hit.1 != hoveredURL || !presented else { return }
                    pending?.cancel()
                    presented = false
                    hoveredURL = hit.1
                    anchor = hit.0
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        presented = true
                    }
                case .ended: closeLater()
                }
            }
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: max(1, anchor.width), height: max(1, anchor.height))
                    .allowsHitTesting(false)
                    .popover(isPresented: $presented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(hoveredURL.map { [$0] } ?? webURLs, id: \.self) { url in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(url.host() ?? url.absoluteString)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(url.absoluteString)
                                        .accessibilityLabel(url.absoluteString)
                                    actions(for: url)
                                }
                            }
                        }
                        .buttonStyle(.plain).padding(12).frame(maxWidth: 320, alignment: .leading)
                        .onHover { inside in
                            pointerInPopover = inside
                            if inside { closing?.cancel() } else { closeLater() }
                        }
                    }
                    .offset(x: anchor.minX, y: anchor.minY)
            }
            .onChange(of: presented) { _, visible in
                if !visible {
                    keyboardPresentation = false
                    pointerInPopover = false
                    closing?.cancel()
                }
            }
            .onDisappear { pending?.cancel(); closing?.cancel(); presented = false }
        #else
        Text(attributed)
        #endif
    }

    private func showFromKeyboard() -> KeyPress.Result {
        guard !webURLs.isEmpty else { return .ignored }
        pending?.cancel()
        closing?.cancel()
        hoveredURL = nil
        keyboardPresentation = true
        presented = true
        return .handled
    }
}

private struct OpenWebLinkInAppKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL) -> Void)? = nil
}
extension EnvironmentValues {
    var openWebLinkInApp: (@MainActor (URL) -> Void)? {
        get { self[OpenWebLinkInAppKey.self] }
        set { self[OpenWebLinkInAppKey.self] = newValue }
    }
}

/// Bordered table like the official app: short columns keep their natural width, long ones wrap.
struct MarkdownTable<Cell: View>: View {
    let rows: [[String]]
    let aligns: [TextAlignment]
    let cell: (String) -> Cell

    private var columns: Int { rows.map(\.count).max() ?? 0 }
    @State private var selection: TableCellRange?
    @State private var frames: [TableCellPosition: CGRect] = [:]
    @State private var coordinateSpace = UUID()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu(copied ? "已复制" : "复制表格") {
                    if !rows.isEmpty, columns > 0 {
                        copyActions(TableCellRange(anchor: .init(row: 0, column: 0), end: .init(row: rows.count - 1, column: columns - 1)))
                    }
                }
                if let selection {
                    Menu("复制所选区域") { copyActions(selection) }
                    Button("取消选择") { self.selection = nil }
                }
                Spacer(minLength: 0)
            }.font(.caption).buttonStyle(.borderless)
            grid
        }
        .onChange(of: rows) { selection = nil; copied = false }
    }

    @ViewBuilder private func copyActions(_ range: TableCellRange) -> some View {
        Button("复制为 Markdown") { Pasteboard.copy(range.markdown(from: rows)); copied = true }
        Button("复制为表格") { TableClipboard.copyTSV(range.text(from: rows)); copied = true }
    }

    private func cellAt(_ point: CGPoint) -> TableCellPosition? {
        frames.first { $0.value.contains(point) }?.key
    }

    private var grid: some View {
        TableLayout(columns: columns) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                ForEach(0..<columns, id: \.self) { c in
                    let align = c < aligns.count ? aligns[c] : .leading
                    cell(c < row.count ? row[c] : "")
                        .fontWeight(r == 0 ? .semibold : .regular)
                        .multilineTextAlignment(align)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(align))
                        .background(selection?.contains(.init(row: r, column: c)) == true ? Theme.accent.opacity(0.22) : (r == 0 ? Theme.surface2 : .clear))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TableCellFrames.self, value: [.init(row: r, column: c): geometry.frame(in: .named(coordinateSpace))])
                        })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            let position = TableCellPosition(row: r, column: c)
                            selection = TableCellRange(anchor: position, end: position)
                            copied = false
                        }
                        .accessibilityAction(named: "选择单元格") {
                            let position = TableCellPosition(row: r, column: c)
                            selection = TableCellRange(anchor: position, end: position)
                            copied = false
                        }
                        .overlay(alignment: .trailing) {
                            if c < columns - 1 { Rectangle().fill(Theme.border).frame(width: 1) }
                        }
                        .overlay(alignment: .bottom) {
                            if r < rows.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                        }
                }
            }
        }
        .font(.system(size: Theme.content - 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        // 表格使用区域选择，避免系统文本选择抢走双击和长按。
        .textSelection(.disabled)
        .coordinateSpace(name: coordinateSpace)
        .onPreferenceChange(TableCellFrames.self) { frames = $0 }
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace)))
            .onChanged { value in
                if case .second(true, let drag?) = value,
                   let start = cellAt(drag.startLocation), let end = cellAt(drag.location) {
                    selection = TableCellRange(anchor: start, end: end)
                    copied = false
                }
            })
        .help("双击选择单元格，长按拖动选择区域")
    }

    private func frameAlignment(_ a: TextAlignment) -> Alignment {
        switch a { case .center: .center; case .trailing: .trailing; default: .leading }
    }
}

/// Row-major grid. Columns that fit get their one-line width; the remaining width is shared
/// equally among the wider ones (water-filling), never going below a readable minimum.
struct TableLayout: Layout {
    let columns: Int
    var minColumn: CGFloat = 64

    struct Cache {
        var width: CGFloat?
        var sizes: ([CGFloat], [CGFloat])?
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }
    private func measured(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout Cache) -> ([CGFloat], [CGFloat]) {
        if cache.width == width, let sizes = cache.sizes { return sizes }
        let sizes = measure(width, subviews)
        cache.width = width
        cache.sizes = sizes
        return sizes
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let (widths, heights) = measured(proposal.width, subviews, &cache)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (widths, heights) = measured(bounds.width, subviews, &cache)
        var y = bounds.minY
        for r in heights.indices {
            var x = bounds.minX
            for c in widths.indices {
                let i = r * columns + c
                guard i < subviews.count else { return }
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[c], height: heights[r]))
                x += widths[c]
            }
            y += heights[r]
        }
    }

    private func measure(_ available: CGFloat?, _ subviews: Subviews) -> ([CGFloat], [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        let rowCount = (subviews.count + columns - 1) / columns
        var ideal = [CGFloat](repeating: 0, count: columns)
        for (i, v) in subviews.enumerated() {
            ideal[i % columns] = max(ideal[i % columns], ceil(v.sizeThatFits(.unspecified).width))
        }
        let total = ideal.reduce(0, +)
        var widths = ideal
        if let available, available.isFinite {
            if total <= available {
                // Stretch to the full width, extra space going to the wider columns.
                let extra = available - total
                widths = ideal.map { $0 + extra * $0 / max(total, 1) }
            } else {
                let floors = ideal.map { min($0, minColumn) }
                var lo: CGFloat = 0, hi = ideal.max() ?? 0
                for _ in 0..<30 {
                    let cap = (lo + hi) / 2
                    let sum = zip(ideal, floors).map { max($1, min($0, cap)) }.reduce(0, +)
                    if sum > available { hi = cap } else { lo = cap }
                }
                widths = zip(ideal, floors).map { max($1, min($0, lo)) }
            }
        }
        var heights = [CGFloat](repeating: 0, count: rowCount)
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height
            heights[i / columns] = max(heights[i / columns], ceil(h))
        }
        return (widths, heights)
    }
}

struct CodeBlock: View {
    let code: String
    var language: String? = nil
    @State private var hovering = false
    @State private var copied = false
    @State private var renderCache = CodeRenderCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).padding(.top, 7)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let lang = SyntaxHighlight.language(for: language) {
                        Text(renderCache.code(code, language: language ?? "") { SyntaxHighlight.highlight(code, lang) })
                    }
                    else { Text(code) }
                }
                .font(.system(size: Theme.code, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button {
                Pasteboard.copy(code)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Theme.dotSuccess : Theme.muted)
            .help("复制代码")
            .accessibilityLabel(copied ? "已复制" : "复制代码")
            .padding(5)
            // No hover on a touch screen: keep the copy button visible there.
            #if os(macOS)
            .opacity(hovering || copied ? 1 : 0)
            #endif
        }
        .onHover { hovering = $0 }
    }
}

/// 每条消息只保留当前版本；已闭合的段落不随尾部 token 重新解析。
@MainActor final class MarkdownRenderCache {
    private var text: String?
    private var stablePrefix = ""
    private var stableBlocks: [MarkdownBlock] = []
    private var value: [MarkdownBlock] = []
    private var inlines: [String: (query: String, value: AttributedString)] = [:]

    func blocks(_ next: String) -> [MarkdownBlock] {
        if text == next { return value }
        if !next.hasPrefix(stablePrefix) { stablePrefix = ""; stableBlocks = [] }
        let tail = String(next.dropFirst(stablePrefix.count))
        // 只有完整空行且不在代码围栏内才是稳定边界；表格、列表、未闭合围栏都留在尾部。
        var fence: String?
        var boundary = tail.startIndex
        var cursor = tail.startIndex
        while let newline = tail[cursor...].firstIndex(of: "\n") {
            let line = tail[cursor..<newline].trimmingCharacters(in: .whitespaces)
            let end = tail.index(after: newline)
            if let active = fence {
                if line.hasPrefix(active) { fence = nil }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
            } else if line.isEmpty { boundary = end }
            cursor = end
        }
        if boundary > tail.startIndex {
            let committed = String(tail[..<boundary])
            stableBlocks += MarkdownBlock.parse(committed)
            stablePrefix += committed
        }
        value = stableBlocks + MarkdownBlock.parse(String(tail[boundary...]))
        text = next
        let strings = Set(value.flatMap(\.inlineStrings))
        inlines = inlines.filter { strings.contains($0.key) }
        return value
    }

    func inline(_ text: String, query: String, _ make: () -> AttributedString) -> AttributedString {
        if let hit = inlines[text], hit.query == query { return hit.value }
        let value = make()
        inlines[text] = (query, value)
        return value
    }
}

@MainActor final class CodeRenderCache {
    private var key: String?
    private var value = AttributedString()
    func code(_ code: String, language: String, _ make: () -> AttributedString) -> AttributedString {
        let next = language + "\u{0}" + code
        if key != next { value = make(); key = next }
        return value
    }
}

enum MarkdownBlock {
    /// 转义的竖线属于单元格内容，不能把它拆成新列。
    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", escaped = false
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("|") { source.removeFirst() }
        if source.hasSuffix("|") {
            let slashes = source.dropLast().reversed().prefix { $0 == "\\" }.count
            if slashes % 2 == 0 { source.removeLast() }
        }
        for c in source {
            if c == "|", !escaped { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
            if c == "\\" { escaped.toggle() } else { escaped = false }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
    var inlineStrings: [String] {
        switch self {
        case .heading(_, let text), .paragraph(let text), .quote(let text): [text]
        case .list(let items): items.map(\.text)
        case .table(let rows, _): rows.flatMap { $0 }
        default: []
        }
    }

    struct ListItem { let marker: String; let text: String; let indent: Int }
    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(String?, String)
    case table([[String]], [TextAlignment])
    case rule
    case image(alt: String, url: String)
    case visualization(VisualizationReference)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var table: [[String]] = []
        var aligns: [TextAlignment] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table, aligns)); table = []; aligns = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(lang.isEmpty ? nil : lang, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let reference = VisualizationReference(marker: trimmed) {
                flush()
                blocks.append(.visualization(reference))
                i += 1; continue
            }
            // A line that is only an image: ![alt](url)
            if let m = trimmed.firstMatch(of: /^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$/) {
                flush()
                blocks.append(.image(alt: String(m.1), url: String(m.2)))
                i += 1; continue
            }
            if trimmed.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) != nil {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(level, String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush(); blocks.append(.rule); i += 1; continue
            }
            let nextCells = i + 1 < lines.count ? tableCells(lines[i + 1]) : []
            let startsTable = trimmed.contains("|") && !nextCells.isEmpty && nextCells.allSatisfy {
                $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
            }
            if (trimmed.hasPrefix("|") && trimmed.hasSuffix("|")) || startsTable || (!table.isEmpty && trimmed.contains("|")) {
                if !paragraph.isEmpty || !list.isEmpty || !quote.isEmpty { flush() }
                let cells = tableCells(trimmed)
                if cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) {
                    aligns = cells.map { c in
                        c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .trailing : .leading
                    }
                } else {
                    table.append(cells)
                }
                i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty || !table.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }
            if let m = trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                if !paragraph.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                let marker = trimmed[m].trimmingCharacters(in: .whitespaces)
                let indent = (line.prefix { $0 == " " }.count) / 2
                let shown = marker.first.map { "-*+".contains($0) } == true ? "•" : marker
                list.append(ListItem(marker: shown, text: String(trimmed[m.upperBound...]), indent: indent))
                i += 1; continue
            }
            if !list.isEmpty, line.hasPrefix("  ") {
                let last = list.removeLast()
                list.append(ListItem(marker: last.marker, text: last.text + " " + trimmed, indent: last.indent))
                i += 1; continue
            }
            if !list.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }
}

/// First-seen copies of images the agent looked at, in Caches; entries unused for 30 days are dropped.
enum ImageSnapshotCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Paseo", isDirectory: true)
            .appendingPathComponent("ImageSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        prune(d)
        return d
    }()

    private static func file(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
    }

    static func load(_ key: String) -> Data? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    static func save(_ data: Data, key: String) { try? data.write(to: file(key)) }

    private static func prune(_ dir: URL) {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Images in replies: web images load directly; file:// paths only exist on the agent's machine,
/// so they show when this app runs on that same machine and as a placeholder otherwise.
struct MarkdownImage: View {
    let alt: String
    let url: String
    var maxSize = CGSize(width: 520, height: 420)
    var alignment: Alignment = .leading
    /// Keep the first copy fetched under this key, so a file overwritten later still shows what was there.
    var cacheKey: String?
    @State private var zoomed: Image?
    @State private var thumbnail: Image?
    @State private var tried = false
    @Environment(\.hostFileReader) private var reader
    @Environment(\.displayScale) private var displayScale

    private var sourceKey: String { (reader?.cacheScope ?? "local") + "|" + (cacheKey ?? url) }
    private var pixels: Int { Int(max(maxSize.width, maxSize.height) * displayScale) }

    var body: some View {
        Group {
            if let thumbnail {
                thumbnail.resizable().scaledToFit()
                    .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: alignment)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        zoomed = thumbnail
                        Task {
                            if let cg = await loadImage(maxPixel: nil), !Task.isCancelled, zoomed != nil {
                                zoomed = Image(decorative: cg, scale: 1)
                            }
                        }
                    }
            } else { placeholder(loading: !tried) }
        }
        .task(id: "\(sourceKey)|\(pixels)") {
            thumbnail = nil
            tried = false
            let cg = await loadImage(maxPixel: pixels)
            guard !Task.isCancelled else { return }
            thumbnail = cg.map { Image(decorative: $0, scale: displayScale) }
            tried = true
        }
        .help(alt.isEmpty ? String(localized: "点击放大") : String(localized: "\(alt)（点击放大）"))
        .sheet(isPresented: Binding(get: { zoomed != nil }, set: { if !$0 { zoomed = nil } })) {
            if let zoomed { ImageLightbox(image: zoomed, title: alt) }
        }
    }

    private func loadImage(maxPixel: Int?) async -> CGImage? {
        await TimelineImageLoader.shared.image(key: sourceKey, url: url, snapshotKey: cacheKey,
                                               maxPixel: maxPixel, reader: reader)
    }

    private func placeholder(loading: Bool) -> some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "photo") }
            Text(alt.isEmpty || alt == "Image" ? String(localized: "图片（无法预览）") : alt).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
        .help(url)
    }
}

/// Slash commands an agent suggests in inline code (`/compact`) become `paseo-cmd:` links; the agent view
/// appends a command the session knows to the composer draft (official 0.15 #8371). Unknown ones do nothing new.
enum CommandLink {
    static let scheme = "paseo-cmd"

    static func make(_ text: String) -> URL? {
        guard isCommand(text) else { return nil }
        return URL(string: scheme + ":" + text.dropFirst())
    }

    /// `/name` with no further slash or spaces (so it is not a path).
    static func isCommand(_ text: String) -> Bool {
        text.range(of: #"^/[A-Za-z][A-Za-z0-9_:.-]*$"#, options: .regularExpression) != nil
    }

    /// The command a link names: a `paseo-cmd:` link, or a Markdown link to `/name`.
    static func name(_ url: URL) -> String? {
        if url.scheme == scheme { return String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding }
        if let (path, line) = FileLink.parse(url), line == nil, isCommand(path) { return String(path.dropFirst()) }
        return nil
    }
}

/// File references in replies become `paseo-file:` links the agent view opens in a file tab.
/// Covers inline code that looks like a path (`Sources/App.swift:42`) and Markdown links to
/// relative or absolute paths (`[App.swift](Sources/App.swift#L42)`). Official: file links in agent-stream markdown.
enum FileLink {
    static let scheme = "paseo-file"

    static func annotate(_ s: inout AttributedString) {
        for run in s.runs {
            let range = run.range
            if let link = run.link {
                if let target = fileTarget(link) { s[range].link = target }
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                let text = String(s[range].characters)
                if looksLikePath(text), let url = make(text) { s[range].link = url }
                else if let url = CommandLink.make(text) { s[range].link = url }
            }
        }
    }

    /// `path`, `path:12`, `path:12:3`, `path#L12`.
    static func parse(_ url: URL) -> (path: String, line: Int?)? {
        guard url.scheme == scheme else { return nil }
        let raw = url.absoluteString.dropFirst(scheme.count + 1)
        guard let decoded = String(raw).removingPercentEncoding else { return nil }
        return split(decoded)
    }

    private static func split(_ s: String) -> (String, Int?) {
        if let m = s.firstMatch(of: /^(.+?)#L(\d+)(?:-L?\d+)?$/) { return (String(m.1), Int(m.2)) }
        if let m = s.firstMatch(of: /^(.+?):(\d+)(?::\d+)?$/) { return (String(m.1), Int(m.2)) }
        return (s, nil)
    }

    private static func make(_ path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":#"))) ?? path
        return URL(string: scheme + ":" + encoded)
    }

    private static func fileTarget(_ url: URL) -> URL? {
        if url.isFileURL { return make(url.path + (url.fragment.map { "#" + $0 } ?? "")) }
        guard url.scheme == nil else { return nil }
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return looksLikePath(s) ? make(s) : nil
    }

    /// A path-ish token: no spaces, has a file extension or a slash, not a URL or a bare number/flag.
    static func looksLikePath(_ raw: String) -> Bool {
        let s = split(raw).0
        guard !s.isEmpty, s.count < 300, !s.contains(" "), !s.contains("://"), !s.hasPrefix("-") else { return false }
        guard s.range(of: #"^[~./A-Za-z0-9_@+-][A-Za-z0-9_@+./-]*$"#, options: .regularExpression) != nil else { return false }
        let last = (s as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension
        let hasExt = !ext.isEmpty && ext.count <= 10 && ext.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil
            && !(last as NSString).deletingPathExtension.isEmpty
        return hasExt && (s.contains("/") || raw != s || knownExtensions.contains(ext.lowercased()))
    }

    private static let knownExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "rs", "java", "kt", "c", "h", "m", "mm", "cpp", "rb", "sh",
        "md", "json", "yml", "yaml", "toml", "plist", "html", "css", "scss", "sql", "txt", "lock", "xml", "vue", "php",
    ]
}

/// Full-size image: pinch or ⌘+/⌘− to zoom, double-click to toggle fit / 2×, Esc to close.
struct ImageLightbox: View {
    @Environment(\.dismiss) private var dismiss
    let image: Image
    var title = ""
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title.isEmpty || title == "Image" ? String(localized: "图片") : title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-", modifiers: .command)
                    .accessibilityLabel("缩小")
                Text("\(Int(scale * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted).frame(width: 44)
                Button { zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("=", modifiers: .command)
                    .accessibilityLabel("放大")
                Button { scale = 1; base = 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .keyboardShortcut("0", modifiers: .command).help("适合窗口")
                    .accessibilityLabel("适合窗口")
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.plain)
            .padding(12)
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    image.resizable().scaledToFit()
                        .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                        .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2; base = scale } }
                }
                .gesture(MagnifyGesture()
                    .onChanged { scale = min(max(base * $0.magnification, 0.5), 8) }
                    .onEnded { _ in base = scale })
            }
            .background(Theme.surface1)
        }
        .macOnly { $0.frame(minWidth: 720, minHeight: 540) }
    }

    private func zoom(_ f: CGFloat) {
        withAnimation(.snappy(duration: 0.15)) { scale = min(max(scale * f, 0.5), 8); base = scale }
    }
}

/// ```mermaid blocks drawn by mermaid.js in a web view (needs network for the script); source is one click away.
struct MermaidView: View {
    let source: String
    @State private var height: CGFloat = 120
    @State private var failed = false
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if failed || showSource {
                CodeBlock(code: source, language: "mermaid")
            } else {
                MermaidWeb(source: source, height: $height, failed: $failed)
                    .frame(height: height)
                    .background(Theme.surface0, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
            Button(showSource ? "显示图" : "显示源码") { showSource.toggle() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

private struct MermaidWeb {
    let source: String
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeWeb(_ c: Coordinator) -> WKWebView {
        let v = WKWebView()
        v.navigationDelegate = c
        #if os(macOS)
        v.setValue(false, forKey: "drawsBackground")
        #else
        v.isOpaque = false
        v.scrollView.isScrollEnabled = false
        #endif
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>body{margin:0;padding:12px;font-family:-apple-system;background:transparent}
        @media (prefers-color-scheme: dark){body{color:#eee}}</style>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script></head>
        <body><pre class="mermaid">\(escaped)</pre>
        <script>
        try {
          mermaid.initialize({startOnLoad:false, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'});
          mermaid.run().then(()=>{document.title='ok:'+document.body.scrollHeight}).catch(()=>{document.title='err'});
        } catch(e) { document.title='err' }
        </script></body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        return v
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: MermaidWeb
        init(_ p: MermaidWeb) { parent = p }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            // mermaid.run is async: poll the title it sets.
            Task { @MainActor in
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(150))
                    let t = (try? await w.evaluateJavaScript("document.title")) as? String ?? ""
                    if t.hasPrefix("ok:"), let h = Double(t.dropFirst(3)) { parent.height = min(max(h, 60), 900); return }
                    if t == "err" { parent.failed = true; return }
                }
                parent.failed = true
            }
        }

        func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.failed = true }
    }
}

#if os(macOS)
extension MermaidWeb: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWeb(context.coordinator) }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
extension MermaidWeb: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWeb(context.coordinator) }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

/// Marks every case-insensitive occurrence of `query` (in-session find).
func highlight(_ s: inout AttributedString, _ query: String) {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return }
    var start = s.startIndex
    while start < s.endIndex, let r = s[start...].range(of: q, options: .caseInsensitive) {
        s[r].backgroundColor = Theme.dotWarning.opacity(0.35)
        start = r.upperBound
    }
}

extension MarkdownBlock {
    /// The message as readable plain text: Markdown markers dropped, list markers and line breaks kept.
    /// For「选择文本」, where one selectable text spans the whole message.
    static func plainText(_ markdown: String) -> String {
        func inline(_ s: String) -> String {
            let a = InlineMarkdown.parse(s)
            return String(a.characters)
        }
        return parse(markdown).compactMap { block -> String? in
            switch block {
            case .heading(_, let s), .paragraph(let s), .quote(let s): inline(s)
            case .list(let items):
                items.map { String(repeating: "  ", count: $0.indent) + $0.marker + " " + inline($0.text) }.joined(separator: "\n")
            case .code(_, let code): code
            case .table(let rows, _): rows.map { $0.map(inline).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: nil
            case .image(let alt, let url): alt.isEmpty ? url : alt
            case .visualization(let reference): reference.path
            }
        }
        .joined(separator: "\n\n")
    }
}
