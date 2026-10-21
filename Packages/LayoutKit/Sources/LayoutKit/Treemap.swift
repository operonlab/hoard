// CONTRACT: the public signatures in this file are frozen. Implementations may change.

public struct LRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var area: Double { width * height }
}

public enum Treemap {
    /// Lays out `weights` inside `rect`. Returns one rect per weight, in the same order as the input.
    /// Zero or negative weights get a zero-area rect. Areas are proportional to weights.
    ///
    /// Squarified layout (Bruls, Huizing, van Wijk 2000): weights are sorted descending internally and
    /// packed in rows along the shorter side of the remaining rect, closing a row as soon as adding the
    /// next item would worsen the row's worst aspect ratio. Zero, negative and non-finite weights, and
    /// weights too small to have a representable area, get a zero-area rect at `rect`'s origin. The last
    /// item of each row and the last row absorb rounding, so the rects tile `rect` exactly.
    public static func squarify(weights: [Double], in rect: LRect) -> [LRect] {
        var out = [LRect](repeating: LRect(x: rect.x, y: rect.y, width: 0, height: 0), count: weights.count)
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return out }

        var order: [Int] = []
        order.reserveCapacity(weights.count)
        var maxWeight = 0.0
        for (i, w) in weights.enumerated() where w > 0 && w.isFinite {
            order.append(i)
            maxWeight = max(maxWeight, w)
        }
        guard !order.isEmpty else { return out }
        order.sort { weights[$0] != weights[$1] ? weights[$0] > weights[$1] : $0 < $1 }

        // Normalize by the largest weight first so the sum cannot overflow.
        var total = 0.0
        for i in order { total += weights[i] / maxWeight }
        let scale = rect.area / total
        var areas: [Double] = []
        areas.reserveCapacity(order.count)
        for i in order {
            let a = weights[i] / maxWeight * scale
            guard a > 0, a.isFinite else { break }  // sorted descending: everything after is smaller
            areas.append(a)
        }

        var x = rect.x, y = rect.y, width = rect.width, height = rect.height
        let n = areas.count
        var start = 0
        while start < n, width > 0, height > 0 {
            let side = min(width, height)
            let side2 = side * side
            let largest = areas[start]
            var sum = largest
            var worst = worstRatio(sum: sum, largest: largest, smallest: largest, side2: side2)
            var end = start + 1
            while end < n {
                let candidateSum = sum + areas[end]
                let candidate = worstRatio(sum: candidateSum, largest: largest, smallest: areas[end], side2: side2)
                if candidate > worst { break }
                sum = candidateSum
                worst = candidate
                end += 1
            }

            let isLastRow = end == n
            if width >= height {
                // Column on the left edge, items stacked top to bottom.
                let thickness = isLastRow ? width : min(sum / height, width)
                var pos = y
                let limit = y + height
                for k in start..<end {
                    let length = segment(area: areas[k], thickness: thickness, pos: pos, limit: limit, last: k == end - 1)
                    out[order[k]] = LRect(x: x, y: pos, width: thickness, height: length)
                    pos += length
                }
                x += thickness
                width = isLastRow ? 0 : max(width - thickness, 0)
            } else {
                // Row along the top edge, items left to right.
                let thickness = isLastRow ? height : min(sum / width, height)
                var pos = x
                let limit = x + width
                for k in start..<end {
                    let length = segment(area: areas[k], thickness: thickness, pos: pos, limit: limit, last: k == end - 1)
                    out[order[k]] = LRect(x: pos, y: y, width: length, height: thickness)
                    pos += length
                }
                y += thickness
                height = isLastRow ? 0 : max(height - thickness, 0)
            }
            start = end
        }
        return out
    }

    /// Worst aspect ratio of a row with total area `sum` laid along a side of squared length `side2`.
    @inline(__always)
    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side2: Double) -> Double {
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }

    /// Length of one item along its row; the last item takes whatever is left so the row ends exactly at `limit`.
    @inline(__always)
    private static func segment(area: Double, thickness: Double, pos: Double, limit: Double, last: Bool) -> Double {
        let remaining = max(limit - pos, 0)
        if last { return remaining }
        guard thickness > 0 else { return 0 }
        return min(area / thickness, remaining)
    }
}
