import SwiftUI

/// Keep the existing Liquid Glass appearance on newer systems, with standard surfaces on iOS 18.
extension View {
    /// 自绘按钮的标签要占有真实触控区域，不能只扩大外层容器。
    @ViewBuilder
    func mobileTouchTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }

    /// 空状态中的主要操作在触屏上使用完整尺寸，避免继承系统的紧凑按钮尺寸。
    @ViewBuilder
    func mobileProminentControlSize() -> some View {
        #if os(iOS)
        controlSize(.large)
        #else
        self
        #endif
    }

    @ViewBuilder
    func compatibleGlassEffect<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(Theme.surface1, in: shape)
                .overlay {
                    shape.strokeBorder(Theme.border, lineWidth: 0.5).allowsHitTesting(false)
                }
        }
    }

    @ViewBuilder
    func compatibleGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            } else {
                buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }

    /// iOS 18 uses its standard scroll edges; scrolling, anchors and keyboard behavior stay intact.
    @ViewBuilder
    func compatibleScrollEdgeEffects() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }
}

#if os(iOS)
extension View {
    /// iOS 18 has no soft scroll edge, so content scrolling under the bar shows through the title, back button and
    /// status bar: give it an opaque bar there. iOS 26+ keeps the floating design — `hiddenOnNewer` hides the bar
    /// background (workspace pages), otherwise the system default is left alone.
    @ViewBuilder
    func compatibleNavigationBarBackground(hiddenOnNewer: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if hiddenOnNewer { toolbarBackgroundVisibility(.hidden, for: .navigationBar) } else { self }
        } else {
            toolbarBackground(Theme.surface0, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        }
    }
}
#endif

/// Glass containers only coordinate visual effects; older systems can use the same content directly.
struct CompatibleGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func compatibleSharedBackgroundHidden() -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
