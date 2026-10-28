import Foundation

public typealias NodeID = Int32

public enum NodeKind: UInt8, Sendable, Codable {
    case file
    case directory
    /// A directory treated as a single item in the UI (.app, .photoslibrary, ...). Still scanned into.
    case bundle
    case symlink
    /// Could not be read (EPERM/EACCES). Size is unknown and recorded as 0.
    case blocked
    /// Synthetic node: all files below the small-file threshold in one directory.
    case smallFilesGroup
    /// Anything else (sockets, devices, mount points that were not descended).
    case other

    public var isContainer: Bool { self == .directory || self == .bundle }
}

/// Flat struct-of-arrays tree. Index = node id. Root is node 0 once added.
/// Children are a singly linked list (firstChild / nextSibling), newest first.
/// Directory sizes and file counts are aggregates of their subtree.
public struct ScanTree: Sendable {
    public static let none: NodeID = -1

    public var parent: [Int32] = []
    public var firstChild: [Int32] = []
    public var nextSibling: [Int32] = []
    public var nameOffset: [UInt32] = []
    public var nameLength: [UInt16] = []
    public var kind: [NodeKind] = []
    public var allocSize: [UInt64] = []
    public var logicalSize: [UInt64] = []
    public var fileCount: [UInt32] = []
    public var modTime: [Int64] = []
    /// 0 if unknown.
    public var accessTime: [Int64] = []
    /// UTF-8 bytes of all names, back to back.
    public var nameArena: [UInt8] = []

    /// Absolute path of node 0 (e.g. "/" or "/Volumes/External").
    public var rootPath: String

    public init(rootPath: String, reserveCapacity: Int = 0) {
        self.rootPath = rootPath
        if reserveCapacity > 0 { reserve(reserveCapacity) }
    }

    public var count: Int { parent.count }
    public var root: NodeID { count > 0 ? 0 : ScanTree.none }

    public mutating func reserve(_ n: Int) {
        parent.reserveCapacity(n); firstChild.reserveCapacity(n); nextSibling.reserveCapacity(n)
        nameOffset.reserveCapacity(n); nameLength.reserveCapacity(n); kind.reserveCapacity(n)
        allocSize.reserveCapacity(n); logicalSize.reserveCapacity(n); fileCount.reserveCapacity(n)
        modTime.reserveCapacity(n); accessTime.reserveCapacity(n); nameArena.reserveCapacity(n * 16)
    }

    /// Appends a node and links it as the first child of `parent` (pass `ScanTree.none` for the root).
    /// Sizes are NOT propagated to ancestors; the scanner aggregates bottom-up.
    @discardableResult
    public mutating func addNode<Name: Collection<UInt8>>(
        nameBytes: Name,
        kind: NodeKind,
        parent: NodeID,
        allocSize: UInt64 = 0,
        logicalSize: UInt64 = 0,
        fileCount: UInt32 = 0,
        modTime: Int64 = 0,
        accessTime: Int64 = 0
    ) -> NodeID {
        let id = NodeID(count)
        self.nameOffset.append(UInt32(nameArena.count))
        self.nameLength.append(UInt16(clamping: nameBytes.count))
        self.nameArena.append(contentsOf: nameBytes.prefix(Int(UInt16.max)))
        self.parent.append(parent)
        self.firstChild.append(ScanTree.none)
        if parent >= 0 {
            self.nextSibling.append(firstChild[Int(parent)])
            self.firstChild[Int(parent)] = id
        } else {
            self.nextSibling.append(ScanTree.none)
        }
        self.kind.append(kind)
        self.allocSize.append(allocSize)
        self.logicalSize.append(logicalSize)
        self.fileCount.append(fileCount)
        self.modTime.append(modTime)
        self.accessTime.append(accessTime)
        return id
    }

    @discardableResult
    public mutating func addNode(
        name: String, kind: NodeKind, parent: NodeID,
        allocSize: UInt64 = 0, logicalSize: UInt64 = 0, fileCount: UInt32 = 0,
        modTime: Int64 = 0, accessTime: Int64 = 0
    ) -> NodeID {
        addNode(nameBytes: Array(name.utf8), kind: kind, parent: parent,
                allocSize: allocSize, logicalSize: logicalSize, fileCount: fileCount,
                modTime: modTime, accessTime: accessTime)
    }

    // MARK: Queries

    public func name(_ id: NodeID) -> String {
        let start = Int(nameOffset[Int(id)])
        let len = Int(nameLength[Int(id)])
        return String(decoding: nameArena[start..<start + len], as: UTF8.self)
    }

    /// Compares a node's name with UTF-8 bytes without allocating a String.
    public func nameEquals(_ id: NodeID, _ bytes: some Collection<UInt8>) -> Bool {
        let start = Int(nameOffset[Int(id)])
        let len = Int(nameLength[Int(id)])
        guard len == bytes.count else { return false }
        return nameArena[start..<start + len].elementsEqual(bytes)
    }

    public func children(_ id: NodeID) -> ChildSequence { ChildSequence(tree: self, first: firstChild[Int(id)]) }

    public func child(of id: NodeID, named name: String) -> NodeID? {
        let bytes = Array(name.utf8)
        var c = firstChild[Int(id)]
        while c >= 0 {
            if nameEquals(c, bytes) { return c }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    /// Absolute path of a node. Root returns `rootPath`.
    public func path(_ id: NodeID) -> String {
        var parts: [String] = []
        var cur = id
        while cur > 0 {
            parts.append(name(cur))
            cur = parent[Int(cur)]
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return parts.isEmpty ? rootPath : base + "/" + parts.reversed().joined(separator: "/")
    }

    /// Looks up an absolute path by walking child names from the root. Returns nil if absent
    /// or outside `rootPath`.
    public func node(atPath absolutePath: String) -> NodeID? {
        guard count > 0 else { return nil }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let path = absolutePath.count > 1 && absolutePath.hasSuffix("/") ? String(absolutePath.dropLast()) : absolutePath
        if path == rootPath || path == base { return 0 }
        guard path.hasPrefix(base + "/") else { return nil }
        var cur: NodeID = 0
        for comp in path.dropFirst(base.count + 1).split(separator: "/") {
            guard let next = child(of: cur, named: String(comp)) else { return nil }
            cur = next
        }
        return cur
    }

    public func depth(_ id: NodeID) -> Int {
        var d = 0
        var cur = id
        while cur > 0 { d += 1; cur = parent[Int(cur)] }
        return d
    }

    /// True if `ancestor` is `id` or one of its ancestors.
    public func isAncestor(_ ancestor: NodeID, of id: NodeID) -> Bool {
        var cur = id
        while cur >= 0 {
            if cur == ancestor { return true }
            cur = parent[Int(cur)]
        }
        return false
    }

    public struct ChildSequence: Sequence, IteratorProtocol {
        let tree: ScanTree
        var next_: NodeID
        init(tree: ScanTree, first: NodeID) { self.tree = tree; self.next_ = first }
        public mutating func next() -> NodeID? {
            guard next_ >= 0 else { return nil }
            let cur = next_
            next_ = tree.nextSibling[Int(cur)]
            return cur
        }
    }
}
