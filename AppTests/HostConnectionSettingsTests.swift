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
        defer {
            AppDefaults.store.removeObject(forKey: key)
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

        restored.setAutomaticConnectionPaused(host: restoredHost, true)
        restored.removeHost(id)
        #expect(AppDefaults.store.object(forKey: key) == nil)
        #expect(AppModel().host(id) == nil)
    }
}
