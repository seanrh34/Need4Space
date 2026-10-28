import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let home = FixtureTree.defaultRootPath
private let mb = Size.mb
private let gb = Size.gb

private func insights(_ tree: ScanTree, homePath: String = home) -> [Insight] {
    RuleEngine().evaluate(tree: tree, homePath: homePath).insights
}

@Test func ruleTableIsWellFormed() {
    #expect(RuleTable.all.count >= 20)
    let ids = RuleTable.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for rule in RuleTable.all {
        #expect(!rule.id.isEmpty)
        #expect(!rule.title.isEmpty)
        #expect(!rule.detail.isEmpty)
        #expect(!rule.patterns.isEmpty)
        #expect(rule.minBytes > 0)
    }
}

@Test func fixedPathRuleMatches() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [.file("Build", 300 * mb)]),
                ]),
            ]),
        ]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "xcode.derivedData" })
    #expect(insight.bytes == 300 * mb)
    #expect(insight.risk == .safe)
    #expect(insight.action == .trash)
    #expect(insight.category == .developer)
    #expect(insight.paths.first?.path == home + "/Library/Developer/Xcode/DerivedData")
    #expect(insight.nodeIDs.count == 1)
}

@Test func trashOnlyRevealsInFinder() throws {
    let tree = FixtureTree.build([
        .dir(".Trash", [.file("old.zip", 250 * mb)]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "trash" })
    #expect(insight.action == .revealOnly)
    #expect(insight.risk == .safe)
    #expect(insight.category == .trash)
}

@Test func missingPathsAreHidden() {
    let tree = FixtureTree.build([.dir("Documents", [.file("notes.txt", 500 * gb)])])
    #expect(insights(tree).isEmpty)
}

@Test func underMinimumIsHidden() {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [.file("Build", 199 * mb)]),
                ]),
            ]),
        ]),
    ])
    #expect(insights(tree).contains { $0.id == "xcode.derivedData" } == false)
}

@Test func exactMinimumIsShown() {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [.file("Build", 200 * mb)]),
                ]),
            ]),
        ]),
    ])
    #expect(insights(tree).contains { $0.id == "xcode.derivedData" })
}

@Test func absolutePatternMatchesOutsideHome() throws {
    let tree = FixtureTree.build(rootPath: "/", [
        .dir("Library", [
            .dir("Logs", [.file("system.log", 300 * mb)]),
        ]),
        .dir("Users", [.dir("tester", [])]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "logs" })
    #expect(insight.bytes == 300 * mb)
    #expect(insight.paths.contains { $0.path == "/Library/Logs" })
}

@Test func perSubfolderChildrenAreAggregated() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Caches", [
                .dir("com.example.a", [.file("f", 150 * mb)]),
                .dir("com.example.b", [.file("f", 150 * mb)]),
                .file("loose-cache-file", 1 * gb),
            ]),
        ]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "userCaches" })
    #expect(insight.bytes == 300 * mb)
    #expect(insight.nodeIDs.count == 2)
    #expect(insight.children.count == 2)
}

@Test func globMatchesLastComponent() throws {
    let tree = FixtureTree.build([
        .dir("Pictures", [
            .dir("Family.photoslibrary", [.file("database", 300 * mb)]),
            .dir("Screenshots", [.file("shot.png", 300 * mb)]),
            .bundle("Work.photoslibrary", [.file("database", 250 * mb)]),
        ]),
        .dir("Movies", [.dir("Travelling.photoslibrary", [.file("x", 1 * gb)])]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "photosLibrary" })
    #expect(insight.bytes == 550 * mb)
    #expect(insight.nodeIDs.count == 2)
    #expect(insight.risk == .careful)
    #expect(insight.action == .revealOnly)
}

@Test func nestedDirectoryNamesAreCountedOnce() throws {
    let tree = FixtureTree.build([
        .dir("Projects", [
            .dir("app", [
                .dir("node_modules", [
                    .file("package", 250 * mb),
                    .dir("dep", [
                        .dir("node_modules", [.file("inner", 300 * mb)]),
                    ]),
                ]),
                .dir("build", [.file("artifact", 100 * mb)]),
            ]),
        ]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "developer.buildOutputs" })
    #expect(insight.nodeIDs.count == 1)
    #expect(insight.bytes == 550 * mb)
    let outer = tree.node(atPath: home + "/Projects/app/node_modules")
    #expect(insight.nodeIDs.first == outer)
}

@Test func nodeModulesBelowMinimumIsIgnored() {
    let tree = FixtureTree.build([
        .dir("Projects", [
            .dir("app", [.dir("node_modules", [.file("package", 150 * mb)])]),
        ]),
    ])
    #expect(insights(tree).contains { $0.id == "developer.buildOutputs" } == false)
}

@Test func downloadsSpecialRuleMatchesLargeFilesAndInstallers() throws {
    let tree = FixtureTree.build([
        .dir("Downloads", [
            .file("big.iso", 600 * mb),
            .file("installer.dmg", 10 * mb),
            .file("archive.zip", 15 * mb),
            .file("notes.txt", 20 * mb),
            .file("release.pkg", 5 * mb),
            .dir("nested", [.file("deep.pkg", 10 * mb)]),
            .file("small.txt", 10 * mb),
        ]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "downloads" })
    #expect(insight.bytes == 640 * mb)
    #expect(insight.nodeIDs.count == 5)
    #expect(insight.risk == .review)
    #expect(insight.action == .trash)
}

@Test func copyCommandsAreData() {
    let byID = Dictionary(uniqueKeysWithValues: RuleTable.all.map { ($0.id, $0) })
    #expect(byID["packageCache.homebrew"]?.action == SuggestedAction.copyCommand("brew cleanup"))
    #expect(byID["packageCache.npm"]?.action == SuggestedAction.copyCommand("npm cache clean --force"))
    #expect(byID["docker.diskImage"]?.action == SuggestedAction.copyCommand("docker system prune"))
    #expect(byID["xcode.simulators"]?.action == SuggestedAction.copyCommand("xcrun simctl delete unavailable"))
}

@Test func swapRuleIsDisplayOnly() throws {
    let tree = FixtureTree.build(rootPath: "/", [
        .dir("private", [
            .dir("var", [
                .dir("vm", [.file("swapfile0", 2 * gb)]),
            ]),
        ]),
        .dir("Users", [.dir("tester", [])]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "swap" })
    #expect(insight.action == .displayOnly)
    #expect(insight.risk == .careful)
}

@Test func multiPathRuleAggregatesExistingPaths() throws {
    let tree = FixtureTree.build([
        .dir("Parallels", [.file("win11.pvm", 1 * gb)]),
        .dir("Library", [
            .dir("Containers", [
                .dir("com.utmapp.UTM", [.file("vm", 500 * mb)]),
            ]),
        ]),
    ])
    let insight = try #require(insights(tree).first { $0.id == "vms" })
    #expect(insight.bytes == 1500 * mb)
    #expect(insight.nodeIDs.count == 2)
}

@Test func homeTrailingSlashIsNormalised() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [.file("Build", 300 * mb)]),
                ]),
            ]),
        ]),
    ])
    let insight = try #require(insights(tree, homePath: home + "/").first { $0.id == "xcode.derivedData" })
    #expect(insight.bytes == 300 * mb)
}
