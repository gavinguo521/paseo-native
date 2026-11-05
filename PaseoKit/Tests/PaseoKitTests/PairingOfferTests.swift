import CryptoKit
import Foundation
import Testing
@testable import PaseoKit

private let pubB64 = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

private func offerUrl(_ json: String) -> String {
    let b64url = Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "https://app.paseo.sh/#offer=\(b64url)"
}

@Suite struct PairingOfferTests {
    @Test func parsesOfferUrl() throws {
        let url = offerUrl(#"{"v":2,"serverId":"srv_abc123","daemonPublicKeyB64":"\#(pubB64)","relay":{"endpoint":"relay.paseo.sh:443","useTls":true},"minimumSecurityMode":"protected"}"#)
        let offer = try PairingOffer.parse(url)
        #expect(offer.serverId == "srv_abc123")
        #expect(offer.daemonPublicKey.count == 32)
        #expect(offer.relayEndpoint == "relay.paseo.sh:443")
        #expect(offer.useTls)
        #expect(offer.requireProtected)
        #expect(offer.password == nil)
        #expect(try offer.relayWebSocketURL().absoluteString == "wss://relay.paseo.sh:443/ws?serverId=srv_abc123&role=client&v=2")
    }

    @Test func offerWithoutUseTlsFallsBackToPort443() throws {
        let a = try PairingOffer.parse(offerUrl(#"{"v":2,"serverId":"s","daemonPublicKeyB64":"\#(pubB64)","relay":{"endpoint":"relay.paseo.sh:443"}}"#))
        #expect(a.useTls)
        let b = try PairingOffer.parse(offerUrl(#"{"v":2,"serverId":"s","daemonPublicKeyB64":"\#(pubB64)","relay":{"endpoint":"10.0.0.2:8080"}}"#))
        #expect(!b.useTls)
        #expect(try b.relayWebSocketURL().absoluteString.hasPrefix("ws://10.0.0.2:8080/ws?"))
    }

    @Test func rejectsBadOffers() {
        #expect(throws: PairingError.self) { try PairingOffer.parse("https://app.paseo.sh/") }
        #expect(throws: PairingError.self) {
            try PairingOffer.parse(offerUrl(#"{"v":1,"serverId":"s","daemonPublicKeyB64":"\#(pubB64)","relay":{"endpoint":"h:1"}}"#))
        }
        #expect(throws: PairingError.self) {
            try PairingOffer.parse(offerUrl(#"{"v":2,"serverId":"s","daemonPublicKeyB64":"not-a-key","relay":{"endpoint":"h:1"}}"#))
        }
        #expect(throws: PairingError.self) {
            try PairingOffer.parse(offerUrl(#"{"v":2,"serverId":"s","daemonPublicKeyB64":"\#(pubB64)","relay":{"endpoint":"h:1"},"minimumSecurityMode":"legacy"}"#))
        }
    }

    @Test func parsesRelayUriWithPassword() throws {
        let key = pubB64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let uri = "relay://relay.paseo.sh:443/srv_abc%2Fx?key=\(key)&ssl=true&security=protected&password=s3cret"
        // serverId must not contain '/', even percent-encoded.
        #expect(throws: PairingError.self) { try PairingOffer.parse(uri) }

        let ok = try PairingOffer.parse("relay://relay.paseo.sh:443/srv_abc?key=\(key)&ssl=true&security=protected&password=s3cret")
        #expect(ok.serverId == "srv_abc")
        #expect(ok.daemonPublicKeyB64 == pubB64)
        #expect(ok.useTls && ok.requireProtected)
        #expect(ok.password == "s3cret")
    }

    @Test func parsesWrappedRelayUriAndIpv6() throws {
        let key = pubB64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let inner = "relay://[::1]:6767/srv_x?key=\(key)"
        let wrapped = "https://app.paseo.sh/#connect=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let offer = try PairingOffer.parse(wrapped)
        #expect(offer.relayEndpoint == "[::1]:6767")
        #expect(!offer.useTls)
        #expect(offer.password == nil)
        #expect(try offer.relayWebSocketURL().absoluteString.hasPrefix("ws://[::1]:6767/ws?"))
    }

    @Test func relayUriRequiresExplicitPortAndKnownSecurity() {
        #expect(throws: PairingError.self) { try PairingOffer.parse("relay://relay.paseo.sh/srv?key=\(pubB64)") }
        #expect(throws: PairingError.self) { try PairingOffer.parse("relay://relay.paseo.sh:443/srv?key=\(pubB64)&security=legacy") }
    }
}
