#if os(macOS)
import AppKit

/// 会话里拖选、双击选词、三击选段后自动拷到剪贴板（设置 → 聊天 →「选中文字后自动拷贝」）。
/// SwiftUI 的 `.textSelection(.enabled)` 没有选区回调，所以在鼠标松开后对第一响应者发系统的 copy:。
/// 只认按下时就点在那块文字上的手势：点空白处不会清掉旧选区，拖分隔栏、双击侧栏也不该把它再拷一遍。
/// 输入框、终端、网页这类能输入的视图不管。
@MainActor enum SelectionAutoCopy {
    static let defaultsKey = "selectionAutoCopy"
    private static var monitor: Any?
    private static weak var pressed: NSView?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            if e.type == .leftMouseDown {
                pressed = e.window?.contentView.flatMap { v in v.hitTest(v.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow) }
            } else if let view = pressed {
                pressed = nil
                // 选区在这次松开被处理之后才定下来。
                DispatchQueue.main.async { copyIfSelected(in: view) }
            }
            return e
        }
    }

    private static func copyIfSelected(in view: NSView) {
        guard UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true,
              let window = view.window, window.firstResponder === view else { return }
        if let tv = view as? NSTextView { guard !tv.isEditable else { return } }
        else if view is NSTextInputClient { return }
        // 没有选区时 SwiftUI 的文字视图不响应 copy:，取不到目标。
        let copy = #selector(NSText.copy(_:))
        guard let target = NSApp.target(forAction: copy, to: nil, from: nil) as? NSResponder, target === view else { return }
        if let v = target as? NSUserInterfaceValidations {
            let item = NSMenuItem(title: "", action: copy, keyEquivalent: "")
            guard v.validateUserInterfaceItem(item) else { return }
        }
        NSApp.sendAction(copy, to: target, from: nil)
    }
}
#endif
