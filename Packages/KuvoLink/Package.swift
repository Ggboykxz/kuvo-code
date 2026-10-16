// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KuvoLink",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "KuvoLink", targets: ["KuvoLink"]),
    ],
    targets: [
        // The machines' side of the link, in JavaScript, which the Mac app puts on each machine.
        .target(name: "KuvoLink", resources: [.copy("Resources/kuvo-link.js")]),
        .testTarget(name: "KuvoLinkTests", dependencies: ["KuvoLink"]),
    ]
)
