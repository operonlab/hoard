import XCTest
@testable import LayoutKit

final class TreemapTests: XCTestCase {
    func testAreasAreProportionalAndFillTheRect() {
        let rect = LRect(x: 0, y: 0, width: 300, height: 200)
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Treemap.squarify(weights: weights, in: rect)
        XCTAssertEqual(rects.count, weights.count)
        let total = weights.reduce(0, +)
        for (r, w) in zip(rects, weights) {
            XCTAssertEqual(r.area, rect.area * w / total, accuracy: 1e-6)
        }
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, rect.area, accuracy: 1e-6)
    }

    func testZeroWeightsGiveZeroArea() {
        let rects = Treemap.squarify(weights: [0, 5, 0], in: LRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(rects[0].area, 0)
        XCTAssertEqual(rects[2].area, 0)
        XCTAssertEqual(rects[1].area, 100, accuracy: 1e-9)
    }
}
