import Testing
import Darwin
import Foundation
@testable import ScannerKit

// Fixture tests: the scanner runs on real temp directories; expected values are computed
// with lstat in the test (the scanner itself never stats per file). Tests remove only
// their own temp dirs, in teardown (defer).

private enum FixtureError: Error {
    case setupFailed(String)
    case statFailed(String)
}

private struct DeviceKey: Hashable {
    let dev: UInt32
    let ino: UInt64
}

private struct StatInfo {
    var dev: UInt32
    var ino: UInt64
    var nlink: UInt64
    var blocks: UInt64
    var size: UInt64
    var mode: Int32
    var mtime: Int64
}

private func statOf(_ path: String) throws -> StatInfo {
    var st = stat()
    guard lstat(path, &st) == 0 else {
        throw FixtureError.statFailed(path)
    }
    return StatInfo(
        dev: st.st_dev, ino: st.st_ino, nlink: UInt64(st.st_nlink),
        blocks: UInt64(st.st_blocks), size: UInt64(st.st_size),
        mode: Int32(st.st_mode), mtime: Int64(st.st_mtime))
}

private func allocOf(_ path: String) throws -> UInt64 {
    try statOf(path).blocks * 512
}

private func makeTempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("n4s-\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ path: String, _ size: Int) throws {
    guard FileManager.default.createFile(atPath: path, contents: Data(count: size)) else {
        throw FixtureError.setupFailed(path)
    }
}

private func child(_ base: URL, _ components: String...) -> String {
    base.path + "/" + components.joined(separator: "/")
}

