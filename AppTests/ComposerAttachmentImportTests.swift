import AppKit
import PaseoKit
import Testing
@testable import Paseo

@MainActor struct ComposerAttachmentImportTests {
    @Test func finderDropImportsMixedAttachmentsOnceWithoutChangingDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picture = directory.appendingPathComponent("图片.PNG")
        let video = directory.appendingPathComponent("录屏.MP4")
        let pdf = directory.appendingPathComponent("文档.pdf")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: picture)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([picture, video, pdf] as [NSURL])
        var images: [ImageAttachment] = [], files: [URL] = []
        var importCount = 0
        let editor = MacComposerEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        editor.string = "已有草稿"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.onAttachments = { pb in
            ComposerAttachmentPasteboard.read(pb, importFiles: { urls in
                importCount += 1
                return ComposerAttachmentImport.files(urls, addImages: { images += $0 }, addFiles: { files += $0 })
            }, addImages: { images += $0 })
        }
        var targeted = false
        editor.onDropTargetChanged = { targeted = $0 }
        let drag = AttachmentDrag(pasteboard)
        #expect(editor.draggingEntered(drag) == .copy)
        #expect(editor.draggingUpdated(drag) == .copy)
        #expect(targeted && importCount == 0)
        #expect(editor.prepareForDragOperation(drag))
        #expect(editor.performDragOperation(drag))
        #expect(!targeted && importCount == 1)
        #expect(images.count == 1)
        #expect(files == [video, pdf])
        #expect(editor.string == "已有草稿")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))

        // NSTextView's alternate paste/read path uses the identical file classifier.
        images = []; files = []
        #expect(editor.readSelection(from: pasteboard, type: .fileURL))
        #expect(images.count == 1 && files == [video, pdf])
        #expect(editor.string == "已有草稿")
    }

    @Test func textPathAndWebPageTextRemainText() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let text = "/tmp/a recording.mp4"
        pb.setString(text, forType: .string)
        pb.setData(Data([1, 2, 3]), forType: .png)
        #expect(!ComposerAttachmentPasteboard.containsAttachments(pb))
        #expect(!ComposerAttachmentPasteboard.read(pb, importFiles: { _ in Issue.record("Plain text is not a file drop"); return true },
                                                   addImages: { _ in Issue.record("Copied text must win") }))
        let editor = MacComposerEditor(frame: .zero)
        editor.isRichText = false
        #expect(editor.readSelection(from: pb, type: .string))
        #expect(editor.string == text)
    }
}

@MainActor private final class AttachmentDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
