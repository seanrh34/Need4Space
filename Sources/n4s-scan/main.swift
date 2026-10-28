import Foundation
import ScannerKit

// n4s-scan: M1 scanner CLI / benchmark (docs/PLAN.md).
// Usage: n4s-scan [path] [--top N] [--threads N] [--json]
// Prints elapsed time, node/dir/file counts, allocated bytes, hard-link dedupe,
// skipped mount points, blocked folders, peak RSS and the top N folders
// (directories at depth 1...4 by allocated size). Progress lines go to stderr.

struct TopFolderReport: Codable {
    var path: String
    var bytes: UInt64
    var files: UInt32
}

var topFolderPcts: [Double] = []

struct VolumeReport: Codable {
    var mountPath: String
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
    var purgeableBytes: UInt64
    var snapshots: Int
}

struct ScanReport: Codable {
    var root: String
    var elapsedSeconds: Double
    var nodes: Int
    var directories: Int
    var files: Int
    var bytesAllocated: UInt64
    var bytesLogical: UInt64
    var hardLinksDeduplicated: Int
    var mountPointsSkipped: Int
    var skippedMountPaths: [String]
    var blockedCount: Int
    var blockedPaths: [String]
    var incompleteCount: Int
    var incompletePaths: [String]
    var peakResidentBytes: UInt64
    var topFolders: [TopFolderReport]
    var volume: VolumeReport?
}

func stderrWrite(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

func usage() -> Never {
    stderrWrite("usage: n4s-scan [path] [--top N] [--threads N] [--json]\n")
    exit(2)
}

func humanBytes(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
}

var path = "/"
var top = 20
var threads: Int?
var json = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--top":
        i += 1
        guard i < args.count, let t = Int(args[i]), t >= 0 else { usage() }
        top = t
    case "--threads":
        i += 1
        guard i < args.count, let t = Int(args[i]), t > 0 else { usage() }
        threads = t
    case "--json":
        json = true
    case "-h", "--help":
        usage()
    default:
        if args[i].hasPrefix("-") { usage() }
        path = args[i]
    }
    i += 1
}

let scanner = ParallelScanner(options: ScanOptions(root: path, threadCount: threads))

// Progress consumer: throttle the 10 Hz stream to ~1 line per second on stderr.
let progressTask = Task {
    var lastSecond = -1
    for await p in scanner.progress {
        let second = Int(p.elapsedSeconds)
        guard second != lastSecond else { continue }
        lastSecond = second
        let seconds = String(format: "%6.1f", p.elapsedSeconds)
        let line = "\r\(seconds)s  \(p.directoriesScanned) dirs  \(p.filesFound) files  "
            + humanBytes(p.bytesFound)
        stderrWrite(line)
    }
    stderrWrite("\n")
}

var result: ScanResult
do {
    result = try await scanner.scan()
} catch {
    progressTask.cancel()
    if json {
        let reason = String(describing: error).replacingOccurrences(of: "\"", with: "'")
        print("{\"error\":\"\(reason)\"}")
    } else {
        stderrWrite("n4s-scan: scan failed: \(error)\n")
    }
    exit(1)
}
progressTask.cancel()

