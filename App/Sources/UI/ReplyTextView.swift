import PaseoKit
import SwiftUI

#if os(macOS)
import AppKit
private typealias ReplyFont = NSFont
#else
import UIKit
private typealias ReplyFont = UIFont
#endif

/// 每个连续文字区只有一个原生文本容器；媒体保留原有独立交互。
struct ReplyTextSection: Identifiable {
    let id: Int
    var blocks: [MarkdownBlock]
    var isText: Bool

    static func split(_ blocks: [MarkdownBlock]) -> [Self] {
        var result: [Self] = []
        for (index, block) in blocks.enumerated() {
            let isText: Bool
            switch block {
            case .heading, .paragraph, .list, .quote, .rule: isText = true
            case .code(let language, _): isText = language?.lowercased() != "mermaid"
            default: isText = false
            }
            if isText, result.last?.isText == true { result[result.count - 1].blocks.append(block) }
            else { result.append(Self(id: index, blocks: [block], isText: isText)) }
        }
        return result
    }
}

struct ReplySelectionPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct ReplyTextView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.findQuery) private var query
    @Environment(\.self) private var environment
    @Environment(\.openURL) private var openURL
    @Environment(\.openWebLinkInApp) private var openInApp
    @State private var cache = ReplyDocumentCache()
    @State private var selecting = false

    var body: some View {
        NativeReplyText(document: cache.document(blocks, query: query, environment: environment),
                        openLink: { openURL($0) }, openInApp: openInApp, selectionChanged: { selecting = $0 })
            .preference(key: ReplySelectionPreference.self, value: selecting)
    }
}

struct ReplyDocument {
    struct Code {
        var range: NSRange
        let text: String
    }
    let text: NSAttributedString
    var codes: [Code] = []
}

/// 复用已闭合块和代码着色；不因新 token 重新解析整条回复的行内 Markdown。
@MainActor final class ReplyDocumentCache {
    private var pieces: [String: NSAttributedString] = [:]
    private var codeCaches: [Int: CodeHighlightCache] = [:]
    private var appearance: String = ""

    func document(_ blocks: [MarkdownBlock], query: String, environment: EnvironmentValues) -> ReplyDocument {
        let appearance = "\(environment.colorScheme)-\(Theme.content)-\(query)"
        if appearance != self.appearance { pieces = [:]; self.appearance = appearance }
        let result = NSMutableAttributedString(string: "")
        var codes: [ReplyDocument.Code] = []
        var used = Set<String>()
        var usedCodes = Set<Int>()
        func color(_ value: Color) -> PlatformColor {
            #if os(macOS)
            NSColor(cgColor: value.resolve(in: environment).cgColor) ?? .labelColor
            #else
            UIColor(cgColor: value.resolve(in: environment).cgColor)
            #endif
        }
        func append(_ source: String, size: CGFloat = Theme.content, bold: Bool = false,
                    indent: CGFloat = 0, first: CGFloat? = nil, muted: Bool = false, literal: Bool = false,
                    code: AttributedString? = nil) {
            let key = "\(size)|\(bold)|\(indent)|\(first ?? indent)|\(muted)|\(literal)|\(source)"
            used.insert(key)
            if code == nil, let cached = pieces[key] { result.append(cached); return }
            var parsed = code ?? (literal ? AttributedString(source) : InlineMarkdown.parse(source))
            if !literal { FileLink.annotate(&parsed) }
            highlight(&parsed, query)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = MarkdownView.lineSpacing
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = first ?? indent
            paragraph.tailIndent = indent > 0 ? -10 : 0
            paragraph.lineBreakMode = .byWordWrapping
            let text = NSMutableAttributedString(string: "")
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let mono = literal || intent.contains(.code)
                var font = mono ? ReplyFont.monospacedSystemFont(ofSize: literal ? Theme.code : size, weight: .regular)
                    : ReplyFont.systemFont(ofSize: size, weight: bold || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
                if intent.contains(.emphasized) {
                    #if os(macOS)
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    #else
                    if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
                    #endif
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: color(run.foregroundColor ?? (muted ? Theme.muted : Theme.foreground)),
                    .paragraphStyle: paragraph
                ]
                if let background = run.backgroundColor { attributes[.backgroundColor] = color(background) }
                else if intent.contains(.code) { attributes[.backgroundColor] = color(Theme.surface2) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = color(Theme.accentBright)
                }
                text.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            if code == nil { pieces[key] = text }
            result.append(text)
        }
        for (index, block) in blocks.enumerated() {
            // 分隔符不占文字行，跨段复制时也不混入装饰字符。
            if case .rule = block { continue }
            if result.length > 0 { append("\n\n") }
            switch block {
            case .heading(let level, let text): append(text, size: Theme.content + CGFloat(max(0, 4 - level)) * 1.5, bold: true)
            case .paragraph(let text): append(text)
            case .quote(let text): append(text, indent: 10, muted: true)
            case .list(let items):
                for (i, item) in items.enumerated() {
                    if i > 0 { append("\n") }
                    let offset = CGFloat(item.indent) * 14
                    append(item.marker + "  " + item.text, indent: offset + 20, first: offset)
                }
            case .code(let language, let code):
                let start = result.length
                // 标题行给复制按钮留出位置；代码在阅读列内换行，不引入嵌套滚动。
                append((language ?? "") + "\n", size: 11, indent: 10, muted: true)
                usedCodes.insert(index)
                var cache = codeCaches[index] ?? CodeHighlightCache()
                let highlighted = cache.highlight(code, language: language ?? "")
                codeCaches[index] = cache
                append(code, indent: 10, literal: true, code: highlighted)
                codes.append(.init(range: NSRange(location: start, length: result.length - start), text: code))
            default: break
            }
        }
        pieces = pieces.filter { used.contains($0.key) }
        codeCaches = codeCaches.filter { usedCodes.contains($0.key) }
        return ReplyDocument(text: result, codes: codes)
    }
}

/// 选中期间暂存最新内容，避免未闭合 Markdown 或服务端定稿改变选区对应的文字。
@MainActor final class ReplyTextCoordinator: NSObject {
    var openLink: (URL) -> Void = { _ in }
    var selectionChanged: (Bool) -> Void = { _ in }
    var pending: ReplyDocument?
    var applying = false
    var selecting = false
    weak var view: ReplyNativeTextView?
    private var appliedText: NSAttributedString?

