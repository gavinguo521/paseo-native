import Foundation

public enum WireFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// A message-oriented socket. Abstracted so the secure channel can be tested without a network.
public protocol FrameTransport: Sendable {
    func send(_ frame: WireFrame) async throws
    /// Throws when the socket closes.
    func receive() async throws -> WireFrame
    func close(code: Int, reason: String) async
}

public struct TransportClosed: Error, CustomStringConvertible {
    public let code: Int
    public let reason: String
    public var description: String { "connection closed (\(code)\(reason.isEmpty ? "" : " \(reason)"))" }
}

public final class WebSocketTransport: FrameTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 100 * 1024 * 1024
        task.resume()
    }

    public func send(_ frame: WireFrame) async throws {
        switch frame {
        case .text(let s): try await task.send(.string(s))
        case .binary(let d): try await task.send(.data(d))
        }
    }

    public func receive() async throws -> WireFrame {
        do {
            switch try await task.receive() {
            case .string(let s): return .text(s)
            case .data(let d): return .binary(d)
            @unknown default: return .binary(Data())
            }
        } catch {
            if task.closeCode != .invalid {
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                throw TransportClosed(code: task.closeCode.rawValue, reason: reason)
            }
            throw error
        }
    }

    public func close(code: Int, reason: String) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
    }
}
