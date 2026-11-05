// Receive side of `binary_chunking_v1` (protocol/src/chunked-transport.ts, docs/protocol-compatibility.md):
// a logical message larger than one relay frame arrives as binary frames [0x31, version 1, kind, flags, slice…]
// with kind 0 = text / 1 = binary and flags bit 0 = START, bit 1 = END. Slices are joined in order and the
// original frame is delivered after END. It sits above the encryption and below message parsing.
// We never chunk outbound frames (our messages are small), like the official native app.

import Foundation

public struct ChunkingError: Error, CustomStringConvertible {
    public let description: String
}

public final class ChunkedReceiver: FrameTransport, @unchecked Sendable {
    static let opcode: UInt8 = 0x31
    static let maxBytes = 100 * 1024 * 1024

    private let inner: any FrameTransport
    // receive() is only ever called from the connection's single read loop.
    private var assembly: Data?
    private var kind: UInt8 = 0

    public init(_ inner: any FrameTransport) { self.inner = inner }

    public func send(_ frame: WireFrame) async throws { try await inner.send(frame) }

    public func close(code: Int, reason: String) async {
        assembly = nil
        await inner.close(code: code, reason: reason)
    }

    public func receive() async throws -> WireFrame {
        while true {
            if let frame = try assemble(try await inner.receive()) { return frame }
        }
    }

    /// The frame to deliver, or nil while a chunked message is incomplete. Throws on a malformed sequence.
    func assemble(_ frame: WireFrame) throws -> WireFrame? {
        guard case .binary(let data) = frame, data.first == Self.opcode else {
            if assembly != nil { throw ChunkingError(description: "Interrupted chunked message") }
            return frame
        }
        let bytes = [UInt8](data.prefix(4))
        guard data.count > 4, bytes[1] == 1, bytes[2] <= 1, bytes[3] & ~3 == 0 else {
            throw ChunkingError(description: "Invalid chunk header")
        }
        let start = bytes[3] & 1 != 0, end = bytes[3] & 2 != 0
        if start == (assembly != nil) { throw ChunkingError(description: "Invalid chunk sequence") }
        if start { assembly = Data(); kind = bytes[2] }
        guard bytes[2] == kind else { throw ChunkingError(description: "Chunk kind changed") }
        assembly!.append(data.dropFirst(4))
        if assembly!.count > Self.maxBytes { throw ChunkingError(description: "Logical message too large") }
        guard end else { return nil }
        let whole = assembly!
        assembly = nil
        if kind == 0 {
            guard let text = String(data: whole, encoding: .utf8) else { throw ChunkingError(description: "Invalid UTF-8 in chunked text") }
            return .text(text)
        }
        return .binary(whole)
    }
}
