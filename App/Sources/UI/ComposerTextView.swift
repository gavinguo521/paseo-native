/// 输入框处理的方向、补全和模式切换键。
enum ComposerKey { case up, down, tab, shiftTab, escape }

#if os(iOS)
import PaseoKit
import SwiftUI
import UIKit

@MainActor
enum PhoneKeyboard {
    /// ComposerTextView's FocusState is a focus request, not its responder state.
    /// Explicit dismissal must reach the native text view instead.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The iPad / iPhone composer's text field: a UITextView, not SwiftUI's vertical TextField. On iPadOS that
/// TextField ends editing on every hardware-keyboard Return, whatever a key handler does with it: Return could
/// not commit the input method's text (the focus was lost instead), ⇧↩ could not add a line, and the focus was
/// gone after sending. Here keys reach us first, and Return is only taken while the input method is not
/// composing — otherwise it goes to the input method as in any system app.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let fontSize: CGFloat
    var minLines: CGFloat = 3
    var maxLines: CGFloat = 12
    /// Hardware Return (no ⇧, input method not composing); `command` = ⌘ held. True when handled (e.g. sent);
    /// false lets the text view type a newline.
    let onReturn: (_ command: Bool) -> Bool
    /// ↑ ↓ Tab ⇧Tab Esc from a hardware keyboard, input method not composing; true when handled.
    var onKey: ((ComposerKey) -> Bool)? = nil
    /// Pasted images (the pasteboard holds images and no text).
    var onPasteImages: (([ImageAttachment]) -> Void)? = nil
    var onLongText: ((String) -> Bool)? = nil
    var tablePaste: TablePasteRequest? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        // 长草稿需要完整、稳定的滚动范围；TextKit 2 的视口估算会在滚动时改变内容高度。
        // UIKit 的 usingTextLayoutManager 工厂入口不会初始化 Swift 子类的存储属性。
        // 显式提供 TextKit 1 文本容器，走子类正常的初始化路径。
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let v = ComposerUITextView(frame: .zero, textContainer: container)
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.textColor = .label
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.placeholderLabel.textColor = .placeholderText
        v.placeholderLabel.numberOfLines = 1
        v.addSubview(v.placeholderLabel)
        v.text = text
        return v
    }

    func updateUIView(_ v: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        let font = UIFont.systemFont(ofSize: fontSize)
        if v.font != font { v.font = font; v.placeholderLabel.font = font }
        // Never overwrite while the input method holds text: that would throw the composition away.
        if v.markedTextRange == nil, v.text != text { v.text = text }
        v.placeholderLabel.text = placeholder
        v.updatePlaceholder()
        v.onReturn = onReturn
        v.onKey = onKey
        v.onPasteImages = onPasteImages
        v.onLongText = onLongText
        if let request = tablePaste, v.lastTablePaste != request.id {
            v.lastTablePaste = request.id
            DispatchQueue.main.async { v.insertTable(request.text) }
        }
        // Focus: only take it when someone asks (FocusState turns true: 「编辑」 a queued message, quoting…).
        // Never give it up from here — this view carries no .focused(), so SwiftUI keeps the FocusState false
        // and resigning on that dropped the focus at every text change (picked a candidate, deleted a character).
        let want = focused.wrappedValue
        if want, !context.coordinator.wanted, !v.isFirstResponder {
            DispatchQueue.main.async { if v.window != nil { v.becomeFirstResponder() } }
        }
        context.coordinator.wanted = want
    }

    /// Grows with the text from `minLines` to `maxLines`, then scrolls (like `.lineLimit(3...12)`).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let line = v.font?.lineHeight ?? UIFont.systemFont(ofSize: fontSize).lineHeight
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let scroll = fit > line * maxLines + 1
        if v.isScrollEnabled != scroll { DispatchQueue.main.async { v.isScrollEnabled = scroll } }
        return CGSize(width: width, height: ceil(min(max(fit, line * minLines), line * maxLines)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// Last FocusState value seen, so a request (false → true) is acted on once.
        var wanted = false
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            (v as? ComposerUITextView)?.updatePlaceholder()
            // Pinyin letters still being composed are not the message yet (autocomplete, drafts).
            guard v.markedTextRange == nil else { return }
            if parent.text != v.text { parent.text = v.text }
        }

        /// Back to false once taken, so the next request is a change again.
        func textViewDidBeginEditing(_ v: UITextView) {
            if parent.focused.wrappedValue { parent.focused.wrappedValue = false }
        }

        func textViewDidEndEditing(_ v: UITextView) {
            // Capture any input-method text committed while the keyboard closes.
            if parent.text != v.text { parent.text = v.text }
            (v as? ComposerUITextView)?.updatePlaceholder()
        }
    }
}

