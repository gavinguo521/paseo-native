import Testing
@testable import PaseoKit
@testable import Paseo

@MainActor struct ScheduleNotificationNavigationTests {
    @Test func resultOpensHistoryEvenWhenThereIsNoAgentInTheSidebar() throws {
        let model = AppModel(testHosts: [])
        let route = try #require(ScheduleNotificationRoute(userInfo: [
            "reason": "schedule_result", "serverId": "execution-host", "scheduleId": "failed-task"
        ]))
        let reveal = model.revealDetail
        model.openScheduleNotification(route)
        #expect(model.destination == .schedules)
        #expect(model.pendingScheduleNotification == route)
        #expect(model.revealDetail == reveal + 1)
    }
}
