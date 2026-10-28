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

private func find(_ insights: [Insight], _ id: String) -> Insight? {
    insights.first { $0.id == id || $0.id.hasPrefix(id + ":") }
}

private func containsInsight(_ insights: [Insight], _ id: String) -> Bool {
    find(insights, id) != nil
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
    let insight = try #require(find(insights(tree), "xcode.derivedData"))
    #expect(insight.bytes == 300 * mb)
    #expect(insight.risk == .safe)
    #expect(insight.action == .trash)
    #expect(insight.category == .developer)
    #expect(insight.paths.first?.path == home + "/Library/Developer/Xcode/DerivedData")
    #expect(insight.id == "xcode.derivedData:\(home)/Library/Developer/Xcode/DerivedData")
    #expect(insight.nodeIDs.count == 1)
}

@Test func trashOnlyRevealsInFinder() throws {
    let tree = FixtureTree.build([
        .dir(".Trash", [.file("old.zip", 250 * mb)]),
    ])
    let insight = try #require(find(insights(tree), "trash"))
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
    #expect(containsInsight(insights(tree), "xcode.derivedData") == false)
}

@Test func perRuleMinimumOverride() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [.file("Build", 150 * mb)]),
                ]),
            ]),
        ]),
    ])
    #expect(containsInsight(insights(tree), "xcode.derivedData") == false)

    var rule = try #require(RuleTable.all.first { $0.id == "xcode.derivedData" })
    rule.minBytes = 100 * mb
    let custom = RuleEngine(rules: [rule]).evaluate(tree: tree, homePath: home).insights
    let insight = try #require(custom.first)
    #expect(insight.id.hasPrefix("xcode.derivedData:"))
    #expect(insight.bytes == 150 * mb)
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
    #expect(containsInsight(insights(tree), "xcode.derivedData"))
}

@Test func absolutePatternMatchesOutsideHome() throws {
    let tree = FixtureTree.build(rootPath: "/", [
        .dir("Library", [
            .dir("Logs", [.file("system.log", 300 * mb)]),
        ]),
        .dir("Users", [.dir("tester", [])]),
    ])
    let insight = try #require(find(insights(tree), "logs"))
    #expect(insight.bytes == 300 * mb)
    #expect(insight.paths.contains(where: { $0.path == "/Library/Logs" }))
}

@Test func perSubfolderChildrenRespectPerItemMinimum() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Caches", [
                .dir("com.example.a", [.file("f", 250 * mb)]),
                .dir("com.example.b", [.file("f", 300 * mb)]),
                .dir("com.example.small", [.file("f", 150 * mb)]),
                .file("loose-cache-file", 1 * gb),
            ]),
        ]),
    ])
    let insight = try #require(find(insights(tree), "userCaches"))
    #expect(insight.bytes == 550 * mb)
    #expect(insight.nodeIDs.count == 2)
    #expect(insight.children.count == 2)
}

@Test func globMatchesRespectPerItemMinimum() throws {
    let tree = FixtureTree.build([
        .dir("Pictures", [
            .dir("Small.photoslibrary", [.file("database", 150 * mb)]),
            .dir("Big.photoslibrary", [.file("database", 300 * mb)]),
        ]),
    ])
    let insight = try #require(find(insights(tree), "photosLibrary"))
    #expect(insight.bytes == 300 * mb)
    #expect(insight.nodeIDs.count == 1)
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
    let insight = try #require(find(insights(tree), "photosLibrary"))
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
    let insight = try #require(find(insights(tree), "developer.buildOutputs"))
    #expect(insight.nodeIDs.count == 1)
    #expect(insight.bytes == 550 * mb)
    let outer = tree.node(atPath: home + "/Projects/app/node_modules")
    #expect(insight.nodeIDs.first == outer)
}

