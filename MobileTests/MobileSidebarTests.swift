import UIKit
import SwiftUI
import Testing
@testable import Paseo

@Suite(.serialized) @MainActor struct MobileSidebarTests {
    @Test func largeSidebarRendersAndScrollsOnCurrentDevice() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let width = pad ? CGFloat(320) : scene.screen.bounds.width
        for count in [30, 60, 100] {
            let model = try SidebarTestFixture.model(projects: count)
            let clock = ContinuousClock()
            let grouping = clock.measure { for _ in 0..<10 { _ = model.groups } }
            #expect(model.groups.count == count)
            SidebarBench.groupCount = 0
            SidebarBench.rowCount = 0
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            defer { window.isHidden = true; window.rootViewController = nil }
            let content = NavigationStack {
                SidebarView(showSettings: .constant(false), showAddHost: .constant(false))
            }
            .frame(width: width).frame(maxWidth: .infinity, alignment: .leading)
            .environment(model).environment(\.colorScheme, .light).background(Color.white)
            let host = UIHostingController(rootView: content)
            let layout = clock.measure {
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
            }
            await Task.yield()
            host.view.layoutIfNeeded()
            #expect(SidebarBench.rowCount > 0)
            #expect(SidebarBench.rowCount < count * 8)
            print("MOBILE-SIDEBAR device=\(pad ? "iPad" : "iPhone") projects=\(count) width=\(width) grouping10=\(grouping) initialLayout=\(layout) groupsBuilt=\(SidebarBench.groupCount) rowsBuilt=\(SidebarBench.rowCount)")

            func scrollViews(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let scroll = try #require(scrollViews(host.view).first { $0.contentSize.height > $0.bounds.height })
            #expect(scroll.bounds.width <= width + 1)
            if count == 100 {
                let initialRows = SidebarBench.rowCount
                var steps = 0
                let start = clock.now
                while steps < 200 {
                    let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    let y = min(bottom, scroll.contentOffset.y + 400)
                    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    host.view.layoutIfNeeded()
                    await Task.yield()
                    if y >= bottom { break }
                    steps += 1
                }
                #expect(steps < 200)
                #expect(SidebarBench.rowCount > initialRows)
                #expect(scroll.contentOffset.y > 0)
                print("MOBILE-SIDEBAR scroll100 steps=\(steps + 1) elapsed=\(start.duration(to: clock.now)) rowsBuilt=\(SidebarBench.rowCount)")
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                host.view.layoutIfNeeded()
                await Task.yield()
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { context in
                    host.view.layer.render(in: context.cgContext)
                }
                let png = try #require(image.pngData())
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-\(pad ? "ipad" : "iphone")-1538.png")
                try png.write(to: url)
                print("MOBILE-SIDEBAR screenshot=\(url.path)")
            }
        }
    }
}
