import Testing
@testable import PaseoKit

@Suite @MainActor struct TimelineLifecycleTests {
    @Test func multipleViewsKeepTimelineAliveUntilLastCloseAndInactiveCacheIsBounded() {
        let host = HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "测试", clientId: "test", appVersion: "test")
        // 不启动网络连接；两个窗口打开同一会话，关闭其中一个不能淘汰另一个正在读的内容。
        host.timelines["shared"] = AgentTimeline()
        host.openTimeline("shared")
        host.openTimeline("shared")
        host.closeTimeline("shared")
        for i in 0..<12 {
            let id = "session-\(i)"
            host.timelines[id] = AgentTimeline()
            host.openTimeline(id)
            host.closeTimeline(id)
        }
        #expect(host.timelines["shared"] != nil)
        #expect(host.timelines.count == 9)
        #expect(host.timelines["session-3"] == nil)
        #expect(host.timelines["session-4"] != nil)
        host.closeTimeline("shared")
        #expect(host.timelines.count == 8)
        #expect(host.timelines["shared"] == nil)
    }
}
