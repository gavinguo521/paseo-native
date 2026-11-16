import Foundation
import Testing
@testable import PaseoKit

struct WorkspaceBaseBranchTests {
    @Test func checkoutStatusParsesExactAndComparisonRefs() throws {
        let s = CheckoutStatus(try JSONValue.parse(#"{"isGit":true,"baseRef":"main","baseRefExact":"refs/remotes/origin/main","comparisonBaseRef":"refs/remotes/origin/main"}"#))
        #expect(s.baseRef == "main")
        #expect(s.baseRefExact == "refs/remotes/origin/main")
        #expect(s.comparisonBaseRef == "refs/remotes/origin/main")
        #expect(s.selectedBaseRef == "refs/remotes/origin/main")
    }

    @Test func checkoutStatusFallsBackForOldDaemon() throws {
        let s = CheckoutStatus(try JSONValue.parse(#"{"isGit":true,"baseRef":"main","baseRefExact":null}"#))
        #expect(s.baseRefExact == nil)
        #expect(s.comparisonBaseRef == nil)
        #expect(s.selectedBaseRef == "main")
    }

    @Test func labels() {
        #expect(WorkspaceBaseBranch.refLabel("refs/remotes/origin/dev") == "origin/dev")
        #expect(WorkspaceBaseBranch.refLabel("refs/heads/feature/x") == "feature/x")
        #expect(WorkspaceBaseBranch.shortLabel("refs/remotes/origin/dev") == "dev")
        #expect(WorkspaceBaseBranch.shortLabel("main") == "main")
    }

    @Test func candidatesParseAndSurfaceError() throws {
        let ok = try JSONValue.parse(#"{"branches":["refs/heads/main","refs/remotes/origin/main"],"error":null,"requestId":"r"}"#)
        #expect(try WorkspaceBaseBranch.candidates(from: ok) == ["refs/heads/main", "refs/remotes/origin/main"])
        let bad = try JSONValue.parse(#"{"branches":[],"error":"Not a git repository","requestId":"r"}"#)
        #expect(throws: HostStore.ActionError.self) { try WorkspaceBaseBranch.candidates(from: bad) }
    }

    @Test func setResponseAcceptedAndRejected() throws {
        let ok = try JSONValue.parse(#"{"requestId":"r","workspaceId":"w","accepted":true,"baseRef":"refs/heads/dev","error":null}"#)
        #expect(try WorkspaceBaseBranch.appliedBaseRef(from: ok) == "refs/heads/dev")
        let bad = try JSONValue.parse(#"{"requestId":"r","workspaceId":"w","accepted":false,"baseRef":null,"error":"Workspace is not a Paseo worktree"}"#)
        do {
            _ = try WorkspaceBaseBranch.appliedBaseRef(from: bad)
            Issue.record("应抛出错误")
        } catch let e as HostStore.ActionError {
            #expect(e.description == "Workspace is not a Paseo worktree")
        }
    }
}
