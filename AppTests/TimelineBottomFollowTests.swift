import AppKit
import SwiftUI
import Testing
@testable import Paseo

@Suite(.serialized) @MainActor struct TimelineBottomFollowTests {
    @Test func contentGrowthDoesNotCancelFollowButUserReadingDoes() {
        let bottom = TimelineFollowGeometry(offset: 600, height: 1000, viewport: 400)
        let grown = TimelineFollowGeometry(offset: 600, height: 1600, viewport: 400)
        // 旧算法会在这一帧误判离底；新策略保持跟随。
        #expect(!grown.nearBottom)
        #expect(grown.following(after: bottom, wasFollowing: true, userDriven: false))
        #expect(grown.following(after: bottom, wasFollowing: true, userDriven: true))
        let up = TimelineFollowGeometry(offset: 400, height: 1600, viewport: 400)
        #expect(!up.following(after: grown, wasFollowing: true, userDriven: true))
        #expect(!grown.following(after: up, wasFollowing: false, userDriven: false))
        let returned = TimelineFollowGeometry(offset: 1200, height: 1600, viewport: 400)
        #expect(returned.following(after: up, wasFollowing: false, userDriven: true))
        let again = TimelineFollowGeometry(offset: 1200, height: 2400, viewport: 400)
        #expect(again.following(after: returned, wasFollowing: true, userDriven: false))
        // 历史定位、窗口缩放不应自行改变跟随意图。
        #expect(!returned.following(after: up, wasFollowing: false, userDriven: false))
        let resized = TimelineFollowGeometry(offset: 1200, height: 1600, viewport: 250)
        #expect(resized.following(after: returned, wasFollowing: true, userDriven: false))
    }

    @Test func nativeScrollViewFollowsRepeatedLargeGrowth() async throws {
        let model = FollowFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: FollowFixtureView(model: model))
        view.sizingOptions = []
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        func settle(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat {
                view.layoutSubtreeIfNeeded()
                await Task.yield()
                if predicate() { return true }
            } while ContinuousClock.now < deadline
            return false
        }
        #expect(await settle { model.geometry?.nearBottom == true })
        for height: CGFloat in [1800, 2900, 4700] {
            model.height = height
            #expect(await settle { model.geometry?.height == height && model.geometry?.nearBottom == true })
            #expect(model.following)
        }
        func findScroll(_ node: NSView) -> NSScrollView? {
            if let scroll = node as? NSScrollView { return scroll }
            return node.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = try #require(findScroll(view))
        func wheel(_ delta: Int32) throws {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: cg))
            scroll.scrollWheel(with: event)
        }
        try wheel(250)
        #expect(await settle { !model.following && model.geometry?.nearBottom == false })
        let readingOffset = try #require(model.geometry?.offset)
        model.height = 5200
        #expect(await settle { model.geometry?.height == 5200 })
        #expect(!model.following)
        #expect(abs((model.geometry?.offset ?? -1000) - readingOffset) < 2)
        try wheel(-10000)
        #expect(await settle { model.following && model.geometry?.nearBottom == true })
        model.height = 5500
        #expect(await settle { model.geometry?.height == 5500 && model.geometry?.nearBottom == true })
        // 与搜索/历史定位相同：显式退出跟随后，继续流式增高不把位置拉回。
        model.following = false
        model.position.scrollTo(y: 300)
        #expect(await settle { abs((model.geometry?.offset ?? -1000) - 300) < 2 })
        model.height = 5800
        #expect(await settle { model.geometry?.height == 5800 })
        #expect(!model.following)
        #expect(abs((model.geometry?.offset ?? -1000) - 300) < 2)
        model.following = true
        model.position.scrollTo(edge: .bottom)
        #expect(await settle { model.geometry?.nearBottom == true })
        model.height = 7000
        #expect(await settle { model.geometry?.height == 7000 && model.geometry?.nearBottom == true })
        model.selectingText = true
        #expect(await settle { !model.following })
        let selectedOffset = try #require(model.geometry?.offset)
        model.height = 7600
        #expect(await settle { model.geometry?.height == 7600 })
        #expect(abs((model.geometry?.offset ?? -1000) - selectedOffset) < 2)
        model.selectingText = false
        model.height = 8000
        #expect(await settle { model.geometry?.height == 8000 })
        #expect(!model.following)
        #expect(abs((model.geometry?.offset ?? -1000) - selectedOffset) < 2)
    }
}

@Observable @MainActor private final class FollowFixture {
    var height: CGFloat = 1000
    var following = true
    var selectingText = false
    var position = ScrollPosition(edge: .bottom)
    var geometry: TimelineFollowGeometry?
}

private struct FollowFixtureView: View {
    @Bindable var model: FollowFixture
    var body: some View {
        ScrollView {
            Color.clear.frame(height: model.height)
                .preference(key: ReplySelectionPreference.self, value: model.selectingText)
        }
        .scrollPosition($model.position)
        .defaultScrollAnchor(.bottom)
        .modifier(TimelineBottomFollow(following: $model.following, position: $model.position, enabled: true))
        .onScrollGeometryChange(for: TimelineFollowGeometry.self) { TimelineFollowGeometry($0) } action: { _, value in
            model.geometry = value
        }
    }
}
