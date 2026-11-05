// 灵动岛 / 锁屏实时活动的数据，App 和 Widget 扩展共用。
//
// 契约（daemon 插件经 APNs 推送时 content-state 必须是同样的 JSON，字段改名或改语义要两边一起改）：
// {
//   "updatedAt": 1730700000.0,     // 生成这份状态的时间，Unix 秒
//   "running": 2,                  // 运行中的工作区数
//   "waiting": 1,                  // 等你处理（批准权限 / 回答问题）的工作区数
//   "failed": 0,                   // 出错的工作区数（只显示，不让活动常驻）
//   // running / waiting / failed 与 rows 都按「工作区」算（同侧栏：一个工作区一行，状态取其中最紧急的会话）
//   "rows": [                      // 最多 4 条，排序：等你处理 → 出错 → 运行中，同类按最近活动
//     {"serverId": "srv_…", "agentId": "<这一行最紧急的会话，点开它>", "host": "Mac Studio",
//      "title": "修复登录页样式",  // 工作区标题（同侧栏行名），没有就用会话标题
//      "project": "web-app",  // 项目名，同侧栏分组名；可省略（旧版插件不带）
//      "status": "waiting" | "failed" | "running", "since": 1730690000.0}   // since：运行中时，最早开始的那个回合，可省略
//   ],
//   "offline": ["Mac mini"]        // 连不上、状态可能过时的机器名，可省略
// }
// 活动只在 running + waiting > 0 时存在；全部结束后以 running = waiting = 0 的状态结束。
// 所有字段解码时都容忍缺省，便于插件和 App 版本不一致时仍能显示。

import Foundation

/// 点灵动岛 / 锁屏上的会话打开它（Mac 上也认，比如从终端 open 这个链接）：paseonative://agent/<serverId>/<agentId>
enum PaseoActivityLink {
    static let scheme = "paseonative"

    static func url(serverId: String, agentId: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "agent"
        c.path = "/" + serverId + "/" + agentId
        return c.url
    }

    static func parse(_ url: URL) -> (serverId: String, agentId: String)? {
        guard url.scheme == scheme, url.host == "agent" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

#if os(iOS)
import ActivityKit

struct PaseoActivityAttributes: ActivityAttributes {
    struct Row: Codable, Hashable, Identifiable {
        var serverId: String
        var agentId: String
        var host: String
        var title: String
        /// 项目名（侧栏分组名）；旧版插件不带，就只显示 title。
        var project: String?
        /// "waiting" | "failed" | "running"；未知值按运行中显示。
        var status: String
        /// 本回合开始时间（Unix 秒），用来在手机上本地走秒。
        var since: Double?

        var id: String { serverId + "/" + agentId }
        var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }

        init(serverId: String, agentId: String, host: String, title: String, project: String? = nil, status: String, since: Double?) {
            self.serverId = serverId; self.agentId = agentId; self.host = host
            self.title = title; self.project = project; self.status = status; self.since = since
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            serverId = try c.decodeIfPresent(String.self, forKey: .serverId) ?? ""
            agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
            host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "会话"
            project = try c.decodeIfPresent(String.self, forKey: .project)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
            since = try c.decodeIfPresent(Double.self, forKey: .since)
        }
    }

    struct ContentState: Codable, Hashable {
        var updatedAt: Double
        var running: Int
        var waiting: Int
        var failed: Int
        var rows: [Row]
        var offline: [String]

        init(updatedAt: Double, running: Int, waiting: Int, failed: Int, rows: [Row], offline: [String]) {
            self.updatedAt = updatedAt; self.running = running; self.waiting = waiting
            self.failed = failed; self.rows = rows; self.offline = offline
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
            running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
            waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
            failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
            rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
            offline = try c.decodeIfPresent([String].self, forKey: .offline) ?? []
        }

        var isActive: Bool { running + waiting > 0 }
        /// 行里出现多台机器时才标机器名（只有一台机器的人看不到机器名）。
        var showsHost: Bool { Set(rows.map(\.host)).count > 1 || !offline.isEmpty }
        /// 比较内容时忽略生成时间，避免没变化也去更新。
        func sameContent(as other: ContentState) -> Bool {
            var a = self, b = other
            a.updatedAt = 0; b.updatedAt = 0
            return a == b
        }
    }
}

#endif
