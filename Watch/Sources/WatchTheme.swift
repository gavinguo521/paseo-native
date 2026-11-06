import SwiftUI
import PaseoWatchBridge

enum WatchTheme {
    static let accent = Color(red: 32.0 / 255, green: 116.0 / 255, blue: 74.0 / 255)
    static let surface = Color(white: 0.12)
    static let controlRadius: CGFloat = 14
    static let controlHeight: CGFloat = 44

    static func color(_ status: WatchSessionStatus) -> Color {
        switch status { case .waiting: .orange; case .failed: .red; case .running: accent; case .attention: .blue; case .done: .secondary }
    }
    static func label(_ status: WatchSessionStatus) -> String {
        switch status {
        case .waiting: String(localized: "等待处理")
        case .failed: String(localized: "出错")
        case .running: String(localized: "运行中")
        case .attention: String(localized: "待查看")
        case .done: String(localized: "已完成")
        }
    }
    static func scheduleLabel(_ status: String) -> String {
        switch status {
        case "active": String(localized: "进行中")
        case "paused": String(localized: "已暂停")
        case "completed", "success", "succeeded": String(localized: "已完成")
        case "running": String(localized: "运行中")
        case "error", "failed": String(localized: "失败")
        case "expired": String(localized: "已过期")
        default: status
        }
    }
}

extension View {
    @ViewBuilder func watchActionStyle(prominent: Bool = false) -> some View {
        if #available(watchOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(WatchTheme.accent)
                    .buttonBorderShape(.roundedRectangle(radius: WatchTheme.controlRadius)).frame(maxWidth: .infinity)
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: WatchTheme.controlRadius)).frame(maxWidth: .infinity)
            }
        } else {
            self.buttonStyle(WatchControlStyle(prominent: prominent)).frame(maxWidth: .infinity)
        }
    }
    func watchCard(padding: CGFloat = 8) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder func watchControlPreviewStyle() -> some View {
        let content = self
            .font(.body.weight(.medium)).foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: WatchTheme.controlHeight, alignment: .center)
        let shape = RoundedRectangle(cornerRadius: WatchTheme.controlRadius)
        if #available(watchOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(WatchTheme.surface, in: shape)
        }
    }
}

private struct WatchControlStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: WatchTheme.controlHeight, alignment: .center)
            .background(prominent ? WatchTheme.accent : WatchTheme.surface,
                        in: RoundedRectangle(cornerRadius: WatchTheme.controlRadius))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: WatchTheme.controlRadius))
    }
}

struct WatchFreshness: View {
    var date: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Group {
                if let date {
                    if context.date.timeIntervalSince(date) < 60 { Text("刚刚刷新") }
                    else { Text(String(localized: "\(date.formatted(.relative(presentation: .numeric)))刷新")) }
                } else { Text("尚未刷新") }
            }
            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}

struct WatchProblem: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}
