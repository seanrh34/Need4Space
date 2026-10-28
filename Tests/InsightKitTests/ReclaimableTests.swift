import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let home = FixtureTree.defaultRootPath
private let mb = Size.mb

private func insight(id: String, nodeIDs: [NodeID], bytes: UInt64, risk: Risk) -> Insight {
    Insight(
        id: id,
        title: id,
        detail: "",
        nodeIDs: nodeIDs,
        paths: [],
        bytes: bytes,
        risk: risk,
        action: .displayOnly
    )
}

@Test func reclaimableCountsNestedNodesOnce() throws {
    let tree = FixtureTree.build([
        .dir("Parent", [
            .dir("Child", [.file("inside", 400 * mb)]),
            .file("outside", 600 * mb),
        ]),
    ])
    let parent = try #require(tree.node(atPath: home + "/Parent"))
    let child = try #require(tree.node(atPath: home + "/Parent/Child"))

    let total = Reclaimable.safeBytes(
        insights: [
            insight(id: "parent", nodeIDs: [parent], bytes: 1000 * mb, risk: .safe),
            insight(id: "child", nodeIDs: [child], bytes: 400 * mb, risk: .safe),
        ],
        tree: tree
    )
    #expect(total == 1000 * mb)
}

@Test func reclaimableDoesNotCountTheSameNodeTwice() throws {
    let tree = FixtureTree.build([
        .dir("Caches", [
            .dir("A", [.file("data", 300 * mb)]),
            .dir("B", [.file("data", 200 * mb)]),
        ]),
    ])
    let a = try #require(tree.node(atPath: home + "/Caches/A"))
    let b = try #require(tree.node(atPath: home + "/Caches/B"))

    let total = Reclaimable.safeBytes(
        insights: [
            insight(id: "all", nodeIDs: [a, b], bytes: 500 * mb, risk: .safe),
            insight(id: "a-again", nodeIDs: [a], bytes: 300 * mb, risk: .safe),
        ],
        tree: tree
    )
    #expect(total == 500 * mb)
}

@Test func reclaimableIgnoresReviewAndCarefulInsights() throws {
    let tree = FixtureTree.build([
        .dir("Safe", [.file("data", 250 * mb)]),
        .dir("Review", [.file("data", 500 * mb)]),
        .dir("Careful", [.file("data", 900 * mb)]),
    ])
    let safe = try #require(tree.node(atPath: home + "/Safe"))
    let review = try #require(tree.node(atPath: home + "/Review"))
    let careful = try #require(tree.node(atPath: home + "/Careful"))

    let total = Reclaimable.safeBytes(
        insights: [
            insight(id: "safe", nodeIDs: [safe], bytes: 250 * mb, risk: .safe),
            insight(id: "review", nodeIDs: [review], bytes: 500 * mb, risk: .review),
            insight(id: "careful", nodeIDs: [careful], bytes: 900 * mb, risk: .careful),
        ],
        tree: tree
    )
    #expect(total == 250 * mb)
}

@Test func reclaimableSurvivesOutOfOrderInsights() throws {
    let tree = FixtureTree.build([
        .dir("Parent", [
            .dir("Child", [.file("inside", 400 * mb)]),
            .file("outside", 600 * mb),
        ]),
    ])
    let parent = try #require(tree.node(atPath: home + "/Parent"))
    let child = try #require(tree.node(atPath: home + "/Parent/Child"))

    let total = Reclaimable.safeBytes(
        insights: [
            insight(id: "child", nodeIDs: [child], bytes: 400 * mb, risk: .safe),
            insight(id: "parent", nodeIDs: [parent], bytes: 1000 * mb, risk: .safe),
        ],
        tree: tree
    )
    #expect(total == 1000 * mb)
}
