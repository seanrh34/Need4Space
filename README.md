# Need4Space

Native macOS (15+) disk usage analyzer: fast getattrlistbulk scanner, insight engine that tells you
what to look at first, and safe Trash-only actions. Personal tool; see `docs/SPEC.md` and `docs/PLAN.md`.

## Build (on a Mac with Xcode 16+ / Swift 6)
```
swift build
swift test
swift run -c release n4s-scan /        # milestone 1 benchmark
```

## Benchmarks
_Recorded after each milestone._

## How to verify on a Mac (M1 scanner + n4s-scan)

Requires macOS 15 and Xcode 16 (Swift 6). Run from the package root.

1. Build and run the full unit/fixture suite (parser tests, real temp-dir fixtures,
   hard links, symlink loops, sparse files, blocked dirs, 10k-entry dir, cancellation):

   ```
   swift build
   swift test
   ```

2. Scan the startup disk (uses 2x activeProcessorCount worker threads, 256 KB per-worker
   buffers, `openat` + `getattrlistbulk` only — never `FileManager.enumerator` or per-file
   stat). Progress lines go to stderr; the report goes to stdout:

   ```
   swift run -c release n4s-scan /
   swift run -c release n4s-scan / --top 30
   swift run -c release n4s-scan /Users/sean --threads 8 --json > /tmp/scan.json
   ```

   What to expect: elapsed time; nodes/dirs/files (file count includes files hidden inside
   "(N small files)" groups); allocated vs logical bytes; hard links deduplicated; mount
   points skipped (with paths); blocked count + first 50 blocked paths; peak RSS
   (`getrusage` `ru_maxrss`, bytes on macOS); top N folders = directories at depth 1...4 by
   allocated size; volume total/used/free/purgeable/snapshot count.

3. Accuracy against `du` (compares `du -sk` with the scanner's JSON totals per directory):

   ```
   scripts/accuracy.sh /Users /Applications ~/Library ~/Downloads
   ```

   Known, expected small differences: `du` counts each directory's own inode (4 KB on APFS)
   and rounds to 1K blocks; the scanner ignores directory inodes (like `du` ignores them in
   subtotals, roughly) and uses `ATTR_FILE_ALLOCSIZE` (`st_blocks * 512`). Hard links are
   counted once by both. Differences above ~1-2% on inode-heavy trees are worth a look.

4. Things that need a real `/` scan and cannot be unit-tested here (verify by eye in the
   JSON output):
   - `mountPointsSkipped` > 0 and `skippedMountPaths` listing firmlinked/mounted volumes
     (e.g. `/System/Volumes/Update`); `/Volumes`, `/dev`, `/.vol`, `/System/Volumes` are
     skipped by path and do not appear in the tree.
   - `/private/var/vm` appears as a `vm` directory under `/private/var` with its true size
     (it lives on the VM volume; the scanner crosses the devid boundary only there).
   - `blocked` paths under `/System` or `/private/var/db` when Full Disk Access is absent;
     run with FDA granted to compare.
   - `usedBytes` (volume) vs `bytesAllocated` (scanned): the gap is expected (purgeable,
     snapshots, other container volumes, APFS metadata), not an error.

