import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let home = FixtureTree.defaultRootPath
private let mb = Size.mb
private let gb = Size.gb

@Test func engineReportCombinesRulesAppsOutliersAndHiddenSpace() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds = Int64(now.timeIntervalSince1970)
    let day: Int64 = 86_400

    let tree = FixtureTree.build([
        .dir(".Trash", [.file("old.zip", 300 * mb)]),
        .dir("Library", [
            .dir("Developer", [
                .dir("Xcode", [
                    .dir("DerivedData", [.file("Build", 250 * mb)]),
                ]),
            ]),
            .dir("Caches", [
                .dir("com.example.a", [.file("data", 250 * mb)]),
                .dir("com.example.b", [.file("data", 300 * mb)]),
            ]),
            .dir("Application Support", [
                .dir("Bar", [.file("data", 50 * mb)]),
            ]),
        ]),
        .dir("Applications", [
            .bundle("Bar.app", [.file("Bar", 100 * mb)]),
        ]),
        .dir("Projects", [
            .dir("Huge", [.file("data", 1 * gb)]),
        ]),
        .file("old-backup.bin", 600 * mb, modTime: nowSeconds - 400 * day, accessTime: 0),
    ])

    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 100 * gb,
        usedBytes: 10 * gb,
        freeBytes: 90 * gb,
        purgeableBytes: 1 * gb
    )
    let report = InsightEngine().run(
        tree: tree,
        homePath: home,
        volume: volume,
        blocked: [0],
        apps: [AppBundleInfo(path: home + "/Applications/Bar.app", name: "Bar", bundleID: "com.example.bar")],
        previous: nil,
        now: now
    )

    #expect(report.insights.contains(where: { $0.id.hasPrefix("trash:") }))
    #expect(report.insights.contains(where: { $0.id.hasPrefix("xcode.derivedData:") }))
    #expect(report.insights.contains(where: { $0.id.hasPrefix("userCaches:") }))
    #expect(report.insights.contains(where: { $0.id.hasPrefix("hidden.space:") }))
    #expect(report.insights.contains(where: { $0.id.hasPrefix("largeFolder:") }))
    #expect(report.insights.contains(where: { $0.id.hasPrefix("staleFile:") }))

    #expect(report.reclaimableSafeBytes == 1100 * mb)
    #expect(report.hidden.gapBytes > 0)
    #expect(report.hidden.blockedCount == 1)

    let bar = try #require(report.apps.first)
    #expect(bar.name == "Bar")
    #expect(bar.bundleBytes == 100 * mb)
    #expect(bar.supportBytes == 50 * mb)
    #expect(!bar.supportOver2xBundle)
}

@Test func engineWithNoVolumeDoesNotInventHiddenSpace() {
    let tree = FixtureTree.build([
        .dir(".Trash", [.file("old.zip", 300 * mb)]),
    ])
    let report = InsightEngine().run(tree: tree, homePath: home)
    #expect(report.hidden.gapBytes == 0)
    #expect(report.insights.contains(where: { $0.id.hasPrefix("hidden.space:") }) == false)
    #expect(report.reclaimableSafeBytes == 300 * mb)
}

@Test func engineRankingPutsSafeFirstWithinTwentyPercent() {
    let tree = FixtureTree.build([
        .dir(".Trash", [.file("old.zip", 900 * mb)]),
        .dir("Downloads", [.file("huge.dmg", 1 * gb)]),
    ])
    let report = InsightEngine().run(tree: tree, homePath: home)
    #expect(report.insights.first?.id.hasPrefix("trash:") == true)
}

@Test func engineProtectsStaleFilesInsideCarefulRulesAndBundles() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds = Int64(now.timeIntervalSince1970)
    let day: Int64 = 86_400
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Mail", [
                .dir("Inbox.mbox", [
                    .file("old.eml", 600 * mb, modTime: nowSeconds - 400 * day),
                ]),
            ]),
        ]),
        .dir("Applications", [
            .bundle("Foo.app", [
                .dir("Contents", [
                    .file("old.bin", 600 * mb, modTime: nowSeconds - 400 * day),
                ]),
            ]),
        ]),
    ])
    let report = InsightEngine().run(tree: tree, homePath: home, now: now)
    let stale = report.insights.filter { $0.id.hasPrefix("staleFile:") }
    #expect(stale.count == 1)
    #expect(stale.first?.risk == .careful)
    #expect(stale.first?.action == .revealOnly)
}

@Test func engineUsesDisplayOnlyForStaleFileInsideSwap() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds = Int64(now.timeIntervalSince1970)
    let day: Int64 = 86_400
    let tree = FixtureTree.build(rootPath: "/", [
        .dir("private", [
            .dir("var", [
                .dir("vm", [
                    .file("swapfile0", 900 * mb, modTime: nowSeconds - 400 * day),
                ]),
            ]),
        ]),
        .dir("Users", [.dir("tester", [])]),
    ])
    let report = InsightEngine().run(tree: tree, homePath: home, now: now)
    let stale = report.insights.filter { $0.id.hasPrefix("staleFile:") }
    #expect(stale.count == 1)
    #expect(stale.first?.risk == .careful)
    #expect(stale.first?.action == .displayOnly)
}

@Test func hiddenInsightDetailListsSnapshots() throws {
    let tree = FixtureTree.build([
        .file("data", 1 * gb),
    ])
    let volume = VolumeInfo(
        mountPath: "/",
        totalBytes: 100 * gb,
        usedBytes: 10 * gb,
        freeBytes: 90 * gb,
        snapshots: [
            LocalSnapshot(name: "a"),
            LocalSnapshot(name: "b", bytes: 2 * gb),
        ]
    )
    let report = InsightEngine().run(tree: tree, homePath: home, volume: volume)
    let hiddenInsight = try #require(
        report.insights.first { $0.id.hasPrefix("hidden.space:") }
    )
    #expect(hiddenInsight.detail.contains("Local snapshots: 2"))
    #expect(hiddenInsight.detail.contains("with known sizes"))
}

@Test func categoriesClassifyCommonPaths() throws {
    let tree = FixtureTree.build([
        .dir(".Trash", []),
        .dir("Library", [
            .dir("Caches", []),
            .dir("Developer", [.dir("Xcode", [.dir("DerivedData", [])])]),
        ]),
        .dir("Applications", [.bundle("Foo.app", [])]),
        .dir("Pictures", [.file("photo.jpg", 10 * mb)]),
        .dir("Documents", [.file("report.pdf", 10 * mb)]),
    ])
    let trash = try #require(tree.node(atPath: home + "/.Trash"))
    let caches = try #require(tree.node(atPath: home + "/Library/Caches"))
    let derivedData = try #require(tree.node(atPath: home + "/Library/Developer/Xcode/DerivedData"))
    let app = try #require(tree.node(atPath: home + "/Applications/Foo.app"))
    let photo = try #require(tree.node(atPath: home + "/Pictures/photo.jpg"))
    let document = try #require(tree.node(atPath: home + "/Documents/report.pdf"))

    #expect(Category.forNode(trash, in: tree, homePath: home) == .trash)
    #expect(Category.forNode(caches, in: tree, homePath: home) == .caches)
    #expect(Category.forNode(derivedData, in: tree, homePath: home) == .developer)
    #expect(Category.forNode(app, in: tree, homePath: home) == .apps)
    #expect(Category.forNode(photo, in: tree, homePath: home) == .media)
    #expect(Category.forNode(document, in: tree, homePath: home) == .documents)
}
