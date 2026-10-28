#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Reads volume capacity information and local Time Machine snapshot names.
///
/// Per plan revision 1: usedBytes = volumeTotalCapacity - volumeAvailableCapacity (APFS
/// container-wide for `/`, what Finder shows). purgeableBytes = importantUsage - plain free,
/// clamped at 0 (it may include snapshot space; never shown as negative, revision 7).
public enum VolumeInfoReader {
    /// Reads capacity info for the volume mounted at `mountPath`. Returns nil when the
    /// resource values are unavailable (e.g. the path is not a mount point).
    public static func read(mountPath: String = "/") -> VolumeInfo? {
        let url = URL(fileURLWithPath: mountPath)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ])
        } catch {
            return nil
        }
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        let importantUsage = values.volumeAvailableCapacityForImportantUsage ?? available
        let used = max(0, Int64(total) - Int64(available))
        let purgeable = max(0, Int64(importantUsage) - Int64(available))
        return VolumeInfo(
            mountPath: mountPath,
            totalBytes: UInt64(max(0, Int64(total))),
            usedBytes: UInt64(used),
            freeBytes: UInt64(max(0, Int64(available))),
            purgeableBytes: UInt64(purgeable),
            snapshots: readLocalSnapshots(mountPath: mountPath))
    }

    /// Lists local Time Machine snapshots by running `/usr/bin/tmutil listlocalsnapshots <path>`
    /// via Process and parsing the printed names and dates. Any failure (missing binary,
    /// non-zero exit, unreadable output) yields an empty list.
    public static func readLocalSnapshots(mountPath: String = "/") -> [LocalSnapshot] {
        #if canImport(Darwin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", mountPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return parseSnapshotList(String(decoding: data, as: UTF8.self))
        #else
        return []
        #endif
    }

    /// Parses `tmutil listlocalsnapshots` output. Lines look like
    /// `com.apple.TimeMachine.2026-10-28-101500.local` (local time, format
    /// yyyy-MM-dd-HHmmss). Unknown lines are ignored.
    static func parseSnapshotList(_ output: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        var snapshots: [LocalSnapshot] = []
        for line in output.split(separator: "\n") {
            for token in line.split(separator: " ") {
                let name = String(token)
                guard name.hasPrefix("com.apple.TimeMachine."), name.hasSuffix(".local") else {
                    continue
                }
                let stamp = name.dropFirst("com.apple.TimeMachine.".count)
                    .dropLast(".local".count)
                snapshots.append(LocalSnapshot(name: name, date: formatter.date(from: String(stamp))))
            }
        }
        return snapshots
    }
}

/// Peak memory helpers (plan revision 12: the benchmark must report peak RSS).
public enum MemoryInfo {
    /// Peak resident set size of this process via getrusage(2). On macOS ru_maxrss is
    /// reported in bytes.
    public static func peakResidentBytes() -> UInt64 {
        #if canImport(Darwin)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(usage.ru_maxrss)
        #else
        return 0
        #endif
    }
}
