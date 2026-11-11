import Foundation
import Testing
@testable import PaseoKit

struct ScheduleNotificationTests {
    enum SaveError: Error { case offline }

    @MainActor @Test func retryAfterNotificationFailureUpdatesTheCreatedSchedule() async throws {
        let saver = ScheduleEditorSave()
        var created = 0
        var updated: [String] = []
        var notified: [String] = []
        do {
            try await saver.save(existingID: nil, create: { created += 1; return "new-task" },
                                 update: { updated.append($0) }, saveNotification: { _ in throw SaveError.offline })
            Issue.record("Expected a partial save failure")
        } catch ScheduleEditorSave.Failure.notification { }
        #expect(saver.createdID == "new-task")
        try await saver.save(existingID: nil, create: { created += 1; return "duplicate" },
                             update: { updated.append($0) }, saveNotification: { notified.append($0) })
        #expect(created == 1)
        #expect(updated == ["new-task"])
        #expect(notified == ["new-task"])
    }

    @MainActor @Test func failedScheduleSaveDoesNotWriteNotificationPreference() async {
        let saver = ScheduleEditorSave()
        var notified = false
        do {
            try await saver.save(existingID: "existing", create: { "unexpected" },
                                 update: { _ in throw SaveError.offline }, saveNotification: { _ in notified = true })
            Issue.record("Expected schedule save failure")
        } catch { }
        #expect(!notified)
        #expect(saver.createdID == nil)
    }

    @MainActor @Test func unchangedNotificationSettingDoesNotRequirePlugin() async throws {
        let saver = ScheduleEditorSave()
        var updated: [String] = []
        try await saver.save(existingID: "old-task", create: { "unexpected" },
                             update: { updated.append($0) }, saveNotification: nil)
        #expect(updated == ["old-task"])
    }

    @Test func missingOrOldPluginResponseIsNotAnOffPreference() {
        #expect(ScheduleNotificationPreference(.null) == nil)
        #expect(ScheduleNotificationPreference([:]) == nil)
        #expect(ScheduleNotificationPreference(["version": 2, "enabled": true, "revision": "x", "ready": true]) == nil)
        #expect(ScheduleNotificationPreference(["version": 1, "enabled": true, "revision": "", "ready": true]) == nil)
    }

    @Test func enabledPreferenceIsPreservedWhenPushBecomesUnavailable() throws {
        let value: JSONValue = ["version": 1, "enabled": true, "revision": "saved-revision", "ready": false]
        let preference = try #require(ScheduleNotificationPreference(value))
        #expect(preference.enabled)
        #expect(!preference.ready)
        #expect(preference.revision == "saved-revision")
    }

    @Test func failedRunWithoutAgentStillRoutesToScheduleHistory() throws {
        let route = try #require(ScheduleNotificationRoute(userInfo: [
            "reason": "schedule_result", "serverId": "host", "scheduleId": "task", "runId": "failed-run"
        ]))
        #expect(route.serverId == "host")
        #expect(route.scheduleId == "task")
        #expect(ScheduleNotificationRoute(userInfo: ["reason": "finished", "serverId": "host", "agentId": "agent"]) == nil)
        #expect(ScheduleNotificationRoute(userInfo: ["reason": "schedule_result", "serverId": "", "scheduleId": "task"]) == nil)
    }

    @Test func barkLinkOpensTaskHistoryWithoutRequiringAnAgent() throws {
        let url = try #require(URL(string: "paseonative://schedule?serverId=srv_host-a&scheduleId=task-a"))
        let route = try #require(ScheduleNotificationRoute(url: url))
        #expect(route.serverId == "srv_host-a")
        #expect(route.scheduleId == "task-a")
    }

    @Test func malformedOrAmbiguousBarkLinksAreIgnored() throws {
        for value in [
            "https://schedule?serverId=host&scheduleId=task",
            "paseonative://agent?serverId=host&scheduleId=task",
            "paseonative://user@ schedule?serverId=host&scheduleId=task",
            "paseonative://schedule?serverId=host",
            "paseonative://schedule?serverId=host&scheduleId=",
            "paseonative://schedule?serverId=a&serverId=b&scheduleId=task",
            "paseonative://schedule?serverId=host&scheduleId=task&scheduleId=other",
            "paseonative://schedule?serverId=host&scheduleId=..%2Fdevices",
            "paseonative://schedule/execute?serverId=host&scheduleId=task"
        ] {
            if let url = URL(string: value) { #expect(ScheduleNotificationRoute(url: url) == nil) }
        }
    }
}
