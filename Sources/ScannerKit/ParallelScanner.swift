#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Synchronization

/// Options for a `ParallelScanner` run.
public struct ScanOptions: Sendable {
    /// Absolute path of the directory to scan (e.g. "/" or "/Volumes/External").
    public var root: String
    /// Worker threads; nil = 2 x activeProcessorCount (plan: bounded work-stealing pool).
    public var threadCount: Int?
    /// Files with allocated size below this are collapsed into one "(N small files)" node.
    public var smallFileThreshold: UInt64
    /// Absolute paths never descended into. Only applied when `root == "/"` (plan: skip list
    /// for / scans, avoiding double counting of firmlinked/mounted system volumes).
    public var skipPaths: [String]
    /// If true, entries on other devices are followed; otherwise they become 0-size `.other`
    /// leaves and are recorded as skipped mount points (plan revision 1).
    public var crossMounts: Bool
    /// Pre-reserved node capacity to avoid copy-on-grow spikes (plan revision 12).
    public var reserveCapacity: Int
    /// Read VolumeInfo (capacity + snapshots) at the end of the scan.
    public var measureVolumeInfo: Bool

    public static let defaultSkipPaths = ["/Volumes", "/dev", "/.vol", "/System/Volumes"]

    public init(
        root: String = "/",
        threadCount: Int? = nil,
        smallFileThreshold: UInt64 = 64 * 1024,
        skipPaths: [String] = ScanOptions.defaultSkipPaths,
        crossMounts: Bool = false,
        reserveCapacity: Int = 1 << 20,
        measureVolumeInfo: Bool = true
    ) {
        self.root = root
        self.threadCount = threadCount
        self.smallFileThreshold = smallFileThreshold
        self.skipPaths = skipPaths
        self.crossMounts = crossMounts
        self.reserveCapacity = reserveCapacity
        self.measureVolumeInfo = measureVolumeInfo
    }
}

public enum ScanError: Error, Sendable {
    /// `scan()` is one-shot (plan revision 6); a second call throws.
    case alreadyScanned
    /// The scan root could not be opened.
    case rootUnreadable(errno: Int32)
}

/// A pending directory-listing job. Carries the child's own fd (opened by the parent's
/// worker via openat, so no path strings are needed to open things) plus its absolute path
/// for bookkeeping (skip list, mount records) — one string per directory, never per file.
struct DirJob: Sendable {
    let nodeID: NodeID
    let fd: Int32
    let path: String
}

/// A regular file seen with linkCount > 1. Bytes are resolved after the walk (revision 8):
/// the owner is the record with the lexicographically smallest path.
struct HardLinkRecord: Sendable {
    let devid: Int32
    let fileID: UInt64
    let nodeID: NodeID
    let alloc: UInt64
    let logical: UInt64
    let path: String
}

struct DeviceFileKey: Hashable, Sendable {
    let devid: Int32
    let fileID: UInt64
}

/// A small file (< smallFileThreshold) waiting to be folded into its directory's
/// smallFilesGroup node at the end of that directory's listing.
struct SmallFileRecord: Sendable {
    let name: [UInt8]
    let alloc: UInt64
    let logical: UInt64
    let modTime: Int64
    let devid: Int32
    let fileID: UInt64
    let linkCount: UInt32
}

/// Mutable scanner state guarded by the builder Mutex (plan revision 6: mutable state lives
/// only in Mutex/Atomic; the tree is never shared unlocked).
struct BuilderState: Sendable {
    var tree: ScanTree
    /// Per-node side arrays (plan revision 3 + 12), discarded with the builder.
    var listingDone: [Bool] = []
    var pendingChildDirs: [Int32] = []
    var finalized: [Bool] = []
    var blockedIDs: [NodeID] = []
    var hardLinks: [HardLinkRecord] = []
    var deduplicatedLinks: Int = 0
    var mountSkipCount: Int = 0
    var skippedMountPaths: [String] = []
    var failedEntries: Int = 0
    /// Directories created but not yet finalized (termination signal + progress).
    var pendingDirs: Int = 0

    init(rootPath: String, reserveCapacity: Int) {
        self.tree = ScanTree(rootPath: rootPath, reserveCapacity: reserveCapacity)
        let root = tree.addNode(name: "", kind: .directory, parent: ScanTree.none)
        _ = root
        listingDone.append(false)
        pendingChildDirs.append(0)
        finalized.append(false)
        pendingDirs = 1 // root waits for its listing
    }

