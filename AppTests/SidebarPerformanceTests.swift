import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct SidebarPerformanceTests {
    @Test func reportLargeSidebarCost() throws {
        for count in [30, 60, 100] {
            let model = try SidebarTestFixture.model(projects: count)
            let clock = ContinuousClock()
            var groups: [SessionGroup] = []
            let grouping = clock.measure { for _ in 0..<10 { groups = model.groups } }
            #expect(groups.count == count)
            SidebarBench.groupCount = 0
            SidebarBench.rowCount = 0
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = NSHostingView(rootView: SidebarView(showSettings: .constant(false), showAddHost: .constant(false))
                .environment(model).environment(\.colorScheme, .light).background(Color.white))
            view.sizingOptions = []
            let layout = clock.measure {
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 300, height: 800)
                view.layoutSubtreeIfNeeded()
            }
            #expect(SidebarBench.rowCount > 0)
            #expect(SidebarBench.rowCount < count * 8)
            print("SIDEBAR projects=\(count) grouping10=\(grouping) initialLayout=\(layout) groupsBuilt=\(SidebarBench.groupCount) rowsBuilt=\(SidebarBench.rowCount)")
            if count == 100 {
                func scrollViews(_ v: NSView) -> [NSScrollView] {
                    (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews)
                }
                let scroll = try #require(scrollViews(view).first { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height })
                let initialRows = SidebarBench.rowCount
                var steps = 0
                let scrolling = clock.measure {
                    while steps < 150 {
                        let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                        let y = min(bottom, scroll.contentView.bounds.minY + 400)
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        view.layoutSubtreeIfNeeded()
                        if y >= bottom { break }
                        steps += 1
                    }
                }
                #expect(steps < 150)
                #expect(SidebarBench.rowCount > initialRows)
                #expect(scroll.contentView.bounds.minY > 0)
                print("SIDEBAR scroll100 steps=\(steps + 1) layoutWork=\(scrolling) rowsBuilt=\(SidebarBench.rowCount)")
                // 回到顶部后取原生视图截图，不依赖 ImageRenderer 对 ScrollView 的支持。
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-sidebar-1536.png")
                try png.write(to: path)
                print("SIDEBAR screenshot=\(path.path)")
            }
        }
    }

    @Test func filteredWorkspaceKeepsStatusOfHiddenSessionsAndNestedChildren() throws {
        let model = try SidebarTestFixture.model(projects: 2)
        let host = try #require(model.hosts.first)
        let visible = try #require(Agent(["id": "visible", "workspaceId": "shared", "cwd": "/test/shared", "title": "查找目标", "status": "idle"]))
        let other = try #require(Agent(["id": "other", "workspaceId": "shared", "cwd": "/test/shared", "title": "不匹配", "status": "running"]))
        host.agents[visible.id] = visible
        host.agents[other.id] = other
        model.search = "查找目标"
        #expect(model.groups.count == 1)
        #expect(model.groups[0].rows.count == 1)
        #expect(model.groups[0].rows[0].agent.id == "visible")
        #expect(model.groups[0].rows[0].bucket == .running)
        host.agents[other.id] = nil
        let child = try #require(Agent(["id": "child", "title": "不匹配", "status": "running", "labels": ["paseo.parent-agent-id": "visible"]]))
        host.agents[child.id] = child
        #expect(model.groups[0].rows[0].bucket == .running)
        host.agents[child.id] = nil
        #expect(model.groups[0].rows[0].bucket == .done)
        model.search = ""
        #expect(model.groups.count == 3)
        model.grouping = .status
        #expect(model.groups.count == 1)
        #expect(model.groups[0].rows.count == 17)
    }

    @Test func projectIconDecodesOnlyAtDisplaySize() async throws {
        let context = try #require(CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try #require(context.makeImage())
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, source, nil)
        #expect(CGImageDestinationFinalize(output))
        let image = try #require(await ProjectIconDecoder.shared.decode(data as Data, maxPixel: 32))
        #expect(image.width == 32 && image.height == 16)
    }
}
