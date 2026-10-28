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
    /// Pre-reserved node capacity. The default is modest (review round 2 fix 1): arrays
    /// grow geometrically instead of pre-allocating a 1M-node tree (~70 MB) per scan.
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
        reserveCapacity: Int = 1 << 16,
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

/// A directory-listing task. Queues hold bare node IDs (4 bytes each); a worker builds
/// the absolute path by walking parents under the lock when it pops the job. The
/// directory is OPENED when the job runs, so at most workerCount+1 fds are ever open.
struct QueuedDir: Sendable {
    let nodeID: NodeID
}

/// A directory job handed to a worker: node plus its materialized path.
struct DirJob: Sendable {
    let nodeID: NodeID
    let path: String
}

/// A regular file seen with linkCount > 1. Bytes are resolved after the walk (revision 8):
/// the owner is the record with the lexicographically smallest path. Records carry no
/// paths (review round 2 fix 3): during resolution one running owner is kept per key and
/// paths are built only for keys seen more than once.
struct HardLinkRecord: Sendable {
    let devid: Int32
    let fileID: UInt64
    let nodeID: NodeID
    let alloc: UInt64
    let logical: UInt64
}

struct DeviceFileKey: Hashable, Sendable {
    let devid: Int32
    let fileID: UInt64
}

/// A hard-linked file below the small-file threshold, kept only until its directory's
/// listing ends (they are rare); the bytes land on the directory's smallFilesGroup node.
struct LinkedSmall: Sendable {
    let devid: Int32
    let fileID: UInt64
    let alloc: UInt64
    let logical: UInt64
}

/// Running aggregate of one directory's small files (review round 2 fix 2: individual
/// small files are never retained until the listing ends; only linked ones are).
struct SmallAgg: Sendable {
    var count = 0
    var alloc: UInt64 = 0
    var logical: UInt64 = 0
    var modTime: Int64 = 0
    var linked: [LinkedSmall] = []
}

/// Mutable scanner state guarded by the builder Mutex (plan revision 6: mutable state lives
/// only in Mutex/Atomic; the tree is never shared unlocked).
struct BuilderState: Sendable {
    var tree: ScanTree
    /// Completion-protocol state for directories that are created but not yet finalized
    /// (review round 2 fix 2: nothing per file node; entries are removed on finalize).
    struct DirState: Sendable {
        var listingDone = false
        var pendingChildDirs: Int32 = 0
    }
    var inFlight: [NodeID: DirState] = [:]
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
        inFlight[0] = DirState()
        pendingDirs = 1 // root waits for its listing
    }

    /// Appends a node. Directory bookkeeping lives in `inFlight` and is created by the
    /// enqueue site, not here.
    mutating func appendNode(
        nameBytes: some Collection<UInt8>, kind: NodeKind, parent: NodeID,
        allocSize: UInt64 = 0, logicalSize: UInt64 = 0, fileCount: UInt32 = 0,
        modTime: Int64 = 0, accessTime: Int64 = 0
    ) -> NodeID {
        tree.addNode(
            nameBytes: nameBytes, kind: kind, parent: parent,
            allocSize: allocSize, logicalSize: logicalSize, fileCount: fileCount,
            modTime: modTime, accessTime: accessTime)
    }

    /// Registers a directory that will be listed (job enqueued): it counts as pending
    /// until its finalize, and its parent waits for it.
    mutating func trackDir(_ id: NodeID, parent: NodeID) {
        inFlight[id] = DirState()
        pendingDirs += 1
        inFlight[parent]?.pendingChildDirs += 1
    }

    mutating func markListingDone(_ id: NodeID) {
        inFlight[id]?.listingDone = true
    }
}

