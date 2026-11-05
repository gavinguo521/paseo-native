import Foundation
import Testing
@testable import PaseoKit

struct ChunkedReceiverTests {
    private func chunk(_ kind: UInt8, _ flags: UInt8, _ bytes: [UInt8]) -> WireFrame {
        .binary(Data([0x31, 1, kind, flags] + bytes))
    }

    private struct Silent: FrameTransport {
        func send(_ frame: WireFrame) async throws {}
        func receive() async throws -> WireFrame { throw TransportClosed(code: 1000, reason: "") }
        func close(code: Int, reason: String) async {}
    }

    @Test func reassemblesTextAcrossChunks() throws {
        let r = ChunkedReceiver(Silent())
        let text = Array(#"{"type":"session","message":{"big":"数据"}}"#.utf8)
        #expect(try r.assemble(chunk(0, 1, Array(text[0..<10]))) == nil)
        #expect(try r.assemble(chunk(0, 0, Array(text[10..<20]))) == nil)
        #expect(try r.assemble(chunk(0, 2, Array(text[20...]))) == .text(String(decoding: text, as: UTF8.self)))
    }

    @Test func singleChunkBinaryAndPassThrough() throws {
        let r = ChunkedReceiver(Silent())
        #expect(try r.assemble(chunk(1, 3, [0x10, 7, 8])) == .binary(Data([0x10, 7, 8])))
        #expect(try r.assemble(.text("plain")) == .text("plain"))
        #expect(try r.assemble(.binary(Data([0x01, 2]))) == .binary(Data([0x01, 2])))
    }

    @Test func rejectsBrokenSequences() throws {
        let r = ChunkedReceiver(Silent())
        #expect(throws: ChunkingError.self) { try r.assemble(chunk(0, 0, [1])) }          // continuation without START
        _ = try r.assemble(chunk(0, 1, [1]))
        #expect(throws: ChunkingError.self) { try r.assemble(.text("interrupt")) }      // plain frame mid-transfer
        let r2 = ChunkedReceiver(Silent())
        _ = try r2.assemble(chunk(0, 1, [1]))
        #expect(throws: ChunkingError.self) { try r2.assemble(chunk(1, 2, [2])) }        // kind changed
        let r3 = ChunkedReceiver(Silent())
        #expect(throws: ChunkingError.self) { try r3.assemble(.binary(Data([0x31, 2, 0, 3, 1]))) } // unknown version
        #expect(throws: ChunkingError.self) { try r3.assemble(.binary(Data([0x31, 1, 0, 4, 1]))) } // unknown flag bit
    }
}
