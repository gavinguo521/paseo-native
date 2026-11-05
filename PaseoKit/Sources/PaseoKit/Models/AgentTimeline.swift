// One agent's timeline: authoritative pages from fetch_agent_timeline plus live agent_stream deltas.
// Pure value type so the sync rules are unit-testable. See docs/protocol/02-messages.md §4.4–4.6.

import Foundation
import Synchronization

public struct TimelineRow: Sendable, Identifiable {
    public let id: String
    public var turnId: String?
    public var timestamp: Date?
    public var item: TimelineItem
    /// Reasoning stops streaming as soon as any other event arrives.
    public var isStreaming: Bool
    /// Local optimistic user row not yet confirmed by the daemon.
    public var isPending: Bool
}

public struct TimelineCursor: Sendable, Equatable {
    public var epoch: String
    public var seq: Int
}

public struct AgentTimeline: Sendable {
    public private(set) var rows: [TimelineRow] = [] { didSet { revision = Self.nextRevision.add(1, ordering: .relaxed).newValue } }
    /// Changes whenever `rows` does, unique across all timelines, so views can cache what they derive from the rows.
    public private(set) var revision = 0
    private static let nextRevision = Atomic<Int>(0)
    public private(set) var epoch: String?
    public private(set) var startSeq: Int?
    public private(set) var endSeq: Int?
    public private(set) var hasOlder = false
    /// 后台命令的结束通知，按原命令的调用 id 和任务 id 各存一份，供 `backgroundTasks` 配对。
    public private(set) var backgroundTaskEnds: [String: BackgroundTaskEnd] = [:]

    public enum StreamResult: Equatable, Sendable {
        case applied, stale, noSeq
        /// Fetch `after` from `endCursor` until `hasNewer == false`, then replay buffered events.
        case gap
        /// Drop local state and fetch the tail again.
        case epochChanged
    }

    public init() {}

    public var isLoaded: Bool { epoch != nil }
    public var startCursor: JSONValue? { cursor(startSeq) }
    public var endCursor: JSONValue? { cursor(endSeq) }

    private func cursor(_ seq: Int?) -> JSONValue? {
        guard let epoch, let seq else { return nil }
        return ["epoch": .string(epoch), "seq": .number(Double(seq))]
    }

    // MARK: Pages

    /// Installs a `fetch_agent_timeline_response` payload. `tail` (or `reset`) replaces everything.
    public mutating func applyPage(_ payload: JSONValue) {
        let direction = payload["direction"]?.stringValue ?? "tail"
        let reset = payload["reset"]?.boolValue == true
        let pageEpoch = payload["epoch"]?.stringValue
        let entries = payload["entries"]?.arrayValue ?? []
        let pageStart = payload["startCursor"]?["seq"]?.doubleValue.map(Int.init)
        let pageEnd = payload["endCursor"]?["seq"]?.doubleValue.map(Int.init)

        if direction == "tail" || reset || pageEpoch != epoch {
            let pending = rows.filter(\.isPending)
            rows = []
            backgroundTaskEnds = [:]
            for e in entries { append(entry: e) }
            epoch = pageEpoch
            startSeq = pageStart
            endSeq = pageEnd ?? pageStart
            hasOlder = payload["hasOlder"]?.boolValue ?? false
            for p in pending where !claims(p.id) { rows.append(p) }
            return
        }

        if direction == "before" {
            var older = AgentTimeline()
            for e in entries { older.append(entry: e) }
            rows.insert(contentsOf: older.rows, at: 0)
            backgroundTaskEnds.merge(older.backgroundTaskEnds) { current, _ in current }
            startSeq = pageStart ?? startSeq
            hasOlder = payload["hasOlder"]?.boolValue ?? false
            return
        }

        // after: only entries beyond what streaming already gave us; a merged assistant/reasoning entry
        // that straddles endSeq replaces the partially streamed row.
        let local = endSeq ?? 0
        for e in entries {
            let seqStart = Int(e["seqStart"]?.doubleValue ?? 0)
            let seqEnd = Int(e["seqEnd"]?.doubleValue ?? 0)
            guard seqEnd > local else { continue }
            if seqStart <= local, let item = e["item"], let last = rows.indices.last {
                let type = item["type"]?.stringValue
                if (type == "assistant_message" && rows[last].item.isAssistant) || (type == "reasoning" && rows[last].item.isReasoning) {
                    rows[last].item = TimelineItem(item)
                    continue
                }
            }
            append(entry: e)
        }
        endSeq = max(local, pageEnd ?? local)
    }

    private mutating func append(entry e: JSONValue) {
        guard let item = e["item"] else { return }
        noteBackgroundTaskEnd(item)
        let seq = e["seqStart"]?.doubleValue.map { Int($0) }
        reduce(TimelineItem(item), turnId: e["turnId"]?.stringValue, timestamp: e["timestamp"]?.dateValue,
               fallbackId: seq.map { "seq-\($0)" }, merging: false)
    }

