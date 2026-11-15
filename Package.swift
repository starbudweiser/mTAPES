// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mTAPES",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "MTapesEngine", targets: ["MTapesEngine"]),
        .executable(name: "mtapes", targets: ["mtapes"]),
    ],
    targets: [
        .target(name: "MTapesEngine"),
        .executableTarget(name: "mtapes", dependencies: ["MTapesEngine"]),
        .testTarget(name: "MTapesEngineTests", dependencies: ["MTapesEngine"]),
    ]
)
