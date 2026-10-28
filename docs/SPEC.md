# MacDisk Analyzer: Technical Spec
Oct 28, 2026 · @Sean  (product name in this repo: **Need4Space**)

## 1. Overview
Build a native macOS app for personal use that scans the startup disk in under 30 seconds and tells the user what is using space and what is unusually large, so they never have to dig through Finder, System Settings or hidden folders.

### Goals
- Fast full-disk scan (target: under 30 s on an APFS SSD with roughly 1M files).
- One screen that answers: where is my space going, and what should I look at first?
- Surface known space hogs automatically: large apps, caches, developer tooling, Xcode data, Docker/VM images, iOS backups, Time Machine snapshots, mail and message attachments, Trash.
- Let the user inspect and remove items safely, always via the Trash.

### Non-goals
- No automated cleaning, no "optimize" button, no background daemon.
- No cloud storage scanning, no network volumes, no FUSE, no legacy macOS support.
- No App Store distribution, notarization or production hardening. An ad-hoc signed local build is fine.
- Do not copy DaisyDisk's name, icon or exact visual design. This is a personal tool with its own identity.

### Target environment
- macOS 15 or later, Apple Silicon (Intel optional).
- Swift 6, SwiftUI, Swift Concurrency. Xcode project or Swift Package with an app target.
- Single internal APFS volume as the primary case. External APFS/HFS+ volumes should work through the same code path.
- No third-party dependencies unless clearly justified.

## 2. Key use cases
| # | User question | What the app must show |
|---|---|---|
| 1 | Where is my disk space going overall? | Breakdown by category (Apps, Documents, Media, Developer, System, Library/Caches, Trash, Other) plus a total used/free/purgeable summary |
| 2 | What are my biggest folders and files? | Ranked list of the top N items at any directory level, with size and percent of parent |
| 3 | Which apps are too large? | Ranked list of installed apps including their support data (Library/Application Support, Caches, Containers) |
| 4 | What is unusually large or suspicious? | Insights panel: flagged items such as Xcode DerivedData, Docker.raw, iOS backups, old simulators, node_modules, large caches, big files not opened in 12+ months |
| 5 | Why does macOS report more used space than I can find? | A "Hidden / unaccounted" slice with a breakdown into snapshots, purgeable space and permission-blocked folders |

### Primary flow
1. Launch the app. If Full Disk Access is missing, show a one-screen prompt that explains why and opens the right System Settings pane.
2. Scan runs automatically with live progress and partial results that grow as the scan proceeds.
3. When done, the Insights panel lists the top space hogs, sorted by reclaimable size.
4. The user clicks an insight or a sunburst segment, drills in, reveals in Finder, and moves items to Trash.
5. A re-scan of only the affected subtree updates numbers instantly, with no full disk re-scan.

## 3. Architecture and tech stack
The UI never touches the disk. A single @MainActor @Observable store holds the scan tree, volume info and insights, and five services fill it or act on it. The insight engine is the part that answers the user's key question.

### Package layout
- **ScannerKit** (Swift package, no UI imports): scanner, flat tree, persistence, FSEvents refresh. Keeping it separate lets a CLI be added later and makes it unit-testable.
- **InsightKit** (Swift package): rule table, per-app totals, outlier detectors, hidden-space calculation. Pure functions over the tree, so they are testable with fixture trees.
- **DiskApp** (app target): SwiftUI views, ScanStore, ActionService, permission onboarding.

### Technology choices
- Language and UI: Swift 6 with strict concurrency, SwiftUI, Canvas for the sunburst. AppKit only where SwiftUI lacks an API (Quick Look panel, Finder reveal).
- Concurrency: scanning runs in background tasks. The finished tree is an immutable value handed to the store via an actor. The UI only ever sees snapshots, never mutable shared state.
- Low-level I/O: getattrlistbulk and open through Darwin directly. No Objective-C or third-party file-scanning libraries.
- Testing: Swift Testing or XCTest, with a fixture generator for synthetic trees.

## 4. Scanner requirements
The scanner must never use FileManager.enumerator or per-file stat calls for the main scan. It reads metadata in batches and walks directories in parallel, and it caches results so repeat launches feel instant.

