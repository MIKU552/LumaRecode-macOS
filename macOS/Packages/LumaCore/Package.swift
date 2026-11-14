// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LumaCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LumaCore", targets: ["LumaCore"])],
    targets: [
        .target(name: "LumaCore", path: "Sources/LumaCore"),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"])
    ]
)
