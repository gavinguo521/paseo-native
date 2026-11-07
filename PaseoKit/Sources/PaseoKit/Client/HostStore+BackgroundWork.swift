import Foundation

extension HostStore {
    public var supportsBackgroundWork: Bool { serverInfo?.hasFeature("agentBackgroundWork") == true }
    public var supportsBackgroundWorkStop: Bool { serverInfo?.hasFeature("agentBackgroundWorkStop") == true }

    func resetBackgroundWork() {
        backgroundWork = [:]
        backgroundWorkErrors = [:]
        backgroundWorkLoading = []
        backgroundWorkRequests = [:]
    }

    /// 更新是整份快照；使已经在途的列表响应失效，避免旧列表覆盖新推送。
    func receiveBackgroundWork(_ payload: JSONValue) {
        guard supportsBackgroundWork, let id = payload["agentId"]?.stringValue else { return }
        backgroundWorkRequests[id] = UUID()
        backgroundWork[id] = (payload["items"]?.arrayValue ?? []).compactMap(AgentBackgroundWork.init)
        backgroundWorkErrors[id] = nil
        backgroundWorkLoading.remove(id)
    }

    public func refreshBackgroundWork(_ agentId: String) async {
        guard supportsBackgroundWork, let c = connection else { return }
        let request = UUID()
        backgroundWorkRequests[agentId] = request
        backgroundWorkLoading.insert(agentId)
        backgroundWorkErrors[agentId] = nil
        defer {
            if backgroundWorkRequests[agentId] == request { backgroundWorkLoading.remove(agentId) }
        }
        do {
            let response = try await c.request("agent.background_work.list.request", ["agentId": .string(agentId)])
            guard connection === c, backgroundWorkRequests[agentId] == request, !Task.isCancelled else { return }
            let payload = response["payload"]
            if let error = payload?["error"]?.stringValue { throw ActionError.rejected(error) }
            backgroundWork[agentId] = (payload?["items"]?.arrayValue ?? []).compactMap(AgentBackgroundWork.init)
        } catch {
            guard connection === c, backgroundWorkRequests[agentId] == request, !Task.isCancelled else { return }
            backgroundWorkErrors[agentId] = String(describing: error)
        }
    }

    public func stopBackgroundWork(_ item: AgentBackgroundWork, agentId: String) async throws {
        guard supportsBackgroundWork, supportsBackgroundWorkStop, item.canStop, let token = item.stopToken else {
            throw ActionError.rejected(String(localized: "当前任务不支持单独停止", bundle: .module))
        }
        let c = try conn()
        let response = try await c.request("agent.background_work.stop.request", [
            "agentId": .string(agentId), "itemId": .string(item.id), "stopToken": .string(token),
        ])
        guard connection === c else { throw ActionError.notConnected }
        if let error = response["payload"]?["error"]?.stringValue { throw ActionError.rejected(error) }
        // 成功响应后重新取权威列表，不能把点击按钮当作任务已停止。
        await refreshBackgroundWork(agentId)
    }
}
