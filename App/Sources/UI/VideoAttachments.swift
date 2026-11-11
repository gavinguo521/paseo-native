import AVFoundation
import AVKit
import CoreText
import CoreTransferable
import ImageIO
import PaseoKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Own a copy, not a security-scoped / Photos provider URL that can expire during a draft.
final class VideoSource: Sendable {
    let url: URL
    let name: String
    private let directory: URL

    private init(url: URL, directory: URL, name: String) {
        self.url = url; self.directory = directory; self.name = name
    }

    static func copy(_ url: URL) throws -> VideoSource {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw VideoPreparationError.unreadable }
        guard let size = values.fileSize, size <= 500 * 1024 * 1024 else { throw VideoPreparationError.tooLarge }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            try Task.checkCancellation()
            return VideoSource(url: destination, directory: directory, name: url.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Photos gives us a temporary file; copy it before the transfer callback returns.
struct PickedVideo: Transferable, Sendable {
    let source: VideoSource
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedVideo(source: try VideoSource.copy(received.file))
        }
    }
}

enum VideoPreparationError: LocalizedError {
    case unreadable, tooLarge, tooLong, encoding, messageTooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "无法读取视频画面，请选择可播放的 MP4 或 MOV 文件。")
        case .tooLarge: String(localized: "视频超过 500 MB，请先裁剪需要分析的片段。")
        case .tooLong: String(localized: "视频超过 3 分钟，请先裁剪需要分析的片段。")
        case .encoding: String(localized: "无法生成视频画面，请换一个视频重试。")
        case .messageTooLarge: String(localized: "本次图片和视频画面过多，请减少附件或分开发送。")
        }
    }
}

struct PreparedVideo: Sendable {
    struct Frame: Sendable {
        let seconds: Double
        let image: ImageAttachment
    }
    let source: VideoSource
    let duration: Double
    let frames: [Frame]

    /// Text attachments are understood by all existing providers; the pixels travel as real images.
    func context(imageOffset: Int) -> JSONValue {
        let times = frames.enumerated().map { "Image \(imageOffset + $0.offset + 1): \(VideoProcessor.timestamp($0.element.seconds))" }.joined(separator: "\n")
        return ["type": "text", "mimeType": "text/plain", "title": .string(source.name), "text": .string("""
        Video recording: \(source.name)
        Duration: \(VideoProcessor.timestamp(duration)). The following image numbers refer to the images attached to this message (1-based).
        \(times)
        These are chronological, sampled video frames, with their actual timestamps printed below each image. They cover the whole clip but are NOT continuous video. Audio has NOT been transcribed or supplied. The original video file has NOT been uploaded.
        Use the frames with the user's description to analyze visible UI states, transitions and problems. Distinguish visible evidence from inference; do not claim to see taps, hear speech, or observe events between samples. If a transient issue is missing, ask for a shorter recording of that interval.
        """)]
    }
}

enum VideoProcessor {
    static let maxFrames = 48
    static let maxImageBytes = 20 * 1024 * 1024 // Base64 + JSON stay below the relay's 32 MiB limit.

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    static func sampleTimes(duration: Double) throws -> [Double] {
        guard duration.isFinite, duration > 0 else { throw VideoPreparationError.unreadable }
        guard duration <= 180 else { throw VideoPreparationError.tooLong }
        let end = max(0, duration - 1.0 / 30)
        let count = min(maxFrames, max(1, Int(ceil(end * 2)) + 1))
        return count == 1 ? [0] : (0..<count).map { end * Double($0) / Double(count - 1) }
    }

    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", ms / 60_000, (ms / 1000) % 60, ms % 1000)
    }

    /// Non-main-actor: decoding / JPEG encoding must not block typing or scrolling.
    static func prepare(_ source: VideoSource, progress: @Sendable (Double) async -> Void = { _ in }) async throws -> PreparedVideo {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source.url)
        let duration = try await asset.load(.duration).seconds
        let times = try sampleTimes(duration: duration)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw VideoPreparationError.unreadable }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }
        var frames: [PreparedVideo.Frame] = []
        // Submit one sequence so the decoder can walk the clip instead of reopening a
        // HEVC seek for every frame (particularly expensive for phone recordings).
        let requested = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        for await result in generator.images(for: requested) {
            try Task.checkCancellation()
            switch result {
            case .success(_, let image, let actual):
                guard actual.seconds.isFinite else { throw VideoPreparationError.unreadable }
                let data = try autoreleasepool { try encode(image, at: actual.seconds) }
                frames.append(.init(seconds: actual.seconds, image: ImageAttachment(data: data, mimeType: "image/jpeg")))
                await progress(Double(frames.count) / Double(times.count))
            case .failure(_, let error): throw error
            }
        }
        try Task.checkCancellation()
        guard frames.count == times.count else { throw VideoPreparationError.unreadable }
        return PreparedVideo(source: source, duration: duration, frames: frames.sorted { $0.seconds < $1.seconds })
    }

    private static func encode(_ image: CGImage, at seconds: Double) throws -> Data {
        // The timestamp occupies its own footer, so no part of the recorded UI is covered.
        for edge in [2048, 1440, 1080] {
            let scale = min(1, Double(edge) / Double(max(image.width, image.height)))
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            let footer = max(28, width / 30)
            guard let ctx = CGContext(data: nil, width: width, height: height + footer, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VideoPreparationError.encoding }
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height + footer))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: footer, width: width, height: height))
            let caption = NSAttributedString(string: timestamp(seconds), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, CGFloat(footer) * 0.6, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 8, y: CGFloat(footer) * 0.24)
            CTLineDraw(CTLineCreateWithAttributedString(caption), ctx)
            guard let stamped = ctx.makeImage() else { throw VideoPreparationError.encoding }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw VideoPreparationError.encoding }
            CGImageDestinationAddImage(destination, stamped, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw VideoPreparationError.encoding }
            if data.length <= 400 * 1024 { return data as Data }
        }
        throw VideoPreparationError.encoding
    }
}

