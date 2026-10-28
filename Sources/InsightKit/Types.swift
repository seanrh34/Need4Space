import Foundation
import ScannerKit

/// How risky it is to act on an insight.
public enum Risk: String, Sendable, Hashable, CaseIterable, Codable {
    /// Nothing is lost that the system cannot recreate.
    case safe
    /// Look before deleting; the data may matter.
    case review
    /// Never act automatically; may break running software or lose user data.
    case careful
}

extension Risk {
    /// Used to merge restrictions inherited from several containing rules.
    var severity: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .careful: return 2
        }
    }
}

/// The action the UI may offer for an insight.
///
/// Deliberately there is no programmatic "empty Trash" action: per PLAN revision 14 the Trash
/// insight only opens the Trash in Finder and the user empties it themselves.
public enum SuggestedAction: Sendable, Hashable {
    /// Move the matched nodes to the Trash (never a permanent delete).
    case trash
    /// Open the path in Finder and let the user decide.
    case revealOnly
    /// Show a command the user can copy and run in a terminal.
    case copyCommand(String)
    /// Explain only; no action offered.
    case displayOnly
    /// Open a System Settings pane.
    case openSettings

    /// The shell command for `.copyCommand`, otherwise nil.
    public var command: String? {
        if case .copyCommand(let command) = self { return command }
        return nil
    }
}

/// Broad bucket used for colouring the sunburst and grouping the UI.
public enum Category: String, Sendable, Hashable, CaseIterable, Codable {
    case apps
    case documents
    case media
    case developer
    case system
    case caches
    case trash
    case other
}

/// One row inside an insight's expandable top-10 list.
public struct InsightChild: Sendable, Hashable {
    public var name: String
    public var bytes: UInt64
    public var nodeID: NodeID
    /// Modification time of the child's parent folder. Non-zero for build-output matches, used to
    /// offer a "most recently worked on project" ordering next to the size ordering.
    public var projectModTime: Int64

    public init(name: String, bytes: UInt64, nodeID: NodeID, projectModTime: Int64 = 0) {
        self.name = name
        self.bytes = bytes
        self.nodeID = nodeID
        self.projectModTime = projectModTime
    }
}

/// One "look at this" item. Sized bytes are the bytes the insight is about (for a rule: the sum of
/// the matched nodes; for a large folder: the part not claimed by other rules).
public struct Insight: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var nodeIDs: [NodeID]
    /// At most `InsightsConfig.maxPathsPerInsight` entries, largest first.
    public var paths: [URL]
    public var bytes: UInt64
    public var risk: Risk
    public var action: SuggestedAction
    /// Up to ten entries, largest first.
    public var children: [InsightChild]
    /// Alternate top ten ordered by project modification time (build-output insights only).
    public var childrenByProjectDate: [InsightChild]
    public var category: Category

    public init(
        id: String,
        title: String,
        detail: String,
        nodeIDs: [NodeID],
        paths: [URL],
        bytes: UInt64,
        risk: Risk,
        action: SuggestedAction,
        children: [InsightChild] = [],
        childrenByProjectDate: [InsightChild] = [],
        category: Category = .other
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.nodeIDs = nodeIDs
        self.paths = paths
        self.bytes = bytes
        self.risk = risk
        self.action = action
        self.children = children
        self.childrenByProjectDate = childrenByProjectDate
        self.category = category
    }
}

/// Everything the Insights screen needs, produced in one pass over the finished tree.
public struct InsightReport: Sendable {
    public var insights: [Insight]
    public var reclaimableSafeBytes: UInt64
    public var apps: [AppUsage]
    public var hidden: HiddenSpace

    public init(
        insights: [Insight],
        reclaimableSafeBytes: UInt64,
        apps: [AppUsage],
        hidden: HiddenSpace
    ) {
        self.insights = insights
        self.reclaimableSafeBytes = reclaimableSafeBytes
        self.apps = apps
        self.hidden = hidden
    }
}

/// Thresholds and limits used by the insight engine. All byte values are allocated bytes.
public struct InsightsConfig: Sendable, Hashable {
    /// Fraction of the volume's used bytes a folder must be unexplained by to be an outlier.
    public var largeFolderFraction: Double
    public var staleFileMinBytes: UInt64
    public var staleFileAgeDays: Int
    public var growthMinBytes: UInt64
    /// Deepest directory level (root = 0) considered for fast growers.
    public var growthMaxDepth: Int
    public var maxPathsPerInsight: Int

    public init(
        largeFolderFraction: Double = 0.03,
        staleFileMinBytes: UInt64 = 500 * 1024 * 1024,
        staleFileAgeDays: Int = 365,
        growthMinBytes: UInt64 = 1024 * 1024 * 1024,
        growthMaxDepth: Int = 6,
        maxPathsPerInsight: Int = 100
    ) {
        self.largeFolderFraction = largeFolderFraction
        self.staleFileMinBytes = staleFileMinBytes
        self.staleFileAgeDays = staleFileAgeDays
        self.growthMinBytes = growthMinBytes
        self.growthMaxDepth = max(0, growthMaxDepth)
        self.maxPathsPerInsight = max(0, maxPathsPerInsight)
    }
}