    func update(_ document: ReplyDocument) {
        guard let view else { return }
        if view.replySelectedRange.length > 0 { pending = document; return }
        pending = nil
        // TextKit 会整理字体属性，不能用处理后的 storage 判断原始文档是否变化。
        guard appliedText?.isEqual(to: document.text) != true else { return }
        appliedText = document.text.copy() as? NSAttributedString
        applying = true
        view.replyStorage.setAttributedString(document.text)
        view.replySelectedRange = NSRange(location: 0, length: 0)
        view.codes = document.codes
        view.invalidateReplyLayout()
        applying = false
    }

    func changed() {
        guard !applying, let view else { return }
        let active = view.replySelectedRange.length > 0
        if active != selecting {
            selecting = active
            // 不在 Representable 更新/拆卸的布局回调里同步修改 SwiftUI 状态。
            let callback = selectionChanged
            Task { @MainActor in callback(active) }
        }
        if !active, let pending { update(pending) }
    }
}

#if os(macOS)
struct NativeReplyText: NSViewRepresentable {
    let document: ReplyDocument
    let openLink: (URL) -> Void
    let openInApp: ((URL) -> Void)?
    let selectionChanged: (Bool) -> Void
    func makeCoordinator() -> ReplyTextCoordinator { ReplyTextCoordinator() }
    func makeNSView(context: Context) -> ReplyTextHostView {
        ReplyTextHostView(coordinator: context.coordinator)
    }
    func updateNSView(_ host: ReplyTextHostView, context: Context) {
        context.coordinator.openLink = openLink
        context.coordinator.selectionChanged = selectionChanged
        host.openInApp = openInApp
        host.update(document)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: ReplyTextHostView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return host.replySize(for: width)
    }
}

/// 创建只读 NSTextView 会同步激活当前输入法并运行嵌套 RunLoop。
/// 必须等 SwiftUI 的 make/update/layout 事务返回后再创建，避免重入布局图。
final class ReplyTextHostView: NSView {
    let coordinator: ReplyTextCoordinator
    private var document: ReplyDocument?
    private var measurement: ReplyTextMeasurement? = ReplyTextMeasurement()
    var openInApp: ((URL) -> Void)? { didSet { coordinator.view?.openInApp = openInApp } }

