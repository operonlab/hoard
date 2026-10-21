// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hoard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .executable(name: "hoard", targets: ["hoard"]),
        .executable(name: "HoardApp", targets: ["HoardApp"]),
    ],
    dependencies: [
        .package(path: "Packages/LayoutKit"),
        .package(path: "Packages/TreeCore"),
    ],
    targets: [
        .target(name: "ScanCore", dependencies: [.product(name: "TreeCore", package: "TreeCore")]),
        .executableTarget(name: "hoard", dependencies: ["ScanCore"]),
        .executableTarget(
            name: "HoardApp",
            dependencies: ["ScanCore", .product(name: "LayoutKit", package: "LayoutKit")]
        ),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
    ]
)
