// Official design tokens (vendor/paseo/packages/app/src/styles/theme.ts). See docs/ui/01-official-layout.md §6.

import PaseoKit
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#endif

extension Color {
    init(light: UInt32, dark: UInt32) {
        func make(_ hex: UInt32) -> PlatformColor {
            PlatformColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                          blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light) })
        #else
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? make(dark) : make(light) })
        #endif
    }
}

enum Theme {
    static let surface0 = Color(light: 0xffffff, dark: 0x181B1A)
    static let surface1 = Color(light: 0xfafafa, dark: 0x1E2120)
    static let surface2 = Color(light: 0xf4f4f5, dark: 0x272A29)
    static let surface3 = Color(light: 0xe4e4e7, dark: 0x434645)
    static let surfaceSidebar = Color(light: 0xf4f4f5, dark: 0x141716)
    /// Selected row in the sidebar: must read against the translucent sidebar in both modes.
    static let selection = Color(light: 0xdedee3, dark: 0x343938)
    static let foreground = Color(light: 0x1a1a1e, dark: 0xfafafa)
    static let muted = Color(light: 0x71717a, dark: 0xA1A5A4)
    static let extraMuted = Color(light: 0xa1a1aa, dark: 0x717574)
    static let border = Color(light: 0xe4e4e7, dark: 0x252B2A)
    static let borderAccent = Color(light: 0xececf1, dark: 0x2F3534)
    static let accent = Color(light: 0x20744A, dark: 0x20744A)
    static let accentBright = Color(light: 0x239956, dark: 0x7ccba0)
    static let destructive = Color(light: 0xb04138, dark: 0xc64f43)

    static let dotSuccess = Color(light: 0x299f51, dark: 0x35c264)
    static let dotDanger = Color(light: 0xf12e2f, dark: 0xf7796d)
    static let dotWarning = Color(light: 0xb37824, dark: 0xdb932e)
    static let dotRunning = Color(light: 0x268ae0, dark: 0x5caaf6)

    static let diffAdd = Color(light: 0x15803d, dark: 0x4ade80)
    static let diffRemove = Color(light: 0xb91c1c, dark: 0xef4444)

    /// Font size step from settings (-1 small … +2 largest); views refresh via RootView's `.id`.
    private static var fontStep: CGFloat { CGFloat(UserDefaults.standard.integer(forKey: "fontStep")) }
    // Official defaults (app/src/hooks/use-settings/storage.ts): desktop UI 14 / content 15, native 15 / 16.
    #if os(macOS)
    static var base: CGFloat { 14 + fontStep }
    static var content: CGFloat { 15 + fontStep }
    #else
    static var base: CGFloat { 15 + fontStep }
    static var content: CGFloat { 16 + fontStep }
    #endif
    static var code: CGFloat { 12 + fontStep }
    /// Chat column width from settings (0 = full width).
    static var chatMaxWidth: CGFloat {
        let w = UserDefaults.standard.integer(forKey: "contentWidth")
        return w == 0 ? (UserDefaults.standard.object(forKey: "contentWidth") == nil ? 820 : .infinity) : CGFloat(w)
    }
}

/// Leading status indicator: amber alert for needs_input, red/blue/green dots, nothing when done.
struct StatusDot: View {
    let bucket: StatusBucket

    var body: some View {
        Group {
            switch bucket {
            case .needsInput:
                Circle().fill(Theme.dotWarning).frame(width: 6, height: 6)
            case .failed:
                Circle().fill(Theme.dotDanger).frame(width: 6, height: 6)
            case .running:
                RunningRing()
            case .attention:
                Circle().fill(Theme.dotSuccess).frame(width: 6, height: 6)
            case .done:
                Color.clear.frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(accessibilityText)
        .accessibilityHidden(bucket == .done)
    }

    private var accessibilityText: String {
        switch bucket {
        case .needsInput: String(localized: "需要输入")
        case .failed: String(localized: "失败")
        case .running: String(localized: "运行中")
        case .attention: String(localized: "待查看")
        case .done: String(localized: "已完成")
        }
    }
}

/// Running: a blue ring with a gap, turning (about one turn a second). Core Animation turns it: a
/// `TimelineView(.animation)` re-ran the window's SwiftUI graph every frame while any session was running,
/// which kept the main thread busy and made the timeline drop frames when scrolled.
struct RunningRing: View {
    var size: CGFloat = 10
    @Environment(\.self) private var environment

    var body: some View {
        SpinningRing(color: Theme.dotRunning.resolve(in: environment).cgColor)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

#if os(macOS)
private struct SpinningRing: NSViewRepresentable {
    let color: CGColor
    func makeNSView(context: Context) -> SpinningRingView { SpinningRingView() }
    func updateNSView(_ view: SpinningRingView, context: Context) { view.color = color }
}
#else
private struct SpinningRing: UIViewRepresentable {
    let color: CGColor
    func makeUIView(context: Context) -> SpinningRingView { SpinningRingView() }
    func updateUIView(_ view: SpinningRingView, context: Context) { view.color = color }
}
#endif

private final class SpinningRingView: PlatformView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat = 1.6
    var color: CGColor = PlatformColor.systemBlue.cgColor {
        didSet {
            track.strokeColor = color.copy(alpha: 0.25)
            arc.strokeColor = color
        }
    }

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        let host = layer!
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let host = layer
        #endif
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = lineWidth
            l.lineCap = .round
            host.addSublayer(l)
        }
        arc.strokeEnd = 0.7
        color = PlatformColor.systemBlue.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); place() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); spin() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); place() }
    override func didMoveToWindow() { super.didMoveToWindow(); spin() }
    #endif

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        for l in [track, arc] {
            l.bounds = bounds
            l.position = CGPoint(x: bounds.midX, y: bounds.midY)
            l.path = path
        }
        CATransaction.commit()
    }

    private func spin() {
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        // Clockwise on screen; AppKit layers have y pointing up.
        #if os(macOS)
        a.toValue = -2 * Double.pi
        #else
        a.toValue = 2 * Double.pi
        #endif
        a.duration = 1
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        arc.add(a, forKey: "spin")
    }
}

