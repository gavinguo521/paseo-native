// Mac 版在线更新检查：查 GitHub Releases 的最新正式版，比本机版本新就提示下载（不自动安装）。
// 仓库来自 Info.plist 的 PaseoReleasesRepo（Config/Paseo.xcconfig 的 PASEO_RELEASES_REPO），留空则不检查，fork 可改成自己的。

#if os(macOS)
import AppKit
import Foundation

@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Codable, Equatable, Identifiable {
        let version: String
        let notes: String
        let page: URL
        let download: URL?
        var id: String { version }
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    private(set) var status: Status = .idle
    /// 要弹窗提示的版本（自动检查发现、且没被跳过；手动检查发现的也弹）。
    var prompt: Release?
    /// 手动检查的结果（已是最新 / 失败），弹一次提示。
    var notice: String?
    private(set) var lastChecked: Date?
    private var lastAttempt: Date?
    private(set) var latestRelease: Release?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (() async throws -> Release)?
    static let checkInterval: TimeInterval = 30 * 60
    static let reminderDelay: TimeInterval = 24 * 3600

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         repo: String? = nil, fetch: (() async throws -> Release)? = nil) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        self.repo = (repo ?? Bundle.main.object(forInfoDictionaryKey: "PaseoReleasesRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
        lastChecked = defaults.object(forKey: "updates.lastChecked") as? Date
        lastAttempt = defaults.object(forKey: "updates.lastAttempt") as? Date ?? lastChecked
        latestRelease = defaults.data(forKey: "updates.latestRelease").flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
    }

    var availableRelease: Release? {
        latestRelease.flatMap { Self.isNewer($0.version, than: currentVersion) ? $0 : nil }
    }

    var autoCheck: Bool {
        get { defaults.object(forKey: "updates.auto") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "updates.auto") }
    }

    let repo: String
    var isEnabled: Bool { repo.contains("/") }

    var currentVersion: String {
        #if DEBUG
        // 测试提示：PASEO_UPDATE_VERSION=1.0.0 假装本机是旧版本
        if let v = ProcessInfo.processInfo.environment["PASEO_UPDATE_VERSION"] { return v }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var timer: Task<Void, Never>?

    private var automaticChecksAllowed: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PASEO_UPDATE_VERSION"] != nil
        #else
        return true
        #endif
    }

    /// 启动和回到前台共用限频；即使失败或多窗口同时触发，也不重复请求。
    func checkOnActivation() {
        guard automaticChecksAllowed else { return }
        Task { await check(manual: false) }
    }

    /// 根据上次尝试时间安排下一次检查，手动检查或前台检查不会让定时器多等一整轮。
    func startAutomaticChecks() {
        guard isEnabled, timer == nil, automaticChecksAllowed else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(manual: false)
                let delay = self.autoCheck
                    ? max(1, Self.checkInterval - self.now().timeIntervalSince(self.lastAttempt ?? self.now()))
                    : Self.checkInterval
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }

    /// manual：用户点的（不管有没有跳过都提示）；alert：用弹窗告诉结果（设置页里点的直接在页面上显示，不弹）。
    func check(manual: Bool, alert: Bool = true) async {
        guard isEnabled, status != .checking else { return }
        let attempt = now()
        if !manual {
            guard autoCheck, attempt.timeIntervalSince(lastAttempt ?? .distantPast) >= Self.checkInterval else { return }
        }
        lastAttempt = attempt
        defaults.set(attempt, forKey: "updates.lastAttempt")
        status = .checking
        do {
            let release: Release
            if let fetch { release = try await fetch() }
            else { release = try await fetchLatest() }
            lastChecked = now()
            defaults.set(lastChecked, forKey: "updates.lastChecked")
            latestRelease = release
            if let data = try? JSONEncoder().encode(release) { defaults.set(data, forKey: "updates.latestRelease") }
            if Self.isNewer(release.version, than: currentVersion) {
                status = .available(release)
                if alert, manual || (autoCheck && shouldRemind(release)), prompt == nil {
                    markPrompted(release)
                    prompt = release
                }
            } else {
                status = .upToDate
                if manual, alert { notice = String(localized: "已是最新版本（\(currentVersion)）") }
            }
        } catch {
            status = .failed("\(error)")
            if manual, alert { notice = String(localized: "检查更新失败：\(error)") }
        }
    }

    func skip(_ release: Release) {
        defaults.set(release.version, forKey: "updates.skipped")
        prompt = nil
    }

    func remindLater(_ release: Release) {
        defaults.set(release.version, forKey: "updates.snoozedVersion")
        defaults.set(now().addingTimeInterval(Self.reminderDelay), forKey: "updates.snoozedUntil")
        prompt = nil
    }

    private func shouldRemind(_ release: Release) -> Bool {
        guard defaults.string(forKey: "updates.skipped") != release.version else { return false }
        if defaults.string(forKey: "updates.snoozedVersion") == release.version,
           let until = defaults.object(forKey: "updates.snoozedUntil") as? Date { return now() >= until }
        return defaults.string(forKey: "updates.promptedVersion") != release.version
    }

    private func markPrompted(_ release: Release) {
        defaults.set(release.version, forKey: "updates.promptedVersion")
        if defaults.string(forKey: "updates.snoozedVersion") == release.version {
            defaults.removeObject(forKey: "updates.snoozedVersion")
            defaults.removeObject(forKey: "updates.snoozedUntil")
        }
    }

    /// 有 dmg 就直接下载 dmg，没有就打开发布页。
    func download(_ release: Release) {
        markPrompted(release)
        NSWorkspace.shared.open(release.download ?? release.page)
        prompt = nil
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private func fetchLatest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw Failure(description: String(localized: "仓库地址无效")) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Paseo-Native/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure(description: code == 404 ? String(localized: "还没有发布版本") : String(localized: "GitHub 返回 \(code)")) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { throw Failure(description: String(localized: "发布信息格式不对")) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       page: page, download: dmg.flatMap(URL.init(string:)))
    }

    /// 按数字逐段比较（1.0.10 > 1.0.9），只看 x.y.z 部分。
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
#endif
