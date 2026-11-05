import PaseoKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

enum ImageTools {
    /// Long edge cap before sending: keeps base64 well under the relay's 32 MiB frame limit.
    static let maxEdge: CGFloat = 2048

    static func attachment(from data: Data) -> ImageAttachment? {
        #if os(macOS)
        guard let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        #endif
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        // Small PNGs (screenshots) stay lossless; everything else becomes JPEG.
        if scale == 1, data.count < 4_000_000, let type = UTType(filenameExtension: "png"), data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ImageAttachment(data: data, mimeType: type.preferredMIMEType ?? "image/png")
        }
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ImageAttachment(data: out as Data, mimeType: "image/jpeg")
    }

    static func attachments(from urls: [URL]) -> [ImageAttachment] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (try? Data(contentsOf: url)).flatMap(attachment(from:))
        }
    }

    nonisolated(unsafe) private static let decoded = { let c = NSCache<NSString, PlatformImage>(); c.countLimit = 200; return c }()

    /// Decoded once per attachment and size: rows redraw while scrolling, and a fresh image from `data`
    /// each time made the picture decode again on the main thread. `maxPixel` downsamples for thumbnails.
    static func image(_ a: ImageAttachment, maxPixel: Int? = nil) -> Image? {
        let key = "\(a.id.uuidString)-\(maxPixel ?? 0)" as NSString
        let platform: PlatformImage
        if let hit = decoded.object(forKey: key) { platform = hit }
        else {
            guard let made = maxPixel.flatMap({ thumbnail(a.data, maxPixel: $0) }) ?? PlatformImage(data: a.data) else { return nil }
            decoded.setObject(made, forKey: key)
            platform = made
        }
        #if os(macOS)
        return Image(nsImage: platform)
        #else
        return Image(uiImage: platform)
        #endif
    }

    private static func thumbnail(_ data: Data, maxPixel: Int) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    /// Loads images from drag-and-drop / paste providers.
    static func load(_ providers: [NSItemProvider], into add: @escaping @MainActor ([ImageAttachment]) -> Void) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let a = (try? Data(contentsOf: url)).flatMap(attachment(from:)) else { return }
                    Task { @MainActor in add([a]) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let a = attachment(from: data) else { return }
                    Task { @MainActor in add([a]) }
                }
            }
        }
    }
}

struct AttachmentTray: View {
    @Binding var images: [ImageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { a in
                    ZStack(alignment: .topTrailing) {
                        (ImageTools.image(a, maxPixel: 240) ?? Image(systemName: "photo"))
                            .resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button { images.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("移除图片")
                    }
                }
            }
            .padding(.top, 6).padding(.horizontal, 4)
        }
    }
}
