import Foundation

/// Opt-in monotonic timings. Records IDs/counts only, never message contents or credentials.
@MainActor public enum SessionSwitchTrace {
    public static let enabled = ProcessInfo.processInfo.environment["PASEO_SWITCH_TRACE"] == "1"
    private static var target = ""
    private static var started = 0.0
    private static var sequence = 0
    private static var stages: Set<String> = []

    public static func begin(_ id: String, cachedRows: Int) {
        guard enabled else { return }
        target = id; started = ProcessInfo.processInfo.systemUptime; sequence += 1; stages = []
        mark(id, "click", detail: "cachedRows=\(cachedRows)")
    }

    public static func generation(for id: String) -> Int { enabled && target == id ? sequence : -1 }

    public static func mark(_ id: String, _ stage: String, detail: String = "", generation: Int? = nil) {
        guard enabled, target == id, generation == nil || generation == sequence,
              stages.insert(stage).inserted else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let line = String(format: "SWITCH n=%d id=%@ stage=%@ ms=%.2f %@\n", sequence, String(id.prefix(8)), stage, ms, detail)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
