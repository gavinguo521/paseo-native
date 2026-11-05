import Foundation
import Testing
@testable import PaseoKit

@MainActor
struct ScheduleListLoaderTests {
    @Test func selectedHostIsTheOnlyHostRequested() async {
        let mini = ScheduleRequest(.success([schedule("mini-task")]))
        let air = ScheduleRequest(.failure(FetchError.offline))
        let loader = ScheduleListLoader()

        await loader.load(sources: [source("air", air), source("mini", mini)], selectedHostID: "mini")

        #expect(mini.calls == 1)
        #expect(air.calls == 0)
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["mini-task"])
        #expect(loader.errorsByHost.isEmpty)
        #expect(loader.loadingHostIDs.isEmpty)
    }

    @Test func fastHostAppearsWhileTheFirstHostIsStillWaiting() async {
        let mini = ScheduleRequest(.success([schedule("mini-task")]))
        let air = ScheduleRequest()
        let loader = ScheduleListLoader()
        let task = Task { await loader.load(sources: [source("air", air), source("mini", mini)], selectedHostID: nil) }
        defer { air.finish(.success([])); task.cancel() }

        #expect(await eventually { loader.schedulesByHost["mini"] != nil })
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["mini-task"])
        #expect(loader.loadingHostIDs == ["air"])

        air.finish(.failure(FetchError.offline))
        await task.value
        #expect(loader.errorsByHost.keys.sorted() == ["air"])
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["mini-task"])
        #expect(loader.loadingHostIDs.isEmpty)
    }

    @Test func changingFilterClearsOtherHostsAndIgnoresTheirLateErrors() async {
        let mini = ScheduleRequest(.success([schedule("old-mini-task")]))
        let air = ScheduleRequest()
        let other = ScheduleRequest(.failure(FetchError.offline))
        let loader = ScheduleListLoader()
        let old = Task {
            await loader.load(sources: [source("air", air), source("mini", mini), source("other", other)], selectedHostID: nil)
        }
        defer { air.finish(.success([])); old.cancel() }
        #expect(await eventually { loader.schedulesByHost["mini"] != nil && loader.errorsByHost["other"] != nil })

        let updatedMini = ScheduleRequest(.success([schedule("new-mini-task")]))
        await loader.load(sources: [source("air", air), source("mini", updatedMini), source("other", other)], selectedHostID: "mini")
        #expect(loader.errorsByHost.isEmpty)
        #expect(air.calls == 1)
        #expect(other.calls == 1)

        air.finish(.failure(FetchError.offline))
        await old.value
        #expect(loader.errorsByHost.isEmpty)
        #expect(loader.schedulesByHost.keys.sorted() == ["mini"])
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["new-mini-task"])
    }

    @Test func oldCompletionCannotClearNewLoadingStateOrReplaceResults() async {
        let oldRequest = ScheduleRequest()
        let newRequest = ScheduleRequest()
        let loader = ScheduleListLoader()
        let old = Task { await loader.load(sources: [source("mini", oldRequest)], selectedHostID: "mini") }
        defer { oldRequest.finish(.success([])); old.cancel() }
        #expect(await eventually { oldRequest.calls == 1 })

        let current = Task { await loader.load(sources: [source("mini", newRequest)], selectedHostID: "mini") }
        defer { newRequest.finish(.success([])); current.cancel() }
        #expect(await eventually { newRequest.calls == 1 })
        oldRequest.finish(.success([schedule("stale-task")]))
        await old.value
        #expect(loader.loadingHostIDs == ["mini"])
        #expect(loader.schedulesByHost.isEmpty)

        newRequest.finish(.success([schedule("fresh-task")]))
        await current.value
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["fresh-task"])
        #expect(loader.loadingHostIDs.isEmpty)
    }

    @Test func refreshKeepsSuccessfulResultsWhileWaitingAndAfterFailure() async {
        let loader = ScheduleListLoader()
        await loader.load(sources: [source("mini", ScheduleRequest(.success([schedule("saved-task")])))], selectedHostID: "mini")
        let request = ScheduleRequest()
        let task = Task { await loader.load(sources: [source("mini", request)], selectedHostID: "mini") }
        defer { request.finish(.success([])); task.cancel() }
        #expect(await eventually { request.calls == 1 })
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["saved-task"])

        request.finish(.failure(FetchError.offline))
        await task.value
        #expect(loader.schedulesByHost["mini"]?.map(\.id) == ["saved-task"])
        #expect(loader.errorsByHost["mini"] != nil)
        #expect(loader.loadingHostIDs.isEmpty)
    }

    @Test func leavingPageDiscardsLateResults() async {
        let loader = ScheduleListLoader()
        let request = ScheduleRequest()
        let task = Task { await loader.load(sources: [source("mini", request)], selectedHostID: nil) }
        defer { request.finish(.success([])); task.cancel() }
        #expect(await eventually { request.calls == 1 })

        loader.cancel()
        request.finish(.success([schedule("late-task")]))
        await task.value
        #expect(loader.schedulesByHost.isEmpty)
        #expect(loader.errorsByHost.isEmpty)
        #expect(loader.loadingHostIDs.isEmpty)
    }

    @Test func selectingAnUnavailableHostDoesNotFallBackToOtherHosts() async {
        let mini = ScheduleRequest(.success([schedule("mini-task")]))
        let loader = ScheduleListLoader()
        await loader.load(sources: [source("mini", mini)], selectedHostID: nil)
        await loader.load(sources: [source("mini", mini)], selectedHostID: "air")
        #expect(mini.calls == 1)
        #expect(loader.schedulesByHost.isEmpty)
        #expect(loader.errorsByHost.isEmpty)
        #expect(loader.loadingHostIDs.isEmpty)
    }

    private func schedule(_ id: String) -> Schedule { Schedule(["id": .string(id)])! }

    private func source(_ hostID: String, _ request: ScheduleRequest) -> ScheduleListLoader.Source {
        .init(hostID: hostID) { try await request.fetch() }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private enum FetchError: Error { case offline }

/// Intentionally ignores cancellation, like a daemon RPC that has already been sent.
@MainActor private final class ScheduleRequest {
    private(set) var calls = 0
    private var result: Result<[Schedule], any Error>?
    private var continuation: CheckedContinuation<[Schedule], any Error>?

    init(_ result: Result<[Schedule], any Error>? = nil) { self.result = result }

    func fetch() async throws -> [Schedule] {
        calls += 1
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<[Schedule], any Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