final class ComposerUITextView: UITextView {
    var lastTablePaste: UUID?
    func insertTable(_ value: String) {
        insertText(TableClipboard.insertion(value, into: text, range: selectedRange))
        updatePlaceholder()
    }
    var onReturn: ((Bool) -> Bool)?
    var onKey: ((ComposerKey) -> Bool)?
    var onPasteImages: (([ImageAttachment]) -> Void)?
    var onLongText: ((String) -> Bool)?
    let placeholderLabel = UILabel()
    /// Presses we acted on: their pressesEnded must not reach the text view either.
    private var taken: Set<UIPress> = []

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty || markedTextRange != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: font?.lineHeight ?? 20)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if markedTextRange == nil, presses.count == 1, let press = presses.first, let key = press.key, handle(key) {
            taken.insert(press)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(taken)
        taken.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(taken)
        taken.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    private func handle(_ key: UIKey) -> Bool {
        let mods = key.modifierFlags
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter:
            // ⇧↩ goes on to the text view, which types a newline.
            guard !mods.contains(.shift) else { return false }
            return onReturn?(mods.contains(.command)) ?? false
        case .keyboardUpArrow: return onKey?(.up) ?? false
        case .keyboardDownArrow: return onKey?(.down) ?? false
        case .keyboardTab: return onKey?(mods.contains(.shift) ? .shiftTab : .tab) ?? false
        case .keyboardEscape: return onKey?(.escape) ?? false
        default: return false
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.contains(pasteboardTypes: ["public.html", TableClipboard.tsvType]) { return true }
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, onLongText?(text) == true { return }
        if let table = TableClipboard.pasted() { insertTable(table); return }
        let pb = UIPasteboard.general
        if let onPasteImages, pb.hasImages, !pb.hasStrings {
            let images = (pb.images ?? []).compactMap { $0.pngData().flatMap(ImageTools.attachment(from:)) }
            if !images.isEmpty { onPasteImages(images); return }
        }
        super.paste(sender)
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// 独立滚动编辑器避免多行 TextField 的共享 field editor 在粘贴时排版整个草稿。
struct MacComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let fontSize: CGFloat
    let onReturn: (Bool) -> Bool
    let onKey: (ComposerKey) -> Bool
    let onPaste: () -> Bool
    var onLongText: ((String) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = MacComposerEditor(frame: .zero)
        view.isRichText = false
        view.textColor = .labelColor
        view.drawsBackground = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MacComposerEditor else { return }
        context.coordinator.parent = self
        let font = NSFont.systemFont(ofSize: fontSize)
        if view.appliedFontSize != fontSize {
            view.font = font
            view.appliedFontSize = fontSize
        }
        if !view.hasMarkedText(), view.string != text {
            view.string = text
            view.undoManager?.removeAllActions(withTarget: view)
        }
        view.placeholder = placeholder
        view.onReturn = onReturn
        view.onKey = onKey
        view.onPaste = onPaste
        view.onLongText = onLongText
        view.focusChanged = { [weak coordinator = context.coordinator] active in
            guard let coordinator else { return }
            coordinator.wanted = active
            coordinator.parent.focused.wrappedValue = active
        }
        view.needsDisplay = true
        let want = focused.wrappedValue
        if want, !context.coordinator.wanted {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        context.coordinator.wanted = want
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return context.coordinator.measurement.size(text, width: width, fontSize: fontSize)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerTextView
        var wanted = false
        let measurement = ComposerTextMeasurement()
        init(_ parent: MacComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MacComposerEditor else { return }
            view.needsDisplay = true
            guard !view.hasMarkedText() else { return }
            if parent.text != view.string { parent.text = view.string }
        }
        func textDidBeginEditing(_ notification: Notification) {
            wanted = true
            parent.focused.wrappedValue = true
        }
        func textDidEndEditing(_ notification: Notification) {
            if let view = notification.object as? NSTextView, parent.text != view.string { parent.text = view.string }
            wanted = false
            parent.focused.wrappedValue = false
        }
    }
}

/// 高度测量只布局最多 12 行；全文保留在原生编辑器中，可滚动、选中和撤销。
@MainActor final class ComposerTextMeasurement {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var lastText = ""
    private var lastFont: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var cached: CGSize?
    init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
    }
    func size(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGSize {
        if let cached, text == lastText, width == lastWidth, fontSize == lastFont { return cached }
        let font = NSFont.systemFont(ofSize: fontSize)
        let line = layout.defaultLineHeight(for: font)
        if text != lastText || fontSize != lastFont {
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        }
        container.containerSize = CGSize(width: width, height: ceil(line * 12))
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).height, layout.extraLineFragmentRect.maxY)
        let size = CGSize(width: width, height: ceil(min(max(height, line * 3), line * 12)))
        lastText = text; lastWidth = width; lastFont = fontSize; cached = size
        return size
    }
}

final class MacComposerEditor: NSTextView {
    var appliedFontSize: CGFloat?
    var placeholder = ""
    var onReturn: ((Bool) -> Bool)?
    var onKey: ((ComposerKey) -> Bool)?
    var onPaste: (() -> Bool)?
    var onLongText: ((String) -> Bool)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !hasMarkedText() {
            (placeholder as NSString).draw(in: bounds, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
    var focusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76:
                if !mods.contains(.shift), onReturn?(mods.contains(.command)) == true { return }
            case 126: if onKey?(.up) == true { return }
            case 125: if onKey?(.down) == true { return }
            case 48: if onKey?(mods.contains(.shift) ? .shiftTab : .tab) == true { return }
            case 53: if onKey?(.escape) == true { return }
            default: break
            }
        }
        super.keyDown(with: event)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           NSPasteboard.general.availableType(from: [.html, .init(TableClipboard.tsvType), .png, .tiff, .fileURL]) != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let text = pasteboard.string(forType: .string), onLongText?(text) == true { return true }
        return super.readSelection(from: pasteboard, type: type)
    }
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), onLongText?(text) == true { return }
        if onPaste?() == true { return }
        // 普通粘贴保持纯文本，避免网页富文本携带的字体和段落样式触发额外排版。
        pasteAsPlainText(sender)
    }
}
#endif
