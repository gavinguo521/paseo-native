// Relay E2EE channel, protected mode only (daemons ≥ v0.13.0).
// Mirrors the client half of vendor/paseo/packages/relay/src/secure-channel.ts (v0.14.0). See docs/protocol/01-connection.md §3.5–3.7.

import CryptoKit
import Foundation

public struct SecureChannelError: Error, CustomStringConvertible {
    /// Client-side close code: 4002 handshake/security failure, 4003 record failure.
    public let closeCode: Int
    public let description: String
}

public actor SecureChannel {
    public static let prologue = Data("paseo-relay-e2ee/1".utf8)
    static let paramsVersion: UInt8 = 0x01
    static let flagBinaryCiphertext: UInt8 = 0x01

    private let transport: FrameTransport
    private var keys: NoiseTransportKeys
    /// Negotiated in the handshake. Only binary payloads (file transfer, terminal frames) go out as binary WebSocket
    /// frames; the daemon base64-encodes text (JSON) records either way (relay/src/secure-channel.ts `send`).
    public nonisolated let binaryCiphertext: Bool
    private var failed = false

    private init(transport: FrameTransport, keys: NoiseTransportKeys, binaryCiphertext: Bool) {
        self.transport = transport
        self.keys = keys
        self.binaryCiphertext = binaryCiphertext
    }

    /// Runs the NK handshake over an already-open transport. The hello is serialized once and resent
    /// byte-for-byte every second until the daemon answers; a differing resend would be rejected.
    public static func open(
        transport: FrameTransport,
        daemonPublicKey: Data,
        offerBinaryCiphertext: Bool = true,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) async throws -> SecureChannel {
        let offeredFlags: UInt8 = offerBinaryCiphertext ? flagBinaryCiphertext : 0
        var handshake = try NoiseHandshake.initiator(remoteStatic: daemonPublicKey, prologue: prologue, ephemeral: ephemeral)
        let msg1 = try handshake.writeMessage(Data([paramsVersion, offeredFlags]))
        // `key` is a separate X25519 key for the legacy path; the daemon requires it even in protected mode.
        let legacyKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let hello = #"{"type":"e2ee_hello","key":"\#(legacyKey)","capabilities":{"binaryCiphertext":\#(offerBinaryCiphertext)},"protected":{"v":1,"message":"\#(msg1.base64EncodedString())"}}"#

        let resend = Task {
            while !Task.isCancelled {
                try? await transport.send(.text(hello))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { resend.cancel() }

        while true {
            guard case .text(let text) = try await transport.receive(),
                  let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  envelope["type"] as? String == "e2ee_ready"
            else { continue }
            guard let prot = envelope["protected"] as? [String: Any] else {
                throw await fail(transport, 4002, "daemon offered only legacy E2EE; protected mode is required")
            }
            guard prot["v"] as? Int == 1, let b64 = prot["message"] as? String, let msg2 = decodeBase64(b64) else {
                throw await fail(transport, 4002, "malformed protected handshake reply")
            }
            let params: Data
            do {
                params = try handshake.readMessage(msg2)
            } catch {
                throw await fail(transport, 4002, "handshake failed: \(error)")
            }
            let p = [UInt8](params)
            guard p.count == 2, p[0] == paramsVersion, p[1] & ~flagBinaryCiphertext == 0, p[1] & ~offeredFlags == 0 else {
                throw await fail(transport, 4002, "invalid handshake parameters")
            }
            let keys = try handshake.split()
            return SecureChannel(transport: transport, keys: keys, binaryCiphertext: p[1] & flagBinaryCiphertext != 0)
        }
    }

    public func send(_ frame: WireFrame) async throws {
        guard !failed else { throw SecureChannelError(closeCode: 4003, description: "channel failed") }
        let record: Data
        let binary: Bool
        switch frame {
        case .text(let s):
            record = try ProtectedRecords.encode(kind: .text, frame: Data(s.utf8), sender: &keys.send)
            binary = false
        case .binary(let d):
            record = try ProtectedRecords.encode(kind: .binary, frame: d, sender: &keys.send)
            binary = binaryCiphertext
        }
        try await transport.send(binary ? .binary(record) : .text(record.base64EncodedString()))
    }

    public func receive() async throws -> WireFrame {
        guard !failed else { throw SecureChannelError(closeCode: 4003, description: "channel failed") }
        while true {
            let record: Data
            switch try await transport.receive() {
            case .binary(let d):
                record = d
            case .text(let text):
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                    let type = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String
                    if type == "e2ee_ready" || type == "e2ee_hello" { continue }
                    throw await poison("plaintext JSON on an encrypted channel")
                }
                guard let d = Self.decodeBase64(text) else { throw await poison("record is not base64") }
                record = d
            }
            let frame: DecodedFrame
            do {
                frame = try ProtectedRecords.decode(record, receiver: &keys.receive)
            } catch {
                throw await poison("record rejected: \(error)")
            }
            switch frame.kind {
            case .binary:
                return .binary(frame.data)
            case .text:
                guard let s = String(data: frame.data, encoding: .utf8) else { throw await poison("invalid UTF-8 text frame") }
                return .text(s)
            }
        }
    }

    public func close(code: Int = 1000, reason: String = "") async {
        await transport.close(code: code, reason: reason)
    }

    private func poison(_ message: String) async -> SecureChannelError {
        failed = true
        keys = NoiseTransportKeys(send: CipherState(), receive: CipherState())
        return await Self.fail(transport, 4003, message)
    }

    private static func fail(_ transport: FrameTransport, _ code: Int, _ message: String) async -> SecureChannelError {
        await transport.close(code: code, reason: message)
        return SecureChannelError(closeCode: code, description: message)
    }

    /// Standard base64, tolerating URL-safe characters and missing padding (as the daemon does).
    static func decodeBase64(_ s: String) -> Data? {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}

/// The daemon connection treats the E2EE channel like any other message socket.
extension SecureChannel: FrameTransport {}
