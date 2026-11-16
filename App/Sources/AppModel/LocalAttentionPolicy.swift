import PaseoKit

enum LocalAttentionPolicy {
    /// Only iOS supplies a Bark lookup. Mac keeps its original local notifications.
    @MainActor static func shouldPost(
        _ event: AttentionEvent,
        isViewing: @MainActor () -> Bool,
        barkEnabled: (@MainActor () async -> Bool)? = nil
    ) async -> Bool {
        guard event.shouldNotify, !isViewing() else { return false }
        if event.reason == "finished", let barkEnabled, await barkEnabled() { return false }
        // Navigation may change while the host answers the preference RPC.
        return !Task.isCancelled && !isViewing()
    }
}
