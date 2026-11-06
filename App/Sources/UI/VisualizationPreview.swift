import SwiftUI
import WebKit

struct VisualizationReference: Equatable {
    let path: String
    let wide: Bool
    let marker: String

    init?(marker: String) {
        let prefix = "visualize", suffix = ""
        guard marker.hasPrefix(prefix), marker.hasSuffix(suffix),
              let data = String(marker.dropFirst(prefix.count).dropLast(suffix.count)).data(using: .utf8),
              let value = try? JSONDecoder().decode(Payload.self, from: data),
              !value.path.isEmpty, !value.path.contains("://"),
              !value.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["html", "htm"].contains((value.path as NSString).pathExtension.lowercased()) else { return nil }
        path = value.path
        wide = value.mode == "wide"
        self.marker = marker
    }

    private struct Payload: Decodable { let path: String; let mode: String? }
}

struct VisualizationPreview: View {
    let reference: VisualizationReference
    @Environment(\.hostFileReader) private var reader
    @State private var controller: VisualizationWebController?
    @State private var loadFailed = false
    @State private var retry = 0
    @State private var loadedKey: String?

    private var title: String { (reference.path as NSString).lastPathComponent }
    private var loadKey: String { (reader?.cacheScope ?? "") + "|" + reference.path + "|\(retry)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "rectangle.on.rectangle").font(.caption).lineLimit(1)
                Spacer()
                Button("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right") { controller?.expanded = true }
                    .disabled(controller == nil || controller?.failed == true)
            }
            .buttonStyle(.borderless).padding(12)
            Divider()
            Group {
                if loadFailed || controller?.failed == true {
                    VStack(spacing: 12) {
                        Text("无法加载预览，请确认文件仍在会话主机上且连接正常。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("重试") { retry += 1 }
                    }.padding()
                } else if let controller {
                    if controller.expanded { Color.clear }
                    else { VisualizationWeb(controller: controller, fullScreen: false) }
                } else {
                    ProgressView("正在加载预览…")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: reference.wide ? 480 : 360)
        }
        .frame(maxWidth: reference.wide ? .infinity : 640)
        .background(Theme.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .task(id: loadKey) {
            // fullScreenCover 返回会重新触发 .task；同一文件保留页面交互状态。
            guard loadedKey != loadKey || controller == nil else { return }
            controller = nil
            loadFailed = false
            guard let reader, let data = await reader.read(reference.path),
                  data.count <= 20 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else {
                if !Task.isCancelled { loadFailed = true }
                return
            }
            guard !Task.isCancelled else { return }
            controller = VisualizationWebController(html: html)
            loadedKey = loadKey
        }
        #if os(iOS)
        .fullScreenCover(isPresented: expanded) { expandedPreview }
        #else
        .sheet(isPresented: expanded) { expandedPreview.frame(minWidth: 760, minHeight: 600) }
        #endif
    }

    private var expanded: Binding<Bool> {
        Binding(get: { controller?.expanded ?? false }, set: { controller?.expanded = $0 })
    }

    private var expandedPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Button("返回会话", systemImage: "chevron.left") { controller?.expanded = false }
                Spacer()
                Text(title).font(.headline).lineLimit(1)
            }.padding()
            Divider()
            if let controller { VisualizationWeb(controller: controller, fullScreen: true) }
        }
        .background(Theme.surface1)
    }
}

/// HTML 只在不共享 Cookie 的隔离页面内执行；不向页面暴露主机文件读取或 App 桥接。
@MainActor @Observable final class VisualizationWebController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var failed = false
    var expanded = false

    init(html: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.document(html), baseURL: nil)
    }

    static func document(_ html: String) -> String {
        // srcdoc 使用不带 allow-same-origin 的 sandbox，页面脚本不能触及外层文档。
        // CSP 随 srcdoc 继承，禁止联网、表单提交及读取相对/本地资源。
        let inner = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>:root{color-scheme:light dark}body{margin:0}</style>" + html
        let escaped = inner.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; frame-src about:; connect-src 'none'; base-uri 'none'; form-action 'none'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;color-scheme:light dark}iframe{display:block;border:0;width:100%;height:100%}</style>
        </head><body><iframe title="HTML preview" sandbox="allow-scripts" srcdoc="\(escaped)"></iframe></body></html>
        """
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 包括自定义 scheme、file URL、新窗口和页面脚本发起的跳转，均不能离开预览。
        let url = navigationAction.request.url
        let allowed = url?.scheme == "about" && ["blank", "srcdoc"].contains(url?.path ?? "")
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }
}

// 放大/返回时移动同一个 WebView，保留表单、按钮和滚动状态。
#if os(macOS)
private struct VisualizationWeb: NSViewRepresentable {
    let controller: VisualizationWebController
    let fullScreen: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let web = controller.webView
        guard controller.expanded == fullScreen, web.superview !== container else { return }
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
    }
}
#else
private struct VisualizationWeb: UIViewRepresentable {
    let controller: VisualizationWebController
    let fullScreen: Bool
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ container: UIView, context: Context) {
        let web = controller.webView
        guard controller.expanded == fullScreen, web.superview !== container else { return }
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
    }
}
#endif
