import XCTest
@testable import PaseoKit

final class ProjectGroupingTests: XCTestCase {
    private let key = "remote:git.example.com/team/Invitation"

    private func m(_ s: String, _ id: String, _ name: String, _ root: String, _ key: String?, wt: Bool = false) -> ProjectGrouping.Member {
        .init(serverId: s, projectId: id, name: name, rootPath: root, projectKey: key, isWorktree: wt)
    }

    /// 这次的实际情况：Studio 只有 batch-04 worktree 项目，mini 有主仓库 Invitation，同一远端 → 并到「Invitation」
    func testWorktreeOnOneHostJoinsRepoOnAnother() {
        let a = ProjectGrouping.autoAliases([
            m("studio", "p1", "Invitation-wx-batch-04", "/x/Invitation-wx-batch-04", key, wt: true),
            m("mini", "p2", "Invitation", "/y/Invitation", key),
        ])
        XCTAssertEqual(a, ["studio|Invitation-wx-batch-04": "Invitation"])
    }

    /// 同一台机器上主仓库和多个 worktree 各是一个项目 → worktree 不算撞 key，全部并到主仓库
    func testWorktreesOnSameHostJoinMainRepo() {
        let a = ProjectGrouping.autoAliases([
            m("studio", "p1", "Invitation", "/x/Invitation", key),
            m("studio", "p2", "Invitation-wx-batch-04", "/x/Invitation-wx-batch-04", key, wt: true),
            m("studio", "p3", "Invitation-wx-batch-05", "/x/Invitation-wx-batch-05", key, wt: true),
        ])
        XCTAssertEqual(a, ["studio|Invitation-wx-batch-04": "Invitation", "studio|Invitation-wx-batch-05": "Invitation"])
    }

    /// 只有 worktree 没有主仓库时，组名取最短的那个
    func testOnlyWorktrees() {
        let a = ProjectGrouping.autoAliases([
            m("studio", "p2", "Invitation-wx-batch-04", "/x/Invitation-wx-batch-04", key, wt: true),
            m("studio", "p3", "Invitation-wx-batch-05", "/x/Invitation-wx-batch-05", key, wt: true),
        ])
        XCTAssertEqual(a, ["studio|Invitation-wx-batch-05": "Invitation-wx-batch-04"])
    }

    /// 同一台机器上同仓库两份独立 clone → 撞 key，按官方各自单独一组（连同它们的 worktree）
    func testTwoClonesOnOneHostStaySeparate() {
        let a = ProjectGrouping.autoAliases([
            m("studio", "p1", "Invitation", "/x/Invitation", key),
            m("studio", "p2", "Invitation-copy", "/x/Invitation-copy", key),
            m("mini", "p3", "Invitation-m", "/y/Invitation-m", key),
        ])
        XCTAssertEqual(a, [:])
    }

    /// 自定义名优先于仓库名；没有 key 的、本地 key 不同的不合并
    func testCustomNameWinsAndMissingKeyIgnored() {
        let a = ProjectGrouping.autoAliases([
            m("studio", "p1", "邀请函", "/x/Invitation", key),
            m("mini", "p2", "Invitation", "/y/Invitation", key),
            m("mini", "p3", "other", "/y/other", nil),
            m("studio", "p4", "other", "/x/other", "host:studio:/x/other"),
        ])
        XCTAssertEqual(a, ["mini|Invitation": "邀请函"])
    }

    /// 同名的项目（同一远端）不产生别名
    func testSameNameNoAlias() {
        let a = ProjectGrouping.autoAliases([
            m("studio", "p1", "Invitation", "/x/Invitation", key),
            m("mini", "p2", "Invitation", "/y/Invitation", key),
        ])
        XCTAssertEqual(a, [:])
    }

    func testRepoName() {
        XCTAssertEqual(ProjectGrouping.repoName(key), "Invitation")
        XCTAssertEqual(ProjectGrouping.repoName("remote:github.com/a/b.git"), "b")
        XCTAssertEqual(ProjectGrouping.repoName("remote:github.com/a/b#subdir:packages/app"), "app")
    }
}
