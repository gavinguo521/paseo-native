import Testing
@testable import PaseoKit
@testable import Paseo

@MainActor struct LocalAttentionPolicyTests {
    @Test(arguments: ["current", "other-conversation", "settings"])
    func barkOwnsPhoneCompletionsOnEveryPage(page: String) async {
        let local = await LocalAttentionPolicy.shouldPost(event(), isViewing: { page == "current" }, barkEnabled: { true })
        #expect(!local)
    }

    @Test(arguments: ["current", "other-conversation", "settings"])
    func disabledBarkKeepsOriginalLocalRules(page: String) async {
        let local = await LocalAttentionPolicy.shouldPost(event(), isViewing: { page == "current" }, barkEnabled: { false })
        #expect(local == (page != "current"))
    }

    @Test func daemonSelectedAnotherClientStillSuppressesLocalDelivery() async {
        var lookedUp = false
        let local = await LocalAttentionPolicy.shouldPost(event(shouldNotify: false), isViewing: { false }, barkEnabled: {
            lookedUp = true
            return false
        })
        #expect(!local && !lookedUp)
    }

    @Test(arguments: ["permission", "error"])
    func barkDoesNotSuppressOrDelayOtherAttentionReasons(reason: String) async {
        var lookedUp = false
        let local = await LocalAttentionPolicy.shouldPost(event(reason: reason), isViewing: { false }, barkEnabled: {
            lookedUp = true
            return true
        })
        #expect(local && !lookedUp)
    }

    @Test func macKeepsLocalCompletionNotifications() async {
        #expect(await LocalAttentionPolicy.shouldPost(event(), isViewing: { false }))
    }

    @Test func openingTheConversationDuringLookupSuppressesTheLateBanner() async {
        var viewing = false
        let local = await LocalAttentionPolicy.shouldPost(event(), isViewing: { viewing }, barkEnabled: {
            viewing = true
            await Task.yield()
            return false
        })
        #expect(!local)
    }

    private func event(reason: String = "finished", shouldNotify: Bool = true) -> AttentionEvent {
        AttentionEvent(serverId: "test-host", agentId: "test-agent", reason: reason, title: "test", body: "done",
                       shouldNotify: shouldNotify, shouldPush: false)
    }
}
