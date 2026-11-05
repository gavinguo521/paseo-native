// Ported from vendor/paseo/packages/relay/src/noise/noise.test.ts (v0.14.0).

import CryptoKit
import Foundation
import Testing
@testable import PaseoKit

private struct VectorFile: Decodable {
    struct Message: Decodable { let payload: String; let ciphertext: String }
    struct Vector: Decodable {
        let name: String
        let init_prologue: String
        let init_ephemeral: String
        let init_remote_static: String
        let resp_prologue: String
        let resp_static: String
        let resp_ephemeral: String
        let messages: [Message]
        let handshake_hash: String?
        let source: String
    }
    let vectors: [Vector]
}

private func loadVectors() throws -> [VectorFile.Vector] {
    let url = try #require(Bundle.module.url(forResource: "nk-25519-chachapoly-sha256", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).vectors
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    try .init(rawRepresentation: Data(hex: hex))
}

private func completedPair(prologue: Data = Data("test".utf8)) throws -> (client: NoiseTransportKeys, server: NoiseTransportKeys) {
    let daemon = Curve25519.KeyAgreement.PrivateKey()
    var initiator = try NoiseHandshake.initiator(remoteStatic: daemon.publicKey.rawRepresentation, prologue: prologue)
    var responder = NoiseHandshake.responder(localStatic: daemon, prologue: prologue)
    _ = try responder.readMessage(initiator.writeMessage(Data()))
    _ = try initiator.readMessage(responder.writeMessage(Data()))
    return (try initiator.split(), try responder.split())
}

@Suite struct NoiseTests {
    @Test func protocolNameIsExactlyHashLength() {
        #expect(Noise.protocolName.utf8.count == 32)
    }

    @Test func matchesNoiseCVectors() throws {
        let vectors = try loadVectors()
        #expect(vectors.count == 2)
        for v in vectors {
            #expect(v.name == Noise.protocolName)
            let respStatic = try key(v.resp_static)
            #expect(respStatic.publicKey.rawRepresentation.hex == v.init_remote_static)

            var initiator = try NoiseHandshake.initiator(
                remoteStatic: Data(hex: v.init_remote_static), prologue: Data(hex: v.init_prologue), ephemeral: key(v.init_ephemeral))
            var responder = NoiseHandshake.responder(
                localStatic: respStatic, prologue: Data(hex: v.resp_prologue), ephemeral: try key(v.resp_ephemeral))

            let m1 = v.messages[0], m2 = v.messages[1]
            let msg1 = try initiator.writeMessage(Data(hex: m1.payload))
            #expect(msg1.hex == m1.ciphertext, "\(v.source) msg1")
            #expect(try responder.readMessage(msg1).hex == m1.payload)
            let msg2 = try responder.writeMessage(Data(hex: m2.payload))
            #expect(msg2.hex == m2.ciphertext, "\(v.source) msg2")
            #expect(try initiator.readMessage(msg2).hex == m2.payload)
            #expect(initiator.isComplete && responder.isComplete)
            if let hh = v.handshake_hash {
                #expect(initiator.handshakeHash.hex == hh)
                #expect(responder.handshakeHash.hex == hh)
            }

            var ik = try initiator.split()
            var rk = try responder.split()
            for (index, m) in v.messages.dropFirst(2).enumerated() {
                let ct: Data
                let pt: Data
                if index % 2 == 0 {
                    ct = try ik.send.encrypt(ad: Data(), plaintext: Data(hex: m.payload))
                    pt = try rk.receive.decrypt(ad: Data(), ciphertext: ct)
                } else {
                    ct = try rk.send.encrypt(ad: Data(), plaintext: Data(hex: m.payload))
                    pt = try ik.receive.decrypt(ad: Data(), ciphertext: ct)
                }
                #expect(ct.hex == m.ciphertext, "\(v.source) transport \(index)")
                #expect(pt.hex == m.payload)
            }
        }
    }

    @Test func rejectsReplayedReflectedAndOutOfOrderMessages() throws {
        var (client, server) = try completedPair()
        let first = try client.send.encrypt(ad: Data(), plaintext: Data([1]))
        let second = try client.send.encrypt(ad: Data(), plaintext: Data([2]))
        #expect(try server.receive.decrypt(ad: Data(), ciphertext: first) == Data([1]))
        #expect(throws: NoiseError.self) { try server.receive.decrypt(ad: Data(), ciphertext: first) }
        // A failed attempt did not advance the counter.
        #expect(try server.receive.decrypt(ad: Data(), ciphertext: second) == Data([2]))
        // Reflection: the client's own record handed back to it.
        #expect(throws: NoiseError.self) { try client.receive.decrypt(ad: Data(), ciphertext: second) }
        let third = try client.send.encrypt(ad: Data(), plaintext: Data([3]))
        let fourth = try client.send.encrypt(ad: Data(), plaintext: Data([4]))
        #expect(throws: NoiseError.self) { try server.receive.decrypt(ad: Data(), ciphertext: fourth) }
        #expect(try server.receive.decrypt(ad: Data(), ciphertext: third) == Data([3]))
        #expect(try server.receive.decrypt(ad: Data(), ciphertext: fourth) == Data([4]))
    }

