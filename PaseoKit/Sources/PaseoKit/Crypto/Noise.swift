// Noise_NK_25519_ChaChaPoly_SHA256, as used by the Paseo relay E2EE (protected mode).
// Mirrors vendor/paseo/packages/relay/src/noise/ (v0.14.0). See docs/protocol/01-connection.md §3.

import CryptoKit
import Foundation

public struct NoiseError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public enum Noise {
    public static let protocolName = "Noise_NK_25519_ChaChaPoly_SHA256"
    public static let maxMessageBytes = 65535
    public static let tagBytes = 16
    public static let dhBytes = 32
}

// MARK: - CipherState

public struct CipherState: Sendable {
    private var key: SymmetricKey?
    public private(set) var nonce: UInt64

    public init(key: Data? = nil, nonce: UInt64 = 0) {
        self.key = key.map { SymmetricKey(data: $0) }
        self.nonce = nonce
    }

    var hasKey: Bool { key != nil }

    private static func nonceBytes(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// The nonce is reserved before encrypting; 2^64-1 is never used (Noise §5.1).
    public mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard nonce != UInt64.max else { throw NoiseError("nonce exhausted") }
        let n = nonce
        nonce += 1
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonceBytes(n), authenticating: ad)
        return box.ciphertext + box.tag
    }

    /// The counter advances only when the tag verifies, so a forged or replayed message leaves state unchanged.
    public mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce != UInt64.max else { throw NoiseError("nonce exhausted") }
        guard ciphertext.count >= Noise.tagBytes else { throw NoiseError("authentication failed") }
        let split = ciphertext.count - Noise.tagBytes
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.nonceBytes(nonce),
                ciphertext: ciphertext.prefix(split),
                tag: ciphertext.suffix(Noise.tagBytes)
            )
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseError("authentication failed")
        }
        nonce += 1
        return plaintext
    }
}

// MARK: - SymmetricState

struct SymmetricState {
    private(set) var ck: Data
    private(set) var h: Data
    var cipher = CipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    mutating func mixKey(_ ikm: Data) {
        let (newCk, k) = Self.hkdf(ck, ikm)
        ck = newCk
        cipher = CipherState(key: k)
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let c = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(c)
        return c
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let p = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return p
    }

    func split() -> (CipherState, CipherState) {
        let (k1, k2) = Self.hkdf(ck, Data())
        return (CipherState(key: k1), CipherState(key: k2))
    }

    static func hkdf(_ chainingKey: Data, _ ikm: Data) -> (Data, Data) {
        let temp = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: chainingKey))))
        let out1 = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: temp))
        let out2 = Data(HMAC<SHA256>.authenticationCode(for: out1 + Data([0x02]), using: temp))
        return (out1, out2)
    }
}

// MARK: - Handshake

public struct NoiseTransportKeys: Sendable {
    public var send: CipherState
    public var receive: CipherState
}

func x25519(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Data) throws -> Data {
    guard pub.count == Noise.dhBytes else { throw NoiseError("invalid DH public key") }
    let shared: Data
    do {
        let secret = try priv.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: pub))
        shared = secret.withUnsafeBytes { Data($0) }
    } catch {
        throw NoiseError("invalid DH public key")
    }
    guard shared.contains(where: { $0 != 0 }) else { throw NoiseError("invalid DH public key") }
    return shared
}

/// NK handshake: `<- s`, `...`, `-> e, es`, `<- e, ee`.
public struct NoiseHandshake {
    public enum Role { case initiator, responder }
    private enum Step { case writeFirst, readFirst, writeSecond, readSecond, complete, split }

    public let role: Role
    private var symmetric: SymmetricState
    private var step: Step
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let localStatic: Curve25519.KeyAgreement.PrivateKey?
    private let remoteStatic: Data?
    private var remoteEphemeral: Data?

    /// Client side: `remoteStatic` is the daemon public key from the pairing offer.
    public static func initiator(
        remoteStatic: Data, prologue: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws -> NoiseHandshake {
        guard remoteStatic.count == Noise.dhBytes else { throw NoiseError("invalid remote static key") }
        return NoiseHandshake(role: .initiator, prologue: prologue, ephemeral: ephemeral, localStatic: nil, remoteStatic: remoteStatic)
    }

    /// Daemon side; used by tests to exercise the client against a real peer.
    public static func responder(
        localStatic: Curve25519.KeyAgreement.PrivateKey, prologue: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) -> NoiseHandshake {
        NoiseHandshake(role: .responder, prologue: prologue, ephemeral: ephemeral, localStatic: localStatic, remoteStatic: nil)
    }

    private init(role: Role, prologue: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey,
                 localStatic: Curve25519.KeyAgreement.PrivateKey?, remoteStatic: Data?) {
        self.role = role
        self.ephemeral = ephemeral
        self.localStatic = localStatic
        self.remoteStatic = remoteStatic
        symmetric = SymmetricState(protocolName: Noise.protocolName)
        symmetric.mixHash(prologue)
        symmetric.mixHash(remoteStatic ?? localStatic!.publicKey.rawRepresentation)
        step = role == .initiator ? .writeFirst : .readFirst
    }

    public var isComplete: Bool { step == .complete || step == .split }
    public var handshakeHash: Data { symmetric.h }

    public mutating func writeMessage(_ payload: Data) throws -> Data {
        let e = ephemeral.publicKey.rawRepresentation
        switch step {
        case .writeFirst:
            symmetric.mixHash(e)
            symmetric.mixKey(try x25519(ephemeral, remoteStatic!))
            let c = try symmetric.encryptAndHash(payload)
            step = .readSecond
            return e + c
        case .writeSecond:
            symmetric.mixHash(e)
            symmetric.mixKey(try x25519(ephemeral, remoteEphemeral!))
            let c = try symmetric.encryptAndHash(payload)
            step = .complete
            return e + c
        default:
            throw NoiseError("handshake message out of order")
        }
    }

    public mutating func readMessage(_ message: Data) throws -> Data {
        guard step == .readFirst || step == .readSecond else { throw NoiseError("handshake message out of order") }
        guard message.count >= Noise.dhBytes + Noise.tagBytes, message.count <= Noise.maxMessageBytes else {
            throw NoiseError("invalid handshake message length")
        }
        let re = Data(message.prefix(Noise.dhBytes))
        let body = Data(message.dropFirst(Noise.dhBytes))
        // Work on a copy so a failed message leaves the handshake untouched.
        var next = symmetric
        next.mixHash(re)
        if step == .readFirst {
            next.mixKey(try x25519(localStatic!, re))
        } else {
            next.mixKey(try x25519(ephemeral, re))
        }
        let payload = try next.decryptAndHash(body)
        symmetric = next
        remoteEphemeral = re
        step = step == .readFirst ? .writeSecond : .complete
        return payload
    }

    public mutating func split() throws -> NoiseTransportKeys {
        guard step == .complete else { throw NoiseError("handshake not complete") }
        step = .split
        let (c1, c2) = symmetric.split()
        return role == .initiator ? NoiseTransportKeys(send: c1, receive: c2) : NoiseTransportKeys(send: c2, receive: c1)
    }
}
