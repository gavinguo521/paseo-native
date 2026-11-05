// Ported from vendor/paseo/packages/relay/src/protected-records.test.ts (v0.14.0).

import Foundation
import Testing
@testable import PaseoKit

private func pair() -> (sender: CipherState, receiver: CipherState) {
    let k = Data((1...32).map { UInt8($0) })
    return (CipherState(key: k), CipherState(key: k))
}

private func frameOf(_ length: Int) -> Data {
    Data((0..<length).map { UInt8(($0 * 7 + 3) & 0xff) })
}

private func reencrypt(_ sender: inout CipherState, _ plaintext: Data) throws -> Data {
    let ct = try sender.encrypt(ad: Data(), plaintext: plaintext)
    var out = Data()
    out.appendU16(UInt16(ct.count))
    return out + ct
}

private func chunkPlaintext(_ kind: UInt8, _ flags: UInt8, _ total: Int, _ data: Data) -> Data {
    var pt = Data([kind, flags])
    pt.appendU32(UInt32(total))
    return pt + data
}

private let maxChunk = ProtectedRecords.maxChunkDataBytes

@Suite struct ProtectedRecordsTests {
    @Test(arguments: [
        (FrameKind.text, 0), (.binary, 0), (.binary, 100), (.text, maxChunk),
        (.binary, maxChunk + 1), (.text, maxChunk * 3), (.binary, maxChunk * 3 + 17),
    ])
    func roundTrips(kind: FrameKind, length: Int) throws {
        var (sender, receiver) = pair()
        let frame = frameOf(length)
        let record = try ProtectedRecords.encode(kind: kind, frame: frame, sender: &sender)
        #expect(record.count == ProtectedRecords.recordByteLength(length))
        let decoded = try ProtectedRecords.decode(record, receiver: &receiver)
        #expect(decoded == DecodedFrame(kind: kind, data: frame))
        #expect(receiver.nonce == sender.nonce)
    }

    @Test func rejectsTwoRecordsConcatenated() throws {
        var (sender, receiver) = pair()
        let a = try ProtectedRecords.encode(kind: .text, frame: frameOf(10), sender: &sender)
        let b = try ProtectedRecords.encode(kind: .text, frame: frameOf(10), sender: &sender)
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(a + b, receiver: &receiver) }
    }

    @Test func rejectsMultiChunkRecordSplitAcrossMessages() throws {
        var (sender, receiver) = pair()
        let record = try ProtectedRecords.encode(kind: .binary, frame: frameOf(maxChunk + 5), sender: &sender)
        let firstChunkLength = 2 + (Int(record[0]) << 8 | Int(record[1]))
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(record.prefix(firstChunkLength), receiver: &receiver) }
    }

    @Test func rejectsZeroChunksAndTrailingBytes() throws {
        var (sender, receiver) = pair()
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(Data(), receiver: &receiver) }
        let record = try ProtectedRecords.encode(kind: .text, frame: frameOf(3), sender: &sender)
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(record + Data([0]), receiver: &receiver) }
    }

    @Test func rejectsExtraEmptyFinalChunkAfterExactMultiple() throws {
        var (sender, receiver) = pair()
        let forged = try reencrypt(&sender, chunkPlaintext(0x00, 0x01, maxChunk, frameOf(maxChunk)))
            + reencrypt(&sender, chunkPlaintext(0x00, 0x02, maxChunk, Data()))
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(forged, receiver: &receiver) }
    }

    @Test func rejectsReservedFlagsInvalidKindAndChangedHeaders() throws {
        let cases: [[Data]] = [
            [chunkPlaintext(0x00, 0x01 | 0x02 | 0x04, 1, Data([1]))],
            [chunkPlaintext(0x02, 0x03, 1, Data([1]))],
            [chunkPlaintext(0x00, 0x01, maxChunk + 1, frameOf(maxChunk)), chunkPlaintext(0x01, 0x02, maxChunk + 1, Data([1]))],
            [chunkPlaintext(0x00, 0x01, maxChunk + 1, frameOf(maxChunk)), chunkPlaintext(0x00, 0x02, maxChunk + 2, Data([1, 2]))],
        ]
        for plaintexts in cases {
            var (sender, receiver) = pair()
            var forged = Data()
            for pt in plaintexts { forged += try reencrypt(&sender, pt) }
            #expect(throws: NoiseError.self) { try ProtectedRecords.decode(forged, receiver: &receiver) }
        }
    }

    @Test func rejectsTamperedChunkWithoutAdvancing() throws {
        var (sender, receiver) = pair()
        var record = try ProtectedRecords.encode(kind: .binary, frame: frameOf(maxChunk + 5), sender: &sender)
        record[2 + 10] ^= 0x01
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(record, receiver: &receiver) }
        #expect(receiver.nonce == 0)
    }

    @Test func rejectsOverclaimedLengthBeforeAllocating() throws {
        var (sender, receiver) = pair()
        let forged = try reencrypt(&sender, chunkPlaintext(0x01, 0x01, 64 * 1024 * 1024, Data([1])))
        #expect(throws: NoiseError("record length mismatch")) { try ProtectedRecords.decode(forged, receiver: &receiver) }

        var (s2, r2) = pair()
        let genuine = try ProtectedRecords.encode(kind: .binary, frame: frameOf(maxChunk * 2 + 1), sender: &s2)
        let firstChunkOnly = genuine.prefix(2 + 6 + maxChunk + 16)
        #expect(throws: NoiseError("record length mismatch")) { try ProtectedRecords.decode(firstChunkOnly, receiver: &r2) }
        #expect(r2.nonce == 1)
    }

    @Test func recordDeliveredTwiceFailsSecondTime() throws {
        var (sender, receiver) = pair()
        let record = try ProtectedRecords.encode(kind: .text, frame: frameOf(20), sender: &sender)
        _ = try ProtectedRecords.decode(record, receiver: &receiver)
        #expect(throws: NoiseError.self) { try ProtectedRecords.decode(record, receiver: &receiver) }
    }
}
