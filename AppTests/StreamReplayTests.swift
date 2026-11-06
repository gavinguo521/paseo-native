import AppKit
import SwiftUI
import Testing
@testable import PaseoKit
@testable import Paseo

private final class ReplayBundleToken: NSObject {}

/// 协议 JSONL → 正式时间线归并 → SwiftUI AgentView，完全隔离于真实 daemon。
@Suite(.serialized) @MainActor struct StreamReplayTests {
    private func fixture(_ name: String) throws -> [JSONValue] {
        let url = try #require(Bundle(for: ReplayBundleToken.self).url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }
    private func content(_ timeline: AgentTimeline) -> [String] { timeline.rows.map { String(describing: $0.item) } }

    @Test func protocolReplayMatchesAuthoritativeSnapshot() throws {
        for name in ["mixed-tools", "long-reply", "table-code"] {
            let events = try fixture(name)
            var timeline = AgentTimeline()
            for event in events {
                let payload = try #require(event["payload"])
                switch event["kind"]?.stringValue {
                case "page": timeline.applyPage(payload)
                case "stream":
                    #expect(timeline.applyStream(payload) == .applied)
                    let before = content(timeline)
                    #expect(timeline.applyStream(payload) == .stale)
                    #expect(content(timeline) == before)
                case "snapshot":
                    var reference = AgentTimeline()
                    reference.applyPage(payload)
                    #expect(content(timeline) == content(reference))
                default: Issue.record("未知回放事件")
                }
            }
            #expect(content(timeline).joined().contains("FINAL REPLY MARKER"))
            if name == "mixed-tools" {
                #expect(timeline.rows.filter { $0.id == "tool-build" }.count == 1)
                #expect(content(timeline).joined().contains("FINAL LOG MARKER"))
            }
            #expect(timeline.applyStream(["epoch": .string(name), "seq": 99999, "event": ["type": "timeline", "item": ["type": "reasoning", "text": "gap"]]]) == .gap)
        }
    }

    @Test func replayThroughNativeTimelineLayout() async throws {
        for name in ["mixed-tools", "long-reply", "table-code"] {
            let events = try fixture(name)
            let host = HostStore(offer: .direct(serverId: "replay-test", endpoint: "localhost:1", useTls: false, password: nil), label: "回放测试", clientId: "test", appVersion: "test")
            host.agents["replay"] = try #require(Agent(["id": "replay", "status": "running", "title": "固定流回放", "cwd": "/test/replay"]))
            let model = AppModel(testHosts: [host])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = NSHostingView(rootView: AgentView(host: host, agentId: "replay", workspace: nil).environment(model).environment(\.colorScheme, .light).background(Color.white))
            view.sizingOptions = []
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            let clock = ContinuousClock()
            let start = clock.now
            var timeline = AgentTimeline()
            var steps = 0
            for event in events {
                guard let payload = event["payload"] else { continue }
                if event["kind"]?.stringValue == "page" { timeline.applyPage(payload) }
                else if event["kind"]?.stringValue == "stream" { #expect(timeline.applyStream(payload) == .applied) }
                else { continue }
                host.timelines["replay"] = timeline
                await Task.yield()
                view.layoutSubtreeIfNeeded()
                steps += 1
            }
            #expect(host.timelines["replay"]?.rows.isEmpty == false)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/paseo-replay-\(name).png"))
            print("STREAM_REPLAY \(name) events=\(steps) layoutElapsed=\(start.duration(to: clock.now))")
        }
    }
}
