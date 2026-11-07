import Foundation
import Testing
@testable import PaseoKit

@Suite(.timeLimit(.minutes(1))) @MainActor struct BaseBranchTests {
    private func fixture() async throws -> (HostStore, RecoveryTransport, DaemonConnection, Workspace) {
        let transport = RecoveryTransport()
        let connection = DaemonConnection(channel: transport)
        try await connection.handshake(hello: HelloOptions(clientId: "test"), expectedServerId: "test")
        let host = HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "测试", clientId: "test", appVersion: "test")
        host.connection = connection
        host.serverInfo = ServerInfo(raw: ["features": ["workspaceBaseBranch": true]])
        let workspace = try #require(Workspace(["id": "w", "workspaceKind": "worktree", "workspaceDirectory": "/tmp/repo/worktree"]))
        return (host, transport, connection, workspace)
    }

    @Test func acceptedChangeRefreshesAuthoritativeStatus() async throws {
        let (host, transport, connection, workspace) = try await fixture()
        let change = Task { try await host.setWorkspaceBaseBranch(workspace, baseRef: "refs/remotes/origin/main") }
        let request = try #require(await transport.nextSent("workspace.base_branch.set.request"))
        #expect(request["workspaceId"]?.stringValue == "w")
        #expect(request["baseRef"]?.stringValue == "refs/remotes/origin/main")
        await transport.reply(to: request, type: "workspace.base_branch.set.response", payload: ["accepted": true, "baseRef": "origin/main"])
        let status = try #require(await transport.nextSent("checkout_status_request"))
        #expect(status["cwd"]?.stringValue == workspace.directory)
        await transport.reply(to: status, type: "checkout_status_response", payload: ["baseRef": "origin/main"])
        try await change.value
        #expect(host.checkoutStatus[workspace.directory]?.baseRef == "origin/main")
        await connection.close()
    }

    @Test func rejectedChangeIsAnErrorAndDoesNotUpdateStatus() async throws {
        let (host, transport, connection, workspace) = try await fixture()
        let change = Task { try await host.setWorkspaceBaseBranch(workspace, baseRef: "missing") }
        let request = try #require(await transport.nextSent("workspace.base_branch.set.request"))
        await transport.reply(to: request, type: "workspace.base_branch.set.response", payload: ["accepted": false, "error": "分支不存在"])
        await #expect(throws: HostStore.ActionError.self) { try await change.value }
        #expect(host.checkoutStatus[workspace.directory] == nil)
        await connection.close()
    }

    @Test func oldDaemonAndDirectoryWorkspaceRejectOperation() async throws {
        let (host, _, connection, workspace) = try await fixture()
        let directory = try #require(Workspace(["id": "directory", "workspaceKind": "directory"]))
        await #expect(throws: HostStore.ActionError.self) { try await host.setWorkspaceBaseBranch(directory, baseRef: "main") }
        host.serverInfo = ServerInfo(raw: ["features": [:]])
        #expect(!host.supportsWorkspaceBaseBranch)
        await #expect(throws: HostStore.ActionError.self) { try await host.setWorkspaceBaseBranch(workspace, baseRef: "main") }
        await connection.close()
    }

    @Test func branchSearchFailureIsNotAnEmptyResult() async throws {
        let (host, transport, connection, _) = try await fixture()
        let search = Task { try await host.fetchBranchSuggestions(cwd: "/tmp/repo", query: "main") }
        let request = try #require(await transport.nextSent("branch_suggestions_request"))
        await transport.reply(to: request, type: "branch_suggestions_response", payload: ["branches": [], "error": "Git 不可用"])
        await #expect(throws: HostStore.ActionError.self) { try await search.value }
        await connection.close()
    }
}
