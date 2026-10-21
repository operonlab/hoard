import XCTest
import LayoutKit

final class LayoutNestedTests: XCTestCase {
    private let bounds = LRect(x: 0, y: 0, width: 400, height: 300)

    private func tree() -> [TreemapNode] {
        [
            TreemapNode(id: 1, weight: 6, children: [
                TreemapNode(id: 11, weight: 4, children: [TreemapNode(id: 111, weight: 1)]),
                TreemapNode(id: 12, weight: 2),
            ]),
            TreemapNode(id: 2, weight: 3),
            TreemapNode(id: 3, weight: 1e-9),  // far below 2x2: skipped
        ]
    }

    private func contains(_ outer: LRect, _ inner: LRect, eps: Double = 1e-6) -> Bool {
        inner.x >= outer.x - eps && inner.y >= outer.y - eps
            && inner.x + inner.width <= outer.x + outer.width + eps
            && inner.y + inner.height <= outer.y + outer.height + eps
    }

    func testPreOrderDepthsAndInsetChildren() {
        let padding = 4.0, header = 16.0
        let out = Treemap.layoutNested(tree(), in: bounds, maxDepth: 10, padding: padding, headerHeight: header)
        XCTAssertEqual(out.map(\.id), [1, 11, 111, 12, 2])
        XCTAssertEqual(out.map(\.depth), [0, 1, 2, 1, 0])

        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0.rect) })
        let parent = byID[1]!
        let inner = LRect(x: parent.x + padding, y: parent.y + padding + header,
                          width: parent.width - 2 * padding, height: parent.height - 2 * padding - header)
        XCTAssertTrue(contains(inner, byID[11]!))
        XCTAssertTrue(contains(inner, byID[12]!))
        XCTAssertEqual(byID[11]!.area + byID[12]!.area, inner.area, accuracy: 1e-6)
        XCTAssertEqual(byID[11]!.area / byID[12]!.area, 2, accuracy: 1e-9)
        for (_, r, _) in out {
            XCTAssertTrue(contains(bounds, r))
            XCTAssertTrue(r.width >= 2 && r.height >= 2)
        }
    }

    func testMaxDepthLimitsLevels() {
        XCTAssertEqual(Treemap.layoutNested(tree(), in: bounds, maxDepth: 0, padding: 2, headerHeight: 10).count, 0)
        XCTAssertEqual(Treemap.layoutNested(tree(), in: bounds, maxDepth: 1, padding: 2, headerHeight: 10).map(\.id), [1, 2])
        XCTAssertEqual(Treemap.layoutNested(tree(), in: bounds, maxDepth: 2, padding: 2, headerHeight: 10).map(\.id), [1, 11, 12, 2])
    }

    func testNoRecursionWhenInnerRectTooSmall() {
        let node = TreemapNode(id: 1, weight: 1, children: [TreemapNode(id: 2, weight: 1)])
        let out = Treemap.layoutNested([node], in: LRect(x: 0, y: 0, width: 10, height: 10), maxDepth: 5, padding: 4.5, headerHeight: 0)
        XCTAssertEqual(out.map(\.id), [1])
    }
}
