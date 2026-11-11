import PaseoKit
import UniformTypeIdentifiers

/// File pickers, Finder drops and clipboard files must produce the same attachment kinds.
@MainActor enum ComposerAttachmentImport {
    @discardableResult
    static func files(_ urls: [URL], addImages: ([ImageAttachment]) -> Void, addFiles: (([URL]) -> Void)?) -> Bool {
        var images: [ImageAttachment] = []
        var files: [URL] = []
        for url in urls where url.isFileURL {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
               let image = ImageTools.attachments(from: [url]).first {
                images.append(image)
            } else {
                files.append(url)
            }
        }
        if !images.isEmpty { addImages(images) }
        if !files.isEmpty { addFiles?(files) }
        return !images.isEmpty || (!files.isEmpty && addFiles != nil)
    }
}

#if os(macOS)
import AppKit

enum ComposerAttachmentPasteboard {
    static func containsAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.fileURL]) != nil { return true }
        // A copied web page can include an image representation alongside its text.
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return false }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    @MainActor static func read(_ pasteboard: NSPasteboard, importFiles: ([URL]) -> Bool,
                               addImages: ([ImageAttachment]) -> Void) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return importFiles(urls) }
        guard containsAttachments(pasteboard),
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let image = ImageTools.attachment(from: data) else { return false }
        addImages([image])
        return true
    }
}
#endif
