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
    public var peakResidentBytes: UInt64 = 0
    public init() {}
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
    public init(tree: ScanTree, blocked: [NodeID], volume: VolumeInfo?, scannedAt: Date,
                stats: ScanStats, lastEventID: UInt64? = nil) {
        self.tree = tree; self.blocked = blocked; self.volume = volume
        self.scannedAt = scannedAt; self.stats = stats; self.lastEventID = lastEventID
    }

    public var scannedTotalBytes: UInt64 { tree.count > 0 ? tree.allocSize[0] : 0 }
}
