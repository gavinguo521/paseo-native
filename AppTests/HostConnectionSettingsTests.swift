import Foundation
import Testing
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct HostConnectionSettingsTests {
    @Test func pauseSurvivesModelReloadAndOnlyAffectsSelectedHost() throws {
        // Use the test scheme's separate Keychain account and preferences only.
        try #require(AppDefaults.isTesting)
        let suffix = try #require(ProcessInfo.processInfo.environment["PASEO_HOSTS_KEY"])
        try #require(!suffix.isEmpty)
        let account = "hosts.v1." + suffix
        let previous = Keychain.load(account)
        let id = "pause-settings-" + UUID().uuidString
        let key = "hostAutoConnectPaused." + id
        let progressKey = "hostReconnectProgress." + id
        defer {
            AppDefaults.store.removeObject(forKey: key)
            AppDefaults.store.removeObject(forKey: progressKey)
            if let previous { Keychain.save(previous, account: account) }
            else { Keychain.delete(account) }
        }
        struct StoredHost: Encodable { let label: String; let offer: PairingOffer }
        let fixtures = [id, id + "-other"].map {
            StoredHost(label: $0, offer: .direct(serverId: $0, endpoint: "localhost:1", useTls: false, password: nil))
        }
        Keychain.save(try JSONEncoder().encode(fixtures), account: account)

        let model = AppModel()
        let host = try #require(model.host(id))
        model.setAutomaticConnectionPaused(host: host, true)
        #expect(host.state == .paused)
        #expect(model.host(id + "-other")?.automaticConnectionPaused == false)

        let restored = AppModel()
        let restoredHost = try #require(restored.host(id))
        restoredHost.start()
        #expect(restoredHost.state == .paused)
        #expect(restored.host(id + "-other")?.automaticConnectionPaused == false)
        restored.setAutomaticConnectionPaused(host: restoredHost, false)
        restoredHost.stop()
        #expect(AppModel().host(id)?.automaticConnectionPaused == false)

        let old = Date().addingTimeInterval(-(15 * 60 + 24 * 60 * 60 + 10))
        let progress = HostReconnectProgress(startedAt: old, failures: 6, retryAt: old)
        AppDefaults.store.set(try JSONEncoder().encode(progress), forKey: progressKey)
        // 客户端长时间没运行留下的旧进度不能在启动时直接暂停，要先真正试连。
        let stale = try #require(AppModel().host(id))
        stale.start()
        #expect(!stale.automaticConnectionPaused)
        stale.stop()
        AppDefaults.store.set(true, forKey: key)
        AppDefaults.store.set(try JSONEncoder().encode(progress), forKey: progressKey)
        let expiredAfterReload = try #require(AppModel().host(id))
        #expect(expiredAfterReload.automaticConnectionExpired)
        #expect(expiredAfterReload.reconnectProgress == progress)
        model.setAutomaticConnectionPaused(host: expiredAfterReload, false)
        expiredAfterReload.stop()
        #expect(AppDefaults.store.object(forKey: progressKey) == nil)

        restored.setAutomaticConnectionPaused(host: restoredHost, true)
        restored.removeHost(id)
        #expect(AppDefaults.store.object(forKey: key) == nil)
        #expect(AppModel().host(id) == nil)
    }
}
