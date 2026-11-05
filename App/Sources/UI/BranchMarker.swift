import SwiftUI
import PaseoKit

/// 会话在哪个分支 / worktree 上：输入框上方的分支胶囊和侧边栏的 worktree 树图标共用。
@MainActor
struct BranchMarker {
    /// 会话所在的 worktree 工作区（kind == worktree）；不在 worktree 里为 nil
    let worktree: Workspace?
    let branch: String?
    let directory: String

    /// 自己的工作区就是 worktree 的直接用；没有工作区的子会话按工作目录找它落在哪个 worktree 里
    init(agent: Agent?, workspace: Workspace?, host: HostStore) {
        let wt: Workspace?
        if let workspace, workspace.kind == "worktree" {
            wt = workspace
        } else if workspace == nil, let cwd = agent?.cwd, !cwd.isEmpty {
            wt = host.workspaces.values.filter { $0.kind == "worktree" && !$0.directory.isEmpty && (cwd == $0.directory || cwd.hasPrefix($0.directory + "/")) }
                .max { $0.directory.count < $1.directory.count }
        } else {
            wt = nil
        }
        worktree = wt
        branch = (wt ?? workspace)?.currentBranch
        directory = wt?.directory ?? workspace?.directory ?? agent?.cwd ?? ""
    }

    var inWorktree: Bool { worktree != nil }

    /// 输入框上方要不要显示：在 worktree 里，或者在 main / master 以外的分支上
    var showsChip: Bool {
        if inWorktree { return true }
        guard let branch, !branch.isEmpty else { return false }
        return !["main", "master"].contains(branch)
    }

    /// 胶囊上的字：分支名；拿不到分支（子会话）就用 worktree 目录名
    var label: String { branch ?? (directory as NSString).lastPathComponent }

    var help: String {
        var lines: [String] = []
        if let branch { lines.append(String(localized: "分支 \(branch)")) }
        if inWorktree { lines.append(String(localized: "worktree \(directory)")) }
        return lines.joined(separator: "\n")
    }
}

/// 输入框上方的分支胶囊，点一下复制分支名。
struct BranchChip: View {
    let marker: BranchMarker

    var body: some View {
        Button {
            Pasteboard.copy(marker.branch ?? marker.directory)
        } label: {
            Chip {
                Image(systemName: marker.inWorktree ? "tree" : "arrow.triangle.branch")
                Text(marker.label).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
            }
        }
        .buttonStyle(.plain)
        .help(marker.help + "\n" + (marker.branch == nil ? String(localized: "点击复制目录") : String(localized: "点击复制分支名")))
    }
}
