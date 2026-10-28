import Foundation
import ScannerKit

struct RuleEvaluation: Sendable {
    var insights: [Insight]
    /// Every node claimed by a produced insight, used to avoid double counting elsewhere.
    var claimed: Set<NodeID>
    /// Nodes inside careful rules (Mail, Messages, Photos, Docker, swap). Used to protect stale files.
    var protected: [NodeID: SuggestedAction]
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

    private struct MatchItem {
        var id: NodeID
        var bytes: UInt64
        var projectModTime: Int64
    }

    func evaluate(tree: ScanTree, homePath: String) -> RuleEvaluation {
        var insights: [Insight] = []
        var claimed = Set<NodeID>()
        var protected: [NodeID: SuggestedAction] = [:]
        let home = PathSupport.normalize(homePath)

        for rule in rules {
            var seen = Set<NodeID>()
            var rawMatches: [NodeID] = []

            for pattern in rule.patterns {
                let found = Self.nodes(
                    matching: pattern,
                    in: tree,
                    homePath: home,
                    claimed: claimed
                )
                if rule.risk == .careful {
                    for id in found { protected[id] = rule.action }
                }
                for id in found {
                    guard Int(id) >= 0, Int(id) < tree.count else { continue }
                    let include: Bool
                    switch pattern {
                    case .home(_), .absolute(_):
                        include = true
                    case .downloads:
                        include = true
                    case .homeGlobChildren(_), .homeGlob(_), .anyDirectoryNamed(_):
                        include = tree.allocSize[Int(id)] >= rule.minBytes
                    }
                    if include, seen.insert(id).inserted {
                        rawMatches.append(id)
                    }
                }
            }

            guard !rawMatches.isEmpty else { continue }

            let claimedSubtree: [UInt64]? = claimed.isEmpty
                ? nil
                : Self.claimedBytesSubtree(tree: tree, claimed: claimed)
            let usesProjectDate = Self.hasAnyDirectoryNamedPattern(rule)

            var items: [MatchItem] = []
            items.reserveCapacity(rawMatches.count)
            for id in rawMatches {
                if !claimed.isEmpty,
                   Self.isClaimedOrInsideClaimed(id, tree: tree, claimed: claimed) {
                    continue
                }
                var bytes = tree.allocSize[Int(id)]
                if let claimedSubtree {
                    let inside = claimedSubtree[Int(id)]
                    if inside > 0 {
                        bytes = bytes > inside ? bytes - inside : 0
                    }
                }
                guard bytes > 0 else { continue }
                let projectModTime: Int64
                if usesProjectDate {
                    let parent = tree.parent[Int(id)]
                    projectModTime = parent >= 0 ? tree.modTime[Int(parent)] : 0
                } else {
                    projectModTime = 0
                }
                items.append(
                    MatchItem(id: id, bytes: bytes, projectModTime: projectModTime)
                )
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
            let primaryPath = paths.first?.path ?? tree.rootPath
            let insight = Insight(
                id: "\(rule.id):\(primaryPath)",
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
            for item in items { claimed.insert(item.id) }
        }

        return RuleEvaluation(insights: insights, claimed: claimed, protected: protected)
    }

    // MARK: - Overlap helpers

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
