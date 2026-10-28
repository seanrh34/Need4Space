# Need4Space implementation plan

Product name: **Need4Space** (own identity; nothing borrowed from DaisyDisk).
Bundle id: `dev.seanrh.Need4Space`. App support dir: `~/Library/Application Support/Need4Space/`.
Logs: `~/Library/Logs/Need4Space/actions.log`.

## Build environment constraint (read this first)
The orchestration VPS is Linux with **no Swift toolchain**. Code written here cannot be compiled
here. Therefore:
- Write conservative, idiomatic Swift 6 (strict concurrency, `swift-tools-version: 6.0`). Avoid
  exotic APIs. Mark Darwin-only code with `#if canImport(Darwin)` only where it would otherwise
  break *other* targets; the package targets macOS 15 only.
- Verification happens on a Mac (Sean's machine or a GitHub Actions `macos-15` runner):
  `swift build`, `swift test`, `swift run -c release n4s-scan /`, `scripts/make-app.sh`.
- Every PR must include a "How to verify on a Mac" section listing these commands.
- Reviewers check compile-ability by reading: Sendable conformance, `@MainActor` isolation,
  unsafe pointer lifetimes, integer widths in getattrlistbulk parsing.

## Repository layout (single SwiftPM package, no Xcode project)
```
Package.swift                   // platforms: [.macOS(.v15)], swift-tools 6.0
Sources/ScannerKit/             // no SwiftUI/AppKit imports
  ScanTree.swift                // SoA tree + name arena + queries (skeleton committed on main)
  ScanResult.swift              // ScanResult, ScanStats, VolumeInfo, LocalSnapshot, BlockedEntry
  DirectoryReader.swift         // getattrlistbulk wrapper: open(O_RDONLY|O_DIRECTORY), 64 KB+ buffer
  ParallelScanner.swift         // bounded worker pool, tree builder, bottom-up aggregation
  ScanProgress.swift            // 10 Hz AsyncStream snapshots
  VolumeInfoReader.swift        // statfs + URLResourceValues (total/free/importantUsage)
  (M5) TreeCache.swift, FSEventsWatcher.swift
Sources/InsightKit/             // depends on ScannerKit only
  Rules.swift                   // rule table as data
  RuleEngine.swift
  AppTotals.swift
  Outliers.swift                // large folders, stale files, (M6) fast growers
  HiddenSpace.swift
  Ranking.swift
  Categories.swift              // node -> Category (apps, media, developer, system, caches, trash, documents, other)
Sources/n4s-scan/main.swift     // CLI + benchmark: time, node count, peak RSS, top 20 folders, blocked list
Sources/Need4Space/             // SwiftUI app (executable target), AppKit only for reveal/QuickLook
Tests/ScannerKitTests/          // fixture generator on real temp dirs
Tests/InsightKitTests/          // in-memory fixture trees via ScanTree.addNode
Tests/SafetyTests/              // (M3) protected paths, no permanent-delete API anywhere
scripts/make-app.sh             // swift build -c release, assemble .app with Info.plist, codesign -s -
scripts/check-no-permanent-delete.sh // grep gate: removeItem, unlink(, rmdir(, "rm " in Sources/
```
Tests use **Swift Testing** (`import Testing`).

## Scanner design (M1)
- **Reader**: `DirectoryReader.read(dirFD:) -> [RawEntry]` (or a callback per batch) using
  getattrlistbulk with attrs from spec §4 plus `FSOPT_PACK_INVAL_ATTRS`. Parse via
  `ATTR_CMN_RETURNED_ATTRS` (attribute_set_t) to know which fields are present; respect field order
  and 4/8-byte alignment as documented in getattrlistbulk(2). Name via `attrreference_t`.
  Per-entry `ATTR_CMN_ERROR` handled (entry becomes blocked / skipped).
  Use `openat(parentFD, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` for children where practical
  (no path string building in the hot loop); fall back to absolute paths if simpler.
  Each worker owns one reusable buffer (256 KB). No FileManager.enumerator, no per-file stat.
- **Pool**: `2 * ProcessInfo.activeProcessorCount` OS threads (Thread or pthread), NOT Swift Tasks
  (blocking syscalls must not starve the cooperative pool). Work stealing: each worker has a local
  deque (LIFO for own pushes, steal FIFO from others); a global idle counter + condition for
  termination. A simpler mutex-protected shared stack is acceptable for v1 *if* benchmarked, but
  name it honestly.
- **Tree builder**: one `Mutex`-protected (Synchronization module) builder holding the `ScanTree`.
  A worker reads a whole directory without the lock, then takes the lock once to append that
  directory's children (batch). Directory children get node ids immediately and are enqueued as jobs
  carrying (nodeId, fd/path).
- **Bottom-up aggregation**: per-dir `pendingChildDirs` counter (side array, discarded at end).
  When a dir's listing is appended and its pending count is 0, it is finalized: its alloc/logical/
  fileCount become the sum over children; then parent's pending is decremented, recursively.
  Directory's own allocSize (the dir inode) is ignored (matches `du` closely enough; document).
- **Small files**: per directory, files with alloc < 64 KB are collapsed into ONE
  `.smallFilesGroup` node named "(N small files)" carrying summed sizes and fileCount = N;
  max modTime, 0 accessTime. Directories, bundles, symlinks are never collapsed.
- **Bundles**: directory names ending in `.app`, `.photoslibrary`, `.xcarchive`, `.bundle`,
  `.framework`, `.plugin`, `.appex` get kind `.bundle` (still scanned into).
- **Symlinks**: recorded as `.symlink` leaf with its own alloc size (usually 0), never followed.
- **Hard links**: entries with linkcount > 1: insert `(devid, fileid)` into a sharded set
  (16 shards by fileid, each `Mutex<Set<UInt64-pair>>`); only the first occurrence counts bytes; later
  ones get a node with size 0 (so they stay visible) — or are skipped; pick one and test it.
- **Mount boundaries / firmlinks**: allowed device set = { devid of `/`, devid of
  `/System/Volumes/Data` if it exists }. An entry whose devid is outside the set is a mount point:
  not descended (record nothing, or a 0-size leaf of kind .other). When scanning a non-root volume,
  allowed set = { devid of the selected root }.
- **Skip list** (absolute paths, only when scanning `/`): `/Volumes`, `/dev`, `/.vol`,
  `/System/Volumes`, `/private/var/vm` (handled separately) and `/cores` is NOT skipped.
  `/private/var/vm`: after the main walk, measure it as its own item (it may live on the VM volume
  with a different devid; read it with one getattrlistbulk on that dir regardless of devid) and attach
  it as a node under `/private/var` named `vm` (kind `.directory`) with its true size.
- **Blocked**: EPERM/EACCES on open or on a getattrlistbulk entry ⇒ node of kind `.blocked`,
  size 0 (unknown), path recorded in `ScanResult.blocked`.
- **Progress**: a 10 Hz timer (DispatchSourceTimer or a Task with `ContinuousClock` sleep) reads
  counters (bytesFound, filesFound, dirsScanned, dirsPending) under lock and yields a `ScanProgress`
  value to an `AsyncStream`. Includes the top 5 finished top-level-ish dirs by size.
  Partial tree snapshots are a copy of the tree arrays; produce at most 1 Hz and only if requested
  (API: `snapshotTree() -> ScanTree`).
- **Cancellation**: `ParallelScanner.cancel()` sets an atomic flag; workers drain and exit.
- **Public API (Sendable)**:
  ```swift
  public final class ParallelScanner: Sendable {
      public init(options: ScanOptions)
      public func scan() async throws -> ScanResult           // runs on its own threads
      public var progress: AsyncStream<ScanProgress> { get }   // single consumer
      public func cancel()
  }
  public struct ScanOptions: Sendable { root: String = "/", threadCount: Int? = nil,
      smallFileThreshold: UInt64 = 64*1024, skipPaths: [String] = defaults, crossMounts = false }
  ```
- **Memory**: per node 4*3 + 4 + 1 + 8*2 + 4 + 8*2 = 53 B + names ≈ 70–80 B/node ⇒ ~80 MB per 1M.
  Reserve capacity up front (e.g. 1M) to avoid repeated copy-on-grow spikes.

## CLI / benchmark (M1)
`swift run -c release n4s-scan [path] [--top 20] [--threads N] [--json]` prints: elapsed time,
node count, dirs, files (real file count incl. small-file groups), bytes allocated, blocked count +
first 50 blocked paths, peak RSS (getrusage `ru_maxrss`, bytes on macOS), top 20 folders by alloc
size (any depth, but exclude a folder whose child is also in the list? no: plain top 20 by size of
directories at depth ≤ 4 is fine; document).
`scripts/accuracy.sh <dir>...` runs `du -sk` vs `n4s-scan --json` for given folders and prints diff %.

## Insight engine (M2, InsightKit) — pure functions over ScanTree
- `Rule { id, title, detail, paths: [PathPattern], risk, action, minBytes = 200 MB, granularity }`
  where PathPattern = `.home("Library/Caches/Homebrew")`, `.absolute("/Library/Logs")`,
  `.homeGlobChildren("Library/Caches")` (per-subfolder), `.homeGlob("Pictures/*.photoslibrary")`,
  `.anyDirectoryNamed(["node_modules","target","build",".venv"])`, `.downloads(...)` special.
  Full rule table from SPEC §6 in `Rules.swift`. `SuggestedAction`: `.trash`, `.emptyTrash`,
  `.revealOnly`, `.copyCommand(String)`, `.displayOnly`, `.openSettings`.
- `InsightEngine.run(tree:, homePath:, volume:, apps: [AppBundleInfo], previous: ScanTree?) -> InsightReport`
  Report: `[Insight]` ranked, `reclaimableSafeBytes`, `apps: [AppUsage]`, `hidden: HiddenSpace`.
  Insight includes `nodeIDs`, `paths`, `bytes`, `risk`, `action`, `children: top 10 (name, bytes, nodeID)`.
- `anyDirectoryNamed`: single pass over the tree; once matched, don't descend (no nested
  node_modules double counting); each match ≥ minBytes listed; sorted by size and project mtime.
