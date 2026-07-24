// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RiseAndGrindCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "RiseAndGrindCore", targets: ["RiseAndGrindCore"]),
        .executable(name: "CoreChecks", targets: ["CoreChecks"]),
    ],
    targets: [
        .target(
            name: "RiseAndGrindCore",
            path: "Core/Sources/RiseAndGrindCore"
        ),
        .testTarget(
            name: "RiseAndGrindCoreTests",
            dependencies: ["RiseAndGrindCore"],
            path: "Core/Tests/RiseAndGrindCoreTests"
        ),
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["RiseAndGrindCore"],
            path: "Core/Checks/CoreChecks"
        ),
    ]
)