@Test func anyDirectoryNamedScopeCaseAndProjectDates() throws {
    let tree = FixtureTree.build([
        .dir("Code", [
            .dir("node_modules", [.file("package", 300 * mb)]),
        ], modTime: 2_000),
        .dir("Other", [
            .dir("node_modules", [.file("package", 350 * mb)]),
        ], modTime: 3_000),
        .dir("Capital", [
            .dir("Build", [.file("artifact", 500 * mb)]),
        ], modTime: 4_000),
        .dir(".Trash", [
            .dir("node_modules", [.file("package", 500 * mb)]),
        ]),
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [
                        .dir("proj", [
                            .dir("Build", [.file("artifact", 500 * mb)]),
                        ]),
                    ]),
                ]),
            ]),
        ]),
        .bundle("Foo.bundle", [
            .dir("node_modules", [.file("package", 500 * mb)]),
        ]),
    ])
    let rule = try #require(RuleTable.all.first { $0.id == "developer.buildOutputs" })
    let result = RuleEngine(rules: [rule]).evaluate(tree: tree, homePath: home)
    let insight = try #require(result.insights.first)
    #expect(insight.nodeIDs.count == 2)
    #expect(insight.children.count == 2)
    #expect(insight.children.first?.bytes == 350 * mb)
    #expect(insight.children.first?.projectModTime == 3_000)
    #expect(insight.childrenByProjectDate.count == 2)
    #expect(insight.childrenByProjectDate.first?.projectModTime == 3_000)
    #expect(insight.childrenByProjectDate.last?.projectModTime == 2_000)
}

@Test func anyDirectoryNamedSkipsClaimedSubtrees() throws {
    let tree = FixtureTree.build([
        .dir("Claimed", [
            .dir("node_modules", [.file("package", 400 * mb)]),
        ]),
    ])
    let claimRule = Rule(
        id: "claim",
        title: "Claimed folder",
        detail: "",
        patterns: [.home("Claimed")],
        risk: .review,
        action: .revealOnly
    )
    let buildRule = try #require(RuleTable.all.first { $0.id == "developer.buildOutputs" })
    let result = RuleEngine(rules: [claimRule, buildRule])
        .evaluate(tree: tree, homePath: home)
    #expect(result.insights.count == 1)
    #expect(result.insights.first?.id.hasPrefix("claim:") == true)
}

@Test func nodeModulesBelowMinimumIsIgnored() {
    let tree = FixtureTree.build([
        .dir("Projects", [
            .dir("app", [.dir("node_modules", [.file("package", 150 * mb)])]),
        ]),
    ])
    #expect(containsInsight(insights(tree), "developer.buildOutputs") == false)
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
    let insight = try #require(find(insights(tree), "downloads"))
    #expect(insight.bytes == 640 * mb)
    #expect(insight.nodeIDs.count == 5)
    #expect(insight.risk == .review)
    #expect(insight.action == .trash)
}

@Test func overlappingRulesDoNotDoubleCountHomebrew() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Caches", [
                .dir("Homebrew", [.file("bottle", 500 * mb)]),
                .dir("com.example.other", [.file("cache", 300 * mb)]),
            ]),
        ]),
    ])
    let evaluation = RuleEngine().evaluate(tree: tree, homePath: home)
    let homebrew = try #require(
        evaluation.insights.first { $0.id.hasPrefix("packageCache.homebrew:") }
    )
    let caches = try #require(
        evaluation.insights.first { $0.id.hasPrefix("userCaches:") }
    )
    #expect(homebrew.bytes == 500 * mb)
    #expect(caches.bytes == 300 * mb)
    #expect(caches.nodeIDs.count == 1)
    #expect(Reclaimable.safeBytes(insights: evaluation.insights, tree: tree) == 800 * mb)
}

@Test func laterRuleSubtractsClaimedDescendants() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Caches", [
                .dir("Homebrew", [.file("bottle", 500 * mb)]),
                .dir("com.example.other", [.file("cache", 300 * mb)]),
            ]),
        ]),
    ])
    let specific = Rule(
        id: "specific",
        title: "Homebrew",
        detail: "",
        patterns: [.home("Library/Caches/Homebrew")],
        risk: .safe,
        action: .trash
    )
    let parent = Rule(
        id: "parent",
        title: "Caches",
        detail: "",
        patterns: [.home("Library/Caches")],
        risk: .safe,
        action: .trash
    )
    let result = RuleEngine(rules: [specific, parent])
        .evaluate(tree: tree, homePath: home)
    let parentInsight = try #require(
        result.insights.first { $0.id.hasPrefix("parent:") }
    )
    #expect(parentInsight.bytes == 300 * mb)
    let cachesNode = try #require(tree.node(atPath: home + "/Library/Caches"))
    #expect(parentInsight.nodeIDs == [cachesNode])
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
    let insight = try #require(find(insights(tree), "swap"))
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
    let insight = try #require(find(insights(tree), "vms"))
    #expect(insight.bytes == 1 * gb + 500 * mb)
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
    let insight = try #require(
        find(insights(tree, homePath: home + "/"), "xcode.derivedData")
    )
    #expect(insight.bytes == 300 * mb)
}