- Per-app totals: `AppBundleInfo { path, name, bundleID }` provided by the caller (the app reads
  Info.plist; InsightKit stays pure and testable). Sum bundle + support dirs per SPEC §6; flag
  support > 2x bundle. Group Containers match: folder name ends with bundle id or contains its
  team-prefixed form (`<TEAMID>.<bundleid>`), best effort.
- Coverage set: every node id claimed by a rule or app; large-folder outlier (> 3% of used) skips
  folders that are, or are inside/contain, claimed nodes; reports top-most qualifying path only.
- Stale files: file nodes (not small groups) ≥ 500 MB with max(accessTime, ?)… use accessTime if
  non-zero else modTime, older than now - 365 d. `now` injected for tests.
- Hidden space: `unaccounted = max(0, used - scannedTotal)`; parts = snapshots (sum of snapshot
  sizes if known; tmutil gives names/dates only, size unknown ⇒ show count, bytes lumped in remainder),
  purgeable, blocked count; remainder label "APFS clones, system volumes and metadata". If scanned >
  used (clone overcount), report the overcount explicitly.
- Ranking: bytes desc; adjacent items within 20% where one is safe and the other isn't ⇒ safe first
  (stable sort with comparator on bucketed size is not transitive — implement as: sort by bytes desc,
  then a single bubble pass promoting safe items past non-safe neighbours within 20%). Header total
  = sum of safe insight bytes (no double counting of overlapping paths: dedupe by node ancestry).