    /// Appends a node and keeps the side arrays in sync.
    mutating func appendNode(
        nameBytes: some Collection<UInt8>, kind: NodeKind, parent: NodeID,
        allocSize: UInt64 = 0, logicalSize: UInt64 = 0, fileCount: UInt32 = 0,
        modTime: Int64 = 0, accessTime: Int64 = 0
    ) -> NodeID {
        let id = tree.addNode(
            nameBytes: nameBytes, kind: kind, parent: parent,
            allocSize: allocSize, logicalSize: logicalSize, fileCount: fileCount,
            modTime: modTime, accessTime: accessTime)
        listingDone.append(false)
        pendingChildDirs.append(0)
        finalized.append(false)
        return id
    }
}

/// All scanner mutable state. Only ever accessed through `ParallelScanner.core`
/// (`Mutex`) or the Atomic counters on the scanner itself.
struct ScannerCore: Sendable {
    var builder: BuilderState
    /// Per-worker deques, shared under the one Mutex. Honest naming (plan revision 6): this
    /// is a coarse single-lock work-stealing pool (local LIFO pop, FIFO steal from others);
    /// per-deque locks are a future optimization if benchmarks show contention.
    var queues: [[DirJob]] = []
    /// Jobs popped but not finished.
    var activeJobs = 0
    var done = false
    /// Guards single delivery of the scan() continuation (revision 6: exactly once).
    var resultDelivered = false
    var continuation: CheckedContinuation<ScanResult, Error>?
    var streamContinuation: AsyncStream<ScanProgress>.Continuation?
    var progressTask: Task<Void, Never>?
    /// Throttled snapshot cache (revision 4: at most 1 Hz).
    var snapshotCache: ScanTree?
    var snapshotTime: ContinuousClock.Instant?
    /// Set when scan() starts; used for the elapsed statistic.
    var startedAt: ContinuousClock.Instant?

    init(builder: BuilderState, workerCount: Int, streamContinuation: AsyncStream<ScanProgress>.Continuation) {
        self.builder = builder
        self.queues = Array(repeating: [], count: workerCount)
        self.streamContinuation = streamContinuation
    }
}

// MARK: - ParallelScanner

/// Bounded work-stealing scanner walking directories with getattrlistbatch (SPEC §4).
///
/// - One-shot: `scan()` throws `ScanError.alreadyScanned` on a second call.
/// - `scan()` runs on `2 * activeProcessorCount` `Thread` workers (never the cooperative
///   pool — the syscalls block) and suspends until completion/cancellation.
/// - Workers poll the shared queue Mutex at short intervals when idle; the Synchronization
///   module has no condition variable, and the poll cost is a few locks per 200 µs per
///   idle worker — negligible next to the syscall-bound work.
/// - `progress` is a single-consumer 10 Hz AsyncStream; `snapshotTree(maxDepth:minFraction:)`
///   hands out pruned tree copies at most once per second.
public final class ParallelScanner: Sendable {
    public let options: ScanOptions

    private let core: Mutex<ScannerCore>
    private let allowedDevids: Set<Int32>
    private let isRootScan: Bool
    private let workerCount: Int
    private let startedFlag = Atomic<Bool>(false)
    private let cancelFlag = Atomic<Bool>(false)
    private let varVMRequested = Atomic<Bool>(false)
    private let bytesFound = Atomic<UInt64>(0)
    private let filesFound = Atomic<UInt64>(0)
    private let dirsScanned = Atomic<UInt64>(0)
    private let progressStream: AsyncStream<ScanProgress>
    private let progressContinuation: AsyncStream<ScanProgress>.Continuation

    public init(options: ScanOptions) {
        self.options = options
        self.isRootScan = options.root == "/"
        self.workerCount = max(1, options.threadCount ?? 2 * ProcessInfo.processInfo.activeProcessorCount)

        var devids = Set<Int32>()
        if let rootDev = Self.deviceID(ofPath: options.root) {
            devids.insert(rootDev)
        }
        if isRootScan, let dataDev = Self.deviceID(ofPath: "/System/Volumes/Data") {
            devids.insert(dataDev)
        }
        self.allowedDevids = devids

        let builder = BuilderState(rootPath: options.root, reserveCapacity: options.reserveCapacity)
        var continuation: AsyncStream<ScanProgress>.Continuation?
        // The build closure runs synchronously during init (AsyncStream documentation).
        let stream = AsyncStream(ScanProgress.self, bufferingPolicy: .bufferingNewest) {
            continuation = $0
        }
        self.progressStream = stream
        self.progressContinuation = continuation!
        self.core = Mutex(
            ScannerCore(
                builder: builder, workerCount: workerCount,
                streamContinuation: continuation!))
    }

    /// Convenience: default options for a root path.
    public convenience init(root: String) {
        self.init(options: ScanOptions(root: root))
    }

    /// Single-consumer progress stream at 10 Hz; the stream finishes when the scan
    /// completes, errors or is cancelled (plan revision 6).
    public var progress: AsyncStream<ScanProgress> { progressStream }

    // MARK: Device helpers

