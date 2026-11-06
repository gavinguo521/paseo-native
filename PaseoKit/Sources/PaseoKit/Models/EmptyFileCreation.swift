import Foundation

public enum EmptyFileCreation {
    /// 文件读取协议目前只有错误字符串；严格匹配错误码，不能把断连/权限失败当成文件缺失。
    public static func isMissing(_ message: String) -> Bool { message.hasPrefix("ENOENT:") }

    static func request(cwd: String, path: String) throws -> [String: JSONValue] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw HostStore.ActionError.rejected(String(localized: "文件路径无效，无法创建文件", bundle: .module))
        }
        let name = String(components.last!)
        let parentPath = components.count == 1 ? "." : components.dropLast().joined(separator: "/")
        // 服务端会 trim 名称，拒绝此类路径，避免在用户点击的位置之外新建文件。
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0) else {
            throw HostStore.ActionError.rejected(String(localized: "文件名无效，无法在此路径创建文件", bundle: .module))
        }
        return ["cwd": .string(cwd), "parentPath": .string(parentPath), "name": .string(name), "kind": "file"]
    }

    static func validate(_ response: JSONValue) throws {
        guard response["payload"]?["success"]?.boolValue == true else {
            throw HostStore.ActionError.rejected(response["payload"]?["error"]?.stringValue
                ?? String(localized: "创建文件失败，请重新加载后重试", bundle: .module))
        }
    }
}
