// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Need4Space",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .library(name: "InsightKit", targets: ["InsightKit"]),
        .executable(name: "n4s-scan", targets: ["n4s-scan"]),
        .executable(name: "Need4Space", targets: ["Need4Space"]),
    ],
    targets: [
        .target(name: "ScannerKit"),
        .target(name: "InsightKit", dependencies: ["ScannerKit"]),
        .executableTarget(name: "n4s-scan", dependencies: ["ScannerKit"]),
        .executableTarget(name: "Need4Space", dependencies: ["ScannerKit", "InsightKit"]),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"]),
        .testTarget(name: "InsightKitTests", dependencies: ["InsightKit", "ScannerKit"]),
    ],
    swiftLanguageModes: [.v6]
)