struct HostStatusDot: View {
    let state: ConnectionState

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .accessibilityLabel(state.label)
    }

    private var color: Color {
        switch state {
        case .connected: Theme.dotSuccess
        case .connecting, .idle: Theme.dotWarning
        case .waiting, .failed: Theme.dotDanger
        }
    }
}

extension ConnectionState {
    var label: String {
        switch self {
        case .idle: String(localized: "未连接")
        case .connecting(let n): n == 0 ? String(localized: "连接中…") : String(localized: "重连中（第 \(n + 1) 次）…")
        case .connected: String(localized: "在线")
        case .waiting(let m, _): String(localized: "离线：\(m)")
        case .failed(let m, let needsPassword): needsPassword ? String(localized: "需要密码") : String(localized: "连接失败：\(m)")
        }
    }
}

extension View {
    /// Haptics on iPhone/iPad only (on a Mac it would buzz the trackpad under the cursor).
    @ViewBuilder func phoneFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        #if os(iOS)
        sensoryFeedback(feedback, trigger: trigger)
        #else
        self
        #endif
    }

    @ViewBuilder func phoneFeedback<T: Equatable>(trigger: T, _ feedback: @escaping (T, T) -> SensoryFeedback?) -> some View {
        #if os(iOS)
        sensoryFeedback(trigger: trigger, feedback)
        #else
        self
        #endif
    }

    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }

    /// Sizes meant for a Mac window or popover. On iPhone / iPad the sheet decides the size; a fixed
    /// 640-wide frame there gets laid out wider than the screen and cut off on both sides.
    @ViewBuilder func macOnly<T: View>(_ transform: (Self) -> T) -> some View {
        #if os(macOS)
        transform(self)
        #else
        self
        #endif
    }

    /// A Mac popover with a search list: on iPhone it becomes a sheet anyway, so make it a proper
    /// half-height one (Mac size only on the Mac).
    func pickerSheet(width: CGFloat, height: CGFloat) -> some View {
        macOnly { $0.frame(width: width, height: height) }
            .presentationDetents([.medium, .large])
    }

    /// Small info popovers stay popovers on iPhone instead of a mostly empty full-height sheet.
    func compactPopover() -> some View {
        presentationCompactAdaptation(.popover)
    }
}

/// Workspace label colors (packages/protocol/src/workspace-labels.ts names).
func labelColor(_ name: String) -> Color {
    switch name {
    case "violet": .purple
    case "sky": .cyan
    case "emerald": .green
    case "orange": .orange
    case "pink": .pink
    case "indigo": .indigo
    case "teal": .teal
    case "red": .red
    case "amber": .yellow
    default: .blue
    }
}


/// Bottom-docked bars (composer, sidebar footer). iOS: sit like the system tab bar — reaching into the
/// home-indicator inset, ~20pt above the screen edge — rather than above the whole inset plus a margin, which
/// left ~45pt of empty space under them. With the keyboard up, a small gap above the keyboard instead.
/// Mac: `macGap` above the window edge.
struct BottomBarPlacement: ViewModifier {
    var macGap: CGFloat = 14
    #if os(iOS)
    @State private var keyboardUp = false
    /// Home-indicator inset of the window (0 on Touch ID iPhones and with no window yet).
    private var homeInset: CGFloat {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return (windows.first { $0.isKeyWindow } ?? windows.first)?.safeAreaInsets.bottom ?? 0
    }
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            // The parent already stops at the inset, and ignoresSafeArea on a bar inside it does not reach past
            // that; a negative padding of (20 − inset) does.
            .padding(.bottom, keyboardUp ? 6 : (homeInset > 0 ? 20 - homeInset : 8))
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        #else
        content.padding(.bottom, macGap)
        #endif
    }
}

extension View {
    func bottomBarPlacement(macGap: CGFloat = 14) -> some View { modifier(BottomBarPlacement(macGap: macGap)) }
}


extension HostStore {
    /// "23 ms" (round trip to the daemon), nil while not connected or not measured yet.
    var latencyText: String? { latencyMs.map { "\($0) ms" } }
}

/// Latency after a machine's name: green under 100 ms, orange under 300, red above.
struct LatencyBadge: View {
    let host: HostStore
    var size: CGFloat = 11

    var body: some View {
        if let ms = host.latencyMs {
            Text("\(ms) ms")
                .font(.system(size: size).monospacedDigit())
                .foregroundStyle(ms < 100 ? Theme.dotSuccess : ms < 300 ? Theme.dotWarning : Theme.destructive)
                .help("到这台机器的往返延迟")
        }
    }
}
