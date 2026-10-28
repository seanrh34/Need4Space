import Foundation
import ScannerKit

/// Accounting for the gap between what the volume reports as used and what the scanner saw.
/// Per PLAN revision 7 the parts are facts listed next to a non-negative gap, not addends.
public struct HiddenSpace: Sendable, Hashable, Codable {
    public static let remainderLabel = "APFS clones, system volumes and metadata"

    public var usedBytes: UInt64
    public var scannedBytes: UInt64
    /// max(0, used - scanned)
    public var gapBytes: UInt64
    /// max(0, scanned - used). APFS clones can make the scanned total exceed the volume figure.
    public var overcountBytes: UInt64
    /// Reported as a fact; may include snapshot space.
    public var purgeableBytes: UInt64
    public var snapshotCount: Int
    /// Only snapshots with a known size contribute; `tmutil` usually reports none.
    public var snapshotKnownBytes: UInt64
    public var blockedCount: Int
    /// max(0, gapBytes - purgeableBytes).
    public var remainderBytes: UInt64

    public init(
        usedBytes: UInt64,
        scannedBytes: UInt64,
        gapBytes: UInt64,
        overcountBytes: UInt64,
        purgeableBytes: UInt64,
        snapshotCount: Int,
        snapshotKnownBytes: UInt64,
        blockedCount: Int,
        remainderBytes: UInt64
    ) {
        self.usedBytes = usedBytes
        self.scannedBytes = scannedBytes
        self.gapBytes = gapBytes
        self.overcountBytes = overcountBytes
        self.purgeableBytes = purgeableBytes
        self.snapshotCount = snapshotCount
        self.snapshotKnownBytes = snapshotKnownBytes
        self.blockedCount = blockedCount
        self.remainderBytes = remainderBytes
    }

    public var hasGap: Bool { gapBytes > 0 || overcountBytes > 0 }

    public static func compute(
        tree: ScanTree,
        volume: VolumeInfo?,
        blocked: [NodeID]
    ) -> HiddenSpace {
        let scanned = tree.count > 0 ? tree.allocSize[0] : 0
        let used = volume?.usedBytes ?? scanned

        let gap: UInt64
        let overcount: UInt64
        if used >= scanned {
            gap = used - scanned
            overcount = 0
        } else {
            gap = 0
            overcount = scanned - used
        }

        let purgeable = volume?.purgeableBytes ?? 0
        let remainder = gap > purgeable ? gap - purgeable : 0

        var snapshotCount = 0
        var knownBytes: UInt64 = 0
        if let snapshots = volume?.snapshots {
            snapshotCount = snapshots.count
            for snapshot in snapshots {
                if let bytes = snapshot.bytes {
                    knownBytes = InsightBuilder.saturatingAdd(knownBytes, bytes)
                }
            }
        }

        return HiddenSpace(
            usedBytes: used,
            scannedBytes: scanned,
            gapBytes: gap,
            overcountBytes: overcount,
            purgeableBytes: purgeable,
            snapshotCount: snapshotCount,
            snapshotKnownBytes: knownBytes,
            blockedCount: blocked.count,
            remainderBytes: remainder
        )
    }
}
