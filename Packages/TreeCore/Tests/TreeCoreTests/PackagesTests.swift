import XCTest
@testable import TreeCore

final class PackagesTests: XCTestCase {
    func testNewExtensionsCaseAndGit() {
        XCTAssertTrue(Packages.isPackage(name: "Novel.scriv"))
        XCTAssertTrue(Packages.isPackage(name: "Archive.DSYM"))
        XCTAssertTrue(Packages.isPackage(name: ".git"))
        XCTAssertTrue(Packages.isPackage(name: ".GIT"))
        XCTAssertFalse(Packages.isPackage(name: "notes.txt"))
        XCTAssertEqual(Packages.enclosing("/work/Novel.scriv/Files/content.rtf"), "Novel.scriv")
    }

    /// The suggest walk tests names on their bytes; it must answer exactly what the package list does.
    func testSuggestWalkAgreesWithThePackageList() {
        var names = ["node_modules", "NODE_MODULES", ".git", ".Git", "src", "a.", ".", "x.app.bak", "Ünïcode.app",
                     "Kelvin.wor\u{212A}", "frame.framewor\u{212A}", "café.bundle", "a.b.c"]
        for ext in Packages.extensions { names += ["X.\(ext)", "X.\(ext.uppercased())", "X.\(ext.prefix(1).uppercased() + ext.dropFirst())", ext] }
        for name in names {
            let expected = name.lowercased() == "node_modules" || Packages.isPackage(name: name)
            XCTAssertEqual(CleanupSuggester.isNoEntryName(name), expected, name)
        }
    }
}