    /// dev_t of a path. Used O(1) for the scan root and the two allowed firmlink targets
    /// only — the scanner itself never stats per-file (SPEC §4).
    private static func deviceID(ofPath path: String) -> Int32? {
        #if canImport(Darwin)
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int32(truncatingIfNeeded: st.st_dev)
        #else
        return nil
        #endif
    }

    /// lexicographic ASCII-suffix check without allocating a String (e.g. "app" for .app).
    static func hasExtension(_ name: [UInt8], _ ext: String) -> Bool {
        let extBytes = Array(ext.utf8)
        let n = name.count, m = extBytes.count
        guard n > m + 1, name[n - m - 1] == UInt8(ascii: ".") else { return false }
        for (i, b) in extBytes.enumerated() {
            let c = name[n - m + i]
            if c != b, c != (b & 0x20) { return false } // ASCII letters only
        }
        return true
    }

    static let bundleExtensions = ["app", "photoslibrary", "xcarchive", "bundle", "framework", "plugin", "appex"]
    /// Small files with these extensions are never grouped (plan revision 9).
    static let neverGroupExtensions = ["dmg", "pkg", "zip", "xip", "iso"]

    static func childPath(parent: String, name: [UInt8]) -> String {
        if parent == "/" {
            return "/" + String(decoding: name, as: UTF8.self)
        }
        return parent + "/" + String(decoding: name, as: UTF8.self)
    }
}

// MARK: - Scan lifecycle

extension ParallelScanner {
    /// Runs the scan on its own worker threads and suspends until it completes.
    /// One-shot; cancellation yields `CancellationError`.
    public func scan() async throws -> ScanResult {
        guard startedFlag.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { throw ScanError.alreadyScanned }

        #if canImport(Darwin)
        let fd = open(options.root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.rootUnreadable(errno: errno) }
        let rootFD = Int32(fd)
        #else
        throw ScanError.rootUnreadable(errno: 0)
        #endif

        let start = ContinuousClock.now

        // Enqueue the root job; workers start below, after the continuation is stored.
        core.withLock { core in
            core.queues[0].append(DirJob(nodeID: 0, fd: rootFD, path: options.root))
            core.startedAt = start
        }

        return try await withCheckedThrowingContinuation { [self] cont in
            core.withLock { $0.continuation = cont }

            // Progress publisher at 10 Hz (SPEC §4). Stored before workers start so the
            // completion path can always cancel it.
            let progressTask = Task(priority: .utility) { [self] in
                await self.runProgressLoop(start: start)
            }
            core.withLock { $0.progressTask = progressTask }

            for index in 0..<workerCount {
                let thread = Thread { [self] in
                    self.workerLoop(index: index)
                }
                thread.name = "ScannerKit.worker-\(index)"
                thread.start()
            }
        }
    }

    /// Requests cancellation. Workers drain their current job and exit; `scan()` throws
    /// `CancellationError`.
    public func cancel() {
        cancelFlag.store(true, ordering: .releasing)
    }

    /// Live pruned copy of the tree for the UI sunburst (plan revision 4): nodes down to
    /// `maxDepth` whose subtree alloc size is at least `minFraction` of the root total.
    /// Throttled to at most one build per second.
    public func snapshotTree(maxDepth: Int = 4, minFraction: Double = 0.001) -> ScanTree {
        core.withLock { core -> ScanTree in
            let now = ContinuousClock.now
            if let cached = core.snapshotCache, let last = core.snapshotTime,
                last.duration(to: now) < .seconds(1)
            {
                return cached
            }
            let snap = Self.prunedCopy(
                core.builder.tree, maxDepth: maxDepth, minFraction: minFraction)
            core.snapshotCache = snap
            core.snapshotTime = now
            return snap
        }
    }

    // MARK: Progress

    private func runProgressLoop(start: ContinuousClock.Instant) async {
        while !Task.isCancelled {
            _ = progressContinuation.yield(makeProgressSnapshot(start: start))
            do {
                try await Task.sleep(for: .milliseconds(100)) // 10 Hz
            } catch {
                break
            }
        }
    }

    private func makeProgressSnapshot(start: ContinuousClock.Instant) -> ScanProgress {
        let duration = start.duration(to: ContinuousClock.now)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        var pending = 0
        var top: [ScanProgressItem] = []
        core.withLock { core in
            pending = max(0, core.builder.pendingDirs)
            let tree = core.builder.tree
            if tree.count > 0 {
                var items: [ScanProgressItem] = []
                var child = tree.firstChild[0]
                while child >= 0 {
                    let k = tree.kind[Int(child)]
                    if k == .directory || k == .bundle {
                        items.append(
                            ScanProgressItem(
                                name: tree.name(child), nodeID: child,
                                bytes: tree.allocSize[Int(child)]))
                    }
                    child = tree.nextSibling[Int(child)]
                }
                items.sort { $0.bytes > $1.bytes }
                top = Array(items.prefix(5))
            }
        }
        return ScanProgress(
            elapsedSeconds: seconds,
            bytesFound: bytesFound.load(ordering: .relaxed),
            filesFound: Int(filesFound.load(ordering: .relaxed)),
            directoriesScanned: Int(dirsScanned.load(ordering: .relaxed)),
            directoriesPending: pending,
            topItems: top)
    }

