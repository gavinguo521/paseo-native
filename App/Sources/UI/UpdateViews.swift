// Mac 版在线更新的界面：发现新版本的提示弹窗，以及「设置 → 关于」里的检查更新（见 UpdateChecker）。

#if os(macOS)
import SwiftUI

/// 挂在主窗口上：自动检查或菜单「检查更新…」发现新版本时弹窗；手动检查已是最新 / 失败时也提示一下。
struct UpdatePromptModifier: ViewModifier {
    @State private var updates = UpdateChecker.shared

    func body(content: Content) -> some View {
        content
            .alert(updates.prompt.map { String(localized: "Paseo Native \($0.version) 可以更新了") } ?? "",
                   isPresented: Binding(get: { updates.prompt != nil }, set: { if !$0 { updates.prompt = nil } }),
                   presenting: updates.prompt) { release in
                Button("下载新版本") { updates.download(release) }
                Button("跳过这个版本") { updates.skip(release) }
                Button("以后再说", role: .cancel) { updates.prompt = nil }
            } message: { release in
                Text(Self.message(release, current: updates.currentVersion))
            }
            .alert(updates.notice ?? "", isPresented: Binding(get: { updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("好") { updates.notice = nil }
            }
    }

    static func message(_ r: UpdateChecker.Release, current: String) -> String {
        var notes = r.notes
        // 发布说明里中英各一份时只取中文部分（「---」之前），太长截断
        if let cut = notes.range(of: "\n---") { notes = String(notes[..<cut.lowerBound]) }
        notes = notes.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if notes.count > 500 { notes = String(notes.prefix(500)) + "…" }
        let tail = String(localized: "你现在用的是 \(current)。下载 dmg 后打开，把 Paseo Native 拖进「应用程序」替换旧版即可，设置和机器列表都会保留。")
        return notes.isEmpty ? tail : notes + "\n\n" + tail
    }
}

/// 「设置 → 关于」里的几行：检查更新按钮和结果、自动检查开关。
struct UpdateSettingsRows: View {
    @State private var updates = UpdateChecker.shared
    @State private var auto = UpdateChecker.shared.autoCheck

    var body: some View {
        if updates.isEnabled {
            HStack {
                Button("检查更新") { Task { await updates.check(manual: true, alert: false) } }
                    .disabled(updates.status == .checking)
                switch updates.status {
                case .checking: ProgressView().controlSize(.small)
                case .upToDate: Text("已是最新版本").foregroundStyle(Theme.muted)
                case .failed(let e): Text("检查失败：\(e)").foregroundStyle(Theme.destructive).lineLimit(2)
                case .available(let r):
                    Text("发现新版本 \(r.version)").foregroundStyle(Theme.accent)
                    Spacer()
                    Button("查看说明") { NSWorkspace.shared.open(r.page) }
                    Button("下载") { updates.download(r) }.buttonStyle(.borderedProminent)
                case .idle: EmptyView()
                }
            }
            Toggle("自动检查更新", isOn: $auto)
                .onChange(of: auto) { _, on in updates.autoCheck = on }
        }
    }
}
#endif