    @Test func recordedFirstMessageCannotDeriveKeysOfFreshResponder() throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let prologue = Data("test".utf8)
        var initiator = try NoiseHandshake.initiator(remoteStatic: daemon.publicKey.rawRepresentation, prologue: prologue)
        let msg1 = try initiator.writeMessage(Data())
        var original = NoiseHandshake.responder(localStatic: daemon, prologue: prologue)
        _ = try original.readMessage(msg1)
        _ = try initiator.readMessage(original.writeMessage(Data()))
        var clientKeys = try initiator.split()
        let record = try clientKeys.send.encrypt(ad: Data(), plaintext: Data([7]))

        var replay = NoiseHandshake.responder(localStatic: daemon, prologue: prologue)
        _ = try replay.readMessage(msg1)
        _ = try replay.writeMessage(Data())
        var replayKeys = try replay.split()
        #expect(throws: NoiseError.self) { try replayKeys.receive.decrypt(ad: Data(), ciphertext: record) }
    }

    @Test func rejectsLowOrderEphemeralAndWrongResponderKey() throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let prologue = Data("test".utf8)
        var responder = NoiseHandshake.responder(localStatic: daemon, prologue: prologue)
        #expect(throws: NoiseError.self) { try responder.readMessage(Data(count: 48)) }

        let other = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseHandshake.initiator(remoteStatic: other.publicKey.rawRepresentation, prologue: prologue)
        var victim = NoiseHandshake.responder(localStatic: daemon, prologue: prologue)
        let msg1 = try initiator.writeMessage(Data())
        #expect(throws: NoiseError.self) { try victim.readMessage(msg1) }
    }

    @Test func stopsAtLastNonceAndKeepsStateOnFailedTag() throws {
        let max = UInt64.max
        let k = Data((1...32).map { UInt8($0) })
        var sender = CipherState(key: k, nonce: max - 1)
        var receiver = CipherState(key: k, nonce: max - 1)
        let last = try sender.encrypt(ad: Data(), plaintext: Data([1, 2, 3]))
        #expect(sender.nonce == max)
        #expect(throws: NoiseError("nonce exhausted")) { try sender.encrypt(ad: Data(), plaintext: Data([4])) }
        #expect(sender.nonce == max)

        var tampered = last
        tampered[tampered.startIndex] ^= 1
        #expect(throws: NoiseError("authentication failed")) { try receiver.decrypt(ad: Data(), ciphertext: tampered) }
        #expect(receiver.nonce == max - 1)
        #expect(try receiver.decrypt(ad: Data(), ciphertext: last) == Data([1, 2, 3]))
        #expect(receiver.nonce == max)
        #expect(throws: NoiseError("nonce exhausted")) { try receiver.decrypt(ad: Data(), ciphertext: last) }
    }

    @Test func refusesToProceedOutOfTurnOrAfterCompletion() throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseHandshake.initiator(remoteStatic: daemon.publicKey.rawRepresentation, prologue: Data())
        var responder = NoiseHandshake.responder(localStatic: daemon, prologue: Data())
        #expect(throws: NoiseError.self) { try responder.writeMessage(Data()) }
        #expect(throws: NoiseError.self) { try initiator.split() }
        _ = try responder.readMessage(initiator.writeMessage(Data()))
        #expect(throws: NoiseError.self) { try initiator.writeMessage(Data()) }
        _ = try initiator.readMessage(responder.writeMessage(Data()))
        #expect(throws: NoiseError.self) { try initiator.readMessage(Data(count: 48)) }
        _ = try initiator.split()
        #expect(throws: NoiseError.self) { try initiator.split() }
    }

    @Test func paseoHandshakeMessagesAreFiftyBytes() throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let prologue = Data("paseo-relay-e2ee/1".utf8)
        var initiator = try NoiseHandshake.initiator(remoteStatic: daemon.publicKey.rawRepresentation, prologue: prologue)
        var responder = NoiseHandshake.responder(localStatic: daemon, prologue: prologue)
        let msg1 = try initiator.writeMessage(Data([0x01, 0x01]))
        #expect(msg1.count == 50)
        #expect(try responder.readMessage(msg1) == Data([0x01, 0x01]))
        let msg2 = try responder.writeMessage(Data([0x01, 0x01]))
        #expect(msg2.count == 50)
        #expect(try initiator.readMessage(msg2) == Data([0x01, 0x01]))
    }
}
