import SwiftUI

struct TimelineFollowGeometry: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var viewport: CGFloat
    var bottomInset: CGFloat = 0

    var nearBottom: Bool { height + bottomInset - offset - viewport < 32 }

    func following(after old: Self, wasFollowing: Bool, userDriven: Bool) -> Bool {
        // 内容增高不是离开底部的用户意图；只有实际向上移动才取消跟随。
        guard userDriven else { return wasFollowing }
        if nearBottom { return true }
        if offset < old.offset { return false }
        return wasFollowing
    }

    init(offset: CGFloat, height: CGFloat, viewport: CGFloat, bottomInset: CGFloat = 0) {
        self.offset = offset; self.height = height; self.viewport = viewport
        self.bottomInset = bottomInset
    }

    init(_ geometry: ScrollGeometry) {
        self.init(offset: geometry.contentOffset.y, height: geometry.contentSize.height,
                  viewport: geometry.containerSize.height, bottomInset: geometry.contentInsets.bottom)
    }
}

/// 跟随意图独立于瞬时底部距离，避免内容重排抢先关闭 sizeChanges 的底部锚点。
struct TimelineBottomFollow: ViewModifier {
    @Binding var following: Bool
    @Binding var position: ScrollPosition
    var enabled: Bool
    @State private var phase: ScrollPhase = .idle
    @State private var selectingText = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ReplySelectionPreference.self) { selected in
                selectingText = selected
                if selected { following = false }
            }
            .defaultScrollAnchor(following && enabled && !selectingText ? .bottom : .top, for: .sizeChanges)
            .onScrollGeometryChange(for: TimelineFollowGeometry.self) { TimelineFollowGeometry($0) } action: { old, new in
                guard enabled, !selectingText else { return }
                // isPositionedByUser 兼容没有连续滚动 phase 的滚轮/键盘移动。
                let userDriven = phase == .interacting || phase == .decelerating ||
                    (position.isPositionedByUser && old.height == new.height && old.viewport == new.viewport)
                following = new.following(after: old, wasFollowing: following, userDriven: userDriven)
                if following, phase == .idle, !new.nearBottom,
                   old.height != new.height || old.viewport != new.viewport {
                    position.scrollTo(edge: .bottom)
                }
            }
            .onScrollPhaseChange { _, next, context in
                phase = next
                if enabled, !selectingText, following, next == .idle, !TimelineFollowGeometry(context.geometry).nearBottom {
                    position.scrollTo(edge: .bottom)
                }
            }
    }
}
