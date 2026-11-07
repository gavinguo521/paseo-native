import PaseoKit
import SwiftUI

/// 只在本次运行中保留阅读位置，不持久化聊天内容。
@Observable @MainActor final class TimelineReadingState {
    @ObservationIgnored var restoreOnNextAppearance = false
    var expanded: [String: Bool] = [:]
    var historyWindow: AgentTimeline?
    @ObservationIgnored var offset: CGFloat = 0
    @ObservationIgnored var atBottom = true
    @ObservationIgnored var hasPosition = false
    @ObservationIgnored var firstRowID: String?
    @ObservationIgnored var anchorID: String?
    @ObservationIgnored var renderStartID: String?

    func shouldRestorePosition(enabled: Bool, liveFirstRowID: String?) -> Bool {
        enabled && hasPosition && !atBottom &&
            (historyWindow != nil || firstRowID == liveFirstRowID)
    }
}

@MainActor final class TimelineHistoryCache {
    private var key: [Int] = []
    private var value: AgentTimeline?
    func snapshot(_ history: AgentTimeline?, live: AgentTimeline?) -> AgentTimeline? {
        let next = [history?.revision ?? -1, live?.revision ?? -1]
        if key != next { value = history?.includingLiveTail(live) ?? live; key = next }
        return value
    }
}

extension EnvironmentValues {
    @Entry var timelineReadingState: TimelineReadingState? = nil
}

/// Bounds initial layout without estimated lazy-stack heights. The stable first ID keeps
/// the reading window fixed as live messages arrive; older items are revealed explicitly.
struct TimelineRenderWindow {
    static let pageSize = 16
    var startID: String?

    func start(in items: [DisplayItem]) -> Int {
        if let startID, let i = items.firstIndex(where: { $0.id == startID }) { return i }
        return max(0, items.count - Self.pageSize)
    }

    func visible(_ items: [DisplayItem]) -> ArraySlice<DisplayItem> { items[start(in: items)...] }

    mutating func pin(_ items: [DisplayItem]) {
        startID = visible(items).first?.id
    }

    mutating func revealOlder(_ items: [DisplayItem]) {
        guard !items.isEmpty else { return }
        startID = items[max(0, start(in: items) - Self.pageSize)].id
    }
}

/// 跨会话复用展示派生结果，最多保留最近八个；不改变网络订阅或阅读位置。
@MainActor final class SessionDisplayCaches {
    private var caches: [AgentRef: DisplayItemCache] = [:]
    private var recent: [AgentRef] = []
    func cache(for ref: AgentRef) -> DisplayItemCache {
        recent.removeAll { $0 == ref }
        recent.append(ref)
        let cache = caches[ref] ?? DisplayItemCache()
        caches[ref] = cache
        if recent.count > 8 { caches[recent.removeFirst()] = nil }
        return cache
    }
}
