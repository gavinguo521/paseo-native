import Foundation

extension HostStore {
    /// daemon 能撤销工作区归档（官方 0.15.3 起，`features.workspaceArchiveUndo`）：归档还在进行就取消，
    /// 已完成就恢复工作区（worktree 会重建）并取消归档当时一起归档的会话。
    public var supportsWorkspaceArchiveUndo: Bool { serverInfo?.hasFeature("workspaceArchiveUndo") == true }

    /// 撤销这个工作区最近一次归档（官方 workspace.archive.undo）。daemon 没能恢复时抛错。
    public func undoWorkspaceArchive(_ id: String) async throws {
        // 撤销已完成的 worktree 归档要重建 worktree，官方给 150 秒。
        let r = try await conn().request("workspace.archive.undo.request", ["workspaceId": .string(id)], timeout: .seconds(150))
        guard r["payload"]?["accepted"]?.boolValue == true else {
            throw ActionError.rejected(r["payload"]?["error"]?.stringValue ?? String(localized: "撤销归档失败", bundle: .module))
        }
    }

    /// 归档 worktree 前现查的 git 状态（官方 #9625）：侧栏缓存的增删行数看不到只有新文件或只有未推送提交的情况。
    /// 不写入 `checkoutStatus` 缓存；daemon 读不了这个目录时抛错。
    public func worktreeArchiveRisk(directory: String) async throws -> WorktreeArchiveRisk {
        let r = try await conn().request("checkout_status_request", ["cwd": .string(directory)], timeout: .seconds(20))
        guard let p = r["payload"] else { throw ActionError.rejected(String(localized: "读取 git 状态失败", bundle: .module)) }
        if let e = p["error"], e != .null {
            throw ActionError.rejected(e["message"]?.stringValue ?? e.stringValue ?? String(localized: "读取 git 状态失败", bundle: .module))
        }
        return WorktreeArchiveRisk(p)
    }
}

/// 归档会删掉 worktree 目录，这里记下会丢的东西。
public struct WorktreeArchiveRisk: Sendable, Equatable {
    /// 有未提交的改动（含未跟踪的新文件，0.16 daemon 按 --untracked-files=normal 判断）。
    public let isDirty: Bool
    /// 没推送到远程的提交数。
    public let unpushedCommits: Int

    public var isSafe: Bool { !isDirty && unpushedCommits == 0 }

    public init(isDirty: Bool, unpushedCommits: Int) {
        self.isDirty = isDirty
        self.unpushedCommits = unpushedCommits
    }

    init(_ payload: JSONValue) {
        // 已经不是 git 仓库的目录两样都没有（同官方 readWorktreeArchiveRisk）。
        isDirty = payload["isDirty"]?.boolValue ?? false
        unpushedCommits = Int(payload["aheadOfOrigin"]?.doubleValue ?? 0)
    }
}
