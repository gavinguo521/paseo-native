import Foundation
import Observation

/// Loads each machine independently so a slow daemon cannot hold up the other machines' schedules.
@MainActor @Observable
public final class ScheduleListLoader {
    public struct Source: Sendable {
        public let hostID: String
        let fetch: @Sendable () async throws -> [Schedule]

        public init(hostID: String, fetch: @escaping @Sendable () async throws -> [Schedule]) {
            self.hostID = hostID
            self.fetch = fetch
        }
    }

    public private(set) var schedulesByHost: [String: [Schedule]] = [:]
    public private(set) var errorsByHost: [String: String] = [:]
    public private(set) var loadingHostIDs: Set<String> = []
    @ObservationIgnored private var generation = 0

    public init() {}

    public func load(sources: [Source], selectedHostID: String?) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let current = generation
        let selected = sources.filter { selectedHostID == nil || $0.hostID == selectedHostID }
        let hostIDs = Set(selected.map(\.hostID))
        // Keep the last successful results during refresh, but discard data outside this query.
        schedulesByHost = schedulesByHost.filter { hostIDs.contains($0.key) }
        errorsByHost = [:]
        loadingHostIDs = hostIDs
        defer {
            if current == generation { loadingHostIDs = [] }
        }

        await withTaskGroup(of: Response.self) { group in
            for source in selected {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return .loaded(source.hostID, try await source.fetch())
                    } catch {
                        return .failed(source.hostID, String(describing: error))
                    }
                }
            }
            for await response in group {
                // A refresh or filter change may have started a newer load while this RPC was waiting.
                guard !Task.isCancelled, current == generation else {
                    group.cancelAll()
                    break
                }
                switch response {
                case .loaded(let hostID, let schedules):
                    schedulesByHost[hostID] = schedules
                    loadingHostIDs.remove(hostID)
                case .failed(let hostID, let message):
                    errorsByHost[hostID] = message
                    loadingHostIDs.remove(hostID)
                }
            }
        }
    }

    /// In-flight daemon requests may still finish after leaving the page; ignore those results.
    public func cancel() {
        generation += 1
        loadingHostIDs = []
    }

    private enum Response: Sendable {
        case loaded(String, [Schedule])
        case failed(String, String)
    }
}
