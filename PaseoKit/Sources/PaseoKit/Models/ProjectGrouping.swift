import Foundation

/// 侧边栏项目自动合并规则，对齐官方 createProjectViewKey（packages/app/src/projects/workspace-structure.ts）：
/// daemon 给每个项目算的 projectKey（有远端时是 `remote:主机/路径`，子目录再带 `#subdir:`）在某台机器上唯一时，
/// 不同机器的同仓库项目合成一组；同一台机器上撞 key（同仓库两份 clone）的各自单独一组。
/// 和官方不同的一处：手动 `git worktree add` 出来的目录 daemon 会单独建项目（工作区 kind 是 worktree），
/// 官方在同一台机器上把它当撞 key 拆开，这里不算撞 key，让它跟主仓库并在一起（比如每批任务各开一个 worktree 的用法）。
public enum ProjectGrouping {
    public struct Member: Sendable, Hashable {
        public let serverId: String
        public let projectId: String
        public let name: String
        public let rootPath: String
        public let projectKey: String?
        /// 这个项目的工作区是 git worktree（不是独立 clone），不参与同机撞 key 判断
        public let isWorktree: Bool

        public init(serverId: String, projectId: String, name: String, rootPath: String, projectKey: String?, isWorktree: Bool = false) {
            self.serverId = serverId
            self.projectId = projectId
            self.name = name
            self.rootPath = rootPath
            self.projectKey = projectKey
            self.isWorktree = isWorktree
        }
    }

    /// 返回 `"serverId|项目名" → 组名`，只含需要改名并入别组的项目；不在表里的按自己的名字显示。
    public static func autoAliases(_ members: [Member]) -> [String: String] {
        // 同一台机器上同一个 key 的独立 clone 数；>1 说明撞 key，这个 key 在这台机器上整体不参与合并（官方 placement key）
        var idsPerServerKey: [String: Set<String>] = [:]
        for m in members {
            guard let k = m.projectKey, !k.isEmpty else { continue }
            guard !m.isWorktree else { continue }
            idsPerServerKey[m.serverId + "\u{1}" + k, default: []].insert(m.projectId)
        }
        var byKey: [String: [Member]] = [:]
        for m in Set(members) {
            guard let k = m.projectKey, !k.isEmpty, (idsPerServerKey[m.serverId + "\u{1}" + k]?.count ?? 0) <= 1 else { continue }
            byKey[k, default: []].append(m)
        }
        var out: [String: String] = [:]
        for (key, list) in byKey {
            let names = Set(list.map(\.name))
            guard names.count > 1 else { continue }
            let canonical = canonicalName(list, key: key)
            for m in list where m.name != canonical { out[m.serverId + "|" + m.name] = canonical }
        }
        return out
    }

    /// 组名：先用起过自定义名的（名字和目录名不同），再用和仓库同名的，再用非 worktree 的，最后取最短的名字。
    static func canonicalName(_ list: [Member], key: String) -> String {
        let repo = repoName(key)
        func rank(_ m: Member) -> Int {
            let dir = (m.rootPath as NSString).lastPathComponent
            if !dir.isEmpty && m.name != dir { return 0 }
            if let repo, m.name.caseInsensitiveCompare(repo) == .orderedSame { return 1 }
            return m.isWorktree ? 3 : 2
        }
        return list.min { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }!.name
    }

    /// key 里的仓库名：`remote:host/owner/repo` → repo；带 `#subdir:a/b` 时取 b。本地路径 key 取最后一段。
    static func repoName(_ key: String) -> String? {
        if let r = key.range(of: "#subdir:") {
            return key[r.upperBound...].split(separator: "/").last.map(String.init)
        }
        let last = key.split(separator: "/").last.map(String.init)
        return last?.hasSuffix(".git") == true ? String(last!.dropLast(4)) : last
    }
}
