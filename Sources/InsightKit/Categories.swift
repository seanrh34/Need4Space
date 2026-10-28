import Foundation
import ScannerKit

extension Category {
    /// Classifies a node for colouring. Called on demand for visible nodes, never for every node
    /// during a scan, so materialising the path here is acceptable.
    public static func forNode(_ id: NodeID, in tree: ScanTree, homePath: String) -> Category {
        guard id >= 0, Int(id) < tree.count else { return .other }
        let home = PathSupport.normalize(homePath)
        let path = tree.path(id)

        if PathSupport.isUnder(path, PathSupport.join(home, ".Trash"))
            || PathSupport.isUnder(path, "/.Trashes") {
            return .trash
        }
        if PathSupport.isUnder(path, PathSupport.join(home, "Library/Caches"))
            || PathSupport.isUnder(path, "/Library/Caches")
            || PathSupport.isUnder(path, "/System/Library/Caches") {
            return .caches
        }
        if PathSupport.isUnder(path, PathSupport.join(home, "Library/Developer"))
            || PathSupport.isUnder(path, "/Library/Developer") {
            return .developer
        }
        if PathSupport.isUnder(path, "/Applications")
            || PathSupport.isUnder(path, PathSupport.join(home, "Applications")) {
            return .apps
        }
        if PathSupport.isUnder(path, "/System")
            || PathSupport.isUnder(path, "/Library")
            || PathSupport.isUnder(path, "/private")
            || PathSupport.isUnder(path, "/usr")
            || PathSupport.isUnder(path, "/bin")
            || PathSupport.isUnder(path, "/sbin")
            || PathSupport.isUnder(path, "/etc")
            || PathSupport.isUnder(path, "/var") {
            return .system
        }

        let name = tree.name(id).lowercased()

        if name.hasSuffix(".app") || name.hasSuffix(".appex") { return .apps }
        if name.hasSuffix(".photoslibrary") || name.hasSuffix(".photolibrary") { return .media }

        if name == "node_modules" || name == "target" || name == "build" || name == ".venv"
            || name == "deriveddata" || name.hasSuffix(".xcarchive") || name.hasSuffix(".dsym")
            || name.hasSuffix(".swiftpm") || name.hasSuffix(".build") {
            return .developer
        }

        if Category.mediaExtensions.contains(where: { name.hasSuffix($0) }) { return .media }
        if Category.developerExtensions.contains(where: { name.hasSuffix($0) }) { return .developer }
        if Category.documentExtensions.contains(where: { name.hasSuffix($0) }) { return .documents }

        if PathSupport.isUnder(path, PathSupport.join(home, "Documents"))
            || PathSupport.isUnder(path, PathSupport.join(home, "Desktop"))
            || PathSupport.isUnder(path, PathSupport.join(home, "Downloads"))
            || PathSupport.isUnder(path, PathSupport.join(home, "Pictures"))
            || PathSupport.isUnder(path, PathSupport.join(home, "Movies"))
            || PathSupport.isUnder(path, PathSupport.join(home, "Music")) {
            return .documents
        }

        return .other
    }

    private static let mediaExtensions: [String] = [
        ".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".tiff", ".tif", ".raw", ".dng",
        ".webp", ".bmp", ".psd", ".mp4", ".mov", ".m4v", ".mkv", ".avi", ".wmv", ".flv",
        ".mp3", ".m4a", ".aac", ".wav", ".flac", ".aiff", ".ogg", ".opus",
    ]

    private static let developerExtensions: [String] = [
        ".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp", ".hpp", ".js", ".ts", ".tsx",
        ".jsx", ".py", ".rb", ".go", ".rs", ".java", ".kt", ".sh", ".dylib", ".a",
        ".framework", ".xcarchive", ".ipa", ".apk", ".class", ".o", ".swiftmodule",
    ]

    private static let documentExtensions: [String] = [
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pages", ".numbers",
        ".key", ".txt", ".rtf", ".md", ".csv", ".epub", ".zip", ".dmg", ".pkg",
    ]
}
