// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KuvoLink",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "KuvoLink", targets: ["KuvoLink"]),
    ],
    targets: [
        .target(name: "KuvoLink"),
        .testTarget(name: "KuvoLinkTests", dependencies: ["KuvoLink"]),
    ]
)
