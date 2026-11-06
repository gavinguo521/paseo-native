import SwiftUI
import CoreText

/// 与原预览保持相同的行数上限和行号文本；后台准备，原生文本系统按视口布局。
struct FileSourceDocument: Sendable {
    let id = UUID()
    let lines: [String]
    let text: String
    let ranges: [NSRange]
    let bodies: [NSRange]
    let width: CGFloat
    let fontName: String
    let fontSize: CGFloat

    init(_ source: String, fontName: String = "Menlo", fontSize: CGFloat = 12) throws {
        self.fontName = fontName; self.fontSize = fontSize
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var measuredWidth: CGFloat = 0
        lines = source.split(separator: "\n", omittingEmptySubsequences: false).prefix(20000).map(String.init)
        let width = String(lines.count).count
        var text = ""
        var ranges: [NSRange] = []
        var bodies: [NSRange] = []
        var offset = 0
        for (i, line) in lines.enumerated() {
            try Task.checkCancellation()
            let prefix = String(repeating: " ", count: width - String(i + 1).count) + "\(i + 1)  "
            let length = prefix.utf16.count + line.utf16.count
            ranges.append(NSRange(location: offset, length: length))
            bodies.append(NSRange(location: offset + prefix.utf16.count, length: line.utf16.count))
            #if os(iOS)
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: prefix + line, attributes: [.font: font]))
            measuredWidth = max(measuredWidth, CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)))
            #endif
            text += prefix + line
            if i + 1 < lines.count { text += "\n" }
            offset += length + 1
        }
        self.text = text; self.ranges = ranges; self.bodies = bodies
        self.width = ceil(measuredWidth) + 40
    }
    func lineIndex(at offset: Int) -> Int {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if ranges[mid].location <= offset { lower = mid + 1 } else { upper = mid }
        }
        return max(0, lower - 1)
    }

}

actor FileSourceHighlighter {
    private let lines: [String]
    private let language: SyntaxHighlight.Language?
    private var values: [AttributedString] = []
    private var inBlock = false

    init(lines: [String], language: String) {
        self.lines = lines
        self.language = SyntaxHighlight.language(for: language)
    }

    func through(_ end: Int) throws -> [AttributedString] {
        let limit = min(end, lines.count, 5000)
        while values.count < limit {
            try Task.checkCancellation()
            let line = lines[values.count]
            values.append(language.map { SyntaxHighlight.line(line, $0, inBlock: &inBlock) } ?? AttributedString(line))
        }
        try Task.checkCancellation()
        return values
    }
}

struct FileSourceView: View {
    let text: String
    let language: String
    var target: Int?
    @State private var document: FileSourceDocument?

