import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let gb = Size.gb
private let mb = Size.mb

@Test func hiddenSpaceSplitsGapAndFacts() {
    let tree = FixtureTree.build([
        .dir("Library", [.file("data", 80 * gb)]),
    ])
    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 500 * gb,
        usedBytes: 100 * gb,
        freeBytes: 400 * gb,
        purgeableBytes: 2 * gb,
        snapshots: [
            LocalSnapshot(name: "snap-a"),
            LocalSnapshot(name: "snap-b", bytes: 1 * gb),
            LocalSnapshot(name: "snap-c"),
        ]
    )
    let hidden = HiddenSpace.compute(tree: tree, volume: volume, blocked: [0, 1, 2])
    #expect(hidden.usedBytes == 100 * gb)
    #expect(hidden.scannedBytes == 80 * gb)
    #expect(hidden.gapBytes == 20 * gb)
    #expect(hidden.overcountBytes == 0)
    #expect(hidden.purgeableBytes == 2 * gb)
    #expect(hidden.remainderBytes == 18 * gb)
    #expect(hidden.snapshotCount == 3)
    #expect(hidden.snapshotKnownBytes == 1 * gb)
    #expect(hidden.blockedCount == 3)
}

@Test func hiddenSpaceReportsOvercountWithoutNegatives() {
    let tree = FixtureTree.build([
        .dir("Library", [.file("data", 90 * gb)]),
    ])
    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 500 * gb,
        usedBytes: 80 * gb,
        freeBytes: 420 * gb,
        purgeableBytes: 5 * gb
    )
    let hidden = HiddenSpace.compute(tree: tree, volume: volume, blocked: [])
    #expect(hidden.gapBytes == 0)
    #expect(hidden.overcountBytes == 10 * gb)
    #expect(hidden.remainderBytes == 0)
    #expect(hidden.purgeableBytes == 5 * gb)
}

@Test func purgeableLargerThanGapDoesNotProduceNegativeRemainder() {
    let tree = FixtureTree.build([
        .file("data", 10 * gb),
    ])
    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 500 * gb,
        usedBytes: 12 * gb,
        freeBytes: 488 * gb,
        purgeableBytes: 8 * gb
    )
    let hidden = HiddenSpace.compute(tree: tree, volume: volume, blocked: [])
    #expect(hidden.gapBytes == 2 * gb)
    #expect(hidden.remainderBytes == 0)
}

@Test func unknownVolumeUsesScannedTotalAndShowsNoGap() {
    let tree = FixtureTree.build([
        .file("data", 1 * gb),
    ])
    let hidden = HiddenSpace.compute(tree: tree, volume: nil, blocked: [])
    #expect(hidden.gapBytes == 0)
    #expect(hidden.overcountBytes == 0)
    #expect(hidden.remainderBytes == 0)
    #expect(hidden.scannedBytes == 1 * gb)
    #expect(hidden.usedBytes == 1 * gb)
}

@Test func snapshotWithoutSizesCountsButAddsNoBytes() {
    let tree = FixtureTree.build([
        .file("data", 1 * mb),
    ])
    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 100 * gb,
        usedBytes: 10 * gb,
        freeBytes: 90 * gb,
        purgeableBytes: 0,
        snapshots: [LocalSnapshot(name: "a"), LocalSnapshot(name: "b")]
    )
    let hidden = HiddenSpace.compute(tree: tree, volume: volume, blocked: [])
    #expect(hidden.snapshotCount == 2)
    #expect(hidden.snapshotKnownBytes == 0)
    #expect(hidden.gapBytes > 0)
    #expect(hidden.remainderBytes == hidden.gapBytes)
}
