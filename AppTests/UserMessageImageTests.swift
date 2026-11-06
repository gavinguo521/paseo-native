import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite @MainActor struct UserMessageImageTests {
    @Test func receivingRowLoadsImagesWithoutAnOptimisticPreview() async throws {
        let calls = ImageReadCalls()
        let reader = HostFileReader(messageImages: { _ in
            await calls.metadata()
            return [MessageImage(id: "image", path: "/host/photo.png", mimeType: "image/png", sha256: String(repeating: "a", count: 64))]
        }) { _ in
            await calls.pixels()
            return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAEklEQVR4nGPQWJDyHx9moL0CAL+zRWEEDF0GAAAAAElFTkSuQmCC")
        }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = TimelineRow(id: "remote", turnId: nil, timestamp: Date(),
                              item: .userMessage(text: "Sent from another device", messageId: "remote"),
                              isStreaming: false, isPending: false)
        let view = NSHostingView(rootView: ScrollView {
            VStack {
                ForEach([row]) { row in
                    TimelineItemView(item: .row(row, footer: true))
                }
                .environment(\.hostFileReader, reader).environment(\.messageImagesConnected, true)
            }
        })
        window.contentView = view
        window.orderFront(nil)
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            if await calls.pixelReads > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await calls.metadataReads == 1)
        #expect(await calls.pixelReads == 1)
        let decoded = await TimelineImageLoader.shared.image(key: reader.cacheScope + "|/host/photo.png",
            url: "/host/photo.png", snapshotKey: nil, maxPixel: 720, reader: reader)
        #expect(decoded != nil)
    }
}

private actor ImageReadCalls {
    private(set) var metadataReads = 0
    private(set) var pixelReads = 0
    func metadata() { metadataReads += 1 }
    func pixels() { pixelReads += 1 }
}
