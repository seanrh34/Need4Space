import Foundation
import ScannerKit

/// Generic outlier detectors: large uncovered folders, large stale files and fast growers.
enum Outliers {
    // MARK: - Large folders (PLAN revision 11)

    static func largeFolders(
        tree: ScanTree,
        usedBytes: UInt64,
        claimed: Set<NodeID>,
        homePath: String,
        config: InsightsConfig
    ) -> [Insight] {
        let nodeCount = tree.count
        guard nodeCount > 1, usedBytes > 0 else { return [] }

        var isClaimed = [Bool](repeating: false, count: nodeCount)
        for id in claimed {
            let index = Int(id)
            if index >= 0 && index < nodeCount { isClaimed[index] = true }
        }

        var claimedBytes = [UInt64](repeating: 0, count: nodeCount)
        var index = 0
        while index < nodeCount {
            if isClaimed[index] { claimedBytes[index] = tree.allocSize[index] }
            index += 1
        }
        index = nodeCount - 1
        while index > 0 {
            let parentIndex = Int(tree.parent[index])
            if parentIndex >= 0 && !isClaimed[parentIndex] {
                claimedBytes[parentIndex] = InsightBuilder.saturatingAdd(
                    claimedBytes[parentIndex],
                    claimedBytes[index]
                )
            }
            index -= 1
        }

        let threshold = UInt64((Double(usedBytes) * config.largeFolderFraction).rounded(.up))
        guard threshold > 0 else { return [] }

        var candidateIDs: [NodeID] = []
        index = 1
        while index < nodeCount {
            if tree.kind[index].isContainer && !isClaimed[index] {
                let alloc = tree.allocSize[index]
                if alloc > claimedBytes[index] {
                    let uncovered = alloc - claimedBytes[index]
                    if uncovered >= threshold {
                        candidateIDs.append(NodeID(index))
                    }
                }
            }
            index += 1
        }
        guard !candidateIDs.isEmpty else { return [] }

        var isCandidate = [Bool](repeating: false, count: nodeCount)
        for id in candidateIDs { isCandidate[Int(id)] = true }

        let excluded = excludedPaths(homePath: homePath)
        var suppressed = Set<NodeID>()
        for id in candidateIDs {
            var parent = tree.parent[Int(id)]
            while parent >= 0 {
                if isCandidate[Int(parent)] {
                    let childUncovered = uncovered(tree: tree, id: id, claimedBytes: claimedBytes)
                    let parentUncovered = uncovered(tree: tree, id: NodeID(parent), claimedBytes: claimedBytes)
                    if Double(childUncovered) >= 0.5 * Double(parentUncovered) {
                        suppressed.insert(NodeID(parent))
                    }
                    break
                }
                parent = tree.parent[Int(parent)]
            }
        }

        let ordered = candidateIDs.sorted { lhs, rhs in
            tree.depth(lhs) < tree.depth(rhs)
        }
        var reported: [NodeID] = []
        var reportedSet = Set<NodeID>()
        for id in ordered {
            if suppressed.contains(id) { continue }
            if excluded.contains(tree.path(id)) { continue }
            var parent = tree.parent[Int(id)]
            var ancestorReported = false
            while parent >= 0 {
                if reportedSet.contains(NodeID(parent)) {
                    ancestorReported = true
                    break
                }
                parent = tree.parent[Int(parent)]
            }
            if ancestorReported { continue }
            reported.append(id)
            reportedSet.insert(id)
        }

        var insights: [Insight] = []
        insights.reserveCapacity(reported.count)
        for id in reported {
            let uncoveredBytes = uncovered(tree: tree, id: id, claimedBytes: claimedBytes)
            let percent = usedBytes > 0 ? Double(uncoveredBytes) * 100.0 / Double(usedBytes) : 0
            let detail = String(
                format: "%.1f%% of used space is not explained by any known rule or app.",
                percent
            )
            insights.append(
                Insight(
                    id: "largeFolder.\(Int(id))",
                    title: "Large folder: \(tree.name(id))",
                    detail: detail,
                    nodeIDs: [id],
                    paths: [URL(fileURLWithPath: tree.path(id))],
                    bytes: uncoveredBytes,
                    risk: .review,
                    action: .revealOnly,
                    children: InsightBuilder.topChildren(of: id, in: tree),
                    category: Category.forNode(id, in: tree, homePath: homePath)
                )
            )
        }
        insights.sort { $0.bytes > $1.bytes }
        return insights
    }

    private static func uncovered(tree: ScanTree, id: NodeID, claimedBytes: [UInt64]) -> UInt64 {
        let index = Int(id)
        let alloc = tree.allocSize[index]
        return alloc > claimedBytes[index] ? alloc - claimedBytes[index] : 0
    }

    private static func excludedPaths(homePath: String) -> Set<String> {
        let home = PathSupport.normalize(homePath)
        return [
            "/",
            "/Users",
            "/System",
            "/Applications",
            "/Library",
            "/private",
            home,
            PathSupport.join(home, "Library"),
        ]
    }

    // MARK: - Large stale files

