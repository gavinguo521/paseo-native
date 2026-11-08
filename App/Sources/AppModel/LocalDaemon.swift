// Runs the Paseo daemon on this Mac without the official desktop app: installs the official CLI (and Node
// when the machine has none) into Application Support, keeps `paseo daemon run` alive with a LaunchAgent,
// and takes over from the desktop app on the same PASEO_HOME, so the machine keeps its identity and pairing.

#if os(macOS)
import AppKit
import CryptoKit
import Foundation

@MainActor @Observable
final class LocalDaemon {
    static let shared = LocalDaemon()

    /// Who runs the daemon of `home` right now.
    enum Owner: Equatable { case stopped, official, native, other }

    struct Status: Equatable {
        var owner: Owner
        var version: String?
        var serverId: String?
        var listen: String?
    }

    /// First version installed; updates go to whatever npm reports as latest.
    static let initialVersion = "0.14.0"
    /// Node used when the machine has no Node 20+ (pinned, checked against nodejs.org's SHASUMS256).
    static let nodeVersion = "v22.23.4"
    static let officialBundleId = "sh.paseo.desktop"

    private(set) var status: Status?
    /// Version of the CLI this app installed (runtime/node_modules/@getpaseo/cli).
    private(set) var installedVersion: String?
    private(set) var latestVersion: String?
    /// Current step while installing / migrating / updating.
    private(set) var step: String?
    private(set) var log: [String] = []
    var error: String?

    let home: URL
    let support: URL
    let label: String
    /// Test mode (DEBUG, PASEO_LOCAL_HOME): a separate home, label and support folder; ~/.local/bin is left alone.
    let isTest: Bool

    private var runtime: URL { support.appending(path: "runtime") }
    private var nodeDir: URL { support.appending(path: "node") }
    private var wrapper: URL { support.appending(path: "bin/paseo") }
    private var logFile: URL { support.appending(path: "logs/daemon.log") }
    private var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist") }
    private var cliLink: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/paseo") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: wrapper.path) }
    var isServiceInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    var isBusy: Bool { step != nil }

    private init() {
        let fm = FileManager.default
        var testHome: String?
        #if DEBUG
        testHome = ProcessInfo.processInfo.environment["PASEO_LOCAL_HOME"]
        #endif
        if let testHome {
            let h = URL(filePath: (testHome as NSString).expandingTildeInPath)
            home = h
            support = h.deletingLastPathComponent().appending(path: "support")
            label = "sh.paseo.native.daemon.test"
            isTest = true
        } else {
            home = fm.homeDirectoryForCurrentUser.appending(path: ".paseo")
            support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Paseo Native")
            label = "sh.paseo.native.daemon"
            isTest = false
        }
    }

    // MARK: Status

