import AVFoundation
import ImageIO
import PaseoKit
import SwiftUI
import Testing
@testable import Paseo

struct VideoAttachmentTests {
    @Test func samplingCoversStartAndEndAndBoundsLongClips() throws {
        let short = try VideoProcessor.sampleTimes(duration: 12)
        #expect(short.count == 25)
        #expect(short.first == 0)
        #expect(short.last! > 11.9 && short.last! < 12)
        #expect(zip(short, short.dropFirst()).allSatisfy { $0 < $1 && $1 - $0 <= 0.5 })
        let long = try VideoProcessor.sampleTimes(duration: 180)
        #expect(long.count == 48 && long.last! > 179.9)
        #expect(try VideoProcessor.sampleTimes(duration: 0.01) == [0])
        for invalid in [0, -1, .infinity, .nan, 181] {
            #expect(throws: VideoPreparationError.self) { try VideoProcessor.sampleTimes(duration: invalid) }
        }
    }

    @Test func hevcFramesKeepPortraitTransformAndActualTimestamps() async throws {
        let url = try await makeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try VideoSource.copy(url)
        let prepared = try await VideoProcessor.prepare(source)
        #expect(prepared.frames.count >= 4)
        #expect(prepared.frames.first!.seconds < 0.1)
        #expect(prepared.frames.last!.seconds > 1.8)
        #expect(zip(prepared.frames, prepared.frames.dropFirst()).allSatisfy { $0.seconds <= $1.seconds })
        for frame in prepared.frames {
            let image = try #require(CGImageSourceCreateWithData(frame.image.data as CFData, nil))
            let cg = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
            #expect(cg.height > cg.width) // encoded landscape + preferred 90° rotation
            #expect(frame.image.mimeType == "image/jpeg")
            #expect(frame.image.data.count <= 400 * 1024)
        }
        #expect(prepared.context(imageOffset: 2)["text"]?.stringValue?.contains("Image 3: 00:00.") == true)
        #expect(prepared.context(imageOffset: 2)["mimeType"]?.stringValue == "text/plain")
    }

    @Test @MainActor func queueEditsRetriesAndRemovalKeepFrameOwnership() async throws {
        let url = try await makeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await VideoProcessor.prepare(VideoSource.copy(url))
        let still = ImageAttachment(data: Data([1]), mimeType: "image/jpeg")
        let item = UploadItem(name: "screen.mp4", isVideo: true, videoSource: prepared.source, video: prepared)
        let queued = QueuedMessage(text: "Find the UI problem", images: [still], files: [], uploads: [item])
        #expect(item.done)
        let payload = try ComposerMediaPayload(images: queued.images, files: queued.files, uploads: queued.uploads)
        #expect(payload.images.map(\.id) == [still.id] + prepared.frames.map(\.image.id))
        #expect(payload.files.count == 1)
        #expect(payload.files[0]["text"]?.stringValue?.contains("Image 2:") == true)
        let restored = UploadItem.restoring(queued.uploads, into: [])
        let retry = try ComposerMediaPayload(images: queued.images, files: [], uploads: UploadItem.restoring(queued.uploads, into: restored))
        #expect(retry.images == payload.images)
        #expect(retry.files == payload.files)
        let removed = try ComposerMediaPayload(images: queued.images, files: [], uploads: [])
        #expect(removed.images == [still] && removed.files.isEmpty)
        let huge = ImageAttachment(data: Data(count: VideoProcessor.maxImageBytes), mimeType: "image/jpeg")
        #expect(throws: VideoPreparationError.self) { try ComposerMediaPayload(images: [huge], files: [], uploads: restored) }
    }

    @Test func invalidVideoFailsAndTemporaryCopyIsReleased() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var source: VideoSource? = try VideoSource.copy(url)
        let copied = source!.url
        do {
            _ = try await VideoProcessor.prepare(source!)
            Issue.record("Invalid video must not silently become a ready attachment")
        } catch { }
        source = nil
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancellationStopsPreparation() async throws {
        let url = try await makeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try VideoSource.copy(url)
        let work = Task { try await VideoProcessor.prepare(source) }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
    }

    /// Optional developer fixture. No private paths or media enter the repository.
    @Test func localRecordingWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["PASEO_TEST_VIDEO"] else { return }
        let video = try await VideoProcessor.prepare(VideoSource.copy(URL(fileURLWithPath: path)))
        #expect(!video.frames.isEmpty)
        let payload = try ComposerMediaPayload(images: [], files: [], uploads: [.init(name: "recording", isVideo: true, video: video)])
        #expect(payload.images.count == video.frames.count)
        print("VIDEO_FIXTURE duration=\(video.duration) frames=\(video.frames.count) imageBytes=\(payload.images.reduce(0) { $0 + $1.data.count })")
        if let dir = ProcessInfo.processInfo.environment["PASEO_TEST_VIDEO_OUTPUT"] {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, frame) in video.frames.enumerated() {
                try frame.image.data.write(to: root.appendingPathComponent("frame-\(index).jpg"))
            }
            let request: JSONValue = ["text": "Analyze this UI recording", "images": .array(payload.images.map {
                ["data": .string($0.data.base64EncodedString()), "mimeType": .string($0.mimeType)]
            }), "attachments": .array(payload.files)]
            try Data(request.serialized().utf8).write(to: root.appendingPathComponent("request.json"))
        }
    }
}

private func makeMovie() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 160])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 160,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for i in 0..<24 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        #expect(status == kCVReturnSuccess)
        let pixel = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 160, bitsPerComponent: 8,
                                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        ctx.setFillColor(CGColor(red: i < 12 ? 1 : 0, green: 0, blue: i < 12 ? 0 : 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(i), timescale: 12)))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}
