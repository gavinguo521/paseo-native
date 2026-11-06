import PaseoKit

@MainActor extension AppModel {
    /// 每台机器只扫描一次，工作区中的其他标签页也要计入未读。
    /// 完全使用 daemon 的待查看状态，不用更新时间猜测新消息。
    func sidebarUnreadIndex() -> [String: [AgentRef]] {
        var result: [String: [AgentRef]] = [:]
        for host in visibleHosts {
            for agent in host.agents.values where agent.archivedAt == nil && !host.isNested(agent) && agent.bucket == .attention {
                result[Self.rowKey(serverId: host.id, agent: agent), default: []]
                    .append(AgentRef(serverId: host.id, agentId: agent.id))
            }
        }
        for key in result.keys { result[key]!.sort { $0.agentId < $1.agentId } }
        return result
    }

    static func unread(in group: SessionGroup, index: [String: [AgentRef]]) -> [AgentRef] {
        group.rows.flatMap { index[rowKey(serverId: $0.serverId, agent: $0.agent)] ?? [] }
    }
}