/// Compose only at dispatch. Draft / queue images remain the user's original attachments,
/// otherwise editing a queue item or retrying a failed send would duplicate video frames.
struct ComposerMediaPayload {
    let images: [ImageAttachment]
    let files: [JSONValue]
    init(images: [ImageAttachment], files: [JSONValue], uploads: [UploadItem]) throws {
        var allImages = images, allFiles = files
        for video in uploads.compactMap(\.video) {
            allFiles.append(video.context(imageOffset: allImages.count))
            allImages += video.frames.map(\.image)
        }
        if uploads.contains(where: { $0.isVideo }), allImages.reduce(0, { $0 + $1.data.count }) > VideoProcessor.maxImageBytes {
            throw VideoPreparationError.messageTooLarge
        }
        self.images = allImages; self.files = allFiles
    }
}

@MainActor
func prepareVideo(into items: Binding<[UploadItem]>, name: String = String(localized: "视频"),
                  load: @escaping @Sendable () async throws -> VideoSource) {
    let item = UploadItem(name: name, isVideo: true)
    items.wrappedValue.append(item)
    let work = Task {
        do {
            let source = try await load()
            try Task.checkCancellation()
            guard let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) else { return }
            items.wrappedValue[i].videoSource = source
            items.wrappedValue[i].name = source.name
            let video = try await VideoProcessor.prepare(source) { value in
                await MainActor.run {
                    if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].progress = value }
                }
            }
            try Task.checkCancellation()
            if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].video = video }
        } catch is CancellationError {
            // Removing the draft item cancels work and never re-inserts it.
        } catch {
            if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].error = error.localizedDescription }
        }
        if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].work = nil }
    }
    if let i = items.wrappedValue.firstIndex(where: { $0.id == item.id }) { items.wrappedValue[i].work = work }
}

struct VideoAttachmentCard: View {
    let item: UploadItem
    let remove: () -> Void
    let retry: () -> Void
    @State private var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { preview = true } label: {
                    ZStack {
                        if let image = item.video?.frames.first?.image, let thumbnail = ImageTools.image(image, maxPixel: 180) {
                            thumbnail.resizable().scaledToFit()
                        }
                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.6))
                    }.frame(width: 48, height: 58).background(.black, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).disabled(item.videoSource == nil).accessibilityLabel("预览视频")
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).lineLimit(1).font(.caption.weight(.medium))
                    if let video = item.video {
                        Text("\(Int(ceil(video.duration))) 秒 · \(video.frames.count) 帧").font(.caption2).foregroundStyle(Theme.muted)
                    } else if item.error == nil {
                        ProgressView(value: item.progress).frame(width: 140)
                        Text("正在准备视频画面…").font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
                Button(action: remove) { Image(systemName: "xmark").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("移除附件")
            }
            if let error = item.error {
                Text(error).font(.caption2).foregroundStyle(Theme.destructive).fixedSize(horizontal: false, vertical: true)
                if item.videoSource != nil { Button("重试", action: retry).font(.caption).buttonStyle(.plain) }
            } else {
                Text("发送采样画面供 AI 分析，不含音频").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .padding(10).frame(width: 290).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $preview) {
            if let source = item.videoSource { VideoAttachmentPreview(source: source, video: item.video) }
        }
    }
}

private struct VideoAttachmentPreview: View {
    let source: VideoSource
    let video: PreparedVideo?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var zoomed: LightboxItem?
    @Namespace private var lightboxNS
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(source.name).font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal)
            VideoPlayer(player: player)
            if let video {
                Text("AI 将分析下方的采样画面，未采样的瞬间可能遗漏；不包含音频。").font(.caption).foregroundStyle(Theme.muted).padding(.horizontal)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(video.frames, id: \.image.id) { frame in
                            Button {
                                zoomed = ImageTools.lightbox(video.frames.map(\.image), selected: frame.image)
                            } label: {
                                VStack {
                                    (ImageTools.image(frame.image, maxPixel: 200) ?? Image(systemName: "photo")).resizable().scaledToFit().frame(width: 72, height: 96)
                                    Text(VideoProcessor.timestamp(frame.seconds)).font(.caption2.monospacedDigit())
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal)
                }.frame(height: 124)
            }
        }
        .padding(.vertical)
        .macOnly { $0.frame(width: 800, height: 650) }
        .onAppear { player = AVPlayer(url: source.url) }
        .onDisappear { player?.pause(); player = nil }
        .imageLightbox($zoomed, namespace: lightboxNS)
    }
}