- Must run < 2 s on 1M nodes: single linear passes, precomputed path→node lookups via
  `ScanTree.node(atPath:)` (child-name walk) — no full path materialization for every node.

## App (M2 shell → M4 full UI)
- `ScanStore` (`@MainActor @Observable`): `tree`, `volume`, `report`, `progress`, `phase`.
  `ScanService` (actor) owns ParallelScanner, hands immutable `ScanResult` to the store.
  `InsightService` runs InsightKit off-main (`Task.detached`), publishes report.
- M2 UI: NavigationSplitView sidebar (Insights default; others placeholder), Insights list of
  cards (title, size via ByteCountFormatter `.file`, detail, risk badge, Reveal in Finder button,
  expandable top-10 children), header "Up to X reclaimable (safe items only)", scan progress view
  (progress bar bytes vs used, live top-5), banner for blocked folders.
- `scripts/make-app.sh` builds `Need4Space.app` (Info.plist: LSMinimumSystemVersion 15.0,
  CFBundleIdentifier dev.seanrh.Need4Space, NSPrincipalClass NSApplication), ad-hoc codesign.

## Milestones & agent assignment
| Step | Branch | Agent | Depends on |
|---|---|---|---|
| A. M1 scanner + CLI + fixture tests | feature/m1-scanner | impl (x-test-2) | skeleton on main |
| B. M2a InsightKit (rules, apps, outliers, hidden, ranking) + tests | feature/m2-insightkit | impl (x-test-2) | skeleton on main (parallel with A) |
| C. M2b App shell + Insights list | feature/m2-app | ui agent | A + B merged |
| D. M3 safe actions | feature/m3-actions | impl | C |
| E. M4 sunburst & browsing | feature/m4-browse | ui agent | C |
| F. M5 cache + FSEvents | feature/m5-cache | impl | A |
| G. M6 hidden space + FDA onboarding + polish | feature/m6-polish | impl/ui | B, C |
Each step: plan review → implement → orchestrator + Codex diff review → fix (max 3 rounds).