### Traversal
- Use getattrlistbulk(2) on a directory fd opened with open(path, O_RDONLY | O_DIRECTORY). Request in one call: ATTR_CMN_RETURNED_ATTRS, ATTR_CMN_ERROR, ATTR_CMN_NAME, ATTR_CMN_DEVID, ATTR_CMN_OBJTYPE, ATTR_CMN_FILEID, ATTR_CMN_MODTIME, ATTR_CMN_ACCTIME (best effort), ATTR_FILE_LINKCOUNT, ATTR_FILE_ALLOCSIZE, ATTR_FILE_DATALENGTH. Buffer of at least 64 KB per call.
- Walk directories concurrently with a bounded work-stealing pool, parallelism ~2x logical core count. Never spawn one task per file.
- Do not follow symlinks. Do not cross into other mounted volumes unless the user selects one. Compare ATTR_CMN_DEVID to detect mount boundaries.
- Scan / and let firmlinks resolve the Data volume. Skip /Volumes, /dev, /.vol and /System/Volumes (avoid double counting), but read /private/var/vm (swap) as its own item.

### Size accounting
- Primary size = allocated size on disk (ATTR_FILE_ALLOCSIZE). Also store logical size (ATTR_FILE_DATALENGTH).
- Hard links: when link count > 1, count each (devid, fileid) once.
- APFS clones/shared blocks cannot be detected cheaply. Accept some overcount; show the gap between scanned total and the volume's reported used space ("Hidden space").
- Permission errors (EPERM, EACCES) create a blocked node with unknown size, recorded so the UI can list them.

### Memory and speed budget
- Nodes in flat arrays (struct of arrays) with Int32 indices for parent and first child, names interned in one byte arena. No class instance per file. Target: 1M nodes under 200 MB.
- Within each directory, collapse files smaller than 64 KB into one synthetic "(N small files)" node.
- Aggregate sizes bottom-up as each directory completes. Publish progress snapshots to the UI at 10 Hz via AsyncStream; never update the UI per file.
- Targets (Apple Silicon, internal SSD): full scan under 30 s (stretch < 15 s), UI responsive at 60 fps during scan.

### Caching and incremental refresh
- Persist the last completed scan to ~/Library/Application Support/<AppName>/ in a compact binary format.
- On launch, show the cached result immediately, labeled "scanned <time ago>", then refresh in the background.
- Refresh incrementally using FSEvents with the stored last event ID. Rescan only changed directories; fall back to full scan if history unavailable.
- After any delete performed by the app, update the affected subtree and ancestors in memory without a rescan.

## 5. Data model (guide, not required API; memory budget must hold)
```swift
struct ScanTree {
    var parent:     [Int32]   // -1 for root
    var firstChild: [Int32]   // -1 if leaf
    var nextSibling:[Int32]   // -1 if last
    var nameOffset: [UInt32]  // into nameArena
    var kind:       [NodeKind]// file, dir, bundle, symlink, blocked, smallFilesGroup
    var allocSize:  [UInt64]  // aggregated for dirs
    var logicalSize:[UInt64]
    var fileCount:  [UInt32]  // aggregated for dirs
    var modTime:    [Int64]
    var accessTime: [Int64]   // 0 if unknown
    var nameArena:  [UInt8]
}
struct VolumeInfo {
    var totalBytes, usedBytes, freeBytes: UInt64
    var purgeableBytes: UInt64   // volumeAvailableCapacityForImportantUsage - free
    var snapshots: [LocalSnapshot]
}
struct Insight: Identifiable {
    var id: String; var title: String; var detail: String
    var paths: [URL]; var bytes: UInt64
    var risk: Risk               // .safe, .review, .careful
    var action: SuggestedAction  // .trash, .revealOnly, .openSettings, .runCommand(String)
}
```
Persistence: cache holds the arrays, VolumeInfo, scan timestamp, last FSEvents ID; includes a format version (mismatch -> discard + rescan). Insights recomputed on load, not stored.

## 6. Insight engine
Turns the tree into a ranked "look at this" list. Runs on the finished tree (no extra disk reads except app bundle metadata and snapshot queries), must finish in < 2 s.

### Rule-based detectors
Rules are data (Swift array or bundled JSON). A rule appears only if its path exists and exceeds its minimum size (default 200 MB, per-rule override). Paths relative to home unless absolute; verify at runtime.

