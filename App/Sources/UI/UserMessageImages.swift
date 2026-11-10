import PaseoKit
import SwiftUI

/// The sender's immediate preview and the receiver's host-backed images occupy the same row.
struct UserMessageImages: View {
    let messageId: String
    let localImages: [ImageAttachment]
    @Environment(\.hostFileReader) private var reader
    @Environment(\.messageImagesConnected) private var connected
    @State private var remoteImages: [MessageImage] = []
    @State private var zoomed: ImageAttachment?

    var body: some View {
        // Keep a concrete container before metadata arrives. An empty Group inside a
        // message row has no rendered child, so SwiftUI never starts its loading task.
        VStack(spacing: 0) {
            if !localImages.isEmpty || !remoteImages.isEmpty {
                HStack(spacing: 6) {
                    // Keep the thumbnail frames with the user's message; center each
                    // image inside its own frame, not across the conversation column.
                    Spacer(minLength: 64)
                    if !localImages.isEmpty {
                        ForEach(localImages) { image in
                            (ImageTools.image(image, maxPixel: 1080) ?? Image(systemName: "photo"))
                                .resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .imageExport(ImageSource(name: "", data: image.data))
                                .onTapGesture { zoomed = image }
                        }
                    } else {
                        ForEach(remoteImages) { image in
                            MarkdownImage(alt: "Image", url: image.path, maxSize: CGSize(width: 360, height: 180), alignment: .center)
                        }
                    }
                }
            }
        }
        .task(id: "\(reader?.cacheScope ?? "")|\(messageId)|\(connected)") {
            guard connected, localImages.isEmpty, let reader else { return }
            // A transport error is not cached; a reconnect or reopening the session retries it.
            for attempt in 0..<3 {
                do {
                    let images = try await reader.messageImages(messageId)
                    guard !Task.isCancelled else { return }
                    remoteImages = images
                    return
                } catch {
                    guard !Task.isCancelled, attempt < 2 else { return }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        .sheet(item: $zoomed) { attachment in
            if let image = ImageTools.image(attachment) {
                ImageLightbox(image: image, source: ImageSource(name: "", data: attachment.data))
            }
        }
    }
}
