import Foundation
import Testing
@testable import PaseoKit

struct BackgroundWorkTests {
    @Test func parsesItemsAndTreatsUnknownKindAsOther() throws {
        let items = BackgroundWorkItem.list(try JSONValue.parse(#"""
        [
          {"id":"a","kind":"shell","description":"跑测试","command":"npm test","startedAt":"2026-11-16T08:00:00.000Z",
           "canStop":true,"stopToken":"tok-a"},
          {"id":"b","kind":"monitor","description":null,"command":"tail -f log","startedAt":"2026-11-16T08:01:00Z"},
          {"id":"c","kind":"future-kind","description":null,"startedAt":"2026-11-16T08:02:00Z","canStop":true,"stopToken":""},
          {"kind":"shell","description":"缺 id 的丢掉","startedAt":"2026-11-16T08:03:00Z"}
        ]
        """#))
        #expect(items.map(\.id) == ["a", "b", "c"])
        #expect(items.map(\.kind) == [.shell, .monitor, .other])
        #expect(items[0].canStop && items[0].stopToken == "tok-a")
        #expect(items[0].startedAt != nil)
        #expect(!items[1].canStop && items[1].stopToken == nil)
        // 空 stopToken 当没有：不能拿去停止。
        #expect(items[2].stopToken == nil)
    }

    @Test func titleFallsBackToCommandAndHidesDuplicateCommand() throws {
        let items = BackgroundWorkItem.list(try JSONValue.parse(#"""
        [
          {"id":"a","kind":"shell","description":"跑测试","command":"npm test","startedAt":"2026-11-16T08:00:00Z"},
          {"id":"b","kind":"shell","description":null,"command":"npm test","startedAt":"2026-11-16T08:00:00Z"},
          {"id":"c","kind":"monitor","description":null,"startedAt":"2026-11-16T08:00:00Z"}
        ]
        """#))
        #expect(items[0].title == "跑测试" && items[0].commandDetail == "npm test")
        #expect(items[1].title == "npm test" && items[1].commandDetail == nil)
        #expect(items[2].title == nil && items[2].commandDetail == nil)
    }

    @Test func idleAgentWithBackgroundWorkCountsAsRunning() throws {
        let idle = try #require(Agent(try JSONValue.parse(#"{"id":"x","status":"idle","backgroundWork":{"count":2}}"#)))
        #expect(idle.backgroundWorkCount == 2)
        #expect(idle.bucket == .running)
        let none = try #require(Agent(try JSONValue.parse(#"{"id":"y","status":"idle","backgroundWork":{"count":0}}"#)))
        #expect(none.bucket == .done)
        let old = try #require(Agent(try JSONValue.parse(#"{"id":"z","status":"idle"}"#)))
        #expect(old.backgroundWorkCount == 0 && old.bucket == .done)
        // 需要输入仍然优先于后台任务。
        let asking = try #require(Agent(try JSONValue.parse(
            #"{"id":"w","status":"idle","attentionReason":"permission","backgroundWork":{"count":1}}"#)))
        #expect(asking.bucket == .needsInput)
    }

    @MainActor @Test func pushReplacesListOnlyForWatchedAgents() throws {
        let host = HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "测试", clientId: "test", appVersion: "test")
        var watched = BackgroundWorkState(items: [])
        watched.watchers = 1
        watched.stops = ["gone": .failed("x"), "tok-a": .failed("y")]
        host.backgroundWork["watched"] = watched

        host.applyBackgroundWorkUpdate(try JSONValue.parse(#"""
        {"agentId":"watched","items":[{"id":"a","kind":"shell","description":null,"command":"sleep 100",
          "startedAt":"2026-11-16T08:00:00Z","canStop":true,"stopToken":"tok-a"}]}
        """#))
        host.applyBackgroundWorkUpdate(try JSONValue.parse(
            #"{"agentId":"other","items":[{"id":"b","kind":"shell","description":null,"startedAt":"2026-11-16T08:00:00Z"}]}"#))

        let state = try #require(host.backgroundWork["watched"])
        #expect(state.items?.map(\.id) == ["a"])
        #expect(state.revision == 1)
        // 已不在列表里的条目，停止失败提示随之清掉；还在的保留。
        #expect(state.stops == ["tok-a": .failed("y")])
        #expect(host.backgroundWork["other"] == nil)
    }
}
