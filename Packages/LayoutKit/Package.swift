// swift-tools-version:5.10
// Pure geometry, no Darwin imports: must build and test on Linux too.
import PackageDescription

let package = Package(
    name: "LayoutKit",
    products: [.library(name: "LayoutKit", targets: ["LayoutKit"])],
    targets: [
        .target(name: "LayoutKit"),
        .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit"]),
    ]
)
