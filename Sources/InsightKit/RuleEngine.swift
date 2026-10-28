import Foundation
import ScannerKit

/// Restriction inherited by files inside a rule-matched area.
struct RuleRestriction: Sendable {
    var risk: Risk
    var action: SuggestedAction
}

struct RuleEvaluation: Sendable {
    var insights: [Insight]
    /// Every node claimed by a produced insight, used to avoid double counting elsewhere.
    var claimed: Set<NodeID>
    /// Every rule-matched node, so stale-file detection can inherit the rule's restriction.
    var restrictions: [NodeID: RuleRestriction]
}

/// Turns the rule table into insights. All work is linear in the tree size; only the handful of
/// fixed paths are materialised as strings.
public struct RuleEngine: Sendable {
    public var rules: [Rule]
    public var maxPathsPerInsight: Int

    public init(rules: [Rule] = RuleTable.all, maxPathsPerInsight: Int = 100) {
        self.rules = rules
        self.maxPathsPerInsight = max(0, maxPathsPerInsight)
    }

    private struct RawMatch {
        var id: NodeID
        var perItem: Bool
    }

    private struct MatchItem {
        var id: NodeID
        var bytes: UInt64
        var projectModTime: Int64
    }

    func evaluate(tree: ScanTree, homePath: String) -> RuleEvaluation {
        var insights: [Insight] = []
        var claimed = Set<NodeID>()
        var restrictions: [NodeID: RuleRestriction] = [:]
        let home = PathSupport.normalize(homePath)

        for rule in rules {
            var seen = Set<NodeID>()
            var rawMatches: [RawMatch] = []

            for pattern in rule.patterns {
                let found = Self.nodes(
                    matching: pattern,
                    in: tree,
                    homePath: home,
                    claimed: claimed
                )
                let restriction = RuleRestriction(risk: rule.risk, action: rule.action)
                let perItem = Self.isPerItemPattern(pattern)
                for id in found {
                    guard Int(id) >= 0, Int(id) < tree.count else { continue }
                    restrictions[id] = Self.mergeRestriction(restrictions[id], restriction)
                    if seen.insert(id).inserted {
                        rawMatches.append(RawMatch(id: id, perItem: perItem))
                    }
                }
            }

            guard !rawMatches.isEmpty else { continue }

            let claimedSubtree: [UInt64]? = claimed.isEmpty
                ? nil
                : Self.claimedBytesSubtree(tree: tree, claimed: claimed)
            let usesProjectDate = Self.hasAnyDirectoryNamedPattern(rule)

            var items: [MatchItem] = []
            for match in rawMatches {
                if !claimed.isEmpty,
                   Self.isClaimedOrInsideClaimed(match.id, tree: tree, claimed: claimed) {
                    continue
                }
                let inside = claimedSubtree?[Int(match.id)] ?? 0
                if inside == 0 {
                    let bytes = tree.allocSize[Int(match.id)]
                    guard bytes > 0 else { continue }
                    // Per-item minima are evaluated on the bytes left after earlier claims.
                    guard !match.perItem || bytes >= rule.minBytes else { continue }
                    items.append(
                        MatchItem(
                            id: match.id,
                            bytes: bytes,
                            projectModTime: Self.projectModTime(
                                for: match.id,
                                tree: tree,
                                usesProjectDate: usesProjectDate
                            )
                        )
                    )
                    claimed.insert(match.id)
                } else {
                    // Never offer an action on a parent that mixes claimed and unclaimed nodes.
                    // Replace it with the unclaimed frontier so every actionable node is clean.
                    let frontier = Self.unclaimedFrontier(
                        under: match.id,
                        tree: tree,
                        claimed: claimed,
                        claimedSubtree: claimedSubtree ?? []
                    )
                    for child in frontier {
                        let bytes = tree.allocSize[Int(child)]
                        guard bytes > 0 else { continue }
                        guard !match.perItem || bytes >= rule.minBytes else { continue }
                        items.append(
                            MatchItem(
                                id: child,
                                bytes: bytes,
                                projectModTime: Self.projectModTime(
                                    for: child,
                                    tree: tree,
                                    usesProjectDate: usesProjectDate
                                )
                            )
                        )
                        claimed.insert(child)
                    }
                    claimed.insert(match.id)
                }
            }

            guard !items.isEmpty else { continue }
            let total = items.reduce(UInt64(0)) {
                InsightBuilder.saturatingAdd($0, $1.bytes)
            }
            guard total >= rule.minBytes else { continue }

            let sorted = items.sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.id < rhs.id
            }
            let children = sorted.prefix(10).map { item in
                InsightChild(
                    name: tree.name(item.id),
                    bytes: item.bytes,
                    nodeID: item.id,
                    projectModTime: item.projectModTime
                )
            }
            let byProjectDate: [InsightChild]
            if usesProjectDate {
                byProjectDate = items
                    .sorted { lhs, rhs in
                        if lhs.projectModTime != rhs.projectModTime {
                            return lhs.projectModTime > rhs.projectModTime
                        }
                        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                        return lhs.id < rhs.id
                    }
                    .prefix(10)
                    .map { item in
                        InsightChild(
                            name: tree.name(item.id),
                            bytes: item.bytes,
                            nodeID: item.id,
                            projectModTime: item.projectModTime
                        )
                    }
            } else {
                byProjectDate = []
            }

            let paths = InsightBuilder.paths(
                sorted.map { $0.id },
                in: tree,
                limit: maxPathsPerInsight
            )
            let scopePath = Self.scopePath(for: rule, homePath: home, tree: tree)
            let insight = Insight(
                id: "\(rule.id):\(scopePath)",
                title: rule.title,
                detail: rule.detail,
                nodeIDs: sorted.map { $0.id },
                paths: paths,
                bytes: total,
                risk: rule.risk,
                action: rule.action,
                children: Array(children),
                childrenByProjectDate: byProjectDate,
                category: rule.category
            )
            insights.append(insight)
        }

