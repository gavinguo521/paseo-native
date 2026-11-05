import SwiftUI

/// Keep the existing Liquid Glass appearance on newer systems, with standard surfaces on iOS 18.
extension View {
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
    /// `topHidden`：内容不满一屏时传 true。贴底显示的短会话上方是一大片空白，软边缘会从工具栏一直铺到内容顶上，
    /// 鼠标经过工具栏时整块变亮（用户报告「新会话上面一截悬停变色」）；那时也没有内容会滚到工具栏下面，关掉即可。
    func compatibleScrollEdgeEffects(topHidden: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(topHidden, for: .top)
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
