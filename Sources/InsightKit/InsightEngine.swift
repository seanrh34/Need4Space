import Foundation
import ScannerKit

/// Pure entry point of InsightKit. Runs over a finished `ScanTree`; does not read the disk.
public struct InsightEngine: Sendable {
    public var rules: [Rule]
    public var config: InsightsConfig

    public init(rules: [Rule] = RuleTable.all, config: InsightsConfig = InsightsConfig()) {
        self.rules = rules
        self.config = config
    }

    public func run(
        tree: ScanTree,
        homePath: String,
        volume: VolumeInfo? = nil,
        blocked: [NodeID] = [],
        apps: [AppBundleInfo] = [],
        previous: ScanTree? = nil,
        now: Date = Date()
    ) -> InsightReport {
        let home = PathSupport.normalize(homePath)
        let ruleEngine = RuleEngine(rules: rules, maxPathsPerInsight: config.maxPathsPerInsight)
        let ruleEvaluation = ruleEngine.evaluate(tree: tree, homePath: home)

        let appUsages = AppTotals.compute(tree: tree, homePath: home, apps: apps)

        var claimed = ruleEvaluation.claimed
        for usage in appUsages {
            for id in usage.nodeIDs { claimed.insert(id) }
        }

        let usedBytes = volume?.usedBytes ?? (tree.count > 0 ? tree.allocSize[0] : 0)

        var insights = ruleEvaluation.insights
        insights.append(
            contentsOf: Outliers.largeFolders(
                tree: tree,
                usedBytes: usedBytes,
                claimed: claimed,
                homePath: home,
                config: config
            )
        )
        insights.append(
            contentsOf: Outliers.staleFiles(
                tree: tree,
                now: now,
                homePath: home,
                config: config,
                restrictions: ruleEvaluation.restrictions
            )
        )
        insights.append(
            contentsOf: Outliers.fastGrowers(
                tree: tree,
                previous: previous,
                homePath: home,
                config: config
            )
        )

        let hidden = HiddenSpace.compute(tree: tree, volume: volume, blocked: blocked)
        if let hiddenInsight = Self.hiddenInsight(hidden, rootPath: tree.rootPath) {
            insights.append(hiddenInsight)
        }

        let safeBytes = Reclaimable.safeBytes(insights: insights, tree: tree)
        let ranked = Ranking.rank(insights)

        return InsightReport(
            insights: ranked,
            reclaimableSafeBytes: safeBytes,
            apps: appUsages,
            hidden: hidden
        )
    }

    private static func hiddenInsight(_ hidden: HiddenSpace, rootPath: String) -> Insight? {
        guard hidden.gapBytes > 0 || hidden.overcountBytes > 0 else { return nil }

        let detail: String
        if hidden.overcountBytes > 0 {
            detail = "The scan found more bytes than the volume reports as used (APFS clones). "
                + "Overcount: \(Self.formatBytes(hidden.overcountBytes)). "
                + "Local snapshots: \(hidden.snapshotCount) "
                + "(\(Self.formatBytes(hidden.snapshotKnownBytes)) with known sizes)."
        } else {
            detail = "Used by the volume but not seen by the scan: \(Self.formatBytes(hidden.gapBytes)). "
                + "Purgeable: \(Self.formatBytes(hidden.purgeableBytes)). "
                + "Local snapshots: \(hidden.snapshotCount) "
                + "(\(Self.formatBytes(hidden.snapshotKnownBytes)) with known sizes). "
                + "Blocked folders: \(hidden.blockedCount). "
                + "Remainder: \(Self.formatBytes(hidden.remainderBytes)) (\(HiddenSpace.remainderLabel))."
        }

        return Insight(
            id: "hidden.space:\(PathSupport.normalize(rootPath))",
            title: "Hidden space",
            detail: detail,
            nodeIDs: [],
            paths: [],
            bytes: hidden.gapBytes,
            risk: .review,
            action: .displayOnly,
            children: [],
            category: .system
        )
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}

/// Reclaimable safe total without double counting nested or repeated nodes.
public enum Reclaimable {
    public static func safeBytes(insights: [Insight], tree: ScanTree) -> UInt64 {
        guard tree.count > 0 else { return 0 }
        var unique: Set<NodeID> = []
        for insight in insights where insight.risk == .safe {
            for id in insight.nodeIDs {
                let index = Int(id)
                if index >= 0 && index < tree.count { unique.insert(id) }
            }
        }
        guard !unique.isEmpty else { return 0 }

        let ordered = unique.sorted { lhs, rhs in
            let lhsDepth = tree.depth(lhs)
            let rhsDepth = tree.depth(rhs)
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs < rhs
        }

        var accepted = Set<NodeID>()
        var total: UInt64 = 0
        for id in ordered {
            var parent = tree.parent[Int(id)]
            var hasAcceptedAncestor = false
            while parent >= 0 {
                if accepted.contains(NodeID(parent)) {
                    hasAcceptedAncestor = true
                    break
                }
                parent = tree.parent[Int(parent)]
            }
            if hasAcceptedAncestor { continue }
            accepted.insert(id)
            total = InsightBuilder.saturatingAdd(total, tree.allocSize[Int(id)])
        }
        return total
    }
}