        return RuleEvaluation(
            insights: insights,
            claimed: claimed,
            restrictions: restrictions
        )
    }

    // MARK: - Overlap helpers

    private static func mergeRestriction(
        _ existing: RuleRestriction?,
        _ new: RuleRestriction
    ) -> RuleRestriction {
        guard let existing else { return new }
        let risk: Risk = new.risk.severity > existing.risk.severity ? new.risk : existing.risk
        let action: SuggestedAction
        if case .displayOnly = existing.action {
            action = existing.action
        } else if case .displayOnly = new.action {
            action = new.action
        } else {
            action = existing.action
        }
        return RuleRestriction(risk: risk, action: action)
    }

    private static func isPerItemPattern(_ pattern: PathPattern) -> Bool {
        switch pattern {
        case .homeGlobChildren(_), .homeGlob(_), .anyDirectoryNamed(_):
            return true
        case .home(_), .absolute(_), .downloads:
            return false
        }
    }

    private static func projectModTime(
        for id: NodeID,
        tree: ScanTree,
        usesProjectDate: Bool
    ) -> Int64 {
        guard usesProjectDate else { return 0 }
        let parent = tree.parent[Int(id)]
        return parent >= 0 ? tree.modTime[Int(parent)] : 0
    }

    private static func hasAnyDirectoryNamedPattern(_ rule: Rule) -> Bool {
        for pattern in rule.patterns {
            if case .anyDirectoryNamed = pattern { return true }
        }
        return false
    }

    private static func isClaimedOrInsideClaimed(
        _ id: NodeID,
        tree: ScanTree,
        claimed: Set<NodeID>
    ) -> Bool {
        var current = id
        while current >= 0 {
            if claimed.contains(current) { return true }
            current = tree.parent[Int(current)]
        }
        return false
    }

    /// Union of claimed bytes inside each subtree. A claimed node stops the accumulation, so nested
    /// claims are never counted twice.
    private static func claimedBytesSubtree(
        tree: ScanTree,
        claimed: Set<NodeID>
    ) -> [UInt64] {
        let count = tree.count
        var subtree = [UInt64](repeating: 0, count: count)
        for id in claimed {
            let index = Int(id)
            if index >= 0 && index < count {
                subtree[index] = tree.allocSize[index]
            }
        }
        var index = count - 1
        while index > 0 {
            let parent = Int(tree.parent[index])
            if parent >= 0 && subtree[index] > 0 && !claimed.contains(NodeID(parent)) {
                subtree[parent] = InsightBuilder.saturatingAdd(subtree[parent], subtree[index])
            }
            index -= 1
        }
        return subtree
    }

    /// Nodes below `root` whose subtrees contain no claimed bytes. Mixed directories are walked so
    /// the result is a set of directly actionable, fully unclaimed nodes. Mixed bundles are skipped
    /// because a bundle cannot be split safely.
    private static func unclaimedFrontier(
        under root: NodeID,
        tree: ScanTree,
        claimed: Set<NodeID>,
        claimedSubtree: [UInt64]
    ) -> [NodeID] {
        var result: [NodeID] = []
        var stack: [NodeID] = []
        var child = tree.firstChild[Int(root)]
        while child >= 0 {
            stack.append(child)
            child = tree.nextSibling[Int(child)]
        }
        while let id = stack.popLast() {
            if claimed.contains(id) { continue }
            let index = Int(id)
            let inside = claimedSubtree[index]
            if inside == 0 {
                result.append(id)
                continue
            }
            if inside >= tree.allocSize[index] { continue }
            let kind = tree.kind[index]
            guard kind.isContainer, kind != .bundle else { continue }
            var nested = tree.firstChild[index]
            while nested >= 0 {
                stack.append(nested)
                nested = tree.nextSibling[Int(nested)]
            }
        }
        return result
    }

    // MARK: - Scope path (stable insight id)

    private static func scopePath(for rule: Rule, homePath: String, tree: ScanTree) -> String {
        guard let first = rule.patterns.first else { return tree.rootPath }
        switch first {
        case .home(let relative), .homeGlobChildren(let relative):
            return PathSupport.join(homePath, relative)
        case .absolute(let absolute):
            return absolute
        case .homeGlob(let glob):
            let parts = glob.split(separator: "/", omittingEmptySubsequences: true)
            let parentRelative = parts.dropLast().joined(separator: "/")
            return parentRelative.isEmpty
                ? homePath
                : PathSupport.join(homePath, parentRelative)
        case .anyDirectoryNamed(_):
            return homePath
        case .downloads:
            return PathSupport.join(homePath, "Downloads")
        }
    }

    // MARK: - Pattern resolution

    private static let installerSuffixes: [[UInt8]] = [
        Array(".dmg".utf8), Array(".pkg".utf8), Array(".zip".utf8),
    ]
    private static let largeDownloadsFileBytes: UInt64 = 500 * 1024 * 1024

    private static func nodes(
        matching pattern: PathPattern,
        in tree: ScanTree,
        homePath: String,
        claimed: Set<NodeID>
    ) -> [NodeID] {
        switch pattern {
        case .home(let relative):
            guard let id = tree.node(atPath: PathSupport.join(homePath, relative)) else { return [] }
            return [id]

        case .absolute(let absolute):
            guard let id = tree.node(atPath: absolute) else { return [] }
            return [id]

        case .homeGlobChildren(let relative):
            guard let parent = tree.node(atPath: PathSupport.join(homePath, relative)) else { return [] }
            var result: [NodeID] = []
            var child = tree.firstChild[Int(parent)]
            while child >= 0 {
                if tree.kind[Int(child)].isContainer && tree.nameLen(child) > 0 {
                    result.append(child)
                }
                child = tree.nextSibling[Int(child)]
            }
            return result

        case .homeGlob(let glob):
            let parts = glob.split(separator: "/", omittingEmptySubsequences: true)
            guard let last = parts.last else { return [] }
            let parentRelative = parts.dropLast().joined(separator: "/")
            let parentPath = parentRelative.isEmpty
                ? homePath
                : PathSupport.join(homePath, parentRelative)
            guard let parent = tree.node(atPath: parentPath) else { return [] }
            let patternString = String(last)
            var result: [NodeID] = []
            var child = tree.firstChild[Int(parent)]
            while child >= 0 {
                if tree.kind[Int(child)].isContainer,
                   GlobPattern.matches(pattern: patternString, name: tree.name(child)) {
                    result.append(child)
                }
                child = tree.nextSibling[Int(child)]
            }
            return result

        case .anyDirectoryNamed(let names):
            return anyDirectories(
                named: names,
                in: tree,
                homePath: homePath,
                claimed: claimed
            )

        case .downloads:
            guard let downloads = tree.node(atPath: PathSupport.join(homePath, "Downloads")) else {
                return []
            }
            var result: [NodeID] = []
            var stack: [NodeID] = [downloads]
            while let id = stack.popLast() {
                var child = tree.firstChild[Int(id)]
                while child >= 0 {
                    let kind = tree.kind[Int(child)]
                    if kind.isContainer {
                        stack.append(child)
                    } else if kind == .file {
                        if tree.allocSize[Int(child)] >= largeDownloadsFileBytes
                            || tree.nameHasAnySuffixIgnoringCase(child, installerSuffixes) {
                            result.append(child)
                        }
                    }
                    child = tree.nextSibling[Int(child)]
                }
            }
            return result
        }
    }

    /// Case-sensitive search below the home directory. Skips ~/Library, ~/.Trash, bundles and any
    /// node already claimed by an earlier rule, and never descends into a match.
    private static func anyDirectories(
        named names: [String],
        in tree: ScanTree,
        homePath: String,
        claimed: Set<NodeID>
    ) -> [NodeID] {
        guard tree.count > 0, !names.isEmpty else { return [] }
        guard let homeNode = tree.node(atPath: homePath) else { return [] }
        if claimed.contains(homeNode) { return [] }

        let candidates = names.map { Array($0.utf8) }
        let homeLibrary = tree.child(of: homeNode, named: "Library")
        let homeTrash = tree.child(of: homeNode, named: ".Trash")

        var result: [NodeID] = []
        var stack: [NodeID] = [homeNode]
        while let id = stack.popLast() {
            if id != homeNode {
                if claimed.contains(id) { continue }
                if id == homeLibrary || id == homeTrash { continue }
                if tree.nameEqualsAnyExact(id, candidates) {
                    result.append(id)
                    continue
                }
            }
            var child = tree.firstChild[Int(id)]
            while child >= 0 {
                if tree.kind[Int(child)] == .directory {
                    stack.append(child)
                }
                child = tree.nextSibling[Int(child)]
            }
        }
        return result
    }
}
