import Foundation
import Testing
@testable import PaseoKit

struct ProjectSuggestionTests {
    private func suggestion(_ root: String, count: Int, providers: [String], at: String) throws -> ProjectSuggestion {
        let json = #"{"rootPath":"\#(root)","displayName":"x","sessionCount":\#(count),"providerIds":["\#(providers.joined(separator: "\",\""))"],"lastActivityAt":"\#(at)"}"#
        return try #require(ProjectSuggestion(try JSONValue.parse(json)))
    }

    @Test func parsesDaemonPayload() throws {
        let s = try suggestion("/r/a", count: 3, providers: ["claude"], at: "2026-11-05T09:08:05.123Z")
        #expect(s.id == "/r/a")
        #expect(s.sessionCount == 3)
        #expect(s.providerIds == ["claude"])
        #expect(s.lastActivityAt != nil)
    }

    @Test func rejectsEntryWithoutRoot() throws {
        #expect(ProjectSuggestion(try JSONValue.parse(#"{"displayName":"x"}"#)) == nil)
    }

    @Test func combinesAFolderAcrossProviders() throws {
        let merged = ProjectSuggestion.merge([
            [try suggestion("/r/a", count: 2, providers: ["codex"], at: "2026-11-01T00:00:00.000Z")],
            [try suggestion("/r/a", count: 3, providers: ["claude"], at: "2026-11-03T00:00:00.000Z")],
        ])
        #expect(merged.count == 1)
        #expect(merged[0].sessionCount == 5)
        #expect(merged[0].providerIds == ["claude", "codex"])
        #expect(merged[0].lastActivityAt == (try suggestion("/r/b", count: 0, providers: [], at: "2026-11-03T00:00:00.000Z")).lastActivityAt)
    }

    @Test func sortsMostRecentFirst() throws {
        let merged = ProjectSuggestion.merge([[
            try suggestion("/r/old", count: 9, providers: ["claude"], at: "2026-10-01T00:00:00.000Z"),
            try suggestion("/r/new", count: 1, providers: ["claude"], at: "2026-11-01T00:00:00.000Z"),
        ]])
        #expect(merged.map(\.rootPath) == ["/r/new", "/r/old"])
    }
}