## Testing (per SPEC §10)
- ScannerKit fixtures (real temp dir): nested dirs; hard link pair (counted once); symlink loop
  (a → b → a; not followed, scan terminates); sparse file (alloc < logical; assert alloc used);
  unreadable dir (chmod 000 ⇒ blocked node; skip assertion when running as root); small files
  grouping; bundle detection; cancel mid-scan. Assert exact totals computed from `stat` of the
  fixture files (tests may use stat; the scanner may not).
- InsightKit: hand-built trees for each rule, nested node_modules, app totals with support > 2x,
  large folder coverage exclusion, stale file with/without atime, hidden-space math incl. overcount,
  ranking tie-break, reclaimable dedupe, perf test on synthetic 1M-node tree (< 2 s, release).
- Safety (M3): protected path table tests; careful ⇒ no delete action; grep gate script in CI.

## Revisions after plan review (Codex, 2026-10-28) — these OVERRIDE earlier sections
1. **Accounting scope.** `VolumeInfo.usedBytes = volumeTotalCapacity - volumeAvailableCapacity` for
   the URL `/` (APFS container-wide, what Finder shows). Scanned set = System volume + Data volume
   (via firmlinks; never traverse `/System/Volumes/Data` directly) + `/private/var/vm`. Everything
   else (Preboot, Recovery, Update, other container volumes, snapshots, clones, metadata) lands in
   the hidden-space remainder. Allowed devids for a `/` scan: devid(`/`) and devid(`/System/Volumes/Data`).
   The scanner records how many mount points it skipped and their paths (`ScanResult` stats).
2. **`/private/var/vm`** is scanned **recursively** as an explicit exception (its own devid allowed only
   inside that subtree), then attached as one directory node with its completed total.
