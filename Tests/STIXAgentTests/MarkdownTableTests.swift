import XCTest
@testable import STIXAgent

final class MarkdownTableTests: XCTestCase {
    func testParsesStandardMarkdownTable() throws {
        let lines = ["| Функция | Что делает |", "|---|---|", "| **Код** | Проверяет синтаксис |", "Текст после"]
        let table = try XCTUnwrap(MarkdownTable.parse(lines: lines, at: 0))
        XCTAssertEqual(table.headers, ["Функция", "Что делает"])
        XCTAssertEqual(table.rows, [["**Код**", "Проверяет синтаксис"]])
        XCTAssertEqual(table.consumedLines, 3)
    }

    func testRepairsSingleCellRowsFromSmallModelsForDisplay() throws {
        let lines = ["| Функция | Что делает |", "|---|---|", "| **Файлы** – читаю и перемещаю |"]
        let table = try XCTUnwrap(MarkdownTable.parse(lines: lines, at: 0))
        XCTAssertEqual(table.rows, [["**Файлы**", "читаю и перемещаю"]])
    }

    func testDoesNotTreatOrdinaryPipesAsTable() {
        XCTAssertNil(MarkdownTable.parse(lines: ["one | two", "a | b"], at: 0))
    }
}
