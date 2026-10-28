import Foundation
import ScannerKit

/// Compact description of a fixture tree. `ScanTree.addNode` does not aggregate directory sizes,
/// so `FixtureTree.build` sums sizes, logical sizes and file counts bottom-up after insertion.
struct FixtureNode {
    enum Kind {
        case dir
        case bundle
        case file
        case symlink
        case blocked
        case smallFiles
    }

    var name: String
    var kind: Kind
    var children: [FixtureNode]
    var bytes: UInt64
    var fileCount: UInt32
    var modTime: Int64
    var accessTime: Int64

    private init(
        name: String,
        kind: Kind,
        children: [FixtureNode] = [],
        bytes: UInt64 = 0,
        fileCount: UInt32 = 0,
        modTime: Int64 = 0,
        accessTime: Int64 = 0
    ) {
        self.name = name
        self.kind = kind
        self.children = children
        self.bytes = bytes
        self.fileCount = fileCount
        self.modTime = modTime
        self.accessTime = accessTime
    }

    static func dir(
        _ name: String,
        _ children: [FixtureNode] = [],
        modTime: Int64 = 0,
        accessTime: Int64 = 0
    ) -> FixtureNode {
        FixtureNode(
            name: name,
            kind: .dir,
            children: children,
            modTime: modTime,
            accessTime: accessTime
        )
    }

    static func bundle(
        _ name: String,
        _ children: [FixtureNode] = [],
        modTime: Int64 = 0
    ) -> FixtureNode {
        FixtureNode(name: name, kind: .bundle, children: children, modTime: modTime)
    }

    static func file(
        _ name: String,
        _ bytes: UInt64,
        modTime: Int64 = 0,
        accessTime: Int64 = 0
    ) -> FixtureNode {
        FixtureNode(
            name: name,
            kind: .file,
            bytes: bytes,
            fileCount: 1,
            modTime: modTime,
            accessTime: accessTime
        )
    }

    static func symlink(_ name: String, bytes: UInt64 = 0) -> FixtureNode {
        FixtureNode(name: name, kind: .symlink, bytes: bytes)
    }

    static func blocked(_ name: String) -> FixtureNode {
        FixtureNode(name: name, kind: .blocked)
    }

    static func smallFiles(_ name: String, count: UInt32, bytes: UInt64) -> FixtureNode {
        FixtureNode(name: name, kind: .smallFiles, bytes: bytes, fileCount: count)
    }
}

enum FixtureTree {
    static let defaultRootPath = "/Users/tester"

    static func build(rootPath: String = defaultRootPath, _ nodes: [FixtureNode]) -> ScanTree {
        var tree = ScanTree(rootPath: rootPath)
        _ = tree.addNode(name: "", kind: .directory, parent: ScanTree.none)
        for node in nodes {
            _ = append(node, parent: 0, to: &tree)
        }
        aggregate(&tree)
        return tree
    }

    @discardableResult
    static func append(_ node: FixtureNode, parent: NodeID, to tree: inout ScanTree) -> NodeID {
        switch node.kind {
        case .dir:
            let id = tree.addNode(
                name: node.name,
                kind: .directory,
                parent: parent,
                modTime: node.modTime,
                accessTime: node.accessTime
            )
            for child in node.children { _ = append(child, parent: id, to: &tree) }
            return id

        case .bundle:
            let id = tree.addNode(
                name: node.name,
                kind: .bundle,
                parent: parent,
                modTime: node.modTime,
                accessTime: node.accessTime
            )
            for child in node.children { _ = append(child, parent: id, to: &tree) }
            return id

        case .file:
            return tree.addNode(
                name: node.name,
                kind: .file,
                parent: parent,
                allocSize: node.bytes,
                logicalSize: node.bytes,
                fileCount: 1,
                modTime: node.modTime,
                accessTime: node.accessTime
            )

        case .symlink:
            return tree.addNode(
                name: node.name,
                kind: .symlink,
                parent: parent,
                allocSize: node.bytes
            )

        case .blocked:
            return tree.addNode(name: node.name, kind: .blocked, parent: parent)

        case .smallFiles:
            return tree.addNode(
                name: node.name,
                kind: .smallFilesGroup,
                parent: parent,
                allocSize: node.bytes,
                logicalSize: node.bytes,
                fileCount: node.fileCount,
                modTime: node.modTime,
                accessTime: node.accessTime
            )
        }
    }

    static func aggregate(_ tree: inout ScanTree) {
        guard tree.count > 0 else { return }
        var index = tree.count - 1
        while index >= 0 {
            if tree.kind[index].isContainer {
                var bytes: UInt64 = 0
                var logical: UInt64 = 0
                var files: UInt32 = 0
                var latest = tree.modTime[index]
                var child = tree.firstChild[index]
                while child >= 0 {
                    bytes += tree.allocSize[Int(child)]
                    logical += tree.logicalSize[Int(child)]
                    files &+= tree.fileCount[Int(child)]
                    if tree.modTime[Int(child)] > latest { latest = tree.modTime[Int(child)] }
                    child = tree.nextSibling[Int(child)]
                }
                tree.allocSize[index] = bytes
                tree.logicalSize[index] = logical
                tree.fileCount[index] = files
                tree.modTime[index] = latest
            }
            index -= 1
        }
    }
}

enum Size {
    static let mb: UInt64 = 1024 * 1024
    static let gb: UInt64 = 1024 * 1024 * 1024
}
