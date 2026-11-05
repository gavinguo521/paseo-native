// Pairing link parsing: `https://app.paseo.sh/#offer=<base64url JSON>` and
// `relay://host:port/<serverId>?key=…[&ssl=true][&security=protected][&password=…]` (optionally wrapped in `#connect=`).
// Mirrors vendor/paseo/packages/protocol/src/{connection-offer,daemon-endpoints}.ts (v0.14.0). See docs/protocol/01-connection.md §1.

import Foundation

public struct PairingError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public struct PairingOffer: Equatable, Sendable, Codable {
    public var serverId: String
    public var daemonPublicKeyB64: String
    /// `host:port`, IPv6 as `[::1]:443`.
    public var relayEndpoint: String
    public var useTls: Bool
    public var requireProtected: Bool
    /// Only the `relay://` form can carry it; the `#offer=` form needs the user to type it.
    public var password: String?
    /// Direct connection `host:port` (no relay, no E2EE; TLS per `useTls`). Set for hosts added by address.
    public var directEndpoint: String?

    public var isDirect: Bool { directEndpoint != nil }

    /// A host reached directly at `ws(s)://host:port/ws`.
    public static func direct(serverId: String, endpoint: String, useTls: Bool, password: String?) -> PairingOffer {
        PairingOffer(serverId: serverId, daemonPublicKeyB64: "", relayEndpoint: "", useTls: useTls, requireProtected: false,
                     password: password, directEndpoint: endpoint)
    }

    /// `ws(s)://host:port/ws` for direct hosts.
    public func directWebSocketURL() throws -> URL {
        guard let directEndpoint else { throw PairingError("not a direct host") }
        let (host, port, isIpv6) = try Self.parseHostPort(directEndpoint)
        var c = URLComponents()
        c.scheme = useTls ? "wss" : "ws"
        c.host = isIpv6 ? "[\(host)]" : host
        c.port = port
        c.path = "/ws"
        guard let url = c.url else { throw PairingError("invalid address") }
        return url
    }

    public var daemonPublicKey: Data { (try? Self.decodePublicKey(daemonPublicKeyB64)) ?? Data() }

    public static func parse(_ raw: String) throws -> PairingOffer {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("relay://") || s.contains("#connect=") {
            return try parseRelayUri(s)
        }
        return try parseOfferUrl(s)
    }

    /// `ws(s)://<relay>/ws?serverId=…&role=client&v=2`. The relay assigns the connection id.
    public func relayWebSocketURL() throws -> URL {
        let (host, port, isIpv6) = try Self.parseHostPort(relayEndpoint)
        var c = URLComponents()
        c.scheme = useTls ? "wss" : "ws"
        c.host = isIpv6 ? "[\(host)]" : host
        c.port = port
        c.path = "/ws"
        c.queryItems = [
            URLQueryItem(name: "serverId", value: serverId),
            URLQueryItem(name: "role", value: "client"),
            URLQueryItem(name: "v", value: "2"),
        ]
        guard let url = c.url else { throw PairingError("invalid relay endpoint") }
        return url
    }

    // MARK: Offer URL

    private struct OfferJSON: Decodable {
        struct Relay: Decodable { let endpoint: String; let useTls: Bool? }
        let v: Int
        let serverId: String
        let daemonPublicKeyB64: String
        let relay: Relay
        let minimumSecurityMode: String?
    }