    // MARK: Live stream

    /// Applies one `agent_stream` payload (`event`, `seq`, `epoch`, `timestamp`).
    public mutating func applyStream(_ payload: JSONValue) -> StreamResult {
        guard let event = payload["event"] else { return .stale }
        let seq = payload["seq"]?.doubleValue.map(Int.init)
        if let seq {
            guard let epoch, let endSeq else { return .gap }
            if let e = payload["epoch"]?.stringValue, e != epoch { return .epochChanged }
            if seq <= endSeq { return .stale }
            if seq > endSeq + 1 { return .gap }
            self.endSeq = seq
        }
        if event["type"]?.stringValue == "timeline", let item = event["item"] {
            noteBackgroundTaskEnd(item)
            reduce(TimelineItem(item), turnId: event["turnId"]?.stringValue, timestamp: payload["timestamp"]?.dateValue,
                   fallbackId: seq.map { "seq-\($0)" }, merging: true)
        } else {
            finishStreamingReasoning()
        }
        return seq == nil ? .noSeq : .applied
    }

    // MARK: Optimistic sends

    public mutating func appendPendingUserMessage(text: String, messageId: String) {
        finishStreamingReasoning()
        rows.append(TimelineRow(id: messageId, turnId: nil, timestamp: Date(),
                                item: .userMessage(text: text, messageId: messageId), isStreaming: false, isPending: true))
    }

    public mutating func dropPendingUserMessage(_ messageId: String) {
        rows.removeAll { $0.id == messageId && $0.isPending }
    }

    private func claims(_ messageId: String) -> Bool {
        rows.contains { $0.id == messageId && !$0.isPending }
    }

    // MARK: Reduction rules (official: packages/app/src/types/stream.ts)

    private mutating func reduce(_ item: TimelineItem, turnId: String?, timestamp: Date?, fallbackId: String?, merging: Bool) {
        let id = fallbackId ?? UUID().uuidString
        if !item.isReasoning { finishStreamingReasoning() }

        switch item {
        case .userMessage(_, let messageId):
            if let messageId, let i = rows.firstIndex(where: { $0.id == messageId }) {
                rows[i].item = item
                rows[i].isPending = false
                rows[i].turnId = turnId ?? rows[i].turnId
                return
            }
            rows.append(TimelineRow(id: messageId ?? id, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))

        case .assistantMessage(let text, let messageId):
            if merging, let last = rows.indices.last, case .assistantMessage(let prev, let prevId) = rows[last].item,
               messageId == nil || prevId == nil || messageId == prevId {
                rows[last].item = .assistantMessage(text: prev + text, messageId: prevId ?? messageId)
                return
            }
            rows.append(TimelineRow(id: id, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))

        case .reasoning(let text):
            if merging, let last = rows.indices.last, rows[last].isStreaming, case .reasoning(let prev) = rows[last].item,
               rows[last].turnId == turnId {
                rows[last].item = .reasoning(text: prev + text)
                return
            }
            rows.append(TimelineRow(id: id, turnId: turnId, timestamp: timestamp, item: item, isStreaming: merging, isPending: false))

        case .toolCall(let callId, _, _, _, _, _):
            let rowId = "tool-\(callId)"
            if let i = rows.firstIndex(where: { $0.id == rowId }) {
                rows[i].item = item
                return
            }
            rows.append(TimelineRow(id: rowId, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))

        case .todo:
            if let i = rows.lastIndex(where: { if case .todo = $0.item { $0.turnId == turnId } else { false } }) {
                rows[i].item = item
                return
            }
            rows.append(TimelineRow(id: id, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))

        case .compaction:
            if let last = rows.indices.last, case .compaction = rows[last].item {
                rows[last].item = item
                return
            }
            rows.append(TimelineRow(id: id, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))

        case .plugin(let pid, let pluginId, _, _, _):
            // Re-appending the same id replaces the row.
            let rowId = "plugin-\(pluginId)-\(pid)"
            if let i = rows.firstIndex(where: { $0.id == rowId }) {
                rows[i].item = item
                return
            }
            rows.append(TimelineRow(id: rowId, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))

        case .unknown:
            return

        default:
            rows.append(TimelineRow(id: id, turnId: turnId, timestamp: timestamp, item: item, isStreaming: false, isPending: false))
        }
    }

    private mutating func noteBackgroundTaskEnd(_ item: JSONValue) {
        guard let (keys, end) = BackgroundTaskEnd.parse(item) else { return }
        for k in keys { backgroundTaskEnds[k] = end }
    }

    private mutating func finishStreamingReasoning() {
        if let last = rows.indices.last, rows[last].isStreaming { rows[last].isStreaming = false }
    }
}

extension TimelineItem {
    var isAssistant: Bool { if case .assistantMessage = self { true } else { false } }
    var isReasoning: Bool { if case .reasoning = self { true } else { false } }
}
