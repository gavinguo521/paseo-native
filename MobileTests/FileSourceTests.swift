import SwiftUI
import Testing
import UIKit
@testable import Paseo

@Suite(.serialized) @MainActor struct FileSourceTests {
    private func textView(_ view: UIView) -> UITextView? {
        (view as? UITextView) ?? view.subviews.lazy.compactMap { textView($0) }.first
    }

    @Test func nativeFilePreviewScrollSelectionAndHighlight() async throws {
        let source = (0..<12000).map { $0 == 10999 ? "let short = 1" : "let value\($0) = \"中文 👨‍👩‍👧‍👦\" // " + String(repeating: "长行", count: 30) }.joined(separator: "\n")
        let fontName = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
        let document = try await Task.detached { try FileSourceDocument(source, fontName: fontName) }.value
        let controller = UIHostingController(rootView: NativeFileSource(document: document, language: "swift", target: nil))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let view = try #require(textView(controller.view))
        let range = NSRange(location: document.bodies[1].location, length: document.ranges[3].location - document.bodies[1].location)
        view.selectedRange = range
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if view.textStorage.attribute(.foregroundColor, at: document.bodies[0].location, effectiveRange: nil) as? UIColor == UIColor(SyntaxHighlight.keyword) { break }
            await Task.yield()
        }
        #expect(view.textStorage.attribute(.foregroundColor, at: document.bodies[0].location, effectiveRange: nil) as? UIColor == UIColor(SyntaxHighlight.keyword))
        #expect(view.selectedRange == range)
        #expect(view.text == document.text)
        let horizontal = try #require(view.superview as? UIScrollView)
        #expect(horizontal.contentSize.width > horizontal.bounds.width)
        #expect(view.contentSize.width < 10000)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-1555-file-mobile.png")
        try image.pngData()?.write(to: url)
        print("FILE_MOBILE screenshot=\(url.path) content=\(view.contentSize) container=\(view.textContainer.size) tracks=\(view.textContainer.widthTracksTextView)")
        horizontal.setContentOffset(CGPoint(x: 400, y: 0), animated: false)
        #expect(horizontal.contentOffset.x > 0)
        controller.rootView = NativeFileSource(document: document, language: "swift", target: 11000)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let scrollDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < scrollDeadline {
            let color = view.textStorage.attribute(.foregroundColor, at: document.bodies[4999].location, effectiveRange: nil) as? UIColor
            if view.contentOffset.y > 1000, color == UIColor(SyntaxHighlight.keyword) { break }
            await Task.yield()
            controller.view.layoutIfNeeded()
        }
        #expect(view.textStorage.attribute(.foregroundColor, at: document.bodies[4999].location, effectiveRange: nil) as? UIColor == UIColor(SyntaxHighlight.keyword))
        #expect(view.contentOffset.y > 1000)
        #expect(horizontal.contentOffset.x == 0)
        let glyphs = view.layoutManager.glyphRange(forCharacterRange: document.ranges[10999], actualCharacterRange: nil)
        let targetRect = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
            .offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
        #expect(targetRect.intersects(view.bounds))
        #expect(view.selectedRange == range)
    }
}
