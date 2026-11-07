import Testing
import PaseoKit
@testable import Paseo

@MainActor struct AutocompleteTests {
    private func host() -> HostStore {
        HostStore(offer: .direct(serverId: "commands-test", endpoint: "localhost:1", useTls: false, password: nil),
                  label: "测试", clientId: "test", appVersion: "test")
    }

    @Test func failureClearsOldOptionsAndRetryKeepsReturnSafe() async {
        let model = AutocompleteModel()
        model.items = [Suggestion(id: "/exit", title: "/exit", detail: "", systemImage: "archivebox", insert: "", local: "exit")]
        model.update(text: "/", host: host(), agentId: "test", cwd: nil)
        #expect(model.loading && model.isActive)
        #expect(model.selected == nil)
        await model.task?.value
        #expect(model.error != nil)
        #expect(model.isActive && model.items.isEmpty)
        model.moveSelection(1)
        #expect(model.selected == nil)
        model.retry?()
        #expect(model.loading && model.error == nil)
        await model.task?.value
        #expect(model.error != nil)
        model.dismiss()
        #expect(!model.isActive && model.retry == nil)
    }

    @Test func dismissedRequestCannotReopenMenu() async {
        let model = AutocompleteModel()
        model.update(text: "/", host: host(), agentId: "test", cwd: nil)
        let pending = model.task
        model.dismiss()
        await pending?.value
        #expect(!model.isActive && model.items.isEmpty && model.error == nil)
    }

    @Test func changingQueryImmediatelyDropsPriorSelection() async {
        let model = AutocompleteModel()
        let host = host()
        model.update(text: "/ex", host: host, agentId: nil, cwd: nil)
        await model.task?.value
        model.items = [Suggestion(id: "/exit", title: "/exit", detail: "", systemImage: "archivebox", insert: "", local: "exit")]
        model.update(text: "/", host: host, agentId: nil, cwd: nil)
        #expect(model.selected == nil)
        await model.task?.value
        #expect(model.items.isEmpty)
    }
}