    init(coordinator: ReplyTextCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        DispatchQueue.main.async { [weak self] in self?.installTextView() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func installTextView() {
        let view = ReplyNativeTextView(frame: bounds)
        view.isEditable = false; view.isSelectable = true
        view.drawsBackground = false
        view.linkTextAttributes = [:]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width, .height]
        view.openInApp = openInApp
        view.delegate = coordinator
        coordinator.view = view
        addSubview(view)
        if let document { coordinator.update(document) }
        measurement = nil
    }

    func update(_ document: ReplyDocument) {
        self.document = document
        coordinator.update(document)
    }

    func replySize(for width: CGFloat) -> CGSize {
        // 首次排版不依赖 NSTextView；选中文字时仍按正在显示的旧文档测量。
        if let view = coordinator.view { return view.replySize(for: width) }
        guard let document else { return CGSize(width: width, height: 0) }
        return measurement!.size(document.text, width: width)
    }
}

@MainActor private final class ReplyTextMeasurement {
    private var sourceText: NSAttributedString?
    private var measuredSizes: [CGFloat: CGSize] = [:]
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
    }
    func size(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        // 测量用的 TextKit 也会整理字体属性，保存输入副本以免误判为新正文。
        if sourceText?.isEqual(to: text) != true {
            sourceText = text.copy() as? NSAttributedString
            measuredSizes.removeAll(keepingCapacity: true)
            storage.setAttributedString(text)
        }
        if let size = measuredSizes[width] { return size }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
        // 保留少量候选宽度，兼顾 SwiftUI 的交替测量和连续调整窗口大小。
        if measuredSizes.count >= 4 { measuredSizes.removeAll(keepingCapacity: true) }
        measuredSizes[width] = size
        return size
    }
}

extension ReplyTextCoordinator: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) { changed() }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { openLink(url); return true }
        return false
    }
}

final class ReplyNativeTextView: NSTextView {
    // 测量不能修改正在显示的容器：SwiftUI 会探测并放弃不同的候选宽度。
    private let measurement = ReplyTextMeasurement()

    func replySize(for width: CGFloat) -> CGSize {
        measurement.size(replyStorage, width: width)
    }
    var openInApp: ((URL) -> Void)?
    private var menuURL: URL?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index < replyStorage.length,
              let url = replyStorage.attribute(.link, at: index, effectiveRange: nil) as? URL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return menu }
        menuURL = url
        menu.addItem(.separator())
        let inside = NSMenuItem(title: String(localized: "应用内打开"), action: #selector(openMenuLinkInApp), keyEquivalent: "")
        inside.target = self
        if openInApp != nil { menu.addItem(inside) }
        let outside = NSMenuItem(title: String(localized: "默认浏览器打开"), action: #selector(openMenuLinkExternally), keyEquivalent: "")
        outside.target = self; menu.addItem(outside)
        let copy = NSMenuItem(title: String(localized: "复制链接"), action: #selector(copyMenuLink), keyEquivalent: "")
        copy.target = self; menu.addItem(copy)
        return menu
    }
    @objc private func openMenuLinkInApp() { if let menuURL { openInApp?(menuURL) } }
    @objc private func openMenuLinkExternally() { if let menuURL { NSWorkspace.shared.open(menuURL) } }
    @objc private func copyMenuLink() { if let menuURL { Pasteboard.copy(menuURL.absoluteString) } }
    var replyStorage: NSTextStorage { textStorage! }
    var replySelectedRange: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }
    var codes: [ReplyDocument.Code] = [] { didSet { rebuildButtons() } }
    private var copyButtons: [NSButton] = []
    func invalidateReplyLayout() { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true }
    private func rebuildButtons() {
        copyButtons.forEach { $0.removeFromSuperview() }
        copyButtons = codes.indices.map { index in
            let button = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: String(localized: "复制代码"))!, target: self, action: #selector(copyCode(_:)))
            button.tag = index; button.isBordered = false; button.toolTip = String(localized: "复制代码")
            addSubview(button)
            return button
        }
    }
    @objc private func copyCode(_ sender: NSButton) { Pasteboard.copy(codes[sender.tag].text) }
    override func layout() {
        super.layout()
        for (index, rect) in codeRects.enumerated() { copyButtons[index].frame = CGRect(x: max(0, bounds.width - 30), y: rect.minY, width: 26, height: 22) }
    }
    private var codeRects: [CGRect] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        return codes.map {
            let glyphs = layout.glyphRange(forCharacterRange: $0.range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.surface2).setFill()
        for rect in codeRects { NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill() }
        super.draw(dirtyRect)
    }
}
#else
struct NativeReplyText: UIViewRepresentable {
    let document: ReplyDocument
    let openLink: (URL) -> Void
    let openInApp: ((URL) -> Void)?
    let selectionChanged: (Bool) -> Void
    func makeCoordinator() -> ReplyTextCoordinator { ReplyTextCoordinator() }
    func makeUIView(context: Context) -> ReplyNativeTextView {
        let view = ReplyNativeTextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.linkTextAttributes = [:]
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: ReplyNativeTextView, context: Context) {
        context.coordinator.openLink = openLink
        view.openInApp = openInApp
        context.coordinator.selectionChanged = selectionChanged
        context.coordinator.update(document)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ReplyNativeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return view.replySize(for: width)
    }
}

