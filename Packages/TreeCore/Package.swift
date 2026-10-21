// swift-tools-version:5.10
// The tree model, snapshots, history and diff. Foundation only, no Darwin APIs:
// must build and test on Linux too (the cloud lane runs these tests there).
import PackageDescription

let package = Package(
    name: "TreeCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TreeCore", targets: ["TreeCore"])],
    targets: [
        .target(name: "TreeCore"),
        .testTarget(name: "TreeCoreTests", dependencies: ["TreeCore"]),
    ]
)
