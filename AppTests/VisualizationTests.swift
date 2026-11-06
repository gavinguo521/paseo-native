import SwiftUI
import WebKit
import Testing
@testable import Paseo
@testable import PaseoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct VisualizationTests {
    private let marker = "visualize{\"path\":\"/output/workbench.html\",\"mode\":\"wide\"}"

    @Test func completeMarkerRendersButCodeExamplesAndPartialTokensRemainText() throws {
        let blocks = MarkdownBlock.parse("说明\n\n" + marker + "\n\n后续")
        #expect(blocks.count == 3)
        guard case .visualization(let reference) = blocks[1] else { Issue.record("没有识别预览标记"); return }
        #expect(reference.path == "/output/workbench.html")
        #expect(reference.wide)
        #expect(MarkdownBlock.plainText(marker) == reference.path)
        let code = MarkdownBlock.parse("```text\n" + marker + "\n```")
        guard case .code = code.first else { Issue.record("代码示例不能自动加载 HTML"); return }
        #expect(VisualizationReference(marker: String(marker.dropLast())) == nil)
        #expect(VisualizationReference(marker: "visualize{\"path\":\"/secret.txt\"}") == nil)
        #expect(VisualizationReference(marker: "visualize{\"path\":\"https://example.com/index.html\"}") == nil)
        let cache = MarkdownRenderCache()
        _ = cache.blocks(String(marker.dropLast()))
        guard case .visualization = cache.blocks(marker).first else { Issue.record("流式补齐后应显示预览"); return }
    }

    @Test func fileReturnSelectsOriginWithoutClosingOrArchiving() throws {
        let model = try SidebarTestFixture.model(projects: 1)
        let ws = WorkspaceRef(serverId: "sidebar-test", workspaceId: "p0-w0")
        model.select(.agent("p0-w0-s1"), in: ws)
        model.openFile("/output/workbench.html", line: nil, in: ws)
        let origin = try #require(model.returnTabForFile("/output/workbench.html", in: ws))
        #expect(origin == .agent("p0-w0-s1"))
        model.select(origin, in: ws)
        #expect(model.selectedTab(ws) == origin)
        #expect(model.tabs(ws).contains(.file("/output/workbench.html")))
        #expect(model.hosts.first?.agents["p0-w0-s1"]?.archivedAt == nil)
        model.select(.agent("p0-w0-s0"), in: ws)
        model.openFile("/output/workbench.html", line: nil, in: ws)
        #expect(model.returnTabForFile("/output/workbench.html", in: ws) == .agent("p0-w0-s0"))
        let host = try #require(model.hosts.first)
        host.agents["archived"] = try #require(Agent(["id": "archived", "workspaceId": "p0-w0", "status": "idle", "archivedAt": "2026-11-06T00:00:00Z"]))
        model.select(.agent("archived"), in: ws)
        model.openFile("/output/workbench.html", line: nil, in: ws)
        #expect(!model.tabs(ws).contains(.agent("archived")))
        let archivedOrigin = try #require(model.returnTabForFile("/output/workbench.html", in: ws))
        #expect(archivedOrigin == .agent("archived"))
        model.select(archivedOrigin, in: ws)
        #expect(model.selectedTab(ws) == .agent("archived"))
    }

    @Test func webPreviewRunsInteractionInsideSandbox() async throws {
        let html = """
        <button id="counter" onclick="this.textContent=Number(this.textContent)+1">0</button>
        <script>document.body.dataset.ran='yes'</script>
        """
        let controller = VisualizationWebController(html: html)
        try await loaded(controller.webView)
        let probe = WebProbe()
        let scripts = controller.webView.configuration.userContentController
        scripts.add(probe, name: "testProbe")
        scripts.addUserScript(WKUserScript(source: """
        if (location.href === 'about:srcdoc') {
          document.getElementById('counter').click();
          let isolated=false, storageBlocked=false;
          try { void parent.document.body; } catch { isolated=true; }
          try { localStorage.setItem('secret','x'); } catch { storageBlocked=true; }
          fetch('https://example.com/blocked').then(()=>false,()=>true).then(networkBlocked=>{
            window.webkit.messageHandlers.testProbe.postMessage({
              count:document.getElementById('counter').textContent, ran:document.body.dataset.ran,
              isolated, storageBlocked, networkBlocked
            });
          });
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.webView.loadHTMLString(VisualizationWebController.document(html), baseURL: nil)
        let result = await probe.result()
        #expect(result["count"]?.stringValue == "1")
        #expect(result["ran"]?.stringValue == "yes")
        #expect(result["isolated"]?.boolValue == true)
        #expect(result["storageBlocked"]?.boolValue == true)
        #expect(result["networkBlocked"]?.boolValue == true)
        #expect(!controller.webView.configuration.websiteDataStore.isPersistent)
        #expect(!controller.failed)
        scripts.removeScriptMessageHandler(forName: "testProbe")
    }

    @Test func previewAtPhoneAndDesktopWidths() async throws {
        let html: String
        if let sample = ProcessInfo.processInfo.environment["PASEO_VISUALIZE_SAMPLE"] {
            html = try String(contentsOfFile: sample, encoding: .utf8)
        } else {
            html = "<style>body{font:18px system-ui;padding:20px}button{padding:14px}</style><h2>交互预览</h2><button onclick=\"this.textContent='已点击'\">点我验证</button>"
        }
        let reference = try #require(VisualizationReference(marker: marker))
        let reader = HostFileReader(cacheScope: "visualization-test") { _ in Data(html.utf8) }
        #if os(macOS)
        let widths = [390, 960]
        #else
        let screen = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen)
        let widths = [Int(screen.bounds.width)]
        #endif
        for width in widths {
            let root = VisualizationPreview(reference: reference).environment(\.hostFileReader, reader)
                .padding(16).frame(maxHeight: .infinity, alignment: .top).environment(\.colorScheme, .light).background(.white)
            #if os(macOS)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            view.frame = window.contentView!.bounds
            view.layoutSubtreeIfNeeded()
            #else
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            let view = host.view!
            #endif
            // 以 WebKit 文档完成回调取证，避免按固定延时猜测加载完成。
            let web = try await findWeb(in: view)
            try await loaded(web)
            let probe = WebProbe()
            web.configuration.userContentController.add(probe, name: "testProbe")
            web.configuration.userContentController.addUserScript(WKUserScript(source: "if(location.href==='about:srcdoc')window.webkit.messageHandlers.testProbe.postMessage({ready:true});", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            web.loadHTMLString(VisualizationWebController.document(html), baseURL: nil)
            let result = await probe.result()
            #expect(result["ready"]?.boolValue == true)
            let image = try await web.takeSnapshot(configuration: nil)
            #if os(macOS)
            let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            #else
            let data = try #require(image.pngData())
            #endif
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("visualization-\(width).png")
            try data.write(to: url)
            print("VISUALIZATION_SCREENSHOT \(url.path)")
            #if os(macOS)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let shell = try #require(bitmap.representation(using: .png, properties: [:]))
            #else
            let shell = try #require(UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }.pngData())
            #endif
            let shellURL = FileManager.default.temporaryDirectory.appendingPathComponent("visualization-card-\(width).png")
            try shell.write(to: shellURL)
            print("VISUALIZATION_CARD_SCREENSHOT \(shellURL.path)")
            let preview = try #require(web.navigationDelegate as? VisualizationWebController)
            _ = try await web.evaluateJavaScript("window.previewContinuity = 42")
            let inlineContainer = try #require(web.superview)
            preview.expanded = true
            try await waitUntil { web.superview != nil && web.superview !== inlineContainer && web.window != nil }
            let fullContainer = try #require(web.superview)
            #if os(iOS)
            let fullController = try #require(host.presentedViewController)
            await finishTransition(fullController)
            let fullView = try #require(fullController.view)
            fullView.layoutIfNeeded()
            try await waitUntil { abs(web.bounds.width - fullView.bounds.width) < 1 && web.bounds.height > 600 }
            _ = try await web.takeSnapshot(configuration: nil)
            let fullImage = UIGraphicsImageRenderer(bounds: fullView.bounds).image { _ in
                fullView.drawHierarchy(in: fullView.bounds, afterScreenUpdates: true)
            }
            let fullURL = FileManager.default.temporaryDirectory.appendingPathComponent("visualization-fullscreen-\(width).png")
            try #require(fullImage.pngData()).write(to: fullURL)
            print("VISUALIZATION_FULLSCREEN_SCREENSHOT \(fullURL.path)")
            #endif
            preview.expanded = false
            try await waitUntil { web.superview != nil && web.superview !== fullContainer && web.window === window }
            #if os(iOS)
            await finishTransition(fullController)
            #endif
            #expect(try await findWeb(in: view) === web)
            #expect((try await web.evaluateJavaScript("window.previewContinuity")) as? Int == 42)
            web.configuration.userContentController.removeScriptMessageHandler(forName: "testProbe")
        }
    }

    #if os(macOS)
    private typealias PlatformView = NSView
    #else
    private typealias PlatformView = UIView
    #endif
    private func findWeb(in view: PlatformView) async throws -> WKWebView {
        func find(_ view: PlatformView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        // SwiftUI 的 .task 和布局均在主线程，逐轮让出执行直到视图挂载。
        for _ in 0..<1000 {
            if let web = find(view) { return web }
            await Task.yield()
        }
        throw NSError(domain: "VisualizationTests", code: 1)
    }

    private func loaded(_ web: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && document.querySelector('iframe') !== null")) as? Bool == true { return }
            await Task.yield()
        }
        throw NSError(domain: "VisualizationTests", code: 3)
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(ready(), "预览应在内嵌与全屏容器之间完成移动")
        if !ready() { throw NSError(domain: "VisualizationTests", code: 2) }
    }

    #if os(iOS)
    private func finishTransition(_ controller: UIViewController) async {
        guard let transition = controller.transitionCoordinator else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                continuation.resume()
            }
        }
    }
    #endif
}

@MainActor private final class WebProbe: NSObject, WKScriptMessageHandler {
    private var value: JSONValue?
    private var waiter: CheckedContinuation<JSONValue, Never>?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let data = try! JSONSerialization.data(withJSONObject: message.body)
        let value = try! JSONValue.parse(String(decoding: data, as: UTF8.self))
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }
    func result() async -> JSONValue {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}
