import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一张可导出的图片：时间线只解码缩略图，存储、拷贝、拖出时才按需取原始字节。
struct ImageSource: Sendable {
    /// 建议文件名（可带路径或 URL，只取最后一段的主名）。
    let name: String
    let load: @Sendable () async -> Data?
    /// 已有字节时直接知道格式，拖出不必等 `load`。
    var type: UTType?

    init(name: String, load: @escaping @Sendable () async -> Data?) {
        self.name = name
        self.load = load
    }

    init(name: String, data: Data) {
        self.init(name: name) { data }
        type = ImageExport.type(of: data)
    }
}

enum ImageExport {
    static func type(of data: Data) -> UTType {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let id = CGImageSourceGetType(src) as String?, let type = UTType(id) else { return .png }
        return type
    }

    /// 取提示里最后一段的主名，扩展名按实际图片格式；没有可用名字时用时间戳。
    static func fileName(_ hint: String, type: UTType) -> String {
        var base = hint
        if let url = URL(string: hint), url.scheme != nil, !url.lastPathComponent.isEmpty { base = url.lastPathComponent }
        base = (base as NSString).lastPathComponent
        base = base.removingPercentEncoding ?? base
        var stem = (base as NSString).deletingPathExtension
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty || stem == "/" || stem == "Image" || stem == "图片" {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            stem = "图片-" + f.string(from: Date())
        }
        return stem + "." + (type.preferredFilenameExtension ?? "png")
    }

    /// 拖出时在临时目录写一份带文件名的副本；Finder / 文件 App 拷走后由系统清理临时目录。
    static func temporaryFile(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paseo-image-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 拖到桌面 / Finder 得到图片文件，拖到其他 App 或本 App 输入框得到图片数据。
    /// `type` 未知（字节还没读过）时先按 PNG 声明，实际内容仍是原图。
    static func itemProvider(_ source: ImageSource, type: UTType?) -> NSItemProvider {
        let type = type ?? source.type ?? .png
        let name = fileName(source.name, type: type)
        let provider = NSItemProvider()
        provider.suggestedName = (name as NSString).deletingPathExtension
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task {
                guard let data = await source.load() else { done(nil, false, CocoaError(.fileReadUnknown)); return }
                do { done(try temporaryFile(data, name: name), false, nil) } catch { done(nil, false, error) }
            }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
            Task {
                let data = await source.load()
                done(data, data == nil ? CocoaError(.fileReadUnknown) : nil)
            }
            return nil
        }
        return provider
    }

    @MainActor static func copy(_ source: ImageSource) async {
        guard let data = await source.load() else { return failed() }
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let image = NSImage(data: data) { pb.writeObjects([image]) }
        pb.setData(data, forType: NSPasteboard.PasteboardType(type(of: data).identifier))
        #else
        UIPasteboard.general.image = UIImage(data: data)
        #endif
    }

    /// Mac 弹出存储面板（记住上次的位置，第一次默认桌面）；手机 / iPad 弹分享菜单，可存到相册或「文件」。
    @MainActor static func save(_ source: ImageSource) async {
        guard let data = await source.load() else { return failed() }
        let name = fileName(source.name, type: type(of: data))
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if !UserDefaults.standard.bool(forKey: savedOnceKey) {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.set(true, forKey: savedOnceKey)
        } catch { failed() }
        #else
        guard let url = try? temporaryFile(data, name: name),
              let top = topViewController() else { return failed() }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
        #endif
    }

    #if os(macOS)
    private static let savedOnceKey = "imageExport.savedOnce"
    #endif

    @MainActor private static func failed() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    #if os(iOS)
    @MainActor private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif
}

extension View {
    /// 右键 / 长按菜单：存储、拷贝；同时允许把图片拖出去。
    func imageExport(_ source: ImageSource?, type: UTType? = nil) -> some View {
        modifier(ImageExportModifier(source: source, type: type))
    }
}

private struct ImageExportModifier: ViewModifier {
    let source: ImageSource?
    let type: UTType?

    func body(content: Content) -> some View {
        if let source {
            content
                .onDrag { ImageExport.itemProvider(source, type: type) }
                .contextMenu {
                    Button { Task { await ImageExport.save(source) } } label: {
                        #if os(macOS)
                        Label("存储图片…", systemImage: "square.and.arrow.down")
                        #else
                        Label("存储或分享图片…", systemImage: "square.and.arrow.up")
                        #endif
                    }
                    Button { Task { await ImageExport.copy(source) } } label: {
                        Label("拷贝图片", systemImage: "doc.on.doc")
                    }
                }
        } else {
            content
        }
    }
}

/// 灯箱标题栏里的存储按钮。
struct ImageSaveButton: View {
    let source: ImageSource

    var body: some View {
        Button { Task { await ImageExport.save(source) } } label: {
            #if os(macOS)
            Image(systemName: "square.and.arrow.down")
            #else
            Image(systemName: "square.and.arrow.up")
            #endif
        }
        .keyboardShortcut("s", modifiers: .command)
        .help("存储图片（⌘S），也可以直接把图片拖出去")
        .accessibilityLabel("存储图片")
    }
}
