import Foundation
import Testing
@testable import PaseoKit

struct WorkspaceURLTests {
    private func workspace(remote: String, branch: String = "feat/x") -> Workspace {
        Workspace(["id": "wks_1", "gitRuntime": ["remoteUrl": .string(remote), "currentBranch": .string(branch)]])!
    }

    @Test(arguments: [
        ("git@github.com:me/app.git", "https://github.com/me/app/tree/feat/x"),
        ("https://github.com/me/app.git", "https://github.com/me/app/tree/feat/x"),
        ("ssh://git@git.example.com:2222/team/app.git", "https://git.example.com/team/app/tree/feat/x"),
        ("git@gitlab.com:team/app.git", "https://gitlab.com/team/app/-/tree/feat/x"),
    ])
    func branchURL(remote: String, expected: String) {
        #expect(workspace(remote: remote).branchWebURL?.absoluteString == expected)
    }
}