    // MARK: Completion / cancellation delivery (exactly once)

    private struct DeliveryPayload: Sendable {
        var continuation: CheckedContinuation<ScanResult, Error>?
        var stream: AsyncStream<ScanProgress>.Continuation
        var progressTask: Task<Void, Never>?
        var result: ScanResult?
    }

    /// Must be called with the core lock held. Claims the single delivery right and
    /// extracts everything needed to finish the scan outside the lock.
    private func completeScanLocked(
        _ core: inout ScannerCore, cancelled: Bool
    ) -> DeliveryPayload? {
        guard !core.resultDelivered, let continuation = core.continuation else { return nil }
        core.resultDelivered = true
        core.done = true
        core.continuation = nil
        let stream = core.streamContinuation
        core.streamContinuation = nil
        let progressTask = core.progressTask
        core.progressTask = nil
        if cancelled {
            // Workers exit without draining queued jobs; close their fds.
            for queue in core.queues {
                for job in queue {
                    #if canImport(Darwin)
                    _ = close(job.fd)
                    #endif
                }
            }
            core.queues = Array(repeating: [], count: core.queues.count)
            return DeliveryPayload(
                continuation: continuation, stream: stream, progressTask: progressTask,
                result: nil)
        }
        let result = buildResultLocked(&core)
        return DeliveryPayload(
            continuation: continuation, stream: stream, progressTask: progressTask,
            result: result)
    }

