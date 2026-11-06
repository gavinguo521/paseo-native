import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo
#if os(macOS)
import AppKit
private typealias PreviewNativeView = NSView
#else
import UIKit
private typealias PreviewNativeView = UIView
#endif

@MainActor private final class PreviewLayoutState: ObservableObject {
    @Published var lineCount = 1
    @Published var expanded = true
    let kind: String
    init(kind: String) { self.kind = kind }

    var row: TimelineRow {
        let lines = (1...lineCount).map { "Line \($0): preview content" }.joined(separator: "\n")
        let detail: ToolCallDetail = kind == "diff"
            ? .edit(filePath: "Sample.swift", oldString: nil, newString: nil,
                    unifiedDiff: lines.split(separator: "\n").map { "+" + $0 }.joined(separator: "\n"))
            : .shell(command: "test-command", cwd: nil, output: lines, exitCode: 0)
        return TimelineRow(id: "tool-preview", turnId: nil, timestamp: nil,
                           item: .toolCall(callId: "preview", name: "shell", status: "completed",
                                           detail: detail, error: nil, agentMessage: nil),
                           isStreaming: false, isPending: false)
    }
}

@MainActor private final class PreviewLayoutProbe {
    var height: CGFloat = -1
    var nextMessageY: CGFloat = -1
}

@MainActor private struct PreviewLayoutFixture: View {
    @ObservedObject var state: PreviewLayoutState
    let probe: PreviewLayoutProbe

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    if state.expanded { ToolDetailView(row: state.row, showHeader: true) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.height = $0 }
                Text("Following message stays below the preview")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("preview-stack")).minY } action: { probe.nextMessageY = $0 }
            }
            .coordinateSpace(name: "preview-stack")
            .padding(12)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black)
    }
}

@Suite(.serialized) @MainActor struct ToolPreviewLayoutTests {
    @Test(arguments: ["shell", "diff"])
    func shortContentShrinksAndLongContentScrolls(kind: String) async throws {
        #if os(macOS)
        let widths: [CGFloat] = [390, 960]
        #else
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let widths = [scene.screen.bounds.width]
        #endif
        for width in widths {
            let state = PreviewLayoutState(kind: kind)
            let probe = PreviewLayoutProbe()
            let root = PreviewLayoutFixture(state: state, probe: probe)
            #if os(macOS)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 620),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            #else
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            let view = host.view!
            #endif

            for count in [1, 120, 1] {
                state.lineCount = count
                try await settle(view) { count == 1 ? (probe.height > 0 && probe.height < 120) : abs(probe.height - 400) < 1 }
                #expect(probe.height > 0)
                #expect(count == 1 ? probe.height < 120 : abs(probe.height - 400) < 1)
                #expect(abs(probe.nextMessageY - probe.height - 12) < 1)
                print("TOOL_PREVIEW kind=\(kind) width=\(width) lines=\(count) height=\(probe.height)")
                if count > 1 {
                    try verifyInternalScroll(in: view)
                }
            }
            state.expanded = false
            try await settle(view) { probe.height == 0 }
            #expect(probe.height == 0)
            state.expanded = true
            try await settle(view) { probe.height > 0 && probe.height < 120 }
            #expect(probe.height > 0 && probe.height < 120)
        }
    }

    private func settle(_ view: PreviewNativeView, until ready: () -> Bool) async throws {
        for _ in 0..<50 {
            #if os(macOS)
            view.layoutSubtreeIfNeeded()
            #else
            view.layoutIfNeeded()
            #endif
            await Task.yield()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func descendants(_ view: PreviewNativeView) -> [PreviewNativeView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func verifyInternalScroll(in view: PreviewNativeView) throws {
        #if os(macOS)
        let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first {
            $0.contentView.bounds.height <= 401 && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 100
        })
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 0)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #else
        let scroll = try #require(descendants(view).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.height <= 401 && $0.contentSize.height > $0.bounds.height + 100
        })
        #expect(scroll.isScrollEnabled)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        #expect(scroll.contentOffset.y > 0)
        scroll.setContentOffset(.zero, animated: false)
        #endif
    }
}
