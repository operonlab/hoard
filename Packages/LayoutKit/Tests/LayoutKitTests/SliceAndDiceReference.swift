import LayoutKit

/// The original slice-and-dice placeholder, kept verbatim as the aspect-ratio baseline for the property tests.
func sliceAndDiceReference(weights: [Double], in rect: LRect) -> [LRect] {
    let total = weights.reduce(0) { $0 + max($1, 0) }
    guard total > 0 else { return weights.map { _ in LRect(x: rect.x, y: rect.y, width: 0, height: 0) } }
    var out: [LRect] = []
    out.reserveCapacity(weights.count)
    var offset = 0.0
    let horizontal = rect.width >= rect.height
    for w in weights {
        let share = max(w, 0) / total
        if horizontal {
            let width = rect.width * share
            out.append(LRect(x: rect.x + offset, y: rect.y, width: width, height: rect.height))
            offset += width
        } else {
            let height = rect.height * share
            out.append(LRect(x: rect.x, y: rect.y + offset, width: rect.width, height: height))
            offset += height
        }
    }
    return out
}
