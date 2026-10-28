import Foundation

/// Data-driven description of a known space hog. Paths are home-relative unless they use
/// `.absolute`; the engine verifies each path exists in the scanned tree.
public struct Rule: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var patterns: [PathPattern]
    public var risk: Risk
    public var action: SuggestedAction
    public var minBytes: UInt64
    public var category: Category

    public init(
        id: String,
        title: String,
        detail: String,
        patterns: [PathPattern],
        risk: Risk,
        action: SuggestedAction,
        minBytes: UInt64 = 200 * 1024 * 1024,
        category: Category = .other
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.patterns = patterns
        self.risk = risk
        self.action = action
        self.minBytes = minBytes
        self.category = category
    }
}

/// How a rule finds the nodes it is about.
public enum PathPattern: Sendable, Hashable {
    /// A single directory below the home directory, e.g. `Library/Developer/Xcode/DerivedData`.
    case home(String)
    /// A single absolute directory, e.g. `/Library/Logs`.
    case absolute(String)
    /// Every immediate child directory of a home-relative directory, e.g. `Library/Caches`.
    case homeGlobChildren(String)
    /// Immediate children of a home-relative directory whose last component matches a glob,
    /// e.g. `Pictures/*.photoslibrary`.
    case homeGlob(String)
    /// Every directory with one of these names, without descending into a match.
    case anyDirectoryNamed([String])
    /// Large files and installers directly or indirectly inside `~/Downloads`.
    case downloads
}

/// The full rule table from SPEC section 6.
public enum RuleTable {
    private static let defaultMinBytes: UInt64 = 200 * 1024 * 1024

