// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LumaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .executable(name: "lumarecode", targets: ["LumaCLI"])
    ],
    targets: [
        .target(name: "LumaCore", path: "Sources/LumaCore"),
        .executableTarget(name: "LumaCLI", dependencies: ["LumaCore"]),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"])
    ],
    swiftLanguageModes: [.v6]
)