3. **Directory completion protocol** (under the builder lock): each dir has `listingDone: Bool` and
   `pendingChildDirs: Int32`. When its listing is appended, set `listingDone = true` and
   `pendingChildDirs = number of child dirs enqueued`. Finalize iff `listingDone && pending == 0`,
   exactly once; finalizing sums children, then decrements the parent's pending and re-checks it
   (iterative, not recursive). Failed/blocked dirs finalize immediately with size 0.
   Tests: empty dirs, 200-deep chain, blocked dirs, wide dirs (10k entries), many threads.
4. **No CoW spikes.** The builder never holds `ChildSequence`/tree copies while mutating; use index
   loops. Live UI snapshots are `snapshotTree(maxDepth: 4, minFraction: 0.001)` — a *pruned* copy
   (sunburst only shows 4 rings), at most every 1 s. Progress values are small structs.
5. **getattrlistbulk parsing**: bounds-check every record length against the buffer; read each
   optional field only if its bit is set in `returned_attrs`; `attrreference_t.attr_dataoffset` is
   relative to the reference field's own address; validate offset+length within the record; use
   `loadUnaligned`. Factor the parser as a pure function `parseAttrBuffer(_ buf: UnsafeRawBufferPointer,
   count: Int) -> [RawEntry]` so it can be unit-tested with hand-built buffers (mixed returned
   attrs, per-entry error, truncated record).
6. **Concurrency design**: `ParallelScanner` is a `final class: Sendable` whose mutable state lives
   only in `Mutex<…>` / `Atomic<…>` (Synchronization). One-shot: calling `scan()` twice throws.
   Worker threads are `Thread`s; `scan()` bridges completion with `withCheckedThrowingContinuation`
   resumed exactly once (by the last worker or by cancellation). The progress `AsyncStream`
   continuation is finished on completion, error or cancel. Cancellation → `CancellationError`.
7. **Hidden space is not additive.** Report `gap = used - scanned` (or overcount if negative),
   then list measured facts separately: purgeable bytes (note: may include snapshot space),
   snapshot count (+ bytes only if known), blocked folder count, remainder =
   `max(0, gap - purgeable)` labelled "APFS clones, system volumes and metadata". Never show negatives.
8. **Hard links, deterministic**: during the walk, entries with linkcount > 1 get size 0 and are
   recorded as `(devid, fileid, nodeID, alloc, logical)`. After the walk, per (devid, fileid) group, the
   owner is the node with the lexicographically smallest path; add its bytes to it and its ancestors.
   Stats count deduplicated links. Test: hard links in sibling folders → stable owner across runs.
9. **Small files**: grouping stays (spec), but files with extensions `.dmg .pkg .zip .xip .iso` are never
   grouped. Acting on individual small files = UI performs a one-directory listing on demand (M4).
10. **Ranking**: sort by bytes desc, then repeat passes promoting a safe item ahead of a non-safe
    predecessor whose bytes are within 20% of it, until no change. Test chains of ≥3.
11. **Large folders**: `uncovered(dir) = alloc(dir) - bytes of claimed (rule/app) nodes inside it`.
    Candidate if uncovered ≥ 3% of used. Report a candidate only if no child candidate holds ≥ 50%
    of its uncovered bytes (push down to where the mass is). Never report `/`, `/Users`, home,
    `~/Library`, `/System`, `/Applications`, `/Library`, `/private` themselves.
12. Memory budget includes side arrays (pending, listingDone), hard-link records, queue; benchmark
    reports peak RSS. Target remains < 200 MB at 1M nodes.
13. **Milestone order**: M3 (safe actions) also does in-memory subtree removal after Trash
    (subtract from ancestors). Basic persistence (save/load + "scanned X ago") moves right after
    the M2 app shell; FSEvents incremental refresh stays later.
14. **Empty Trash** conflicts with acceptance criterion 4 (no permanent deletion). Default until Sean
    decides: the Trash insight only offers "Open Trash in Finder"; no programmatic emptying.