/// Walks a directory tree with lstat and computes the totals the scanner must produce:
/// allocated size of regular files, hard links counted once (by dev+ino), directories
/// and symlinks contributing 0 bytes.
private func expectedTotals(_ rootPath: String) throws -> (alloc: UInt64, files: Int) {
    var seen = Set<DeviceKey>()
    var alloc: UInt64 = 0
    var files = 0

    func visit(_ path: String) throws {
        let fm = FileManager.default
        for entry in try fm.contentsOfDirectory(atPath: path) {
            let full = path == "/" ? "/" + entry : path + "/" + entry
            let st = try statOf(full)
            if st.mode & S_IFMT == S_IFDIR {
                try visit(full)
            } else if st.mode & S_IFMT == S_IFREG {
                files += 1
                if st.nlink > 1 {
                    let key = DeviceKey(dev: st.dev, ino: st.ino)
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                alloc += st.blocks * 512
            }
        }
    }
    try visit(rootPath)
    return (alloc, files)
}

private func runScan(
    _ root: URL, threads: Int = 4, threshold: UInt64 = 64 * 1024
) async throws -> ScanResult {
    let scanner = ParallelScanner(
        options: ScanOptions(
            root: root.path, threadCount: threads, smallFileThreshold: threshold,
            reserveCapacity: 4096, measureVolumeInfo: false))
    return try await scanner.scan()
}

@Suite("Scanner fixtures", .serialized)
struct FixtureScanTests {

    @Test func nestedDirsAndFilesExactTotals() async throws {
        let root = try makeTempDir("nested")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "a"))
        try FileManager.default.createDirectory(atPath: child(root, "b", "empty"))
        try writeFile(child(root, "a", "big1.bin"), 1_500_000)
        try writeFile(child(root, "a", "small1.txt"), 5_000)
        try writeFile(child(root, "a", "small2.txt"), 7_000)
        try writeFile(child(root, "b", "big2.bin"), 2_500_000)
        try writeFile(child(root, "top.bin"), 3_000_000)

        let result = try await runScan(root)
        let tree = result.tree
        let total = try expectedTotals(root.path)

        #expect(result.scannedTotalBytes == total.alloc)
        #expect(tree.fileCount[0] == UInt32(total.files))

        let a = try #require(tree.node(atPath: child(root, "a")))
        #expect(tree.kind[Int(a)] == .directory)
        #expect(tree.allocSize[Int(a)] == try expectedTotals(child(root, "a")).alloc)

        let empty = try #require(tree.node(atPath: child(root, "b", "empty")))
        #expect(tree.kind[Int(empty)] == .directory)
        #expect(tree.allocSize[Int(empty)] == 0)

        let big1 = try #require(tree.node(atPath: child(root, "a", "big1.bin")))
        let big1Stat = try statOf(child(root, "a", "big1.bin"))
        #expect(tree.kind[Int(big1)] == .file)
        #expect(tree.allocSize[Int(big1)] == big1Stat.blocks * 512)
        #expect(tree.logicalSize[Int(big1)] == big1Stat.size)
        #expect(tree.modTime[Int(big1)] == big1Stat.mtime)

        // Two small files collapse into one group with exact sums.
        let group = try #require(tree.child(of: a, named: "(2 small files)"))
        #expect(tree.kind[Int(group)] == .smallFilesGroup)
        #expect(tree.fileCount[Int(group)] == 2)
        let s1 = try allocOf(child(root, "a", "small1.txt"))
        let s2 = try allocOf(child(root, "a", "small2.txt"))
        #expect(tree.allocSize[Int(group)] == s1 + s2)
    }

    @Test func hardLinkPairInSiblingFoldersCountedOnceWithStableOwner() async throws {
        let root = try makeTempDir("hardlink")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "h1"))
        try FileManager.default.createDirectory(atPath: child(root, "h2"))
        try writeFile(child(root, "h1", "alpha.bin"), 1_000_000)
        #expect(link(child(root, "h1", "alpha.bin"), child(root, "h2", "alpha.bin")) == 0)
        try writeFile(child(root, "h2", "small.txt"), 3_000)

        let fileAlloc = try allocOf(child(root, "h1", "alpha.bin"))
        let total = try expectedTotals(root.path)

        var previousOwnerAlloc: UInt64?
        for _ in 0..<2 {
            let result = try await runScan(root)
            let tree = result.tree
            #expect(result.scannedTotalBytes == total.alloc) // 1 MB counted exactly once

            let h1 = try #require(tree.node(atPath: child(root, "h1", "alpha.bin")))
            let h2 = try #require(tree.node(atPath: child(root, "h2", "alpha.bin")))
            // Owner = lexicographically smallest path: /h1/alpha.bin.
            #expect(tree.allocSize[Int(h1)] == fileAlloc)
            #expect(tree.allocSize[Int(h2)] == 0)
            #expect(result.stats.hardLinksDeduplicated == 1)

            if let previousOwnerAlloc {
                #expect(tree.allocSize[Int(h1)] == previousOwnerAlloc) // stable across runs
            }
            previousOwnerAlloc = tree.allocSize[Int(h1)]
        }
    }

    @Test func hardLinkedSmallFileIsOwnedBySmallerSiblingGroup() async throws {
        let root = try makeTempDir("smalllink")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "g1"))
        try FileManager.default.createDirectory(atPath: child(root, "g2"))
        try writeFile(child(root, "g1", "tiny.bin"), 2_000)
        #expect(link(child(root, "g1", "tiny.bin"), child(root, "g2", "tiny.bin")) == 0)

        let result = try await runScan(root)
        let tree = result.tree
        let tinyAlloc = try allocOf(child(root, "g1", "tiny.bin"))
        #expect(result.scannedTotalBytes == tinyAlloc)
        #expect(result.stats.hardLinksDeduplicated == 1)

        let g1 = try #require(tree.node(atPath: child(root, "g1")))
        let g2 = try #require(tree.node(atPath: child(root, "g2")))
        let group1 = try #require(tree.child(of: g1, named: "(1 small files)"))
        let group2 = try #require(tree.child(of: g2, named: "(1 small files)"))
        #expect(tree.fileCount[Int(group1)] == 1)
        #expect(tree.fileCount[Int(group2)] == 1)
        #expect(tree.allocSize[Int(group1)] == tinyAlloc)
        #expect(tree.allocSize[Int(group2)] == 0)
    }

    @Test func symlinkLoopTerminatesAndIsNotFollowed() async throws {
        let root = try makeTempDir("loop")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: child(root, "loopA"), withDestinationPath: "loopB")
        try FileManager.default.createSymbolicLink(
            atPath: child(root, "loopB"), withDestinationPath: "loopA")
        try writeFile(child(root, "data.bin"), 100_000)

        let result = try await runScan(root)
        let tree = result.tree
        let dataAlloc = try allocOf(child(root, "data.bin"))

        #expect(result.scannedTotalBytes == dataAlloc)
        #expect(tree.fileCount[0] == 1)
        for name in ["loopA", "loopB"] {
            let node = try #require(tree.child(of: 0, named: name))
            #expect(tree.kind[Int(node)] == .symlink)
            #expect(tree.allocSize[Int(node)] == 0)
        }
    }
}

@Suite("Scanner fixtures, part 2", .serialized)
struct FixtureScanTests2 {

