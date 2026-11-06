import Foundation
import Testing
@testable import PaseoKit
@testable import Paseo

@MainActor enum SidebarTestFixture {
    static func model(projects: Int) throws -> AppModel {
        let host = HostStore(offer: .direct(serverId: "sidebar-test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "测试机器", clientId: "test", appVersion: "test")
        // 每项目 8 个工作区、每工作区 2 个会话；样本只存在测试进程内。
        for p in 0..<projects {
            for w in 0..<8 {
                for s in 0..<2 {
                    let id = "p\(p)-w\(w)-s\(s)"
                    let agent = try #require(Agent(["id": .string(id), "workspaceId": .string("p\(p)-w\(w)"),
                        "cwd": .string("/test/project-\(p)"), "title": .string("项目 \(p) 的工作区 \(w) 会话 \(s)"),
                        "status": "idle", "createdAt": .string(Date(timeIntervalSince1970: Double(p * 1000 + w * 10 + s)).ISO8601Format())]))
                    host.agents[id] = agent
                }
            }
        }
        let model = AppModel(testHosts: [host])
        model.hostFilter = nil
        model.grouping = .project
        model.sort = .created
        return model
    }

}
