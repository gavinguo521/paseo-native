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

/// Hardware-keyboard keys the composer acts on besides Return (completion list, recall, permission mode).
enum ComposerKey { case up, down, tab, shiftTab, escape }

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
    var tablePaste: TablePasteRequest? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        // 长草稿需要完整、稳定的滚动范围；TextKit 2 的视口估算会在滚动时改变内容高度。
        let v = ComposerUITextView(usingTextLayoutManager: false)
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
