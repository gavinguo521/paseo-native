import Foundation
import Testing
@testable import PaseoKit

@Suite(.timeLimit(.minutes(1))) struct FileUploadTests {
    @Test @MainActor func slowRequestStillPrecedesBeginChunksAndEnd() async throws {
        let transport = UploadTransport(headerDelay: .milliseconds(120))
        let (host, connection) = try await connected(transport)
        for size in [0, 1, 300_001] {
            let data = Data((0..<size).map { UInt8($0 % 251) })
            let file = try await host.upload(fileName: "录屏帧-\(size).jpg", mimeType: "image/jpeg", data: data)
            #expect(file.size == size)
            #expect(await transport.contents(file.id) == data)
        }
        #expect(await transport.violations.isEmpty)
        await connection.close()
    }

    @Test @MainActor func concurrentUploadsKeepIndependentOrderedBodies() async throws {
        let transport = UploadTransport(headerDelay: .milliseconds(90))
        let (host, connection) = try await connected(transport)
        let jobs = (0..<8).map { index in
            Task { @MainActor in
                let data = Data(repeating: UInt8(index), count: 140_000 + index)
                let file = try await host.upload(fileName: "frame-\(index).jpg", mimeType: "image/jpeg", data: data)
                #expect(await transport.contents(file.id) == data)
            }
        }
        for job in jobs { try await job.value }
        #expect(await transport.violations.isEmpty)
        await connection.close()
    }

    @Test @MainActor func cancellingDuringHeaderStopsBodyAndReleasesWaiter() async throws {
        let transport = UploadTransport(headerDelay: .seconds(30))
        let (host, connection) = try await connected(transport)
        let upload = Task { try await host.upload(fileName: "cancel.jpg", mimeType: "image/jpeg", data: Data([1, 2])) }
        await transport.waitForHeader()
        upload.cancel()
        await #expect(throws: CancellationError.self) { try await upload.value }
        #expect(await transport.binaryCount == 0)
        #expect(await !connection.isClosed)
        await connection.close()
    }

    @Test @MainActor func bodySendFailureIsReportedWithoutWaitingForUploadTimeout() async throws {
        let transport = UploadTransport(failBody: true)
        let (host, connection) = try await connected(transport)
        await #expect(throws: URLError.self) {
            try await host.upload(fileName: "failure.jpg", mimeType: "image/jpeg", data: Data([1]))
        }
        #expect(await transport.binaryCount == 1)
        await connection.close()
    }

    @Test @MainActor func timedOutRequestDoesNotSendItsBodyLater() async throws {
        let transport = UploadTransport(headerDelay: .seconds(30))
        let (_, connection) = try await connected(transport)
        await #expect(throws: DaemonConnectionError.self) {
            try await connection.request("file.upload.request", timeout: .milliseconds(20), afterSend: {
                try await connection.sendBinary(Data([0x10]))
            })
        }
        #expect(await transport.binaryCount == 0)
        await connection.close()
    }

    @MainActor private func connected(_ transport: UploadTransport) async throws -> (HostStore, DaemonConnection) {
        let connection = DaemonConnection(channel: transport)
        try await connection.handshake(hello: HelloOptions(clientId: "test"), expectedServerId: "test")
        let host = HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "test", clientId: "test", appVersion: "test")
        host.connection = connection
        return (host, connection)
    }
}

/// Intentionally suspends JSON delivery beyond the old 30 ms sleep. Binary sends can overtake it
/// unless the caller actually awaits the header. No network, real host or uploaded files are used.
private actor UploadTransport: FrameTransport {
    private struct Upload {
        let request: JSONValue
        var started = false
        var data = Data()
    }
    let headerDelay: Duration
    let failBody: Bool
    private var uploads: [String: Upload] = [:]
    private var incoming: [WireFrame] = []
    private var receiver: CheckedContinuation<WireFrame, Error>?
    private var closed = false
    private let headers: AsyncStream<Void>
    private let headerSink: AsyncStream<Void>.Continuation
    private(set) var violations: [String] = []
    private(set) var binaryCount = 0

    init(headerDelay: Duration = .zero, failBody: Bool = false) {
        self.headerDelay = headerDelay; self.failBody = failBody
        (headers, headerSink) = AsyncStream.makeStream(of: Void.self)
    }

    func send(_ frame: WireFrame) async throws {
        switch frame {
        case .text(let text):
            let envelope = try JSONValue.parse(text)
            if envelope["type"]?.stringValue == "hello" {
                deliver(["type": "status", "payload": ["status": "server_info", "serverId": "test"]])
                return
            }
            guard let request = envelope["message"], request["type"]?.stringValue == "file.upload.request" else { return }
            headerSink.yield(())
            try await Task.sleep(for: headerDelay)
            let id = request["requestId"]!.stringValue!
            uploads[id] = Upload(request: request)
        case .binary(let data):
            binaryCount += 1
            if failBody { throw URLError(.networkConnectionLost) }
            let bytes = [UInt8](data)
            guard bytes.count >= 2, bytes.count >= 2 + Int(bytes[1]) else { throw URLError(.badServerResponse) }
            let id = String(decoding: bytes[2..<2 + Int(bytes[1])], as: UTF8.self)
            guard var upload = uploads[id] else {
                violations.append("Binary arrived before JSON request")
                deliver(["type": "file.upload.response", "payload": ["requestId": .string(id), "error": "Upload chunks arrived before file begin."]])
                return
            }
            let body = Array(bytes.dropFirst(2 + Int(bytes[1])))
            switch bytes[0] {
            case 0x10:
                let length = Int(body[0]) << 8 | Int(body[1])
                #expect(body.count == length + 2)
                let meta = try JSONValue.parse(String(decoding: body.dropFirst(2), as: UTF8.self))
                #expect(meta["fileName"] == upload.request["fileName"])
                #expect(meta["size"] == upload.request["size"])
                upload.started = true
            case 0x11:
                if !upload.started { violations.append("Chunk arrived before begin") }
                upload.data.append(contentsOf: body)
            case 0x12:
                #expect(upload.started)
                #expect(Double(upload.data.count) == upload.request["size"]?.doubleValue)
                deliver(["type": "file.upload.response", "payload": ["requestId": .string(id), "error": .null,
                    "file": ["id": .string(id), "fileName": upload.request["fileName"]!, "type": "uploaded_file"]]])
            default: Issue.record("Unexpected upload opcode")
            }
            uploads[id] = upload
        }
    }

    func contents(_ id: String) -> Data? { uploads[id]?.data }
    func waitForHeader() async { for await _ in headers { return } }
    func receive() async throws -> WireFrame {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw TransportClosed(code: 1000, reason: "test closed") }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close(code: Int, reason: String) async {
        closed = true
        receiver?.resume(throwing: TransportClosed(code: code, reason: reason)); receiver = nil
        headerSink.finish()
    }
    private func deliver(_ message: JSONValue) {
        let frame = WireFrame.text(try! JSONValue.object(["type": "session", "message": message]).serialized())
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { incoming.append(frame) }
    }
}
