import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let home = FixtureTree.defaultRootPath
private let gb = Size.gb

/// One million nodes: 1,000 top-level project folders with 999 files each, plus the root.
/// The engine must stay linear and must not build a path string for every node.
@Test func millionNodeEngineRunsWellUnderTwoSeconds() {
    let nodeTarget = 1_000_000
    let directoryCount = 1_000
    let filesPerDirectory = 999
    let fileBytes: UInt64 = 4 * 1024

    var tree = ScanTree(rootPath: home, reserveCapacity: nodeTarget + 1)
    _ = tree.addNode(name: "", kind: .directory, parent: ScanTree.none)

    let fileName = Array("f".utf8)
    var directoryIDs: [NodeID] = []
    directoryIDs.reserveCapacity(directoryCount)

    var directory = 0
    while directory < directoryCount {
        let dirID = tree.addNode(name: "d\(directory)", kind: .directory, parent: 0)
        directoryIDs.append(dirID)
        var file = 0
        while file < filesPerDirectory {
            _ = tree.addNode(
                nameBytes: fileName,
                kind: .file,
                parent: dirID,
                allocSize: fileBytes,
                logicalSize: fileBytes,
                fileCount: 1
            )
            file += 1
        }
        directory += 1
    }

    var rootBytes: UInt64 = 0
    let perDirectoryBytes = UInt64(filesPerDirectory) * fileBytes
    for id in directoryIDs {
        tree.allocSize[Int(id)] = perDirectoryBytes
        tree.logicalSize[Int(id)] = perDirectoryBytes
        tree.fileCount[Int(id)] = UInt32(filesPerDirectory)
        rootBytes += perDirectoryBytes
    }
    tree.allocSize[0] = rootBytes
    tree.logicalSize[0] = rootBytes
    tree.fileCount[0] = UInt32(directoryCount * filesPerDirectory)

    #expect(tree.count == nodeTarget + 1)
    #expect(rootBytes < 5 * gb)

    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 500 * gb,
        usedBytes: rootBytes,
        freeBytes: 500 * gb - rootBytes
    )

    let engine = InsightEngine()
    let start = Date()
    let report = engine.run(
        tree: tree,
        homePath: home,
        volume: volume,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let elapsed = Date().timeIntervalSince(start)

    #expect(report.insights.isEmpty)
    #expect(report.reclaimableSafeBytes == 0)

    #if DEBUG
    // Debug builds bounds-check and do not inline; release is the number that matters (< 2 s).
    #expect(elapsed < 10.0, "engine took \(elapsed) s on 1M nodes (debug)")
    #else
    #expect(elapsed < 2.0, "engine took \(elapsed) s on 1M nodes")
    #endif
}
