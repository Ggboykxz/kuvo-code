// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenCodeKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OpenCodeKit", targets: ["OpenCodeKit"]),
    ],
    targets: [
        .target(name: "OpenCodeKit"),
        .testTarget(name: "OpenCodeKitTests", dependencies: ["OpenCodeKit"], resources: [.copy("Fixtures")]),
    ]
)
