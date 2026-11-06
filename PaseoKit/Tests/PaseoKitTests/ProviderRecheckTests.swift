import Foundation
import Testing
@testable import PaseoKit

struct ProviderRecheckTests {
    @Test func picksOnlyEnabledUnavailableProviders() throws {
        let entries = try JSONValue.parse(#"""
        [
          {"provider":"claude","status":"ready","enabled":true},
          {"provider":"codex","status":"unavailable","enabled":true},
          {"provider":"omp","status":"unavailable","enabled":false},
          {"provider":"opencode","status":"loading","enabled":true},
          {"provider":"muse","status":"error","enabled":true}
        ]
        """#).arrayValue ?? []
        #expect(ProviderRecheck.candidates(in: entries) == ["codex"])
    }

    @Test func firstCheckIsAlwaysDue() {
        #expect(ProviderRecheck.isDue(last: nil, now: .now))
    }

    @Test func throttlesUntilIntervalPasses() {
        let start = ContinuousClock.now
        #expect(!ProviderRecheck.isDue(last: start, now: start.advanced(by: .seconds(29))))
        #expect(ProviderRecheck.isDue(last: start, now: start.advanced(by: ProviderRecheck.minimumInterval)))
    }
}
