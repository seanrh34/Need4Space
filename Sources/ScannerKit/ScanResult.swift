import Foundation

public struct LocalSnapshot: Sendable, Hashable, Codable {
    /// e.g. "com.apple.TimeMachine.2026-10-28-101500.local"
    public var name: String
    public var date: Date?
    /// Usually unknown (tmutil does not report sizes).
    public var bytes: UInt64?
    public init(name: String, date: Date? = nil, bytes: UInt64? = nil) {
        self.name = name; self.date = date; self.bytes = bytes
    }
}

public struct VolumeInfo: Sendable, Hashable, Codable {
    public var mountPath: String
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var freeBytes: UInt64
    /// volumeAvailableCapacityForImportantUsage - free (0 if unavailable or negative).
    public var purgeableBytes: UInt64
    public var snapshots: [LocalSnapshot]
    public init(mountPath: String, totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64,
                purgeableBytes: UInt64 = 0, snapshots: [LocalSnapshot] = []) {
        self.mountPath = mountPath; self.totalBytes = totalBytes; self.usedBytes = usedBytes
        self.freeBytes = freeBytes; self.purgeableBytes = purgeableBytes; self.snapshots = snapshots
    }
}

public struct ScanStats: Sendable, Hashable, Codable {
    public var elapsedSeconds: Double = 0
    public var directoriesScanned: Int = 0
    public var filesSeen: Int = 0
    public var hardLinksDeduplicated: Int = 0
    public var mountPointsSkipped: Int = 0
    /// Paths of skipped mount points (capped; see scanner). Added in M1 (revision 1).
    public var skippedMountPaths: [String] = []
    public var peakResidentBytes: UInt64 = 0
    public init() {}
}

/// A directory that could not be read completely: an open or getattrlistbulk failure
/// other than EPERM/EACCES (those become blocked nodes), or a failed open inside the
/// /private/var/vm walk. Children read so far are kept; this subtree's totals may be
/// undercounts and must not be presented as complete (review round 2 fix 7).
public struct IncompleteDir: Sendable, Hashable {
    public var nodeID: NodeID
    public var errno: Int32
    public init(nodeID: NodeID, errno: Int32) {
        self.nodeID = nodeID
        self.errno = errno
    }
}

/// Immutable result of a completed scan.
public struct ScanResult: Sendable {
    public var tree: ScanTree
    /// Node ids of kind `.blocked`.
    public var blocked: [NodeID]
    public var volume: VolumeInfo?
    public var scannedAt: Date
    public var stats: ScanStats
    /// FSEvents id at scan start (M5); nil if not recorded.
    public var lastEventID: UInt64?
    /// Directories whose contents are known to be incomplete (review round 2 fix 7).
    public var incomplete: [IncompleteDir]
    public init(tree: ScanTree, blocked: [NodeID], volume: VolumeInfo?, scannedAt: Date,
                stats: ScanStats, lastEventID: UInt64? = nil, incomplete: [IncompleteDir] = []) {
        self.tree = tree; self.blocked = blocked; self.volume = volume
        self.scannedAt = scannedAt; self.stats = stats; self.lastEventID = lastEventID
        self.incomplete = incomplete
    }

    public var scannedTotalBytes: UInt64 { tree.count > 0 ? tree.allocSize[0] : 0 }
}