    static func parseOfferUrl(_ s: String) throws -> PairingOffer {
        guard let r = s.range(of: "#offer=") else { throw PairingError("not a pairing link") }
        var b64 = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !b64.isEmpty else { throw PairingError("empty offer") }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), String(data: data, encoding: .utf8) != nil else {
            throw PairingError("offer is not valid base64url UTF-8")
        }
        let offer: OfferJSON
        do {
            offer = try JSONDecoder().decode(OfferJSON.self, from: data)
        } catch {
            throw PairingError("offer JSON is malformed")
        }
        guard offer.v == 2 else { throw PairingError("unsupported offer version \(offer.v)") }
        guard !offer.serverId.isEmpty, !offer.daemonPublicKeyB64.isEmpty, !offer.relay.endpoint.isEmpty else {
            throw PairingError("offer is missing fields")
        }
        guard offer.minimumSecurityMode == nil || offer.minimumSecurityMode == "protected" else {
            throw PairingError("unsupported security mode")
        }
        _ = try decodePublicKey(offer.daemonPublicKeyB64)
        let endpoint = try normalizeHostPort(offer.relay.endpoint)
        // COMPAT: offers that predate explicit useTls imply TLS on port 443.
        let useTls = offer.relay.useTls ?? ((try? parseHostPort(endpoint).port) == 443)
        return PairingOffer(
            serverId: offer.serverId,
            daemonPublicKeyB64: offer.daemonPublicKeyB64,
            relayEndpoint: endpoint,
            useTls: useTls,
            requireProtected: offer.minimumSecurityMode == "protected",
            password: nil
        )
    }

    // MARK: relay:// URI

    static func parseRelayUri(_ s: String) throws -> PairingOffer {
        var uri = s
        if let r = s.range(of: "#connect=") {
            guard let decoded = String(s[r.upperBound...]).removingPercentEncoding else {
                throw PairingError("invalid relay connection URI")
            }
            uri = decoded
        }
        guard let u = URLComponents(string: uri), u.scheme == "relay",
              let host = u.host, !host.isEmpty, let port = u.port,
              u.user == nil, u.password == nil
        else { throw PairingError("invalid relay connection URI") }
        let query = { (name: String) in u.queryItems?.first { $0.name == name }?.value }
        let serverId = String(u.percentEncodedPath.dropFirst()).removingPercentEncoding ?? ""
        guard !serverId.isEmpty, !serverId.contains("/"), let key = query("key"), !key.isEmpty else {
            throw PairingError("relay connection URI requires a server id and key")
        }
        let security = query("security")
        guard security == nil || security == "protected" else { throw PairingError("unsupported security mode") }
        _ = try decodePublicKey(key)
        let password = query("password").flatMap { $0.isEmpty ? nil : $0 }
        return PairingOffer(
            serverId: serverId,
            daemonPublicKeyB64: key,
            relayEndpoint: try normalizeHostPort("\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host):\(port)"),
            useTls: query("ssl") == "true",
            requireProtected: security == "protected",
            password: password
        )
    }

    // MARK: Helpers

    /// Strict standard base64 of exactly 32 bytes, re-encoding to the same text (as the daemon checks).
    static func decodePublicKey(_ b64: String) throws -> Data {
        guard b64.count % 4 == 0,
              b64.range(of: #"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"#, options: .regularExpression) != nil,
              let data = Data(base64Encoded: b64), data.base64EncodedString() == b64
        else { throw PairingError("invalid daemon public key encoding") }
        guard data.count == 32 else { throw PairingError("invalid daemon public key length") }
        return data
    }

    static func parseHostPort(_ input: String) throws -> (host: String, port: Int, isIpv6: Bool) {
        let s = input.trimmingCharacters(in: .whitespaces)
        let isIpv6 = s.hasPrefix("[")
        let pattern = isIpv6 ? #"^\[([^\]]+)\]:(\d{1,5})$"# : #"^(.+):(\d{1,5})$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let hr = Range(m.range(at: 1), in: s), let pr = Range(m.range(at: 2), in: s),
              let port = Int(s[pr]), (1...65535).contains(port)
        else { throw PairingError("invalid host:port") }
        let host = s[hr].trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw PairingError("host is required") }
        return (host, port, isIpv6)
    }

    static func normalizeHostPort(_ input: String) throws -> String {
        let (host, port, isIpv6) = try parseHostPort(input)
        return isIpv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
