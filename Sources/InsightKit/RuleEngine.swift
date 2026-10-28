import Foundation
import ScannerKit

struct RuleEvaluation: Sendable {
    var insights: [Insight]
    /// Every node claimed by a produced insight, used to avoid double counting elsewhere.
    var claimed: Set<NodeID>
}

/// Turns the rule table into insights. All work is linear in the tree size; only the handful of
/// fixed paths are materialised as strings.
public struct RuleEngine: Sendable {
    public var rules: [Rule]
    public var maxPathsPerInsight: Int

    public init(rules: [Rule] = RuleTable.all, maxPathsPerInsight: Int = 100) {
        self.rules = rules
        self.maxPathsPerInsight = maxPathsPerInsight
    }

    func evaluate(tree: ScanTree, homePath: String) -> RuleEvaluation {
        var insights: [Insight] = []
        var claimed = Set<NodeID>()
        let home = PathSupport.normalize(homePath)

        for rule in rules {
            var matched: [NodeID] = []
            var seen = Set<NodeID>()

            for pattern in rule.patterns {
                let found = Self.nodes(matching: pattern, in: tree, homePath: home)
                if case .anyDirectoryNamed = pattern {
                    for id in found {
                        guard Int(id) < tree.count else { continue }
                        guard tree.allocSize[Int(id)] >= rule.minBytes else { continue }
                        if seen.insert(id).inserted { matched.append(id) }
                    }
                } else {
                    for id in found where Int(id) < tree.count {
                        if seen.insert(id).inserted { matched.append(id) }
                    }
                }
            }

            guard !matched.isEmpty else { continue }
            let total = InsightBuilder.sumBytes(matched, in: tree)
            guard total >= rule.minBytes else { continue }

            let sorted = InsightBuilder.sortedBySize(matched, in: tree)
            let children = sorted.prefix(10).map { id in
                InsightChild(
                    name: tree.name(id),
                    bytes: tree.allocSize[Int(id)],
                    nodeID: id
                )
            }

            let insight = Insight(
                id: rule.id,
                title: rule.title,
                detail: rule.detail,
                nodeIDs: sorted,
                paths: InsightBuilder.paths(sorted, in: tree, limit: maxPathsPerInsight),
                bytes: total,
                risk: rule.risk,
                action: rule.action,
                children: Array(children),
                category: rule.category
            )
            insights.append(insight)
            for id in sorted { claimed.insert(id) }
        }

        return RuleEvaluation(insights: insights, claimed: claimed)
    }

    // MARK: - Pattern resolution

    private static let installerSuffixes: [[UInt8]] = [
        Array(".dmg".utf8), Array(".pkg".utf8), Array(".zip".utf8),
    ]
    private static let largeDownloadsFileBytes: UInt64 = 500 * 1024 * 1024

    private static func nodes(matching pattern: PathPattern, in tree: ScanTree, homePath: String) -> [NodeID] {
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
            guard tree.count > 0, !names.isEmpty else { return [] }
            let candidates = names.map { Array($0.utf8) }
            var result: [NodeID] = []
            var stack: [NodeID] = [0]
            while let id = stack.popLast() {
                if id != 0, tree.kind[Int(id)].isContainer, tree.nameEqualsAny(id, candidates) {
                    result.append(id)
                    continue
                }
                var child = tree.firstChild[Int(id)]
                while child >= 0 {
                    stack.append(child)
                    child = tree.nextSibling[Int(child)]
                }
            }
            return result

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
}
