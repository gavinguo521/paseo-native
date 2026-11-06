import Foundation

/// 每份文件只做一次分行和大小写归一化；搜索在 actor 上执行，取消后不发布旧结果。
actor FileSearchIndex {
    private var source: String?
    private var lines: [String] = []

    func matches(in text: String, query: String) throws -> [Int] {
        guard !query.isEmpty else { return [] }
        if source != text {
            var prepared: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                try Task.checkCancellation()
                prepared.append(line.lowercased())
            }
            lines = prepared
            source = text
        }
        let query = query.lowercased()
        var result: [Int] = []
        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            if line.contains(query) { result.append(index + 1) }
        }
        return result
    }
}
