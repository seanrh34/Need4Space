import Testing
@testable import ScannerKit

@Test func pathLookupRoundTrips() {
    var t = ScanTree(rootPath: "/")
    let root = t.addNode(name: "", kind: .directory, parent: ScanTree.none)
    let users = t.addNode(name: "Users", kind: .directory, parent: root)
    let sean = t.addNode(name: "sean", kind: .directory, parent: users)
    #expect(t.path(sean) == "/Users/sean")
    #expect(t.node(atPath: "/Users/sean") == sean)
    #expect(t.node(atPath: "/") == root)
    #expect(t.node(atPath: "/Users/nobody") == nil)
    #expect(Array(t.children(users)) == [sean])
}
