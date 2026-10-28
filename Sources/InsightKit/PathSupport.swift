import Foundation
import ScannerKit

/// String helpers for the handful of fixed paths rules resolve. Nothing here runs per node.
enum PathSupport {
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Joins a base directory and a relative path. Absolute relatives replace the base.
    static func join(_ base: String, _ relative: String) -> String {
        let b = normalize(base)
        var r = relative
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        if r == "/" { return "/" }
        if r.hasPrefix("/") { r.removeFirst() }
        if r.isEmpty { return b }
        if b == "/" { return "/" + r }
        return b + "/" + r
    }

    /// True if `path` equals `base` or is inside it (component-aware, so "/a/bc" is not under "/a/b").
    static func isUnder(_ path: String, _ base: String) -> Bool {
        let p = normalize(path)
        let b = normalize(base)
        if p == b { return true }
        if b == "/" { return p.hasPrefix("/") }
        return p.hasPrefix(b + "/")
    }
}

/// Minimal shell-style glob matching for last path components: `*`, `?`, case-insensitive.
enum GlobPattern {
    static func matches(pattern: String, name: String) -> Bool {
        let p = Array(pattern.utf8).map { lowercasedASCII($0) }
        let s = Array(name.utf8).map { lowercasedASCII($0) }
        if p.isEmpty { return s.isEmpty }

        var pi = 0
        var si = 0
        var starIndex = -1
        var starMatch = 0

        while si < s.count {
            if pi < p.count && (p[pi] == 63 || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == 42 {
                starIndex = pi
                starMatch = si
                pi += 1
            } else if starIndex >= 0 {
                pi = starIndex + 1
                starMatch += 1
                si = starMatch
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == 42 { pi += 1 }
        return pi == p.count
    }

    @inline(__always)
    static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte &+ 32 : byte
    }
}

// MARK: - Allocation-free name access

extension ScanTree {
    func nameStart(_ id: NodeID) -> Int { Int(nameOffset[Int(id)]) }
    func nameLen(_ id: NodeID) -> Int { Int(nameLength[Int(id)]) }

    func nameBytes(_ id: NodeID) -> ArraySlice<UInt8> {
        let start = nameStart(id)
        return nameArena[start..<start + nameLen(id)]
    }

    func nameEqualsIgnoringCase(_ id: NodeID, _ bytes: [UInt8]) -> Bool {
        let start = nameStart(id)
        let len = nameLen(id)
        guard len == bytes.count else { return false }
        var i = 0
        while i < len {
            if GlobPattern.lowercasedASCII(nameArena[start + i]) != GlobPattern.lowercasedASCII(bytes[i]) {
                return false
            }
            i += 1
        }
        return true
    }

    func nameEqualsAny(_ id: NodeID, _ candidates: [[UInt8]]) -> Bool {
        for candidate in candidates {
            if nameEqualsIgnoringCase(id, candidate) { return true }
        }
        return false
    }

    func nameHasSuffixIgnoringCase(_ id: NodeID, _ suffix: [UInt8]) -> Bool {
        let start = nameStart(id)
        let len = nameLen(id)
        guard suffix.count <= len else { return false }
        let offset = start + len - suffix.count
        var i = 0
        while i < suffix.count {
            if GlobPattern.lowercasedASCII(nameArena[offset + i]) != GlobPattern.lowercasedASCII(suffix[i]) {
                return false
            }
            i += 1
        }
        return true
    }

    func nameHasAnySuffixIgnoringCase(_ id: NodeID, _ suffixes: [[UInt8]]) -> Bool {
        for suffix in suffixes {
            if nameHasSuffixIgnoringCase(id, suffix) { return true }
        }
        return false
    }

    /// Looks up a child by exact UTF-8 name without allocating a String.
    func childNamed(_ parent: NodeID, bytes: [UInt8]) -> NodeID? {
        var child = firstChild[Int(parent)]
        while child >= 0 {
            if nameLen(child) == bytes.count {
                let start = nameStart(child)
                if nameArena[start..<start + bytes.count].elementsEqual(bytes) {
                    return child
                }
            }
            child = nextSibling[Int(child)]
        }
        return nil
    }

    /// Looks up the child of `parent` whose name equals the name of `id`. Used to match two trees
    /// (fast growers) without materialising paths.
    func childMatchingName(of parent: NodeID, nameOf id: NodeID) -> NodeID? {
        let wantedStart = nameStart(id)
        let wantedLen = nameLen(id)
        guard wantedLen > 0 else { return nil }
        let wanted = nameArena[wantedStart..<wantedStart + wantedLen]
        var child = firstChild[Int(parent)]
        while child >= 0 {
            if nameLen(child) == wantedLen {
                let start = nameStart(child)
                if nameArena[start..<start + wantedLen].elementsEqual(wanted) {
                    return child
                }
            }
            child = nextSibling[Int(child)]
        }
        return nil
    }
}