    @Test func sparseFileUsesAllocatedSize() async throws {
        let root = try makeTempDir("sparse")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = child(root, "sparse.bin")
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, 8_000_000) == 0)
        let chunk = [UInt8](repeating: 0xA5, count: 4096)
        let written = chunk.withUnsafeBufferPointer { buffer in
            pwrite(fd, buffer.baseAddress!, 4096, 7_996_000)
        }
        #expect(written == 4096)
        close(fd)

        let result = try await runScan(root)
        let tree = result.tree
        let node = try #require(tree.node(atPath: path))
        let st = try statOf(path)
        #expect(tree.allocSize[Int(node)] == st.blocks * 512)
        #expect(tree.logicalSize[Int(node)] == 8_000_000)
        #expect(tree.allocSize[Int(node)] < tree.logicalSize[Int(node)])
        #expect(result.scannedTotalBytes == st.blocks * 512)
    }

    @Test func chmodZeroDirIsBlockedUnlessRoot() async throws {
        let root = try makeTempDir("blocked")
        defer {
            _ = chmod(child(root, "secret"), 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(atPath: child(root, "secret"))
        try FileManager.default.createDirectory(atPath: child(root, "open"))
        try writeFile(child(root, "open", "readme.txt"), 5_000)
        #expect(chmod(child(root, "secret"), 0o000) == 0)

        let result = try await runScan(root)
        let tree = result.tree
        let secret = try #require(tree.node(atPath: child(root, "secret")))
        if getuid() == 0 {
            // Running as root: the directory is readable, not blocked.
            #expect(tree.kind[Int(secret)] == .directory)
        } else {
            #expect(tree.kind[Int(secret)] == .blocked)
            #expect(result.blocked.count == 1)
            #expect(result.blocked.contains(secret))
            #expect(tree.path(secret) == child(root, "secret"))
            let readmeAlloc = try allocOf(child(root, "open", "readme.txt"))
            #expect(result.scannedTotalBytes == readmeAlloc)
        }
    }

    @Test func smallFileGroupingSkipsArchivesAndLargeFiles() async throws {
        let root = try makeTempDir("grouping")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "data"))
        try writeFile(child(root, "data", "s1.txt"), 1_000)
        try writeFile(child(root, "data", "s2.txt"), 2_000)
        try writeFile(child(root, "data", "s3.txt"), 3_000)
        try writeFile(child(root, "data", "tiny.zip"), 1_000)
        try writeFile(child(root, "data", "big.bin"), 200_000)

        let result = try await runScan(root)
        let tree = result.tree
        let data = try #require(tree.node(atPath: child(root, "data")))

        let group = try #require(tree.child(of: data, named: "(3 small files)"))
        #expect(tree.kind[Int(group)] == .smallFilesGroup)
        #expect(tree.fileCount[Int(group)] == 3)
        let expectedGroup = try allocOf(child(root, "data", "s1.txt"))
            + try allocOf(child(root, "data", "s2.txt"))
            + try allocOf(child(root, "data", "s3.txt"))
        #expect(tree.allocSize[Int(group)] == expectedGroup)

        // .zip files are never grouped, whatever their size.
        let zip = try #require(tree.child(of: data, named: "tiny.zip"))
        #expect(tree.kind[Int(zip)] == .file)
        #expect(tree.allocSize[Int(zip)] == try allocOf(child(root, "data", "tiny.zip")))

        let big = try #require(tree.child(of: data, named: "big.bin"))
        #expect(tree.kind[Int(big)] == .file)
        #expect(tree.fileCount[0] == 5)
    }

    @Test func bundlesDetectedAndScannedInto() async throws {
        let root = try makeTempDir("bundles")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "MyApp.app", "Contents", "MacOS"))
        try FileManager.default.createDirectory(atPath: child(root, "Photos.photoslibrary"))
        try writeFile(child(root, "MyApp.app", "Contents", "MacOS", "binary"), 100_000)
        try writeFile(child(root, "Photos.photoslibrary", "database.db"), 4_000)

        let result = try await runScan(root)
        let tree = result.tree
        let app = try #require(tree.node(atPath: child(root, "MyApp.app")))
        #expect(tree.kind[Int(app)] == .bundle)
        let binary = try #require(tree.node(atPath: child(root, "MyApp.app", "Contents", "MacOS", "binary")))
        #expect(tree.kind[Int(binary)] == .file)
        #expect(tree.allocSize[Int(app)] == try expectedTotals(child(root, "MyApp.app")).alloc)

        let photos = try #require(tree.node(atPath: child(root, "Photos.photoslibrary")))
        #expect(tree.kind[Int(photos)] == .bundle)
        #expect(result.scannedTotalBytes == try expectedTotals(root.path).alloc)
    }

    @Test func deepChain200Finalizes() async throws {
        let root = try makeTempDir("deep")
        defer { try? FileManager.default.removeItem(at: root) }
        var dir = root.path
        for level in 0..<200 {
            let next = dir + "/d\(level)"
            try FileManager.default.createDirectory(atPath: next)
            dir = next
        }
        try writeFile(dir + "/bottom.bin", 10_000)
        let bottomAlloc = try allocOf(dir + "/bottom.bin")

        let result = try await runScan(root, threads: 8)
        let tree = result.tree
        let bottom = try #require(tree.node(atPath: dir + "/bottom.bin"))
        #expect(tree.depth(bottom) == 201) // root + 200 nested directories
        #expect(result.scannedTotalBytes == bottomAlloc)
        #expect(tree.fileCount[0] == 1)
        #expect(tree.allocSize[0] == bottomAlloc)
    }

    @Test func wideDir10kEntries() async throws {
        let root = try makeTempDir("wide")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "wide"))
        var smallSum: UInt64 = 0
        for index in 0..<10_000 {
            let path = child(root, "wide", String(format: "f%05d.dat", index))
            try writeFile(path, 512)
            smallSum += try allocOf(path)
        }
        try writeFile(child(root, "wide", "big1.bin"), 100_000)
        try writeFile(child(root, "wide", "big2.bin"), 100_000)
        try writeFile(child(root, "wide", "big3.bin"), 100_000)

        let result = try await runScan(root, threads: 6)
        let tree = result.tree
        let wide = try #require(tree.node(atPath: child(root, "wide")))
        let group = try #require(tree.child(of: wide, named: "(10000 small files)"))
        #expect(tree.fileCount[Int(group)] == 10_000)
        #expect(tree.allocSize[Int(group)] == smallSum)
        #expect(result.scannedTotalBytes == smallSum
            + try allocOf(child(root, "wide", "big1.bin"))
            + try allocOf(child(root, "wide", "big2.bin"))
            + try allocOf(child(root, "wide", "big3.bin")))
        #expect(result.stats.filesSeen == 10_003)
    }

    @Test func cancellationYieldsCancellationError() async throws {
        let root = try makeTempDir("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "d"))
        try writeFile(child(root, "d", "file.bin"), 100_000)

        let scanner = ParallelScanner(
            options: ScanOptions(
                root: root.path, threadCount: 4, reserveCapacity: 4096,
                measureVolumeInfo: false))
        let task = Task { try await scanner.scan() }
        scanner.cancel()
        do {
            _ = try await task.value
            Issue.record("expected the scan to be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func secondScanThrowsAlreadyScanned() async throws {
        let root = try makeTempDir("oneshot")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(child(root, "file.bin"), 1_000)

        let scanner = ParallelScanner(
            options: ScanOptions(
                root: root.path, threadCount: 2, reserveCapacity: 4096,
                measureVolumeInfo: false))
        _ = try await scanner.scan()
        do {
            _ = try await scanner.scan()
            Issue.record("second scan() must throw")
        } catch {
            if case ScanError.alreadyScanned = error {} else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func snapshotTreePrunesByDepthAndFraction() async throws {
        let root = try makeTempDir("snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: child(root, "a", "b"))
        try writeFile(child(root, "a", "b", "leaf.bin"), 50_000)
        try writeFile(child(root, "top.bin"), 50_000)

        let scanner = ParallelScanner(
            options: ScanOptions(
                root: root.path, threadCount: 2, reserveCapacity: 4096,
                measureVolumeInfo: false))
        let result = try await scanner.scan()

        let wide = scanner.snapshotTree(maxDepth: 1, minFraction: 0)
        #expect(wide.node(atPath: child(root, "a")) != nil)
        #expect(wide.node(atPath: child(root, "a", "b")) == nil) // deeper than maxDepth
        #expect(wide.allocSize[0] == result.scannedTotalBytes)

        // With a fraction above every child, only the root survives pruning.
        let pruned = scanner.snapshotTree(maxDepth: 4, minFraction: 0.999)
        #expect(pruned.count == 1)
        #expect(pruned.allocSize[0] == result.scannedTotalBytes)
    }
}

@Suite("VolumeInfoReader parsing")
struct SnapshotParsingTests {
    @Test func parseSnapshotListExtractsNamesAndDates() {
        let output = """
        Snapshots for / :
        com.apple.TimeMachine.2026-01-02-030405.local
        com.apple.TimeMachine.2026-01-03-111213.local
        """
        let snapshots = VolumeInfoReader.parseSnapshotList(output)
        #expect(snapshots.count == 2)
        #expect(snapshots[0].name == "com.apple.TimeMachine.2026-01-02-030405.local")
        #expect(snapshots[0].date != nil)
        #expect(snapshots[1].date != nil)
        #expect(snapshots[0].bytes == nil)
    }

    @Test func parseSnapshotListIgnoresGarbage() {
        #expect(VolumeInfoReader.parseSnapshotList("no snapshots").isEmpty)
        #expect(VolumeInfoReader.parseSnapshotList("").isEmpty)
        let snapshots = VolumeInfoReader.parseSnapshotList(
            "com.apple.TimeMachine.not-a-date.local\ncom.apple.TimeMachine.2026-13-99-999999.local")
        #expect(snapshots.count == 2)
        #expect(snapshots[0].date == nil)
    }
}
