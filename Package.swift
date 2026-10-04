// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Disker",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Disker", targets: ["Disker"]),
        .library(name: "DiskerCore", targets: ["DiskerCore"]),
        .executable(name: "disker-index", targets: ["DiskerIndexCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0")
    ],
    targets: [
        .executableTarget(name: "Disker", dependencies: ["DiskerCore"]),
        .target(name: "CDiskerScan", publicHeadersPath: "include"),
        .target(name: "DiskerCore", dependencies: ["CDiskerScan", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "DiskerIndexCLI", dependencies: ["DiskerCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "DiskerCoreTests", dependencies: ["DiskerCore"]),
        .testTarget(name: "DiskerAppTests", dependencies: ["Disker", "DiskerCore"])
    ]
)
