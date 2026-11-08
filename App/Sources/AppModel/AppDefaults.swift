import Foundation

/// App 的偏好设置都从这里读写，不要直接用 `UserDefaults.standard`，`@AppStorage` 也要带 `store: AppDefaults.store`。
/// Mac 版测试跑在 App 进程里（TEST_HOST），包名和正式版相同：直接用 standard 会改掉本机正式版的设置
/// （测试夹具把排序改成「创建时间」、清空手动顺序，用户再切回「手动」时就把错的顺序记了下来）。
/// 测试时换成独立的一份。
enum AppDefaults {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    // UserDefaults 本身线程安全，只是没标 Sendable。
    nonisolated(unsafe) static let store: UserDefaults = {
        guard isTesting else { return .standard }
        return UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "paseo") + ".testing") ?? .standard
    }()
}
