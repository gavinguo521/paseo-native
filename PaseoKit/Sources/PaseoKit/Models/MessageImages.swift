import CryptoKit
import Foundation

/// A durable image on the connected host, independent of the sending client's memory.
public struct MessageImage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let mimeType: String
    public let sha256: String
}

struct MessageImageManifest: Codable, Sendable {
    static let directory = "~/.paseo/native-message-images/v1"
    static let maxBytes = 128 * 1024
    let version: Int
    let messageId: String
    let images: [MessageImage]

    init(messageId: String, images: [MessageImage]) {
        version = 1
        self.messageId = messageId
        self.images = images
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(_ messageId: String) -> String {
        digest(Data(messageId.utf8)) + ".json"
    }

    static func decode(_ data: Data, messageId: String) throws -> Self {
        guard data.count <= maxBytes else { throw MessageImageError.invalidManifest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.messageId == messageId, !value.images.isEmpty,
              Set(value.images.map(\.id)).count == value.images.count,
              value.images.allSatisfy({ !$0.id.isEmpty && $0.path.hasPrefix("/") &&
                  $0.mimeType.hasPrefix("image/") && $0.sha256.count == 64 }) else {
            throw MessageImageError.invalidManifest
        }
        return value
    }
}

enum MessageImageError: Error, CustomStringConvertible {
    case invalidManifest, unavailable
    var description: String { String(localized: "图片同步失败，请重试", bundle: .module) }
}

/// One cache per host. Missing manifests are normal for text-only and older messages.
/// Coalesces requests and bounds parallel reads when a long transcript is opened.
actor MessageImageCache {
    private var values: [String: [MessageImage]] = [:]
    private var order: [String] = []
    private var pending: [String: Task<[MessageImage], Error>] = [:]
    private var lanes: [Task<Void, Never>?] = Array(repeating: nil, count: 4)
    private var nextLane = 0

    func load(_ messageId: String, read: @escaping @Sendable () async throws -> Data?) async throws -> [MessageImage] {
        if let hit = values[messageId] { return hit }
        if let task = pending[messageId] { return try await task.value }
        let previous = lanes[nextLane]
        let task = Task {
            await previous?.value
            guard let data = try await read() else { return [MessageImage]() }
            return try MessageImageManifest.decode(data, messageId: messageId).images
        }
        lanes[nextLane] = Task { _ = try? await task.value }
        nextLane = (nextLane + 1) % lanes.count
        pending[messageId] = task
        defer { pending[messageId] = nil }
        let images = try await task.value
        // A local send may have published the manifest while an earlier read was in flight.
        if let published = values[messageId], !published.isEmpty { return published }
        remember(images, for: messageId)
        return images
    }

    func remember(_ images: [MessageImage], for messageId: String) {
        order.removeAll { $0 == messageId }
        order.append(messageId)
        values[messageId] = images
        if order.count > 512 { values[order.removeFirst()] = nil }
    }
}
