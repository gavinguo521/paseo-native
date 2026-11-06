import Foundation
import Testing
@testable import PaseoKit

@Suite struct MessageImageTests {
    private func manifest(_ id: String, paths: [String] = ["/home/test/.paseo/uploads/upload_1/photo.jpg"]) throws -> Data {
        try JSONEncoder().encode(MessageImageManifest(messageId: id, images: paths.enumerated().map { index, path in
            MessageImage(id: "upload_\(index)", path: path, mimeType: "image/jpeg", sha256: MessageImageManifest.digest(Data(path.utf8)))
        }))
    }

    @Test func anotherClientAndRelaunchRecoverImagesInAttachmentOrder() async throws {
        let data = try manifest("message", paths: ["/home/a/second.jpg", "/home/a/first.jpg"])
        let phone = MessageImageCache(), mac = MessageImageCache(), relaunched = MessageImageCache()
        let sent = try await phone.load("message") { data }
        let received = try await mac.load("message") { data }
        let restored = try await relaunched.load("message") { data }
        #expect(received == sent && restored == sent)
        #expect(received.map(\.path) == ["/home/a/second.jpg", "/home/a/first.jpg"])
    }

    @Test func messageIdsCannotEscapeStorageAndManifestsCannotClaimAnotherMessage() throws {
        let file = MessageImageManifest.fileName("../../图片/../../../secret")
        #expect(!file.contains("/"))
        #expect(file.count == 69 && file.hasSuffix(".json"))
        let data = try manifest("a")
        #expect(throws: MessageImageError.self) { try MessageImageManifest.decode(data, messageId: "b") }
        let remote = try manifest("a", paths: ["https://example.com/tracker.jpg"])
        #expect(throws: MessageImageError.self) { try MessageImageManifest.decode(remote, messageId: "a") }
    }

    @Test func cacheIsHostScopedAndMissingTextMessagesAreNotRepeatedlyRequested() async throws {
        let first = MessageImageCache(), second = MessageImageCache()
        let calls = ReadCounter()
        #expect(try await first.load("text") { await calls.read(nil) }.isEmpty)
        #expect(try await first.load("text") { await calls.read(nil) }.isEmpty)
        #expect(await calls.count == 1)
        let data = try manifest("text")
        #expect(try await second.load("text") { data }.count == 1)
    }

    @Test func concurrentRowsShareOneRequestAndLongHistoriesBoundNetworkConcurrency() async throws {
        let cache = MessageImageCache(), calls = ReadCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = try await cache.load("shared") { await calls.read(nil, delay: true) } } }
            try await group.waitForAll()
        }
        #expect(await calls.count == 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { _ = try await cache.load("row-\(index)") { await calls.read(nil, delay: true) } }
            }
            try await group.waitForAll()
        }
        #expect(await calls.count == 21)
        #expect(await calls.maximum <= 4)
    }

    @Test func transportFailureCanRetryAndPublicationReplacesNegativeCache() async throws {
        let cache = MessageImageCache()
        do {
            _ = try await cache.load("image") { throw URLError(.networkConnectionLost) }
            Issue.record("Expected a transport failure")
        } catch { }
        let data = try manifest("image")
        let recovered = try await cache.load("image") { data }
        #expect(recovered.count == 1)
        #expect(try await cache.load("pending") { nil }.isEmpty)
        await cache.remember(recovered, for: "pending")
        #expect(try await cache.load("pending") { nil } == recovered)
    }

    @Test func malformedOrOversizedRecordsDoNotBecomePermanentCacheHits() async throws {
        let cache = MessageImageCache()
        for data in [Data("{}".utf8), Data(repeating: 32, count: MessageImageManifest.maxBytes + 1)] {
            do { _ = try await cache.load("image") { data }; Issue.record("Expected invalid manifest") }
            catch { }
        }
        let valid = try manifest("image")
        #expect(try await cache.load("image") { valid }.count == 1)
    }
}

private actor ReadCounter {
    private(set) var count = 0
    private var active = 0
    private(set) var maximum = 0
    func read(_ data: Data?, delay: Bool = false) async -> Data? {
        count += 1
        active += 1
        maximum = max(maximum, active)
        if delay { try? await Task.sleep(for: .milliseconds(10)) }
        active -= 1
        return data
    }
}