    static func staleFiles(
        tree: ScanTree,
        now: Date,
        homePath: String,
        config: InsightsConfig
    ) -> [Insight] {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let ageSeconds = Int64(config.staleFileAgeDays) * 86_400
        guard ageSeconds > 0, tree.count > 0 else { return [] }

        var insights: [Insight] = []
        var index = 0
        while index < tree.count {
            if tree.kind[index] == .file,
               tree.allocSize[index] >= config.staleFileMinBytes {
                let access = tree.accessTime[index]
                let modified = tree.modTime[index]
                let timestamp = access != 0 ? access : modified
                if timestamp > 0, nowSeconds >= timestamp {
                    let elapsed = nowSeconds - timestamp
                    if elapsed >= ageSeconds {
                        let id = NodeID(index)
                        let usedAccessTime = access != 0
                        let detail = usedAccessTime
                            ? "Last accessed \(config.staleFileAgeDays) days ago or more."
                            : "Access time is unavailable; last modified \(config.staleFileAgeDays) days ago or more."
                        insights.append(
                            Insight(
                                id: "staleFile.\(index)",
                                title: "Large file not used in over a year: \(tree.name(id))",
                                detail: detail,
                                nodeIDs: [id],
                                paths: [URL(fileURLWithPath: tree.path(id))],
                                bytes: tree.allocSize[index],
                                risk: .review,
                                action: .trash,
                                children: [],
                                category: Category.forNode(id, in: tree, homePath: homePath)
                            )
                        )
                    }
                }
            }
            index += 1
        }
        insights.sort { $0.bytes > $1.bytes }
        return insights
    }

    // MARK: - Fast growers

    static func fastGrowers(
        tree: ScanTree,
        previous: ScanTree?,
        homePath: String,
        config: InsightsConfig
    ) -> [Insight] {
        guard let previous,
              tree.count > 0,
              previous.count > 0,
              config.growthMaxDepth > 0,
              PathSupport.normalize(tree.rootPath) == PathSupport.normalize(previous.rootPath) else {
            return []
        }

        var grown: [(id: NodeID, growth: UInt64)] = []
        visitGrowth(
            current: 0,
            previous: 0,
            depth: 0,
            tree: tree,
            oldTree: previous,
            config: config,
            grown: &grown
        )
        guard !grown.isEmpty else { return [] }

        // Report only the deepest folders where the growth is concentrated. A parent whose bytes
        // grew because one child grew would otherwise double count that child in the total.
        let candidates = Set(grown.map { $0.id })
        var hasCandidateDescendant = Set<NodeID>()
        for item in grown {
            var parent = tree.parent[Int(item.id)]
            while parent >= 0 {
                let parentID = NodeID(parent)
                if candidates.contains(parentID) { hasCandidateDescendant.insert(parentID) }
                parent = tree.parent[parent]
            }
        }
        var reported = grown.filter { !hasCandidateDescendant.contains($0.id) }
        guard !reported.isEmpty else { return [] }
        reported.sort { lhs, rhs in
            if lhs.growth != rhs.growth { return lhs.growth > rhs.growth }
            return lhs.id < rhs.id
        }

        var total: UInt64 = 0
        for item in reported { total = InsightBuilder.saturatingAdd(total, item.growth) }
        let ids = reported.map { $0.id }
        let children = reported.prefix(10).map { item in
            InsightChild(name: tree.name(item.id), bytes: item.growth, nodeID: item.id)
        }
        let paths = reported.prefix(config.maxPathsPerInsight).map {
            URL(fileURLWithPath: tree.path($0.id))
        }
        let gigabytes = Double(config.growthMinBytes) / (1024.0 * 1024.0 * 1024.0)
        let detail = String(
            format: "Folders that grew by more than %.1f GB since the previous scan.",
            gigabytes
        )

        return [
            Insight(
                id: "outlier.fastGrowers",
                title: "Folders that grew since the last scan",
                detail: detail,
                nodeIDs: ids,
                paths: paths,
                bytes: total,
                risk: .review,
                action: .revealOnly,
                children: Array(children),
                category: .other
            )
        ]
    }

    private static func visitGrowth(
        current: NodeID,
        previous: NodeID,
        depth: Int,
        tree: ScanTree,
        oldTree: ScanTree,
        config: InsightsConfig,
        grown: inout [(id: NodeID, growth: UInt64)]
    ) {
        guard depth < config.growthMaxDepth else { return }
        var child = tree.firstChild[Int(current)]
        while child >= 0 {
            if tree.kind[Int(child)].isContainer {
                let childDepth = depth + 1
                if let oldChild = tree.childMatchingName(of: previous, nameOf: child) {
                    let newBytes = tree.allocSize[Int(child)]
                    let oldBytes = oldTree.allocSize[Int(oldChild)]
                    if newBytes > oldBytes {
                        let growth = newBytes - oldBytes
                        if growth >= config.growthMinBytes {
                            grown.append((id: child, growth: growth))
                        }
                    }
                    if childDepth < config.growthMaxDepth {
                        visitGrowth(
                            current: child,
                            previous: oldChild,
                            depth: childDepth,
                            tree: tree,
                            oldTree: oldTree,
                            config: config,
                            grown: &grown
                        )
                    }
                }
            }
            child = tree.nextSibling[Int(child)]
        }
    }
}
