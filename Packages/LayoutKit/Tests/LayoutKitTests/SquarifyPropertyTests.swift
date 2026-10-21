import XCTest
import Dispatch
import LayoutKit

/// Deterministic 64-bit LCG (Knuth MMIX constants); high bits only.
struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() >> 33) % (range.upperBound - range.lowerBound + 1)
    }
}

struct LayoutCase {
    var weights: [Double]
    var bounds: LRect
}

func makeCase(_ rng: inout LCG) -> LayoutCase {
    let count = rng.unit() < 0.1 ? rng.int(in: 1...9) : rng.int(in: 10...300)
    let distribution = rng.int(in: 0...2)
    var weights: [Double] = []
    weights.reserveCapacity(count)
    for _ in 0..<count {
        let u = rng.unit()
        var w: Double
        switch distribution {
        case 0: w = u + 1e-3                      // roughly uniform
        case 1: w = pow(1 - u, -1.5)              // heavy tail (Pareto-like)
        default: w = pow(10, u * 6)               // file sizes over six orders of magnitude
        }
        let r = rng.unit()
        if r < 0.05 { w = 0 } else if r < 0.08 { w = -w }
        weights.append(w)
    }
    let width = 1 + rng.unit() * 2000
    let aspect = pow(10, rng.unit() * 2 - 1)      // 0.1 ... 10
    let bounds = LRect(x: rng.unit() * 1000 - 500, y: rng.unit() * 1000 - 500, width: width, height: width * aspect)
    return LayoutCase(weights: weights, bounds: bounds)
}

func cases(count: Int = 200, seed: UInt64 = 0x5EED_D15C) -> [LayoutCase] {
    var rng = LCG(seed: seed)
    return (0..<count).map { _ in makeCase(&rng) }
}

/// Worst aspect ratio over the non-empty rects of one layout.
func worstAspect(_ rects: [LRect]) -> Double {
    var worst = 1.0
    for r in rects where r.width > 0 && r.height > 0 {
        worst = max(worst, max(r.width / r.height, r.height / r.width))
    }
    return worst
}

final class SquarifyPropertyTests: XCTestCase {
    func testRectsStayInsideBounds() {
        for (n, c) in cases().enumerated() {
            let b = c.bounds
            for (i, r) in Treemap.squarify(weights: c.weights, in: b).enumerated() {
                let inside = r.width >= 0 && r.height >= 0
                    && r.x >= b.x - 1e-6 && r.y >= b.y - 1e-6
                    && r.x + r.width <= b.x + b.width + 1e-6
                    && r.y + r.height <= b.y + b.height + 1e-6
                if !inside { return XCTFail("case \(n) rect \(i) \(r) outside \(b)") }
            }
        }
    }

    func testNonEmptyRectsDoNotOverlap() {
        for (n, c) in cases().enumerated() {
            let rects = Treemap.squarify(weights: c.weights, in: c.bounds).filter { $0.area > 0 }
            let tolerance = 1e-9 * c.bounds.area
            for i in rects.indices {
                let a = rects[i]
                for j in (i + 1)..<rects.count {
                    let b = rects[j]
                    let dx = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                    let dy = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                    if dx > 0, dy > 0, dx * dy > tolerance {
                        return XCTFail("case \(n): \(a) overlaps \(b) by \(dx * dy)")
                    }
                }
            }
        }
    }

    func testTotalAreaEqualsBoundsArea() {
        for (n, c) in cases().enumerated() {
            let rects = Treemap.squarify(weights: c.weights, in: c.bounds)
            let positive = c.weights.contains { $0 > 0 }
            let expected = positive ? c.bounds.area : 0
            XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, expected, accuracy: 1e-9 * c.bounds.area, "case \(n)")
        }
    }

    func testAreaProportionalToWeight() {
        for (n, c) in cases().enumerated() {
            let rects = Treemap.squarify(weights: c.weights, in: c.bounds)
            XCTAssertEqual(rects.count, c.weights.count)
            let total = c.weights.reduce(0) { $0 + ($1 > 0 ? $1 : 0) }
            for (i, (r, w)) in zip(rects, c.weights).enumerated() {
                let expected = w > 0 ? c.bounds.area * w / total : 0
                if abs(r.area - expected) > 1e-9 * c.bounds.area {
                    return XCTFail("case \(n) item \(i): area \(r.area), expected \(expected)")
                }
                if w <= 0 { XCTAssertEqual(r, LRect(x: c.bounds.x, y: c.bounds.y, width: 0, height: 0)) }
            }
        }
    }

    func testAspectRatioMuchBetterThanSliceAndDice() {
        let all = cases()
        let squarified = all.map { worstAspect(Treemap.squarify(weights: $0.weights, in: $0.bounds)) }
        let slice = all.map { worstAspect(sliceAndDiceReference(weights: $0.weights, in: $0.bounds)) }
        let meanSquarified = squarified.reduce(0, +) / Double(all.count)
        let meanSlice = slice.reduce(0, +) / Double(all.count)
        print("mean worst aspect ratio: squarified \(meanSquarified), slice-and-dice \(meanSlice)")
        XCTAssertLessThan(meanSquarified, 0.5 * meanSlice)
    }

    func testTenThousandWeightsPerformance() {
        var rng = LCG(seed: 10_000)
        let weights = (0..<10_000).map { _ in pow(10, rng.unit() * 6) }
        let bounds = LRect(x: 0, y: 0, width: 1920, height: 1080)
        _ = Treemap.squarify(weights: weights, in: bounds)  // warm-up
        var best = UInt64.max
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let rects = Treemap.squarify(weights: weights, in: bounds)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertEqual(rects.count, weights.count)
            best = min(best, elapsed)
        }
        let ms = Double(best) / 1e6
        #if DEBUG
        print("squarify 10k weights: \(ms) ms (debug build, not asserted)")
        #else
        print("squarify 10k weights: \(ms) ms (release build)")
        XCTAssertLessThan(ms, 20)
        #endif
    }
}