    private func deliver(_ payload: DeliveryPayload) {
        payload.progressTask?.cancel()
        payload.stream.finish()
        if let result = payload.result {
            payload.continuation?.resume(returning: result)
        } else {
            payload.continuation?.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Worker loop

extension ParallelScanner {
    private enum WorkerAction: Sendable {
        case run(DirJob)
        case wait
        case exit(DeliveryPayload?)
    }

    private func workerLoop(index: Int) {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: DirectoryReader.defaultBufferBytes, alignment: 64)
        defer { buffer.deallocate() }

        while true {
            switch nextAction(index: index) {
            case .run(let job):
                process(job, workerIndex: index, buffer: buffer)
            case .wait:
                // Idle: the Synchronization module has no condition variable, so idle
                // workers poll briefly (documented class comment).
                Thread.sleep(forTimeInterval: 0.0002)
            case .exit(let payload):
                if let payload { deliver(payload) }
                return
            }
        }
    }

    /// Pops local work (LIFO) or steals from another deque (FIFO), under the one lock.
    private func nextAction(index: Int) -> WorkerAction {
        core.withLock { core -> WorkerAction in
            if core.done { return .exit(nil) }
            if cancelFlag.load(ordering: .relaxed) {
                return .exit(completeScanLocked(&core, cancelled: true))
            }
            if let job = core.queues[index].popLast() {
                core.activeJobs += 1
                return .run(job)
            }
            let n = core.queues.count
            var victim = (index + 1) % n
            for _ in 1..<n {
                if !core.queues[victim].isEmpty {
                    let job = core.queues[victim].removeFirst()
                    core.activeJobs += 1
                    return .run(job)
                }
                victim = (victim + 1) % n
            }
            // No work anywhere: normal completion iff nothing pending and nothing active.
            if core.builder.pendingDirs == 0, core.activeJobs == 0 {
                return .exit(completeScanLocked(&core, cancelled: false))
            }
            return .wait
        }
    }

    // MARK: Processing one directory

    private func process(_ job: DirJob, workerIndex: Int, buffer: UnsafeMutableRawPointer) {
        defer {
            #if canImport(Darwin)
            _ = close(job.fd)
            #endif
        }

        var smalls: [SmallFileRecord] = []

        listing: while true {
            if cancelFlag.load(ordering: .relaxed) { break }
            let n = DirectoryReader.readEntries(
                fd: job.fd, buffer: buffer, bufferSize: DirectoryReader.defaultBufferBytes)
            if n < 0 {
                handleDirErrorLocked(job, errno: errno)
                break
            }
            if n == 0 { break }
            let entries = DirectoryReader.parseAttrBuffer(
                UnsafeRawBufferPointer(start: buffer, count: DirectoryReader.defaultBufferBytes),
                count: n)
            if entries.isEmpty { break } // malformed batch; next readEntries returns fresh data

            // Phase 2 (no lock): open child directories with openat.
            var childFDs: [Int32] = []
            var childErrnos: [Int32] = []
            var childPaths: [String?] = []
            childFDs.reserveCapacity(entries.count)
            for entry in entries {
                guard entry.objType == Attr.ObjType.vdir, let name = entry.name else {
                    childFDs.append(-1)
                    childErrnos.append(0)
                    childPaths.append(nil)
                    continue
                }
                let path = Self.childPath(parent: job.path, name: name)
                if isRootScan {
                    if options.skipPaths.contains(path) || path == "/private/var/vm" {
                        if path == "/private/var/vm" {
                            varVMRequested.store(true, ordering: .relaxed)
                        }
                        childFDs.append(-1)
                        childErrnos.append(-1) // marker: skip entirely
                        childPaths.append(path)
                        continue
                    }
                }
                if !options.crossMounts, let dev = entry.devid, !allowedDevids.contains(dev) {
                    // Mount boundary: 0-size leaf, never descended (plan revision 1).
                    childFDs.append(-1)
                    childErrnos.append(-2) // marker: mount skip
                    childPaths.append(path)
                    continue
                }
                #if canImport(Darwin)
                var nameBytes = name
                nameBytes.append(0)
                let childFD = nameBytes.withUnsafeBufferPointer { bytes -> Int32 in
                    openat(job.fd, bytes.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                #else
                let childFD: Int32 = -1
                #endif
                if childFD >= 0 {
                    childFDs.append(childFD)
                    childErrnos.append(0)
                    childPaths.append(path)
                } else {
                    childFDs.append(-1)
                    childErrnos.append(errno)
                    childPaths.append(path)
                }
            }

            // Phase 3: one lock acquisition to append this batch's nodes and jobs.
            core.withLock { core in
                appendBatchLocked(
                    &core, job: job, entries: entries, childFDs: childFDs,
                    childErrnos: childErrnos, childPaths: childPaths,
                    workerIndex: workerIndex, smalls: &smalls)
            }
        }

        // Listing finished (or failed / cancelled): complete the directory.
        let payload = core.withLock { core -> DeliveryPayload? in
            core.builder.listingDone[Int(job.nodeID)] = true
            finalizeSmallGroupLocked(&core.builder, job: job, smalls: smalls)
            finalizeChainLocked(&core.builder, start: job.nodeID)
            core.activeJobs -= 1
            _ = dirsScanned.add(1, ordering: .relaxed)
            if !core.resultDelivered, core.builder.pendingDirs == 0, core.activeJobs == 0 {
                return completeScanLocked(&core, cancelled: cancelFlag.load(ordering: .relaxed))
            }
            return nil
        }
        if let payload { deliver(payload) }
    }

    /// The directory's getattrlistbulk failed at the top level: blocked for permission
    /// errors (recorded, revision plan "Blocked"), otherwise treated as vanished.
    private func handleDirErrorLocked(_ job: DirJob, errno: Int32) {
        core.withLock { core in
            let i = Int(job.nodeID)
            if errno == EPERM || errno == EACCES {
                core.builder.tree.kind[i] = .blocked
                core.builder.blockedIDs.append(job.nodeID)
            } else {
                core.builder.tree.kind[i] = .other
            }
        }
    }
}

// MARK: - Tree building (all with the core lock held)

extension ParallelScanner {
    /// Appends one parsed batch to the tree. Per-batch (not per-listing) so memory stays
    /// bounded and other workers can steal early. The directory is NOT completed here;
    /// its job's final step sets listingDone and runs the finalize chain.
    private func appendBatchLocked(
        _ core: inout ScannerCore, job: DirJob, entries: [RawEntry],
        childFDs: [Int32], childErrnos: [Int32], childPaths: [String?],
        workerIndex: Int, smalls: inout [SmallFileRecord]
    ) {
        for i in entries.indices {
            let entry = entries[i]

            // Per-entry error (getattrlistbulk(2)): blocked for permission errors,
            // otherwise counted and skipped.
            if let err = entry.error {
                if err == EPERM || err == EACCES, let name = entry.name {
                    let id = core.builder.appendNode(
                        nameBytes: name, kind: .blocked, parent: job.nodeID)
                    core.builder.blockedIDs.append(id)
                } else {
                    core.builder.failedEntries += 1
                }
                continue
            }
            guard let name = entry.name else {
                core.builder.failedEntries += 1
                continue
            }

            switch entry.objType {
            case Attr.ObjType.vdir:
                let marker = childErrnos[i]
                if marker == -1 {
                    continue // skip list or /private/var/vm: no node at all
                }
                if marker == -2 {
                    // Mount boundary: 0-size leaf, never descended; record the path.
                    core.builder.mountSkipCount += 1
                    if core.builder.skippedMountPaths.count < 1000, let p = childPaths[i] {
                        core.builder.skippedMountPaths.append(p)
                    }
                    _ = core.builder.appendNode(
                        nameBytes: name, kind: .other, parent: job.nodeID,
                        modTime: entry.modTime ?? 0, accessTime: entry.accessTime ?? 0)
                    continue
                }
                let isBundle = Self.bundleExtensions.contains { Self.hasExtension(name, $0) }
                if marker == EPERM || marker == EACCES {
                    // Blocked directory: counted in the completion protocol, then
                    // finalized immediately with size 0 (plan revision 3).
                    let id = core.builder.appendNode(
                        nameBytes: name, kind: .blocked, parent: job.nodeID,
                        modTime: entry.modTime ?? 0, accessTime: entry.accessTime ?? 0)
                    core.builder.blockedIDs.append(id)
                    core.builder.pendingDirs += 1
                    core.builder.pendingChildDirs[Int(job.nodeID)] += 1
                    finalizeChainLocked(&core.builder, start: id)
                } else if marker != 0 || childFDs[i] < 0 {
                    // Vanished mid-scan (ENOENT, ELOOP, ...): 0-size other leaf.
                    _ = core.builder.appendNode(
                        nameBytes: name, kind: .other, parent: job.nodeID,
                        modTime: entry.modTime ?? 0, accessTime: entry.accessTime ?? 0)
                } else {
                    let id = core.builder.appendNode(
                        nameBytes: name, kind: isBundle ? NodeKind.bundle : NodeKind.directory,
                        parent: job.nodeID, modTime: entry.modTime ?? 0,
                        accessTime: entry.accessTime ?? 0)
                    core.builder.pendingDirs += 1
                    core.builder.pendingChildDirs[Int(job.nodeID)] += 1
                    core.queues[workerIndex].append(
                        DirJob(nodeID: id, fd: childFDs[i], path: childPaths[i] ?? ""))
                }

            case Attr.ObjType.vlnk:
                // Symlink: leaf with its own (usually zero) alloc size; never followed.
                _ = core.builder.appendNode(
                    nameBytes: name, kind: .symlink, parent: job.nodeID,
                    allocSize: entry.allocSize ?? 0, logicalSize: entry.logicalSize ?? 0,
                    modTime: entry.modTime ?? 0, accessTime: entry.accessTime ?? 0)

            case Attr.ObjType.vreg:
                let alloc = entry.allocSize ?? entry.logicalSize ?? 0
                let logical = entry.logicalSize ?? 0
                let linkCount = entry.linkCount ?? 1
                let excluded = Self.neverGroupExtensions.contains { Self.hasExtension(name, $0) }
                if !excluded, alloc < options.smallFileThreshold {
                    smalls.append(
                        SmallFileRecord(
                            name: name, alloc: alloc, logical: logical,
                            modTime: entry.modTime ?? 0, devid: entry.devid ?? 0,
                            fileID: entry.fileID ?? 0, linkCount: linkCount))
                } else {
                    var nodeAlloc = alloc
                    var nodeLogical = logical
                    if linkCount > 1 { nodeAlloc = 0; nodeLogical = 0 }
                    let id = core.builder.appendNode(
                        nameBytes: name, kind: .file, parent: job.nodeID,
                        allocSize: nodeAlloc, logicalSize: nodeLogical, fileCount: 1,
                        modTime: entry.modTime ?? 0, accessTime: entry.accessTime ?? 0)
                    if linkCount > 1 {
                        core.builder.hardLinks.append(
                            HardLinkRecord(
                                devid: entry.devid ?? 0, fileID: entry.fileID ?? 0,
                                nodeID: id, alloc: alloc, logical: logical,
                                path: Self.childPath(parent: job.path, name: name)))
                    }
                }
                _ = filesFound.add(1, ordering: .relaxed)
                _ = bytesFound.add(alloc, ordering: .relaxed)

            default:
                // Sockets, FIFOs, devices: 0-size leaf.
                _ = core.builder.appendNode(
                    nameBytes: name, kind: .other, parent: job.nodeID,
                    modTime: entry.modTime ?? 0, accessTime: entry.accessTime ?? 0)
            }
        }
    }

    /// Folds the directory's collected small files into ONE smallFilesGroup node
    /// (SPEC §4, revision 9). Linked small files contribute 0 bytes here; their bytes
    /// are added after the walk if their record owns the (devid, fileid) group.
    private func finalizeSmallGroupLocked(
        _ b: inout BuilderState, job: DirJob, smalls: [SmallFileRecord]
    ) {
        guard !smalls.isEmpty else { return }
        var alloc: UInt64 = 0
        var logical: UInt64 = 0
        var modTime: Int64 = 0
        for s in smalls {
            if s.linkCount <= 1 {
                alloc &+= s.alloc
                logical &+= s.logical
            }
            if s.modTime > modTime { modTime = s.modTime }
        }
        let groupName = "(\(smalls.count) small files)"
        let id = b.appendNode(
            nameBytes: Array(groupName.utf8), kind: .smallFilesGroup, parent: job.nodeID,
            allocSize: alloc, logicalSize: logical, fileCount: UInt32(smalls.count),
            modTime: modTime)
        for s in smalls where s.linkCount > 1 {
            b.hardLinks.append(
                HardLinkRecord(
                    devid: s.devid, fileID: s.fileID, nodeID: id, alloc: s.alloc,
                    logical: s.logical, path: Self.childPath(parent: job.path, name: s.name)))
        }
    }

    /// Directory completion protocol (plan revision 3), iterative: finalize `start` if its
    /// listing is done and no child directories are pending; then decrement the parent's
    /// pending counter and re-check, walking up until a directory is not ready.
    private func finalizeChainLocked(_ b: inout BuilderState, start: NodeID) {
        var cur = start
        while cur >= 0 {
            let i = Int(cur)
            if b.finalized[i] { break }
            let k = b.tree.kind[i]
            guard k == .directory || k == .bundle || k == .blocked else { break }
            guard b.listingDone[i], b.pendingChildDirs[i] == 0 else { break }
            var alloc: UInt64 = 0
            var logical: UInt64 = 0
            var files: UInt32 = 0
            var child = b.tree.firstChild[i]
            while child >= 0 {
                alloc &+= b.tree.allocSize[Int(child)]
                logical &+= b.tree.logicalSize[Int(child)]
                files &+= b.tree.fileCount[Int(child)]
                child = b.tree.nextSibling[Int(child)]
            }
            b.tree.allocSize[i] = alloc
            b.tree.logicalSize[i] = logical
            b.tree.fileCount[i] = files
            b.finalized[i] = true
            b.pendingDirs -= 1
            let parent = b.tree.parent[i]
            if parent >= 0 {
                b.pendingChildDirs[Int(parent)] &-= 1
            }
            cur = parent
        }
    }

    private func addBytesLocked(
        _ core: inout ScannerCore, nodeID: NodeID, alloc: UInt64, logical: UInt64
    ) {
        var cur = nodeID
        while cur >= 0 {
            let i = Int(cur)
            core.builder.tree.allocSize[i] &+= alloc
            core.builder.tree.logicalSize[i] &+= logical
            cur = core.builder.tree.parent[i]
        }
    }

    // MARK: Post-walk passes

    /// Revision 8: per (devid, fileid) group, the owner is the record with the
    /// lexicographically smallest path; its bytes are added to it and its ancestors.
    private func resolveHardLinksLocked(_ core: inout ScannerCore) {
        var groups: [DeviceFileKey: [HardLinkRecord]] = [:]
        for record in core.builder.hardLinks {
            groups[DeviceFileKey(devid: record.devid, fileID: record.fileID), default: []]
                .append(record)
        }
        for records in groups.values {
            if records.count > 1 {
                core.builder.deduplicatedLinks += records.count - 1
            }
            guard let owner = records.min(by: { $0.path < $1.path }) else { continue }
            addBytesLocked(&core, nodeID: owner.nodeID, alloc: owner.alloc, logical: owner.logical)
        }
    }

    /// Revision 2: /private/var/vm (firmlinked to the VM volume) is measured recursively
    /// as an explicit exception and attached under /private/var with its completed total.
    private func attachVarVMLocked(_ core: inout ScannerCore) {
        guard varVMRequested.load(ordering: .relaxed) else { return }
        guard let totals = Self.scanDirectorySequentially(path: "/private/var/vm") else { return }
        guard core.builder.tree.count > 0,
            let privateVar = core.builder.tree.node(atPath: "/private/var")
        else { return }
        let vmID = core.builder.appendNode(
            nameBytes: Array("vm".utf8), kind: .directory, parent: privateVar,
            allocSize: totals.alloc, logicalSize: totals.logical,
            fileCount: UInt32(clamping: totals.files))
        addBytesLocked(&core, nodeID: vmID, alloc: totals.alloc, logical: totals.logical)
    }

    /// Sequential (single-threaded) recursive measurement used only for the small
    /// /private/var/vm exception. Ignores devid boundaries on purpose; deduplicates
    /// hard links within the subtree.
    static func scanDirectorySequentially(path: String) -> (alloc: UInt64, logical: UInt64, files: Int)? {
        #if canImport(Darwin)
        let rootFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        var stack: [Int32] = [rootFD]
        defer {
            while let fd = stack.popLast() {
                _ = close(fd)
            }
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: DirectoryReader.defaultBufferBytes, alignment: 64)
        defer { buffer.deallocate() }

        var seenLinked = Set<DeviceFileKey>()
        var alloc: UInt64 = 0
        var logical: UInt64 = 0
        var files = 0

        while let fd = stack.popLast() {
            while true {
                let n = DirectoryReader.readEntries(
                    fd: fd, buffer: buffer, bufferSize: DirectoryReader.defaultBufferBytes)
                if n <= 0 { break }
                let entries = DirectoryReader.parseAttrBuffer(
                    UnsafeRawBufferPointer(start: buffer, count: DirectoryReader.defaultBufferBytes),
                    count: n)
                for entry in entries {
                    if entry.error != nil { continue }
                    switch entry.objType {
                    case Attr.ObjType.vdir:
                        guard let name = entry.name else { continue }
                        var nameBytes = name
                        nameBytes.append(0)
                        let childFD = nameBytes.withUnsafeBufferPointer { bytes -> Int32 in
                            openat(fd, bytes.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        }
                        if childFD >= 0 { stack.append(childFD) }
                    case Attr.ObjType.vreg:
                        let entryAlloc = entry.allocSize ?? entry.logicalSize ?? 0
                        let entryLogical = entry.logicalSize ?? 0
                        if (entry.linkCount ?? 1) > 1, let devid = entry.devid, let fileID = entry.fileID {
                            let key = DeviceFileKey(devid: devid, fileID: fileID)
                            if seenLinked.contains(key) { continue }
                            seenLinked.insert(key)
                        }
                        alloc &+= entryAlloc
                        logical &+= entryLogical
                        files += 1
                    default:
                        break
                    }
                }
            }
            _ = close(fd)
        }
        return (alloc, logical, files)
        #else
        return nil
        #endif
    }

    // MARK: Result assembly

    private func buildResultLocked(_ core: inout ScannerCore) -> ScanResult {
        resolveHardLinksLocked(&core)
        attachVarVMLocked(&core)

        var stats = ScanStats()
        if let startedAt = core.startedAt {
            let duration = startedAt.duration(to: ContinuousClock.now)
            stats.elapsedSeconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
        }
        stats.directoriesScanned = Int(dirsScanned.load(ordering: .relaxed))
        stats.filesSeen = core.builder.tree.count > 0 ? Int(core.builder.tree.fileCount[0]) : 0
        stats.hardLinksDeduplicated = core.builder.deduplicatedLinks
        stats.mountPointsSkipped = core.builder.mountSkipCount
        stats.skippedMountPaths = core.builder.skippedMountPaths
        stats.peakResidentBytes = MemoryInfo.peakResidentBytes()

        let volume = options.measureVolumeInfo ? VolumeInfoReader.read(mountPath: options.root) : nil
        return ScanResult(
            tree: core.builder.tree, blocked: core.builder.blockedIDs, volume: volume,
            scannedAt: Date(), stats: stats, lastEventID: nil)
    }

    /// Pruned copy for live UI snapshots (revision 4): nodes down to `maxDepth` whose
    /// subtree allocated size is at least `minFraction` of the root total. Kept nodes
    /// carry their true (current) totals, so a parent's size covers pruned children.
    static func prunedCopy(_ tree: ScanTree, maxDepth: Int, minFraction: Double) -> ScanTree {
        var copy = ScanTree(rootPath: tree.rootPath)
        guard tree.count > 0 else { return copy }
        let rootAlloc = tree.allocSize[0]
        let threshold = UInt64((minFraction * Double(max(rootAlloc, 1))).rounded())
        func nameBytes(_ id: NodeID) -> ArraySlice<UInt8> {
            let start = Int(tree.nameOffset[Int(id)])
            return tree.nameArena[start..<start + Int(tree.nameLength[Int(id)])]
        }
        let newRoot = copy.addNode(
            nameBytes: nameBytes(0), kind: tree.kind[0], parent: ScanTree.none,
            allocSize: tree.allocSize[0], logicalSize: tree.logicalSize[0],
            fileCount: tree.fileCount[0], modTime: tree.modTime[0],
            accessTime: tree.accessTime[0])
        var stack: [(old: NodeID, newParent: NodeID, depth: Int)] = [(0, newRoot, 0)]
        while let (old, newParent, depth) = stack.popLast() {
            var child = tree.firstChild[Int(old)]
            while child >= 0 {
                let ci = Int(child)
                let childDepth = depth + 1
                if childDepth <= maxDepth, tree.allocSize[ci] >= threshold {
                    let newID = copy.addNode(
                        nameBytes: nameBytes(child), kind: tree.kind[ci], parent: newParent,
                        allocSize: tree.allocSize[ci], logicalSize: tree.logicalSize[ci],
                        fileCount: tree.fileCount[ci], modTime: tree.modTime[ci],
                        accessTime: tree.accessTime[ci])
                    stack.append((child, newID, childDepth))
                }
                child = tree.nextSibling[ci]
            }
        }
        return copy
    }
}
