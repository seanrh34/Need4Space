import Foundation

/// One entry of the live top list carried in a `ScanProgress` snapshot: a top-level
/// directory whose subtree has completed (bottom-up aggregation), with its total.
public struct ScanProgressItem: Sendable, Hashable {
    public var name: String
    public var nodeID: NodeID
    public var bytes: UInt64
    public init(name: String, nodeID: NodeID, bytes: UInt64) {
        self.name = name; self.nodeID = nodeID; self.bytes = bytes
    }
}

/// Live progress snapshot. Published at 10 Hz on the scanner's progress stream (SPEC §4:
/// aggregate counters, never per-file updates). Values are small structs (plan revision 4).
public struct ScanProgress: Sendable, Hashable {
    /// Seconds since the scan started.
    public var elapsedSeconds: Double
    /// File bytes seen so far (allocated; before hard-link deduplication).
    public var bytesFound: UInt64
    /// Regular files seen so far (including files inside small-file groups).
    public var filesFound: Int
    /// Directories listed so far.
    public var directoriesScanned: Int
    /// Directories enqueued but not yet finalized.
    public var directoriesPending: Int
    /// Up to 5 completed children of the scan root, largest first.
    public var topItems: [ScanProgressItem]

    public init(
        elapsedSeconds: Double = 0, bytesFound: UInt64 = 0, filesFound: Int = 0,
        directoriesScanned: Int = 0, directoriesPending: Int = 0, topItems: [ScanProgressItem] = []
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.bytesFound = bytesFound
        self.filesFound = filesFound
        self.directoriesScanned = directoriesScanned
        self.directoriesPending = directoriesPending
        self.topItems = topItems
    }
}