extension ReplyTextCoordinator: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !applying { (textView as? ReplyNativeTextView)?.revealMovingSelection() }
        changed()
    }
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in self?.openLink(url) }
    }
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        guard case .link(let url) = textItem.content,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let openInApp = (textView as? ReplyNativeTextView)?.openInApp else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
        let action = UIAction(title: String(localized: "应用内打开"), image: UIImage(systemName: "globe")) { _ in openInApp(url) }
        return UITextItem.MenuConfiguration(menu: UIMenu(children: [action] + defaultMenu.children))
    }
}

final class ReplyNativeTextView: UITextView {
    var openInApp: ((URL) -> Void)?
    // UIKit 的 usingTextLayoutManager 工厂初始化器不能用于带存储属性的 Swift 子类。
    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }
    var replyStorage: NSTextStorage { textStorage }
    var replySelectedRange: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { selectedRange = NSRange(location: 0, length: 0) }
        return resigned
    }
    private var previousSelection = NSRange(location: 0, length: 0)
    /// 文字自身不滚动；拖动选区端点到可视区外时滚动外层会话。
    func revealMovingSelection() {
        let old = previousSelection
        previousSelection = selectedRange
        guard isFirstResponder, selectedRange.length > 0 else { return }
        let offset = old.length > 0 && old.location != selectedRange.location ? selectedRange.location : NSMaxRange(selectedRange)
        guard let position = position(from: beginningOfDocument, offset: offset) else { return }
        var parent = superview
        while let candidate = parent {
            if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled {
                let rect = convert(caretRect(for: position), to: scroll).insetBy(dx: 0, dy: -18)
                scroll.scrollRectToVisible(rect, animated: false)
                return
            }
            parent = candidate.superview
        }
    }
    var codes: [ReplyDocument.Code] = [] { didSet { rebuildButtons() } }
    private var copyButtons: [UIButton] = []
    private var codeBackgrounds: [UIView] = []
    // SwiftUI 会重复试探尺寸；避免每次让 UITextView 临时改容器宽度并重新排版。
    private var measuredSizes: [CGFloat: CGSize] = [:]
    func replySize(for width: CGFloat) -> CGSize {
        if let size = measuredSizes[width] { return size }
        let size = CGSize(width: width, height: ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        if measuredSizes.count >= 4 { measuredSizes.removeAll(keepingCapacity: true) }
        measuredSizes[width] = size
        return size
    }
    func invalidateReplyLayout() {
        measuredSizes.removeAll(keepingCapacity: true)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
    private func rebuildButtons() {
        copyButtons.forEach { $0.removeFromSuperview() }
        codeBackgrounds.forEach { $0.removeFromSuperview() }
        codeBackgrounds = codes.map { _ in
            let background = UIView()
            background.backgroundColor = UIColor(Theme.surface2)
            background.layer.cornerRadius = 8
            background.isUserInteractionEnabled = false
            insertSubview(background, at: 0)
            return background
        }
        copyButtons = codes.indices.map { index in
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11)), for: .normal)
            button.tintColor = UIColor(Theme.muted)
            button.accessibilityLabel = String(localized: "复制代码")
            let code = codes[index].text
            button.addAction(UIAction { _ in Pasteboard.copy(code) }, for: .touchUpInside)
            addSubview(button)
            return button
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, code) in codes.enumerated() {
            let glyphs = layoutManager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            codeBackgrounds[index].frame = CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height)
            copyButtons[index].frame = CGRect(x: max(0, bounds.width - 32), y: rect.minY, width: 30, height: 24)
        }
    }
}
#endif
