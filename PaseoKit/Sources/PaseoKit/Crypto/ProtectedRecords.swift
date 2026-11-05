// Authenticated framing of app frames over Noise transport messages.
// Mirrors vendor/paseo/packages/relay/src/protected-records.ts (v0.14.0). See docs/protocol/01-connection.md §3.6.
//
//   chunk plaintext = kind(1) || flags(1) || totalLength(u32 BE) || data
//   wire record     = for each chunk: ciphertextLength(u16 BE) || ciphertext

import Foundation

public enum FrameKind: UInt8, Sendable {
    case text = 0x00
    case binary = 0x01
}

public struct DecodedFrame: Equatable, Sendable {
    public let kind: FrameKind
    public let data: Data
}

public enum ProtectedRecords {
    static let flagFirst: UInt8 = 0x01
    static let flagFinal: UInt8 = 0x02
    static let headerBytes = 6
    static let lengthPrefixBytes = 2

    public static let maxChunkDataBytes = Noise.maxMessageBytes - Noise.tagBytes - headerBytes
    public static let maxFrameBytes = Int(UInt32.max)
    static let chunkOverheadBytes = lengthPrefixBytes + headerBytes + Noise.tagBytes

    public static func chunkCount(_ frameBytes: Int) -> Int {
        max(1, (frameBytes + maxChunkDataBytes - 1) / maxChunkDataBytes)
    }

    public static func recordByteLength(_ frameBytes: Int) -> Int {
        frameBytes + chunkCount(frameBytes) * chunkOverheadBytes
    }

    public static func encode(kind: FrameKind, frame: Data, sender: inout CipherState) throws -> Data {
        guard frame.count <= maxFrameBytes else { throw NoiseError("frame too large") }
        let chunks = chunkCount(frame.count)
        var out = Data(capacity: recordByteLength(frame.count))
        for index in 0..<chunks {
            let start = frame.startIndex + index * maxChunkDataBytes
            let end = min(frame.endIndex, start + maxChunkDataBytes)
            var plaintext = Data(capacity: headerBytes + (end - start))
            plaintext.append(kind.rawValue)
            plaintext.append((index == 0 ? flagFirst : 0) | (index == chunks - 1 ? flagFinal : 0))
            plaintext.appendU32(UInt32(frame.count))
            plaintext.append(frame[start..<end])
            let ciphertext = try sender.encrypt(ad: Data(), plaintext: plaintext)
            out.appendU16(UInt16(ciphertext.count))
            out.append(ciphertext)
        }
        return out
    }

    /// Decodes one wire record. On any error the caller must close the channel: the receive
    /// counter may already have advanced past the authenticated chunks.
    public static func decode(_ record: Data, receiver: inout CipherState) throws -> DecodedFrame {
        let bytes = [UInt8](record)
        var offset = 0
        var kind: FrameKind?
        var totalLength = 0
        var expectedChunks = 0
        var frame = Data()
        var index = 0

        while offset < bytes.count {
            if kind != nil, index >= expectedChunks { throw NoiseError("unexpected chunk after final") }
            guard bytes.count - offset >= lengthPrefixBytes else { throw NoiseError("record truncated") }
            let ciphertextLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            let start = offset + lengthPrefixBytes
            guard ciphertextLength >= Noise.tagBytes + headerBytes, ciphertextLength <= Noise.maxMessageBytes else {
                throw NoiseError("invalid chunk length")
            }
            guard bytes.count - start >= ciphertextLength else { throw NoiseError("record truncated") }
            let plaintext = [UInt8](try receiver.decrypt(ad: Data(), ciphertext: Data(bytes[start..<(start + ciphertextLength)])))
            offset = start + ciphertextLength

            let flags = plaintext[1]
            guard flags & ~(flagFirst | flagFinal) == 0 else { throw NoiseError("reserved flag set") }
            guard let chunkKind = FrameKind(rawValue: plaintext[0]) else { throw NoiseError("invalid frame kind") }
            let isFirst = flags & flagFirst != 0
            let isFinal = flags & flagFinal != 0
            let chunkTotal = Int(plaintext[2]) << 24 | Int(plaintext[3]) << 16 | Int(plaintext[4]) << 8 | Int(plaintext[5])
            let data = plaintext[headerBytes...]

            if let kind {
                guard !isFirst else { throw NoiseError("FIRST repeated inside record") }
                guard chunkKind == kind else { throw NoiseError("frame kind changed inside record") }
                guard chunkTotal == totalLength else { throw NoiseError("frame length changed inside record") }
            } else {
                guard isFirst else { throw NoiseError("record does not start with FIRST") }
                // The claimed length fixes the exact wire length; check before allocating.
                guard recordByteLength(chunkTotal) == bytes.count else { throw NoiseError("record length mismatch") }
                kind = chunkKind
                totalLength = chunkTotal
                expectedChunks = chunkCount(chunkTotal)
                frame.reserveCapacity(chunkTotal)
            }

            let isLastExpected = index == expectedChunks - 1
            guard isFinal == isLastExpected else { throw NoiseError("FINAL flag mismatch") }
            let expectedData = isLastExpected ? totalLength - index * maxChunkDataBytes : maxChunkDataBytes
            guard data.count == expectedData else { throw NoiseError("chunk size mismatch") }
            frame.append(contentsOf: data)
            index += 1
        }

        guard let kind else { throw NoiseError("empty record") }
        guard index == expectedChunks, frame.count == totalLength else { throw NoiseError("record incomplete") }
        return DecodedFrame(kind: kind, data: frame)
    }
}

extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