// Aggregate report values.
let tree = result.tree
var directories = 0
var topFolders: [TopFolderReport] = []
if tree.count > 0 {
    var candidates: [(id: Int, path: String, bytes: UInt64, files: UInt32, depth: Int)] = []
    for id in 0..<tree.count {
        let kind = tree.kind[id]
        if kind == .directory || kind == .bundle {
            directories += 1
            let depth = tree.depth(NodeID(id))
            if depth >= 1, depth <= 4 {
                candidates.append(
                    (id, tree.path(NodeID(id)), tree.allocSize[id], tree.fileCount[id], depth))
            }
        }
    }
    // Review round 2 fix 8: keep the parent, skip the child when the child holds >= 95%
    // of its parent's bytes (collapses X.app -> X.app/Contents chains). Only applied
    // from depth 2 on so the root's direct children always stay visible.
    let scannedTotal = max(result.scannedTotalBytes, 1)
    let filtered = candidates.filter { row in
        guard row.depth >= 2 else { return true }
        let parentID = Int(tree.parent[row.id])
        guard parentID >= 0 else { return true }
        let parentAlloc = tree.allocSize[parentID]
        return Double(row.bytes) < 0.95 * Double(max(parentAlloc, 1))
    }
    filtered.sort { $0.bytes > $1.bytes }
    topFolders = filtered.prefix(top).map {
        TopFolderReport(path: $0.path, bytes: $0.bytes, files: $0.files)
    }
    topFolderPcts = filtered.prefix(top).map { Double($0.bytes) * 100.0 / Double(scannedTotal) }
}

let volume: VolumeReport? = result.volume.map {
    VolumeReport(
        mountPath: $0.mountPath, totalBytes: $0.totalBytes, usedBytes: $0.usedBytes,
        freeBytes: $0.freeBytes, purgeableBytes: $0.purgeableBytes, snapshots: $0.snapshots.count)
}

let report = ScanReport(
    root: path,
    elapsedSeconds: result.stats.elapsedSeconds,
    nodes: tree.count,
    directories: directories,
    files: result.stats.filesSeen,
    bytesAllocated: result.scannedTotalBytes,
    bytesLogical: tree.count > 0 ? tree.logicalSize[0] : 0,
    hardLinksDeduplicated: result.stats.hardLinksDeduplicated,
    mountPointsSkipped: result.stats.mountPointsSkipped,
    skippedMountPaths: result.stats.skippedMountPaths,
    blockedCount: result.blocked.count,
    blockedPaths: result.blocked.prefix(50).map { tree.path($0) },
    incompleteCount: result.incomplete.count,
    incompletePaths: result.incomplete.prefix(20).map { tree.path($0.nodeID) },
    peakResidentBytes: result.stats.peakResidentBytes,
    topFolders: topFolders,
    volume: volume)

if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    print(String(decoding: data, as: UTF8.self))
} else {
    print("n4s-scan \(path) — \(String(format: "%.2f", report.elapsedSeconds)) s")
    print(
        "nodes \(report.nodes)  dirs \(report.directories)  files \(report.files)" +
        "  allocated \(humanBytes(report.bytesAllocated))  logical \(humanBytes(report.bytesLogical))")
    print(
        "hard links deduped \(report.hardLinksDeduplicated)" +
        "  mount points skipped \(report.mountPointsSkipped)" +
        "  blocked \(report.blockedCount)" +
        "  incomplete \(report.incompleteCount)" +
        "  peak RSS \(humanBytes(report.peakResidentBytes))")
    if let v = volume {
        print(
            "volume \(v.mountPath): total \(humanBytes(v.totalBytes)), used \(humanBytes(v.usedBytes))," +
            " free \(humanBytes(v.freeBytes)), purgeable \(humanBytes(v.purgeableBytes))," +
            " snapshots \(v.snapshots)")
    }
    if !report.blockedPaths.isEmpty {
        print("blocked paths (first \(report.blockedPaths.count)):")
        for p in report.blockedPaths {
            print("  \(p)")
        }
    }
    if !report.incompletePaths.isEmpty {
        print("incomplete directories (first \(report.incompletePaths.count)):")
        for p in report.incompletePaths {
            print("  \(p)")
        }
    }
    if !topFolders.isEmpty {
        print("top \(topFolders.count) folders (depth 1...4, allocated size, % of scanned total):")
        for (rank, folder) in topFolders.enumerated() {
            let pct = rank < topFolderPcts.count
                ? String(format: "%.1f%%", topFolderPcts[rank]) : "n/a"
            print("  \(rank + 1). \(folder.path) — \(humanBytes(folder.bytes)) (\(pct), \(folder.files) files)")
        }
    }
}
