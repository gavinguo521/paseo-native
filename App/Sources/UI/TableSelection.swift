import SwiftUI
import PaseoKit

struct TableCellPosition: Hashable {
    let row: Int
    let column: Int
}

struct TableCellRange: Equatable {
    let anchor: TableCellPosition
    let end: TableCellPosition
    var rows: ClosedRange<Int> { min(anchor.row, end.row)...max(anchor.row, end.row) }
    var columns: ClosedRange<Int> { min(anchor.column, end.column)...max(anchor.column, end.column) }
    func contains(_ cell: TableCellPosition) -> Bool { rows.contains(cell.row) && columns.contains(cell.column) }

    func cells(from table: [[String]]) -> [[String]] {
        rows.filter { table.indices.contains($0) }.map { row in
            columns.map { column in
                table[row].indices.contains(column) ? String(InlineMarkdown.parse(table[row][column].replacingOccurrences(of: "<br>", with: "\n")).characters) : ""
            }
        }
    }

    func markdown(from table: [[String]]) -> String { TableClipboard.markdown(cells(from: table)) }

    /// TSV 中带制表符、换行或引号的单元格必须转义，避免粘贴时错列。
    func text(from table: [[String]]) -> String {
        cells(from: table).map { row in
            row.map { value in
                if value.contains(where: { "\t\n\r\"".contains($0) }) { return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                return value
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

struct TableCellFrames: PreferenceKey {
    static let defaultValue: [TableCellPosition: CGRect] = [:]
    static func reduce(value: inout [TableCellPosition: CGRect], nextValue: () -> [TableCellPosition: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