    /// Reads `paseo daemon status` with our CLI if installed, else any `paseo` on the login PATH (the desktop app's).
    func refresh() async {
        installedVersion = readInstalledVersion()
        // 官方 App 不一定把 CLI 装进 PATH；找不到时用它包里自带的，否则官方 daemon 在跑也会被当成「没有运行」
        var cli = isInstalled ? wrapper.path : await loginExecutable("paseo")
        if cli == nil { cli = Self.officialBundledCLI() }
        guard let cli else { status = Status(owner: .stopped); return }
        guard let out = try? await run(cli, ["daemon", "status", "--json", "--home", home.path], timeout: 30),
              let data = out.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            status = Status(owner: .stopped)
            return
        }
        let running = (json["localDaemon"] as? String) == "running"
        let node = json["daemonNode"] as? String ?? ""
        let owner: Owner = !running ? .stopped
            : (json["desktopManaged"] as? Bool) == true ? .official
            : node.hasPrefix(nodeDir.path) || isServiceInstalled ? .native : .other
        status = Status(owner: owner, version: json["daemonVersion"] as? String,
                        serverId: json["serverId"] as? String, listen: json["listen"] as? String)
    }

    /// 官方 App 包内自带的 CLI（Contents/Resources/bin/paseo）。
    static func officialBundledCLI() -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: officialBundleId) else { return nil }
        let cli = app.appending(path: "Contents/Resources/bin/paseo").path
        return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
    }

    func checkLatest() async {
        guard let npm = await npmPath(),
              let out = try? await run(npm, ["view", "@getpaseo/cli", "version"], env: toolEnv(), timeout: 60) else { return }
        let v = out.output.trimmingCharacters(in: .whitespacesAndNewlines)
        latestVersion = v.isEmpty ? nil : v
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion, let current = installedVersion else { return false }
        return latest.compare(current, options: .numeric) == .orderedDescending
    }

    // MARK: Actions

    /// Fresh machine: install Node (if needed) and the CLI, then run the daemon as a LaunchAgent.
    func install() async { await perform { try await self.installCLI(Self.initialVersion); try await self.startService() } }

    /// Desktop app → this app: quit it, stop its daemon, start ours on the same home, repoint ~/.local/bin/paseo.
    func migrateFromOfficial() async {
        await perform {
            if !self.isInstalled { try await self.installCLI(self.status?.version ?? Self.initialVersion) }
            self.step = String(localized: "退出官方 Paseo App")
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.officialBundleId) { app.terminate() }
            for _ in 0..<30 where !NSRunningApplication.runningApplications(withBundleIdentifier: Self.officialBundleId).isEmpty {
                try await Task.sleep(for: .milliseconds(500))
            }
            self.step = String(localized: "停止官方 App 的 daemon")
            _ = try? await self.run(self.wrapper.path, ["daemon", "stop", "--home", self.home.path], timeout: 60)
            try await self.startService()
            if !self.isTest { try self.relinkCLI() }
        }
    }

    /// 官方 Paseo App 是否装在这台 Mac 上（「切回官方 App」的前提）。
    var officialAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.officialBundleId) }

    /// This app → desktop app（migrateFromOfficial 的反向）：停掉并移走本 App 的开机启动项，~/.local/bin/paseo 指回原处，
    /// 再打开官方 App，由它用同一个 ~/.paseo 启动 daemon，机器 ID 和配对不变。装好的命令行和 Node 留着，以后再切回来不用重装。
    func returnToOfficial() async {
        await perform {
            guard let app = self.officialAppURL else { throw Failure(String(localized: "这台 Mac 上没有找到官方 Paseo App，先装好它再切回去")) }
            self.step = String(localized: "停止本 App 的 daemon")
            _ = try? await self.launchctl(["disable", self.serviceTarget])
            _ = try? await self.launchctl(["bootout", self.serviceTarget])
            for _ in 0..<30 {
                await self.refresh()
                if self.status?.owner == .stopped { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard self.status?.owner == .stopped else { throw Failure(String(localized: "本 App 的 daemon 没有停下来，看看日志：\(self.logFile.path)")) }
            // 启动项文件移到废纸篓（可恢复）；以后再点「改由本 App 运行」会重新生成
            if self.isServiceInstalled { try FileManager.default.trashItem(at: self.plist, resultingItemURL: nil) }
            if self.isTest { return }
            try self.restoreCLILink()
            self.step = String(localized: "打开官方 Paseo App")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
            self.step = String(localized: "等待官方 App 启动 daemon")
            for _ in 0..<60 {
                await self.refresh()
                if self.status?.owner == .official { return }
                try await Task.sleep(for: .seconds(1))
            }
            throw Failure(String(localized: "官方 App 已打开，但 60 秒内没看到它启动 daemon；可以在官方 App 里看看，或稍后回到这里刷新"))
        }
    }

    /// Latest CLI from npm, then restart the daemon on it.
    func update() async {
        await perform {
            await self.checkLatest()
            guard let latest = self.latestVersion else { throw Failure(String(localized: "查不到最新版本")) }
            try await self.installCLI(latest)
            try await self.startService(step: String(localized: "重启 daemon"))
        }
    }

    /// Reloads the LaunchAgent rather than `kickstart -k`, so a LaunchAgent written by an older version
    /// picks up the current environment (LANG).
    func restart() async { await perform { try await self.startService(step: String(localized: "重启 daemon")) } }

    func stop() async {
        await perform {
            self.step = String(localized: "停止 daemon")
            // Disabled survives logout and reboot: the LaunchAgent stays off until 「启动」.
            _ = try? await self.launchctl(["disable", self.serviceTarget])
            _ = try? await self.launchctl(["bootout", self.serviceTarget])
            for _ in 0..<30 {
                await self.refresh()
                if self.status?.owner == .stopped { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func start() async { await perform { try await self.startService() } }

    func logTail(lines: Int = 200) -> String {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return String(localized: "（还没有日志）") }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Pairing link of the local daemon, so the app can add it as a machine without copying anything.
    func pairingLink() async -> String? {
        guard isInstalled, let out = try? await run(wrapper.path, ["daemon", "pair", "--json", "--home", home.path], timeout: 60),
              let data = out.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["url"] as? String
    }

    // MARK: Steps

    private func perform(_ body: @escaping () async throws -> Void) async {
        guard step == nil else { return }
        error = nil
        log = []
        do { try await body() } catch { self.error = "\(error)" }
        step = nil
        await refresh()
    }

    private func installCLI(_ version: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try fm.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        step = String(localized: "准备 Node")
        let node = try await ensureNode()
        step = String(localized: "安装 Paseo 命令行 \(version)（约 1–2 分钟）")
        let npm = node.deletingLastPathComponent().appending(path: "npm").path
        let result = try await run(npm, ["install", "--prefix", runtime.path, "@getpaseo/cli@\(version)",
                                         "--no-fund", "--no-audit", "--loglevel=error"], env: toolEnv(nodeBin: node.deletingLastPathComponent()), timeout: 900)
        if result.status != 0 { throw Failure(String(localized: "npm 安装失败：\(String(result.output.suffix(600)))")) }
        try await writeWrapper(nodeDir: node.deletingLastPathComponent().path)
        installedVersion = readInstalledVersion()
    }

    /// The wrapper pins our Node and the shell's PATH, so provider CLIs (claude, codex) resolve like in a terminal.
    /// Rewritten on every start, so a PATH added to ~/.zshrc later is picked up by 「重启」.
    private func writeWrapper(nodeDir: String) async throws {
        let path = nodeDir + ":" + (await loginPath())
        let script = """
        #!/bin/sh
        # Written by Paseo Native: the official Paseo CLI with the Node it was installed for.
        export PATH="\(path)"
        exec "\(runtime.path)/node_modules/.bin/paseo" "$@"

        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    /// The Mac's language and region as a UTF-8 locale (zh_CN.UTF-8), like Terminal.app; en_US.UTF-8 when it has none.
    static var utf8Locale: String {
        let name = (Locale.current.language.languageCode?.identifier ?? "en") + "_" + (Locale.current.region?.identifier ?? "US") + ".UTF-8"
        return FileManager.default.fileExists(atPath: "/usr/share/locale/" + name) ? name : "en_US.UTF-8"
    }

    private var serviceTarget: String { "gui/\(getuid())/\(label)" }

    private func startService(step stepTitle: String = String(localized: "设置开机自动启动")) async throws {
        step = stepTitle
        cachedLoginPath = nil
        let path = await loginPath()
        if let nodeDir = readWrapperNodeDir() { try await writeWrapper(nodeDir: nodeDir) }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [wrapper.path, "daemon", "run", "--home", home.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            // LANG: launchd gives none, and terminals inherit it from the daemon; without it zsh runs in the C locale
            // and shows Chinese as <008e>-style garbage (Terminal.app sets LANG itself).
            "EnvironmentVariables": ["PATH": path, "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LANG": Self.utf8Locale],
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        _ = try? await launchctl(["bootout", serviceTarget])
        step = String(localized: "启动 daemon")
        _ = try? await launchctl(["enable", serviceTarget])
        try await launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        try await waitUntilRunning()
    }

    private func waitUntilRunning() async throws {
        for _ in 0..<90 {
            await refresh()
            if status?.owner == .native { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure(String(localized: "daemon 没有在 90 秒内启动，看看日志：\(logFile.path)"))
    }

    /// ~/.local/bin/paseo → our wrapper; the previous target is remembered so it can be restored.
    private func relinkCLI() throws {
        let fm = FileManager.default
        if let old = try? fm.destinationOfSymbolicLink(atPath: cliLink.path), old != wrapper.path {
            AppDefaults.store.set(old, forKey: "localDaemon.previousCLILink")
        }
        try fm.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.attributesOfItem(atPath: cliLink.path)) != nil { try fm.removeItem(at: cliLink) }
        try fm.createSymbolicLink(at: cliLink, withDestinationURL: wrapper)
    }

    var previousCLILink: String? { AppDefaults.store.string(forKey: "localDaemon.previousCLILink") }

    /// ~/.local/bin/paseo 只在指向本 App 的命令行时才改：指回改之前记下的目标（还存在的话），否则指向官方 App 包里的命令行，
    /// 都没有就去掉这个链接。用户自己改过的链接不动。
    private func restoreCLILink() throws {
        let fm = FileManager.default
        guard let current = try? fm.destinationOfSymbolicLink(atPath: cliLink.path), current == wrapper.path else { return }
        let target = [previousCLILink, Self.officialBundledCLI()].compactMap { $0 }
            .first { $0 != wrapper.path && fm.isExecutableFile(atPath: $0) }
        try fm.removeItem(at: cliLink)
        if let target { try fm.createSymbolicLink(at: cliLink, withDestinationURL: URL(filePath: target)) }
        AppDefaults.store.removeObject(forKey: "localDaemon.previousCLILink")
    }

    // MARK: Node

    /// Node 20+ from the login PATH, else the pinned Node under Application Support (downloaded once).
    private func ensureNode() async throws -> URL {
        let bundled = nodeDir.appending(path: "bin/node")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        var forceDownload = false
        #if DEBUG
        forceDownload = ProcessInfo.processInfo.environment["PASEO_FORCE_NODE_DOWNLOAD"] == "1"
        #endif
        if !forceDownload, let node = await loginExecutable("node"),
           let v = try? await run(node, ["--version"], timeout: 10),
           let major = Int(v.output.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").first ?? ""),
           major >= 20 {
            return URL(filePath: node)
        }
        try await downloadNode()
        return bundled
    }

    private func downloadNode() async throws {
        step = String(localized: "下载 Node \(Self.nodeVersion)")
        var machine = utsname()
        uname(&machine)
        let arch = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let name = "node-\(Self.nodeVersion)-darwin-\(arch == "arm64" ? "arm64" : "x64").tar.gz"
        let base = URL(string: "https://nodejs.org/dist/\(Self.nodeVersion)/")!
        let (sums, _) = try await URLSession.shared.data(from: base.appending(path: "SHASUMS256.txt"))
        guard let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n")
            .first(where: { $0.hasSuffix("  " + name) })?.split(separator: " ").first.map(String.init) else {
            throw Failure(String(localized: "nodejs.org 的校验文件里没有 \(name)"))
        }
        let (file, _) = try await URLSession.shared.download(from: base.appending(path: name))
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw Failure(String(localized: "Node 安装包校验失败")) }
        let fm = FileManager.default
        try? fm.removeItem(at: nodeDir)
        try fm.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        let r = try await run("/usr/bin/tar", ["-xzf", file.path, "-C", nodeDir.path, "--strip-components", "1"], timeout: 300)
        if r.status != 0 { throw Failure(String(localized: "解压 Node 失败：\(r.output)")) }
    }

    private func npmPath() async -> String? {
        if isInstalled, let node = readWrapperNodeDir() { return node + "/npm" }
        return await loginExecutable("npm")
    }

    private func toolEnv(nodeBin: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = nodeBin?.path ?? readWrapperNodeDir()
        env["PATH"] = [dir, cachedLoginPath ?? env["PATH"]].compactMap { $0 }.joined(separator: ":")
        return env
    }

    private func readWrapperNodeDir() -> String? {
        guard let text = try? String(contentsOf: wrapper, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("export PATH=\"") }) else { return nil }
        return line.dropFirst("export PATH=\"".count).split(separator: ":").first.map(String.init)
    }

    private func readInstalledVersion() -> String? {
        let pkg = runtime.appending(path: "node_modules/@getpaseo/cli/package.json")
        guard let data = try? Data(contentsOf: pkg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    // MARK: Shell

    private var cachedLoginPath: String?

    /// PATH of the user's shell (the app itself starts with launchd's minimal PATH). Interactive login first, like the
    /// official desktop app: installers (Claude Code, nvm, npm prefix) often add their PATH only to ~/.zshrc, which a
    /// plain login shell skips. The value is read between markers, since rc files may print banners.
    private func loginPath() async -> String {
        if let cachedLoginPath { return cachedLoginPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__PASEO_PATH_\(UUID().uuidString.prefix(8))__"
        var path = ""
        for args in [["-i", "-l", "-c"], ["-l", "-c"]] {
            guard let out = try? await run(shell, args + ["printf '%s%s%s' \(marker) \"$PATH\" \(marker)"], timeout: 20),
                  let r = out.output.range(of: marker),
                  let end = out.output.range(of: marker, range: r.upperBound..<out.output.endIndex) else { continue }
            path = String(out.output[r.upperBound..<end.lowerBound])
            if !path.isEmpty { break }
        }
        if path.isEmpty { path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        cachedLoginPath = path
        return path
    }

    private func loginExecutable(_ name: String) async -> String? {
        let fm = FileManager.default
        for dir in (await loginPath()).split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func launchctl(_ args: [String]) async throws {
        let r = try await run("/bin/launchctl", args, timeout: 60)
        if r.status != 0 { throw Failure("launchctl \(args.first ?? "")：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    struct Output { let status: Int32; let output: String }

    /// Runs a process off the main actor; stdout and stderr together, killed after `timeout` seconds.
    private func run(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval) async throws -> Output {
        log.append("$ " + ([exe] + args).joined(separator: " "))
        let result: Output = try await Task.detached {
            let p = Process()
            p.executableURL = URL(filePath: exe)
            p.arguments = args
            if let env { p.environment = env }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return Output(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
        let tail = result.output.split(separator: "\n").suffix(5).joined(separator: "\n")
        if !tail.isEmpty { log.append(tail) }
        return result
    }
}
#endif
