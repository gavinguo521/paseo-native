// Menu bar extra: what needs you and what is running, without bringing the main window up.

#if os(macOS)
import AppKit
import PaseoKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = MenuBarSessions(model: model).waiting.count
        HStack(spacing: 3) {
            Image(systemName: n > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill" : "bubble.left.and.bubble.right")
            if n > 0 { Text("\(n)") }
        }
        .accessibilityLabel(n > 0 ? "Paseo，\(n) 个会话等你处理" : "Paseo")
    }
}

/// Top-level sessions of the visible hosts, split the way the sidebar dots are.
struct MenuBarSessions {
    struct Row: Identifiable {
        let ref: AgentRef
        let agent: Agent
        let project: String
        let host: String
        var id: AgentRef { ref }
    }

    let waiting: [Row]
    let running: [Row]

    @MainActor init(model: AppModel) {
        var waiting: [Row] = [], running: [Row] = []
        let multiHost = model.hosts.count > 1
        for h in model.hosts {
            for a in h.agents.values where a.archivedAt == nil && !h.isNested(a) {
                let row = Row(ref: AgentRef(serverId: h.id, agentId: a.id), agent: a,
                              project: model.projectName(of: a, in: h), host: multiHost ? h.label : "")
                switch a.bucket {
                case .needsInput, .failed, .attention: waiting.append(row)
                case .running: running.append(row)
                case .done: break
                }
            }
        }
        let recent: (Row, Row) -> Bool = { ($0.agent.updatedAt ?? .distantPast) > ($1.agent.updatedAt ?? .distantPast) }
        self.waiting = waiting.sorted { $0.agent.bucket != $1.agent.bucket ? $0.agent.bucket < $1.agent.bucket : recent($0, $1) }
        self.running = running.sorted(by: recent)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sessions = MenuBarSessions(model: model)
        VStack(alignment: .leading, spacing: 0) {
            if sessions.waiting.isEmpty && sessions.running.isEmpty {
                Text(model.hosts.isEmpty ? "还没有添加机器" : "没有在跑或等你处理的会话")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
            section("等你处理", sessions.waiting)
            section("运行中", sessions.running)
            Divider().padding(.vertical, 4)
            HStack {
                Button("打开 Paseo") { showMain() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .padding(.vertical, 6)
        .frame(width: 340)
    }

    @ViewBuilder private func section(_ title: String, _ rows: [MenuBarSessions.Row]) -> some View {
        if !rows.isEmpty {
            Text("\(title) · \(rows.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            ForEach(rows.prefix(12)) { row in
                MenuBarRow(row: row, detail: detail(row)) { open(row.ref) }
            }
            if rows.count > 12 {
                Text("还有 \(rows.count - 12) 个").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 2)
            }
        }
    }

    private func detail(_ row: MenuBarSessions.Row) -> String {
        var parts = [row.project]
        if !row.host.isEmpty { parts.append(row.host) }
        switch row.agent.bucket {
        case .needsInput: parts.append("需要你批准或回答")
        case .failed: parts.append("出错了")
        case .attention: parts.append("已完成，未查看")
        case .running:
            if let quiet = row.agent.quietMinutes() { parts.append("\(quiet) 分钟没有动静") }
        case .done: break
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ ref: AgentRef) {
        model.open(ref)
        showMain()
    }

    /// Bring the existing main window forward; open one only if it was closed.
    private func showMain() {
        dismiss()
        if !MainWindow.bringForward() { openWindow(id: PaseoApp.mainWindowId) }
    }
}

enum MainWindow {
    /// Activates the app and fronts the main window; false if there is none.
    @MainActor @discardableResult static func bringForward() -> Bool {
        NSApp.activate()
        guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(PaseoApp.mainWindowId) == true }) else { return false }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Right-click on the Dock icon: the same lists as the menu bar panel.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { Self.debugModel = model } }
    static var debugModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SelectionAutoCopy.install()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let sessions = MenuBarSessions(model: model)
        let menu = NSMenu()
        for (title, rows) in [("等你处理", sessions.waiting), ("运行中", sessions.running)] where !rows.isEmpty {
            menu.addItem(.sectionHeader(title: title))
            for row in rows.prefix(10) {
                let item = NSMenuItem(title: row.agent.displayTitle, action: #selector(openSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = row.ref
                item.subtitle = row.project
                menu.addItem(item)
            }
        }
        return menu
    }

    #if DEBUG
    static func dumpDockMenu(to path: String) async {
        // PASEO_DUMP_DELAY=<seconds>: wait longer, to see whether running sessions keep updating.
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["PASEO_DUMP_DELAY"] ?? "") ?? 6))
        let menu = NSApp.delegate?.applicationDockMenu?(NSApp)
        var lines: [String] = menu?.items.map { item in
            item.isSectionHeader ? "## " + item.title : "- " + item.title + " · " + (item.subtitle ?? "")
        } ?? ["(no menu)"]
        if let model = (NSApp.delegate as? AppDelegate)?.model ?? Self.debugModel {
            for row in MenuBarSessions(model: model).running {
                lines.append("age \(row.agent.displayTitle): \(Int(Date().timeIntervalSince(row.agent.updatedAt ?? .distantPast)))s")
            }
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(0)
    }
    #endif

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? AgentRef else { return }
        model?.open(ref)
        MainWindow.bringForward()
    }
}

private struct MenuBarRow: View {
    let row: MenuBarSessions.Row
    let detail: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StatusDot(bucket: row.agent.bucket).frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.agent.displayTitle).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hover = $0 }
    }
}
#endif
