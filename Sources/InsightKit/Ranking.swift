import Foundation

/// Ranking per SPEC section 6 and PLAN revision 10: bytes descending, then safe items are moved
/// left past non-safe predecessors whose sizes are within 20%. Insertion-style promotion keeps this
/// bounded instead of repeating whole-array passes.
public enum Ranking {
    public static func rank(_ insights: [Insight]) -> [Insight] {
        var items = insights.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.id < rhs.id
        }
        guard items.count > 1 else { return items }

        var index = 1
        while index < items.count {
            let current = items[index]
            if current.risk == .safe {
                var position = index
                while position > 0 {
                    let predecessor = items[position - 1]
                    guard predecessor.risk != .safe,
                          withinTwentyPercent(current.bytes, predecessor.bytes) else {
                        break
                    }
                    items.swapAt(position - 1, position)
                    position -= 1
                }
            }
            index += 1
        }
        return items
    }

    /// True when `smaller` is at least 80% of `larger`.
    public static func withinTwentyPercent(_ smaller: UInt64, _ larger: UInt64) -> Bool {
        guard larger > 0 else { return true }
        return Double(smaller) >= 0.8 * Double(larger)
    }
}
