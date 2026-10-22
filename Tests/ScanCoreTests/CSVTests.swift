import XCTest
import ScanCore

final class CSVTests: XCTestCase {
    func testEncoding() throws {
        let table = CSVTable(header: ["name", "値"], rows: [[.text("plain"), .integer(-42)],
            [.text("a,b"), .text("a\"b")], [.text("a\rb"), .text("a\nb")],
            [.text("漢字"), .empty], [.bool(true), .bool(false)]])
        let data = table.encoded()
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let body = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(body, "name,値\r\nplain,-42\r\n\"a,b\",\"a\"\"b\"\r\n\"a\rb\",\"a\nb\"\r\n漢字,\r\ntrue,false\r\n")
    }

    func testFormulaGuard() {
        for lead in ["=", "+", "-", "@", "\t", "\r"] {
            let csv = String(decoding: CSVTable(header: [], rows: [[.text(lead + "SUM(1)")]]).encoded().dropFirst(3), as: UTF8.self)
            XCTAssertTrue(csv.contains("'" + lead + "SUM(1)"), "unguarded: \(lead)")
        }
        XCTAssertEqual(String(decoding: CSVTable(header: ["normal"], rows: [[.text("normal")]]).encoded().dropFirst(3), as: UTF8.self), "normal\r\nnormal\r\n")
        let combining = String(decoding: CSVTable(header: [], rows: [[.text("=\u{301}SUM(1)")]]).encoded().dropFirst(3), as: UTF8.self)
        XCTAssertTrue(combining.contains("'=\u{301}SUM(1)"), "unguarded: = with a combining mark")
    }

    func testChildren() {
        let tree = FileTree(rootPath: "/fixture", device: 1)
        let complete = tree.addChild(of: 0, entry: ScanEntry(name: "complete", isDirectory: true, modTime: 1))
        tree.addChild(of: complete, entry: ScanEntry(name: "nested", isDirectory: false, allocSize: 30))
        let partial = tree.addChild(of: 0, entry: ScanEntry(name: "partial", isDirectory: true))
        tree.addChild(of: partial, entry: ScanEntry(name: "known", isDirectory: false, allocSize: 20))
        let unavailable = tree.addChild(of: 0, entry: ScanEntry(name: "unavailable", isDirectory: true))
        tree.addChild(of: 0, entry: ScanEntry(name: "file", isDirectory: false, allocSize: 10))
        let removed = tree.addChild(of: 0, entry: ScanEntry(name: "removed", isDirectory: false, allocSize: 100))
        tree.recomputeAggregates()
        tree.setStatus(partial, .partial)
        tree.setStatus(unavailable, .unavailable)
        tree.removeSubtree(removed)
        let table = TreeExport.children(of: 0, in: tree, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        XCTAssertEqual(table.header, ["name", "path", "kind", "size_bytes", "size_status", "files", "folders", "modified"])
        let rows = table.rows
        XCTAssertEqual(rows.map(\.first), [.text("complete"), .text("partial"), .text("file"), .text("unavailable")])
        XCTAssertEqual(rows[0][0...2], [.text("complete"), .text("/fixture/complete"), .text("folder")])
        XCTAssertEqual(rows[0][7], .text("1970-01-01T08:00:01+08:00"))
        XCTAssertEqual(rows[0][3...6], [.integer(30), .text("exact"), .integer(1), .integer(0)])
        XCTAssertEqual(rows[1][3...6], [.integer(20), .text("at_least"), .integer(1), .integer(0)])
        XCTAssertEqual(rows[2][0...2], [.text("file"), .text("/fixture/file"), .text("file")])
        XCTAssertEqual(rows[2][5...6], [.empty, .empty])
        XCTAssertEqual(rows[3][3...6], [.empty, .text("unknown"), .empty, .empty])
    }

    func testTimestamp() {
        XCTAssertEqual(TreeExport.timestamp(1_798_000_089, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), .text("2026-12-23T12:28:09+08:00"))
        XCTAssertEqual(TreeExport.timestamp(0), .empty)
    }
}
