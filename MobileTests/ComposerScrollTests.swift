import SwiftUI
import Testing
import UIKit
import XCTest
@testable import Paseo

@Suite(.serialized) @MainActor struct ComposerScrollTests {
    @Test func pastedDraftReachesEndAfterKeyboardDismissalAndCanShrink() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let text = (1...1000).map { "第\($0)行：" + String(repeating: "测试长内容输入框的滚动。", count: 8) }
            .joined(separator: "\n") + "\n末尾标记 END"
        let host = UIHostingController(rootView: ScrollFixture(initialText: ""))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        let view = try #require(editor(in: host.view))
        #expect(view.becomeFirstResponder())
        let pasteboardItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = pasteboardItems }
        UIPasteboard.general.string = text
        let pasted = XCTestExpectation(description: "系统完成文本粘贴")
        let observer = NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification,
                                                              object: view, queue: .main) { _ in pasted.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        view.paste(nil)
        let pasteResult = await XCTWaiter.fulfillment(of: [pasted], timeout: 5)
        #expect(pasteResult == .completed)
        #expect(view.text == text)
        PhoneKeyboard.dismiss()
        #expect(!view.isFirstResponder)
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        await Task.yield()
        #expect(view.isScrollEnabled)
        #expect(view.panGestureRecognizer.isEnabled)
        #expect(view.bounds.height < 250)

        let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
        view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        view.layoutIfNeeded()
        await Task.yield()
        let end = view.caretRect(for: view.endOfDocument)
        #expect(end.maxY <= view.bounds.maxY + 1)
        #expect(end.minY >= view.bounds.minY)
        #expect(view.text == text)

        view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        view.insertText("\n新增末尾")
        #expect(view.text.hasSuffix("END\n新增末尾"))
        view.selectedRange = NSRange(location: 0, length: (view.text as NSString).length)
        view.insertText("短草稿")
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        await Task.yield()
        #expect(view.text == "短草稿")
        #expect(!view.isScrollEnabled)
        #expect(view.bounds.height < 100)
    }

    private func editor(in view: UIView) -> ComposerUITextView? {
        if let editor = view as? ComposerUITextView { return editor }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
}

private struct ScrollFixture: View {
    @State var text: String
    @FocusState private var focused: Bool
    init(initialText: String) { _text = State(initialValue: initialText) }
    var body: some View {
        VStack {
            Spacer()
            ComposerTextView(text: $text, placeholder: "输入", focused: $focused, fontSize: 16,
                             onReturn: { _ in false })
        }.padding(28)
    }
}
