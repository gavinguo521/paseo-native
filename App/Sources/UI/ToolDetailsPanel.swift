import PaseoKit
import SwiftUI

struct ToolDetailsAction {
    let open: (String) -> Void
}

extension EnvironmentValues {
    @Entry var toolDetailsAction: ToolDetailsAction? = nil
}

/// 用稳定的消息 id 跟踪选中块；流式替换内容不会丢失选择。
enum ToolDetailsSelection {
    static func rows(_ rows: [TimelineRow]) -> [TimelineRow] {
        rows.filter {
            switch $0.item { case .toolCall, .reasoning: true; default: false }
        }
    }
    static func text(_ row: TimelineRow) -> String {
        switch row.item {
        case .reasoning(let text): return text
        case .toolCall(_, _, _, let detail, let error, _):
            let body: String
            switch detail {
            case .shell(let command, let cwd, let output, let exit):
                body = [cwd, "$ " + command, output, exit.map { "[exit \($0)]" }].compactMap { $0 }.joined(separator: "\n")
            case .read(let path, let content), .write(let path, let content): body = path + "\n" + (content ?? "")
            case .edit(let path, let old, let new, let diff): body = path + "\n" + (diff ?? DiffView.fallback(old: old ?? "", new: new ?? ""))
            case .search(let query, let content, let files): body = query + "\n" + (content ?? files.joined(separator: "\n"))
            case .fetch(let url, let result): body = url + "\n" + (result ?? "")
            case .subAgent(let description, let log): body = [description, log].compactMap { $0 }.joined(separator: "\n")
            case .plainText(let label, let text, _): body = [label, text].compactMap { $0 }.joined(separator: "\n")
            case .plan(let text): body = text
            case .unknown(let value): body = value.description
            }
            return body + (error == nil || error == .null ? "" : "\n" + error!.description)
        default: return row.item.toolSummary
        }
    }
    static func neighbor(_ id: String, in rows: [TimelineRow], offset: Int) -> String? {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset) else { return nil }
        return rows[index + offset].id
    }
}

struct ToolDetailsPresenter: ViewModifier {
    let rows: [TimelineRow]
    @Binding var selectedID: String?
    @State private var width: CGFloat = 0
    private var wide: Bool { width >= 900 }
    private var sheet: Binding<Bool> {
        Binding(get: { selectedID != nil && !wide }, set: { if !$0 && !wide { selectedID = nil } })
    }
    func body(content: Content) -> some View {
        content
            .environment(\.toolDetailsAction, ToolDetailsAction { selectedID = $0 })
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if wide, selectedID != nil {
                    HStack(spacing: 0) {
                        Divider()
                        ToolDetailsPanel(rows: rows, selectedID: $selectedID).frame(width: min(440, width * 0.42))
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .sheet(isPresented: sheet) {
                ToolDetailsPanel(rows: rows, selectedID: $selectedID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .macOnly { $0.frame(minWidth: 460, minHeight: 480) }
            }
    }
}

struct ToolDetailsPanel: View {
    let rows: [TimelineRow]
    @Binding var selectedID: String?
    @State private var follow = true
    private var blocks: [TimelineRow] { ToolDetailsSelection.rows(rows) }
    private var row: TimelineRow? { blocks.first { $0.id == selectedID } }

    private var streaming: Bool {
        guard let row else { return false }
        if case .toolCall(_, _, let status, _, _, _) = row.item { return status == "running" }
        return row.isStreaming
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("工具详情").font(.headline)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.left").mobileTouchTarget() }
                    .disabled(neighbor(-1) == nil).accessibilityLabel("上一条")
                Button { move(1) } label: { Image(systemName: "chevron.right").mobileTouchTarget() }
                    .disabled(neighbor(1) == nil).accessibilityLabel("下一条")
                Button { selectedID = nil } label: { Image(systemName: "xmark").mobileTouchTarget() }.accessibilityLabel("关闭")
            }.buttonStyle(.borderless).padding(14)
            Divider()
            if let row {
                HStack {
                    Text(row.item.toolSummary).font(.caption).lineLimit(2)
                    Spacer()
                    Button { Pasteboard.copy(ToolDetailsSelection.text(row)) } label: { Image(systemName: "doc.on.doc").mobileTouchTarget() }
                        .accessibilityLabel("复制详情")
                }.padding(12)
                ScrollView {
                    ToolDetailView(row: row, showHeader: false, fullContent: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .id(row.id)
                .defaultScrollAnchor(follow && streaming ? .bottom : .top, for: .sizeChanges)
                if streaming {
                    Toggle("跟随实时输出", isOn: $follow).font(.caption).padding(12)
                }
            } else {
                ContentUnavailableView("详情暂不可用", systemImage: "doc.text", description: Text("该消息不在当前历史窗口中，请重新打开。"))
            }
        }
        .background(Theme.surface0)
    }
    private func neighbor(_ offset: Int) -> String? {
        selectedID.flatMap { ToolDetailsSelection.neighbor($0, in: blocks, offset: offset) }
    }
    private func move(_ offset: Int) { if let next = neighbor(offset) { selectedID = next } }
}