    var body: some View {
        Group {
            if let document {
                NativeFileSource(document: document, language: language, target: target)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: text) {
            document = nil
            #if os(macOS)
            let fontName = NSFont.monospacedSystemFont(ofSize: Theme.code, weight: .regular).fontName
            #else
            let fontName = UIFont.monospacedSystemFont(ofSize: Theme.code, weight: .regular).fontName
            #endif
            let fontSize = Theme.code
            let task = Task.detached(priority: .userInitiated) { try FileSourceDocument(text, fontName: fontName, fontSize: fontSize) }
            let result = await withTaskCancellationHandler {
                try? await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            document = result
        }
    }
}

#if os(macOS)
import AppKit
typealias SourceTextView = NSTextView
#else
import UIKit
typealias SourceTextView = UITextView
#endif

/// 原生连续文本选择不因按需高亮而拆成逐行选择；着色只修改属性，不替换文本或选区。
@MainActor final class FileSourceCoordinator: NSObject {
    weak var view: SourceTextView?
    var document: FileSourceDocument?
    var language = ""
    var worker: FileSourceHighlighter?
    var task: Task<Void, Never>?
    private var visibleTask: Task<Void, Never>?
    var requested = 0
    var applied = 0
    var target: Int?
    private var numberedRange = 0..<0
    var observer: NSObjectProtocol?

    func stop() {
        task?.cancel()
        visibleTask?.cancel()
        visibleTask = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func update(_ document: FileSourceDocument, language: String, target: Int?) {
        guard let view else { return }
        if self.document?.id != document.id || self.language != language {
            task?.cancel()
            self.document = document; self.language = language
            worker = FileSourceHighlighter(lines: document.lines, language: language)
            requested = 0; applied = 0; self.target = nil; numberedRange = 0..<0
            #if os(macOS)
            view.string = document.text
            view.font = .init(name: document.fontName, size: document.fontSize)
            view.textColor = PlatformColor(Theme.foreground)
            #else
            view.text = document.text
            view.font = .init(name: document.fontName, size: document.fontSize)
            view.textColor = PlatformColor(Theme.foreground)
            #endif
        }
        let storage: NSTextStorage? = view.textStorage
        if self.target != target {
            if let old = self.target, document.ranges.indices.contains(old - 1) {
                storage?.removeAttribute(.backgroundColor, range: document.ranges[old - 1])
            }
            self.target = target
            if let target, document.ranges.indices.contains(target - 1) {
                let range = document.ranges[target - 1]
                storage?.addAttribute(.backgroundColor, value: PlatformColor(Theme.dotWarning).withAlphaComponent(0.2), range: range)
                #if os(macOS)
                view.scrollRangeToVisible(range)
                #else
                // 远距离定位需要真实纵坐标；仅布局目标片段会使 UITextView 按估算位置复位偏移。
                view.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
                let glyphs = view.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
                    .offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
                view.layoutIfNeeded()
                let y = max(0, min(rect.midY - view.bounds.height / 2,
                                   view.contentSize.height - view.bounds.height))
                view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                #endif
            }
        }
        requestVisible()
    }

    func requestVisible() {
        // 滚动回调可能发生在 TextKit 布局中；退出本次回调后再修改属性，避免重入布局。
        guard visibleTask == nil else { return }
        visibleTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.visibleTask = nil
            self.updateVisible()
        }
    }

    private func updateVisible() {
        guard let view, let document, let worker else { return }
        let manager: NSLayoutManager? = view.layoutManager
        let container: NSTextContainer? = view.textContainer
        guard let manager, let container else { return }
        #if os(macOS)
        let rect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        #else
        let rect = view.bounds.offsetBy(dx: -view.textContainerInset.left, dy: -view.textContainerInset.top)
        #endif
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let firstVisible = document.lineIndex(at: characters.location)
        let lastVisible = min(document.lines.count, document.lineIndex(at: NSMaxRange(characters)) + 81)
        let visibleNumbers = max(0, firstVisible - 20)..<lastVisible
        if visibleNumbers != numberedRange {
            numberedRange = visibleNumbers
            let storage: NSTextStorage? = view.textStorage
            storage?.beginEditing()
            for index in visibleNumbers {
                let row = document.ranges[index], body = document.bodies[index]
                storage?.addAttribute(.foregroundColor, value: PlatformColor(Theme.extraMuted), range: NSRange(location: row.location, length: body.location - row.location))
            }
            storage?.endEditing()
        }
        let end = min(5000, document.lines.count, max(160, lastVisible, (target ?? 0) + 80))
        guard end > requested else { return }
        requested = end
        task?.cancel()
        task = Task { [weak self] in
            guard let values = try? await worker.through(end), !Task.isCancelled,
                  let self, self.document?.id == document.id, let view = self.view else { return }
            let storage: NSTextStorage? = view.textStorage
            // 每批最多 128 行，远距离跳转也不把整份高亮一次性发布到主线程。
            while self.applied < values.count {
                guard !Task.isCancelled, self.document?.id == document.id else { return }
                let end = min(self.applied + 128, values.count)
                storage?.beginEditing()
                for index in self.applied..<end {
                    let body = document.bodies[index]
                    let value = values[index]
                    for run in value.runs {
                        guard let color = run.foregroundColor else { continue }
                        let prefix = String(value.characters[..<run.range.lowerBound]).utf16.count
                        let length = String(value.characters[run.range]).utf16.count
                        storage?.addAttribute(.foregroundColor, value: PlatformColor(color), range: NSRange(location: body.location + prefix, length: length))
                    }
                }
                storage?.endEditing()
                self.applied = end
                await Task.yield()
            }
        }
    }
}

#if os(macOS)
struct NativeFileSource: NSViewRepresentable {
    let document: FileSourceDocument
    let language: String
    let target: Int?
    func makeCoordinator() -> FileSourceCoordinator { FileSourceCoordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true
        text.drawsBackground = false; text.isRichText = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 14, height: 10)
        text.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = text
        context.coordinator.view = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.requestVisible() }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(document, language: language, target: target)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: FileSourceCoordinator) { coordinator.stop() }
}
#else
extension FileSourceCoordinator: UITextViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { requestVisible() }
}
final class FileSourceScrollView: UIScrollView {
    let source = UITextView(usingTextLayoutManager: false)
    var sourceWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: max(bounds.width, sourceWidth), height: bounds.height)
        if source.frame.size != size { source.frame = CGRect(origin: .zero, size: size) }
        if contentSize != size { contentSize = size }
    }
}

struct NativeFileSource: UIViewRepresentable {
    let document: FileSourceDocument
    let language: String
    let target: Int?
    func makeCoordinator() -> FileSourceCoordinator { FileSourceCoordinator() }
    func makeUIView(context: Context) -> FileSourceScrollView {
        // 外层只负责横向，UITextView 保留原生纵向滚动、连续选择和放大镜。
        let scroll = FileSourceScrollView()
        scroll.isDirectionalLockEnabled = true
        let view = scroll.source
        view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear
        view.isDirectionalLockEnabled = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        view.layoutManager.allowsNonContiguousLayout = true
        view.delegate = context.coordinator
        scroll.addSubview(view)
        context.coordinator.view = view
        return scroll
    }
    func updateUIView(_ scroll: FileSourceScrollView, context: Context) {
        scroll.sourceWidth = document.width
        if target != nil, context.coordinator.target != target {
            scroll.setContentOffset(.zero, animated: false)
        }
        scroll.setNeedsLayout()
        scroll.layoutIfNeeded()
        context.coordinator.update(document, language: language, target: target)
    }
    static func dismantleUIView(_ view: FileSourceScrollView, coordinator: FileSourceCoordinator) { coordinator.stop() }
}
#endif