| Rule | Path or match | Risk | Suggested action |
|---|---|---|---|
| Trash | ~/.Trash | safe | Empty via Finder API, with confirmation |
| Xcode DerivedData | ~/Library/Developer/Xcode/DerivedData | safe | Move to Trash |
| Xcode iOS DeviceSupport | ~/Library/Developer/Xcode/iOS DeviceSupport | safe | Move to Trash (re-downloaded when needed) |
| Xcode Archives | ~/Library/Developer/Xcode/Archives | review | Reveal, per-archive delete |
| iOS Simulators | ~/Library/Developer/CoreSimulator | review | Show `xcrun simctl delete unavailable` |
| iOS device backups | ~/Library/Application Support/MobileSync/Backup | review | Reveal, per-backup delete |
| Docker disk image | ~/Library/Containers/com.docker.docker/Data/vms | careful | Show `docker system prune`; never trash the file directly |
| VM images | ~/Parallels, ~/Virtual Machines.localized, ~/Library/Containers/com.utmapp.UTM | review | Reveal only |
| Package caches | ~/Library/Caches/Homebrew, ~/.npm, ~/.cache/pip, ~/.cargo/registry, ~/.gradle/caches, pnpm and yarn stores | safe | Move to Trash, or show tool-specific cleanup command |
| ML model caches | ~/.cache/huggingface, ~/.ollama/models | review | Reveal, per-model delete |
| Android SDK and AVDs | ~/Library/Android/sdk, ~/.android/avd | review | Reveal only |
| node_modules and build outputs | any node_modules, target, build, .venv directory over 200 MB | review | List all, sorted by size and by project last-modified date |
| User caches | ~/Library/Caches/* (per subfolder) | safe | Move to Trash |
| Logs | ~/Library/Logs, /Library/Logs | safe | Move to Trash |
| Downloads | ~/Downloads: files over 500 MB, plus .dmg, .pkg, .zip installers | review | Reveal, move to Trash |
| Mail and Messages | ~/Library/Mail, ~/Library/Messages/Attachments | careful | Reveal only |
| Photos library | ~/Pictures/*.photoslibrary | careful | Reveal only; never delete from this app |
| Swap and sleep image | /private/var/vm | careful | Display only, no action |

### Per-app totals
- For every app in /Applications and ~/Applications, read CFBundleIdentifier from Info.plist and sum: the bundle, ~/Library/Application Support/<name or bundle id>, ~/Library/Caches/<bundle id>, ~/Library/Containers/<bundle id>, matching ~/Library/Group Containers/*, and ~/Library/Logs/<name>.
- Ranked Apps list with bundle size and support-data size as separate columns. Flag any app whose support data > 2x its bundle size.

### Generic outlier detectors
- Large folders: any directory holding > 3% of used disk space that no rule or app already covers. Show its top-level path, not every child.
- Large stale files: files > 500 MB (configurable) not accessed for 12+ months (access time, fallback mod time).
- Fast growers: compare against the cached previous scan; flag folders that grew > 1 GB.
- Duplicates (stretch): files > 50 MB, group by size, then partial hash (head/middle/tail), confirm with full hash. On demand only.

### Hidden space
unaccounted = volumeUsed - scannedTotal, broken down into: local Time Machine snapshots (`tmutil listlocalsnapshots /`), purgeable space (volumeAvailableCapacityForImportantUsage vs plain free), permission-blocked folders, remainder labeled "APFS clones, system volumes and metadata". Shown as its own slice and its own insight.

### Ranking
Sort by bytes descending, safe items first when sizes are within 20% of each other. Header total: "Up to X GB reclaimable" from safe items only.

## 7. UI specification
Single-window SwiftUI app, three regions. Insights list is the default landing view.
1. Sidebar: Insights (default), Apps, Largest Files, Largest Folders, Hidden Space, Volumes picker. Disk usage bar at top: used, free, purgeable.
2. Main pane: Insights = ranked cards. Folders = sunburst with breadcrumb. Apps and Largest Files = sortable tables.
3. Inspector: full path, size (allocated and logical), % of parent and of disk, file count, modified and last-accessed dates, risk label, action buttons.

### Sunburst
- SwiftUI Canvas (or Core Graphics), not one view per segment. Smooth with 5,000 visible arcs.
- Center circle shows current folder name and size; click navigates up.
- At most 4 rings deep; merge segments < 0.5% of the ring into "other".
- Hover highlights + updates inspector. Click drills in. Double-click opens in Finder. Space = Quick Look.
- Color by category (apps, media, developer, system, caches, other); same palette in sidebar and lists.

### Insight cards
- Title, size, one-line explanation, risk badge, buttons (Reveal in Finder, Move to Trash, or Copy command).
- Header "Up to X GB reclaimable (safe items only)".
- Cards expand to show the top 10 child items with sizes.

### Scan experience
- Cached result immediately on launch, subtle "Updating..." indicator while refreshing.
- During a full scan: progress bar (bytes found vs volume used), live top-5 list, sunburst fills in.
- Menu commands: cancel scan, force full rescan.

### Other
- Native look: sidebar vibrancy, system fonts, light/dark, VoiceOver labels on list rows.
- Keyboard: arrows move through lists, Return drills in, Cmd-Delete trashes (with confirmation), Cmd-R rescans the selection.

## 8. Actions and safety
Remove files only on explicit user request, one action at a time, only through the Trash.

Allowed actions:
- Reveal in Finder: NSWorkspace.activateFileViewerSelecting.
- Quick Look: QLPreviewPanel.
- Move to Trash: FileManager.trashItem(at:resultingItemURL:). Never removeItem, rm, or any permanent delete.
- Empty Trash: only for the Trash insight, behind confirmation showing total size and item count.
- Copy command: copies a cleanup command to the clipboard. The app never executes it.
- Delete local snapshot: runs `tmutil deletelocalsnapshots <date>` after confirmation; if admin needed, show the command to copy instead.

Safety rules:
1. Protected paths: refuse any action on /System, /usr, /bin, /sbin, /private, /Library (top level), /Applications itself, the home folder itself, ~/Library itself. Single apps inside /Applications may be trashed.
2. Risk gating: safe = one confirmation; review = show item list + size, confirmation repeats the item name; careful = no delete button, only Reveal.
3. Open-file check: before trashing an app or cache, check NSRunningApplication and warn.
4. Undo: toast with Undo after each Trash action, moves back using resultingItemURL.
5. Action log: append (time, path, size, result) to ~/Library/Logs/<AppName>/actions.log.
6. Dry-run mode: Settings toggle; every action only prints what it would do. Default ON for first launch.

## 9. Permissions and privacy
- Detect Full Disk Access by listing ~/Library/Safari or ~/Library/Mail; permission error = missing.
- If missing: first-run sheet + button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Still allow scan without access, with persistent banner "Results are incomplete: N folders could not be read" + blocked path list.
- Unsandboxed, no special entitlements, no admin/root, no privileged helper.
- Read only metadata; never file contents (except on-demand duplicate finder). No network access at all. Cache and log stay local.

## 10. Milestones, testing and acceptance
| # | Milestone | Exit criteria |
|---|---|---|
| 1 | Fast scanner (CLI or minimal window) | Full scan of / with getattrlistbulk, parallel walk, hard-link dedupe, blocked-folder list. Prints top 20 folders. Under 30 s on the dev machine. |
| 2 | Insight engine and Insights list | Rule table and per-app totals, ranked cards with sizes and risk labels, Reveal in Finder. First version that solves the problem. |
| 3 | Safe actions | Move to Trash with confirmation, Undo toast, protected-path rules, action log, dry-run mode. |
| 4 | Sunburst and browsing | Canvas sunburst, breadcrumb, inspector, Quick Look, Largest Files and Apps tables. |
| 5 | Cache and incremental refresh | Persisted scan at launch, FSEvents partial rescan, subtree rescan after deletes. |
| 6 | Hidden space and polish | Snapshots, purgeable, unaccounted breakdown, FDA onboarding, stale-file and fast-grower insights. |
| 7 | Stretch | Duplicate finder, menu bar gauge, Markdown export. |

Testing:
- Accuracy: compare folder totals against `du -sk` and Finder Get Info for >= 10 folders incl. one with hard links. Differences > 1% explained in a code comment or README.
- Fixture tests: generator builds a synthetic tree (nested dirs, hard links, symlink loops, sparse files, unreadable dirs) and asserts exact totals.
- Performance: benchmark target printing scan time, node count, peak memory. Record in README after each milestone.
- Safety tests: protected paths refused, careful items never expose delete, no code path calls a permanent delete.
- Manual: with/without FDA, with external drive, while disk is busy.

Acceptance:
1. First-time user lands on ranked Insights within 30 s of launch; relaunch shows cached results in < 1 s.
2. Top 10 items match manual digging (Xcode data, Docker, caches, large apps), sizes within 1% of du.
3. Total scanned + hidden space equals volume's reported used space (gap explained).
4. No file is ever permanently deleted; every removal can be undone from the Trash.
5. Zero network connections.

Open questions (defaults assumed): ad-hoc signed local build; UI only but scanner kept as separate package (CLI can be added later); include all rules, hide ones whose paths don't exist.
