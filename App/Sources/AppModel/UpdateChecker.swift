// Mac 版在线更新检查：查 GitHub Releases 的最新正式版，比本机版本新就提示下载（不自动安装）。
// 仓库来自 Info.plist 的 PaseoReleasesRepo（Config/Paseo.xcconfig 的 PASEO_RELEASES_REPO），留空则不检查，fork 可改成自己的。

#if os(macOS)
import AppKit
import Foundation

@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable, Identifiable {
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
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "updates.lastChecked") as? Date

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "updates.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updates.auto") }
    }

    let repo = (Bundle.main.object(forInfoDictionaryKey: "PaseoReleasesRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    var isEnabled: Bool { repo.contains("/") }

    var currentVersion: String {
        #if DEBUG
        // 测试提示：PASEO_UPDATE_VERSION=1.0.0 假装本机是旧版本
        if let v = ProcessInfo.processInfo.environment["PASEO_UPDATE_VERSION"] { return v }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var timer: Task<Void, Never>?

    /// 启动后自动检查：距上次超过一天才查，之后每 6 小时看一次是否又满一天。Debug 版不自动查（避免开发时弹窗），可用 PASEO_UPDATE_VERSION 测试。
    func startAutomaticChecks() {
        guard isEnabled, timer == nil else { return }
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PASEO_UPDATE_VERSION"] != nil else { return }
        #endif
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.autoCheck, Date().timeIntervalSince(self.lastChecked ?? .distantPast) > 86_400 {
                    await self.check(manual: false)
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// manual：用户点的（不管有没有跳过都提示）；alert：用弹窗告诉结果（设置页里点的直接在页面上显示，不弹）。
    func check(manual: Bool, alert: Bool = true) async {
        guard isEnabled, status != .checking else { return }
        status = .checking
        do {
            let release = try await fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "updates.lastChecked")
            if Self.isNewer(release.version, than: currentVersion) {
                status = .available(release)
                if alert, manual || UserDefaults.standard.string(forKey: "updates.skipped") != release.version { prompt = release }
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
        UserDefaults.standard.set(release.version, forKey: "updates.skipped")
        prompt = nil
    }

    /// 有 dmg 就直接下载 dmg，没有就打开发布页。
    func download(_ release: Release) {
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
