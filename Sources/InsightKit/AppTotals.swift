import Foundation
import ScannerKit

/// Description of one installed application. The caller reads Info.plist; InsightKit stays pure.
public struct AppBundleInfo: Sendable, Hashable {
    /// Absolute path of the `.app` bundle.
    public var path: String
    public var name: String
    public var bundleID: String?

    public init(path: String, name: String, bundleID: String? = nil) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
    }
}

/// One row of the Apps list. `bundleBytes` and `supportBytes` are separate columns.
public struct AppUsage: Sendable, Identifiable, Hashable {
    public var name: String
    public var bundleID: String?
    public var bundlePath: String
    public var bundleBytes: UInt64
    public var supportBytes: UInt64
    /// True when support data is more than twice the bundle size (SPEC section 6).
    public var supportOver2xBundle: Bool
    /// Bundle plus all matched support directories; used to claim coverage for outliers.
    public var nodeIDs: [NodeID]

    public var id: String { bundleID ?? bundlePath }
    public var totalBytes: UInt64 { InsightBuilder.saturatingAdd(bundleBytes, supportBytes) }

    public init(
        name: String,
        bundleID: String?,
        bundlePath: String,
        bundleBytes: UInt64,
        supportBytes: UInt64,
        supportOver2xBundle: Bool,
        nodeIDs: [NodeID]
    ) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.bundleBytes = bundleBytes
        self.supportBytes = supportBytes
        self.supportOver2xBundle = supportOver2xBundle
        self.nodeIDs = nodeIDs
    }
}

public enum AppTotals {
    /// Sums bundle + Application Support (name and bundle id) + Caches/<id> + Containers/<id> +
    /// matching Group Containers + Logs/<name> for each app.
    public static func compute(
        tree: ScanTree,
        homePath: String,
        apps: [AppBundleInfo]
    ) -> [AppUsage] {
        guard tree.count > 0 else { return [] }
        let home = PathSupport.normalize(homePath)
        var usages: [AppUsage] = []
        usages.reserveCapacity(apps.count)

        for app in apps {
            var seen = Set<NodeID>()
            var claimed: [NodeID] = []
            var bundleBytes: UInt64 = 0
            var supportBytes: UInt64 = 0

            func include(_ id: NodeID, isSupport: Bool) {
                let index = Int(id)
                guard index >= 0, index < tree.count else { return }
                guard seen.insert(id).inserted else { return }
                claimed.append(id)
                let bytes = tree.allocSize[index]
                if isSupport {
                    supportBytes = InsightBuilder.saturatingAdd(supportBytes, bytes)
                } else {
                    bundleBytes = InsightBuilder.saturatingAdd(bundleBytes, bytes)
                }
            }

            if let bundleNode = tree.node(atPath: app.path) {
                include(bundleNode, isSupport: false)
            }

            for relative in [
                "Library/Application Support/\(app.name)",
                "Library/Logs/\(app.name)",
            ] {
                if let id = tree.node(atPath: PathSupport.join(home, relative)) {
                    include(id, isSupport: true)
                }
            }

            if let bundleID = app.bundleID, !bundleID.isEmpty {
                for relative in [
                    "Library/Application Support/\(bundleID)",
                    "Library/Caches/\(bundleID)",
                    "Library/Containers/\(bundleID)",
                ] {
                    if let id = tree.node(atPath: PathSupport.join(home, relative)) {
                        include(id, isSupport: true)
                    }
                }
                includeGroupContainers(
                    tree: tree,
                    home: home,
                    bundleID: bundleID,
                    include: include
                )
            }

            let over2x: Bool
            if bundleBytes == 0 {
                over2x = supportBytes > 0
            } else {
                over2x = Double(supportBytes) > 2.0 * Double(bundleBytes)
            }

            usages.append(
                AppUsage(
                    name: app.name,
                    bundleID: app.bundleID,
                    bundlePath: app.path,
                    bundleBytes: bundleBytes,
                    supportBytes: supportBytes,
                    supportOver2xBundle: over2x,
                    nodeIDs: claimed
                )
            )
        }

        usages.sort { lhs, rhs in
            let lTotal = Double(lhs.bundleBytes) + Double(lhs.supportBytes)
            let rTotal = Double(rhs.bundleBytes) + Double(rhs.supportBytes)
            if lTotal != rTotal { return lTotal > rTotal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return usages
    }

    private static func includeGroupContainers(
        tree: ScanTree,
        home: String,
        bundleID: String,
        include: (NodeID, Bool) -> Void
    ) {
        let groupRootPath = PathSupport.join(home, "Library/Group Containers")
        guard let groupRoot = tree.node(atPath: groupRootPath) else { return }
        let exact = Array(bundleID.utf8)
        let suffix = Array(("." + bundleID).utf8)
        var child = tree.firstChild[Int(groupRoot)]
        while child >= 0 {
            if tree.kind[Int(child)].isContainer,
               tree.nameEqualsIgnoringCase(child, exact)
                || tree.nameHasSuffixIgnoringCase(child, suffix) {
                include(child, true)
            }
            child = tree.nextSibling[Int(child)]
        }
    }
}
