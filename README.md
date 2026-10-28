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

## How to verify on a Mac (InsightKit / M2a)
InsightKit is pure logic over `ScanTree`; it never reads the disk, so no Full Disk Access is needed
for these checks.

```
# 1. Build everything (Swift 6 / macOS 15 toolchain)
swift build

# 2. Run all tests, including the InsightKit fixtures
swift test

# 3. Run the 1M-node performance test in release mode (must report < 2 s)
swift test -c release --filter millionNodeEngineRunsWellUnderTwoSeconds

# 4. Confirm Sources/ has no permanent-delete API and no programmatic empty-Trash action
! grep -RInE 'removeItem\(|unlink\(|rmdir\(|unlinkat\(|"rm |emptyTrash' Sources/
```

Expected results:
- All tests green. InsightKit tests build trees with `FixtureTree` (which aggregates directory sizes
  bottom-up) and call `InsightEngine.run(tree:homePath:volume:blocked:apps:previous:now:)` directly.
- The release run of `millionNodeEngineRunsWellUnderTwoSeconds` reports a time well under 2 s; the
  debug variant uses a looser 10 s bound because debug Swift bounds-checks every array access.
- The Trash insight only offers "open in Finder" (PLAN revision 14); `SuggestedAction` has no
  programmatic-Trash-empty case.
