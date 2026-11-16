import Foundation

extension HostStore {
    /// Check the execution host for each local completion candidate: a different
    /// client may have changed Bark since this phone last opened its settings.
    public func barkHandlesCompletions() async -> Bool {
        if pluginsLoaded, !isPluginRunning("live-activity") {
            barkCompletionEnabled = false
            return false
        }
        do {
            _ = try await invokePlugin("live-activity", "bark.status", [:], timeout: .seconds(3))
        } catch {
            // A transient RPC failure must not re-enable local banners when this
            // host last confirmed Bark was on. Unknown/old plugins keep the native path.
        }
        return barkCompletionEnabled == true
    }

    func recordBarkCompletionPreference(_ value: JSONValue) {
        guard let configured = value["configured"]?.boolValue else { return }
        if !configured {
            barkCompletionEnabled = false
        } else {
            // Older plugins support scheduled results only, with no completion switch.
            barkCompletionEnabled = value["notifyOnFinish"]?.boolValue ?? false
        }
    }
}
