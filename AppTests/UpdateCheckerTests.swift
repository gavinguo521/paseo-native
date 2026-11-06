import Foundation
import Testing
@testable import Paseo

@MainActor struct UpdateCheckerTests {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        func advance(_ seconds: TimeInterval) { date += seconds }
    }
    private func release(_ version: String = "99.0.0") -> UpdateChecker.Release {
        .init(version: version, notes: "测试更新", page: URL(string: "https://example.invalid/release")!, download: nil)
    }
    private func defaults() -> (String, UserDefaults) {
        let name = "update-tests-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test func automaticChecksAreThrottledAcrossActivationAndRestart() async {
        let (name, store) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let clock = Clock()
        var calls = 0
        let fetch = { calls += 1; return release() }
        let checker = UpdateChecker(defaults: store, now: { clock.date }, repo: "test/repo", fetch: fetch)
        await checker.check(manual: false)
        #expect(calls == 1 && checker.prompt != nil)
        checker.prompt = nil
        clock.advance(1799)
        await checker.check(manual: false)
        #expect(calls == 1)
        clock.advance(1)
        await checker.check(manual: false)
        #expect(calls == 2 && checker.prompt == nil)
        let restarted = UpdateChecker(defaults: store, now: { clock.date }, repo: "test/repo", fetch: fetch)
        #expect(restarted.availableRelease == release())
        await restarted.check(manual: false)
        #expect(calls == 2)
        clock.advance(1800)
        await restarted.check(manual: false)
        #expect(calls == 3 && restarted.prompt == nil)
    }

    @Test func laterRemindsAfterOneDayAndSkipPersistsButManualCanCheck() async {
        let (name, store) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let clock = Clock()
        let current = release()
        let checker = UpdateChecker(defaults: store, now: { clock.date }, repo: "test/repo", fetch: { current })
        await checker.check(manual: false)
        checker.remindLater(current)
        clock.advance(23 * 3600)
        await checker.check(manual: false)
        #expect(checker.prompt == nil)
        let restarted = UpdateChecker(defaults: store, now: { clock.date }, repo: "test/repo", fetch: { current })
        clock.advance(3600)
        await restarted.check(manual: false)
        #expect(restarted.prompt == current)
        restarted.skip(current)
        clock.advance(86400)
        await restarted.check(manual: false)
        #expect(restarted.prompt == nil && restarted.availableRelease == current)
        restarted.autoCheck = false
        await restarted.check(manual: true)
        #expect(restarted.prompt == current)
    }

    @Test func failedChecksAreThrottledAndKeepDownloadEntry() async {
        let (name, store) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let clock = Clock()
        var calls = 0
        let checker = UpdateChecker(defaults: store, now: { clock.date }, repo: "test/repo") {
            calls += 1
            if calls > 1 { throw URLError(.notConnectedToInternet) }
            return release()
        }
        await checker.check(manual: false)
        checker.prompt = nil
        clock.advance(1800)
        await checker.check(manual: false)
        #expect(checker.availableRelease == release() && checker.notice == nil)
        await checker.check(manual: false)
        #expect(calls == 2)
        await checker.check(manual: true)
        #expect(calls == 3 && checker.notice != nil)
    }

    @Test func newerReleaseIsNotSuppressedByPreviousSkip() async {
        let (name, store) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let clock = Clock()
        let old = release(), new = release("99.0.1")
        var latest = old
        let checker = UpdateChecker(defaults: store, now: { clock.date }, repo: "test/repo", fetch: { latest })
        await checker.check(manual: false)
        checker.skip(old)
        latest = new
        clock.advance(1800)
        await checker.check(manual: false)
        #expect(checker.prompt == new)
        #expect(UpdateChecker.isNewer("1.0.14", than: "1.0.13"))
        #expect(!UpdateChecker.isNewer("1.0.13", than: "1.0.13"))
    }

    @Test func concurrentTriggersShareRequestAndDisablingStopsPrompt() async {
        let (name, store) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let (events, signal) = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<UpdateChecker.Release, any Error>?
        var calls = 0
        let checker = UpdateChecker(defaults: store, repo: "test/repo") {
            calls += 1
            return try await withCheckedThrowingContinuation {
                finish = $0
                signal.yield(())
            }
        }
        let request = Task { await checker.check(manual: false) }
        for await _ in events { break }
        await checker.check(manual: false)
        #expect(calls == 1)
        checker.autoCheck = false
        finish?.resume(returning: release())
        await request.value
        #expect(checker.prompt == nil && checker.availableRelease == release())
        signal.finish()
    }
}
