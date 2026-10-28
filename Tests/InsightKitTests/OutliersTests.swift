import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let home = FixtureTree.defaultRootPath
private let mb = Size.mb
private let gb = Size.gb

@Test func largeFoldersPushDownToWhereTheMassIs() {
    let tree = FixtureTree.build([
        .dir("ParentA", [
            .dir("ChildHeavy", [.file("data", 1200 * mb)]),
            .dir("ChildSmall", [.file("data", 300 * mb)]),
            .file("rest", 500 * mb),
        ]),
        .dir("ParentB", [
            .dir("SpreadA", [.file("data", 600 * mb)]),
            .dir("SpreadB", [.file("data", 500 * mb)]),
            .file("rest", 900 * mb),
        ]),
    ])
    let insights = Outliers.largeFolders(
        tree: tree,
        usedBytes: 10 * gb,
        claimed: [],
        homePath: home,
        config: InsightsConfig()
    )
    let titles = Set(insights.map(\.title))
    #expect(!titles.contains("Large folder: ParentA"))
    #expect(titles.contains("Large folder: ChildHeavy"))
    #expect(titles.contains("Large folder: ParentB"))
    #expect(!titles.contains("Large folder: SpreadA"))
    #expect(!titles.contains("Large folder: SpreadB"))
}

@Test func largeFoldersSkipProtectedPaths() {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("SomeHugeThing", [.file("data", 3 * gb)]),
        ]),
        .dir("HomeLibrary", [.file("data", 3 * gb)]),
    ])
    let insights = Outliers.largeFolders(
        tree: tree,
        usedBytes: 10 * gb,
        claimed: [],
        homePath: home,
        config: InsightsConfig()
    )
    #expect(insights.contains { $0.paths.first?.path == home + "/Library" } == false)
    #expect(insights.contains { $0.title == "Large folder: SomeHugeThing" })
}

@Test func largeFoldersIgnoreClaimedBytes() throws {
    let tree = FixtureTree.build([
        .dir("ClaimedDir", [
            .dir("Claimed", [.file("data", 800 * mb)]),
            .file("rest", 400 * mb),
        ]),
    ])
    let claimedNode = try #require(tree.node(atPath: home + "/ClaimedDir/Claimed"))
    let insights = Outliers.largeFolders(
        tree: tree,
        usedBytes: 10 * gb,
        claimed: [claimedNode],
        homePath: home,
        config: InsightsConfig()
    )
    let claimedDir = try #require(insights.first { $0.title == "Large folder: ClaimedDir" })
    #expect(claimedDir.bytes == 400 * mb)
    #expect(insights.contains { $0.title == "Large folder: Claimed" } == false)
}

@Test func largeFoldersRespectMinimumFraction() {
    let tree = FixtureTree.build([
        .dir("Medium", [.file("data", 250 * mb)]),
    ])
    let insights = Outliers.largeFolders(
        tree: tree,
        usedBytes: 10 * gb,
        claimed: [],
        homePath: home,
        config: InsightsConfig()
    )
    #expect(insights.isEmpty)
}

@Test func staleFilesUseAccessTimeWhenPresent() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds = Int64(now.timeIntervalSince1970)
    let day: Int64 = 86_400
    let tree = FixtureTree.build([
        .dir("Files", [
            .file(
                "accessed-long-ago",
                600 * mb,
                modTime: nowSeconds - 10 * day,
                accessTime: nowSeconds - 400 * day
            ),
            .file(
                "modified-long-ago",
                600 * mb,
                modTime: nowSeconds - 400 * day,
                accessTime: 0
            ),
            .file(
                "recently-accessed",
                600 * mb,
                modTime: nowSeconds - 400 * day,
                accessTime: nowSeconds - 10 * day
            ),
            .file("too-small", 400 * mb, modTime: nowSeconds - 400 * day),
            .smallFiles("group", count: 10, bytes: 900 * mb),
            .file("no-times", 600 * mb),
        ]),
    ])
    let insights = Outliers.staleFiles(
        tree: tree,
        now: now,
        homePath: home,
        config: InsightsConfig()
    )
    #expect(insights.count == 2)
    #expect(insights.allSatisfy { $0.risk == .review && $0.action == .trash })
    #expect(insights.contains { $0.paths.first?.lastPathComponent == "accessed-long-ago" })
    #expect(insights.contains { $0.paths.first?.lastPathComponent == "modified-long-ago" })
}

@Test func staleFilesRespectAgeAndSizeConfiguration() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds = Int64(now.timeIntervalSince1970)
    let day: Int64 = 86_400
    let tree = FixtureTree.build([
        .dir("Files", [
            .file("old-but-small", 600 * mb, modTime: nowSeconds - 800 * day),
            .file("old-and-big", 700 * mb, modTime: nowSeconds - 800 * day),
        ]),
    ])
    var config = InsightsConfig()
    config.staleFileMinBytes = 650 * mb
    config.staleFileAgeDays = 700
    let strict = Outliers.staleFiles(tree: tree, now: now, homePath: home, config: config)
    #expect(strict.count == 1)
    let only = try #require(strict.first)
    #expect(only.bytes == 700 * mb)

    config.staleFileAgeDays = 1000
    let none = Outliers.staleFiles(tree: tree, now: now, homePath: home, config: config)
    #expect(none.isEmpty)
}

@Test func fastGrowersMatchByNameAndSize() throws {
    let old = FixtureTree.build([
        .dir("Projects", [
            .dir("Grew", [.file("data", 100 * mb)]),
            .dir("Same", [.file("data", 100 * mb)]),
            .dir("Shrank", [.file("data", 2 * gb)]),
        ]),
    ])
    let new = FixtureTree.build([
        .dir("Projects", [
            .dir("Grew", [.file("data", 100 * mb + 1 * gb)]),
            .dir("Same", [.file("data", 100 * mb)]),
            .dir("Shrank", [.file("data", 100 * mb)]),
        ]),
        .dir("OtherNew", [.file("data", 5 * gb)]),
    ])
    let insights = Outliers.fastGrowers(
        tree: new,
        previous: old,
        homePath: home,
        config: InsightsConfig()
    )
    let insight = try #require(insights.first)
    #expect(insight.id == "outlier.fastGrowers")
    #expect(insight.bytes == 1 * gb)
    #expect(insight.nodeIDs.count == 1)
    #expect(insight.children.first?.name == "Grew")
}

@Test func fastGrowersNeedAPreviousScan() {
    let tree = FixtureTree.build([
        .dir("Projects", [.file("data", 5 * gb)]),
    ])
    #expect(
        Outliers.fastGrowers(
            tree: tree,
            previous: nil,
            homePath: home,
            config: InsightsConfig()
        ).isEmpty
    )
}

@Test func fastGrowersIgnoreDirectoriesDeeperThanTheLimit() throws {
    func makeTree(fileBytes: UInt64) -> ScanTree {
        var children: [FixtureNode] = [.file("data", fileBytes)]
        for level in stride(from: 7, through: 1, by: -1) {
            children = [.dir("d\(level)", children)]
        }
        return FixtureTree.build(children)
    }

    let old = makeTree(fileBytes: 100 * mb)
    let new = makeTree(fileBytes: 2 * gb + 100 * mb)
    let insights = Outliers.fastGrowers(
        tree: new,
        previous: old,
        homePath: home,
        config: InsightsConfig()
    )
    let insight = try #require(insights.first)
    #expect(insight.nodeIDs.count == 1)
    #expect(insight.children.contains { $0.name == "d7" } == false)
    #expect(insight.children.contains { $0.name == "d6" })
}