/// All scanner mutable state. Only ever accessed through `ParallelScanner.core`
/// (`Mutex`) or the Atomic counters on the scanner itself.
struct ScannerCore: Sendable {
    var builder: BuilderState
    /// Per-worker deques of node IDs, shared under the one Mutex. Honest naming (plan
    /// revision 6): coarse single-lock work-stealing pool (local LIFO pop, FIFO steal);
    /// per-deque locks are a future optimization if benchmarks show contention.
    var queues: [[NodeID]] = []
    /// Jobs popped but not finished.
    var activeJobs = 0
    var done = false
    /// Guards single delivery of the scan() continuation (revision 6: exactly once).
    var resultDelivered = false
    var continuation: CheckedContinuation<ScanResult, Error>?
    var streamContinuation: AsyncStream<ScanProgress>.Continuation?
    var progressTask: Task<Void, Never>?
    /// Throttled snapshot cache (revision 4: at most 1 Hz), keyed by the pruning
    /// parameters so different requests are not served a stale tree.
    var snapshotCache: ScanTree?
    var snapshotTime: ContinuousClock.Instant?
    var snapshotKey: (maxDepth: Int, minFraction: Double)?
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
        let stream = AsyncStream(ScanProgress.self, bufferingPolicy: .bufferingNewest(8)) {
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

    /// ASCII case-insensitive suffix check without allocating a String (e.g. "app"
    /// matches .app and .APP): only A-Z are folded (c | 0x20), review fix G.
    static func hasExtension(_ name: [UInt8], _ ext: String) -> Bool {
        let extBytes = Array(ext.utf8)
        let n = name.count, m = extBytes.count
        guard n > m + 1, name[n - m - 1] == UInt8(ascii: ".") else { return false }
        for (i, b) in extBytes.enumerated() {
            var c = name[n - m + i]
            if c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") { c |= 0x20 }
            if c != b { return false }
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

    /// Opens a directory, retrying transient fd-exhaustion instead of dropping the
    /// subtree (review fix D). Returns -1 with errno set on final failure.
    static func openDirectory(_ path: String, noFollow: Bool) -> Int32 {
        var flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        if noFollow { flags |= O_NOFOLLOW }
        var attempt = 0
        while true {
            let fd = open(path, flags)
            if fd >= 0 { return fd }
            let err = errno
            if err == EMFILE || err == ENFILE, attempt < 50 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            return -1
        }
    }

    /// Absolute path of a node by walking parents (review round 2 fix 4). Called with the
    /// core lock held when a job is popped; one string per directory job, never per file.
    static func nodePath(_ tree: ScanTree, _ id: NodeID) -> String {
        if id <= 0 { return tree.rootPath }
        var slices: [ArraySlice<UInt8>] = []
        var cur = id
        while cur > 0 {
            let i = Int(cur)
            let start = Int(tree.nameOffset[i])
            slices.append(tree.nameArena[start..<start + Int(tree.nameLength[i])])
            cur = tree.parent[i]
        }
        var bytes: [UInt8] = tree.rootPath == "/" ? [] : Array(tree.rootPath.utf8)
        for slice in slices.reversed() {
            bytes.append(UInt8(ascii: "/"))
            bytes.append(contentsOf: slice)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Scan lifecycle

extension ParallelScanner {
    /// Runs the scan on its own worker threads and suspends until it completes.
    /// One-shot; cancellation (via `cancel()` or cancelling the calling Task) yields
    /// `CancellationError`.
    public func scan() async throws -> ScanResult {
        guard startedFlag.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { throw ScanError.alreadyScanned }

        let rootProbe = Self.openDirectory(options.root, noFollow: false)
        guard rootProbe >= 0 else {
            // No scan will ever run on this instance: end the progress stream (review fix H).
            progressContinuation.finish()
            throw ScanError.rootUnreadable(errno: errno)
        }
        _ = close(rootProbe) // jobs open by path; this was only the readability probe

        let start = ContinuousClock.now

        // Enqueue the root job; workers start below, after the continuation is stored.
        core.withLock { core in
            core.queues[0].append(DirJob(nodeID: 0, path: options.root))
            core.startedAt = start
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [self] cont in
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
        } onCancel: { [self] in
            // Cancelling the awaiting Task cancels the scan (review fix H).
            cancel()
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
            let key = (maxDepth, minFraction)
            if let cached = core.snapshotCache, let cachedKey = core.snapshotKey, cachedKey.maxDepth == key.0, cachedKey.minFraction == key.1,
                let last = core.snapshotTime, last.duration(to: now) < .seconds(1)
            {
                return cached
            }
            let snap = Self.prunedCopy(
                core.builder.tree, maxDepth: maxDepth, minFraction: minFraction)
            core.snapshotCache = snap
            core.snapshotTime = now
            core.snapshotKey = key
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
        var stream: AsyncStream<ScanProgress>.Continuation?
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
            // Jobs carry no fds (they open by path when they run), so cancelling can
            // never leak queued descriptors; just drop the queued work.
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
        payload.stream?.finish()
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
    /// The popped node's path is built here (review round 2 fix 4); queues hold 4-byte
    /// node IDs only.
    private func nextAction(index: Int) -> WorkerAction {
        core.withLock { core -> WorkerAction in
            if core.done { return .exit(nil) }
            if cancelFlag.load(ordering: .relaxed) {
                return .exit(completeScanLocked(&core, cancelled: true))
            }
            if let id = core.queues[index].popLast() {
                let path = Self.nodePath(core.builder.tree, id)
                core.activeJobs += 1
                return .run(DirJob(nodeID: id, path: path))
            }
            let n = core.queues.count
            var victim = (index + 1) % n
            for _ in 1..<n {
                if let id = core.queues[victim].first {
                    core.queues[victim].removeFirst()
                    let path = Self.nodePath(core.builder.tree, id)
                    core.activeJobs += 1
                    return .run(DirJob(nodeID: id, path: path))
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
        var smalls = SmallAgg()

        // The fd lives only for this listing (review fix D/E: nothing is enqueued with
        // an fd, so cancellation can never leak descriptors).
        let fd = Self.openDirectory(job.path, noFollow: job.nodeID != 0)
        if fd < 0 {
            markDirFailureLocked(job, errno: errno)
        } else {
            defer { _ = close(fd) }
            listing: while true {
                if cancelFlag.load(ordering: .relaxed) { break }
                let n = DirectoryReader.readEntries(
                    fd: fd, buffer: buffer, bufferSize: DirectoryReader.defaultBufferBytes)
                if n < 0 {
                    markDirFailureLocked(job, errno: errno)
                    break
                }
                if n == 0 { break }
                let entries = DirectoryReader.parseAttrBuffer(
                    UnsafeRawBufferPointer(start: buffer, count: DirectoryReader.defaultBufferBytes),
                    count: n)
                if entries.isEmpty { break } // malformed batch; next readEntries returns fresh data

                // Classify entries (no lock, no fd opens). childMarkers per entry:
                // 0 = enqueue a job, -1 = skip entirely (skip list / /private/var/vm),
                // -2 = mount boundary leaf.
                var childPaths: [String?] = []
                var childMarkers: [Int32] = []
                childPaths.reserveCapacity(entries.count)
                childMarkers.reserveCapacity(entries.count)
                for entry in entries {
                    guard entry.objType == Attr.ObjType.vdir, let name = entry.name else {
                        childPaths.append(nil)
                        childMarkers.append(0)
                        continue
                    }
                    let path = Self.childPath(parent: job.path, name: name)
                    if isRootScan,
                        options.skipPaths.contains(path) || path == "/private/var/vm"
                    {
                        if path == "/private/var/vm" {
                            varVMRequested.store(true, ordering: .relaxed)
                        }
                        childPaths.append(path)
                        childMarkers.append(-1)
                        continue
                    }
                    if !options.crossMounts, let dev = entry.devid, !allowedDevids.contains(dev) {
                        // Mount boundary: 0-size leaf, never descended (plan revision 1).
                        childPaths.append(path)
                        childMarkers.append(-2)
                        continue
                    }
                    childPaths.append(path)
                    childMarkers.append(0)
                }

                // One lock acquisition to append this batch's nodes and jobs.
                core.withLock { core in
                    appendBatchLocked(
                        &core, job: job, entries: entries, childPaths: childPaths,
                        childMarkers: childMarkers, workerIndex: workerIndex,
                        smalls: &smalls)
                }
            }
        }

        // Listing finished (failed, cancelled, or done): the directory ALWAYS completes
        // so pending counters stay balanced (review fixes B/C).
        let payload = core.withLock { core -> DeliveryPayload? in
            core.builder.markListingDone(job.nodeID)
            finalizeSmallGroupLocked(&core.builder, job: job, agg: smalls)
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

    /// A queued directory could not be listed (open or getattrlistbulk failure).
    /// Permission errors become blocked nodes; every other error leaves a zero-size
    /// directory node. Either way the job's final step marks listingDone and finalizes,
    /// so the completion protocol never wedges (review fixes B/C).
    private func markDirFailureLocked(_ job: DirJob, errno: Int32) {
        core.withLock { core in
            let i = Int(job.nodeID)
            if errno == EPERM || errno == EACCES {
                core.builder.tree.kind[i] = .blocked
                core.builder.blockedIDs.append(job.nodeID)
            }
        }
    }
}

// MARK: - Tree building (all with the core lock held)

extension ParallelScanner {
    /// Appends one parsed batch to the tree. Per-batch (not per-listing) so memory stays
    /// bounded and other workers can steal early. The directory is NOT completed here;
    /// its job's final step sets listingDone and runs the finalize chain. Child
    /// directories become path-based jobs — opening (and any open error) happens when
    /// the child's job runs.
    private func appendBatchLocked(
        _ core: inout ScannerCore, job: DirJob, entries: [RawEntry],
        childPaths: [String?], childMarkers: [Int32],
        workerIndex: Int, smalls: inout SmallAgg
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
                let marker = childMarkers[i]
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
                let id = core.builder.appendNode(
                    nameBytes: name, kind: isBundle ? NodeKind.bundle : NodeKind.directory,
                    parent: job.nodeID, modTime: entry.modTime ?? 0,
                    accessTime: entry.accessTime ?? 0)
                core.builder.trackDir(id, parent: job.nodeID)
                core.queues[workerIndex].append(id)

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
                    // Aggregated per batch (review round 2 fix 2); only linked small files
                    // are retained, for ownership resolution.
                    smalls.count += 1
                    if entry.modTime ?? 0 > smalls.modTime { smalls.modTime = entry.modTime ?? 0 }
                    if linkCount <= 1 {
                        smalls.alloc &+= alloc
                        smalls.logical &+= logical
                    } else {
                        smalls.linked.append(
                            LinkedSmall(
                                devid: entry.devid ?? 0, fileID: entry.fileID ?? 0,
                                alloc: alloc, logical: logical))
                    }
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
                                nodeID: id, alloc: alloc, logical: logical))
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

    /// Folds the directory's aggregated small files into ONE smallFilesGroup node
    /// (SPEC §4, revision 9). Linked small files contribute 0 bytes here; their bytes
    /// are added after the walk if their record owns the (devid, fileid) group.
    private func finalizeSmallGroupLocked(
        _ b: inout BuilderState, job: DirJob, agg: SmallAgg
    ) {
        guard agg.count > 0 else { return }
        let groupName = "(\(agg.count) small files)"
        let id = b.appendNode(
            nameBytes: Array(groupName.utf8), kind: .smallFilesGroup, parent: job.nodeID,
            allocSize: agg.alloc, logicalSize: agg.logical, fileCount: UInt32(agg.count),
            modTime: agg.modTime)
        for s in agg.linked {
            b.hardLinks.append(
                HardLinkRecord(
                    devid: s.devid, fileID: s.fileID, nodeID: id,
                    alloc: s.alloc, logical: s.logical))
        }
    }

    /// Directory completion protocol (plan revision 3), iterative: finalize `start` if its
    /// listing is done and no child directories are pending; then decrement the parent's
    /// pending counter and re-check, walking up until a directory is not ready. Finalized
    /// directories leave `inFlight` entirely (review round 2 fix 2).
    private func finalizeChainLocked(_ b: inout BuilderState, start: NodeID) {
        var cur = start
        while cur >= 0 {
            let i = Int(cur)
            // Absent from inFlight = already finalized, or a leaf that never takes part.
            guard let state = b.inFlight[i] else { break }
            let k = b.tree.kind[i]
            guard k == .directory || k == .bundle || k == .blocked else { break }
            guard state.listingDone, state.pendingChildDirs == 0 else { break }
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
            b.inFlight[i] = nil
            b.pendingDirs -= 1
            let parent = b.tree.parent[i]
            if parent >= 0 {
                b.inFlight[parent]?.pendingChildDirs &-= 1
            }
            cur = parent
        }
    }

    private func addBytesLocked(
        _ core: inout ScannerCore, nodeID: NodeID, alloc: UInt64, logical: UInt64
    ) {
        Self.addBytes(&core.builder.tree, nodeID: nodeID, alloc: alloc, logical: logical)
    }

    /// Adds bytes to a node and all of its ancestors (used by the hard-link owner pass
    /// and by subtree attachment).
    static func addBytes(
        _ tree: inout ScanTree, nodeID: NodeID, alloc: UInt64, logical: UInt64
    ) {
        var cur = nodeID
        while cur >= 0 {
            let i = Int(cur)
            tree.allocSize[i] &+= alloc
            tree.logicalSize[i] &+= logical
            cur = tree.parent[i]
        }
    }

    // MARK: Post-walk passes

    /// Revision 8: per (devid, fileid) group the owner is the record with the smallest
    /// path; its bytes are added to it and its ancestors. Records carry no paths (review
    /// round 2 fix 3): one running owner is kept per key, and paths are built only for
    /// keys seen more than once. For records attached to a smallFilesGroup node the
    /// comparison key is the group's node path — deterministic and stable across runs
    /// (group paths are prefixes of the member file paths).
    private func resolveHardLinksLocked(_ core: inout ScannerCore) {
        struct KeyState {
            var count = 0
            var best: HardLinkRecord?
            var bestPath: String?
        }
        var groups: [DeviceFileKey: KeyState] = [:]
        for record in core.builder.hardLinks {
            let key = DeviceFileKey(devid: record.devid, fileID: record.fileID)
            var state = groups[key] ?? KeyState()
            state.count += 1
            if state.count == 1 {
                state.best = record
            } else {
                if state.bestPath == nil, let best = state.best {
                    state.bestPath = core.builder.tree.path(best.nodeID)
                }
                let path = core.builder.tree.path(record.nodeID)
                if let bestPath = state.bestPath, path < bestPath {
                    state.best = record
                    state.bestPath = path
                }
            }
            groups[key] = state
        }
        for state in groups.values {
            if state.count > 1 {
                core.builder.deduplicatedLinks += state.count - 1
            }
            guard let best = state.best else { continue }
            Self.addBytes(
                &core.builder.tree, nodeID: best.nodeID,
                alloc: best.alloc, logical: best.logical)
        }
        core.builder.hardLinks.removeAll(keepingCapacity: false)
    }

    /// Revision 2: /private/var/vm (firmlinked to the VM volume) is measured recursively
    /// as an explicit exception and attached under /private/var with its completed total.
    private func attachVarVMLocked(_ core: inout ScannerCore) {
        guard varVMRequested.load(ordering: .relaxed) else { return }
        guard let totals = Self.scanDirectorySequentially(path: "/private/var/vm") else { return }
        _ = Self.attachSubtree(
            &core.builder, underPath: "/private/var", name: "vm",
            alloc: totals.alloc, logical: totals.logical, files: totals.files)
    }

    /// Attaches a completed subtree as one directory node under an existing path. The
    /// node starts at zero and receives its totals exactly once via addBytes, which also
    /// pushes them up the ancestors (review fix F: the old code set the sizes on append
    /// AND added them again). Internal so tests can pin the single-count behavior.
    static func attachSubtree(
        _ b: inout BuilderState, underPath: String, name: String,
        alloc: UInt64, logical: UInt64, files: Int
    ) -> NodeID? {
        guard b.tree.count > 0, let parent = b.tree.node(atPath: underPath) else { return nil }
        let id = b.appendNode(nameBytes: Array(name.utf8), kind: .directory, parent: parent)
        b.tree.fileCount[Int(id)] = UInt32(clamping: files)
        addBytes(&b.tree, nodeID: id, alloc: alloc, logical: logical)
        return id
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
                            bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                                openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            }
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
        // The scan is over: drop the cached snapshot so a finished scanner does not pin
        // a second copy of the tree (review round 2 fix 4).
        core.snapshotCache = nil
        core.snapshotKey = nil
        core.snapshotTime = nil

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
    /// While the root total is still zero (scan incomplete) the minFraction filter is
    /// useless, so the copy is capped at `nodeCap` nodes (review round 2 fix 4).
    static func prunedCopy(
        _ tree: ScanTree, maxDepth: Int, minFraction: Double, nodeCap: Int = 20_000
    ) -> ScanTree {
        var copy = ScanTree(rootPath: tree.rootPath)
        guard tree.count > 0 else { return copy }
        let rootAlloc = tree.allocSize[0]
        let capActive = rootAlloc == 0
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
            if capActive, copy.count >= nodeCap { break }
            var child = tree.firstChild[Int(old)]
            while child >= 0 {
                if capActive, copy.count >= nodeCap { break }
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
