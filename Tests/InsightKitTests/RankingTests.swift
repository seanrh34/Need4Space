import Foundation
import ScannerKit
import Testing

@testable import InsightKit

private let mb = Size.mb

private func makeInsight(_ id: String, bytes: UInt64, risk: Risk) -> Insight {
    Insight(
        id: id,
        title: id,
        detail: "",
        nodeIDs: [],
        paths: [],
        bytes: bytes,
        risk: risk,
        action: .displayOnly
    )
}

@Test func rankingSortsByBytesDescending() {
    let ranked = Ranking.rank([
        makeInsight("small", bytes: 10 * mb, risk: .safe),
        makeInsight("large", bytes: 100 * mb, risk: .careful),
        makeInsight("medium", bytes: 50 * mb, risk: .review),
    ])
    #expect(ranked.map(\.id) == ["large", "medium", "small"])
}

@Test func rankingPromotesSafeChainThroughSeveralUnsafeItems() {
    let ranked = Ranking.rank([
        makeInsight("unsafe-100", bytes: 100 * mb, risk: .review),
        makeInsight("safe-95", bytes: 95 * mb, risk: .safe),
        makeInsight("safe-90", bytes: 90 * mb, risk: .safe),
        makeInsight("safe-85", bytes: 85 * mb, risk: .safe),
    ])
    #expect(ranked.map(\.id) == ["safe-95", "safe-90", "safe-85", "unsafe-100"])
}

@Test func rankingDoesNotPromoteItemsOutsideTwentyPercent() {
    let ranked = Ranking.rank([
        makeInsight("unsafe-100", bytes: 100 * mb, risk: .careful),
        makeInsight("safe-60", bytes: 60 * mb, risk: .safe),
    ])
    #expect(ranked.map(\.id) == ["unsafe-100", "safe-60"])
}

@Test func rankingPromotesWhenSizesAreExactlyWithinTwentyPercent() {
    let ranked = Ranking.rank([
        makeInsight("unsafe-100", bytes: 100 * mb, risk: .review),
        makeInsight("safe-80", bytes: 80 * mb, risk: .safe),
    ])
    #expect(ranked.map(\.id) == ["safe-80", "unsafe-100"])
}

@Test func rankingLeavesSafeItemsAlone() {
    let ranked = Ranking.rank([
        makeInsight("safe-100", bytes: 100 * mb, risk: .safe),
        makeInsight("review-90", bytes: 90 * mb, risk: .review),
        makeInsight("safe-70", bytes: 70 * mb, risk: .safe),
    ])
    #expect(ranked.map(\.id) == ["safe-100", "review-90", "safe-70"])
}
