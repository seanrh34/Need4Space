import Foundation

/// Ranking per SPEC section 6 and PLAN revision 10: bytes descending, then repeated passes that
/// promote a safe item ahead of a non-safe predecessor when their sizes are within 20%.
public enum Ranking {
    public static func rank(_ insights: [Insight]) -> [Insight] {
        var items = insights.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.id < rhs.id
        }
        guard items.count > 1 else { return items }

        var changed = true
        while changed {
            changed = false
            var index = 1
            while index < items.count {
                let current = items[index]
                let previous = items[index - 1]
                if current.risk == .safe,
                   previous.risk != .safe,
                   withinTwentyPercent(current.bytes, previous.bytes) {
                    items.swapAt(index - 1, index)
                    changed = true
                }
                index += 1
            }
        }
        return items
    }

    /// True when `smaller` is at least 80% of `larger`.
    public static func withinTwentyPercent(_ smaller: UInt64, _ larger: UInt64) -> Bool {
        guard larger > 0 else { return true }
        return Double(smaller) >= 0.8 * Double(larger)
    }
}
