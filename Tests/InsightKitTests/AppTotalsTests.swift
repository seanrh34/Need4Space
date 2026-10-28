import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let home = FixtureTree.defaultRootPath
private let mb = Size.mb

@Test func appTotalsIncludeAllSupportLocations() throws {
    let tree = FixtureTree.build([
        .dir("Applications", [
            .bundle("Foo.app", [.file("Foo", 100 * mb)]),
        ]),
        .dir("Library", [
            .dir("Application Support", [
                .dir("Foo", [.file("data", 300 * mb)]),
            ]),
            .dir("Caches", [
                .dir("com.example.foo", [.file("cache", 50 * mb)]),
            ]),
            .dir("Containers", [
                .dir("com.example.foo", [.file("container", 100 * mb)]),
            ]),
            .dir("Group Containers", [
                .dir("TEAM123456.com.example.foo", [.file("group", 20 * mb)]),
                .dir("TEAM123456.com.example.other", [.file("other", 900 * mb)]),
            ]),
            .dir("Logs", [
                .dir("Foo", [.file("log", 10 * mb)]),
            ]),
        ]),
    ])

    let apps = AppTotals.compute(
        tree: tree,
        homePath: home,
        apps: [
            AppBundleInfo(
                path: home + "/Applications/Foo.app",
                name: "Foo",
                bundleID: "com.example.foo"
            ),
        ]
    )
    let foo = try #require(apps.first)
    #expect(foo.bundleBytes == 100 * mb)
    #expect(foo.supportBytes == 480 * mb)
    #expect(foo.supportOver2xBundle)
    #expect(foo.totalBytes == 580 * mb)
    #expect(foo.nodeIDs.count == 6)
    #expect(foo.id == "com.example.foo")
}

@Test func applicationSupportByBundleIDIsCounted() throws {
    let tree = FixtureTree.build([
        .dir("Applications", [
            .bundle("Bar.app", [.file("Bar", 300 * mb)]),
        ]),
        .dir("Library", [
            .dir("Application Support", [
                .dir("com.example.bar", [.file("data", 100 * mb)]),
            ]),
        ]),
    ])
    let bar = try #require(
        AppTotals.compute(
            tree: tree,
            homePath: home,
            apps: [AppBundleInfo(path: home + "/Applications/Bar.app", name: "Bar", bundleID: "com.example.bar")]
        ).first
    )
    #expect(bar.bundleBytes == 300 * mb)
    #expect(bar.supportBytes == 100 * mb)
    #expect(!bar.supportOver2xBundle)
}

@Test func missingBundleStillReportsSupportData() throws {
    let tree = FixtureTree.build([
        .dir("Library", [
            .dir("Application Support", [
                .dir("Ghost", [.file("data", 400 * mb)]),
            ]),
        ]),
    ])
    let ghost = try #require(
        AppTotals.compute(
            tree: tree,
            homePath: home,
            apps: [AppBundleInfo(path: home + "/Applications/Ghost.app", name: "Ghost", bundleID: nil)]
        ).first
    )
    #expect(ghost.bundleBytes == 0)
    #expect(ghost.supportBytes == 400 * mb)
    #expect(ghost.supportOver2xBundle)
}

@Test func appsAreSortedByTotalDescending() {
    let tree = FixtureTree.build([
        .dir("Applications", [
            .bundle("Small.app", [.file("bin", 100 * mb)]),
            .bundle("Large.app", [.file("bin", 900 * mb)]),
        ]),
    ])
    let apps = AppTotals.compute(
        tree: tree,
        homePath: home,
        apps: [
            AppBundleInfo(path: home + "/Applications/Small.app", name: "Small", bundleID: "small"),
            AppBundleInfo(path: home + "/Applications/Large.app", name: "Large", bundleID: "large"),
        ]
    )
    #expect(apps.map(\.name) == ["Large", "Small"])
}
