// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LumaCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .library(name: "LumaPhotos", targets: ["LumaPhotos"]),
        .executable(name: "lumarecode", targets: ["LumaCLI"])
    ],
    targets: [
        .target(name: "LumaCore", path: "Sources/LumaCore", resources: [.process("Resources")]),
        .target(name: "LumaPhotos", dependencies: ["LumaCore"], path: "Sources/LumaPhotos"),
        .executableTarget(name: "LumaCLI", dependencies: ["LumaCore"]),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"]),
        .testTarget(name: "LumaPhotosTests", dependencies: ["LumaPhotos"])
    ],
    swiftLanguageModes: [.v6]
)
