#if DEBUG && PASEO_REPLAY
import Foundation
@testable import PaseoKit

/// 只在独立的 replay-tests 构建运行：不读钥匙串，不启动网络或模型。
@MainActor final class DebugStreamReplay {
    static var active: DebugStreamReplay?
    let host: HostStore
    private let events: [JSONValue]
    private var started = false

    static func loadIfRequested() -> DebugStreamReplay? {
        guard let path = ProcessInfo.processInfo.environment["PASEO_REPLAY_FILE"] else { return nil }
        guard Bundle.main.bundleIdentifier?.hasSuffix(".replay-tests") == true else {
            fatalError("回放只允许在独立的 replay-tests 应用标识下运行")
        }
        do {
            let replay = try DebugStreamReplay(path: path)
            active = replay
            return replay
        } catch { fatalError("无法读取固定回放样本：\(error)") }
    }

    private init(path: String) throws {
        events = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
        host = HostStore(offer: .direct(serverId: "fixture-host", endpoint: "localhost:1", useTls: false, password: nil),
                         label: "固定样本（无连接）", clientId: "replay", appVersion: "test")
        host.agents["replay"] = Agent(["id": "replay", "title": "固定消息流回放", "cwd": "/test/回放项目", "provider": "test", "status": "running"])
        host.agents["reference"] = Agent(["id": "reference", "title": "排序对照会话", "cwd": "/test/对照项目", "provider": "test", "status": "idle"])
        host.timelines["replay"] = AgentTimeline()
    }

    func play() {
        guard !started else { return }
        started = true
        Task {
            var timeline = AgentTimeline()
            var lastTime = 0
            for event in events {
                guard let payload = event["payload"] else { continue }
                switch event["kind"]?.stringValue {
                case "page": timeline.applyPage(payload)
                case "stream":
                    // 这是样本内定义的事件间隔，不用延时猜测 UI 是否已就绪。
                    let time = Int(event["t"]?.doubleValue ?? 0)
                    if time > lastTime { try? await Task.sleep(for: .milliseconds(time - lastTime)) }
                    lastTime = time
                    guard timeline.applyStream(payload) == .applied else { fatalError("回放序列不连续") }
                case "snapshot": continue
                default: fatalError("未知回放事件")
                }
                host.timelines["replay"] = timeline
            }
            host.agents["replay"] = Agent(["id": "replay", "title": "固定消息流回放", "cwd": "/test/回放项目", "provider": "test", "status": "idle", "requiresAttention": true, "attentionReason": "completed"])
            print("STREAM_REPLAY_COMPLETE rows=\(timeline.rows.count)")
        }
    }
}
#endif
