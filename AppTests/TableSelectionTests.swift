import Testing
@testable import Paseo

@MainActor struct TableSelectionTests {
    @Test func reversedRectanglePreservesRowsAndColumns() {
        let range = TableCellRange(anchor: .init(row: 2, column: 2), end: .init(row: 1, column: 1))
        #expect(range.text(from: [["H", "X", "Y"], ["A", "10", "20"], ["B", "30", "40"]]) == "10\t20\n30\t40")
        #expect(!range.contains(.init(row: 0, column: 1)))
    }
    @Test func copyDoesNotSplitQuotedOrMultilineCells() {
        let range = TableCellRange(anchor: .init(row: 0, column: 0), end: .init(row: 0, column: 2))
        #expect(range.text(from: [["a\tb", "say \"hi\"", "c"]]) == "\"a\tb\"\t\"say \"\"hi\"\"\"\tc")
        #expect(range.text(from: [["one"]]) == "one\t\t")
    }
}