    public static let all: [Rule] = [
        Rule(
            id: "trash",
            title: "Trash",
            detail: "Items you already moved to the Trash. Open the Trash in Finder and empty it yourself; this app never deletes permanently.",
            patterns: [.home(".Trash")],
            risk: .safe,
            action: .revealOnly,
            category: .trash
        ),
        Rule(
            id: "xcode.derivedData",
            title: "Xcode DerivedData",
            detail: "Build products and indexes Xcode regenerates on the next build. Safe to move to the Trash.",
            patterns: [.home("Library/Developer/Xcode/DerivedData")],
            risk: .safe,
            action: .trash,
            category: .developer
        ),
        Rule(
            id: "xcode.deviceSupport",
            title: "Xcode iOS DeviceSupport",
            detail: "Debug symbols for iOS versions you synced. Xcode downloads them again when needed.",
            patterns: [.home("Library/Developer/Xcode/iOS DeviceSupport")],
            risk: .safe,
            action: .trash,
            category: .developer
        ),
        Rule(
            id: "xcode.archives",
            title: "Xcode Archives",
            detail: "Archived builds and their dSYMs. Keep the ones you may resubmit; review archive by archive.",
            patterns: [.home("Library/Developer/Xcode/Archives")],
            risk: .review,
            action: .revealOnly,
            category: .developer
        ),
        Rule(
            id: "xcode.simulators",
            title: "iOS Simulators",
            detail: "Simulator runtimes and device data. Remove runtimes for iOS versions you no longer test with.",
            patterns: [.home("Library/Developer/CoreSimulator")],
            risk: .review,
            action: .copyCommand("xcrun simctl delete unavailable"),
            category: .developer
        ),
        Rule(
            id: "ios.backups",
            title: "iPhone and iPad backups",
            detail: "Local device backups made by Finder. Review the list and remove backups you no longer need.",
            patterns: [.home("Library/Application Support/MobileSync/Backup")],
            risk: .review,
            action: .revealOnly,
            category: .documents
        ),
        Rule(
            id: "docker.diskImage",
            title: "Docker disk image",
            detail: "Images and containers stored inside Docker's virtual disk. Let Docker reclaim them instead of moving the disk image.",
            patterns: [.home("Library/Containers/com.docker.docker/Data/vms")],
            risk: .careful,
            action: .copyCommand("docker system prune"),
            category: .developer
        ),
        Rule(
            id: "vms",
            title: "Virtual machine images",
            detail: "Parallels, VMware or UTM virtual machines. Review them in Finder; deleting a VM loses its contents.",
            patterns: [
                .home("Parallels"),
                .home("Virtual Machines.localized"),
                .home("Library/Containers/com.utmapp.UTM"),
            ],
            risk: .review,
            action: .revealOnly,
            category: .developer
        ),
        Rule(
            id: "packageCache.homebrew",
            title: "Homebrew cache",
            detail: "Downloaded formula bottles and source archives. Homebrew can remove the ones no longer needed.",
            patterns: [.home("Library/Caches/Homebrew")],
            risk: .safe,
            action: .copyCommand("brew cleanup"),
            category: .developer
        ),
        Rule(
            id: "packageCache.npm",
            title: "npm cache",
            detail: "Downloaded npm packages. npm can rebuild its cache from the registry.",
            patterns: [.home(".npm")],
            risk: .safe,
            action: .copyCommand("npm cache clean --force"),
            category: .developer
        ),
        Rule(
            id: "packageCache.pip",
            title: "pip cache",
            detail: "Downloaded Python wheels and source distributions. pip can download them again.",
            patterns: [.home(".cache/pip")],
            risk: .safe,
            action: .copyCommand("pip cache purge"),
            category: .developer
        ),
        Rule(
            id: "packageCache.cargo",
            title: "Cargo registry cache",
            detail: "Downloaded Rust crates. Cargo re-downloads anything a build needs.",
            patterns: [.home(".cargo/registry")],
            risk: .safe,
            action: .trash,
            category: .developer
        ),
        Rule(
            id: "packageCache.gradle",
            title: "Gradle cache",
            detail: "Downloaded Gradle distributions and dependencies. Gradle re-downloads them on demand.",
            patterns: [.home(".gradle/caches")],
            risk: .safe,
            action: .trash,
            category: .developer
        ),
        Rule(
            id: "packageCache.pnpm",
            title: "pnpm store",
            detail: "Content-addressed pnpm package store. Pruning removes packages no project references.",
            patterns: [
                .home("Library/pnpm/store"),
                .home(".local/share/pnpm/store"),
            ],
            risk: .safe,
            action: .copyCommand("pnpm store prune"),
            category: .developer
        ),
        Rule(
            id: "packageCache.yarn",
            title: "Yarn cache",
            detail: "Downloaded Yarn packages. Yarn can fetch them again when a project needs them.",
            patterns: [
                .home("Library/Caches/Yarn"),
                .home(".cache/yarn"),
            ],
            risk: .safe,
            action: .copyCommand("yarn cache clean"),
            category: .developer
        ),
        Rule(
            id: "mlCaches",
            title: "Machine-learning model caches",
            detail: "Downloaded models for Hugging Face and Ollama. Review them; large models are quick to re-download but slow to lose mid-project.",
            patterns: [
                .home(".cache/huggingface"),
                .home(".ollama/models"),
            ],
            risk: .review,
            action: .revealOnly,
            category: .developer
        ),
        Rule(
            id: "android.sdk",
            title: "Android SDK and emulators",
            detail: "Android SDK packages and emulator images. Review them in Finder; they are slow to reinstall.",
            patterns: [
                .home("Library/Android/sdk"),
                .home(".android/avd"),
            ],
            risk: .review,
            action: .revealOnly,
            category: .developer
        ),
        Rule(
            id: "developer.buildOutputs",
            title: "Dependency and build output folders",
            detail: "node_modules, target, build and .venv folders. Reinstalling dependencies recreates them; review by project.",
            patterns: [.anyDirectoryNamed(["node_modules", "target", "build", ".venv"])],
            risk: .review,
            action: .revealOnly,
            category: .developer
        ),
        Rule(
            id: "userCaches",
            title: "User caches",
            detail: "Per-application caches in ~/Library/Caches. Apps rebuild them as needed.",
            patterns: [.homeGlobChildren("Library/Caches")],
            risk: .safe,
            action: .trash,
            category: .caches
        ),
        Rule(
            id: "logs",
            title: "Logs",
            detail: "Application and system logs. Safe to move to the Trash; new logs are written as needed.",
            patterns: [
                .home("Library/Logs"),
                .absolute("/Library/Logs"),
            ],
            risk: .safe,
            action: .trash,
            category: .system
        ),
        Rule(
            id: "downloads",
            title: "Large downloads and installers",
            detail: "Files over 500 MB plus .dmg, .pkg and .zip installers in ~/Downloads. Review before moving them to the Trash.",
            patterns: [.downloads],
            risk: .review,
            action: .trash,
            category: .documents
        ),
        Rule(
            id: "mail",
            title: "Mail and Messages attachments",
            detail: "Local mailboxes and message attachments. Delete from inside Mail or Messages; never delete these folders directly.",
            patterns: [
                .home("Library/Mail"),
                .home("Library/Messages/Attachments"),
            ],
            risk: .careful,
            action: .revealOnly,
            category: .documents
        ),
        Rule(
            id: "photosLibrary",
            title: "Photos library",
            detail: "A Photos library. Manage it from Photos; deleting it from Finder loses the library and its edits.",
            patterns: [.homeGlob("Pictures/*.photoslibrary")],
            risk: .careful,
            action: .revealOnly,
            category: .media
        ),
        Rule(
            id: "swap",
            title: "Swap and sleep image",
            detail: "macOS swap files and the sleep image. Shown for information only; macOS manages this space.",
            patterns: [.absolute("/private/var/vm")],
            risk: .careful,
            action: .displayOnly,
            category: .system
        ),
    ]

    /// Kept explicit so the default does not drift from the SPEC.
    public static var defaultMinimumBytes: UInt64 { defaultMinBytes }
}
