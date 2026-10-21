import XCTest
import LayoutKit

final class SquarifyEdgeCaseTests: XCTestCase {
    private func assertFinite(_ rects: [LRect], file: StaticString = #filePath, line: UInt = #line) {
        for r in rects {
            XCTAssertTrue(r.x.isFinite && r.y.isFinite && r.width.isFinite && r.height.isFinite, "\(r)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(r.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(r.height, 0, file: file, line: line)
        }
    }

    func testOutputIsInInputOrder() {
        let rect = LRect(x: 0, y: 0, width: 100, height: 100)
        let weights: [Double] = [1, 9, 3, 7]
        let rects = Treemap.squarify(weights: weights, in: rect)
        for (r, w) in zip(rects, weights) {
            XCTAssertEqual(r.area, rect.area * w / 20, accuracy: 1e-9)
        }
    }

    func testNonFiniteAndNegativeWeightsGetZeroAreaAtOrigin() {
        let rect = LRect(x: 3, y: 4, width: 50, height: 20)
        let weights: [Double] = [.nan, 2, -.infinity, .infinity, -1, 0, 2]
        let rects = Treemap.squarify(weights: weights, in: rect)
        assertFinite(rects)
        for i in [0, 2, 3, 4, 5] {
            XCTAssertEqual(rects[i], LRect(x: 3, y: 4, width: 0, height: 0))
        }
        XCTAssertEqual(rects[1].area, 500, accuracy: 1e-9)
        XCTAssertEqual(rects[6].area, 500, accuracy: 1e-9)
    }

    func testEmptyAndDegenerateBounds() {
        XCTAssertEqual(Treemap.squarify(weights: [], in: LRect(x: 0, y: 0, width: 10, height: 10)), [])
        for rect in [LRect(x: 1, y: 2, width: 0, height: 10), LRect(x: 1, y: 2, width: 10, height: 0), LRect(x: 1, y: 2, width: -5, height: 10)] {
            let rects = Treemap.squarify(weights: [1, 2, 3], in: rect)
            XCTAssertEqual(rects, Array(repeating: LRect(x: 1, y: 2, width: 0, height: 0), count: 3))
        }
    }

    func testTinyRectsAndExtremeWeightsStayFinite() {
        let tiny = Treemap.squarify(weights: [1, 1e-300, .leastNonzeroMagnitude, 1], in: LRect(x: 0, y: 0, width: 1e-6, height: 1e-6))
        assertFinite(tiny)
        let huge = Treemap.squarify(weights: [.greatestFiniteMagnitude, .greatestFiniteMagnitude, 1], in: LRect(x: 0, y: 0, width: 10, height: 10))
        assertFinite(huge)
        XCTAssertEqual(huge[0].area, 50, accuracy: 1e-9)
        XCTAssertEqual(huge[1].area, 50, accuracy: 1e-9)
    }

    func testManyEqualWeightsFillTheRect() {
        let rect = LRect(x: 0, y: 0, width: 1920, height: 1080)
        let rects = Treemap.squarify(weights: Array(repeating: 1, count: 100_000), in: rect)
        assertFinite(rects)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, rect.area, accuracy: 1e-9 * rect.area)
    }
}
