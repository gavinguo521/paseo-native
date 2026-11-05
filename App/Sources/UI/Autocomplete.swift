// "/" commands & skills and "@" file mentions. Official: utils/agent-command-autocomplete.ts,
// utils/file-mention-autocomplete.ts. The trigger is the token being typed at the end of the text.

import PaseoKit
import SwiftUI

enum AutocompleteTrigger: Equatable {
    /// `atStart`: the "/" is the first character (commands + skills); otherwise skills only.
    case command(query: String, range: Range<String.Index>, atStart: Bool)
    case mention(query: String, range: Range<String.Index>)

    static func detect(_ text: String) -> AutocompleteTrigger? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        // Token = trailing run without whitespace.
        let tokenStart = text.lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? text.startIndex
        let token = text[tokenStart...]
        if token.first == "/", !token.dropFirst().contains(where: { "/\"'".contains($0) }) {
            return .command(query: String(token.dropFirst()), range: tokenStart..<text.endIndex, atStart: tokenStart == text.startIndex)
        }
        if let at = token.lastIndex(of: "@") {
            if at > token.startIndex, let prev = token[..<at].last, prev.isLetter || prev.isNumber || prev == "+" || prev == "_" { return nil }
            let q = token[token.index(after: at)...]
            if q.contains(where: { "\"'<>".contains($0) }) { return nil }
            return .mention(query: String(q), range: at..<text.endIndex)
        }
        return nil
    }
}

struct Suggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    /// Replaces the trigger token.
    let insert: String
    /// Client-side command run instead of inserting.
    var local: String?
}

@MainActor @Observable
final class AutocompleteModel {
    var items: [Suggestion] = []
    var index = 0
    var trigger: AutocompleteTrigger?
    private var task: Task<Void, Never>?

    var isActive: Bool { trigger != nil && !items.isEmpty }

    func update(text: String, host: HostStore, agentId: String?, cwd: String?) {
        let t = AutocompleteTrigger.detect(text)
        guard t != trigger else { return }
        trigger = t
        task?.cancel()
        guard let t else { items = []; return }
        task = Task {
            switch t {
            case .command(let q, _, let atStart):
                var list: [Suggestion] = []
                if atStart, agentId != nil {
                    list += [
                        Suggestion(id: "/new", title: "/new", detail: "在这个工作区开新会话（沿用模型和模式）", systemImage: "plus.bubble", insert: "", local: "new"),
                        Suggestion(id: "/clear", title: "/clear", detail: "归档并开新会话（沿用模型和模式）", systemImage: "square.and.pencil", insert: "", local: "clear"),
                        Suggestion(id: "/exit", title: "/exit", detail: "归档这个会话（也可以用 /quit、/q）", systemImage: "archivebox", insert: "", local: "exit"),
                        Suggestion(id: "/quit", title: "/quit", detail: "归档这个会话", systemImage: "archivebox", insert: "", local: "exit"),
                        Suggestion(id: "/q", title: "/q", detail: "归档这个会话", systemImage: "archivebox", insert: "", local: "exit"),
                    ]
                }
                let commands = agentId != nil ? await host.listCommands(agentId!) : []
                list += commands.filter { atStart || $0.isSkill }.map {
                    Suggestion(id: "/" + $0.name, title: "/" + $0.name + ($0.argumentHint.isEmpty ? "" : " " + $0.argumentHint),
                               detail: $0.description, systemImage: $0.isSkill ? "sparkles" : "command", insert: "/" + $0.name + " ")
                }
                let ql = q.lowercased()
                let filtered = ql.isEmpty ? list : list.filter { $0.id.lowercased().contains(ql) }
                guard !Task.isCancelled else { return }
                items = Array(filtered.prefix(40))
            case .mention(let q, _):
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let found = await host.pathSuggestions(cwd: cwd, query: q)
                guard !Task.isCancelled else { return }
                items = found.map {
                    let quoted = "\"" + $0.path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
                    return Suggestion(id: $0.path, title: $0.path, detail: "", systemImage: $0.isDirectory ? "folder" : "doc", insert: quoted + " ")
                }
            }
            index = 0
        }
    }

    func apply(_ s: Suggestion, to text: inout String) {
        guard let trigger else { return }
        let range: Range<String.Index>
        switch trigger {
        case .command(_, let r, _), .mention(_, let r): range = r
        }
        if range.upperBound <= text.endIndex { text.replaceSubrange(range, with: s.insert) }
        dismiss()
    }

    func dismiss() {
        task?.cancel()
        items = []
        trigger = nil
    }
}

struct SuggestionList: View {
    let model: AutocompleteModel
    let onPick: (Suggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, s in
                        Button { onPick(s) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: s.systemImage).frame(width: 18).foregroundStyle(Theme.muted)
                                Text(s.title).font(.system(size: 13, design: s.systemImage == "doc" || s.systemImage == "folder" ? .monospaced : .default))
                                    .lineLimit(1)
                                Text(s.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(i == model.index ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.index) { _, i in proxy.scrollTo(i) }
        }
        .compatibleGlassEffect(in: RoundedRectangle(cornerRadius: 16))
    }
}
