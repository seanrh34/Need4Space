import Foundation
import ScannerKit

/// Small helpers shared by the detectors. They only touch arrays and never build a path string
/// unless an insight is actually produced.
enum InsightBuilder {
    static func sumBytes(_ ids: [NodeID], in tree: ScanTree) -> UInt64 {
        var total: UInt64 = 0
        for id in ids {
            let index = Int(id)
            guard index >= 0, index < tree.count else { continue }
            let (sum, overflow) = total.addingReportingOverflow(tree.allocSize[index])
            total = overflow ? UInt64.max : sum
        }
        return total
    }

    static func sortedBySize(_ ids: [NodeID], in tree: ScanTree) -> [NodeID] {
        ids.sorted { lhs, rhs in
            let l = tree.allocSize[Int(lhs)]
            let r = tree.allocSize[Int(rhs)]
            if l != r { return l > r }
            return lhs < rhs
        }
    }

    static func topChildren(of id: NodeID, in tree: ScanTree, limit: Int = 10) -> [InsightChild] {
        guard id >= 0, Int(id) < tree.count else { return [] }
        var ids: [NodeID] = []
        var child = tree.firstChild[Int(id)]
        while child >= 0 {
            ids.append(child)
            child = tree.nextSibling[Int(child)]
        }
        return sortedBySize(ids, in: tree).prefix(limit).map { childID in
            InsightChild(
                name: tree.name(childID),
                bytes: tree.allocSize[Int(childID)],
                nodeID: childID
            )
        }
    }

    static func paths(_ ids: [NodeID], in tree: ScanTree, limit: Int) -> [URL] {
        ids.prefix(limit).map { URL(fileURLWithPath: tree.path($0)) }
    }

    static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
